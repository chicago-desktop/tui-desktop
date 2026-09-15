-- GET /tui-desktop/apps — windows built in the runtime and saved.
--
-- Also returns the `live` flag: whether the registry has the entry right now.
-- A row without an entry means the window is saved but did not come up — and
-- that is exactly what otherwise looks like "the window vanished".

local http = require("http")
local registry = require("registry")
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

    local windows, err = repo.list()
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "reading the store: " .. tostring(err)})
        return
    end

    local out = {}
    for _, window in ipairs(windows or {}) do
        local id = apps.entry_id(window.name)
        out[#out + 1] = {
            name = window.name,
            title = window.title,
            entry = id,
            width = window.width,
            height = window.height,
            modules = window.modules,
            group = window.group,
            spec = window.spec,
            updated_at = window.updated_at,
            live = registry.get(id) ~= nil,
        }
    end

    res:set_status(http.STATUS.OK)
    res:write_json({success = true, apps = out})
end

return {handler = handler}
