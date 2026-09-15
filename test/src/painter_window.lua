-- A window that puts one recognizable line into its viewport.
--
-- It is needed because in pixel mode the window's content is placed by the
-- compositor: an empty window would not tell "placed it" from "nothing to place".
local channel = require("channel")
local time = require("time")
local tty = require("tty")

local MARK = "CONTENT"

local function main()
    local events = assert(tty.events())
    assert(tty.start())
    local out = assert(tty.surface({hide_cursor = true}))

    local width, height = tty.screen_size()
    width = math.tointeger(math.floor(tonumber(width) or 0)) or 0
    height = math.tointeger(math.floor(tonumber(height) or 0)) or 0
    if width < 12 then width = 12 end
    if height < 2 then height = 2 end

    local rows = {}
    for index = 1, height do rows[index] = index == 1 and MARK or "" end
    assert(out:present(rows))

    while true do
        local picked = channel.select({events:case_receive(), time.after("30s"):case_receive()})
        if not picked.ok then break end
        if picked.value ~= nil and type(picked.value) == "table"
            and picked.value.type == "close" then break end
    end

    assert(out:close())
    assert(tty.stop())
end

return {main = main}
