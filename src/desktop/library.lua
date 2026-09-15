-- Композитор: механика оконного десктопа, вызываемая как библиотека.
--
-- Вида здесь нет. Всё, что рисуется, приходит темой в options.chrome, и
-- геометрию хрома — сколько строк занято сверху и снизу — тоже объявляет
-- она. Поэтому вторая оболочка приносит свою тему и получает другой вид,
-- не копируя ни хостинг окон, ни PTY, ни командный канал.
--
-- Он держит список окон в z-порядке, кладёт их кадры на общий холст,
-- раздаёт ввод и принимает команды снаружи. Окна о нём не знают: каждое
-- пишет в свой viewport через обычный `tty` и считает, что владеет
-- терминалом целиком.
--
-- Три правила, нарушение которых даёт молчаливую поломку:
--   * ни один yield-вызов не заканчивает функцию голым `return` — в
--     go-lua v1.5.18 такой хвостовой вызов не выполняется вовсе;
--   * `snapshot().rows` — общий неизменяемый массив брокера, его нельзя
--     править на месте;
--   * `viewport:send` до `tty.start()` окна — ошибка, а не потеря, поэтому
--     ввод придерживается до первого кадра.

local channel = require("channel")
local process = require("process")
local registry = require("registry")
local time = require("time")
local tty = require("tty")

local logger = require("logger")

local repo = require("repo")
local apps = require("apps")

-- Что запись реестра говорит о своей программе: тип окна и признак «показывать
-- в меню». Отдельной библиотекой, потому что читают её и меню, и открытие, а
-- умолчание, посчитанное в двух местах, однажды разойдётся.
local programs = require("programs")

-- Сборка пиксельного кадра: пробелы под картинками, разбор размещений и
-- попаданий. Отдельной библиотекой, потому что это арифметика — её проверяют
-- без терминала и без графики.
local pixels = require("pixels")

-- Протокол «окно просит десктоп». Отсюда механика берёт ключ, которым имя
-- композитора кладётся окну в контекст: разойдись ключ у отправителя и
-- получателя, окно молча обращалось бы к штатному имени.
local window_api = require("window_api")

