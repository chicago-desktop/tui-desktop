-- The stock cell theme plus desktop widgets, for the cells mode of the
-- compositor.
--
-- In cells mode `fill` is called at another place of the frame than in pixel
-- mode, and both must hand the theme `state.widgets`. This theme draws what
-- the stock one draws, then the widget marks and hit records of the pixel test
-- theme — without ids here, in the exact record shape of FR-006 §5.
local stock = require("stock")
local pixel_chrome = require("pixel_chrome")

local chrome = {}
for key, value in pairs(stock) do chrome[key] = value end

function chrome.fill(canvas: any, width: any, height: any, state: any)
    local given: any = stock.fill(canvas, width, height, state)
    local hits = {}
    for _, hit in ipairs(type(given) == "table" and given or {}) do hits[#hits + 1] = hit end
    pixel_chrome.mark_widgets(canvas, state)
    for _, hit in ipairs(pixel_chrome.widget_hits(width, state, false)) do hits[#hits + 1] = hit end
    return hits
end

return chrome
