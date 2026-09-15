-- A window that refuses a close the way an SDK application with a changed
-- document does: on every `close` it answers `desktop.close{refused = true}`
-- through the base's library (no id — a cells window's runner has none; the
-- compositor knows it by its process) and stays. It counts the closes it got
-- and reports each to the watcher named in its argument. No name of its own.
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")
local desktop = require("desktop")

local function main(watcher)
    local events = assert(tty.events())
    assert(tty.start())
    local out = assert(tty.surface({hide_cursor = true}))
    assert(out:present({"REFUSER"}))
    local closes = 0
    while true do
        local picked = channel.select({events:case_receive(), time.after("30s"):case_receive()})
        if not picked.ok then break end
        local event: any = picked.value
        if type(event) == "table" and event.type == "close" then
            closes = closes + 1
            process.send(tostring(watcher), "probe.closes", {count = closes})
            desktop.close(nil, {refused = true})
        end
    end
end

return {main = main}
