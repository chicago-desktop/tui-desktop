-- The same raster theme, but returning hits as a FLAT list.
--
-- Exactly the mistake the specification allows a reader to make: "hits — as
-- now". "As now" is three different lists from three calls, and `id` means
-- something different in each. The theme exists to check that the mechanics
-- does not guess at such a list but names the reason where a person will see it.
local base = require("pixel_chrome")

local chrome = {}
for key, value in pairs(base) do chrome[key] = value end

function chrome.paint(state: any, cell_w, cell_h)
    local painted: any = base.paint(state, cell_w, cell_h)
    local flat = {}
    for _, hit in ipairs(painted.hits.bars) do flat[#flat + 1] = hit end
    return {placements = painted.placements, hits = flat}
end

return chrome
