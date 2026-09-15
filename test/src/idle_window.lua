-- A window that simply exists.
--
-- No frame, no input: what is checked is window kinship, not drawing. `tty.start()`
-- is deliberately not called — the compositor kills such a window at once, without
-- the polite grace period, and the test does not have to wait three seconds for the close.
local channel = require("channel")
local time = require("time")

local function main()
    while true do
        local picked = channel.select({time.after("30s"):case_receive()})
        if not picked.ok then break end
    end
end

return {main = main}
