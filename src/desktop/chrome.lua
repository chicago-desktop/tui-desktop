-- Тема композитора: единственное, что композитор знает о виде.
--
-- Композитор зовёт только функции контракта (README, «Контракт темы») и сам
-- не решает ни про рамки, ни про полосы, ни про то, сколько строк занято
-- сверху и снизу. Вторая оболочка приносит другую тему и получает другой
-- вид, не трогая механику окон.
--
-- Здесь нет ни одного вызова, который уходит в рантайм: только строки и
-- арифметика. Поэтому файл — библиотека, а не процесс, и его можно звать
-- из любой отрисовки.
--
-- Правило, которое стоит держать в голове при правках: рамка и содержимое
-- окна кладутся на холст РАЗДЕЛЬНО. Попытка слить их в одну строку означает
-- решения об обрезке, которые принять уже нельзя — содержимое приходит
-- готовыми строками от чужого процесса.

local tty = require("tty")

local chrome = {}

-- Кнопки в правом верхнем углу рамки. Порядок и ширина заданы здесь один
-- раз: и рисование, и попадание мыши считают по этой же таблице, иначе
-- кнопка «закрыть» однажды окажется на один символ левее, чем выглядит.
chrome.BUTTONS = {
    {id = "minimize", label = "[-]"},
    {id = "maximize", label = "[□]"},
    {id = "close",    label = "[×]"},
}
chrome.BUTTONS_WIDTH = 9  -- три кнопки по три ячейки

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

-- Сколько строк хром забирает сверху и снизу. Рабочий стол — строки
-- layout.top + 1 .. height - layout.bottom.
--
-- Раньше это число было константой внутри композитора, и панель задач снизу
-- поставить было нельзя, не правя композитор: основа снова знала бы про вид.
function chrome.layout(width: any, height: any)
    return {top = 1, bottom = 1}
end

-- Фон рабочего стола и значки на нём. Здесь нет ни того, ни другого: холст
-- уже очищен, а раскладку эта оболочка не показывает — окна открываются из
-- каталога по alt+o. Тема с бирюзовым столом заливает фон и рисует значки
-- сама, возвращая разметку попаданий; отсутствие ответа читается как «на
-- столе нечего нажимать».
function chrome.fill(canvas, width: any, height: any, state)
end

-- clip(text, cells) — обрезать по ЯЧЕЙКАМ, а не по байтам.
--
-- `#строка` считает байты и не видит управляющих последовательностей: на
-- кириллице и на стилизованном тексте он врёт вдвое и втрое.
local function clip(text, cells: any)
    local width = math.tointeger(cells) or 0
    if width <= 0 then return "" end
    return tty.text.truncate(text, width)
end

chrome.clip = clip

-- Заголовочная строка окна: рамка, имя, кнопки.
--
-- Возвращает готовую строку ровно в `width` ячеек.
local function title_row(title, width: any, focused)
    if width <= 0 then return "" end
    if width == 1 then return BORDER.horizontal end
    if width == 2 then return BORDER.horizontal .. BORDER.horizontal end

    local border_style = focused and styles.focused or styles.unfocused
    local name_style = focused and styles.title or styles.title_dim

    local buttons = width >= chrome.BUTTONS_WIDTH + 6 and chrome.BUTTONS_WIDTH or 0
    -- Свободно под имя: вся ширина минус углы, минус кнопки, минус пробелы
    -- вокруг имени и минимум один сегмент рамки слева.
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

-- Нарисовать окно целиком: рамка, заголовок, содержимое.
--
-- `rows` — массив строк, как его отдаёт viewport:snapshot(). Он общий и
-- неизменяемый, поэтому кладётся как есть: put_rows сам обрежет по ширине.
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
        -- Обрезать по высоте рамки обязана тема: put_rows держит границу
        -- холста, а не окна. Обычно лишних строк нет — viewport сделан ровно
        -- в рамку, — но в момент смены размера приезжает кадр прежней
        -- геометрии, и лишняя строка ложится поверх нижней грани и ниже
        -- окна. Читается это как сломанная рамка, а не как отставший кадр.
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

-- Полосы хрома: полоса окон сверху и статусная строка снизу.
--
-- Возвращает разметку попаданий — по ней композитор считает клик. Отдельная
-- формула для клика однажды разъедется с отрисовкой, и кнопка окажется на
-- символ левее, чем выглядит; поэтому таблица одна на оба дела.
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

-- Меню приложений: список окон, которые объявило приложение. Пустой список
-- говорит об этом прямо — молчаливое пустое меню читается как поломка.
-- Меню штатной темы: один уровень, без папок.
--
-- `cursor` — номер выбранной строки; тема ПОМЕЧАЕТ её в разметке (`cursor =
-- true`), и композитор потом открывает помеченную, а не считает выбор заново.
-- Цифр в строках нет намеренно: клавиатурный путь, не видный в интерфейсе,
-- заводить нельзя, а видный требует колонки цифр — её здесь и не рисуем.
-- `anchor` — контекстное меню значка: та же рамка, но у указателя, а не по
-- центру экрана, и подпись пункта берётся из `label` (у пункта «Открыть»
-- `title` — заголовок окна, которое он откроет, а не его подпись).
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
        -- Отказ реестра и пустой каталог выглядят одинаково, если не назвать
        -- причину: человек ищет ошибку в своём приложении, а её там нет.
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
                -- Уровень и номер строки — то, по чему композитор двигает
                -- курсор; пометка — то, по чему он открывает.
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
