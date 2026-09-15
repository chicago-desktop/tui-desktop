-- A view window's state provider that publishes what the test asks for.
--
-- The argument is the test's watcher name: the provider tells it its pid
-- (`probe.ready`), publishes `{title, image}` through the real
-- `window_api.publish_state` on `probe.publish`, and says `probe.published`.
-- It registers no name of its own: test files run in parallel, and a probe
-- with one fixed name would answer the neighbouring file's test.
local channel = require("channel")
local process = require("process")
local time = require("time")
local desktop = require("desktop")

local function body_of(message: any): any
    local body: any = message:payload()
    if type(body) == "userdata" then
        local ok, decoded = pcall(function() return body:data() end)
        body = ok and decoded or {}
    end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function main(_service, window_id, args)
    local watcher = tostring(args or "")
    local inbox = process.inbox()
    if watcher ~= "" then process.send(watcher, "probe.ready", {pid = tostring(process.pid())}) end
    local count: any = {value = 0}
    while true do
        local picked = channel.select({inbox:case_receive(), time.after("30s"):case_receive()})
        if not picked.ok or picked.channel ~= inbox then break end
        local message = picked.value
        if message:topic() == "probe.publish" then
            local body: any = body_of(message)
            count.value = count.value + 1
            local state: any = {tick = count.value, title = body.title, image = body.image}
            local ok, err = desktop.publish_state(tostring(window_id), state)
            process.send(watcher, "probe.published", {ok = ok == true, error = err and tostring(err) or nil})
        end
    end
end

return {main = main}
