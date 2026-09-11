-- Что окно может попросить у десктопа.
--
-- Окно рисует себя и получает ввод, но соседями не распоряжается: чтобы
-- открыть, закрыть или поднять окно, оно просит об этом композитор — тот же
-- путь, которым ходит командный канал снаружи. Своего доступа к процессам и
-- программам у окна нет.
--
-- Библиотека существует, чтобы каждый виджет не переписывал протокол
-- сообщений заново: разойдись эти реализации, и половина окон однажды начала
-- бы слать команды, которых композитор уже не понимает.

local process = require("process")
local channel = require("channel")
local time = require("time")

-- Лог здесь не роскошь: `open` ответа не ждёт намеренно, и окно, которое не
-- проверило второе возвращаемое значение, иначе не расскажет об отказе никак.
-- Терминальный хост уводит лог в события, поэтому кадр он не разъезжает.
local logger = require("logger")
local log = logger:named("tui_desktop.window")

-- Имя композитора приезжает в контексте процесса: композитор кладёт его туда,
-- когда запускает окно. Ключ один на обе стороны — механика композитора
-- берёт его отсюда же, чтобы имя ключа не разошлось молча.
local CONTEXT_KEY = "tui_desktop.service"

-- Запасное имя — штатная оболочка. Окно, запущенное старым композитором или
-- чужим запуском, ведёт себя как раньше, а не падает.
local DEFAULT_SERVICE = "butschster.tui_desktop.desktop"

-- Модуль объявляет ЭТА библиотека, а не запись окна: библиотека получает свои
-- модули, поэтому окно, написанное до появления имени в контексте, работает
-- без единой правки. `require` недоступного модуля бросает, а окно не должно
-- умирать на первой строке из-за диагностики — отсюда pcall.
local has_ctx, ctx = pcall(require, "ctx")

local input = require("input")
local api = {}
api.normalize_event = input.normalize

api.CONTEXT_KEY = CONTEXT_KEY
api.DEFAULT_SERVICE = DEFAULT_SERVICE

-- Топик, на котором композитор отвечает. Одна константа на обе стороны:
-- механика берёт её отсюда же.
api.REPLY_TOPIC = "desktop.reply"

-- Сколько ждать ответа. Ожидание обязано кончаться: окно, которое ждёт вечно,
-- не рисуется и не принимает ввод, и снаружи это «зависло», а не «ждёт».
api.BUDGET = "5s"

-- service() -> имя композитора, откуда оно взято ("context" | "default")
--
-- Окну это знать незачем — оно зовёт open/close/focus. Наружу отдано ради
-- проверок и диагностики: «к кому обращается это окно» иначе не спросить.
function api.service()
    if has_ctx and type(ctx) == "table" then
        local name = ctx.get(CONTEXT_KEY)
        if type(name) == "string" and name ~= "" then return name, "context" end
    end
    return DEFAULT_SERVICE, "default"
end

-- Почему композитора не нашли. Отказ обязан назвать и имя, и то, откуда оно
-- взялось: молчание здесь и было исходным дефектом — под второй оболочкой
-- окно обращалось к несуществующему процессу, а `api.open` ответа не ждёт,
-- так что «успех» выглядел неотличимо от настоящего открытия.
local function unreachable(name, source, lerr)
    local reason = "desktop \"" .. name .. "\" does not answer (" .. tostring(lerr) .. ")"
    if source ~= "default" then return reason end
    if has_ctx then
        return reason .. "; the compositor's name did not arrive at start — the context has no key "
            .. CONTEXT_KEY .. ", so the fallback was taken"
    end
    return reason .. "; there is nothing to read the compositor's name with — the ctx module is unavailable, "
        .. "so the fallback was taken"
end

-- `service` — имя композитора, названное вызывающим. Нужно тому, у кого нет
-- контекста окна: сервис приложения, кладущий пункт в трей, композитором не
-- запускался и ключа в контексте не получил.
local function call(topic, body, service: string?)
    local name, source = api.service()
    if type(service) == "string" and service ~= "" then name, source = service, "argument" end
    local pid, lerr = process.registry.lookup(name)
    if not pid then
        local reason = unreachable(name, source, lerr)
        log:error("the window did not find its desktop",
            {service = name, source = source, topic = topic, error = reason})
        return nil, reason
    end
    local sent, serr = process.send(pid, topic, body or {})
    if not sent then
        return nil, "the command did not reach \"" .. name .. "\": " .. tostring(serr)
    end
    return true, nil
