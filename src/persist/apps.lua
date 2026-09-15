-- Окно, собранное в рантайме, как запись реестра.
--
-- Одно место, где решается, во что превращается присланный код: им пользуются
-- и мастерская (когда окно собирают), и загрузчик (когда его поднимают после
-- перезапуска). Разойдись эти две сборки — окно вело бы себя по-разному до и
-- после рестарта, а это худший вид расхождения: он проявляется через сутки.

local registry = require("registry")

local apps = {}

apps.NAMESPACE = "windows.tui_desktop.apps"
apps.WINDOW_TYPE = "tui_desktop.window"
apps.POLICY = "windows.tui_desktop.security:app_window_scope"

-- Что окну можно требовать. Список узкий нарочно: окно рисует себя и читает
-- данные, но не порождает процессов и не ходит наружу.
--
-- `env` отсюда убран, и не из осторожности: права `env.get` у окна нет, а без
-- права `env.get` не отказывает громко — он отдаёт nil, и соседнее `or
-- умолчание` превращает отказ по правам в «человек ничего не назначал».
-- Выдать право было бы хуже: код окна приезжает по HTTP, а в окружении лежат
-- токены. Отказ на сборке называет модуль по имени — это видно сразу.
apps.ALLOWED_MODULES = {
    channel = true,
    time = true,
    tty = true,
    json = true,
    sql = true,
    -- Нужен, чтобы окно могло попросить композитор открыть соседнее окно.
    -- Права при этом узкие: послать сообщение и найти адресата, не более.
    process = true,
}

apps.DEFAULT_MODULES = {"channel", "time", "tty"}

-- Библиотека десктопа подключается каждому окну под этим именем; занять его
-- своим импортом нельзя.
apps.DESKTOP_IMPORT = "windows.tui_desktop.desktop:window_api"
apps.WINDOW_TYPES = {app = true, dialog = true, tool = true}

-- Описание окна сверх кода — то, что у записи из файла лежит в meta и
-- imports. Здесь только известные поля: чужие не доезжают до записи молча.
--
--   imports      — {имя = id библиотеки}: SDK оболочки, свои библиотеки.
--   pixel_render — библиотека пиксельного вида; pixel_state — само окно.
--   image, icon, window_type, resizable, in_menu, order — как у записи.
function apps.normalize_spec(given: any): any
    local spec: any = type(given) == "table" and given or {}
    local out: any = {}
    if type(spec.imports) == "table" then
        local imports: any = {}
        local any = false
        for alias, id in pairs(spec.imports) do
            if type(alias) == "string" and type(id) == "string" and id ~= "" then
                imports[alias] = id
                any = true
            end
        end
        if any then out.imports = imports end
    end
    if type(spec.image) == "string" and spec.image ~= "" then out.image = spec.image end
    if type(spec.icon) == "string" and spec.icon ~= "" then out.icon = spec.icon end
    if type(spec.window_type) == "string" and apps.WINDOW_TYPES[spec.window_type] then
        out.window_type = spec.window_type
    end
    if spec.resizable == false then out.resizable = false end
    if spec.in_menu == false then out.in_menu = false end
    if type(spec.pixel_render) == "string" and spec.pixel_render ~= "" then
        out.pixel_render = spec.pixel_render
    end
    if type(spec.order) == "number" then out.order = spec.order end
    return out
end

