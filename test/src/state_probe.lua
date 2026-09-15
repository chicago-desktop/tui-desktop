-- State provider for a view window.
--
-- Exactly the process §4b separated the two names for: it obtains the data,
-- under its own actor, and the view only draws them. Here it obtains nothing —
-- what is checked is not the obtaining but the path: the compositor gave the name and
-- the window number, the provider pushes the state itself, and input arrives to it too.
local channel = require("channel")
local process = require("process")
local time = require("time")

local NAME = "windows.tui_desktop.test.provider"

local function body_of(message: any)
    local body: any = message:payload()
    if type(body) == "userdata" then
        local ok, decoded = pcall(function() return body:data() end)
        body = ok and decoded or {}
    end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function main(desktop, window_id)
    local inbox = process.inbox()
    process.registry.register(NAME)

    local pushed = 0
    local inputs = {}
    local last_resize: any = nil

    while true do
        local picked = channel.select({inbox:case_receive(), time.after("30s"):case_receive()})
        if not picked.ok then break end
        if picked.channel ~= inbox then break end

        local message = picked.value
        local topic = message:topic()
        local body = body_of(message)

        if topic == "probe.push" then
            -- The provider pushes the state, the compositor does not ask for it:
            -- only the provider knows when the data changed.
            pushed = pushed + 1
            process.send(tostring(desktop), "desktop.state", {
                id = tostring(window_id),
                state = {title = "ready", tick = pushed},
            })
        elseif topic == "window.input" then
            local event: any = body.event or {}
            -- A close is a request a window may refuse; this provider has
            -- nothing to keep, so it answers the way a real one does — by
            -- ending (the SDK runner and the image viewer's provider do too).
            if event.type == "close" then break end
            if event.type == "resize" then last_resize = event end
            inputs[#inputs + 1] = tostring(event.type) .. ":"
                .. tostring(event.x) .. "," .. tostring(event.y)
                .. ":" .. tostring(event.action) .. ":" .. tostring(event.button)
        elseif topic == "probe.report" then
            process.send(tostring(body.reply_to), "probe.state", {
                desktop = tostring(desktop),
                window = tostring(window_id),
                pushed = pushed,
                resize = last_resize,
                inputs = table.concat(inputs, " "),
            })
        end
    end

    process.registry.unregister(NAME)
end

return {main = main}