end

-- Ответ приезжает обёрнутым: payload — userdata, внутри бывает ещё и массив
-- из одного элемента. Поле, прочитанное напрямую, окажется nil без ошибки.
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

-- Канал ответов. Отдельная подписка на топик, а НЕ чтение общего inbox, и это
-- главное решение здесь.
--
-- Цикл, который ждёт ответ в inbox, забирает оттуда всё подряд и выбрасывает
-- чужое — измерено: команда `desktop.close`, посланная окну, пока оно ждало,
-- исчезала без следа, и снаружи это выглядело как окно, переставшее слушаться
-- мышь. Рантайм при этом ничего не терял сам: сообщение, которому некому
-- отдаться, ждёт в очереди процесса. Значит достаточно не забирать его —
-- ответ приходит своим каналом, чужая команда остаётся в inbox и дожидается
-- цикла окна.
local replies: any = nil

local function reply_channel()
    if replies then return replies, nil end
    -- Подписка создаётся ДО отправки вопроса: созданная после, она пропустила
    -- бы быстрый ответ в inbox, где его съел бы чужой цикл.
    local opened = process.listen(api.REPLY_TOPIC, {message = true})
    if not opened then return nil, "the window could not subscribe to the desktop's replies" end
    replies = opened
    return replies, nil
end

-- replies() -> канал ответов десктопа
--
-- Для окна со своим циклом это лучше, чем `ask`: оно кладёт канал в свой
-- `channel.select` рядом с событиями и inbox и не перестаёт рисоваться,
-- пока ждёт. `ask` удобнее, но на время ожидания окно не читает ни ввод, ни
-- команды — они дождутся его (проверено), но кадр в это время стоит.
function api.replies()
    local opened, err = reply_channel()
    return opened, err
end

-- Ответ, оставшийся от прошлого вопроса, или отказ, приехавший сам. Выбрасывается перед
-- новым вопросом: его никто не ждёт, а прочитанный как свежий он ответил бы на
-- прошлый вопрос вместо нынешнего. Выбросить ответ безопасно — в отличие от
-- команды, ради которой всё это и сделано.
local function drop_stale(ch)
    local dropped = 0
    while true do
        local picked = channel.select({ch:case_receive()}, true)
        if picked.default or not picked.ok then break end
        dropped = dropped + 1
    end
    return dropped
end

-- request(topic, body) -> true | nil, причина
--
-- Задать вопрос и не ждать: ответ приедет в `api.replies()`. Ровно это нужно
-- окну, которое рисует себя и не имеет права замирать.
function api.request(topic, body)
    local name, source = api.service()
    local pid, lerr = process.registry.lookup(name)
    if not pid then
        local reason = unreachable(name, source, lerr)
        log:error("the window did not find its desktop",
            {service = name, source = source, topic = topic, error = reason})
        return nil, reason
    end

    local ch, cerr = reply_channel()
    if not ch then return nil, tostring(cerr) end

    body = type(body) == "table" and body or {}
    body.reply_to = tostring(process.pid())

    local sent, serr = process.send(pid, topic, body)
    if not sent then
        return nil, "the question did not reach \"" .. name .. "\": " .. tostring(serr)
    end
    return true, nil
end

-- ask(topic, body, opts) -> ответ | nil, причина
--
-- opts.timeout — срок ожидания (по умолчанию api.BUDGET).
function api.ask(topic, body, opts)
    local options: any = type(opts) == "table" and opts or {}
    local budget = type(options.timeout) == "string" and options.timeout ~= ""
        and options.timeout or api.BUDGET

    local ch, cerr = reply_channel()
    if not ch then return nil, tostring(cerr) end

    local stale = drop_stale(ch)
    if stale > 0 then
        log:warn("dropped a reply nobody was waiting for",
            {topic = topic, dropped = stale})
    end

    local ok, rerr = api.request(topic, body)
    if not ok then return nil, rerr end

    local expiry = time.after(budget)
    while true do
        local picked = channel.select({ch:case_receive(), expiry:case_receive()})
        if picked.channel == expiry then
            local name = api.service()
            return nil, "desktop \"" .. name .. "\" did not answer within " .. budget
        end
        if not picked.ok then
            return nil, "the reply channel closed while waiting for the desktop"
        end

        local answer = unwrap(picked.value:payload())
        if answer.unsolicited then
            -- Отказ на команду, которой не ждали ответа: он приехал сам и
            -- ответом на ЭТОТ вопрос не является. Принять его за ответ значит
            -- соврать про другую команду — поэтому он только называется в
            -- логе, а ожидание продолжается.
            log:warn("the desktop refused a command sent without waiting",
                {command = tostring(answer.command), error = tostring(answer.error)})
        elseif type(answer.command) == "string" and answer.command ~= topic then
            log:warn("a reply to a different question",
                {asked = tostring(topic), answered = tostring(answer.command)})
        elseif answer.ok == false then
            return nil, tostring(answer.error or "the desktop refused without a reason")
        else
            return answer, nil
        end
    end
