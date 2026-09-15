-- Stub window: reports which compositor it addresses.
--
-- A real window draws itself and calls desktop.open; here only the half of it is
-- needed that the registry's shape cannot check — the compositor's name that
-- arrived (or did not arrive) at launch.
local process = require("process")
local desktop = require("desktop")

local function main(reply_to)
    local name, source = desktop.service()
    -- This must not be written as a bare `return process.send(...)`: a tail call
    -- of a yield function in go-lua v1.5.18 is not executed at all.
    local sent, serr = process.send(tostring(reply_to), "probe.service",
        {name = name, source = source})
    return sent, serr
end

return {main = main}
