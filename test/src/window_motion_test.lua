-- Plain mouse motion reaches the focused window's client (for SDK menu hover).
--
-- The compositor sends a motion with no button and no capture to the focused
-- window only while the pointer is over its client, in client cells, once per
-- cell; over the frame, the desktop or a window without the focus nothing is
-- sent, and leaving the client forgets the cell. Two probe windows report what
-- they receive; "nothing arrived" is proven by the NEXT event being the one
-- sent after, not by waiting.
--
-- A file of its own: it boots a compositor, and the harness gives each file
-- thirty seconds — the wiring suite already spends most of its own.
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

local function define_tests()
    test.describe("windows.tui_desktop pointer motion", function()
        test.it("plain motion reaches only the focused window's client, in client cells, once per cell", function()
            local desk = boot("windows.tui_desktop.test.motion")
            local reports = process.listen("probe.event", {message = true})
            -- Mouse events from the window WITHOUT the focus: there must be none.
            local strays: any = {list = {}}

            -- The next report matching `want`; mouse reports from A are strays.
            local function next_report(want: any, what: string): any
                local expiry = time.after("5s")
                while true do
                    local picked = channel.select({reports:case_receive(), expiry:case_receive()})
                    if picked.channel == expiry or not picked.ok then
                        test.is_true(false, "no report: " .. what)
                        return {}
                    end
                    local got: any = body_of(picked.value)
                    if got.type == "mouse" and got.window == "A" then strays.list[#strays.list + 1] = got end
                    if want(got) then return got end
                end
            end
            local function next_motion(what: string): any
                return next_report(function(got: any) return got.type == "mouse" and got.window == "B" end, what)
            end
            local function move(x: integer, y: integer)
                local sent = desk.view:send({type = "mouse", action = "motion", button = "none", x = x, y = y})
                test.is_true(sent == true, "the motion did not reach the compositor")
            end

            -- A at columns 2..31, B (opened last, so focused) at 40..69; rows 3..12.
            -- The test theme's insets are one cell on every side, so the
            -- client of a window at (wx, wy) starts at (wx + 1, wy + 1) and a
            -- pointer at (wx + 5, wy + 4) is client cell (5, 4).
            local a = ask(desk, "desktop.open", {entry = "app:motion_probe", args = desk.watcher .. "|A",
                x = 2, y = 3, w = 30, h = 10})
            test.is_true(a.ok == true, "A did not open: " .. tostring(a.error))
            next_report(function(got: any) return got.window == "A" and got.type == "focus" end, "A drew and got the focus")
            local b = ask(desk, "desktop.open", {entry = "app:motion_probe", args = desk.watcher .. "|B",
                x = 40, y = 3, w = 30, h = 10})
            test.is_true(b.ok == true, "B did not open: " .. tostring(b.error))
            next_report(function(got: any) return got.window == "B" and got.type == "focus" and got.focused end,
                "B drew and got the focus")

            move(45, 7)
            local first = next_motion("motion over B's client")
            test.eq(first.action, "motion")
            test.eq(first.x, 5, "client column")
            test.eq(first.y, 4, "client row")

            -- The same cell again is not news; the next cell is.
            move(45, 7)
            move(46, 7)
            local second = next_motion("motion to the next cell")
            test.eq(second.x, 6, "the repeated cell was not sent")
            test.eq(second.y, 4)

            -- The frame, the title row, the desktop and the window without the
            -- focus get nothing: the next B report is the one sent after them.
            move(40, 7)
            move(43, 3)
            move(75, 20)
            move(7, 7)
            move(47, 8)
            local third = next_motion("motion back over B's client")
            test.eq(third.x, 7, "nothing was sent for the frame, the desktop or A")
            test.eq(third.y, 5)

            -- Leaving the client forgets the cell: coming back to it is news.
            move(75, 20)
            move(47, 8)
            local again = next_motion("the same cell after leaving")
            test.eq(again.x, 7)
            test.eq(again.y, 5)

            pause("300ms")
            while true do
                local picked = channel.select({reports:case_receive(), time.after("50ms"):case_receive()})
                if not picked.ok or picked.channel ~= reports then break end
                local got: any = body_of(picked.value)
                if got.type == "mouse" and got.window == "A" then strays.list[#strays.list + 1] = got end
            end
            test.eq(#strays.list, 0, "the window without the focus got no motion")

            process.unlisten(reports)
            process.registry.unregister(desk.watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
