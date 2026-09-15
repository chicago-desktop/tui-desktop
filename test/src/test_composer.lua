-- The whole compositor, brought up in a test.
--
-- Its screen is real, only not a terminal but a viewport handed out by the test:
-- so the window kinship check goes through a live compositor rather than
-- through the registry's shape. The name arrives as an argument so that runs
-- do not fight over one.
local library = require("library")
local chrome = require("chrome")

local function main(service)
    local ok, err = library.run({
        chrome = chrome,
        service_name = tostring(service),
        restore = false,
    })
    return ok, err
end

return {main = main}
