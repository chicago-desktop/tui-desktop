-- A window that REFUSED a close must not read as stuck (C2).
--
-- The window's own process answers a `close` with `desktop.close{refused =
-- true}`: the request is over at once, no "did not close" on the taskbar, and
-- the next × asks again. A refusal from any other process is refused and
-- changes nothing — a pending request elsewhere still ends in its notice.
--
-- A file of its own: it waits out the grace twice, and the harness gives each
-- file thirty seconds.
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

local function listed(desk: any, id: any): (any, any)
    local listing: any = ask(desk, "desktop.list", {})
    for _, window in ipairs(listing.windows or {}) do
        if tostring(window.id) == tostring(id) then return window, listing end
    end
    return nil, listing
end

local function wait_for(desk: any, id: any, seconds: number, check: any): (any, any)
    local deadline = time.now():unix_nano() + math.floor(seconds * 1000000000)
    local window, listing = listed(desk, id)
    while time.now():unix_nano() < deadline do
        if check(window, listing) then return window, listing end
        pause("100ms")
        window, listing = listed(desk, id)
    end
    return window, listing
end

local function open(desk: any, spec: any): any
    local opened: any = ask(desk, "desktop.open", spec)
    test.is_true(opened.ok == true, "the window did not open: " .. tostring(opened.error))
    local id = opened.window and opened.window.id
    local window = wait_for(desk, id, 5, function(found: any) return found ~= nil and found.ready == true end)
    test.is_true(window ~= nil and window.ready == true, "the window never got ready")
    return id
end

-- The next close count the refusing window reports, or nil after `seconds`.
local function next_count(closes: any, seconds: string): any
    local picked = channel.select({closes:case_receive(), time.after(seconds):case_receive()})
    if picked.channel ~= closes or not picked.ok then return nil end
    return body_of(picked.value).count
end

local function define_tests()
    test.describe("butschster.tui_desktop refused close", function()
        test.it("a window that refuses stays without a notice and is asked again; a stranger cannot refuse for it", function()
            local desk = boot("butschster.tui_desktop.test.refuse")
            local reports = desk.service .. ".refuser"
            process.registry.register(reports)
            local closes = process.listen("probe.closes", {message = true})

            local refuser = open(desk, {entry = "app:refusing_window", args = reports, w = 30, h = 8, x = 2, y = 2})
            ask(desk, "desktop.close", {id = refuser})
            test.eq(next_count(closes, "3s"), 1, "the window got the request")
            local window = wait_for(desk, refuser, 2, function(found: any) return found ~= nil and found.closing == false end)
            test.is_true(window ~= nil and window.closing == false, "its refusal ends the request at once")
            -- Past the grace: still there, and nothing on the taskbar calls it stuck.
            pause("3500ms")
            local listing: any
            window, listing = listed(desk, refuser)
            test.not_nil(window, "a refused close leaves the window open")
            test.eq(tostring(listing.notice or ""), "", "a refusal is not a window that did not close")
            -- The next × asks again.
            ask(desk, "desktop.close", {id = refuser})
            test.eq(next_count(closes, "3s"), 2, "a later request reaches the window again")

            -- A refusal from a process that is not the window's own.
            local stubborn = open(desk, {entry = "app:stubborn_window", w = 30, h = 8, x = 34, y = 2})
            ask(desk, "desktop.close", {id = stubborn})
            local stranger: any = ask(desk, "desktop.close", {id = stubborn, refused = true})
            test.is_true(stranger.ok == false, "a stranger may not refuse a window's close")
            test.is_true(tostring(stranger.error):find("own process", 1, true) ~= nil, tostring(stranger.error))
            local other: any = ask(desk, "desktop.close", {id = refuser, refused = true})
            test.is_true(other.ok == false, "nor refuse for a window that already answered")
            window = listed(desk, stubborn)
            test.is_true(window ~= nil and window.closing == true, "the pending request is untouched")
            window, listing = wait_for(desk, stubborn, 5, function(_: any, list: any) return list.notice == "Stubborn did not close" end)
            test.eq(listing.notice, "Stubborn did not close", "and ends in its notice as before")

            process.unlisten(closes)
            process.registry.unregister(reports)
            process.registry.unregister(desk.watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
