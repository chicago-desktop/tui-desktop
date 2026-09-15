-- A raster theme for the checks: the same shape as the real one, but without graphics.
--
-- Placements arrive WITHOUT a raster — the surface allows that ("the picture is
-- already on screen, leave it as is"), and that is exactly why the compositor's
-- pixel path is checked on a runtime that has no gfx module at all. Everything
-- that belongs to the compositor is checked this way: blanks under pictures,
-- window contents in characters and the hit layout.

local chrome = {}

chrome.pixel = true
local custom_insets = false
local zoom_cell: any = nil
function chrome.configure_cell_size(w, h)
    zoom_cell = {w = w, h = h}
end
function chrome.configure_insets()
    custom_insets = true
end

function chrome.window_background(canvas, window)
    if custom_insets then canvas:put(window.x + 2, window.y + 3, "BACKGROUND", 10) end
end

function chrome.layout(width, height)
    if zoom_cell then return {top = 1, bottom = math.ceil(28 / zoom_cell.h)} end
    return {top = 1, bottom = 1}
end

function chrome.window_insets()
    if zoom_cell then return {top = math.ceil(20 / zoom_cell.h), bottom = 1, left = 1, right = 1} end
    if custom_insets then return {top = 3, bottom = 1, left = 2, right = 1} end
    return {top = 1, bottom = 1, left = 1, right = 1}
end

function chrome.icon_grid()
    return {w = 12, h = 4, left = 2}
end

-- This theme has no title buttons: the checks need no clicks on the title,
-- and a silent nil is more honest than an invented table.
function chrome.title_button_at(window, x: any, y: any)
    return nil
end

-- An icon gives TWO hit rows — the picture and the label, as in the real
-- theme. The compositor must merge them into one icon: otherwise the down
-- arrow would move from the picture onto its own label.
local function icon_hits(state: any): any
    local hits = {}
    for _, item in ipairs(state.items or {}) do
        local x = math.tointeger(item.x) or 1
        local y = math.tointeger(item.y) or 1
        for line = 0, 1 do
            hits[#hits + 1] = {
                row = y + line, from = x, to = x + 9,
                id = item.id, entry = item.entry, title = item.title,
                w = item.w, h = item.h, args = item.args,
            }
        end
    end
    return hits
end

-- Desktop widgets (FR-006): a column at the right edge, the first on the
-- icons' first row, one empty row between them. The layout is this test's;
-- the real one is the shell's. Exposed so the cell test theme stands its
-- widgets on the same cells.
function chrome.widget_rects(width: any, state: any): any
    local rects = {}
    local y = (math.tointeger(state.top) or 1) + 2
    local list: any = type(state.widgets) == "table" and state.widgets or {}
    for _, widget in ipairs(list) do
        local w = math.tointeger(widget.w) or 1
        local h = math.tointeger(widget.h) or 1
        rects[#rects + 1] = {widget = widget, x = (math.tointeger(width) or 80) - w + 1, y = y, w = w, h = h}
        y = y + h + 1
    end
    return rects
end

-- One hit record per widget row: the icon-row shape plus `widget = <id>`,
-- with `entry` naming what a click opens (FR-006 §5). `with_id` adds an id,
-- as a theme may: the compositor must still not take a widget for an icon.
function chrome.widget_hits(width: any, state: any, with_id: boolean): any
    local hits = {}
    for _, rect in ipairs(chrome.widget_rects(width, state)) do
        for line = 0, rect.h - 1 do
            hits[#hits + 1] = {
                row = rect.y + line, from = rect.x, to = rect.x + rect.w - 1,
                widget = rect.widget.id, entry = rect.widget.opens, title = rect.widget.title,
                id = with_id and ("widget:" .. tostring(rect.widget.id)) or nil,
            }
        end
    end
    return hits
end

-- Everything the theme was given about each widget, one line per widget from
-- row WIDGET_MARK_ROW down: the screen is the only place the theme's state
-- can be read from outside the compositor. Row 14, because the stock cell
-- theme writes its empty-desktop hint on the middle row (12 of 24). `note` is
-- what the widget's process published; the last field is its life.
chrome.WIDGET_MARK_ROW = 14
function chrome.mark_widgets(canvas: any, state: any)
    local list: any = type(state.widgets) == "table" and state.widgets or {}
    for index, widget in ipairs(list) do
        local published: any = widget.content_state
        local note = type(published) == "table" and published.note or "-"
        local life = widget.stopped == true and "stopped" or (widget.waiting == true and "waiting" or "live")
        local text = "W" .. index .. ":" .. tostring(widget.id)
            .. "|" .. tostring(widget.w) .. "x" .. tostring(widget.h)
            .. "|" .. tostring(widget.title) .. "|" .. tostring(widget.opens)
            .. "|" .. tostring(note) .. "|" .. life
        canvas:put(2, chrome.WIDGET_MARK_ROW + index - 1, text, 58)
    end
end

-- The desktop fill is in CELLS, in pixel mode too: otherwise the desktop shows
-- through the window body wherever the program inside wrote nothing, and the
-- desktop itself relies on the terminal's colour instead of its own.
function chrome.fill(canvas: any, width, height, state: any)
    local row = string.rep("▒", math.tointeger(width) or 0)
    for line = math.tointeger(state.top) or 1, math.tointeger(state.bottom) or 1 do
        canvas:put(1, line, row, width)
    end
    chrome.mark_widgets(canvas, state)
    return icon_hits(state)
end

-- The Start button on the taskbar and the row the menu starts at. The numbers
-- are pulled out because the check clicks by them too: if they drifted apart
-- they would give "the click did not work" instead of an honest refusal.
chrome.MENU_BUTTON = {from = 60, to = 70}
chrome.MENU_ROW = 6
chrome.FOLDER = "Programs"

-- One piece for each window's title and one for the taskbar — the same as the
-- real one will have: cut by rows, so that typing in a window does not
-- resend the whole chrome.
function chrome.paint(state: any, cell_w, cell_h)
    if zoom_cell then
        assert(cell_w == zoom_cell.w and cell_h == zoom_cell.h,
            "paint received stale cell dimensions after font zoom")
    end
    local placements, slots, choices = {}, {}, {}

    for index, window in ipairs(state.windows) do
        placements[#placements + 1] = {
            id = "win:" .. tostring(window.id) .. ":title",
            x = window.x, y = window.y, cols = window.w, rows = 1,
        }
        -- The window's taskbar button: ten cells per window.
        slots[#slots + 1] = {
            row = state.height, from = index * 10 - 9, to = index * 10,
            id = window.id,
        }
    end

    placements[#placements + 1] = {
        id = "taskbar", x = 1, y = state.height, cols = state.width, rows = 1,
    }

    -- The menu button is the same kind of bar hit, only with an action instead
    -- of a window number.
    slots[#slots + 1] = {
        row = state.height, from = chrome.MENU_BUTTON.from,
        to = chrome.MENU_BUTTON.to, action = "menu",
    }

    if chrome.clock_entry then
        slots[#slots + 1] = {row = state.height, from = 73, to = 80, entry = chrome.clock_entry}
    end

    -- The menu is drawn only when the compositor says it is open: its state
    -- is held by the mechanics, and the theme only shows it.
    if state.menu then
        local items: any = state.menu.items or {}
        local open: any = state.menu.open or {}
        local at = math.tointeger(state.menu.cursor) or 1
        placements[#placements + 1] = {
            id = "menu", x = 2, y = chrome.MENU_ROW,
            cols = 30, rows = math.max(1, #items + 1),
        }

        if type(state.menu.anchor) == "table" then
            -- An icon's context menu: a flat list at the anchor, no folder.
            placements[#placements].x = math.tointeger(state.menu.anchor.x) or 2
            placements[#placements].y = math.tointeger(state.menu.anchor.y) or chrome.MENU_ROW
            for index in ipairs(items) do
                choices[#choices + 1] = {
                    row = chrome.MENU_ROW + index - 1, from = 2, to = 31, index = index,
                    level = 1, slot = index, cursor = at == index,
                }
            end
        elseif #open == 0 then
            -- The root panel: the FOLDER first, then the programs. The folder
            -- carries the whole path — the compositor does not remember the tree
            -- and opens what it is given.
            choices[#choices + 1] = {
                row = chrome.MENU_ROW, from = 2, to = 31,
                open = {chrome.FOLDER}, level = 1, slot = 1, cursor = at == 1,
            }
            for index in ipairs(items) do
                choices[#choices + 1] = {
                    row = chrome.MENU_ROW + index, from = 2, to = 31, index = index,
                    level = 1, slot = index + 1, cursor = at == index + 1,
                }
            end
        else
            -- An opened folder is the second panel: the cursor moves over it
            -- because its `level` is higher. The root panel does NOT disappear
            -- meanwhile — as in the real theme: its rows stay hits without a
            -- cursor, and hovering over them closes the submenu.
            choices[#choices + 1] = {
                row = chrome.MENU_ROW, from = 2, to = 31,
                open = {chrome.FOLDER}, level = 1, slot = 1,
            }
            for index in ipairs(items) do
                choices[#choices + 1] = {
                    row = chrome.MENU_ROW + index, from = 2, to = 31, index = index,
                    level = 1, slot = index + 1,
                }
            end
            for index in ipairs(items) do
                choices[#choices + 1] = {
                    row = chrome.MENU_ROW + index - 1, from = 34, to = 63, index = index,
                    level = 2, slot = index, cursor = at == index,
                }
            end
        end
    end

    -- Two cell rows per target, but one keyboard choice per item.
    for _, hit in ipairs(slots) do
        hit.row = state.height - 1
        hit.bottom_row = state.height
    end
    for _, hit in ipairs(choices) do
        hit.row = chrome.MENU_ROW + (hit.row - chrome.MENU_ROW) * 2
        hit.bottom_row = hit.row + 1
    end

    -- Widget records exist only here, never in `fill`'s hits: a widget click
    -- that works in pixel mode proves `paint` got `state.widgets`. The icons
    -- come along, because the compositor takes `paint`'s desktop hits over
    -- `fill`'s whenever there are any.
    local desktop = {}
    local widget_rows = chrome.widget_hits(state.width, state, true)
    if #widget_rows > 0 then
        for _, hit in ipairs(icon_hits(state)) do desktop[#desktop + 1] = hit end
        for _, hit in ipairs(widget_rows) do desktop[#desktop + 1] = hit end
    end

    return {
        placements = placements,
        hits = {desktop = desktop, bars = slots, menu = choices},
    }
end

return chrome
