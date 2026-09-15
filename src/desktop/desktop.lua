-- The default shell: the compositor with the standard theme.
--
-- All the mechanics are in `library`; here is only the choice of the look and
-- of the name under which the desktop is visible to processes. A second shell
-- (another module) calls the same library with its own theme and its own
-- name, without copying window hosting, the PTY, or the command channel.

local library = require("library")
local chrome = require("chrome")

local function main()
    -- This must not be written as a bare `return library.run(...)`: in go-lua
    -- v1.5.18 a tail call of a yield function from a coroutine's base frame is
    -- not executed at all — silently, in 0 ms.
    local ok, err = library.run({
        chrome = chrome,
        service_name = "windows.tui_desktop.desktop",
        hint = "alt+n — bash window · alt+o — applications · ctrl+q — quit",
    })
    return ok, err
end

return {main = main}
