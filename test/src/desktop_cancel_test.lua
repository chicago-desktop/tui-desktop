-- A desktop asked to finish closes its windows before it goes.
--
-- Under a terminal.ssh host the terminal is a connection, and a connection
-- drops; the host then asks the desktop to finish (CANCEL). The desktop must
-- shut down as "Shut Down" does: a desktop that simply died would leave its
-- windows — a bash among them — running with nobody to see them.
--
-- The other road to the same end, a frame that fails because the terminal is
-- gone, is not reachable from here: closing the test's viewport only drops a
-- viewer, the compositor's port stays open, and a grant cannot be revoked
-- from the granting side. The live terminal.ssh check covers it.
--
-- A file of its own: it boots a compositor, and the harness gives each file
-- thirty seconds.
local test = require("test")
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local WATCHER = "butschster.tui_desktop.test.cancel.watcher"

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
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "the viewport was not created")
    local pid, err = process.with_options({terminal = view:grant()})
        :spawn_monitored("app:test_composer_pixels", "app:processes", service .. "|" .. WATCHER .. "|ok")
    test.is_nil(err)
    test.not_nil(pid, "the compositor did not start")
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline and not process.registry.lookup(service) do pause("100ms") end
    test.not_nil(process.registry.lookup(service), "the compositor did not register as " .. service)
    return {pid = pid, view = view, service = service}
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
        if picked.channel == expiry or not picked.ok then break end
        local got: any = body_of(picked.value)
        if not got.unsolicited and (got.command == nil or got.command == topic) then
            answer = got
            break
        end
    end
    process.unlisten(replies)
    return answer
end

-- open_window(desk) -> the pid of an idle window opened on the desktop,
-- watched by this test.
local function open_window(desk: any): string
    local opened = ask(desk, "desktop.open", {entry = "app:idle_window", x = 10, y = 3, w = 20, h = 8})
    test.is_true(opened.ok == true, "the window did not open: " .. tostring(opened.error))
    local pid: any = nil
    for _, window in ipairs(ask(desk, "desktop.list", {}).windows or {}) do
        if window.id == opened.window.id then pid = window.pid end
    end
    test.not_nil(pid, "desktop.list does not name the window's process")
    process.monitor(tostring(pid))
    return tostring(pid)
end

-- await_exits(pids) -> the pids that did not exit within eight seconds.
local function await_exits(events: any, pids: any): any
    local waiting: any = {}
    for _, pid in ipairs(pids) do waiting[pid] = true end
    local expiry = time.after("8s")
    while next(waiting) ~= nil do
        local picked = channel.select({events:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then break end
        local event = picked.value
        if event.kind == process.event.EXIT then waiting[tostring(event.from)] = nil end
    end
    local left: any = {}
    for pid in pairs(waiting) do left[#left + 1] = pid end
    return left
end

local function define_tests()
    test.describe("butschster.tui_desktop desktop shutdown without a terminal", function()
        test.it("a cancel closes the desktop's windows, then the desktop", function()
            process.registry.register(WATCHER)
            local events = process.events()
            local desk = boot("butschster.tui_desktop.test.cancel")
            local window = open_window(desk)

            process.cancel(tostring(desk.pid), "the terminal disconnected")

            local left = await_exits(events, {window, tostring(desk.pid)})
            test.eq(#left, 0, "still running after the cancel: " .. table.concat(left, ", "))
            process.registry.unregister(WATCHER)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
