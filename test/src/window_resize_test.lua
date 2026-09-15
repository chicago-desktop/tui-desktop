-- The size handle is the last two cells of the bottom frame row (G2): the
-- theme draws the Windows 95 sizing grip there, 13×13 px reaching into the
-- second cell at a 10×20 cell. A press on either cell starts the resize and the
-- window keeps the pointer's offset from the corner; the third cell from the
-- right does nothing; a window whose entry says `resizable: false` ignores the
-- handle.
--
-- Mouse input is handled in order, so "nothing happened" is proven by a later
-- resize landing, not by waiting: the presses that must do nothing are sent
-- first, and the size is read once the one after them has taken effect.
--
-- A file of its own: it boots a compositor, and the harness gives each file
-- thirty seconds.
local test = require("test")
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local function body_of(message: any): any
    local body: any = message:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function pause(duration: string)
    channel.select({time.after(duration):case_receive()})
end

local function boot(service: string): any
    local watcher = service .. ".watcher"
    process.registry.register(watcher)
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "the viewport was not created")
    local pid, err = process.with_options({terminal = view:grant()})
        :spawn_monitored("app:test_composer_pixels", "app:processes", service .. "|" .. watcher .. "|ok")
    test.is_nil(err)
    test.not_nil(pid, "the compositor did not start")
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(service) then break end
        pause("100ms")
    end
    test.not_nil(process.registry.lookup(service), "the compositor did not register as " .. service)
    return {pid = pid, view = view, service = service, watcher = watcher}
end

local function ask(desk: any, topic: string, body: any): any
    local payload: any = body or {}
    payload.reply_to = tostring(process.pid())
    local replies = process.listen("desktop.reply", {message = true})
    local sent, serr = process.send(desk.service, topic, payload)
    test.is_true(sent == true, "the command did not reach the compositor: " .. tostring(serr))
    local expiry = time.after("8s")
    local answer: any = {}
    while true do
        local picked = channel.select({replies:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then
            test.is_true(false, "no answer to " .. topic .. " (look at the compositor's screen)")
            break
        end
        local got: any = body_of(picked.value)
        if not got.unsolicited and (got.command == nil or got.command == topic) then
            answer = got
            break
        end
    end
    process.unlisten(replies)
    return answer
end

local function geometry(desk: any, id: any): any
    local listed = ask(desk, "desktop.list", {})
    for _, window in ipairs(listed.windows or {}) do
        if window.id == id then return window end
    end
    return {}
end

-- The window's geometry once `ready(window)` holds, or the last one read when
-- it never does within five seconds.
local function settled(desk: any, id: any, ready: any): any
    local deadline = time.now():unix_nano() + 5000000000
    local window: any = geometry(desk, id)
    while not ready(window) and time.now():unix_nano() < deadline do
        pause("100ms")
        window = geometry(desk, id)
    end
    return window
end

local function define_tests()
    test.describe("chicago.tui_desktop size handle", function()
        test.it("the last two cells of the bottom frame row resize; the third does not, nor a fixed window", function()
            local desk = boot("chicago.tui_desktop.test.resize")
            local function mouse(action: string, x: integer, y: integer)
                local sent = desk.view:send({type = "mouse", action = action, button = "left", x = x, y = y})
                test.is_true(sent == true, "the mouse event did not reach the compositor")
            end
            -- press at (x, y), drag to (x + dx, y + dy), release there.
            local function drag(x: integer, y: integer, dx: integer, dy: integer)
                mouse("press", x, y)
                mouse("motion", x + dx, y + dy)
                mouse("release", x + dx, y + dy)
            end

            local fixed = ask(desk, "desktop.open", {entry = "app:fixed_window", x = 2, y = 3})
            test.is_true(fixed.ok == true, "the fixed window did not open: " .. tostring(fixed.error))
            local sized = ask(desk, "desktop.open", {entry = "app:idle_window", x = 40, y = 3, w = 20, h = 8})
            test.is_true(sized.ok == true, "the resizable window did not open: " .. tostring(sized.error))

            local f = geometry(desk, fixed.window.id)
            local r = geometry(desk, sized.window.id)
            test.is_false(f.resizable, "the entry declares resizable: false")
            test.is_true(r.resizable)
            test.eq(r.width, 20)
            test.eq(r.height, 8)
            local f_right, f_bottom = f.x + f.width - 1, f.y + f.height - 1
            local r_right, r_bottom = r.x + r.width - 1, r.y + r.height - 1

            -- A fixed window ignores both cells of the handle.
            drag(f_right, f_bottom, 3, 2)
            drag(f_right - 1, f_bottom, 3, 2)
            -- The second-to-last cell takes the resizable window, and the
            -- corner stays one column right of the pointer: +3 columns, +2 rows.
            drag(r_right - 1, r_bottom, 3, 2)
            local after = settled(desk, sized.window.id, function(window: any) return window.width ~= 20 end)
            test.eq(after.width, 23, "the second-to-last cell resizes, keeping the offset")
            test.eq(after.height, 10)
            local still = geometry(desk, fixed.window.id)
            test.eq(still.width, f.width, "a fixed window ignores the handle")
            test.eq(still.height, f.height)

            -- The third cell from the right is frame, not handle; the last cell
            -- is still the handle: only the second drag counts (+2, +2).
            r_right, r_bottom = after.x + after.width - 1, after.y + after.height - 1
            drag(r_right - 2, r_bottom, 3, 1)
            drag(r_right, r_bottom, 2, 2)
            local final = settled(desk, sized.window.id, function(window: any) return window.width ~= 23 end)
            test.eq(final.width, 25, "the third cell did nothing, the last cell resized")
            test.eq(final.height, 12)

            process.registry.unregister(desk.watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
