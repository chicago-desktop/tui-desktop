-- The compositor tells windows when they gain and lose the keyboard.
--
-- A live compositor on the test's viewport, two probe windows, and the
-- events each of them received, in order. Minimizing goes through the real
-- input path — Alt+M into the compositor's screen — not a command: a check
-- that needs its own way to press would add that way to the interface.
local test = require("test")
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local SERVICE = "windows.tui_desktop.test.focus"
local WATCHER = "windows.tui_desktop.test.focus_watcher"

local function body_of(message: any): any
    local body: any = message:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function boot(): any
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "the viewport was not created")
    local grant = view:grant()
    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("app:test_composer", "app:processes", SERVICE)
    test.is_nil(err)
    test.not_nil(pid, "the compositor did not start")
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(SERVICE) then break end
        channel.select({time.after("100ms"):case_receive()})
    end
    test.not_nil(process.registry.lookup(SERVICE), "the compositor did not register as " .. SERVICE)
    return {pid = pid, view = view}
end

-- A command with a reply, heard on the reply topic subscribed BEFORE sending.
local function ask(topic: string, body: any): any
    local payload: any = body or {}
    payload.reply_to = tostring(process.pid())
    local replies = process.listen("desktop.reply", {message = true})
    local sent, serr = process.send(SERVICE, topic, payload)
    test.is_true(sent == true, "the command did not reach the compositor: " .. tostring(serr))
    local expiry = time.after("8s")
    local answer: any = {}
    while true do
        local picked = channel.select({replies:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then
            test.is_true(false, "no answer to " .. topic)
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

-- Reads focus reports until every window in `want` has at least that many,
-- or the budget runs out. `seen` accumulates "in"/"out" per window name.
local function collect(inbox: any, seen: any, want: any, budget: string)
    local deadline = time.after(budget)
    local function done(): boolean
        for name, count in pairs(want) do
            if #(seen[name] or {}) < count then return false end
        end
        return true
    end
    while not done() do
        local picked = channel.select({inbox:case_receive(), deadline:case_receive()})
        if picked.channel == deadline or not picked.ok then break end
        local message = picked.value
        if message:topic() == "focus.seen" then
            local body: any = body_of(message)
            local name = tostring(body.window)
            local list = seen[name] or {}
            seen[name] = list
            list[#list + 1] = body.focused == true and "in" or "out"
        end
    end
end

local function joined(list: any): string
    return table.concat(list or {}, ",")
end

local function define_tests()
    test.describe("windows.tui_desktop window focus", function()
        test.it("tells the old window it lost the keyboard and the new one it has it, on open and on minimize", function()
            local inbox = process.inbox()
            process.registry.register(WATCHER)
            local desk = boot()
            local seen: any = {}

            local first = ask("desktop.open", {entry = "app:focus_probe", args = "A", x = 2, y = 3, w = 30, h = 8})
            test.is_true(first.ok == true, "A did not open: " .. tostring(first.error))
            collect(inbox, seen, {A = 1}, "8s")
            test.eq(joined(seen.A), "in", "the only window gets the keyboard once it has drawn")

            local second = ask("desktop.open", {entry = "app:focus_probe", args = "B", x = 10, y = 5, w = 30, h = 8})
            test.is_true(second.ok == true, "B did not open: " .. tostring(second.error))
            collect(inbox, seen, {A = 2, B = 1}, "8s")
            test.eq(joined(seen.A), "in,out", "a new window on top takes the keyboard from A")
            test.eq(joined(seen.B), "in")

            -- Alt+M minimizes the focused window, through the compositor's screen.
            local pressed = desk.view:send({type = "key", key = "m", key_type = "runes", action = "press", alt = true})
            test.is_true(pressed == true, "the key did not reach the compositor's screen")
            collect(inbox, seen, {A = 3, B = 2}, "8s")
            test.eq(joined(seen.B), "in,out", "a minimized window loses the keyboard")
            test.eq(joined(seen.A), "in,out,in", "and the window under it gets it back")

            -- Nothing more arrives: a frame without a focus change says nothing.
            collect(inbox, seen, {A = 4}, "600ms")
            test.eq(joined(seen.A), "in,out,in", "no repeated focus events")
            test.eq(joined(seen.B), "in,out")
            test.is_nil(seen["?"], "every probe knows its name: the open args reached the window")

            process.registry.unregister(WATCHER)
            process.terminate(tostring(desk.pid))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
