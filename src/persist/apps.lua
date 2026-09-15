-- A window built in the runtime, as a registry entry.
--
-- The one place that decides what the submitted code turns into: both the
-- workshop (when a window is built) and the loader (when it is brought back
-- after a restart) use it. Were these two builds to diverge, a window would
-- behave differently before and after a restart, and that is the worst kind
-- of divergence: it shows up a day later.

local registry = require("registry")

local apps = {}

apps.NAMESPACE = "windows.tui_desktop.apps"
apps.WINDOW_TYPE = "tui_desktop.window"
apps.POLICY = "windows.tui_desktop.security:app_window_scope"

-- What a window may require. The list is narrow on purpose: a window draws
-- itself and reads data, but does not spawn processes and does not go outside.
--
-- `env` was removed from here, and not out of caution: the window has no
-- `env.get` permission, and without the permission `env.get` does not refuse
-- loudly — it returns nil, and the neighbouring `or default` turns a
-- permission refusal into "the person assigned nothing".
-- Granting the permission would be worse: the window's code arrives over HTTP,
-- and the environment holds tokens. A refusal at build time names the module —
-- that is visible at once.
apps.ALLOWED_MODULES = {
    channel = true,
    time = true,
    tty = true,
    json = true,
    sql = true,
    -- Needed so that a window can ask the compositor to open a neighbouring
    -- window. The permissions are narrow: send a message and find the
    -- addressee, nothing more.
    process = true,
}

apps.DEFAULT_MODULES = {"channel", "time", "tty"}

-- The desktop library is attached to every window under this name; it cannot
-- be taken by a window's own import.
apps.DESKTOP_IMPORT = "windows.tui_desktop.desktop:window_api"
apps.WINDOW_TYPES = {app = true, dialog = true, tool = true}

-- The window's description beyond the code — what an entry from a file keeps
-- in meta and imports. Only known fields here: foreign ones do not silently
-- reach the entry.
--
--   imports      — {name = library id}: the shell's SDK, own libraries.
--   pixel_render — the pixel view library; pixel_state — the window itself.
--   image, icon, window_type, resizable, in_menu, order — as in an entry.
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

-- What in the description will not pass. Each refusal names the field and the
-- reason: a window with a dead import would be applied, get into the menu and
-- crash on the first open — when the reason is hardest to tie to the field.
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

-- prepare(body) -> window | nil, reason
--
-- One check for all of the workshop's inputs — HTTP and the MCP tool: two
-- parsings of one body would diverge on the very first new field.
function apps.prepare(body: any): (any, any)
    local given: any = type(body) == "table" and body or {}
    local name = type(given.name) == "string" and given.name or ""
    if not name:match("^[a-z][a-z0-9_]*$") then
        return nil, "name: lowercase Latin letters, digits and underscore, starting with a letter"
    end
    local source = type(given.source) == "string" and given.source or ""
    if source == "" then return nil, "source: the window code is required" end
    -- The process is started by the main method. An entry without it is
    -- applied silently and dies on the first open, with no explanation why.
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
        -- The "Start" menu folder, like `meta.group` of an entry from a file.
        -- Empty — the shell decides itself.
        group = type(given.group) == "string" and given.group or "",
        spec = apps.normalize_spec(given),
    }, nil
end

function apps.entry_id(name)
    return apps.NAMESPACE .. ":" .. name
end

-- A built window always carries tty and channel: without them it can neither
-- draw itself nor wait for an event, and would crash on its very first line —
-- after the person has already decided the window is created.
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
    -- `process` is added for the window itself, not for the library: the
    -- library declares its modules itself and works with them — that is how
    -- `desktop` reads the compositor's name with the `ctx` module, which is not
    -- in this list. A direct `process.send` call from the window's code would
    -- not build without this line.
    add("process")
    table.sort(out)
    return out
end

-- Modules that are requested but not allowed. The refusal must name them:
-- "the window does not work" without the module's name sends one looking for
-- the error in the window's code.
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
    -- The menu folder — as in an entry from a file, with the same field. An
    -- empty one is not written at all: "not named" and "named empty" are
    -- different answers for the shell, and the workshop must not decide for
    -- the window that it wants the root.
    if type(window.group) == "string" and window.group ~= "" then meta.group = window.group end

    -- The description beyond the code: the same fields and the same names as
    -- in an entry from a file, so the catalog and the theme recognize them
    -- without translation.
    local spec = apps.normalize_spec(window.spec)
    if spec.image then meta.image = spec.image end
    if spec.icon then meta.icon = spec.icon end
    if spec.window_type then meta.window_type = spec.window_type end
    if spec.resizable == false then meta.resizable = false end
    if spec.in_menu == false then meta.in_menu = false end
    if spec.order then meta.order = spec.order end
    -- Pixel view: the named library draws, the window itself publishes the
    -- state — as with the shell's SDK windows from files.
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

-- apply(window) -> (true, nil) | (nil, reason)
--
-- A repeated name is an update: `create` over a taken id refuses, and editing
-- a window would look like "the name is taken forever".
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

-- remove(name) -> (true, nil) | (nil, reason)
--
-- An entry that does not exist is a success: removal must lead to absence,
-- not argue about how the absence came about.
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
