-- The compositor's theme: the only thing the compositor knows about the look.
--
-- The compositor calls only the contract's functions (README, "The look is
-- separate from the mechanics: the theme contract") and decides nothing
-- itself about borders, bars, or how many rows are taken at the top and
-- bottom. A second shell brings another theme and
-- gets another look without touching the window mechanics.
--
-- There is not a single call here that goes into the runtime: only strings and
-- arithmetic. So the file is a library, not a process, and it can be called
-- from any drawing.
--
-- A rule worth keeping in mind when editing: a window's border and content are
-- put on the canvas SEPARATELY. An attempt to merge them into one string means
-- clipping decisions that can no longer be made — the content arrives as
-- ready-made rows from someone else's process.

local tty = require("tty")

local chrome = {}

-- Buttons in the top right corner of the border. The order and width are set
-- here once: both drawing and mouse hits count by this same table, otherwise
-- the "close" button will one day end up one character to the left of where
-- it appears.
chrome.BUTTONS = {
    {id = "minimize", label = "[-]"},
    {id = "maximize", label = "[□]"},
    {id = "close",    label = "[×]"},
}
chrome.BUTTONS_WIDTH = 9  -- three buttons of three cells each

local BORDER = {
    top_left = "╭", top_right = "╮",
    bottom_left = "╰", bottom_right = "╯",
    horizontal = "─", vertical = "│",
}

local styles = {
    focused    = tty.style():foreground("81"),
    unfocused  = tty.style():foreground("240"),
    title      = tty.style():foreground("252"),
    title_dim  = tty.style():foreground("244"),
    button     = tty.style():foreground("245"),
    tab_active = tty.style():bold():foreground("#000000"):background("81"),
    tab_idle   = tty.style():foreground("250"):background("238"),
    bar        = tty.style():foreground("250"):background("236"),
    hint       = tty.style():faint(),
}

-- How many rows the chrome takes at the top and bottom. The desktop is rows
-- layout.top + 1 .. height - layout.bottom.
--
-- This number used to be a constant inside the compositor, and a taskbar at
-- the bottom could not be placed without editing the compositor: the base
-- would again know about the look.
function chrome.layout(width: any, height: any)
    return {top = 1, bottom = 1}
end

-- The desktop background and the icons on it. Neither is here: the canvas is
-- already cleared, and this shell shows no layout — windows are opened from
-- the catalog with alt+o. A theme with a teal desktop fills the background and
-- draws the icons itself, returning the hit layout; no answer reads as
-- "nothing to click on the desktop".
function chrome.fill(canvas, width: any, height: any, state)
end

-- clip(text, cells) — clip by CELLS, not by bytes.
--
-- `#string` counts bytes and does not see control sequences: on Cyrillic and
-- on styled text it is off two- and threefold.
local function clip(text, cells: any)
    local width = math.tointeger(cells) or 0
    if width <= 0 then return "" end
    return tty.text.truncate(text, width)
end

chrome.clip = clip

