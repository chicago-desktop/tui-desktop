-- A window that reports every mouse and focus event it receives, in order.
--
-- The argument is "<watcher>|<label>": the reports go to the watcher the test
-- registered under its own name. Test files run in parallel, so a probe with
-- one fixed name would answer the neighbouring file's test.
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local function main(args)
    local watcher, label = tostring(args or ""):match("^([^|]+)|(.+)$")
    local events = assert(tty.events())
    assert(tty.start())
    local out = assert(tty.surface({hide_cursor = true}))
    assert(out:present({"motion probe " .. tostring(label)}))

    while true do
        local picked = channel.select({events:case_receive(), time.after("30s"):case_receive()})
        if not picked.ok then break end
        local event: any = picked.value
        if type(event) == "table" then
            if event.type == "close" then break end
            if event.type == "focus" and watcher then
                process.send(watcher, "probe.event", {window = label, type = "focus", focused = event.focused == true})
            elseif event.type == "mouse" and watcher then
                process.send(watcher, "probe.event", {window = label, type = "mouse", action = event.action,
                    button = event.button, x = event.x, y = event.y})
            end
        end
    end

    assert(out:close())
    assert(tty.stop())
end

return {main = main}
