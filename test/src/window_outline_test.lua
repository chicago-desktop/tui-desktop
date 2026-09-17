-- A move or resize drag shows an OUTLINE, and the window takes its rect on the
-- release, as in Windows 95: while the pointer moves, desktop.list still
-- reports the old place; the release applies the new one; Esc drops the
-- outline. And a burst of motions costs a few frames, not one per motion (the
-- frame gate): a frame per motion backed the loop up until nothing, the clock
-- included, was drawn.
--
-- Input is handled in order, so "the motion was handled" is read off the frame
-- counter, and "nothing happened" is proven by a later drag landing.
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

local function listed(desk: any): any
    return ask(desk, "desktop.list", {})
end

local function geometry(desk: any, id: any): any
    for _, window in ipairs(listed(desk).windows or {}) do
        if window.id == id then return window end
    end
    return {}
end

local function frames(desk: any): integer
    local report: any = listed(desk).frame or {}
    return math.tointeger(report.frames_total) or 0
end

-- Wait until `ready()` holds, or five seconds.
local function until_true(ready: any)
    local deadline = time.now():unix_nano() + 5000000000
    while not ready() and time.now():unix_nano() < deadline do pause("50ms") end
end

local function define_tests()
    test.describe("chicago.tui_desktop outline drag", function()
        test.it("the window stays until the release, Esc drops the outline, and a burst of motions is a few frames", function()
            local desk = boot("chicago.tui_desktop.test.outline")
            local function send(event: any)
                test.is_true(desk.view:send(event) == true, "the event did not reach the compositor")
            end
            local function mouse(action: string, x: integer, y: integer)
                send({type = "mouse", action = action, button = "left", x = x, y = y})
            end
            local opened = ask(desk, "desktop.open", {entry = "app:idle_window", x = 10, y = 3, w = 20, h = 8})
            test.is_true(opened.ok == true, "the window did not open: " .. tostring(opened.error))
            local id = opened.window.id
            local start = geometry(desk, id)

            -- Press on the title, move: the press and the motion are painted
            -- (two frames), and the window has not moved.
            local before = frames(desk)
            mouse("press", start.x + 4, start.y)
            mouse("motion", start.x + 10, start.y + 3)
            until_true(function() return frames(desk) >= before + 2 end)
            local held = geometry(desk, id)
            test.eq(tostring(held.x) .. "," .. tostring(held.y), tostring(start.x) .. "," .. tostring(start.y),
                "while the pointer moves only the outline follows it")
            test.eq(held.width, start.width)
            mouse("release", start.x + 10, start.y + 3)
            local moved: any = {}
            until_true(function() moved = geometry(desk, id); return moved.x ~= start.x end)
            test.eq(tostring(moved.x) .. "," .. tostring(moved.y), tostring(start.x + 6) .. "," .. tostring(start.y + 3),
                "the release moves the window to the outline")

            -- Esc drops the outline: a later drag lands from the old place.
            mouse("press", moved.x + 4, moved.y)
            mouse("motion", moved.x + 9, moved.y + 1)
            send({type = "key", key_type = "esc", key = "esc", action = "press"})
            mouse("release", moved.x + 9, moved.y + 1)
            mouse("press", moved.x + 4, moved.y)
            mouse("motion", moved.x + 6, moved.y)
            mouse("release", moved.x + 6, moved.y)
            local after: any = {}
            until_true(function() after = geometry(desk, id); return after.x ~= moved.x end)
            test.eq(tostring(after.x) .. "," .. tostring(after.y), tostring(moved.x + 2) .. "," .. tostring(moved.y),
                "Esc dropped the first outline; only the second drag moved it")

            -- Motions that leave the outline where it is draw nothing. Each is
            -- apart from the last by more than the frame gate, so without the
            -- check every one of them would be a frame of its own.
            mouse("press", after.x + 4, after.y)
            mouse("motion", after.x + 5, after.y + 1)
            local settled = frames(desk)
            until_true(function()
                local now = frames(desk)
                if now ~= settled then settled = now; return false end
                return now > 0
            end)
            pause("150ms")
            local still_from = frames(desk)
            for _ = 1, 5 do
                mouse("motion", after.x + 5, after.y + 1)
                pause("60ms")
            end
            pause("150ms")
            test.eq(frames(desk) - still_from, 0, "motions that do not move the outline are not painted")
            send({type = "key", key_type = "esc", key = "esc", action = "press"})
            mouse("release", after.x + 5, after.y + 1)

            -- A burst of forty motions during a drag: a few frames, not forty.
            local burst_from = frames(desk)
            mouse("press", after.x + 4, after.y)
            for step = 1, 40 do mouse("motion", after.x + 4 + step % 3, after.y + step % 2) end
            mouse("release", after.x + 5, after.y)
            local last: any = {}
            until_true(function() last = geometry(desk, id); return last.x ~= after.x end)
            local spent = frames(desk) - burst_from
            test.is_true(spent < 15, "forty motions were painted as " .. tostring(spent) .. " frames")
            local report: any = listed(desk).frame or {}
            local triggers: any = type(report.window) == "table" and report.window.triggers or {}
            test.not_nil(triggers.batch, "the merged frames are named batch in the report")

            process.registry.unregister(desk.watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
