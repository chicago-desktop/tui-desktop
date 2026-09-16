-- The compositor in pixel mode, brought up by the check.
--
-- The argument is "service|watcher|kind": the kind chooses what exactly is
-- checked — a working cell size, no answer from the terminal, or a theme without
-- chrome.paint. The composer's refusal goes to the watcher: `run` returns the
-- reason, and losing it here would mean checking silence with silence.
local process = require("process")
local library = require("library")
local pixel_chrome = require("pixel_chrome")
local cell_chrome = require("cell_chrome")
local flat_chrome = require("flat_chrome")
local widget_cells = require("widget_cells")
local channel = require("channel")
local time = require("time")
local security = require("security")

local function split(text)
    local out = {}
    for piece in tostring(text):gmatch("[^|]+") do out[#out + 1] = piece end
    return out
end

local function body_of(message: any)
    local body: any = message:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

-- The widgets the shell would list from the registry: two good ones out of
-- order and one too wide, which must be refused by its entry, not clamped.
local WIDGETS = {
    {entry = "app:widget_alpha", title = "Alpha", w = 20, h = 4, order = 20, opens = "app:menu_target"},
    {entry = "app:widget_beta", title = "Beta", w = 12, h = 3, order = 10},
    {entry = "app:widget_wide", title = "Too wide", w = 41, h = 4, order = 30},
}

local function main(args)
    local parts = split(args)
    local service, watcher, kind = parts[1], parts[2], parts[3] or "ok"

    -- The desktop layout: four icons in a two-by-two grid, the coordinates named
    -- explicitly — the check uses them too to work out where the arrow must go.
    local function desktop_items()
        return {
            {id = "i1", title = "First", entry = "app:menu_target", x = 2, y = 4, w = 20, h = 6},
            {id = "i2", title = "Second", entry = "app:menu_target", x = 14, y = 4, w = 20, h = 6},
            {id = "i3", title = "Third", entry = "app:menu_target", x = 2, y = 8, w = 20, h = 6},
            {id = "i4", title = "Fourth", entry = "app:menu_target", x = 14, y = 8, w = 20, h = 6},
        }, nil
    end

    local reads = {menu = 0}
    local options: any = {
        chrome = pixel_chrome,
        desktop_menu = function()
            reads.menu = reads.menu + 1
            local items = {{label = "Properties", entry = "app:menu_target"},
                {label = "Another module", entry = "app:menu_target"}}
            if reads.menu > 1 then items[#items+1] = {label = "Installed later", entry = "app:menu_target"} end
            return items
        end,
        service_name = service,
        pixels = true,
        restore = false,
        desktop_items = desktop_items,
    }

    if kind == "zoom" then
        local reads = 0
        options.cell_size = function()
            reads = reads + 1
            local sizes = {{10, 20}, {8, 18}, {12, 24}}
            local size = sizes[math.min(reads, #sizes)]
            pixel_chrome.configure_cell_size(size[1], size[2])
            return size[1], size[2]
        end
    elseif kind == "actions" then
        pixel_chrome.clock_entry = "app:view_window"
        options.cell_size = function() return 10, 20 end
        options.catalog = function()
            return {{title = "Shut Down", action = "quit"}}, nil
        end
    elseif kind == "insets" then
        pixel_chrome.configure_insets()
        options.cell_size = function() return 10, 20 end
    elseif kind == "ok" then
        options.cell_size = function() return 10, 20 end
    elseif kind == "silent" then
        -- Exactly what gfx.cell_size() answers on a terminal that stayed
        -- silent: nil and a reason.
        options.cell_size = function()
            return nil, "the terminal did not say how large a cell is"
        end
    elseif kind == "nothing" then
        options.cell_size = nil
    elseif kind == "flat" then
        options.chrome = flat_chrome
        options.cell_size = function() return 10, 20 end
    elseif kind == "cells_theme" then
        options.chrome = cell_chrome
        options.cell_size = function() return 10, 20 end
    elseif kind == "user" or kind == "admin" then
        -- Logged on at once: a person without rights of their own, or one
        -- whose scope allows a shell (`app:pty_allowed`).
        options.cell_size = function() return 10, 20 end
        options.logon = function()
            local policies: any = {}
            if kind == "admin" then
                local allowed, perr = security.policy("app:pty_allowed")
                if not allowed then return nil, "policy app:pty_allowed: " .. tostring(perr) end
                policies = {allowed}
            end
            return {
                actor = security.new_actor("test:desk-user"),
                scope = security.new_scope(policies),
                context = {user_id = "u1", user_name = "Tester"},
            }, nil
        end
    elseif kind == "widgets" then
        options.cell_size = function() return 10, 20 end
    elseif kind == "cells_widgets" then
        -- Cells mode with widgets: `fill` is called at the other place of
        -- the frame and must get `state.widgets` there too.
        options.chrome = widget_cells
        options.pixels = false
    end

    -- Widgets (FR-006): the list starts as WIDGETS and changes when the test
    -- sends `test.widgets` to this process before `desktop.refresh` — the
    -- only way to change from outside what `options.widgets` answers. The
    -- topic is listened to, so the compositor's inbox never sees it.
    if kind == "widgets" or kind == "cells_widgets" then
        local changes = process.listen("test.widgets", {message = true})
        local list: any = {current = WIDGETS}
        options.widgets = function()
            while true do
                local picked = channel.select({changes:case_receive(), time.after("50ms"):case_receive()})
                if not picked.ok or picked.channel ~= changes then break end
                local given: any = body_of(picked.value).widgets
                list.current = type(given) == "table" and given or {}
            end
            return list.current, nil
        end
    end

    local ok, err = library.run(options)
    if not ok then
        process.send(tostring(watcher), "composer.refused", {error = tostring(err)})
    end
    return ok, err
end

return {main = main}
