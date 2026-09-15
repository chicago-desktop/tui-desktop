-- A window that sends a command known to miss and listens on the reply channel.
--
-- The order of the commands is the control here: between the miss and the question
-- stands a VALID command. If the compositor sent something in reply to it too, that
-- would arrive as the second message instead of the answer to the question — and no
-- waiting is needed for this, messages arrive in order.
local channel = require("channel")
local process = require("process")
local time = require("time")
local desktop = require("desktop")

local function body_of(message: any)
    local body: any = message:payload()
    if type(body) == "userdata" then
        local ok, decoded = pcall(function() return body:data() end)
        body = ok and decoded or {}
    end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function main(watcher)
    -- The reply channel is created FIRST: a refusal of a command sent before the
    -- subscription would go to the inbox — not a loss either, but not here.
    local replies = desktop.replies()

    desktop.focus("w404")
    desktop.open({entry = "app:idle_window", title = "Alive", w = 20, h = 6})
    desktop.request("desktop.list", {})

    local got = {}
    for _ = 1, 2 do
        local picked = channel.select({replies:case_receive(), time.after("5s"):case_receive()})
        if picked.channel ~= replies or not picked.ok then break end
        got[#got + 1] = body_of(picked.value)
    end

    local first: any = got[1] or {}
    local second: any = got[2] or {}
    process.send(tostring(watcher), "probe.refusals", {
        first_command = tostring(first.command),
        first_error = tostring(first.error),
        first_unsolicited = first.unsolicited == true,
        second_command = tostring(second.command),
        second_ok = second.ok == true,
    })

    while true do
        local picked = channel.select({time.after("30s"):case_receive()})
        if not picked.ok then break end
    end
end

return {main = main}
