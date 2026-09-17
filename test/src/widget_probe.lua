-- A desktop widget's process for the tests (FR-006): what the compositor
-- spawns for a registry entry of `meta.type: chicago.widget`.
--
-- It publishes a state at start and again on `probe.publish`. The state names
-- the widget id, the size and cell it was spawned with, and a counter, so the
-- test sees all of it drawn by the theme. It registers
-- `<compositor>.widget.<id>`, so the test can find the process to poke or kill.
local channel = require("channel")
local process = require("process")
local time = require("time")

local function main(desktop, widget_id, args: any, geometry: any)
    local inbox = process.inbox()
    local name = tostring(desktop) .. ".widget." .. tostring(widget_id)
    process.registry.register(name)
    local size: any = type(geometry) == "table" and geometry or {}
    -- A table: the counter is changed by the closure and read by nobody else,
    -- but the rule of this codebase is not to share plain locals with closures.
    local counter: any = {published = 0}

    local function publish()
        counter.published = counter.published + 1
        process.send(tostring(desktop), "desktop.state", {
            id = tostring(widget_id),
            state = {note = tostring(widget_id) .. ":" .. tostring(size.width) .. "x" .. tostring(size.height)
                .. "@" .. tostring(size.cell_w) .. "x" .. tostring(size.cell_h)
                .. "#" .. tostring(counter.published) .. (type(args) == "table" and args.value and ":" .. tostring(args.value) or "")},
        })
    end

    publish()
    while true do
        local picked = channel.select({inbox:case_receive(), time.after("60s"):case_receive()})
        if not picked.ok or picked.channel ~= inbox then break end
        local topic = picked.value:topic()
        if topic == "probe.publish" then publish() end
        if topic == "window.input" then
            local body: any = picked.value:payload()
            if type(body) == "userdata" then body = body:data() end
            local event: any = body.event
            if event and event.type == "close" then break end
            if event and event.type == "resize" then
                for key, value in pairs(event) do size[key] = value end
                publish()
            end
        end
        -- What the SDK runner sends when its loop ends: a close of its own id,
        -- without a reply address. The probe stays alive after it, so the test
        -- sees what the close does, not what the exit does.
        if topic == "probe.close" then
            process.send(tostring(desktop), "desktop.close", {id = tostring(widget_id)})
        end
    end
    process.registry.unregister(name)
end

return {main = main}
