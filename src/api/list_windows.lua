-- GET /tui-desktop/windows — what is open on the screen now.
--
-- Authentication is provided by the router (token_auth + endpoint_firewall);
-- the actor check keeps direct calls honest.
local http = require("http")
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

    -- ?frame_samples=1 — raw frames of the measurement ring (up to two hundred
    -- rows): needed for the per-phase measurement, in the ordinary status they
    -- are only extra weight.
    local samples_wanted = req:query("frame_samples") == "1"
    local answer, err = control.call("desktop.list", {frame_samples = samples_wanted})
    if not answer then
        res:set_status(http.STATUS.SERVICE_UNAVAILABLE)
        res:write_json({success = false, error = err})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        windows = answer.windows or {},
        focused = answer.focused,
        screen = answer.screen,
        -- What happened to the saved windows at start: silence here would read
        -- as "there were no windows", and that is a different statement.
        restore = answer.restore,
        -- The whole desktop state, not only the window list. Each field here
        -- tells apart two states that look the same FROM OUTSIDE: a refusal
        -- that only the person sees in the status line; an open menu versus
        -- a click that did not arrive; an expanded folder versus an
        -- unexpanded one; "nothing to expand" versus "broken"; a selected
        -- icon versus a selection that was not drawn; the frame cost, which
        -- shows wrongly cut chrome — it draws the right screen, just slowly.
        --
        -- The compositor already returns them; not passing them through here
        -- would mean they cannot be used from the live stand, where all of
        -- this is needed.
        notice = answer.notice,
        menu_open = answer.menu_open,
        menu_path = answer.menu_path,
        menu_choices = answer.menu_choices,
        menu_folders = answer.menu_folders,
        selected = answer.selected,
        pixels = answer.pixels,
        frame = answer.frame,
    })
end

return {handler = handler}
