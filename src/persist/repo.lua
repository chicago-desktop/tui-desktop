-- Windows built in the runtime. One row per window, the name is the key.
--
-- The workshop endpoint writes here and applies the entry to the registry; the
-- loader reads this at start and brings the windows back into the registry
-- after a restart. Without the table a built window lives exactly until the
-- process ends.

local sql = require("sql")
local env = require("env")
local json = require("json")

-- The default value is in code, overridable by the environment: the database
-- resource belongs to the application, not to the module.
local DB_ID = env.get("TUI_DESKTOP_DB_ID") or "app:db"
local TABLE = "chicago_tui_desktop_windows"

local repo = {}

-- The connection is returned on EVERY path, including an error inside the
-- work: a lost connection gives no sign of itself until the pool runs out.
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

-- The description beyond the code (imports, icon, window type, pixel view) —
-- JSON in the `spec` column (migration 03). A row without the column reads as
-- "nothing declared", not as a refusal.
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
        -- The menu folder; empty — not named. The column appeared with
        -- migration 02, so it is read allowing for a row that does not have
        -- it yet.
        group = type(row.menu_group) == "string" and row.menu_group or "",
        spec = decode_spec(row.spec),
        created_at = row.created_at,
        updated_at = row.updated_at,
    }
end

-- Save a window. A repeated name overwrites: no edit history is kept here, and
-- "name taken" would be a refusal to fix one's own window.
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

-- Returns whether the row existed: "deleted a nonexistent one" and "deleted"
-- are different answers, otherwise a typo in the name looks like success.
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
