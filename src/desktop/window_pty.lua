-- A window with a real program.
--
-- The process gets an ordinary tty port — in fact the compositor's viewport —
-- and hands it to the program under a PTY. It knows neither its position on
-- the screen nor that other windows lie over it; that is the whole point of
-- the boundary.
--
-- There is no surface of its own here and there cannot be: attach_terminal()
-- takes the port's lease for itself, and there is one lease per port.

local channel = require("channel")
local exec = require("exec")
local tty = require("tty")

local EXECUTOR = "windows.tui_desktop:exec"
-- Interactive Bash reads ~/.bashrc; the host config supplies HOME and PATH
-- on the dedicated PTY executor (exec.native does not inherit OS variables).
local DEFAULT_COMMAND = "/bin/bash -i"

local function main(command)
    -- Subscribe before the start: start() emits the first event, and the
    -- subscriber must already exist.
    local events = assert(tty.events())
    assert(tty.start())

    local executor = assert(exec.get(EXECUTOR))

    -- The PTY size is not set: attach_terminal reads the port's screen_size(),
    -- that is, the window's inner size. After that it is changed by resize
    -- events that the compositor sends when an edge is dragged.
    local proc, perr = executor:exec(
        type(command) == "string" and command ~= "" and command or DEFAULT_COMMAND,
        {pty = {term = "xterm-256color"}})
    if not proc then
        executor:release()
        error("the window could not start the program: " .. tostring(perr))
    end

    -- attach_terminal CONSUMES proc: from here on the lifecycle owner is the
    -- session, and the original handle must not be used.
    local session, serr = proc:attach_terminal()
    if not session then
        executor:release()
        error("the window could not take the terminal: " .. tostring(serr))
    end

    local done = session:done()

    while true do
        local selected = channel.select({
            events:case_receive(),
            done:case_receive(),
        })
        if not selected.ok or selected.channel == done then break end

        local event = selected.value
        -- `close` is sent by the compositor; a real terminal does not emit it.
        if event.type == "close" then break end

        -- This call must not be written as a bare `return session:send(event)`:
        -- a tail call of a yield function in go-lua v1.5.18 is not executed.
        assert(session:send(event))
    end

    assert(session:close())
    assert(executor:release())
    assert(tty.stop())
end

return {main = main}
