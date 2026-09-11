-- Кадр, в котором хром — картинки, а содержимое окон — символы.
--
-- Здесь только арифметика и разбор: ни одного вызова в рантайм, поэтому
-- проверяется прямо, без терминала и без графики.
--
-- Две вещи, ради которых это отдельный файл:
--
--   * **Под картинкой обязаны быть пробелы.** Поверхность перерисовывает
--     изменившиеся строки; символ, оставшийся под размещением, вылезет
--     из-под него при первой же перерисовке — и никто не поймёт, откуда он.
--   * **Кривое размещение не должно ронять стол.** `present` отвергает КАДР
--     целиком, если хоть одно размещение неверно, а композитор зовёт его
--     через assert. Тема с одной опечаткой погасила бы весь десктоп, поэтому
--     негодное отбрасывается здесь и называется по имени.

local pixels = {}

local function whole(value: any)
    local number = tonumber(value)
    if not number then return nil end
    local integer = math.tointeger(math.floor(number))
    return integer
end

-- check(placement) -> размещение | nil, причина
--
-- Правила те же, что у поверхности: непустой `id`, положительные `x`, `y`,
-- `cols`, `rows`. Растр НЕ обязателен: размещение без него означает «эта
-- картинка уже на экране, оставь как есть» — на этом стоит вся экономия.
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

-- blank_under(canvas, placement) — стереть символы под картинкой.
function pixels.blank_under(canvas: any, placement: any)
    -- Числа вынуты из таблицы `any`, поэтому проходят через math.tointeger:
    -- линтер держит арифметику на них за ошибку, и он прав — сюда попадает
    -- то, что вернула тема.
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

-- hits(painted) -> {desktop, bars, menu}, жалоба или nil
--
-- Разметка попаданий остаётся в ЯЧЕЙКАХ и делится на те же три вида, что и
-- при отрисовке символами: у стола, у полос и у меню разный смысл полей, и
-- один плоский список пришлось бы разбирать по догадке — а `id` там значит
-- разное. Плоский список поэтому не угадывается, а называется жалобой:
-- молча потерянные щелчки выглядят как мёртвый интерфейс.
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

-- frame(canvas, painted) -> размещения, жалобы
--
-- Годные размещения возвращаются в порядке темы (он и есть порядок рисования)
-- и под каждым стирается канва. Жалобы — список строк: их называет
-- композитор, потому что тема о состоянии экрана не узнает никак.
function pixels.frame(canvas: any, painted: any)
    local list: any = type(painted) == "table" and painted.placements or nil
    local images, complaints, seen = {}, {}, {}

    if type(list) ~= "table" then
        if painted ~= nil then
            complaints[#complaints + 1] = "the theme returned no placement list"
        end
        return images, complaints
    end

    for _, entry in ipairs(list) do
        local placement, reason = pixels.check(entry)
        if not placement then
            complaints[#complaints + 1] = tostring(reason)
        elseif seen[placement.id] then
            -- Два размещения с одним id — это не два рисунка, а спор о том,
            -- какой из них показать; на экране он выглядит миганием.
            complaints[#complaints + 1] = "placement " .. placement.id .. " is named twice"
        else
            seen[placement.id] = true
            pixels.blank_under(canvas, placement)
            images[#images + 1] = placement
        end
    end

    return images, complaints
end

return pixels