-- claim_desktop_name(family, slots) -> name | nil, reason
--
-- Registers the first free name of the family (window_api.desktop_names). A
-- name is released with its process, so the number of a desktop that ended
-- goes to the next one.
local function claim_desktop_name(family: string, slots: any): (any, any)
    local first_error: any = nil
    local names: any = window_api.desktop_names(family, slots)
    for _, name in ipairs(names) do
        local ok, err = process.registry.register(tostring(name))
        if ok then return tostring(name), nil end
        first_error = first_error or err
    end
    return nil, "no desktop name of " .. family .. " is free (" .. tostring(#names)
        .. " tried): " .. tostring(first_error)
end

local WINDOW_HOST = "windows.tui_desktop:workers"

-- Окно — это любая запись процесса, которая умеет писать в свой tty-порт.
-- Модуль знает ровно одну свою (программа под PTY); всё остальное приносит
-- приложение и называет записью — иначе каждое новое окно требовало бы
-- правки этого модуля.
local PTY_WINDOW = "windows.tui_desktop.desktop:window_pty"

-- Каталог окон приложения: записи, помеченные этим meta.type, композитор
-- находит сам и показывает в меню по alt+o.
local WINDOW_META_TYPE = programs.WINDOW_META_TYPE

-- Топик ответа берётся у протокола окна, а не повторяется строкой: на нём
-- держится подписка окна, и разойдись они — ответ уехал бы окну в inbox, где
-- его съел бы чужой цикл.
local REPLY_TOPIC = window_api.REPLY_TOPIC

-- Команды, адресованные конкретному окну. Список нужен, чтобы отличать «нет
-- такого окна» от «нет такой команды»: пока их различал только порядок
-- проверок, ЛЮБАЯ неизвестная команда отвечала «нет окна nil» — то есть
-- отправитель шёл искать опечатку в идентификаторе, которого не посылал, а
-- ветка про неизвестную команду была недостижима вовсе.
local WINDOW_COMMANDS = {
    ["desktop.close"] = true,
    ["desktop.focus"] = true,
    ["desktop.move"] = true,
    ["desktop.resize"] = true,
    ["desktop.minimize"] = true,
    ["desktop.screen"] = true,
    ["desktop.type"] = true,
    ["desktop.key"] = true,
    -- Состояние окна-вида, присланное его поставщиком. Тоже адресовано окну,
    -- поэтому живёт здесь же: иначе «нет такого окна» и «нет такой команды»
    -- снова разошлись бы по разным веткам.
    ["desktop.state"] = true,
}

local DEFAULT_COMMAND = "/bin/bash -i"
local CLOSE_GRACE = "3s"


-- Часы на панели задач должны идти и тогда, когда никто ничего не нажимает.
-- Без этого тика кадр обновляется только на событии, и время на экране
-- останавливается — вид «оболочка зависла» при исправной оболочке.
local CLOCK_TICK = "15s"
-- Сколько последних кадров помнит замер времени (`frame.window` в статусе).
-- Двести — несколько секунд под потоком вывода и минуты в покое: хватает на
-- p95, не хватает, чтобы старый всплеск висел в сводке вечно.
local FRAME_WINDOW = 200
-- The shortest gap between two frames, in milliseconds. A frame per mouse
-- motion and per pty chunk backed the loop up until nothing — the clock
-- included — was drawn (the owner's freeze, 2026-09-14: 2.4 cores and 1.8 MB/s
-- to the terminal during a resize). Requests inside the gap are one frame.
local FRAME_MS = 33

-- Задержка, с которой наведение в меню раскрывает папку или закрывает
-- подменю. Как в Windows: без неё мышь, идущая от папки к её подменю по
-- диагонали, проходит над соседней строкой и закрывает то, куда идёт.
-- Выделение самой строки задержки не ждёт.
local HOVER_DELAY = "300ms"

-- Область уведомлений (трей). Пункт — короткая подпись у часов, которую
-- кладёт процесс приложения (погода, почта, состояние сервиса). Потолки не
-- украшение: пункт шире часов съедает кнопки окон, а седьмой пункт почти
-- всегда значит, что поставщик кладёт новый ключ на каждое обновление вместо
-- того, чтобы обновлять свой.
local TRAY_MAX = 6
local TRAY_TEXT = 16
local TRAY_KEY = 64

-- Desktop widgets (FR-006 in windows/shell): registry entries whose
-- process the compositor spawns like the state provider of a view window,
-- and whose published tree the theme draws in a panel under every window.
-- The base spawns, stops and hands the list to the theme; it draws nothing.
-- A size outside the limits is refused, not clamped: a tree laid out for
-- another size would be another widget.
local WIDGET_W, WIDGET_H = 20, 5
local WIDGET_MIN_W, WIDGET_MAX_W = 10, 40
local WIDGET_MIN_H, WIDGET_MAX_H = 2, 16
local WIDGET_ORDER = 100

-- Печатаемый текст, который агент шлёт в окно, отправляется по одной
-- клавише: у окна нет «вставки», а `paste` доезжает до программы только
-- если та включила bracketed paste.
local function runes(text)
    local out = {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = char
    end
    return out
end

-- Сообщение процесса приезжает обёрнутым: payload — userdata, а внутри
-- бывает ещё и массив из одного элемента. Прочитать поле напрямую значит
-- получить nil без всякой ошибки.
local function unwrap(value)
    if type(value) == "userdata" then
        local ok, decoded = pcall(function() return value:data() end)
        if ok and type(decoded) == "table" then return decoded end
        return {}
    end
    if type(value) ~= "table" then return {} end
    if value[1] ~= nil and #value > 0 then return unwrap(value[1]) end
    return value
end

-- clamp принимает что угодно и всегда возвращает целое: значения приходят
-- и от мыши, и из JSON команды, где числом может оказаться что угодно.
local function clamp(value, low, high)
    local lo = math.floor(low)
    local hi = math.floor(high)
    if lo > hi then lo = hi end
    local number = tonumber(value)
    if not number then return lo end
    number = math.floor(number)
    if number < lo then return lo end
    if number > hi then return hi end
    return number
end

-- run(options) — поднять композитор на текущем терминале.
--
--   options.chrome        — тема (контракт в README). Обязательна.
--   options.service_name  — имя, под которым композитор виден процессам.
--   options.service_slots — how many desktops of that name may run at once
--                           (default window_api.DESKTOP_SLOTS); each claims
--                           the first free of name, name.2, …
--   options.hint          — подсказка на пустом рабочем столе.
--   options.logon         — (screen) -> identity | nil, причина. Вход до первого
--                           кадра: identity = {actor, scope, context}, и под ней
--                           порождается каждое окно. Подробности в README.
--   options.widgets       — () -> {{entry, title, w, h, order, opens}, …}, failure:
--                           desktop widgets to spawn (README, "Desktop widgets").
local function run(options: any)
    options = type(options) == "table" and options or {}

    -- Тема обязательна и не подставляется молча: композитор без вида — это
    -- пустой экран, в котором нечего искать. Пусть отказ назовёт причину.
    local chrome: any = options.chrome
    if type(chrome) ~= "table" then
        return nil, "the compositor was given no theme (options.chrome)"
    end

    -- Пиксельный хром: рамки, заголовки, значки и панель задач приезжают
    -- растрами, содержимое окон остаётся символами. Включается ЯВНО — тем же
    -- решением, которым выбирают тему: терминал, умеющий графику, не повод
    -- рисовать иначе, чем человек просил.
    --
    -- Размер ячейки спрашивает ОБОЛОЧКА и передаёт сюда функцией. Так вышло не
    -- из вкуса: модуль `gfx` есть не в каждом рантайме, а запись, объявившая
    -- недоступный модуль, роняет боот целиком («node with ID {gfx :gfx} not
    -- found») — измерено. Механика, объявившая `gfx`, стала бы негодной везде,
    -- где графики нет, включая тех, кому пиксели не нужны. Решение при этом
    -- осталось здесь: без размера ячейки режим НЕ включается и называет
    -- причину — картинка не того размера выглядит как ошибка рисования, а не
    -- как незаданный вопрос.
    local PIXELS = options.pixels == true
    local cell_w, cell_h = 0, 0
    if PIXELS then
        if type(chrome.paint) ~= "function" then
            return nil, "pixel mode does not start: the theme has no chrome.paint"
        end
        if type(options.cell_size) ~= "function" then
            return nil, "pixel mode does not start: the shell gave nothing to learn "
                .. "the cell size with (options.cell_size — usually gfx.cell_size)"
        end
    end
    local function refresh_cell_size()
        if not PIXELS then return true end
        local w, h = options.cell_size()
        if type(w) ~= "number" or type(h) ~= "number" then
            -- gfx.cell_size() отвечает (nil, причина): вторым значением тут
            -- приезжает именно она.
            return nil, "pixel mode does not start: " .. tostring(h)
        end
        local next_w = math.tointeger(math.floor(w)) or 0
        local next_h = math.tointeger(math.floor(h)) or 0
        if next_w < 1 or next_h < 1 then
            return nil, "pixel mode does not start: a cell size of "
                .. tostring(w) .. "x" .. tostring(h) .. " is impossible"
        end
        cell_w, cell_h = next_w, next_h
        return true
    end
    local sized, size_error = refresh_cell_size()
    if not sized then return nil, size_error end

    -- The name this desktop answers to: the first free one of the family.
    -- Several run in one runtime when a terminal.ssh host gives every
    -- connection its own desktop.
    local SERVICE_FAMILY = type(options.service_name) == "string"
        and options.service_name ~= "" and options.service_name
        or "windows.tui_desktop.desktop"
    local claimed, claim_error = claim_desktop_name(SERVICE_FAMILY, options.service_slots)
    if not claimed then return nil, claim_error end
    local SERVICE_NAME: string = tostring(claimed)

    local HINT = type(options.hint) == "string" and options.hint
        or "alt+n — bash window · alt+o — programs · ctrl+q — quit"

    -- Вход в систему. Оболочка отдаёт функцию, которая рисует диалог на этом
    -- же терминале и возвращает личность: {actor, scope, context = {...}}.
    -- Под этой личностью композитор порождает КАЖДОЕ окно — и это вся
    -- механика «текущего пользователя»: сам композитор остаётся под своим
    -- актором, а личность окна фиксируется в момент порождения. Сменить
    -- пользователя значит закрыть окна и войти заново.
    local logon: any = type(options.logon) == "function" and options.logon or nil
    local IDENTITY: any = nil

    -- Порождение окна под вошедшим пользователем. Одна функция на оба вида
    -- окон: поставщик состояния и процесс с viewport получают одного и того
    -- же актора, иначе окно-вид и окно с программой жили бы под разными
    -- людьми, и различие всплыло бы на первом же «мои агенты».
    local function spawner(base: any, context: any): any
        if IDENTITY then
            for key, value in pairs(IDENTITY.context or {}) do
                if context[key] == nil then context[key] = value end
            end
        end
        local chain: any = base and base:with_context(context) or process.with_context(context)
        if IDENTITY then chain = chain:with_actor(IDENTITY.actor):with_scope(IDENTITY.scope) end
        return chain
    end

    -- Каталог программ. Внутренний отдаёт плоский список: механике окон
    -- незачем знать про папки меню и значки. Оболочка, которой это нужно,
    -- приносит свой — и отвечает за форму сама.
    local read_catalog: any = type(options.catalog) == "function" and options.catalog or nil

    -- Раскладка рабочего стола — ярлыки и папки. Механика их не хранит и
    -- не создаёт: это состояние оболочки, которое двигает пользователь.
    -- Она только показывает то, что дали, и говорит, куда кликнули.
    local read_desktop: any = type(options.desktop_items) == "function" and options.desktop_items or nil
    -- Окно свойств самого стола — пункт «Свойства» по правой кнопке на
    -- пустом месте. Идентификатор записи; нет — нет и меню.
    local desktop_properties: any = type(options.desktop_properties) == "string" and options.desktop_properties or nil
    -- Desktop widgets (FR-006): `() -> {{entry, title, w, h, order, opens}, …}, failure`.
    -- The shell reads the registry and hands the list over, as it does for
    -- desktop items; the base spawns the entries and draws nothing.
    local read_widgets: any = type(options.widgets) == "function" and options.widgets or nil

    -- Восстановление окон мастерской требует права менять реестр. Оболочке
    -- под другим актором его может не быть, и тогда важно, чтобы отказ был
    -- назван, а не проглочен: он уезжает в restore_report.
    local RESTORE = options.restore ~= false

    -- Толщина рамки. Раньше композитор считал её равной единице со всех
    -- сторон — то есть знал про вид. Тема с полосой заголовка ВНУТРИ рамки
    -- забирает сверху три строки, и окно, посчитанное по единице, отдало бы
    -- программе на строку больше, чем видно.
    local insets: any = {}
    local FRAME_W, FRAME_H, MIN_W, MIN_H = 2, 2, 12, 5
    local function refresh_frame()
        insets = {top = 1, bottom = 1, left = 1, right = 1}
        if type(chrome.window_insets) == "function" then
            local given: any = chrome.window_insets()
            if type(given) == "table" then
                for _, side in ipairs({"top", "bottom", "left", "right"}) do
                    local value = math.tointeger(tonumber(given[side]) or 1) or 1
                    insets[side] = math.max(0, value)
                end
            end
        end
        FRAME_W = (math.tointeger(insets.left) or 1) + (math.tointeger(insets.right) or 1)
        FRAME_H = (math.tointeger(insets.top) or 1) + (math.tointeger(insets.bottom) or 1)
        MIN_W = math.max(12, FRAME_W + 4)
        MIN_H = math.max(5, FRAME_H + 3)
    end
    refresh_frame()

    -- Записать новое место значка. Раскладку хранит оболочка, поэтому
    -- композитор не пишет её сам, а просит — и откатывает значок, если
    -- запись не удалась. Отказ, после которого значок остался на новом
    -- месте, соврал бы: до перезапуска он там, после — нет.
    local move_item: any = type(options.move_desktop_item) == "function"
        and options.move_desktop_item or nil

    local events = assert(tty.events())
    assert(tty.start())
    assert(tty.mouse(true))

    local lifecycle = assert(process.events())
    local inbox = process.inbox()

    -- Окна, собранные в рантайме, возвращаются в реестр здесь, а не фоновым
    -- сервисом: платформа намеренно запрещает процессам в группе
    -- `wippy.security:process` менять реестр, и такой сервис молча не сделал
    -- бы ничего. Композитор работает под собственным актором, и права у него
    -- свои — а нужны эти окна ровно тогда, когда десктоп запущен.
    local log = logger:named("tui_desktop.desktop")

    -- Итог восстановления держится в состоянии и отдаётся командным каналом:
    -- лог терминального хоста заглушён (иначе он разъедет кадр), и отказ,
    -- рассказанный только в лог, не расскажут никому.
    local restore_report: any = {restored = 0, failed = 0, error = nil, names = {}}

    local stored: any = nil
    local store_err: any = nil
    if RESTORE then stored, store_err = repo.list() end

    if not RESTORE then
        restore_report.skipped = true
    elseif store_err then
        restore_report.error = tostring(store_err)
        log:error("window storage unavailable", {error = tostring(store_err)})
    else
        local restored, failed = 0, {}
        for _, window in ipairs(stored or {}) do
            local ok, aerr = apps.apply(window)
            if ok then
                restored = restored + 1
            else
                failed[#failed + 1] = window.name .. ": " .. tostring(aerr)
                log:error("window did not come up", {window = window.name, error = tostring(aerr)})
            end
        end
        restore_report.restored = restored
        restore_report.failed = #failed
        restore_report.names = failed
        if restored > 0 or #failed > 0 then
            log:info("windows restored",
                {restored = restored, failed = #failed, names = table.concat(failed, ", ")})
        end
    end

    local out = assert(tty.surface({
        alternate_screen = true,
        hide_cursor = true,
        synchronized_output = true,
    }))

    -- Размера может не быть вовсе: запуск не из терминала (скрипт, CI,
    -- пайп) отвечает нулями, и холст такую ширину отвергает — процесс падал
    -- на первой же строке с «canvas width must be positive».
    local FALLBACK_W, FALLBACK_H = 80, 24
    local MIN_SCREEN_W, MIN_SCREEN_H = 8, 6

    local function screen_geometry()
        local w, h = tty.screen_size()
        w = math.floor(tonumber(w) or 0)
        h = math.floor(tonumber(h) or 0)
        if w < MIN_SCREEN_W then w = FALLBACK_W end
        if h < MIN_SCREEN_H then h = FALLBACK_H end
        return w, h
    end

    local width, height = screen_geometry()
    local canvas = tty.canvas(width, height)

    -- Вход — до первого кадра стола и до того, как композитор начнёт читать
    -- команды: окно, открытое каналом в этот момент, родилось бы без
    -- личности. Диалог рисует оболочка на этом же холсте; композитор держит
    -- размер экрана и показывает кадр — то же, что он делает для стола.
    if logon then
        local screen: any = {
            events = events, pixels = PIXELS,
            width = width, height = height, canvas = canvas,
        }
        function screen.cell() return cell_w, cell_h end
        function screen.resize()
            width, height = screen_geometry()
            canvas = tty.canvas(width, height)
            screen.width, screen.height, screen.canvas = width, height, canvas
            return width, height
        end
        function screen.present(painted: any)
            local images: any = nil
            if PIXELS and type(painted) == "table" then
                images = pixels.frame(canvas, painted)
            end
            return out:present(canvas:rows(), {images = images})
        end
        -- Упавший диалог — отказ входа с причиной, а не композитор, оставивший
        -- терминал в alternate screen без единого слова.
        local ok, identity, why = pcall(logon, screen)
        if not ok then identity, why = nil, "the logon dialog crashed: " .. tostring(identity) end
        if type(identity) ~= "table" or identity.actor == nil or identity.scope == nil then
            -- Отказ входа — это выход, а не стол под служебным актором: стол
            -- без пользователя выглядел бы как вошедший, а окна в нём
            -- работали бы от имени процесса.
            process.registry.unregister(SERVICE_NAME)
            assert(tty.mouse(false))
            assert(out:close())
            assert(tty.stop())
            return nil, type(why) == "string" and why or "logon failed"
        end
        IDENTITY = {actor = identity.actor, scope = identity.scope,
            context = type(identity.context) == "table" and identity.context or {}}
    end

    -- Первая и последняя строка, свободные под окна. Считаются по теме, а
    -- не по константе: у одной полоса окон сверху, у другой панель задач
    -- снизу.
    -- math.floor, а не литерал: линтер различает integer и number, а дальше
    -- эти границы уезжают в clamp, где ждут number.
    local desktop_top = math.floor(2)
    local desktop_last = math.floor(height - 1)

    local function apply_layout()
        local spec: any = chrome.layout(width, height)
        if type(spec) ~= "table" then spec = {} end
        local top = math.tointeger(tonumber(spec.top) or 1) or 1
        local bottom = math.tointeger(tonumber(spec.bottom) or 1) or 1
        if top < 0 then top = 0 end
        if bottom < 0 then bottom = 0 end
        -- Тема, попросившая больше экрана, чем есть, не должна ронять
        -- композитор: окна уехали бы за край молча.
        if top + bottom >= height then
            top = 0
            if bottom >= height then bottom = math.tointeger(height - 1) or 0 end
            if bottom < 0 then bottom = 0 end
        end
        desktop_top = top + 1
        desktop_last = height - bottom
        if desktop_last < desktop_top then desktop_last = desktop_top end
    end

    apply_layout()

    -- windows — z-порядок: последний рисуется поверх и держит фокус.
    local windows = {}
    local next_id = 0
    -- Перетаскивание: одна структура вместо «либо nil, либо таблица» —
    -- во второй форме поля смещения для проверяющего не существуют.
    local drag: any = {active = false, id = "", mode = "move", dx = 0, dy = 0}
    -- The frame gate (`draw` / `draw_now` / `flush`): when the last frame was
    -- painted, whether one is owed, how many requests it merges, and the
    -- timer that paints it. A table, not locals: the loop and the closures
    -- share it (the go-lua pcall trap).
    local frame_gate: any = {last_ms = 0, dirty = false, merged = 0, timer = nil}
    -- Set when a frame could not be written: the terminal is gone (a remote
    -- session disconnected). The loop then shuts the desktop down.
    local terminal_state: any = {lost = nil, cancelled = false}
    -- Меню открыто — весь ввод принадлежит ему, включая цифры: иначе выбор
    -- пункта уехал бы в окно под меню.
    local menu: any = nil
    -- Разметка попаданий, которую вернула тема при последней отрисовке. И
    -- рисование, и клик считаются по ней одной.
    local catalog: any
    local bar_hits: any = {}
    local desk_hits: any = {}
    -- Ярлыки стола держатся в состоянии, а не читаются на каждый кадр:
    -- кадр рисуется десятки раз в секунду, а раскладка меняется руками.
    local desk: any = {items = {}, failure = nil}
    -- Двойной щелчок: как в оболочке, откуда взят вид. Одиночный щелчок,
    -- запускающий программу, — ловушка: по значку кликают, чтобы выбрать.
    local last_click: any = {x = 0, y = 0, at = 0}
    -- Выделение живёт здесь, а не в раскладке: его меняет каждый щелчок, а
    -- раскладка — то, что переживает перезапуск.
    local selected_id: any = nil
    -- Причина последнего отказа. Показывается вместо статуса: у оболочки
    -- терминала нет ни лога, ни всплывающих окон, и рассказать иначе негде.
    local notice = ""
    -- Что стоил последний кадр. Отдаётся командным каналом, потому что цену
    -- нарезки хрома иначе не увидеть: неверно порезанный хром рисует
    -- ПРАВИЛЬНЫЙ экран, просто медленный, а у медленного нет ни стека, ни
    -- симптома — по ssh его не найти глазами.
    local frame_cost: any = {}
    -- Сколько кадр стоил ВРЕМЕНЕМ и что его разбудил. Байты и строки выше
    -- говорят, сколько ушло в терминал, но не где прошло время: в пересборке
    -- канвы темой или в `present`. `trigger` пишет цикл, читает `draw`;
    -- `samples` — кольцо последних FRAME_WINDOW кадров для avg/p95/max.
    -- Таблицей, а не локальными: выше по кадру стоит pcall входа, а после
    -- ошибки под pcall простая локальная у цикла и у замыкания расходится.
    local meter: any = {trigger = "start", snapshot_ms = nil, total = 0, next = 1, samples = {}}
    -- Which window was last told it has the keyboard. The composer keeps no
    -- focus field (focus is the top visible window, see `focused`), so a
    -- change is noticed by comparing after each frame. A table, like `meter`:
    -- the logon pcall sits above in this frame. `notify_focus` is assigned
    -- below `send_to`, which it needs; `draw` calls it through this name.
    local focus_seen: any = {id = nil}
    local notify_focus: any = nil
    local menu_hits: any = {}
    -- Таймер наведения в меню: есть только пока каскад ждёт своей смены,
    -- см. `hover_menu`. Объявлен здесь, потому что цикл кладёт его в select.
    local hover_timer: any = nil
    local clock = ""
    -- Пункты трея в порядке появления. Таблицей, а не локальным списком: см.
    -- `meter` — после ошибки под pcall присваивание локальной из замыкания
    -- владелец больше не видит.
    local tray: any = {items = {}}

    -- Что трей отдаёт теме и командному каналу. Теме — только то, что она
    -- рисует и во что превращает попадание; наружу — ещё владелец и остаток
    -- срока, без них «пункт висит» не объяснить.
    local function tray_view(detailed: boolean): any
        local out = {}
        local now = time.now():unix_nano()
        for _, item in ipairs(tray.items) do
            local view: any = {key = item.key, text = item.text, entry = item.entry, title = item.title,
                image = item.image, icon = item.icon}
            if detailed then
                view.owner = item.owner
                if item.expires ~= nil then
                    local left: integer = math.tointeger((tonumber(item.expires) or now) - now) or 0
                    view.expires_in = math.max(0, left // 1000000000)
                end
            end
            out[#out + 1] = view
        end
        return out
    end

    -- Пункт с истёкшим сроком снимается. Поставщик, переставший обновлять
    -- свой пункт, скорее всего остановился, а подпись, пережившая его,
    -- выдаёт старое значение за нынешнее — вид исправного трея, который врёт.
    -- Отвечает, изменился ли трей: перерисовка нужна только тогда.
    local function prune_tray(): boolean
        local now = time.now():unix_nano()
        local kept, changed = {}, false
        for _, item in ipairs(tray.items) do
            if item.expires ~= nil and item.expires <= now then changed = true
            else kept[#kept + 1] = item end
        end
        if changed then tray.items = kept end
        return changed
    end

    -- set_tray(body, from) -> принят, причина, изменился ли вид
    --
    -- Ключ выбирает поставщик: повторная команда с тем же ключом обновляет
    -- пункт, а не добавляет второй. Владельцем пункт не запирается нарочно:
    -- поставщик-сервис после перезапуска приходит с новым pid, и запертый
    -- пункт висел бы мёртвым до конца срока рядом с новым. Подменить чужую
    -- подпись может любой процесс, который и так может закрыть любое окно
    -- командой `desktop.close`; `entry` пункта открывает то же, что меню.
    local function set_tray(body: any, from: any): (boolean, any, boolean)
        local key = type(body.key) == "string" and body.key or ""
        if key == "" then return false, "the tray item has no key", false end
        if #key > TRAY_KEY then return false, "the tray item key is longer than " .. TRAY_KEY, false end
        local pruned = prune_tray()

        local index = 0
        for position, item in ipairs(tray.items) do
            if item.key == key then index = position end
        end
        if body.remove == true then
            if index == 0 then return true, nil, pruned end
            local kept = {}
            for position, item in ipairs(tray.items) do
                if position ~= index then kept[#kept + 1] = item end
            end
            tray.items = kept
            return true, nil, true
        end

        local text = type(body.text) == "string" and body.text or ""
        if text == "" then return false, "tray item " .. key .. " has no caption", pruned end
        if #runes(text) > TRAY_TEXT then
            return false, "the tray caption is longer than " .. TRAY_TEXT .. " characters", pruned
        end
        local entry = type(body.entry) == "string" and body.entry ~= "" and body.entry or nil
        local title = type(body.title) == "string" and body.title ~= "" and body.title or nil
        -- A picture beside the caption: `image` — a name from the theme's
        -- icon catalog (pixels), `icon` — one character for the cell theme.
        -- Both optional; the theme that has neither draws the caption alone.
        local image = type(body.image) == "string" and body.image ~= "" and body.image or nil
        if image ~= nil and #image > TRAY_KEY then
            return false, "the tray item image name is longer than " .. TRAY_KEY, pruned
        end
        local icon = type(body.icon) == "string" and body.icon ~= "" and body.icon or nil
        if icon ~= nil and #runes(icon) > 1 then
            return false, "the tray item icon is one character", pruned
        end
        local expires = nil
        if body.ttl ~= nil then
            local ttl: number = tonumber(body.ttl) or 0
            if ttl <= 0 then
                return false, "a tray item's ttl is a number of seconds above zero", pruned
            end
            expires = time.now():unix_nano() + math.floor(ttl * 1000000000)
        end
        if index == 0 and #tray.items >= TRAY_MAX then
            return false, "the tray already holds " .. TRAY_MAX .. " items", pruned
        end

        local item: any = {key = key, text = text, entry = entry, title = title,
            image = image, icon = icon,
            expires = expires, owner = from ~= nil and tostring(from) or nil}
        if index == 0 then
            tray.items[#tray.items + 1] = item
            return true, nil, true
        end
        local old = tray.items[index]
        tray.items[index] = item
        -- Продление срока без смены подписи кадра не стоит: поставщик
        -- обновляет пункт по таймеру, и каждое такое обновление иначе было бы
        -- полной перерисовкой панели.
        local changed = old.text ~= text or old.entry ~= entry or old.title ~= title
            or old.image ~= image or old.icon ~= icon
        return true, nil, changed or pruned
    end

    -- Running widgets in display order. A table, like `tray`: the logon pcall
    -- sits above in this frame, and `sync_widgets` replaces the list.
    local widgets: any = {items = {}, spawned = 0}

    -- What widgets give the theme and the command channel. The theme gets a
    -- view window's shape (`id`, `content_state`, `state_revision`) so the
    -- SDK renderer takes a widget as it is; the channel gets the status
    -- without the tree — the tree is what is drawn, not a status.
    local function widget_view(detailed: boolean): any
        local out = {}
        for _, item in ipairs(widgets.items) do
            local view: any = {id = item.id, entry = item.entry, title = item.title, opens = item.opens,
                w = item.w, h = item.h, waiting = item.waiting == true, stopped = item.stopped == true}
            if detailed then
                view.revision = item.state_revision
            else
                view.content_state = item.content_state
                view.state_revision = item.state_revision
            end
            out[#out + 1] = view
        end
        return out
    end

    local function widget_of(id: any): any
        for _, item in ipairs(widgets.items) do
            if item.id == id then return item end
        end
        return nil
    end

    -- A widget whose process ended — its exit, or its runner's own close: the
    -- last tree stays, `stopped` says so, the status line names the entry, and
    -- `desktop.refresh` spawns it again. One place for both, so the two ways
    -- a widget stops cannot leave two different states.
    local function stop_widget(item: any)
        item.pid, item.stopped = nil, true
        notice = "widget " .. tostring(item.entry) .. " stopped"
        log:warn("widget stopped", {widget = item.id, entry = tostring(item.entry)})
    end

    -- A size in whole cells within the limits, the default when not given,
    -- nil when refused. 12.5 and "20" are refused, not rounded or parsed.
    local function whole_cells(value: any, default: integer, low: integer, high: integer): integer?
        if value == nil then return default end
        if type(value) ~= "number" then return nil end
        local cells = math.tointeger(value)
        if cells == nil or cells < low or cells > high then return nil end
        return cells
    end

    -- A widget's size and the cell size reach its process as the resize event
    -- a state provider of a view window gets.
    local function tell_widget_size(item: any)
        if item.pid == nil then return end
        process.send(tostring(item.pid), "window.input", {id = item.id, event = {
            type = "resize", width = item.w, height = item.h, cell_w = cell_w, cell_h = cell_h,
        }})
    end

    -- Spawned exactly like the state provider of a view window: under the
    -- logged-on user, with the compositor's name in the context, the widget id
    -- where a window id goes and the size as the fourth argument. Answers the
    -- reason when the spawn failed.
    local function spawn_widget(item: any): string?
        local pid, err = spawner(nil, {[window_api.CONTEXT_KEY] = SERVICE_NAME})
            :spawn_monitored(tostring(item.entry), WINDOW_HOST, SERVICE_NAME, tostring(item.id), nil, {
                width = item.w, height = item.h, cell_w = cell_w, cell_h = cell_h,
            })
        if not pid then
            item.pid, item.stopped = nil, true
            return "widget " .. tostring(item.entry) .. " did not start: " .. tostring(err)
        end
        item.pid, item.stopped = pid, false
        -- A respawned widget keeps its last tree until the new process
        -- publishes: waiting means "never had a state", not "restarting".
        item.waiting = item.content_state == nil
        return nil
    end

    -- sync_widgets() — bring the running widgets in line with the shell's
    -- list (FR-006 §3): spawn new entries, respawn stopped ones, stop and
    -- forget those that vanished. Called after logon, so that every spawn
    -- carries the user's actor, and on `desktop.refresh`.
    --
    -- A size outside the limits is refused, not clamped; the reason names the
    -- entry in the status line, the one place a person sees it.
    local function sync_widgets()
        if not read_widgets then return end
        local listed, failure = read_widgets()
        local problems = {}
        if failure ~= nil then problems[#problems + 1] = "widgets: " .. tostring(failure) end
        if type(listed) ~= "table" then
            -- No list is not an empty list: stopping every widget because the
            -- shell could not read the registry would blank the desktop over a
            -- hiccup.
            if #problems > 0 then notice = table.concat(problems, "; ") end
            return
        end

        local wanted, seen = {}, {}
        for _, spec in ipairs(listed) do
            local entry: any = type(spec) == "table" and spec.entry or nil
            if type(entry) ~= "string" or entry == "" then
                problems[#problems + 1] = "a widget without an entry was not shown"
            elseif not seen[entry] then
                seen[entry] = true
                local w = whole_cells(spec.w, WIDGET_W, WIDGET_MIN_W, WIDGET_MAX_W)
                local h = whole_cells(spec.h, WIDGET_H, WIDGET_MIN_H, WIDGET_MAX_H)
                if w == nil then
                    problems[#problems + 1] = "widget " .. entry .. ": width " .. tostring(spec.w)
                        .. " is not a whole number of cells from " .. WIDGET_MIN_W .. " to " .. WIDGET_MAX_W
                elseif h == nil then
                    problems[#problems + 1] = "widget " .. entry .. ": height " .. tostring(spec.h)
                        .. " is not a whole number of cells from " .. WIDGET_MIN_H .. " to " .. WIDGET_MAX_H
                else
                    wanted[#wanted + 1] = {entry = entry, w = w, h = h,
                        order = tonumber(spec.order) or WIDGET_ORDER,
                        title = type(spec.title) == "string" and spec.title ~= "" and spec.title or nil,
                        opens = type(spec.opens) == "string" and spec.opens ~= "" and spec.opens or nil}
                end
            end
        end
        table.sort(wanted, function(left: any, right: any)
            if left.order ~= right.order then return left.order < right.order end
            return left.entry < right.entry
        end)

        local running: any = {}
        for _, item in ipairs(widgets.items) do running[item.entry] = item end
        local kept = {}
        for _, spec in ipairs(wanted) do
            local item: any = running[spec.entry]
            running[spec.entry] = nil
            if item == nil then
                widgets.spawned = widgets.spawned + 1
                item = {id = "g" .. widgets.spawned, entry = spec.entry, pid = nil,
                    waiting = true, stopped = false, content_state = nil, state_revision = 0}
            end
            local resized = item.w ~= nil and (item.w ~= spec.w or item.h ~= spec.h)
            item.w, item.h, item.order = spec.w, spec.h, spec.order
            item.title, item.opens = spec.title, spec.opens
            if item.pid == nil then
                local why = spawn_widget(item)
                if why then problems[#problems + 1] = why end
            elseif resized then
                tell_widget_size(item)
            end
            kept[#kept + 1] = item
        end
        -- Vanished from the registry: stopped and forgotten. Its exit, when it
        -- arrives, finds nobody to mark stopped.
        for _, gone in pairs(running) do
            if gone.pid ~= nil then process.terminate(tostring(gone.pid)) end
        end
        widgets.items = kept

        for _, problem in ipairs(problems) do log:warn("widget not shown", {reason = problem}) end
        if #problems > 0 then notice = table.concat(problems, "; ") end
    end

    local quitting = false
    -- Экран прощания просят только через «Завершение работы» в меню: ctrl+q
    -- — аварийный выход, ему пять секунд чёрного экрана ни к чему.
    local farewell_wanted = false

    local function desktop_height() return math.max(1, desktop_last - desktop_top + 1) end

    local function index_of(id)
        for index, window in ipairs(windows) do
            if window.id == id then return index end
        end
        return 0
    end

    local function find(id)
        local index = index_of(id)
        if index == 0 then return nil end
        return windows[index]
    end

    -- Фокус — верхнее развёрнутое окно. Отдельного поля нет нарочно: два
    -- источника истины про фокус разъезжаются на первом же закрытии.
    local function focused()
        for index = #windows, 1, -1 do
            if not windows[index].minimized and not windows[index].closing then
                return windows[index]
            end
        end
        return nil
    end

    -- Окно, которому принадлежит этот процесс. Родителя диалога композитор
    -- определяет по ОТПРАВИТЕЛЮ, а не по номеру в запросе: своего номера окно
    -- не знает, а присланный в поле чужой номер ничем не проверить — и связь
    -- можно было бы объявить о любом окне на столе.
    local function window_of(from: any)
        if from == nil then return nil end
        local key = tostring(from)
        for _, window in ipairs(windows) do
            if tostring(window.pid) == key or tostring(window.state_pid) == key then return window end
        end
        return nil
    end

    -- Диалог и служебное окно живут ПРИ своём окне: закрываются вместе с ним
    -- и держатся поверх него. Обычная программа, открытая из другого окна, —
    -- просто программа: уходить ей следом незачем, и «Мой компьютер», открывший
    -- просмотрщик, не должен уносить его с собой.
    local function follows_parent(window: any)
        local kind: any = window and window.window_type or nil
        return kind == "dialog" or kind == "tool"
    end

    local function children_of(id)
        local out = {}
        for _, window in ipairs(windows) do
            if window.opened_by == id and follows_parent(window) then
                out[#out + 1] = window
            end
        end
        return out
    end

    local function raise(window)
        local index = index_of(window.id)
        if index ~= 0 and index ~= #windows then
            table.remove(windows, index)
            windows[#windows + 1] = window
        end
        -- Диалог держится поверх своего окна. Уехав под него, он выглядит
        -- пропавшим — а достать его нечем: модальности здесь нет намеренно,
        -- ввод остальных окон не блокируется.
        for _, child in ipairs(children_of(window.id)) do raise(child) end
    end

    -- Объявлено заранее: укладка считает сетку значков, а сетка известна
    -- ниже. Забыть вызвать её после перечитывания нельзя — тогда значок без
    -- координат не нарисуется вовсе.
    local arrange_desktop: any

    -- Раскладка перечитывается по команде, а не по таймеру: её меняют
    -- ручки оболочки, и они же говорят композитору, что пора обновиться.
    local function reload_desktop()
        if not read_desktop then
            desk = {items = {}, failure = nil}
            return
        end
        local items, failure = read_desktop()
        desk = {
            items = type(items) == "table" and items or {},
            failure = failure and tostring(failure) or nil,
        }
        arrange_desktop()
    end

    -- Шаг сетки значков объявляет тема: она рисует значок и знает, сколько
    -- он занимает. Композитор только выравнивает по нему брошенный значок —
    -- иначе значок встаёт между шагами и перекрывается попаданием соседа.
    local function icon_grid()
        local grid: any = nil
        if type(chrome.icon_grid) == "function" then grid = chrome.icon_grid() end
        if type(grid) ~= "table" then
            grid = {w = chrome.ICON_W, h = chrome.ICON_H, left = chrome.ICON_LEFT}
        end
        local gw = math.tointeger(tonumber(grid.w) or 12) or 12
        local gh = math.tointeger(tonumber(grid.h) or 4) or 4
        local gl = math.tointeger(tonumber(grid.left) or 1) or 1
        if gw < 1 then gw = 1 end
        if gh < 1 then gh = 1 end
        if gl < 1 then gl = 1 end
        return gw, gh, gl
    end

    local function snap(value: any, step: any, base: any)
        local origin = math.tointeger(tonumber(base) or 1) or 1
        local size = math.tointeger(tonumber(step) or 1) or 1
        if size < 1 then size = 1 end
        local point = math.tointeger(tonumber(value) or origin) or origin
        local offset = point - origin
        if offset < 0 then offset = 0 end
        local cell = math.tointeger((offset + size // 2) // size) or 0
        return origin + cell * size
    end

    -- Значок без координат ставит композитор: ширину экрана знает только
    -- он, а раскладку оболочка составляет раньше, чем терминал сообщил
    -- размер. Вычисленное место НЕ записывается обратно — иначе первый же
    -- кадр превратил бы автопосаженный значок в поставленный руками, и
    -- человек потерял бы разницу, ради которой это сделано.
    --
    -- Мест не хватило — значок ложится в последнюю ячейку поверх соседа.
    -- Значки внахлёст видно и можно растащить; пропавший за краем читается
    -- как «я его случайно удалил».
    arrange_desktop = function()
        local gw, gh, gl = icon_grid()

        local rows = math.tointeger((desktop_last - desktop_top + 1) // gh) or 1
        if rows < 1 then rows = 1 end
        local columns = math.tointeger((width - gl + 1) // gw) or 1
        if columns < 1 then columns = 1 end

        local taken: any = {}
        for _, item in ipairs(desk.items) do
            if not item.auto and tonumber(item.x) and tonumber(item.y) then
                taken[tostring(item.x) .. ":" .. tostring(item.y)] = true
            end
        end

        local slot = 0
        for _, item in ipairs(desk.items) do
            if item.auto or tonumber(item.x) == nil or tonumber(item.y) == nil then
                local x, y = gl, desktop_top
                local steps = 0
                while steps <= columns * rows do
                    local column = math.tointeger(slot // rows) or 0
                    local row = math.tointeger(slot % rows) or 0
                    if column >= columns then break end
                    x = gl + column * gw
                    y = desktop_top + row * gh
                    slot = slot + 1
                    steps = steps + 1
                    if not taken[tostring(x) .. ":" .. tostring(y)] then break end
                end
                item.x, item.y = x, y
                item.auto = true
                taken[tostring(x) .. ":" .. tostring(y)] = true
            end
        end
    end

    local function desktop_item(id)
        for _, item in ipairs(desk.items) do
            if item.id == id then return item end
        end
        return nil
    end

    local function desktop_spot(x, y)
        for _, spot in ipairs(desk_hits) do
            if y == spot.row and x >= spot.from and x <= spot.to then return spot end
        end
        return nil
    end

    -- Содержимое окна в пиксельном режиме кладёт КОМПОЗИТОР.
    --
    -- В режиме символов строки окна кладёт тема — она же рисует вокруг них
    -- рамку одним куском. Растровая тема рамку рисует картинками и в канву не
    -- пишет вовсе; строки при этом остаются символами (bash умеет только их),
    -- и положить их больше некому.
    local function put_content(window)
        if type(window.rows) ~= "table" or #window.rows == 0 then return end
        local left = math.tointeger(insets.left) or 1
        local top_inset = math.tointeger(insets.top) or 1
        local x = (math.tointeger(window.x) or 1) + left
        local y = (math.tointeger(window.y) or 1) + top_inset
        local span = (math.tointeger(window.w) or 0) - FRAME_W
        local room = (math.tointeger(window.h) or 0) - FRAME_H
        if span < 1 or room < 1 then return end

        -- Лишние строки режутся здесь, как и в теме символов: в момент смены
        -- размера приезжает кадр прежней геометрии, и лишняя строка легла бы
        -- ниже окна — на экране это читается как сломанная рамка, а не как
        -- отставший кадр.
        local rows: any = window.rows
        if #rows > room then
            local cut = {}
            for index = 1, room do cut[index] = rows[index] end
            rows = cut
        end
        if type(chrome.content_colors) == "function" then
            local defaults: any = chrome.content_colors(window)
            if type(defaults) == "table" then
                canvas:put_rows(x, y, rows :: {string}, span, {
                    foreground = type(defaults.foreground) == "string" and tostring(defaults.foreground) or nil,
                    background = type(defaults.background) == "string" and tostring(defaults.background) or nil,
                })
                return
            end
        end
        canvas:put_rows(x, y, rows :: {string}, span)
    end

    local function round_ms(value)
        return math.floor(value * 1000 + 0.5) / 1000
    end

    local function record_frame(cost: any, at)
        meter.total = meter.total + 1
        meter.samples[meter.next] = {
            paint = cost.paint_ms, present = cost.present_ms, total = cost.total_ms,
            bytes = tonumber(cost.bytes_written) or 0, trigger = cost.trigger, at = at,
            seq = meter.total,
        }
        meter.next = meter.next % FRAME_WINDOW + 1
    end

    -- Цена кадров для статуса: последний кадр как был, плюс сводка по кольцу.
    -- Перцентиль считается здесь, по запросу: кадров под потоком вывода —
    -- десятки в секунду, а статус спрашивают раз в несколько секунд.
    local function frame_report(with_samples)
        local report: any = {}
        for key, value in pairs(frame_cost) do report[key] = value end
        report.frames_total = meter.total
        local samples: any = meter.samples
        local count = #samples
        if with_samples then
            -- Сырые кадры, от старого к новому. Замер по фазам склеивает их по
            -- `seq` из соседних снимков: сводка кольца на конце короткой фазы
            -- смешала бы её с кадрами предыдущей.
            local raw = {}
            for offset = 0, count - 1 do
                local sample = samples[(meter.next - 1 + offset) % count + 1]
                raw[#raw + 1] = {
                    seq = sample.seq, at_ms = math.floor(sample.at / 1000000),
                    paint_ms = sample.paint, present_ms = sample.present,
                    total_ms = sample.total, bytes = sample.bytes, trigger = sample.trigger,
                }
            end
            report.samples = raw
        end
        if count == 0 then return report end

        local function part(field)
            local values = {}
            local sum, max, max_trigger = 0, -1, nil
            for _, sample in ipairs(samples) do
                local value = tonumber(sample[field]) or 0
                values[#values + 1] = value
                sum = sum + value
                if value > max then max, max_trigger = value, sample.trigger end
            end
            table.sort(values)
            local rank = math.tointeger(math.max(1, math.ceil(#values * 0.95))) or 1
            return {avg_ms = round_ms(sum / #values), p95_ms = round_ms(values[rank]),
                max_ms = round_ms(max), max_trigger = max_trigger}
        end

        local oldest, newest = nil, nil
        local bytes_sum, bytes_max = 0, 0
        local triggers: any = {}
        for _, sample in ipairs(samples) do
            if oldest == nil or sample.at < oldest then oldest = sample.at end
            if newest == nil or sample.at > newest then newest = sample.at end
            bytes_sum = bytes_sum + sample.bytes
            if sample.bytes > bytes_max then bytes_max = sample.bytes end
            -- По виду, без окна: «pty:w3» и «pty:w4» — один вопрос.
            local kind = tostring(sample.trigger):match("^[^:]+") or "?"
            triggers[kind] = (triggers[kind] or 0) + 1
        end
        report.window = {
            frames = count,
            span_s = round_ms(((newest or 0) - (oldest or 0)) / 1000000000),
            paint = part("paint"), present = part("present"), total = part("total"),
            bytes_avg = math.floor(bytes_sum / count + 0.5), bytes_max = bytes_max,
            triggers = triggers,
        }
        return report
    end

    -- The rect a move or resize drag would give. Windows 95 drags an OUTLINE:
    -- the window keeps its place and size until the release, and only the
    -- outline follows the pointer — a frame per motion then costs a dotted
    -- rectangle, not the whole window re-laid and re-sent at a new size.
    local function drag_outline(): any
        if drag.active and drag.mode ~= "icon" and drag.pending ~= nil then return drag.pending end
        return nil
    end

    -- The outline in cells for a theme without `chrome.outline`: a dotted frame.
    local function default_outline(target: any, rect: any)
        local x, y = math.tointeger(rect.x) or 1, math.tointeger(rect.y) or 1
        local w, h = math.tointeger(rect.w) or 0, math.tointeger(rect.h) or 0
        if w < 2 or h < 2 then return end
        target:put(x, y, string.rep("┄", w), w)
        target:put(x, y + h - 1, string.rep("┄", w), w)
        for row = y + 1, y + h - 2 do
            target:put(x, row, "┆", 1)
            target:put(x + w - 1, row, "┆", 1)
        end
    end

    -- draw_now() paints a frame at once; `draw()` (below) is how everything
    -- asks for one.
    local function draw_now()
        local started = time.now():unix_nano()
        canvas:clear(" ")

        local top = focused()
        -- Считается до ветвления по `top`: после if/else линтер держит его
        -- сужённым и поле `id` для него уже не существует.
        local focused_id = top and top.id or nil
        -- One list for both modes and every call of the frame: `fill` and
        -- `paint` must see the same widgets in the same order.
        local widget_list: any = widget_view(false)

        desk_hits = {}
        if not PIXELS then
            -- Фон рисует и значки стола, если тема умеет: композитор отдаёт ей
            -- раскладку и границы свободного места, а обратно берёт разметку
            -- попаданий — по ней же считается щелчок.
            local painted = chrome.fill(canvas, width, height, {
                top = desktop_top,
                bottom = desktop_last,
                items = desk.items,
                failure = desk.failure,
                selected = selected_id,
                widgets = widget_list,
            })
            if type(painted) == "table" then desk_hits = painted end

            if #windows == 0 then
                chrome.empty_desktop(canvas, width, height, HINT)
            end

            for _, window in ipairs(windows) do
                if not window.minimized then
                    chrome.window(canvas, window, top ~= nil and window.id == top.id)
                end
            end
        else
            -- Фон и стол заливаются ЯЧЕЙКАМИ и в этом режиме тоже. Без этого
            -- тело окна просвечивает столом там, где программа внутри ничего
            -- не написала: в режиме символов фон закрашивал `chrome.window`, а
            -- растровая тема в канву не пишет вовсе. И сам стол держался бы не
            -- на своём цвете, а на цвете терминала.
            if type(chrome.fill) == "function" then
                local filled = chrome.fill(canvas, width, height, {
                    top = desktop_top,
                    bottom = desktop_last,
                    items = desk.items,
                    failure = desk.failure,
                    selected = selected_id,
                    widgets = widget_list,
                })
                if type(filled) == "table" then desk_hits = filled end
            end

            for _, window in ipairs(windows) do
                if not window.minimized then
                    if type(chrome.window_background) == "function" then
                        chrome.window_background(canvas, window)
                    end
                    put_content(window)
                end
            end
        end

        -- The taskbar carries only notices — an open that failed, a theme that
        -- returned a bad frame. Windows 95 has no key hint there (owner's rule,
        -- 2026-09-11); the keys are explained on the empty desktop (`hint`).
        -- `status` stays for older themes and carries the same text.
        local status = notice

        -- Состояние для растровой темы — объединение того, что в режиме
        -- символов приезжает тремя вызовами. Имена полей те же нарочно: тема,
        -- умеющая оба режима, узнаёт их без перевода.
        local images: any = nil
        if PIXELS then
            local painted = chrome.paint({
                width = width, height = height,
                top = desktop_top, bottom = desktop_last,
                windows = windows, focused_id = focused_id,
                items = desk.items, failure = desk.failure, selected = selected_id,
                menu = menu and {items = menu.items, failure = menu.failure,
                    open = menu.open, cursor = menu.cursor, anchor = menu.anchor} or nil,
                status = status, notice = notice, clock = clock, tray = tray_view(false), hint = HINT,
                widgets = widget_list,
                -- A move or resize drag's pending rect: the theme draws its
                -- outline over everything (a theme that does not know the
                -- field shows nothing until the release).
                outline = drag_outline(),
            }, cell_w, cell_h)

            local complaints
            -- Пробелы под картинками кладёт `frame`, и делает это ПОСЛЕ
            -- содержимого: иначе строка окна вылезла бы из-под чужой рамки.
            images, complaints = pixels.frame(canvas, painted)
            local hits, quarrel = pixels.hits(painted)
            bar_hits, menu_hits = hits.bars, hits.menu
            -- Значки стола рисует `paint`, поэтому его разметка старше. Но
            -- если он её не вернул, остаётся та, что вернула заливка: молча
            -- потерянные щелчки по столу выглядят как мёртвые значки.
            if #hits.desktop > 0 then desk_hits = hits.desktop end
            if quarrel then complaints[#complaints + 1] = quarrel end
            for _, complaint in ipairs(complaints) do
                log:warn("the theme returned a bad frame", {reason = complaint})
            end
            -- И в строку состояния тоже. Лог терминального хоста заглушён —
            -- иначе он разъедет кадр, — а значит жалоба, рассказанная только
            -- ему, не рассказана никому: на стенде это выглядит как «мышь не
            -- работает», а не как «тема отдала попадания не в той форме».
            if #complaints > 0 then notice = tostring(complaints[1]) end
        else
            bar_hits = chrome.bars(canvas, width, height, {
                windows = windows,
                focused_id = focused_id,
                -- «Пуск» нажат, пока открыт его каскад; контекстное меню
                -- значка (с якорем) — не его.
                menu_open = menu ~= nil and menu.anchor == nil,
                status = status,
                notice = notice,
                clock = clock,
                -- Трей стоит у часов. Тема без него его просто не рисует:
                -- поле необязательное, как и сами часы.
                tray = tray_view(false),
            })
            if type(bar_hits) ~= "table" then bar_hits = {} end

            menu_hits = {}
            if menu then
                -- Курсор отдаётся теме, а не считается ею: она помечает
                -- выбранную строку в разметке, и та же разметка возвращается
                -- сюда. Так «что выбрано» существует в одном месте — в том,
                -- что нарисовано.
                local hits = chrome.menu(canvas, width, height, menu.items, menu.failure,
                    menu.open, menu.cursor, menu.anchor)
                if type(hits) == "table" then menu_hits = hits end
            end

            local outline = drag_outline()
            if outline then
                if type(chrome.outline) == "function" then chrome.outline(canvas, outline)
                else default_outline(canvas, outline) end
            end
        end

        -- Аппаратный курсор один на экран, поэтому его получает только
        -- фокусное окно — и со смещением на свою рамку, иначе он встанет
        -- строкой выше собственного текста.
        local cursor = nil
        if top and top.cursor then
            cursor = {
                x = clamp(top.x + (math.tointeger(insets.left) or 1) - 1 + top.cursor.x, 1, width),
                y = clamp(top.y + (math.tointeger(insets.top) or 1) - 1 + top.cursor.y, 1, height),
                visible = top.cursor.visible,
            }
        end

        -- A terminal that is gone fails the write. That is not a crash:
        -- nothing can be shown any more, so the loop shuts the desktop down
        -- as "Shut Down" does, and the windows are closed rather than left
        -- behind with nobody to see them.
        if terminal_state.lost then return end
        local painted_at = time.now():unix_nano()
        local stats, present_error = out:present(canvas:rows(), {cursor = cursor, images = images})
        if not stats then
            terminal_state.lost = tostring(present_error)
            frame_gate.dirty, frame_gate.merged = false, 0
            return
        end
        local presented_at = time.now():unix_nano()
        frame_cost = {
            changed_rows = stats.changed_rows,
            bytes_written = stats.bytes_written,
            -- Сколько растров ушло на самом деле, в отличие от того, сколько
            -- кадр объявил. Рантайм, который этого не считает, оставит поле
            -- пустым — и «не измеряли» не притворится нулём.
            placements_sent = stats.placements_sent,
            images = images and #images or 0,
            -- paint — канва и тема (fill/window/bars/menu или paint+frame),
            -- present — диффер поверхности и кодирование растров.
            paint_ms = round_ms((painted_at - started) / 1000000),
            present_ms = round_ms((presented_at - painted_at) / 1000000),
            total_ms = round_ms((presented_at - started) / 1000000),
            trigger = meter.trigger,
            -- Только у кадра окна: снимок его viewport до `draw`.
            snapshot_ms = meter.snapshot_ms,
        }
        record_frame(frame_cost, presented_at)
        frame_gate.last_ms = presented_at // 1000000
        frame_gate.dirty, frame_gate.merged = false, 0
        if notify_focus then notify_focus() end
    end

    -- draw() — asks for a frame. The first request after FRAME_MS of quiet is
    -- painted at once, so a single click or key shows at once; the requests
    -- inside the gap only mark the frame owed, and the frame timer (in the
    -- loop's select) paints them as ONE frame: a drag's motions, a progress
    -- bar's lines and several windows' states cost a frame per FRAME_MS.
    local function draw()
        local now = time.now():unix_nano() // 1000000
        if frame_gate.timer == nil and now - frame_gate.last_ms >= FRAME_MS then
            draw_now()
            return
        end
        frame_gate.dirty = true
        frame_gate.merged = frame_gate.merged + 1
        if frame_gate.timer == nil then
            local wait = math.tointeger(math.max(1, FRAME_MS - (now - frame_gate.last_ms))) or 1
            frame_gate.timer = time.after(string.format("%dms", wait))
        end
    end

    -- flush() — an owed frame is painted now. What reads the frame — a
    -- press or a key (the hits), the `screen` command — must see the last
    -- state, not the one before the batch.
    local function flush()
        if not frame_gate.dirty then return end
        -- The frame is the owed batch's, and the report says so; the event
        -- being handled keeps its own name for the frame it may draw next.
        local was = meter.trigger
        meter.trigger = "batch:" .. tostring(frame_gate.merged)
        draw_now()
        meter.trigger = was
    end

    -- open_window(spec, from) — `from` это отправитель команды. Если он
    -- оказался одним из окон, открытое запоминает, кем открыто.
    local function open_window(spec, from: any)
        spec = type(spec) == "table" and spec or {}

        local entry = type(spec.entry) == "string" and spec.entry ~= "" and spec.entry or PTY_WINDOW

        local opener = window_of(from)

        -- Тип нужен раньше геометрии: диалог встаёт не там, где обычное окно.
        local record: any = registry.get(entry)
        local declared: any = nil
        local window_type = programs.DEFAULT_TYPE
        if record then
            local unknown
            declared, unknown = programs.item(record)
            if declared then window_type = declared.window_type end
            if unknown then
                log:warn("unknown window type", {
                    entry = entry, window_type = unknown, used = programs.DEFAULT_TYPE,
                })
            end
        end
        if type(spec.window_type) == "string" and programs.TYPES[spec.window_type] then
            window_type = spec.window_type
        end

        -- An entry may name the action a person needs to open it
        -- (`meta.requires`). A window whose own policy grants what the person
        -- lacks — a shell on the server — must not open for everyone who logs
        -- on. The question goes to the logged-on identity's scope; a desktop
        -- without logon runs under its own actor and asks nobody, as before.
        local requires: any = record and type(record.meta) == "table" and record.meta.requires or nil
        if type(requires) == "string" and requires ~= "" and IDENTITY ~= nil then
            local verdict = IDENTITY.scope:evaluate(IDENTITY.actor, requires, entry)
            if verdict ~= "allow" then
                local context: any = type(IDENTITY.context) == "table" and IDENTITY.context or {}
                local who = context.user_name or context.user_id or "the logged-on user"
                return nil, tostring(who) .. " may not open " .. entry .. " (it needs " .. requires .. ")"
            end
        end

        -- Размер: у окна с фиксированным размером — ТОЛЬКО из записи, что бы
        -- ни просил открывающий; иначе часы, открытые с панели задач без
        -- размера, встали бы во весь стол с диалогом в углу. У остальных —
        -- просьба открывающего, потом запись, потом умолчание композитора.
        local declared_w = declared and tonumber(declared.w) or nil
        local declared_h = declared and tonumber(declared.h) or nil
        local fixed = declared ~= nil and declared.resizable == false
        local w = clamp((fixed and declared_w) or spec.w or declared_w or math.floor(width * 0.6), MIN_W, width)
        local h = clamp((fixed and declared_h) or spec.h or declared_h or math.floor(desktop_height() * 0.7),
            MIN_H, desktop_height())
        -- Каскад, чтобы новое окно не легло ровно на предыдущее и не
        -- выглядело как отсутствие результата.
        local step = (#windows % 6) * 2
        local x = clamp(spec.x or (2 + step), 1, math.max(1, width - w + 1))
        local y = clamp(spec.y or (desktop_top + step), desktop_top, math.max(desktop_top, height - h))

        -- Диалог своего окна встаёт по его центру, а не в общий каскад: искать
        -- глазами по всему столу окно, которое открыл сам, — работа, которой
        -- не должно быть. Явные координаты сильнее: их назвал тот, кто просил.
        if opener and spec.x == nil and spec.y == nil
            and (window_type == "dialog" or window_type == "tool") then
            local ox = math.tointeger(opener.x) or 1
            local oy = math.tointeger(opener.y) or desktop_top
            local ow = math.tointeger(opener.w) or w
            local oh = math.tointeger(opener.h) or h
            x = clamp(ox + (ow - w) // 2, 1, math.max(1, width - w + 1))
            y = clamp(oy + (oh - h) // 2, desktop_top, math.max(desktop_top, height - h))
        end

        -- Окно-вид: процесса внутри нет вовсе. Рисует его тема, зовя чистую
        -- библиотеку `render`; данные добывает отдельный процесс-поставщик со
        -- своим узким актором. Композитор ни того, ни другого не исполняет —
        -- он несёт состояние от поставщика к теме.
        local content = declared and declared.content or programs.DEFAULT_CONTENT
        local render_ref = declared and declared.render or nil
        local state_ref = declared and declared.state or nil
        if PIXELS and declared and declared.pixel_render
            and type(chrome.renders) == "function" and chrome.renders(declared.pixel_render) then
            content, render_ref, state_ref = "pixels", declared.pixel_render, declared.pixel_state
        end
        if content == "pixels" then
            if not render_ref then
                return nil, "window " .. entry .. " declared its content as a view "
                    .. "but named no render — nothing to draw it with"
            end
            if not registry.get(render_ref) then
                return nil, "window " .. entry .. ": entry " .. render_ref .. " does not exist — "
                    .. "a dead render reference stays silent until the first open"
            end

            if state_ref and not registry.get(state_ref) then
                return nil, "window " .. entry .. ": entry " .. state_ref .. " does not exist — "
                    .. "the state provider is declared but missing"
            end

            next_id = next_id + 1
            local view_window: any = {
                id = "w" .. next_id,
                entry = entry,
                window_type = window_type,
                opened_by = opener and opener.id or nil,
                title = type(spec.title) == "string" and spec.title ~= "" and spec.title
                    or (declared and declared.title or entry),
                content = content,
                render = render_ref,
                image = spec.image or (declared and declared.image),
                state_ref = state_ref,
                resizable = declared == nil or declared.resizable ~= false,
                -- Состояния ещё нет: вид рисуется пустым и ГОВОРИТ, что ждёт,
                -- а не показывает вчерашнее и не висит.
                waiting = state_ref ~= nil,
                state_revision = 0,
                -- As for a process window: `desktop.list` reports it.
                args = type(spec.args) == "string" and spec.args ~= "" and spec.args or nil,
                x = x, y = y, w = w, h = h,
                view = nil, updates = nil, pid = nil,
                rows = {}, cursor = nil, revision = -1,
                ready = false, minimized = false, maximized = false,
                closing = false, deadline = nil,
                saved = {x = x, y = y, w = w, h = h},
            }

            if state_ref then
                -- Поставщик получает имя композитора и номер окна: обратно он
                -- шлёт состояние сам, когда оно изменилось. Спрашивать его на
                -- каждый кадр значило бы читать реестр шестьдесят раз в
                -- секунду ради списка, который меняется раз в час, — и ждать
                -- чужой процесс, пока стоит весь стол.
                -- Args retain their position; geometry is a separate fourth argument.
                local state_pid, serr = spawner(nil, {[window_api.CONTEXT_KEY] = SERVICE_NAME})
                    :spawn_monitored(tostring(state_ref), WINDOW_HOST, SERVICE_NAME, tostring(view_window.id),
                        type(spec.args) == "string" and spec.args ~= "" and spec.args or nil, {
                            width = w - FRAME_W, height = h - FRAME_H,
                            cell_w = cell_w, cell_h = cell_h,
                        })
                if not state_pid then
                    return nil, "the state provider did not start: " .. tostring(serr)
                end
                view_window.state_pid = state_pid
                view_window.ready = true
            end

            windows[#windows + 1] = view_window
            return view_window, nil
        end

        local view, verr = tty.viewport({width = w - FRAME_W, height = h - FRAME_H})
        if not view then return nil, tostring(verr) end

        local updates, uerr = view:updates()
        if not updates then return nil, tostring(uerr) end

        local grant, gerr = view:grant()
        if not grant then return nil, tostring(gerr) end

        local command = type(spec.command) == "string" and spec.command ~= ""
            and spec.command or DEFAULT_COMMAND

        -- Окно-приложение получает свой параметр (`args`), окно с программой —
        -- команду. Одно поле на оба смысла читалось бы как «команда», и окно
        -- подробностей открывали бы строкой «/bin/bash».
        local argument = type(spec.args) == "string" and spec.args ~= ""
            and spec.args or (entry == PTY_WINDOW and command or nil)

        -- Имя композитора едет окну в контексте процесса: под второй
        -- оболочкой десктоп зарегистрирован своим именем, и окно, знающее
        -- только константу, обращалось бы к чужому процессу — молча, потому
        -- что `desktop.open` ответа не ждёт.
        local pid, perr = spawner(process.with_options({terminal = grant}), {[window_api.CONTEXT_KEY] = SERVICE_NAME})
            :spawn_monitored(entry, WINDOW_HOST, argument)
        if not pid then
            view:close()
            return nil, tostring(perr)
        end

        next_id = next_id + 1
        local window = {
            id = "w" .. next_id,
            entry = entry,
            -- Тема выбирает по нему состав кнопок заголовка; композитор
            -- только несёт его от записи до темы.
            window_type = window_type,
            -- Кем открыто. Для диалога и служебного окна это его окно —
            -- отсюда и общий z, и общее закрытие. Для обычной программы это
            -- просто след: кто её запустил.
            opened_by = opener and opener.id or nil,
            content = content,
            image = spec.image or (declared and declared.image),
            -- Запись сказала «размер фиксирован» — окно не тянется за угол и
            -- не разворачивается; тема по этому же полю убирает кнопку.
            resizable = declared == nil or declared.resizable ~= false,
            title = type(spec.title) == "string" and spec.title ~= "" and spec.title
                or (entry == PTY_WINDOW and command or (declared and declared.title or entry)),
            command = command,
            -- The argument the window was opened with, as `desktop.list`
            -- reports it: an opener finds a window already open for the same
            -- thing (a folder window for the same path) and focuses it
            -- instead of opening a second one. A bash window's command is
            -- `command`, not this.
            args = type(spec.args) == "string" and spec.args ~= "" and spec.args or nil,
            x = x, y = y, w = w, h = h,
            view = view, updates = updates, pid = pid,
            rows = {}, cursor = nil, revision = -1,
            ready = false, minimized = false, maximized = false,
            closing = false, deadline = nil,
            saved = {x = x, y = y, w = w, h = h},
        }
        windows[#windows + 1] = window
        return window, nil
    end

    -- Объявлено заранее: закрытие вида зовёт `forget` сразу (процесса, чья
    -- смерть позвала бы его сама, у вида нет), а `forget` в свою очередь
    -- закрывает диалоги. Без этой строки `forget` внутри `close_window` — это
    -- глобальная переменная, то есть nil, и композитор падает ровно там, где
    -- закрывают окно-вид.
    local forget: any

    -- Закрытие: сначала вежливо, потом по сроку. Окно, ещё не позвавшее
    -- tty.start(), ввод не принимает — его гасим сразу.
    -- `how` is "request" (the default: the ×, ctrl+w, a plain `desktop.close`)
    -- or "force" (shutdown, `desktop.close{force = true}`). A request sends
    -- `close` and waits: the window may refuse — Notepad asks to save a
    -- changed document — and when the grace runs out it stays open and the
    -- status line says so. A force kills after the grace, as before. A PTY
    -- window has no loop that could answer: every close of it is a force.
    local function close_window(window, how: any?)
        local mode = how == "force" and "force" or "request"
        if window.entry == PTY_WINDOW then mode = "force" end
        if window.closing then
            -- Shutdown over a pending request: it stops waiting for a yes.
            if mode == "force" then window.close_how = "force" end
            return
        end
        window.closing = true
        window.close_how = mode
        -- Диалог без своего окна — сирота: он объявлен принадлежащим номеру,
        -- которого больше нет, и на столе остаётся предмет, о котором никто
        -- не помнит, откуда он.
        --
        -- Каскад здесь и в `forget` — не дубль: этот закрывает диалоги СРАЗУ,
        -- а тот ловит окно, умершее само. Без здешнего диалог висел бы на
        -- столе всё время вежливого срока — до трёх секунд после того, как
        -- его окно попросили закрыться.
        for _, child in ipairs(children_of(window.id)) do close_window(child, mode) end

        -- Both transports receive close and the same grace period for cleanup.
        if window.content == "pixels" then
            if window.state_pid then
                process.send(tostring(window.state_pid), "window.input", {id = window.id, event = {type = "close"}})
                window.deadline = time.after(CLOSE_GRACE)
            else forget(window) end
            return
        end

        if window.ready then
            window.view:send({type = "close"})
            window.deadline = time.after(CLOSE_GRACE)
        else
            process.terminate(tostring(window.pid))
        end
    end

    forget = function(window)
        if type(chrome.forget) == "function" then chrome.forget(window.id) end
        local index = index_of(window.id)
        if index > 0 then table.remove(windows, index) end
        if window.view then window.view:close() end
        -- Окно могло умереть само, не дождавшись вежливого закрытия: его
        -- диалоги остались бы на столе привязанными к номеру, которого нет.
        -- A dialog of a window that is gone may not refuse: force.
        for _, child in ipairs(children_of(window.id)) do close_window(child, "force") end
    end

    local function request_quit()
        quitting = true
        menu = nil
        drag.active = false
        -- Closing a view can remove it and its children synchronously.
        local closing = {}
        for _, window in ipairs(windows) do closing[#closing + 1] = window end
        -- Shutdown does not ask: a window that would refuse is killed after
        -- the grace, or the desktop would never go away.
        for index = #closing, 1, -1 do close_window(closing[index], "force") end
    end

    -- raise_open(entry) -> whether a window of that entry was already open
    --
    -- The tray, the taskbar clock and desktop widgets name a window rather
    -- than launch a program: a second click must bring back the window the
    -- first one opened, minimised or covered, not open a second copy.
    local function raise_open(entry: any): boolean
        for _, candidate in ipairs(windows) do
            if candidate.entry == entry and not candidate.closing then
                candidate.minimized = false
                raise(candidate)
                return true
            end
        end
        return false
    end

    local function activate_menu_item(item: any)
        if item.action == "quit" then
            farewell_wanted = true
            request_quit()
            return
        end
        -- `raise` marks an item that names a window rather than a program to
        -- start again: Open in a widget's context menu does what its click does.
        if item.raise == true and raise_open(item.entry) then return end
        local window, err = open_window({
            entry = item.entry, title = item.title, w = item.w, h = item.h,
            args = item.args, window_type = item.window_type, image = item.image,
        }, nil)
        if window then raise(window)
        else notice = "could not open: " .. tostring(err) end
    end

    -- Контекстное меню значка стола: «Открыть» — то же, что двойной щелчок,
    -- и «Свойства», если программа объявила окно свойств (`meta.properties`
    -- у записи — его тема кладёт в попадание значка). Пункты — те же
    -- таблицы, что у каталога «Пуска», поэтому их открывает тот же
    -- `activate_menu_item`, а ходит по ним та же клавиатура и то же
    -- наведение. Подпись пункта — `label`; `title` остаётся заголовком
    -- окна, которое пункт открывает.
    local function context_items(spot: any): any
        local items = {}
        if type(spot.entry) == "string" and spot.entry ~= "" then
            items[#items + 1] = {label = "Open", bold = true,
                entry = spot.entry, title = spot.title, w = spot.w, h = spot.h,
                args = spot.args, window_type = spot.window_type, image = spot.image}
        end
        if type(spot.properties) == "string" and spot.properties ~= "" then
            items[#items + 1] = {label = "Properties", entry = spot.properties,
                separator_before = #items > 0 or nil}
        end
        return items
    end

    -- resized_rect(window, w, h) -> {x, y, w, h}: the window at that size,
    -- clamped to the screen. One rule for the resize itself and for the
    -- outline a resize drag shows before its release.
    local function resized_rect(window, w: any, h: any): any
        local nw = clamp(tonumber(w) or window.w, MIN_W, width)
        local nh = clamp(tonumber(h) or window.h, MIN_H, desktop_height())
        return {w = nw, h = nh, x = clamp(window.x, 1, math.max(1, width - nw + 1)),
            y = clamp(window.y, desktop_top, math.max(desktop_top, height - nh))}
    end

    local function resize_window(window, w: any, h: any)
        local rect = resized_rect(window, w, h)
        window.w, window.h, window.x, window.y = rect.w, rect.h, rect.x, rect.y
        -- У вида viewport'а нет: его размер — это просто числа, по которым
        -- тема рисует в следующем кадре.
        if window.view then
            window.view:resize(window.w - FRAME_W, window.h - FRAME_H)
        elseif window.state_pid then
            process.send(tostring(window.state_pid), "window.input", {id = window.id, event = {
                type = "resize", width = window.w - FRAME_W, height = window.h - FRAME_H,
                cell_w = cell_w, cell_h = cell_h,
            }})
        end
    end

    local function toggle_maximize(window)
        -- Окно с фиксированным размером не разворачивается: его раскладка
        -- посчитана под один размер, и во весь экран оно показало бы серое
        -- поле вокруг кнопок. Тема кнопку не рисует; alt+клавиша и команда
        -- снаружи упираются сюда же, чтобы обходного пути не было.
        if window.resizable == false then return end
        if window.maximized then
            local saved = window.saved
            window.maximized = false
            window.x = saved.x
            window.y = saved.y
            resize_window(window, saved.w, saved.h)
        else
            window.saved = {x = window.x, y = window.y, w = window.w, h = window.h}
            window.maximized = true
            window.x, window.y = 1, desktop_top
            resize_window(window, width, desktop_height())
        end
    end

    local function send_to(window: any, event)
        if not window or not window.ready or window.closing then return false end

        -- Ввод в окно-вид уходит его поставщику состояния: живой части у
        -- такого окна больше нет, а вид — чистая функция и щелчок принять не
        -- может. Что делать с ним — решает поставщик и отвечает новым
        -- состоянием.
        if window.content == "pixels" then
            if not window.state_pid then return false end
            local sent = process.send(tostring(window.state_pid), "window.input",
                {id = window.id, event = event})
            return sent and true or false
        end

        local ok = window.view:send(event)
        return ok and true or false
    end

    -- Focus changes reach the windows as the runtime's own terminal event,
    -- `{type = "focus", focused = …}` — the shape `tty.events()` delivers when
    -- the physical terminal gains or loses focus — so a window reads one event
    -- whatever moved the keyboard. Without it a window never learns it lost
    -- the keyboard: an armed button or a captured scrollbar waits for a
    -- release that now goes to another window (windows-module sdk-review A11).
    --
    -- The loser hears first, then the winner. The winner is remembered only
    -- once the send succeeded: a window that has not drawn its first frame is
    -- not `ready`, `send_to` drops the event, and it is told on the next frame
    -- instead of never. A PTY window forwards the event to its session, and
    -- the runtime's PTY proxy writes \e[I / \e[O only when the program inside
    -- asked for focus reports (mode 1004): bash gets nothing, vim its report.
    notify_focus = function()
        local top = focused()
        local now = top and top.id or nil
        if now == focus_seen.id then return end
        if focus_seen.id ~= nil then
            local before = find(focus_seen.id)
            focus_seen.id = nil
            if before then send_to(before, {type = "focus", focused = false}) end
        end
        if top and send_to(top, {type = "focus", focused = true}) then focus_seen.id = now end
    end

    -- ─── ввод ────────────────────────────────────────────────────────────

    local function hit(x, y)
        for index = #windows, 1, -1 do
            local window = windows[index]
            if not window.minimized and not window.closing
                and x >= window.x and x <= window.x + window.w - 1
                and y >= window.y and y <= window.y + window.h - 1 then
                return window
            end
        end
        return nil
    end

    -- Кнопка под точкой заголовка. Считает тема: только она знает строку
    -- заголовка, толщину рамки и состав кнопок — три числа, которые здесь
    -- пришлось бы повторить. Повторение уже стоило дефекта: заголовок
    -- переехал внутрь рамки, а проверка осталась на верхней грани, и по
    -- кнопкам перестало попадать вовсе.
    local function title_button_at(window, x, y)
        if type(chrome.title_button_at) == "function" then
            return chrome.title_button_at(window, x, y)
        end
        -- Запасной путь для темы, которая хит-теста не считает.
        local step = math.tointeger(tonumber(chrome.BUTTON_STEP) or 3) or 3
        local span = math.tointeger(tonumber(chrome.BUTTONS_WIDTH) or 9) or 9
        if step < 1 then step = 1 end
        if window.w < span + 6 then return nil end
        local from = window.x + window.w - 1 - span
        if x < from or x > from + span - 1 then return nil end
        local slot = math.tointeger((x - from) // step) or 0
        -- Тема без таблицы кнопок — не повод падать: до этой ветки доходит
        -- только та, что не считает хит-тест сама, и промах по кнопке дешевле
        -- погасшего стола.
        local set: any = chrome.BUTTONS
        local button: any = type(set) == "table" and set[slot + 1] or nil
        return button and button.id or nil
    end

    local client_capture: any = nil
    local function client_pointer(window: any, event: any)
        return send_to(window, {type = "mouse", action = event.action, button = event.button,
            x = event.x - window.x - insets.left + 1, y = event.y - window.y - insets.top + 1,
            alt = event.alt, ctrl = event.ctrl, shift = event.shift})
    end
    -- Plain motion — no button held, nothing captured — goes to the focused
    -- window when the pointer is over its client, once per cell: an SDK menu
    -- follows the pointer by it, as the Start menu does here. Over the frame,
    -- another window or the desktop nothing is sent, and leaving the client
    -- forgets the cell, so coming back to it is news again. The last cell lives
    -- on the window record, not in an upvalue: an error under pcall in go-lua
    -- splits upvalues from their owner.
    local function pointer_motion(event: any)
        local window: any = focused()
        if not window then return end
        local left = math.tointeger(insets.left) or 1
        local top = math.tointeger(insets.top) or 1
        if event.x < window.x + left or event.x >= window.x + window.w - (math.tointeger(insets.right) or 1)
            or event.y < window.y + top or event.y >= window.y + window.h - (math.tointeger(insets.bottom) or 1) then
            window.motion_cell = nil
            return
        end
        local x, y = event.x - window.x - left + 1, event.y - window.y - top + 1
        local cell = tostring(x) .. ":" .. tostring(y)
        if window.motion_cell == cell then return end
        if send_to(window, {type = "mouse", action = "motion", button = event.button, x = x, y = y,
            alt = event.alt, ctrl = event.ctrl, shift = event.shift}) then
            window.motion_cell = cell
        end
    end
    -- Наведение в открытом меню. Строка под мышью становится выбранной сразу,
    -- а каскад — папка раскрывается, подменю глубже строки закрывается — через
    -- HOVER_DELAY: «иду в подменю» и «ушёл на соседнюю строку» в первом
    -- событии движения одинаковы и различаются только тем, где мышь окажется
    -- через мгновение.
    --
    -- Курсор живёт на самом глубоком раскрытом уровне — так же, как у
    -- стрелок. Поэтому папка, которая уже раскрыта, курсора не берёт: выбор
    -- идёт в её панели, а сама она нарисована раскрытой.
    local function menu_spot_at(x, y)
        for _, spot in ipairs(menu_hits) do
            if spot.slot ~= nil and y >= spot.row and y <= (spot.bottom_row or spot.row)
                and x >= spot.from and x <= spot.to then
                return spot
            end
        end
        return nil
    end

    local function same_path(left: any, right: any)
        if type(left) ~= "table" or type(right) ~= "table" then return false end
        if #left ~= #right then return false end
        for index = 1, #left do
            if left[index] ~= right[index] then return false end
        end
        return true
    end

    local function hover_menu(x, y)
        local spot: any = menu_spot_at(x, y)
        if spot == nil then return end
        local level = math.tointeger(spot.level) or 1
        local open: any = type(menu.open) == "table" and menu.open or {}
        local folder = type(spot.open) == "table"
        -- Что должно быть раскрыто, пока мышь над этой строкой: папка — она
        -- сама, пункт — всё до его уровня.
        local wanted: any = {}
        if folder then
            wanted = spot.open
        else
            for index = 1, level - 1 do wanted[index] = open[index] end
        end
        if same_path(open, wanted) then
            menu.pending = nil
            hover_timer = nil
            if not folder
                and (math.tointeger(menu.cursor) or 0) ~= (math.tointeger(spot.slot) or 0) then
                menu.cursor = spot.slot
                draw()
            end
            return
        end
        local pending: any = menu.pending
        if pending and same_path(pending.open, wanted) then return end
        -- Папка, раскрытая наведением, в подменю ничего не выбирает: курсор
        -- 0 — «строки нет», enter на нём молчит, стрелка вниз ведёт на первую.
        menu.pending = {open = wanted, cursor = folder and 0 or spot.slot}
        hover_timer = time.after(HOVER_DELAY)
    end

    local function settle_hover()
        hover_timer = nil
        if menu == nil then return end
        local pending: any = menu.pending
        menu.pending = nil
        if pending == nil then return end
        menu.open = pending.open
        menu.cursor = pending.cursor
        draw()
    end

    local function handle_mouse(event)
        if client_capture and (event.action == "motion" or event.action == "release") then
            local target = find(client_capture)
            if target and not target.minimized then client_pointer(target, event) end
            if event.action == "release" or not target then client_capture = nil end
            return
        end
        if event.action == "motion" and drag.active and drag.mode == "icon" then
            local item = desktop_item(drag.id)
            if not item then drag.active = false; return end
            item.x = clamp(event.x - drag.dx, 1, width)
            item.y = clamp(event.y - drag.dy, desktop_top, desktop_last)
            draw()
            return
        end

        if event.action == "motion" and drag.active then
            local window = find(drag.id)
            if not window then drag.active = false; return end
            -- Only the outline follows the pointer (`drag_outline`); the
            -- window takes the rect on the release. The resize keeps G2's
            -- offset from the corner (`drag.dx`).
            if drag.mode == "move" then
                drag.pending = {w = window.w, h = window.h,
                    x = clamp(event.x - drag.dx, 1, math.max(1, width - window.w + 1)),
                    y = clamp(event.y - drag.dy, desktop_top, math.max(desktop_top, height - window.h))}
            else
                drag.pending = resized_rect(window, event.x + drag.dx - window.x + 1, event.y + drag.dy - window.y + 1)
            end
            draw()
            return
        end

        if event.action == "motion" then
            if menu and not drag.active and not quitting then hover_menu(event.x, event.y) end
            -- The Start menu lies over the windows: while it is open the
            -- pointer is its.
            if not menu and not quitting then pointer_motion(event) end
            return
        end

        if event.action == "release" then
            if drag.active and drag.mode == "icon" then
                drag.active = false
                local item = desktop_item(drag.id)
                if item then
                    local gw, gh, gl = icon_grid()
                    item.x = snap(item.x, gw, gl)
                    item.y = snap(item.y, gh, desktop_top)
                    -- Перетащенный значок перестаёт быть автопосаженным —
                    -- но только если место записалось: иначе он вернулся на
                    -- прежнее, и прежним было автопосаженное.
                    local was_auto = item.auto
                    item.auto = nil
                    if move_item then
                        local ok, err = move_item(drag.id, item.x, item.y)
                        if not ok then
                            item.auto = was_auto
                            -- Значок обязан вернуться туда, откуда взят:
                            -- иначе до перезапуска он на новом месте, а
                            -- после — на старом, и человек решит, что
                            -- перезапуск его потерял.
                            item.x, item.y = drag.from_x, drag.from_y
                            notice = "the icon did not move: " .. tostring(err)
                        end
                    end
                end
                draw()
                return
            end
            if drag.active then
                -- The release applies the outline: one move, one resize (and
                -- one resize event to the program inside), however long the drag.
                drag.active = false
                local window = find(drag.id)
                local pending: any = drag.pending
                drag.pending = nil
                if window and pending then
                    if drag.mode == "resize" then resize_window(window, pending.w, pending.h)
                    else window.x, window.y = pending.x, pending.y end
                end
                draw()
            end
            return
        end

        if event.action == "wheel" then
            if menu or quitting then return end
            local window = hit(event.x, event.y)
            if window and event.x >= window.x + insets.left
                and event.x < window.x + window.w - insets.right
                and event.y >= window.y + insets.top
                and event.y < window.y + window.h - insets.bottom then
                send_to(window, {
                    type = "mouse", action = "wheel", button = event.button,
                    x = event.x - window.x - insets.left + 1,
                    y = event.y - window.y - insets.top + 1,
                    shift = event.shift, alt = event.alt, ctrl = event.ctrl,
                })
            end
            return
        end
        if event.action ~= "press" or quitting then return end

        -- Хром слушает только ЛЕВУЮ кнопку: правая по заголовку закрывала
        -- окно, по «Пуску» открывала меню. Правая и средняя уходят окну под
        -- указателем, в его тело, — там их ждут программы.
        if event.button ~= "left" then
            if menu then return end
            local window = hit(event.x, event.y)
            if window and event.x >= window.x + insets.left
                and event.x < window.x + window.w - insets.right
                and event.y >= window.y + insets.top
                and event.y < window.y + window.h - insets.bottom then
                send_to(window, {
                    type = "mouse", action = event.action, button = event.button,
                    x = event.x - window.x - (math.tointeger(insets.left) or 1) + 1,
                    y = event.y - window.y - (math.tointeger(insets.top) or 1) + 1,
                    alt = event.alt, ctrl = event.ctrl, shift = event.shift,
                })
                return
            end
            -- Правая кнопка по значку стола — контекстное меню у указателя.
            -- Это то же меню, что «Пуск», только с плоским списком и якорем:
            -- тема кладёт панель у якоря, а не над панелью задач.
            if event.button == "right" and not window then
                local spot: any = desktop_spot(event.x, event.y)
                local items: any = {}
                if spot and spot.widget ~= nil then
                    -- A widget (FR-006 §5): Open when it names a window, and
                    -- nothing otherwise — not the desktop's Properties, which
                    -- the empty-desktop branch below would give a widget
                    -- record without an id. No selection either.
                    if type(spot.entry) == "string" and spot.entry ~= "" then
                        items = {{label = "Open", bold = true, entry = spot.entry, raise = true}}
                    end
                elseif spot and spot.id then
                    selected_id = spot.id
                    items = context_items(spot)
                elseif event.y >= desktop_top and event.y <= desktop_last
                    and type(desktop_properties) == "string" and desktop_properties ~= "" then
                    -- Пустой стол: «Свойства» стола, если оболочка назвала
                    -- окно (`options.desktop_properties`) — как в Windows 95.
                    selected_id = nil
                    items = {{label = "Properties", entry = desktop_properties}}
                end
                if #items > 0 then
                    menu = {items = items, failure = nil, open = {}, cursor = 1,
                        anchor = {x = event.x, y = event.y}}
                end
                draw()
            end
            return
        end

        -- Открытое меню забирает клик целиком: попал в пункт — открываем,
        -- мимо — закрываем. Иначе клик «мимо меню» уходил бы в окно под ним,
        -- и меню оставалось бы висеть поверх результата.
        if menu then
            -- Щелчок решает сам: каскад, которого ждало наведение, не должен
            -- смениться следом за ним.
            menu.pending = nil
            hover_timer = nil
            for _, spot in ipairs(menu_hits) do
                if event.y >= spot.row and event.y <= (spot.bottom_row or spot.row)
                    and event.x >= spot.from and event.x <= spot.to then
                    -- Папка несёт ПОЛНЫЙ путь от корня, поэтому композитору
                    -- не надо разбирать дерево и помнить, где он находится:
                    -- он кладёт путь и рисует снова.
                    if type(spot.open) == "table" then
                        menu.open = spot.open
                        draw()
                        return
                    end
                    local item = menu.items[spot.index]
                    if item then
                        -- Меню, ярлык и alt+n — это сам композитор, а не
                        -- окно: открытому здесь принадлежать некому.
                        activate_menu_item(item)
                    end
                    menu = nil
                    draw()
                    return
                end
            end
            menu = nil
            draw()
            return
        end

        -- Полосы хрома: кнопка окна поднимает и разворачивает его, кнопка
        -- меню открывает и закрывает каталог.
        for _, spot in ipairs(bar_hits) do
            if event.y >= spot.row and event.y <= (spot.bottom_row or spot.row)
                    and event.x >= spot.from and event.x <= spot.to then
                if spot.id then
                    local window = find(spot.id)
                    if window then
                        window.minimized = false
                        raise(window)
                        draw()
                    end
                elseif spot.action == "menu" then
                    if menu then
                        menu = nil
                    else
                        local items, failure = catalog()
                        menu = {items = items, failure = failure, open = {}, cursor = 1}
                    end
                    draw()
                elseif type(spot.entry) == "string" and spot.entry ~= "" then
                    if not raise_open(spot.entry) then activate_menu_item(spot) end
                    draw()
                end
                return
            end
        end

        local window = hit(event.x, event.y)
        if not window then
            -- Пустое место: под окнами лежит стол со значками. Одиночный
            -- щелчок выделяет и берёт значок, двойной открывает.
            notice = ""
            -- `any`: after the widget branch below the linter narrows a plain
            -- local to `false?` and then refuses every field of an icon.
            local spot: any = desktop_spot(event.x, event.y)
            -- A widget is not an icon (FR-006 §5): a press opens the window it
            -- names, or raises the one already open, as a tray caption does.
            -- No selection, no drag and no double-click bookkeeping.
            if spot and spot.widget ~= nil then
                if type(spot.entry) == "string" and spot.entry ~= "" and not raise_open(spot.entry) then
                    -- Only the entry: the record's title, w and h describe the
                    -- widget, not the window it opens.
                    activate_menu_item({entry = spot.entry})
                end
                draw()
                return
            end

            local moment = time.now():unix_nano()
            local repeated = last_click.x == event.x and last_click.y == event.y
                and (moment - last_click.at) < 500000000
            last_click = {x = event.x, y = event.y, at = moment}

            if not spot then
                if selected_id then selected_id = nil; draw() end
                return
            end

            if spot.id then selected_id = spot.id end

            if repeated then
                if type(spot.entry) == "string" and spot.entry ~= "" then
                    local opened = open_window({
                        entry = spot.entry, title = spot.title,
                        w = spot.w, h = spot.h, args = spot.args,
                        window_type = spot.window_type,
                    }, nil)
                    if opened then raise(opened) end
                end
                draw()
                return
            end

            local item = spot.id and desktop_item(spot.id) or nil
            if item then
                local at_x = math.tointeger(tonumber(item.x) or event.x) or event.x
                local at_y = math.tointeger(tonumber(item.y) or event.y) or event.y
                drag = {active = true, id = spot.id, mode = "icon",
                    dx = event.x - at_x, dy = event.y - at_y,
                    from_x = at_x, from_y = at_y}
            end
            draw()
            return
        end
        raise(window)

        -- Полоса заголовка занимает весь верхний инсет: у темы с рамкой
        -- вокруг заголовка это не одна строка.
        if event.y < window.y + (math.tointeger(insets.top) or 1) then
            local button = title_button_at(window, event.x, event.y)
            if button == "close" then close_window(window)
            elseif button == "minimize" then window.minimized = true
            elseif button == "maximize" then toggle_maximize(window)
            elseif button then
                -- Кнопка, которой композитор не знает — например «справка» у
                -- диалога. Делать нечего, но и перетаскивание начинать
                -- нельзя: окно уехало бы от щелчка по кнопке.
                drag.active = false
            else
                drag = {active = true, id = window.id, mode = "move",
                    dx = event.x - window.x, dy = event.y - window.y}
            end
            draw()
            return
        end

        -- The bottom-right corner of the frame drags the size, if the entry
        -- allows it: the last TWO cells of the bottom row, where the theme
        -- draws the Windows 95 sizing grip (13×13 px reaches into the second
        -- cell at a 10×20 cell). `dx` is how far the press is from the corner,
        -- so a window taken by the second-to-last cell does not lose a column
        -- on the first motion.
        local corner_x = window.x + window.w - 1
        if window.resizable ~= false and event.y == window.y + window.h - 1
            and event.x >= corner_x - 1 and event.x <= corner_x then
            drag = {active = true, id = window.id, mode = "resize", dx = corner_x - event.x, dy = 0}
            draw()
            return
        end

        -- Тело окна: клик уходит внутрь, в координатах самого окна.
        if event.x < window.x + insets.left or event.x >= window.x + window.w - insets.right
            or event.y < window.y + insets.top or event.y >= window.y + window.h - insets.bottom then return end
        client_capture = window.id
        send_to(window, {
            type = "mouse", action = event.action, button = event.button,
            x = event.x - window.x - (math.tointeger(insets.left) or 1) + 1,
            y = event.y - window.y - (math.tointeger(insets.top) or 1) + 1,
            alt = event.alt, ctrl = event.ctrl, shift = event.shift,
        })
        draw()
    end

    -- Акселераторы держатся на alt: ctrl и tab слишком часто нужны самим
    -- программам в окнах, и красть их — значит ломать редактор внутри.
    -- Каталог окон приложения. Читается в момент открытия меню, а не при
    -- старте: приложение может объявить окно и без перезапуска десктопа.
    catalog = function()
        if read_catalog then
            local items, failure = read_catalog()
            return type(items) == "table" and items or {}, failure
        end
        local found, err = registry.find({["meta.type"] = WINDOW_META_TYPE})
        if err then return {}, tostring(err) end
        if type(found) ~= "table" then return {}, "the registry did not answer with a list" end
        -- Скрытые (`meta.in_menu: false`) сюда не попадают, неизвестный тип
        -- считается обычным окном. Опечатка в типе не повод не показать
        -- программу, но и молчать о ней нельзя — иначе она живёт вечно.
        local items, warnings = programs.menu(found)
        for _, warning in ipairs(warnings) do
            log:warn("unknown window type", {
                entry = warning.entry, window_type = warning.window_type,
                used = programs.DEFAULT_TYPE,
            })
        end
        return items, nil
    end

    -- ─── стрелки по меню ─────────────────────────────────────────────────
    --
    -- Курсор ходит по РАЗМЕТКЕ, а не по каталогу: выбирается то, что
    -- нарисовано. Считать выбор заново значило бы завести второе
    -- представление о том, где строки, и однажды курсор поехал бы по строкам,
    -- которых на экране нет.

    -- Строки самой глубокой раскрытой панели — те, между которыми ходит
    -- курсор. Панель левее раскрыта, но выбор идёт в той, что открыли
    -- последней.
    local function menu_rows()
        local deepest = 0
        for _, spot in ipairs(menu_hits) do
            local level = math.tointeger(spot.level) or 1
            if spot.slot ~= nil and level > deepest then deepest = level end
        end
        local rows = {}
        for _, spot in ipairs(menu_hits) do
            if spot.slot ~= nil and (math.tointeger(spot.level) or 1) == deepest then
                rows[#rows + 1] = spot
            end
        end
        table.sort(rows, function(left, right)
            return (math.tointeger(left.slot) or 0) < (math.tointeger(right.slot) or 0)
        end)
        return rows
    end

    -- Строка под курсором. Сначала та, которую тема ПОМЕТИЛА, и только потом
    -- та, чей номер совпал: пометка — единственное, что связывает наш номер с
    -- нарисованным.
    local function menu_cursor_spot()
        local rows = menu_rows()
        for _, spot in ipairs(rows) do
            if spot.cursor == true then return spot end
        end
        local wanted = math.tointeger(menu.cursor) or 1
        for _, spot in ipairs(rows) do
            if (math.tointeger(spot.slot) or 0) == wanted then return spot end
        end
        return nil
    end

    local function move_menu_cursor(step)
        local rows = menu_rows()
        if #rows == 0 then return false end
        local wanted = math.tointeger(menu.cursor) or 1
        local at = 0
        for index, spot in ipairs(rows) do
            if (math.tointeger(spot.slot) or 0) == wanted then at = index end
        end
        if at == 0 then at = step > 0 and 0 or 1 end
        local next_at = at + step
        if next_at < 1 then next_at = #rows end
        if next_at > #rows then next_at = 1 end
        menu.cursor = math.tointeger(rows[next_at].slot) or 1
        return true
    end

    local function open_menu_item(spot: any)
        local item: any = menu.items[math.tointeger(spot.index) or 0]
        if not item then return false end
        activate_menu_item(item)
        return true
    end

    -- ─── стрелки по столу ────────────────────────────────────────────────

    -- Значки по разметке: у значка с подписью попаданий несколько (строка
    -- рисунка и строки подписи), а значок один — поэтому они сводятся по id, и
    -- за место берётся самая верхняя строка.
    local function icon_spots()
        local seen: any = {}
        local spots = {}
        for _, hit in ipairs(desk_hits) do
            local id = hit.id
            -- Widget records share the desktop group but are not icons: the
            -- arrows walk the icon grid only (FR-006 §5).
            if type(id) == "string" and id ~= "" and hit.widget == nil then
                local row = math.tointeger(hit.row) or 0
                local col = math.tointeger(hit.from) or 0
                local at = seen[id]
                if at == nil then
                    spots[#spots + 1] = {id = id, row = row, col = col, hit = hit}
                    seen[id] = #spots
                else
                    local kept: any = spots[at]
                    if row < kept.row then kept.row = row end
                end
            end
        end
        return spots
    end

    local function move_selection(dx, dy)
        local spots = icon_spots()
        if #spots == 0 then return false end

        local current: any = nil
        for _, spot in ipairs(spots) do
            if spot.id == selected_id then current = spot end
        end
        -- Ничего не выделено — первая стрелка выделяет, а не двигает.
        if current == nil then
            selected_id = spots[1].id
            return true
        end

        local best: any = nil
        local best_score = 0
        for _, spot in ipairs(spots) do
            if spot.id ~= current.id then
                local drow = spot.row - current.row
                local dcol = spot.col - current.col
                local forward = false
                local score = 0
                if dy ~= 0 and drow * dy > 0 then
                    forward = true
                    score = math.abs(drow) * 1000 + math.abs(dcol)
                elseif dx ~= 0 and dcol * dx > 0 and drow == 0 then
                    forward = true
                    score = math.abs(dcol) * 1000 + math.abs(drow)
                end
                if forward and (best == nil or score < best_score) then
                    best, best_score = spot, score
                end
            end
        end

        if best == nil then return false end
        selected_id = best.id
        return true
    end

    local function open_selected_icon()
        for _, hit in ipairs(desk_hits) do
            if hit.id == selected_id and hit.widget == nil
                and type(hit.entry) == "string" and hit.entry ~= "" then
                local opened = open_window({
                    entry = hit.entry, title = hit.title,
                    w = hit.w, h = hit.h, args = hit.args,
                    window_type = hit.window_type,
                }, nil)
                if opened then raise(opened) end
                return true
            end
        end
        return false
    end

    local function handle_key(event)
        if event.ctrl and event.key == "q" then
            request_quit()
            if #windows == 0 then return "quit" end
            draw()
            return "handled"
        end
        if quitting then return "handled" end
        -- Esc during a move or resize drops the outline: the window stays
        -- where it was, as in Windows 95.
        if drag.active and drag.mode ~= "icon" and event.key_type == "esc" then
            drag.active, drag.pending = false, nil
            draw()
            return "handled"
        end
        if menu then
            menu.pending = nil
            hover_timer = nil
            if event.key_type == "esc" then
                menu = nil
                draw()
                return "handled"
            end

            if event.key_type == "up" then
                if move_menu_cursor(-1) then draw() end
            elseif event.key_type == "down" then
                if move_menu_cursor(1) then draw() end
            elseif event.key_type == "right" then
                -- Папка раскрывается вправо: путь кладётся целиком, как и при
                -- щелчке, — композитор дерева не помнит.
                local spot = menu_cursor_spot()
                if spot and type(spot.open) == "table" then
                    menu.open = spot.open
                    menu.cursor = 1
                    draw()
                end
            elseif event.key_type == "left" then
                local open: any = menu.open
                if type(open) == "table" and #open > 0 then
                    local shorter = {}
                    for index = 1, #open - 1 do shorter[index] = open[index] end
                    menu.open = shorter
                    menu.cursor = 1
                    draw()
                end
            elseif event.key_type == "enter" then
                local spot = menu_cursor_spot()
                if spot == nil then
                    -- Тема не пометила выбранную строку: enter молчал бы, а
                    -- молчащая клавиша неотличима от сломанного меню. Курсор
                    -- 0 — другое: строки не выбрано, папку раскрыло наведение.
                    if (math.tointeger(menu.cursor) or 0) > 0 then
                        notice = "the theme did not mark the selected menu row"
                        draw()
                    end
                elseif type(spot.open) == "table" then
                    menu.open = spot.open
                    menu.cursor = 1
                    draw()
                else
                    if open_menu_item(spot) then menu = nil end
                    draw()
                end
            end

            -- Открытое меню забирает ввод целиком: иначе клавиша уехала бы в
            -- окно под ним.
            return "handled"
        end

        -- Стрелки принадлежат столу только тогда, когда ни одно окно не в
        -- фокусе. Иначе стол крал бы их у редактора внутри окна — а это ровно
        -- та кража клавиш, из-за которой акселераторы здесь держатся на alt.
        if focused() == nil then
            if event.key_type == "up" then
                if move_selection(0, -1) then draw() end
                return "handled"
            elseif event.key_type == "down" then
                if move_selection(0, 1) then draw() end
                return "handled"
            elseif event.key_type == "left" then
                if move_selection(-1, 0) then draw() end
                return "handled"
            elseif event.key_type == "right" then
                if move_selection(1, 0) then draw() end
                return "handled"
            elseif event.key_type == "enter" and selected_id then
                if open_selected_icon() then draw() end
                return "handled"
            end
        end

        if event.alt then
            local top = focused()
            if event.key == "n" then
                local window, err = open_window({}, nil)
                if window then raise(window) end
                -- Said on the desktop, not only in the log: a person refused a
                -- shell would otherwise see a key that does nothing.
                if err then
                    notice = "could not open: " .. tostring(err)
                    log:error("window did not open", {error = tostring(err)})
                end
                draw()
                return "handled"
            elseif event.key == "w" and top then
                close_window(top); draw(); return "handled"
            elseif event.key == "m" and top then
                top.minimized = true; draw(); return "handled"
            elseif event.key == "o" then
                local items, failure = catalog()
                menu = {items = items, failure = failure, open = {}, cursor = 1}
                draw()
                return "handled"
            elseif event.key_type == "tab" and #windows > 1 then
                local bottom = windows[1]
                bottom.minimized = false
                raise(bottom); draw(); return "handled"
            end
        end

        return "forward"
    end

    -- ─── команды снаружи ─────────────────────────────────────────────────

    local function describe(window)
        return {
            id = window.id, entry = window.entry, title = window.title, command = window.command,
            -- The window's process: whoever watches a desktop close can see
            -- its windows go, not only the desktop.
            pid = window.pid ~= nil and tostring(window.pid) or nil,
            image = window.image,
            args = window.args,
            window_type = window.window_type,
            opened_by = window.opened_by,
            -- Чем рисуется содержимое и дождалось ли оно данных. Снаружи это
            -- единственный способ отличить «вид ждёт состояния» от «вид
            -- нарисован пустым»: на экране это одно и то же.
            content = window.content,
            waiting = window.waiting == true,
            state_revision = window.state_revision,
            -- Подпись вида (`content_state.caption`) — то немногое, что вид
            -- рассказывает о себе словами. Снаружи это единственный способ
            -- узнать, что прокрутка или раскрытие дошли до поставщика, не
            -- глядя на пиксели.
            caption = type(window.content_state) == "table"
                and type(window.content_state.caption) == "string"
                and window.content_state.caption or nil,
            resizable = window.resizable ~= false,
            x = window.x, y = window.y, width = window.w, height = window.h,
            ready = window.ready, minimized = window.minimized,
            maximized = window.maximized, closing = window.closing,
        }
    end

    -- Ответ всегда называет команду, на которую отвечает. Без этого поля
    -- спрашивающий сопоставляет ответ с вопросом по одному лишь порядку — а
    -- отказ, приехавший сам (см. `refuse`), этот порядок нарушает.
    -- Путь раскрытой папки строкой: наружу его отдаёт командный канал, а
    -- строка читается человеком без разбора таблиц.
    local function menu_path_text()
        if menu == nil then return nil end
        local open: any = menu.open
        if type(open) ~= "table" then return "" end
        local parts = {}
        for _, name in ipairs(open) do parts[#parts + 1] = tostring(name) end
        return table.concat(parts, "/")
    end

    -- Сколько строк на самом глубоком уровне и сколько из них папки.
    -- Считается по РАЗМЕТКЕ, как и всё про меню: это то, что нарисовано.
    -- Объявлены заранее, потому что зовёт их ответ командного канала, а
    -- считают они по `menu_hits`, который к тому моменту уже собран.
    local function menu_level_rows()
        local deepest = 0
        for _, spot in ipairs(menu_hits) do
            local level = math.tointeger(spot.level) or 1
            if spot.slot ~= nil and level > deepest then deepest = level end
        end
        local rows = {}
        for _, spot in ipairs(menu_hits) do
            if spot.slot ~= nil and (math.tointeger(spot.level) or 1) == deepest then
                rows[#rows + 1] = spot
            end
        end
        return rows
    end

    local function menu_choices_count()
        if menu == nil then return nil end
        return #menu_level_rows()
    end

    local function menu_folders_count()
        if menu == nil then return nil end
        local folders = 0
        for _, spot in ipairs(menu_level_rows()) do
            if type(spot.open) == "table" then folders = folders + 1 end
        end
        return folders
    end

    local function reply(body: any, to, topic)
        if to == "" then return end
        body.command = topic
        process.send(to, REPLY_TOPIC, body)
    end

    -- Отказ на команду, которой никто не ждёт.
    --
    -- Команды от окна приходят без обратного адреса: окно не ждёт ответа,
    -- чтобы не морозить свой кадр. Значит «нет такого окна» и «не знаю такой
    -- команды» уходили В НИКУДА, и опечатка в идентификаторе выглядела как
    -- выполненная команда.
    --
    -- Теперь у отказа три адресата, и каждый нужен своему читателю: строка
    -- состояния — человеку за столом, лог — тому, кто разбирается потом, и
    -- САМ ОТПРАВИТЕЛЬ — потому что у окна есть канал ответов, и получить туда
    -- отказ оно может, не замирая. Пометка `unsolicited` обязательна: без неё
    -- приехавший сам отказ был бы принят за ответ на следующий вопрос.
    local function refuse(reason, to, topic, from: any)
        if to ~= "" then
            reply({ok = false, error = reason}, to, topic)
            return false
        end
        if from ~= nil then
            process.send(tostring(from), REPLY_TOPIC, {
                ok = false, error = reason, command = topic, unsolicited = true,
            })
        end
        notice = reason
        log:warn("command refused and nobody asked",
            {reason = reason, command = tostring(topic)})
        return true
    end

    local function handle_command(topic, body, from: any)
        -- What reads the frame reads the last state: the list reports what
        -- the painted hits and the frame meter say, the screen what is shown.
        if topic == "desktop.list" or topic == "desktop.screen" then flush() end
        local to = ""
        if type(body.reply_to) == "string" then to = body.reply_to end
        local window = find(type(body.id) == "string" and body.id or "")

        if topic == "desktop.list" then
            -- Истёкшие пункты снимаются и здесь: иначе список сказал бы про
            -- пункт, которого на экране уже нет, до следующего тика часов.
            local pruned = prune_tray()
            local list = {}
            for _, item in ipairs(windows) do list[#list + 1] = describe(item) end
            local top = focused()
            reply({ok = true, windows = list, focused = top and top.id or nil,
                screen = {width = width, height = height},
                -- The name this desktop claimed: several run at once under a
                -- terminal.ssh host, one per connection.
                service = SERVICE_NAME,
                -- Размер ячейки в пикселях и режим кадра: окно «Свойства:
                -- Экран» показывает разрешение по ним, а само их снять не
                -- может — терминал отвечает только композитору.
                cell = {w = cell_w, h = cell_h},
                pixels = PIXELS,
                -- Кто вошёл. Без этого поля «окна под пользователем» и «окна
                -- под служебным актором» снаружи неотличимы.
                user = IDENTITY and {id = IDENTITY.context.user_id, name = IDENTITY.context.user_name} or nil,
                -- Строка состояния: единственное место, где отказ виден
                -- человеку. Наружу она отдаётся, чтобы «отказ показан» можно
                -- было проверить, а не рассматривать глазами.
                notice = notice,
                -- Открыто ли меню. Снаружи это единственный способ отличить
                -- «щелчок по кнопке меню не дошёл» от «дошёл, а нарисовать
                -- меню не смогли»: на экране оба выглядят одинаково.
                menu_open = menu ~= nil,
                -- Выделенный значок стола: стрелки двигают именно его, и
                -- снаружи «стрелка не сработала» иначе неотличимо от «значок
                -- выделен, но тема этого не нарисовала».
                selected = selected_id,
                -- Раскрытая папка меню, путём от корня. Без неё «стрелка
                -- вправо не сработала» и «сработала, а тема не нарисовала
                -- подменю» выглядят одинаково — оба как ноль байт на экране.
                menu_path = menu_path_text(),
                -- Сколько строк на текущем уровне и сколько из них
                -- раскрываются. Третий вид того же вопроса: «вправо молчит»
                -- может значить «нечего раскрывать», и отличить это иначе
                -- нельзя — пустое меню и меню без папок на экране одинаковы.
                menu_choices = menu_choices_count(),
                menu_folders = menu_folders_count(),
                menu_context = (menu ~= nil and menu.anchor ~= nil) or false,
                -- Номер выбранной строки на текущем уровне; 0 — не выбрано.
                -- Без него «наведение не выделило» и «выделило, а тема не
                -- нарисовала» — один и тот же кадр.
                menu_cursor = menu and (math.tointeger(menu.cursor) or 0) or nil,
                -- Цена последнего кадра: изменившиеся строки, отправленные
                -- растры, байты. Мера для §8 FR-005 и единственный способ
                -- заметить, что хром порезан неверно.
                -- Плюс время: paint_ms/present_ms последнего кадра, его
                -- причина и сводка avg/p95/max по последним FRAME_WINDOW.
                frame = frame_report(body.frame_samples == true),
                pixels = PIXELS,
                -- Трей с владельцами и остатком срока: «пункт не появился» и
                -- «появился, а тема его не нарисовала» иначе неотличимы.
                tray = tray_view(true),
                -- Widgets without their trees: "not spawned", "waiting for
                -- its first state" and "stopped" differ here and nowhere else.
                widgets = widget_view(true),
                restore = restore_report}, to, topic)
            return pruned
        end

        -- Пункт области уведомлений: `{key, text, entry?, title?, ttl?}` кладёт
        -- или обновляет, `{key, remove = true}` снимает. Отказ называет
        -- причину — поставщик, которому трей тихо не показал пункт, решил бы,
        -- что показал.
        if topic == "desktop.tray" then
            local accepted, why, changed = set_tray(body, from)
            if not accepted then return refuse(tostring(why), to, topic, from) end
            reply({ok = true, key = body.key, items = #tray.items}, to, topic)
            return changed
        end

        if topic == "desktop.refresh" then
            reload_desktop()
            -- Widgets follow the registry on the same command: new entries
            -- are spawned, vanished ones stopped, stopped ones respawned.
            sync_widgets()
            reply({ok = true, items = #desk.items, failure = desk.failure,
                widgets = #widgets.items}, to, topic)
            return true
        end

        -- Окно мастерской в реестр — по просьбе снаружи, тем же кодом, что
        -- восстановление на старте. Просит туз MCP: скоуп MCP-сессии запрещает
        -- `registry.apply` явным deny, и туз, применяющий запись сам, молча
        -- ничего бы не сделал. Композитор работает под своим актором — у него
        -- это право есть, и строка к тому моменту уже в хранилище.
        if topic == "desktop.workshop" then
            local name = type(body.name) == "string" and body.name or ""
            if name == "" then return refuse("window name not given", to, topic, from) end
            local entry_id = apps.entry_id(name)
            if body.remove == true then
                local removed, rerr = apps.remove(name)
                if not removed then return refuse("removing from the registry: " .. tostring(rerr), to, topic, from) end
                reply({ok = true, name = name, entry = entry_id, live = false}, to, topic)
                return false
            end
            local stored_window, gerr = repo.get(name)
            if gerr then return refuse("storage: " .. tostring(gerr), to, topic, from) end
            if not stored_window then return refuse("window " .. name .. " is not in storage", to, topic, from) end
            local applied, aerr = apps.apply(stored_window)
            if not applied then return refuse("applying: " .. tostring(aerr), to, topic, from) end
            reply({ok = true, name = name, entry = entry_id, live = registry.get(entry_id) ~= nil}, to, topic)
            return false
        end

        if topic == "desktop.open" then
            local opened, err = open_window(body, from)
            if not opened then return refuse(tostring(err), to, topic, from) end
            raise(opened)
            reply({ok = true, window = describe(opened)}, to, topic)
            return true
        end

        -- Дальше только команды, адресованные конкретному окну. Порядок
        -- проверок тут — не стиль: пока «нет окна» стояло первым, ЛЮБАЯ
        -- неизвестная команда отвечала «нет окна nil», отправитель шёл искать
        -- опечатку в идентификаторе, которого не посылал, а ветка про
        -- неизвестную команду была недостижима вовсе.
        -- The state of a widget (FR-006 §3), accepted only from the process
        -- the compositor spawned for it — the rule of view windows: nobody
        -- else can draw into a widget. Widget ids are `g<n>`, never `w<n>`.
        -- So is its close: the SDK runner sends `desktop.close` with its id
        -- when its loop ends. From the widget's own process that is the widget
        -- stopping; answered "no window" it would sit in the status line as a
        -- refusal nobody made a mistake to earn.
        local widget: any = (topic == "desktop.state" or topic == "desktop.close") and widget_of(body.id) or nil
        if widget then
            if widget.pid == nil or from == nil or tostring(widget.pid) ~= tostring(from) then
                if topic == "desktop.close" then
                    return refuse("widget " .. widget.id .. " is closed only by its own process", to, topic, from)
                end
                return refuse("the state of widget " .. widget.id .. " is accepted only from its provider",
                    to, topic, from)
            end
            if topic == "desktop.close" then
                stop_widget(widget)
                reply({ok = true}, to, topic)
                return true
            end
            widget.content_state = body.state
            widget.waiting = false
            widget.state_revision = (math.tointeger(widget.state_revision) or 0) + 1
            reply({ok = true, revision = widget.state_revision}, to, topic)
            return true
        end

        -- A refused close (C2): the window's own process answers the `close`
        -- it got by staying — a changed document to save — and the request is
        -- over, with no "did not close" on the taskbar. The sender names the
        -- window: a cells window's runner does not know its id. Only that
        -- process may refuse; a given `id` must name the same window, and a
        -- forced close (shutdown) is not refused.
        if topic == "desktop.close" and body.refused == true then
            local own: any = nil
            for _, candidate in ipairs(windows) do
                if from ~= nil and ((candidate.pid ~= nil and tostring(candidate.pid) == tostring(from))
                    or (candidate.state_pid ~= nil and tostring(candidate.state_pid) == tostring(from))) then
                    own = candidate
                    break
                end
            end
            if own == nil or (type(body.id) == "string" and body.id ~= "" and body.id ~= own.id) then
                return refuse("only a window's own process may refuse its close", to, topic, from)
            end
            if own.close_how == "force" then
                return refuse("a forced close is not refused", to, topic, from)
            end
            own.closing = false
            own.close_how = nil
            own.deadline = nil
            reply({ok = true}, to, topic)
            return true
        end

        if not WINDOW_COMMANDS[topic] then
            return refuse("unknown command " .. tostring(topic), to, topic, from)
        end
        if not window then
            -- Молчаливое «нет такого» превратило бы опечатку в id в успешную
            -- команду.
            return refuse("no window " .. tostring(body.id), to, topic, from)
        end

        if topic == "desktop.close" then
            -- A request unless the sender says `force`: a window may refuse a
            -- request (it answers the `close` it gets by not closing).
            close_window(window, body.force == true and "force" or "request")
            reply({ok = true}, to, topic); return true
        elseif topic == "desktop.focus" then
            window.minimized = false; raise(window); reply({ok = true}, to, topic); return true
        elseif topic == "desktop.move" then
            window.x = clamp(body.x, 1, math.max(1, width - window.w + 1))
            window.y = clamp(body.y, desktop_top, math.max(desktop_top, height - window.h))
            reply({ok = true, window = describe(window)}, to, topic)
            return true
        elseif topic == "desktop.resize" then
            if window.resizable == false then
                return refuse("window " .. window.id .. " declared a fixed size",
                    to, topic, from)
            end
            resize_window(window, body.w, body.h)
            reply({ok = true, window = describe(window)}, to, topic)
            return true
        elseif topic == "desktop.minimize" then
            window.minimized = not not body.value
            reply({ok = true, window = describe(window)}, to, topic)
            return true
        elseif topic == "desktop.state" then
            -- Состояние принимается ТОЛЬКО от поставщика этого окна. Иначе
            -- содержимое чужого окна мог бы подменить любой, кто знает номер,
            -- — а вид, нарисованный подложенными данными, от настоящего
            -- неотличим.
            if window.content ~= "pixels" then
                return refuse("window " .. window.id .. " draws itself; it takes no state",
                    to, topic, from)
            end
            if window.state_pid == nil or from == nil
                or tostring(window.state_pid) ~= tostring(from) then
                return refuse("the state of window " .. window.id
                    .. " is accepted only from its provider", to, topic, from)
            end
            window.content_state = body.state
            if type(body.title) == "string" and body.title ~= "" then window.title = body.title end
            -- The title-bar picture, the same way: a name replaces it, no name
            -- (or an empty one) keeps the one the window has.
            if type(body.image) == "string" and body.image ~= "" then window.image = body.image end
            window.waiting = false
            window.state_revision = (math.tointeger(window.state_revision) or 0) + 1
            reply({ok = true, revision = window.state_revision}, to, topic)
            return true
        elseif topic == "desktop.screen" then
            -- Копия, а не сам массив: строки снимка — общая память брокера.
            local rows = {}
            for index, row in ipairs(window.rows) do rows[index] = row end
            reply({ok = true, id = window.id, rows = rows, ready = window.ready}, to, topic)
            return false
        elseif topic == "desktop.type" then
            if not window.ready then
                return refuse("window " .. window.id .. " does not take input yet", to, topic, from)
            end
            local sent = 0
            for _, char in ipairs(runes(type(body.text) == "string" and body.text or "")) do
                if send_to(window, {type = "key", key = char, key_type = "runes", action = "press"}) then
                    sent = sent + 1
                end
            end
            if body.enter then
                send_to(window, {type = "key", key = "enter", key_type = "enter", action = "press"})
            end
            reply({ok = true, sent = sent}, to, topic)
            return false
        elseif topic == "desktop.key" then
            local key = type(body.key) == "string" and body.key or ""
            if key == "" then return refuse("key not named", to, topic, from) end
            local ok = send_to(window, {
                type = "key", key = key, key_type = body.key_type or key,
                action = "press", ctrl = not not body.ctrl,
                alt = not not body.alt, shift = not not body.shift,
            })
            if not ok then return refuse("window " .. window.id .. " did not take the input", to, topic, from) end
            reply({ok = true}, to, topic)
            return false
        end

        -- Досюда доходит только команда окна, которую забыли разобрать выше:
        -- список WINDOW_COMMANDS и ветки обязаны совпадать.
        return refuse("command " .. tostring(topic) .. " is declared but not handled", to, topic, from)
    end

    -- ─── цикл ────────────────────────────────────────────────────────────

    local function tick_clock()
        local now = time.now()
        local text = now and now:format("15:04") or ""
        if text == clock then return false end
        clock = text
        return true
    end

    tick_clock()
    reload_desktop()
    -- After logon (above): a widget's process runs under the user, like a window.
    sync_widgets()
    draw()

    local ticker = time.after(CLOCK_TICK)

    while true do
        local cases = {
            events:case_receive(),
            lifecycle:case_receive(),
            inbox:case_receive(),
            ticker:case_receive(),
        }
        if hover_timer then cases[#cases + 1] = hover_timer:case_receive() end
        if frame_gate.timer then cases[#cases + 1] = frame_gate.timer:case_receive() end
        local watched = {}
        for _, window in ipairs(windows) do
            -- У окна-вида кадров нет: их некому публиковать.
            if window.updates then
                cases[#cases + 1] = window.updates:case_receive()
                watched[#watched + 1] = window
            end
            if window.deadline then
                if not window.updates then watched[#watched + 1] = window end
                cases[#cases + 1] = window.deadline:case_receive()
            end
        end

        local selected = channel.select(cases)
        if not selected.ok then break end
        -- Причина кадра: каждая ветка ниже называет себя, `draw` её пишет в
        -- цену. «unknown» в статусе — ветка, которую забыли назвать.
        meter.trigger, meter.snapshot_ms = "unknown", nil

        -- Тик часов не событие окна: он ничего не пересылает, только
        -- обновляет кадр, если минута сменилась.
        local handled = false
        if selected.channel == ticker then
            meter.trigger = "tick"
            ticker = time.after(CLOCK_TICK)
            -- Оба вопроса задаются всегда: `a() or b()` не спросил бы трей в
            -- ту минуту, когда сменились часы.
            local ticked = tick_clock()
            local pruned = prune_tray()
            if ticked or pruned then draw() end
            handled = true
        end
        -- The owed frame: every request since the last one, painted once.
        if frame_gate.timer ~= nil and selected.channel == frame_gate.timer then
            frame_gate.timer = nil
            meter.trigger = "batch:" .. tostring(frame_gate.merged)
            if frame_gate.dirty then draw_now() end
            handled = true
        end
        if hover_timer ~= nil and selected.channel == hover_timer then
            meter.trigger = "hover"
            settle_hover()
            handled = true
        end

        -- Кадр окна. Уведомление — водяной знак, а не кадр: состояние
        -- всегда берётся снимком.
        for _, window in ipairs(watched) do
            if selected.channel == window.updates then
                meter.trigger = "pty:" .. tostring(window.id)
                local asked = time.now():unix_nano()
                local snapshot = window.view:snapshot(window.revision)
                meter.snapshot_ms = round_ms((time.now():unix_nano() - asked) / 1000000)
                if snapshot then
                    window.rows = snapshot.rows
                    window.cursor = snapshot.cursor
                    window.revision = snapshot.revision
                    window.ready = true
                    if not window.minimized then draw() end
                end
                handled = true
                break
            end
            if window.deadline and selected.channel == window.deadline then
                meter.trigger = "deadline"
                window.deadline = nil
                -- One way to force: `close_how`. Shutdown sets it on every
                -- window, a pending request included (`close_window` raises it).
                if window.close_how == "force" then
                    process.terminate(tostring(window.state_pid or window.pid))
                else
                    -- A request the window did not answer by closing: it
                    -- refused (a document to save) or it hangs. Either way it
                    -- stays, and says so — killing it would lose the document,
                    -- and a silent stay would read as a dead ×.
                    window.closing = false
                    window.close_how = nil
                    notice = tostring(window.title or window.id) .. " did not close"
                    draw()
                end
                handled = true
                break
            end
        end

        if not handled then
            if selected.channel == inbox then
                local message = selected.value
                if message then
                    meter.trigger = "command:" .. tostring(message:topic())
                    local body = unwrap(message:payload())
                    -- Отправитель нужен, чтобы связать диалог с его окном:
                    -- в теле такой связи верить нельзя.
                    if handle_command(message:topic(), body, message:from()) then draw() end
                end
            elseif selected.channel == lifecycle then
                local event = selected.value
                meter.trigger = "exit"
                if event.kind == process.event.CANCEL then
                    -- Asked to finish: the remote terminal left (terminal.ssh)
                    -- or the runtime is stopping. Shut down as "Shut Down"
                    -- does: the windows are closed, not left orphaned.
                    meter.trigger = "cancel"
                    -- The terminal may already be gone: the cleanup below
                    -- must not fail on it.
                    terminal_state.cancelled = true
                    if not quitting then
                        request_quit()
                        draw()
                    end
                    if #windows == 0 then break end
                end
                if event.kind == process.event.EXIT then
                    local gone = tostring(event.from)
                    -- A widget's process: the last tree stays, the theme says
                    -- "stopped" over it, and `desktop.refresh` spawns it again.
                    local widget_stopped = false
                    for _, item in ipairs(widgets.items) do
                        if item.pid ~= nil and tostring(item.pid) == gone then
                            stop_widget(item)
                            widget_stopped = true
                            break
                        end
                    end
                    for index = #windows, 1, -1 do
                        if widget_stopped then break end
                        local window = windows[index]
                        if window == nil then break end
                        if window.pid ~= nil and tostring(window.pid) == gone then
                            forget(window)
                            break
                        end
                        -- Умер поставщик состояния: окно-вид остаётся, но
                        -- рисовать его больше нечем — и об этом надо сказать.
                        -- Вид, застывший на последнем состоянии, выглядит
                        -- живым и врёт тем убедительнее, чем дольше висит.
                        if window.state_pid ~= nil and tostring(window.state_pid) == gone then
                            if window.closing then forget(window); break end
                            window.state_pid = nil
                            window.waiting = true
                            window.ready = false
                            notice = "the state provider of window " .. window.id .. " stopped"
                            log:warn("state provider stopped",
                                {window = window.id, entry = tostring(window.state_ref)})
                            break
                        end
                    end
                    draw()
                    if quitting and #windows == 0 then break end
                end
            else
                local event = selected.value
                -- resize / mouse / key / paste…: вид события и есть причина.
                meter.trigger = tostring(event.type)
                if event.type == "resize" then
                    -- Font zoom changes pixels per cell independently of the
                    -- grid. Refresh the theme before its layout/insets, then
                    -- resize every client and rebuild rasters at native size.
                    local refreshed, refresh_error = refresh_cell_size()
                    if refreshed then refresh_frame()
                    else notice = "cell size not refreshed: " .. tostring(refresh_error) end
                    -- Ресайз тоже приходит с нулями, когда терминал исчез;
                    -- нулевой холст уронил бы композитор вместе со всеми окнами.
                    local w = math.floor(tonumber(event.width) or 0)
                    local h = math.floor(tonumber(event.height) or 0)
                    if w >= MIN_SCREEN_W then width = w end
                    if h >= MIN_SCREEN_H then height = h end
                    canvas = tty.canvas(width, height)
                    apply_layout()
                    arrange_desktop()
                    for _, window in ipairs(windows) do
                        if window.maximized then
                            window.x, window.y = 1, desktop_top
                            resize_window(window, width, desktop_height())
                        else
                            resize_window(window, window.w, window.h)
                        end
                    end
                    -- A widget keeps its cells, but the pixels of a cell may
                    -- have changed with the font.
                    for _, item in ipairs(widgets.items) do tell_widget_size(item) end
                    out:invalidate()
                    draw()
                elseif event.type == "mouse" then
                    -- A press or a release is aimed at what is on screen: an
                    -- owed frame is painted first, so the hits are its.
                    -- Motion and the wheel stay batched.
                    if event.action ~= "motion" and event.action ~= "wheel" then flush() end
                    handle_mouse(event)
                    if quitting and #windows == 0 then break end
                elseif event.type == "key" then
                    -- An open menu's keys read the painted menu (its hits
                    -- carry the marked row): its owed frame first. A key for a
                    -- window needs no frame — and one squeezed in before it put
                    -- a focus report into the window's pty just ahead of the key.
                    if menu ~= nil then flush() end
                    local verdict = handle_key(event)
                    if verdict == "quit" or (quitting and #windows == 0) then break end
                    if verdict == "forward" and not quitting then
                        send_to(focused(), event)
                    end
                elseif event.type ~= "start" then
                    if not quitting then send_to(focused(), event) end
                end
            end
        end
        if terminal_state.lost and not quitting then
            log:warn("the terminal is gone; shutting the desktop down", {error = terminal_state.lost})
            request_quit()
        end
        if terminal_state.lost and #windows == 0 then break end
    end

    -- Прощание: «Теперь питание компьютера можно отключить». Рисует тема,
    -- если умеет (`chrome.farewell`), держится `chrome.FAREWELL_HOLD` секунд
    -- (по умолчанию пять), ввод за это время съедается — экран не для
    -- взаимодействия. Тема без прощания выходит сразу, как раньше.
    if farewell_wanted and not terminal_state.lost and #windows == 0 and type(chrome.farewell) == "function" then
        canvas:clear(" ")
        local painted = chrome.farewell(canvas, width, height)
        local images: any = nil
        if PIXELS and type(painted) == "table" then
            images = pixels.frame(canvas, painted)
        end
        assert(out:present(canvas:rows(), {images = images}))
        local hold = tonumber(chrome.FAREWELL_HOLD) or 5
        local deadline = time.after(string.format("%dms", math.floor(hold * 1000)))
        while true do
            local picked = channel.select({deadline:case_receive(), events:case_receive()})
            if not picked.ok or picked.channel == deadline then break end
        end
    end

    for _, window in ipairs(windows) do
        if window.view then window.view:close() end
        if window.state_pid then process.terminate(tostring(window.state_pid)) end
    end
    for _, item in ipairs(widgets.items) do
        if item.pid then process.terminate(tostring(item.pid)) end
    end
    process.registry.unregister(SERVICE_NAME)
    if terminal_state.lost or terminal_state.cancelled then
        -- Nothing to restore on a terminal that is gone — lost, or the
        -- reason for the cancel: every write fails, and the desktop ended
        -- as asked, not with an error.
        tty.mouse(false)
        out:close()
        tty.stop()
    else
        assert(tty.mouse(false))
        assert(out:close())
        assert(tty.stop())
    end
end

return {run = run}
