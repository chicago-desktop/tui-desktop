-- A window that reports every focus event it receives, in order.
--
-- The compositor tells a window when it gains and loses the keyboard with the
-- runtime's terminal event `{type = "focus", focused = …}`. This window draws
-- one frame (a window that never drew is not `ready`, and nothing is sent to
-- it), then forwards each focus event to the test under its own name — the
-- argument it was opened with.
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local WATCHER = "windows.tui_desktop.test.focus_watcher"

local function main(args)
    local name = tostring(args or "?")
    local events = assert(tty.events())
    assert(tty.start())
    local out = assert(tty.surface({hide_cursor = true}))
    assert(out:present({"focus probe " .. name}))

    while true do
        local picked = channel.select({events:case_receive(), time.after("30s"):case_receive()})
        if not picked.ok then break end
        local event: any = picked.value
        if type(event) == "table" then
            if event.type == "close" then break end
            if event.type == "focus" then
                process.send(WATCHER, "focus.seen", {window = name, focused = event.focused == true})
            end
        end
    end

    assert(out:close())
    assert(tty.stop())
end

return {main = main}