end

-- list(opts) -> {windows, focused, screen, restore} | nil, причина
function api.list(opts)
    local answer, err = api.ask("desktop.list", {}, opts)
    return answer, err
end

-- open{entry=…, title=…, args=…, x=…, y=…, w=…, h=…}
--
-- Ответа не ждём намеренно: окно рисует себя, и ожидание чужого ответа
-- заморозило бы кадр. Что окно открылось, видно на экране; что композитора не
-- нашли — видно во втором возвращаемом значении, и его стоит проверять.
function api.open(spec)
    spec = type(spec) == "table" and spec or {}
    return call("desktop.open", spec)
end

-- open_wait(spec, opts) -> описание открытого окна | nil, причина
--
-- То же, что `open`, но с ответом: в описании есть `id`, а без него окно не
-- может ни закрыть открытое, ни поднять его. Кадр на время ожидания стоит —
-- поэтому по умолчанию `open` остаётся тем, чем был.
function api.open_wait(spec, opts)
    local answer, err = api.ask("desktop.open", type(spec) == "table" and spec or {}, opts)
    if not answer then return nil, err end
    return answer.window, nil
end

-- dialog(spec, opts) -> описание диалога | nil, причина
--
-- Диалог принадлежит окну, которое его открыло: композитор узнаёт родителя по
-- отправителю, ставит диалог по центру своего окна, держит поверх него и
-- закрывает вместе с ним. Модальности нет намеренно: блокировать ввод
-- остальных окон там, где окно — чужой процесс, значит уметь подвесить весь
-- стол.
function api.dialog(spec, opts)
    local body: any = type(spec) == "table" and spec or {}
    body.window_type = "dialog"
    local answer, err = api.ask("desktop.open", body, opts)
    if not answer then return nil, err end
    return answer.window, nil
end

-- Отказ на команду без ожидания приезжает сюда же, помеченный `unsolicited`:
-- окно, которое держит канал в своём `select`, узнаёт, что `close` или `focus`
-- не выполнились, и не морозит себя ради этого. Окну, которое канал не
-- создавало, отказ приходит обычным сообщением в inbox.
function api.close(id)
    return call("desktop.close", {id = id})
end

function api.focus(id)
    return call("desktop.focus", {id = id})
end

-- State providers use the same owner and command channel as TTY windows.
-- No reply is requested for frames: feeding replies back into drawing would loop.
function api.publish_state(id, state: any)
    local ok, err = call("desktop.state", {id = id, state = state,
        title = type(state) == "table" and state.title or nil})
    return ok, err
end

-- tray{key=…, text=…, entry=…, title=…, ttl=…} [, service]
-- tray{key=…, remove=true} [, service]
--
-- Пункт области уведомлений у часов панели задач. Ключ выбирает поставщик:
-- тот же ключ обновляет пункт. `entry` — окно, которое откроет щелчок по
-- пункту (или поднимет уже открытое). `ttl` в секундах: пункт, который не
-- обновили за этот срок, композитор снимает сам — подпись, пережившая своего
-- поставщика, выдавала бы старое значение за нынешнее.
--
-- Ответа не ждёт, как `open`: отказ (нет ключа, трей полон) приезжает сам в
-- `api.replies()` с пометкой `unsolicited`, а без канала — в inbox.
function api.tray(spec, service: string?)
    local ok, err = call("desktop.tray", type(spec) == "table" and spec or {}, service)
    return ok, err
end

function api.inputs()
    local opened = process.listen("window.input", {message = true})
    return opened
end

function api.input_event(message: any)
    local body = unwrap(message:payload())
    return input.normalize(body.event)
end

return api
