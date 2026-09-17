-- The gap the compositor keeps between two frames, adapted to what frames
-- cost.
--
-- A fixed gap of FLOOR_MS is right while a frame is cheap. When one costs
-- more than the gap — a wallpaper over a sixel terminal, a big window
-- repainted — the next request is due before the last frame is out, the loop
-- paints back to back, and a press or a motion waits behind frames nobody
-- will see. So the gap follows the last frame's cost with some headroom, and
-- eases back to the floor as frames get cheap again, a step at a time: one
-- cheap frame in a slow stream is not a reason to go back to 30 per second.
local frame_gate = {}

-- The gap for cheap frames: about thirty frames a second.
frame_gate.FLOOR_MS = 33
-- The longest gap: a slow terminal still shows motion four times a second.
frame_gate.CEIL_MS = 250
-- How much longer than the last frame the gap is.
frame_gate.HEADROOM = 1.5
-- How much of the distance to the floor one cheap frame takes back.
frame_gate.EASE = 0.25

-- next(gap, cost) -> the gap after a frame that took `cost` milliseconds.
function frame_gate.next(gap: any, cost: any): integer
    local current = tonumber(gap) or frame_gate.FLOOR_MS
    local spent = tonumber(cost) or 0
    local wanted = math.max(frame_gate.FLOOR_MS, spent * frame_gate.HEADROOM)
    local after
    if wanted >= current then
        after = wanted
    else
        after = current - (current - wanted) * frame_gate.EASE
    end
    after = math.min(frame_gate.CEIL_MS, math.max(frame_gate.FLOOR_MS, after))
    -- Down, not to nearest: rounding to nearest parks the gap a step above
    -- the floor, where a quarter of the distance rounds back to itself.
    return math.tointeger(math.floor(after)) or frame_gate.FLOOR_MS
end

return frame_gate
