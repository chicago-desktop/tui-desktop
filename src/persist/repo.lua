-- Окна, собранные в рантайме. Одна строка на окно, имя — ключ.
--
-- Ручка мастерской пишет сюда и применяет запись в реестр; загрузчик читает
-- это на старте и возвращает окна в реестр после перезапуска. Без таблицы
-- собранное окно живёт ровно до конца процесса.

local sql = require("sql")
local env = require("env")
local json = require("json")

-- Значение по умолчанию в коде, переопределяемое окружением: ресурс базы
-- принадлежит приложению, а не модулю.
local DB_ID = env.get("BUTSCHSTER_TUI_DESKTOP_DB_ID") or "app:db"
local TABLE = "butschster_tui_desktop_windows"

local repo = {}

-- Соединение возвращается на КАЖДОМ пути, включая ошибку внутри работы:
-- потерянное соединение не даёт о себе знать, пока не кончится пул.
local function with_db(work)
    local db, err = sql.get(DB_ID)
    if err or not db then return nil, err or ("database unavailable: " .. DB_ID) end
    local ok, result, work_err = pcall(work, db)
    db:release()
    if not ok then return nil, tostring(result) end
    return result, work_err
end

local function decode_modules(raw)
    if type(raw) ~= "string" or raw == "" then return {} end
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then return {} end
    return decoded
end

-- Описание сверх кода (импорты, значок, тип окна, пиксельный вид) — JSON в
-- колонке `spec` (миграция 03). Строка без колонки читается как «ничего
-- не объявлено», а не как отказ.
local function decode_spec(raw: any): any
    if type(raw) ~= "string" or raw == "" then return {} end
    local decoded = json.decode(raw)
    if type(decoded) ~= "table" then return {} end
    return decoded
end

local function to_window(row: any)
    return {
        name = row.name,
        title = row.title,
        width = tonumber(row.width) or 0,
        height = tonumber(row.height) or 0,
        source = row.source,
        modules = decode_modules(row.modules),
        -- Папка меню; пусто — не названа. Колонка появилась миграцией 02,
        -- поэтому читается с запасом на строку, где её ещё нет.
        group = type(row.menu_group) == "string" and row.menu_group or "",
        spec = decode_spec(row.spec),
        created_at = row.created_at,
        updated_at = row.updated_at,
    }
end

-- Сохранить окно. Повторное имя перезаписывает: история правок здесь не
-- ведётся, и «имя занято» было бы отказом чинить собственное окно.
function repo.save(window)
    return with_db(function(db)
        local modules = json.encode(window.modules or {})
        local _, err = db:execute(
            "DELETE FROM " .. TABLE .. " WHERE name = $1", { window.name })
        if err then return nil, err end
        local group = type(window.group) == "string" and window.group or ""
        local spec = json.encode(type(window.spec) == "table" and window.spec or {})
        local _, ierr = db:execute(
            "INSERT INTO " .. TABLE ..
            " (name, title, width, height, source, modules, menu_group, spec) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
            { window.name, window.title, window.width, window.height, window.source, modules, group, spec })
        if ierr then return nil, ierr end
        return window.name
    end)
end

function repo.get(name)
    return with_db(function(db)
        local rows, err = db:query(
            "SELECT * FROM " .. TABLE .. " WHERE name = $1", { name })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then return nil, nil end
        return to_window(row)
    end)
end

function repo.list()
    return with_db(function(db)
        local rows, err = db:query("SELECT * FROM " .. TABLE .. " ORDER BY name", {})
        if err then return nil, err end
        local out = {}
        for _, row in ipairs(rows or {}) do out[#out + 1] = to_window(row) end
        return out
    end)
end

-- Возвращает, была ли строка: «удалил несуществующее» и «удалил» — разные
-- ответы, иначе опечатка в имени выглядит успехом.
function repo.delete(name)
    return with_db(function(db)
        local rows, err = db:query(
            "SELECT name FROM " .. TABLE .. " WHERE name = $1", { name })
        if err then return nil, err end
        if not (rows and rows[1]) then return false end
        local _, derr = db:execute("DELETE FROM " .. TABLE .. " WHERE name = $1", { name })
        if derr then return nil, derr end
        return true
    end)
end

return repo
