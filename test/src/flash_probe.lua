-- A window that asks the compositor to flash it, naming no window: the
-- compositor finds it by its process, the way it finds a window that refuses
-- its close. It has the focus when it opens, and a focused window flashes
-- only with a count, so it asks for three cycles.
local channel = require("channel")
local time = require("time")
local desktop = require("desktop")

local function main()
    desktop.flash({count = 3})
    while true do
        local picked = channel.select({time.after("30s"):case_receive()})
        if not picked.ok then break end
    end
end

return {main = main}
