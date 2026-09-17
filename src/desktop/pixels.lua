-- A frame in which the chrome is pictures and the windows' content is characters.
--
-- Only arithmetic and parsing here: not a single call into the runtime, so it
-- is tested directly, without a terminal and without graphics.
--
-- Two things this file exists separately for:
--
--   * **There must be spaces under a picture.** The surface redraws the rows
--     that changed; a character left under a placement will crawl out from
--     under it at the very first redraw — and nobody will understand where it
--     came from.
--   * **A malformed placement must not bring down the desktop.** `present`
--     rejects the WHOLE frame if even one placement is invalid, and the
--     compositor calls it through assert. A theme with one typo would put out
--     the entire desktop, so an unfit placement is dropped here and named.

local pixels = {}

local function whole(value: any)
    local number = tonumber(value)
    if not number then return nil end
    local integer = math.tointeger(math.floor(number))
    return integer
end

-- check(placement) -> placement | nil, reason
--
-- The rules are the same as the surface's: a non-empty `id`, positive `x`,
-- `y`, `cols`, `rows`. The raster is NOT required: a placement without one
-- means "this picture is already on screen, leave it as is" — all the savings
-- rest on this.
function pixels.check(placement: any)
    if type(placement) ~= "table" then return nil, "a placement is not a table" end

    local id = placement.id
    if type(id) ~= "string" or id == "" then
        return nil, "a placement has no id"
    end

    local x, y = whole(placement.x), whole(placement.y)
    if not x or not y or x < 1 or y < 1 then
        return nil, "placement " .. id .. ": x and y are counted in cells and start at one"
    end

    local cols, rows = whole(placement.cols), whole(placement.rows)
    if not cols or not rows or cols < 1 or rows < 1 then
        return nil, "placement " .. id .. ": cols and rows must be positive"
    end

    return {id = id, x = x, y = y, cols = cols, rows = rows, raster = placement.raster}, nil
end

-- blank_under(canvas, placement) — erase the characters under a picture.
function pixels.blank_under(canvas: any, placement: any)
    -- The numbers are taken out of an `any` table, so they go through
    -- math.tointeger: the linter treats arithmetic on them as an error, and it
    -- is right — what the theme returned ends up here.
    local cols = math.tointeger(placement.cols) or 0
    local rows = math.tointeger(placement.rows) or 0
    local x = math.tointeger(placement.x) or 1
    local y = math.tointeger(placement.y) or 1
    if cols < 1 or rows < 1 then return end
    local blank = string.rep(" ", cols)
    for row = 0, rows - 1 do
        canvas:put(x, y + row, blank, cols)
    end
end

-- hits(painted) -> {desktop, bars, menu}, complaint or nil
--
-- The hit layout stays in CELLS and is split into the same three kinds as in
-- drawing with characters: the desktop, the bars and the menu give their
-- fields different meanings, and one flat list would have to be parsed by
-- guesswork — and `id` means different things there. So a flat list is not
-- guessed at but named as a complaint: silently lost clicks look like a dead
-- interface.
function pixels.hits(painted: any)
    local given: any = type(painted) == "table" and painted.hits or nil
    if type(given) ~= "table" then
        return {desktop = {}, bars = {}, menu = {}}, nil
    end
    if given[1] ~= nil then
        return {desktop = {}, bars = {}, menu = {}},
            "the theme returned a flat list of hits; groups {desktop, bars, menu} were expected"
    end
    return {
        desktop = type(given.desktop) == "table" and given.desktop or {},
        bars = type(given.bars) == "table" and given.bars or {},
        menu = type(given.menu) == "table" and given.menu or {},
    }, nil
end

-- frame(canvas, painted) -> placements, complaints
--
-- Valid placements are returned in the theme's order (which is the drawing
-- order), and the canvas is erased under each. Complaints are a list of
-- strings: the compositor names them, because the theme has no way to learn
-- about the state of the screen.
function pixels.frame(canvas: any, painted: any)
    local list: any = type(painted) == "table" and painted.placements or nil
    local images, complaints, seen = {}, {}, {}

    if type(list) ~= "table" then
        if painted ~= nil then
            complaints[#complaints + 1] = "the theme returned no placement list"
        end
        return images, complaints
    end

    -- The cells to blank, by row: pictures side by side (a wallpaper row cut
    -- in pieces) are blanked with one put per run, not one per picture.
    local runs: any = {}
    for _, entry in ipairs(list) do
        local placement, reason = pixels.check(entry)
        if not placement then
            complaints[#complaints + 1] = tostring(reason)
        elseif seen[placement.id] then
            -- Two placements with one id are not two pictures but a dispute
            -- over which one to show; on screen it looks like flickering.
            complaints[#complaints + 1] = "placement " .. placement.id .. " is named twice"
        else
            seen[placement.id] = true
            -- An overlay (a drag's outline) is transparent but for its line:
            -- the text under it must stay, so its cells are not blanked.
            if entry.overlay ~= true then
                local x = math.tointeger(placement.x) or 1
                local y = math.tointeger(placement.y) or 1
                local cols = math.tointeger(placement.cols) or 0
                local rows = math.tointeger(placement.rows) or 0
                if cols > 0 then
                    for row = y, y + rows - 1 do
                        local line: any = runs[row]
                        if line == nil then
                            line = {}
                            runs[row] = line
                        end
                        line[#line + 1] = {x, x + cols}
                    end
                end
            end
            images[#images + 1] = placement
        end
    end
    for row, line in pairs(runs) do
        table.sort(line, function(a: any, b: any): boolean return a[1] < b[1] end)
        local from, to = line[1][1], line[1][2]
        for index = 2, #line + 1 do
            local run: any = line[index]
            if run ~= nil and run[1] <= to then
                if run[2] > to then to = run[2] end
            else
                pixels.blank_under(canvas, {x = from, y = row, cols = to - from, rows = 1})
                if run ~= nil then from, to = run[1], run[2] end
            end
        end
    end

    return images, complaints
end

return pixels
