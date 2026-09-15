-- pixels.frame blanks the cells under a picture — its gaps would otherwise
-- show the text through — but not under an overlay (a drag's outline), which
-- is transparent but for its line: the text under it stays.
local test = require("test")
local tty = require("tty")
local pixels = require("pixels")

local function plain(row: any): string
    return (tostring(row or ""):gsub("\27%[[%d;:]*m", ""))
end

local function define_tests()
    test.describe("chicago.tui_desktop pixels.frame", function()
        test.it("blanks the cells under a picture, not under an overlay", function()
            local canvas = tty.canvas(20, 4)
            canvas:clear(" ")
            canvas:put(1, 1, "abcdefghij", 10)
            canvas:put(1, 3, "klmnopqrst", 10)
            local images, complaints = pixels.frame(canvas, {placements = {
                {id = "picture", x = 1, y = 1, cols = 4, rows = 1},
                {id = "outline", x = 1, y = 3, cols = 4, rows = 1, overlay = true},
            }})
            test.eq(#complaints, 0, tostring(complaints[1]))
            test.eq(#images, 2, "both are placed")
            local rows: any = canvas:rows()
            test.eq(plain(rows[1]):sub(1, 10), "    efghij", "the picture's cells are blanked")
            test.eq(plain(rows[3]):sub(1, 10), "klmnopqrst", "the overlay's are not")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
