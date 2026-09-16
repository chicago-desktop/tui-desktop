-- What a registry entry says about its program.
--
-- The one place where a window's `meta` turns into the fields the mechanics
-- and the theme use: the window type, the "show in the menu" flag, the size
-- and the title. Were these reads scattered across the call sites, a default
-- would one day be computed differently in the menu and on opening, and the
-- same window would look like a dialog from "Start" and like an ordinary
-- window from the desktop.
--
-- Pure tables: not a single call into the runtime, so it is tested directly.

local programs = {}

-- The mark by which the compositor finds the application's windows in the registry.
programs.WINDOW_META_TYPE = "tui_desktop.window"

-- The window type chooses the set of title bar buttons for the theme. The
-- values are declared as a list, not derived from the entry's kind: the kind
-- belongs to the registry, the type to the shell.
programs.DEFAULT_TYPE = "app"
programs.TYPES = {app = true, dialog = true, tool = true}

-- What draws the window's content. The ENTRY declares it, rather than it being
-- inferred from who wrote the program inside: the next reader would infer it
-- differently.
--
-- The default is `cells`, and this is not a matter of taste. A foreign program
-- (bash, htop) can only output cells; a window whose entry says nothing about
-- this field must behave as before. Erring towards `cells` loses beauty;
-- erring towards `pixels` loses bash.
programs.DEFAULT_CONTENT = "cells"
programs.CONTENTS = {cells = true, pixels = true}

local function meta_of(record: any)
    local entry: any = type(record) == "table" and record or {}
    if type(entry.meta) == "table" then return entry.meta end
    if type(entry.data) == "table" and type(entry.data.meta) == "table" then return entry.data.meta end
    return {}
end

-- window_type(meta) -> type, unknown value or nil
--
-- An unknown type is `app` and a warning, not a refusal to show the program:
-- the entry was declared by someone else, and a typo in one field is no reason
-- to hide a window that is otherwise sound.
function programs.window_type(meta: any)
    if type(meta) ~= "table" then return programs.DEFAULT_TYPE, nil end
    local given: any = meta.window_type
    if type(given) ~= "string" or given == "" then return programs.DEFAULT_TYPE, nil end
    if programs.TYPES[given] then return given, nil end
    return programs.DEFAULT_TYPE, given
end

-- in_menu(meta) -> whether to show the program in the menu
--
-- Yes by default: the program to hide is the one that asked for it. The
-- string "false" counts as a refusal on par with the boolean: an entry arrives
-- both from YAML and from JSON, and a silent "a string is true" would show in
-- the menu exactly the windows that asked to be hidden.
-- Read as a field, not through `and … or`: for `false` that construct takes
-- the "no value" branch, that is, exactly the opposite answer — a hidden
-- program would end up in the menu.
function programs.in_menu(meta: any)
    if type(meta) ~= "table" then return true end
    local given: any = meta.in_menu
    if given == nil then return true end
    if given == false or given == "false" then return false end
    return true
end

-- content(meta) -> "cells" | "pixels", unknown value or nil
--
-- An unknown value is `cells` and a warning: a window that declared a typo
-- must open as an ordinary one, not disappear.
function programs.content(meta: any)
    if type(meta) ~= "table" then return programs.DEFAULT_CONTENT, nil end
    local given: any = meta.window_content
    if type(given) ~= "string" or given == "" then return programs.DEFAULT_CONTENT, nil end
    if programs.CONTENTS[given] then return given, nil end
    return programs.DEFAULT_CONTENT, given
end

-- resizable(meta) -> whether the window's size can be changed
--
-- Yes by default: a window with a fixed size is the one that asked for it. The
-- Calculator and a properties dialog in Windows 95 do not stretch by the
-- corner and do not maximize: their layout is computed for one size, and a
-- stretched window would show a gray field around the buttons. The string
-- "false" counts as a refusal on par with the boolean — an entry arrives both
-- from YAML and from JSON.
function programs.resizable(meta: any)
    if type(meta) ~= "table" then return true end
    local given: any = meta.resizable
    if given == nil then return true end
    if given == false or given == "false" then return false end
    return true
end

local function reference(meta: any, field)
    if type(meta) ~= "table" then return nil end
    local given: any = meta[field]
    if type(given) ~= "string" or given == "" then return nil end
    return given
end

-- item(record) -> catalog item or nil
--
-- nil means "this is not a program": an entry without an id has nothing to open it by.
function programs.item(record: any)
    local entry: any = type(record) == "table" and record or {}
    local id = entry.id
    if type(id) ~= "string" or id == "" then return nil, nil end

    local meta = meta_of(entry)
    local window_type, unknown = programs.window_type(meta)
    local content, odd_content = programs.content(meta)
    return {
        entry = id,
        title = type(meta.title) == "string" and meta.title ~= "" and meta.title or id,
        w = tonumber(meta.width),
        h = tonumber(meta.height),
        window_type = window_type,
        in_menu = programs.in_menu(meta),
        presentation = meta.presentation == true,
        -- What draws the content and what it lives on. `render` is a pure
        -- drawing library, `state` is a provider process with its own actor:
        -- drawing in the compositor, permissions outside.
        content = content,
        render = reference(meta, "render"),
        state = reference(meta, "state"),
        pixel_render = reference(meta, "pixel_render"),
        pixel_state = reference(meta, "pixel_state"),
        image = reference(meta, "image"),
        -- The fixed size is declared by the entry, not by whoever opens it:
        -- otherwise the same calculator would stretch when opened from the
        -- menu and not stretch when opened from a shortcut.
        resizable = programs.resizable(meta),
        -- Which extensions the program opens (`meta.opens: [txt, png]`).
        -- It reaches the item as is: the type registry is assembled by the
        -- shell, and an item that lost this field would leave the explorer
        -- without associations.
        opens = type(meta.opens) == "table" and meta.opens or nil,
    }, unknown or odd_content
end

-- menu(records) -> menu items, warnings
--
-- Items are sorted by title, hidden ones are dropped. Warnings are a list of
-- {entry, window_type} with unknown types: they do not prevent showing the
-- program, but they must be named, otherwise a typo in a declaration lives
-- forever.
function programs.menu(records: any)
    local items, warnings = {}, {}
    for _, record in ipairs(type(records) == "table" and records or {}) do
        local item, unknown = programs.item(record)
        if item then
            if unknown then
                warnings[#warnings + 1] = {entry = item.entry, window_type = unknown}
            end
            if item.in_menu then items[#items + 1] = item end
        end
    end
    table.sort(items, function(left, right) return left.title < right.title end)
    return items, warnings
end

return programs
