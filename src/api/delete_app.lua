-- DELETE /tui-desktop/apps/{name} — remove a built window entirely.
--
-- Removes both the row and the registry entry. Windows of this kind that are
-- already open keep working: the process lives its own life, and what is
-- removed is the ability to open a new one. The answer says so directly,
-- otherwise "deleted, yet it is on screen" reads as a deletion that did not
-- work.

local http = require("http")
local security = require("security")
local repo = require("repo")
local apps = require("apps")

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

    local name = req:param("name")
    if type(name) ~= "string" or name == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({success = false, error = "the window name is not given"})
        return
    end

    local existed, derr = repo.delete(name)
    if derr then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "deleting the row: " .. tostring(derr)})
        return
    end

    local ok, rerr = apps.remove(name)
    if not ok then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = rerr})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        name = name,
        existed = existed == true,
        note = "windows of this kind that are already open keep working until closed",
    })
end

return {handler = handler}
