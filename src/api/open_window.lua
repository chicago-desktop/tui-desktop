-- POST /tui-desktop/windows — open a window with a program.
--
-- Body: {"entry": "…:window_calc", "args": "…", "command": "...",
--         "title": "...", "x": 1, "y": 2, "w": 80, "h": 20}.
-- `args` — the application window's parameter, `command` — the program for a PTY window.
-- Everything is optional; without an entry a window with an interactive bash
-- opens, and then `command` names the program.
local http = require("http")
local json = require("json")
local security = require("security")
local control = require("control")

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

    local answer, err = control.call("desktop.open", {
        entry = body.entry, args = body.args, command = body.command, title = body.title,
        x = body.x, y = body.y, w = body.w, h = body.h,
    })
    if not answer then
        res:set_status(http.STATUS.SERVICE_UNAVAILABLE)
        res:write_json({success = false, error = err})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({success = true, window = answer.window})
end

return {handler = handler}
