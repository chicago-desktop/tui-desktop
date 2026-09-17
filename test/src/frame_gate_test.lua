-- The frame gap follows what frames cost: a slow frame widens it at once, cheap
-- frames bring it back to the floor gradually, and it stays within its bounds.
local test = require("test")
local gate = require("frame_gate")

local function define_tests()
    test.describe("chicago.tui_desktop frame gate", function()
        test.it("cheap frames keep the floor", function()
            test.eq(gate.next(gate.FLOOR_MS, 3), gate.FLOOR_MS)
            test.eq(gate.next(nil, nil), gate.FLOOR_MS)
        end)

        test.it("a slow frame widens the gap at once, with headroom, up to the ceiling", function()
            test.eq(gate.next(gate.FLOOR_MS, 80), 120)
            test.eq(gate.next(gate.FLOOR_MS, 900), gate.CEIL_MS)
        end)

        test.it("cheap frames after slow ones ease back, never below the floor", function()
            local gap = gate.next(gate.FLOOR_MS, 160)
            test.eq(gap, 240)
            local after = gate.next(gap, 2)
            test.is_true(after < gap and after > gate.FLOOR_MS, "one cheap frame is a step, not a jump: " .. tostring(after))
            for _ = 1, 40 do gap = gate.next(gap, 2) end
            test.eq(gap, gate.FLOOR_MS)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
