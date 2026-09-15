-- A window that refuses to close: it starts its terminal (so the compositor
-- counts it ready and sends it `close`) and then ignores every `close`, the
-- way an application with a changed document answers "not yet". Only a kill
-- ends it. It registers no name: the test reads the compositor's own list.
local channel = require("channel")
local time = require("time")
local tty = require("tty")

local function main()
    local events = assert(tty.events())
    assert(tty.start())
    local out = assert(tty.surface({hide_cursor = true}))
    assert(out:present({"STUBBORN"}))
    while true do
        local picked = channel.select({events:case_receive(), time.after("30s"):case_receive()})
        if not picked.ok then break end
        -- `close` is read and dropped on purpose.
    end
end

return {main = main}
