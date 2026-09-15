-- POST /tui-desktop/windows/{id}/{action} — do something with one window.
--
-- Actions: close, focus, minimize, move, resize, type, key, screen.
-- `screen` returns the window's content as rows — this is how an external
-- agent READS the screen of the program it drives.
local http = require("http")
local json = require("json")
local security = require("security")
local control = require("control")

-- The whitelist is not for security — the compositor rejects the unfamiliar
-- anyway — but for the answer: a typo in the action would otherwise reach it
-- and come back as "unknown command", already without the endpoint's name.
local ACTIONS = {
    close = "desktop.close", focus = "desktop.focus", minimize = "desktop.minimize",
    move = "desktop.move", resize = "desktop.resize", type = "desktop.type",
    key = "desktop.key", screen = "desktop.screen",
}

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

    local id = req:param("id")
    local action = req:param("action")
    local topic = ACTIONS[action or ""]
    if not topic then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({success = false, error = "unknown action: " .. tostring(action)})
        return
    end

    local body = json.decode(req:body() or "") or {}
    if type(body) ~= "table" then body = {} end
    body.id = id

    local answer, err = control.call(topic, body)
    if not answer then
        res:set_status(http.STATUS.SERVICE_UNAVAILABLE)
        res:write_json({success = false, error = err})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true, window = answer.window,
        rows = answer.rows, ready = answer.ready, sent = answer.sent,
    })
end

return {handler = handler}