-- A window's title row: border, name, buttons.
--
-- Returns a ready string exactly `width` cells wide.
local function title_row(title, width: any, focused)
    if width <= 0 then return "" end
    if width == 1 then return BORDER.horizontal end
    if width == 2 then return BORDER.horizontal .. BORDER.horizontal end

    local border_style = focused and styles.focused or styles.unfocused
    local name_style = focused and styles.title or styles.title_dim

    local buttons = width >= chrome.BUTTONS_WIDTH + 6 and chrome.BUTTONS_WIDTH or 0
    -- Room for the name: the whole width minus the corners, minus the buttons,
    -- minus the spaces around the name and at least one border segment on the left.
    local room = width - 2 - buttons - 4
    local name = room > 0 and clip(title or "", room) or ""

    local parts = {border_style:render(BORDER.top_left .. BORDER.horizontal)}
    local used = 2

    if name ~= "" then
        parts[#parts + 1] = name_style:render(" " .. name .. " ")
        used = used + tty.text.width(name) + 2
    end

    local tail = width - used - buttons - 1
    if tail > 0 then
        parts[#parts + 1] = border_style:render(string.rep(BORDER.horizontal, tail))
    end

    if buttons > 0 then
        local labels = {}
        for _, button in ipairs(chrome.BUTTONS) do labels[#labels + 1] = button.label end
        parts[#parts + 1] = styles.button:render(table.concat(labels))
    end

    parts[#parts + 1] = border_style:render(BORDER.top_right)
    return table.concat(parts)
end

chrome.title_row = title_row

-- Draw a whole window: border, title, content.
--
-- `rows` is an array of strings as viewport:snapshot() returns it. It is shared
-- and immutable, so it is put as is: put_rows clips it to the width itself.
function chrome.window(canvas, window, focused)
    local x, y, w, h = window.x, window.y, window.w, window.h
    if w < 2 or h < 2 then return end

    local border_style = focused and styles.focused or styles.unfocused
    local span = w - 2

    canvas:put(x, y, title_row(window.title, w, focused), w)

    local middle = border_style:render(BORDER.vertical)
        .. string.rep(" ", span)
        .. border_style:render(BORDER.vertical)
    for row = 1, h - 2 do
        canvas:put(x, y + row, middle, w)
    end

    canvas:put(x, y + h - 1, border_style:render(
        BORDER.bottom_left .. string.rep(BORDER.horizontal, span) .. BORDER.bottom_right), w)

    if window.rows then
        -- Clipping to the border's height is the theme's duty: put_rows keeps
        -- the canvas's boundary, not the window's. Usually there are no extra
        -- rows — the viewport is made to fit the border exactly — but at the
        -- moment of a resize a frame of the previous geometry arrives, and the
        -- extra row lies over the bottom edge and below the window. It reads
        -- as a broken border, not as a lagging frame.
        local room = h - 2
        local rows = window.rows
        if #rows > room then
            local cut = {}
            for index = 1, room do cut[index] = rows[index] end
            rows = cut
        end
        canvas:put_rows(x + 1, y + 1, rows, w - 2)
    end
end

-- The chrome's bars: the window bar at the top and the status line at the bottom.
--
-- Returns the hit layout — the compositor counts a click by it. A separate
-- formula for the click would one day drift from the drawing, and a button
-- would end up a character to the left of where it appears; so there is one
-- table for both jobs.
--
-- state = {windows, focused_id, menu_open, status, clock}
function chrome.bars(canvas, width: any, height: any, state)
    local windows = type(state.windows) == "table" and state.windows or {}
    local focused_id = state.focused_id

    local hits, column = {}, 1
    local parts = {}

    for index, window in ipairs(windows) do
        local label = " " .. index .. " " .. clip(window.title or "?", 18) .. " "
        local cells = tty.text.width(label)
        if column + cells > width then break end
        local style = window.id == focused_id and styles.tab_active or styles.tab_idle
        parts[#parts + 1] = style:render(label)
        hits[#hits + 1] = {row = 1, from = column, to = column + cells - 1, id = window.id}
        column = column + cells
    end

    canvas:put(1, 1, styles.bar:width(width):render(table.concat(parts)), width)

    local status = type(state.status) == "string" and state.status or ""
    canvas:put(1, height, styles.bar:width(width):render(clip(" " .. status .. " ", width)), width)
    return hits
end

-- The applications menu: the list of windows the application declared. An
-- empty list says so directly — a silent empty menu reads as breakage.
-- The standard theme's menu: one level, no folders.
--
-- `cursor` — the number of the selected row; the theme MARKS it in the layout
-- (`cursor = true`), and the compositor then opens the marked one instead of
-- computing the choice again.
-- There are no digits in the rows on purpose: a keyboard path not visible in
-- the interface must not be introduced, and a visible one needs a column of
-- digits — which is exactly what we do not draw here.
-- `anchor` — an icon's context menu: the same box, but at the pointer rather
-- than at the screen's center, and the item's caption is taken from `label`
-- (for the "Open" item `title` is the title of the window it will open, not
-- its caption).
function chrome.menu(canvas, width: any, height: any, items, failure, open: any, cursor: any, anchor: any)
    local box_w = 40
    if box_w > width - 4 then box_w = width - 4 end
    if box_w < 12 then box_w = 12 end
    local rows = #items + 2
    local box_h = rows + 2
    local left = (width - box_w) // 2
    local top = (height - box_h) // 2
    if type(anchor) == "table" then
        box_w = 16
        local at_x: integer = math.tointeger(tonumber(anchor.x) or 1) or 1
        local at_y: integer = math.tointeger(tonumber(anchor.y) or 2) or 2
        local right_most: integer = (math.tointeger(width) or 0) - box_w + 1
        local low_most: integer = (math.tointeger(height) or 0) - box_h
        left = at_x < right_most and at_x or right_most
        top = at_y < low_most and at_y or low_most
    end
    if left < 1 then left = 1 end
    if top < 2 then top = 2 end

    local span = box_w - 2
    canvas:put(left, top, styles.focused:render("╭" .. string.rep(BORDER.horizontal, span) .. "╮"), box_w)
    for row = 1, box_h - 2 do
        canvas:put(left, top + row,
            styles.focused:render("│") .. string.rep(" ", span) .. styles.focused:render("│"), box_w)
    end
    canvas:put(left, top + box_h - 1,
        styles.focused:render("╰" .. string.rep(BORDER.horizontal, span) .. "╯"), box_w)
    canvas:put(left + 2, top, styles.title:render(type(anchor) == "table" and " icon " or " applications "), box_w - 4)

    local hits = {}

    if failure then
        -- A registry refusal and an empty catalog look the same unless the
        -- reason is named: a person looks for the error in their application,
        -- and it is not there.
        canvas:put(left + 2, top + 2, styles.hint:render("catalog not read: " .. tostring(failure)), span - 2)
    elseif #items == 0 then
        canvas:put(left + 2, top + 2, styles.hint:render("the application declared no windows"), span - 2)
    else
        local at = math.tointeger(tonumber(cursor) or 1) or 1
        for index, item in ipairs(items) do
            local label = " " .. clip(tostring(item.label or item.title or ""), span - 2) .. " "
            local style = index == at and styles.title or styles.tab_idle
            canvas:put(left + 1, top + index, style:width(span):render(label), span)
            hits[#hits + 1] = {
                row = top + index, from = left + 1, to = left + span, index = index,
                -- The level and the row number are what the compositor moves
                -- the cursor by; the mark is what it opens by.
                level = 1, slot = index, cursor = index == at,
            }
        end
    end
    canvas:put(left + 2, top + box_h - 1,
        styles.hint:render(" arrows — select · enter — open · esc — close "), span)
    return hits
end

function chrome.empty_desktop(canvas, width: any, height: any, text)
    local room = width - 4
    local message = clip(text, room < 1 and 1 or room)
    local column = (width - tty.text.width(message)) // 2
    canvas:put(column < 1 and 1 or column, height // 2,
        styles.hint:render(message), width)
end

return chrome