-- Что в описании не пройдёт. Каждый отказ называет поле и причину: окно с
-- мёртвым импортом применилось бы, попало в меню и упало при первом
-- открытии — когда причину связать с полем труднее всего.
function apps.rejected_spec(given: any): any
    local out = {}
    local spec: any = type(given) == "table" and given or {}
    local function library(id: any, field: string)
        local entry: any = registry.get(tostring(id))
        if not entry then
            out[#out + 1] = field .. ": entry " .. tostring(id) .. " is not in the registry"
        elseif type(entry) == "table" and entry.kind ~= nil and entry.kind ~= "library.lua" then
            out[#out + 1] = field .. ": " .. tostring(id) .. " — not a library (" .. tostring(entry.kind) .. ")"
        end
    end
    if type(spec.imports) == "table" then
        for alias, id in pairs(spec.imports) do
            local name = tostring(alias)
            if not name:match("^[a-z_][a-z0-9_]*$") then
                out[#out + 1] = "imports: name " .. name .. " — lowercase Latin letters, digits and underscore"
            elseif name == "desktop" then
                out[#out + 1] = "imports: the name desktop is taken by the desktop library"
            elseif type(id) ~= "string" or id == "" then
                out[#out + 1] = "imports: " .. name .. " has no entry id"
            else
                library(id, "imports")
            end
        end
    end
    if spec.window_type ~= nil and not apps.WINDOW_TYPES[tostring(spec.window_type)] then
        out[#out + 1] = "window_type: app, dialog or tool"
    end
    if spec.pixel_render ~= nil then
        if type(spec.pixel_render) ~= "string" or spec.pixel_render == "" then
            out[#out + 1] = "pixel_render: the id of a view library"
        else
            library(spec.pixel_render, "pixel_render")
        end
    end
    return out
end

-- prepare(body) -> окно | nil, причина
--
-- Одна проверка на все входы мастерской — HTTP и туз MCP: два разбора одного
-- тела разошлись бы на первом же новом поле.
function apps.prepare(body: any): (any, any)
    local given: any = type(body) == "table" and body or {}
    local name = type(given.name) == "string" and given.name or ""
    if not name:match("^[a-z][a-z0-9_]*$") then
        return nil, "name: lowercase Latin letters, digits and underscore, starting with a letter"
    end
    local source = type(given.source) == "string" and given.source or ""
    if source == "" then return nil, "source: the window code is required" end
    -- Процесс запускается методом main. Запись без него применится молча и
    -- умрёт при первом открытии, уже без объяснения причины.
    if not source:find("main", 1, true) then
        return nil, "source: the code must return a table with a main function"
    end
    local refused = apps.rejected_modules(given.modules)
    if #refused > 0 then return nil, "modules: unavailable — " .. table.concat(refused, ", ") end
    local spec_refused = apps.rejected_spec(given)
    if #spec_refused > 0 then return nil, table.concat(spec_refused, "; ") end
    return {
        name = name,
        title = type(given.title) == "string" and given.title ~= "" and given.title or name,
        width = tonumber(given.width) or 40,
        height = tonumber(given.height) or 12,
        source = source,
        modules = apps.normalize_modules(given.modules),
        -- Папка меню «Пуск», как `meta.group` у записи из файла. Пусто —
        -- оболочка решает сама.
        group = type(given.group) == "string" and given.group or "",
        spec = apps.normalize_spec(given),
    }, nil
end

function apps.entry_id(name)
    return apps.NAMESPACE .. ":" .. name
end

-- Собранное окно всегда несёт tty и channel: без них оно не сможет ни
-- нарисоваться, ни дождаться события, и упадёт на первой же строке — уже
-- после того, как человек решит, что окно создано.
function apps.normalize_modules(requested)
    local seen, out = {}, {}
    local function add(name: any)
        if type(name) == "string" and apps.ALLOWED_MODULES[name] and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    for _, name in ipairs(type(requested) == "table" and requested or {}) do add(name) end
    add("channel")
    add("tty")
    -- `process` добавляется ради самого окна, а не ради библиотеки: она
    -- объявляет свои модули сама и работает с ними — так `desktop` читает имя
    -- композитора модулем `ctx`, которого в этом списке нет. Прямой вызов
    -- `process.send` из кода окна без этой строки не собрался бы.
    add("process")
    table.sort(out)
    return out
end

-- Модули, которые запрошены, но не разрешены. Отказ обязан называть их:
-- «окно не работает» без имени модуля отправляет искать ошибку в коде окна.
function apps.rejected_modules(requested)
    local out = {}
    for _, name in ipairs(type(requested) == "table" and requested or {}) do
        if type(name) ~= "string" or not apps.ALLOWED_MODULES[name] then
            out[#out + 1] = tostring(name)
        end
    end
    return out
end

function apps.build_entry(window)
    local meta: any = {
        type = apps.WINDOW_TYPE,
        title = window.title,
        width = window.width,
        height = window.height,
        comment = "Built in the runtime; the source is stored in windows_tui_desktop_windows.",
    }
    -- Папка меню — как у записи из файла, тем же полем. Пустая не пишется
    -- вовсе: «не названа» и «названа пустой» для оболочки разные ответы,
    -- и решать за окно, что оно хочет на корень, мастерская не должна.
    if type(window.group) == "string" and window.group ~= "" then meta.group = window.group end

    -- Описание сверх кода: те же поля и те же имена, что у записи из файла,
    -- поэтому каталог и тема узнают их без перевода.
    local spec = apps.normalize_spec(window.spec)
    if spec.image then meta.image = spec.image end
    if spec.icon then meta.icon = spec.icon end
    if spec.window_type then meta.window_type = spec.window_type end
    if spec.resizable == false then meta.resizable = false end
    if spec.in_menu == false then meta.in_menu = false end
    if spec.order then meta.order = spec.order end
    -- Пиксельный вид: рисует названная библиотека, состояние публикует само
    -- окно — как у окон SDK оболочки из файлов.
    if spec.pixel_render then
        meta.pixel_render = spec.pixel_render
        meta.pixel_state = apps.entry_id(window.name)
    end
    local imports: any = {desktop = apps.DESKTOP_IMPORT}
    for alias, id in pairs(spec.imports or {}) do imports[alias] = id end

    return {
        id = apps.entry_id(window.name),
        kind = "process.lua",
        meta = meta,
        data = {
            source = window.source,
            method = "main",
            modules = apps.normalize_modules(window.modules),
            imports = imports,
            security = {policies = {apps.POLICY}},
        },
    }
end

-- apply(window) -> (true, nil) | (nil, причина)
--
-- Повторное имя — обновление: `create` поверх занятого id отказывается, и
-- правка окна выглядела бы как «имя занято навсегда».
function apps.apply(window)
    local snapshot, serr = registry.snapshot()
    if not snapshot then return nil, "registry snapshot: " .. tostring(serr) end

    local entry = apps.build_entry(window)
    local changes = snapshot:changes()
    if registry.get(entry.id) then
        changes:update(entry)
    else
        changes:create(entry)
    end

    local version, aerr = changes:apply()
    if not version then return nil, "applying the version: " .. tostring(aerr) end
    return true, nil
end

-- remove(name) -> (true, nil) | (nil, причина)
--
-- Запись, которой нет, — это успех: удаление должно приводить к отсутствию,
-- а не спорить о том, как отсутствие возникло.
function apps.remove(name)
    local id = apps.entry_id(name)
    if not registry.get(id) then return true, nil end

    local snapshot, serr = registry.snapshot()
    if not snapshot then return nil, "registry snapshot: " .. tostring(serr) end

    local changes = snapshot:changes()
    changes:delete(id)
    local version, aerr = changes:apply()
    if not version then return nil, "applying the version: " .. tostring(aerr) end
    return true, nil
end

return apps
