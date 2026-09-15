-- A window that opens its own dialog.
--
-- Opens TWO windows: a dialog and an ordinary program. The second is the control:
-- the link must change the dialog's fate and not touch the program's, otherwise
-- "closed together with the parent" checks not the link but that the compositor
-- closes everything in sight.
local channel = require("channel")
local process = require("process")
local time = require("time")
local desktop = require("desktop")

local function main(watcher)
    local dialog, derr = desktop.dialog({entry = "app:idle_window", title = "Properties", w = 20, h = 6})
    local plain, perr = desktop.open_wait({entry = "app:idle_window", title = "Viewer", w = 20, h = 6})

    process.send(tostring(watcher), "probe.opened", {
        dialog = dialog and dialog.id or nil,
        dialog_error = derr and tostring(derr) or nil,
        plain = plain and plain.id or nil,
        plain_error = perr and tostring(perr) or nil,
    })

    -- The window must stay alive: once closed, it would take the dialog with it
    -- on its own, and the cascade check would mean nothing.
    while true do
        local picked = channel.select({time.after("30s"):case_receive()})
        if not picked.ok then break end
    end
end

return {main = main}
