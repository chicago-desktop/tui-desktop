-- POST /tui-desktop/apps — build a window in the running runtime and save it.
--
-- The process entry is built and applied through the registry's changes API,
-- so the window appears in the desktop menu at once: no file on disk, no
-- restart. The source goes into the table, and the loader brings the window
-- back after a restart.
--
-- The order matters here: the row first, then the registry. If applying
-- failed, the row is removed — otherwise the storage would accumulate windows
-- that never come up, and every start would silently complain about them.

local http = require("http")
local json = require("json")
local security = require("security")
local repo = require("repo")
local apps = require("apps")

local function bad(res, message)
    res:set_status(http.STATUS.BAD_REQUEST)
    res:write_json({success = false, error = message})
end

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then return nil, "no http context" end
    res:set_content_type(http.CONTENT.JSON)

    if not security.actor() then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({success = false, error = "authentication required"})
        return
    end

    local body = json.decode(req:body() or "") or {}
    if type(body) ~= "table" then body = {} end

    -- Parsing and checking the body live in the library shared with the MCP
    -- tool: two parsings of one body would diverge on the first new field.
    local window, verr = apps.prepare(body)
    if not window then return bad(res, tostring(verr)) end
    local name = window.name

    local existing = repo.get(name)

    local _, serr = repo.save(window)
    if serr then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "saving: " .. tostring(serr)})
        return
    end

    local ok, aerr = apps.apply(window)
    if not ok then
        repo.delete(name)
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = aerr})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        entry = apps.entry_id(name),
        name = name,
        title = window.title,
        modules = window.modules,
        group = window.group,
        spec = window.spec,
        replaced = existing ~= nil,
    })
end

return {handler = handler}
