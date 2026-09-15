-- The window's view: a pure library with no runtime and no permissions.
--
-- The compositor does not call it and cannot — it can neither create a raster
-- (the gfx module is not declared to the mechanics) nor load a library by name
-- from the registry. The theme that imports it calls it. It exists here so that
-- the reference in the window's entry leads to a live entry: a dead one would
-- stay silent until the first open.
local render = {}

function render.draw(state: any)
    local given: any = type(state) == "table" and state or {}
    return {title = tostring(given.title or "")}
end

return render
