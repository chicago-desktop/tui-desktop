local channel = require("channel")
local tty = require("tty")
local function main()
    local events = assert(tty.events())
    assert(tty.start())
    local surface = assert(tty.surface({hide_cursor=true}))
    local keys, clicks, point = 0, 0, ""
    assert(surface:present({"Keys: 0 Clicks: 0"}))
    while true do
        local picked = channel.select({events:case_receive()})
        if not picked.ok then break end
        local event = picked.value
        if event.type == "close" then break end
        if event.type == "key" and event.action ~= "release" then keys=keys+1 end
        if event.type == "mouse" and event.action == "press" then clicks=clicks+1;point=" At: "..event.x..","..event.y end
        assert(surface:present({"Keys: "..keys.." Clicks: "..clicks..point}))
    end
    surface:close()
    tty.stop()
end
return {main=main}
