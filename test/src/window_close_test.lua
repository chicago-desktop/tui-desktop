-- A close is a request a window may refuse (Notepad's "save changes?").
--
-- The title bar's ×, ctrl+w and a plain `desktop.close` send `close` and wait:
-- a window that answers by closing goes; one that does not stays after the
-- grace (3 s), and the status line says "<title> did not close". Shutdown and
-- `desktop.close{force = true}` kill after the grace, as every close did
-- before; a PTY window is always closed that way.
--
-- A file of its own: it boots two compositors and waits out the grace twice,
-- and the harness gives each file thirty seconds.
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

-- A command with a reply, heard on the reply topic subscribed BEFORE sending.
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

-- The listed window with this id, or nil; and the list itself.
local function listed(desk: any, id: any): (any, any)
    local listing: any = ask(desk, "desktop.list", {})
    for _, window in ipairs(listing.windows or {}) do
        if tostring(window.id) == tostring(id) then return window, listing end
    end
    return nil, listing
end

-- Wait until `check(window, listing)` holds, polling the list; seconds is the cap.
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
    -- Ready: its terminal started, so it gets `close` rather than a kill.
    local window = wait_for(desk, id, 5, function(found: any) return found ~= nil and found.ready == true end)
    test.is_true(window ~= nil and window.ready == true, "the window never got ready")
    return id
end

local function define_tests()
    test.describe("chicago.tui_desktop close requests", function()
        test.it("a window that refuses stays with a notice; one that closes itself goes; force kills; a PTY closes", function()
            local desk = boot("chicago.tui_desktop.test.close")

            local stubborn = open(desk, {entry = "app:stubborn_window", w = 30, h = 8, x = 2, y = 2})
            local answer = ask(desk, "desktop.close", {id = stubborn})
            test.is_true(answer.ok == true)
            local window = listed(desk, stubborn)
            test.is_true(window ~= nil and window.closing == true, "the request is pending")
            -- Past the grace: it is still there, no longer closing, and the
            -- status line names it.
            local listing: any
            window, listing = wait_for(desk, stubborn, 6, function(found: any, list: any)
                return found ~= nil and found.closing == false and tostring(list.notice):find("did not close", 1, true) ~= nil
            end)
            test.not_nil(window, "a refused close does not kill the window")
            test.is_true(window ~= nil and window.closing == false, "and it is no longer closing")
            test.eq(listing.notice, "Stubborn did not close")
            -- A second request is taken again.
            ask(desk, "desktop.close", {id = stubborn})
            window = listed(desk, stubborn)
            test.is_true(window ~= nil and window.closing == true, "a second request is accepted")
            -- Force over the pending request: killed after the grace.
            ask(desk, "desktop.close", {id = stubborn, force = true})
            window = wait_for(desk, stubborn, 6, function(found: any) return found == nil end)
            test.is_nil(window, "force kills a window that refuses")

            local polite = open(desk, {entry = "app:painter_window", w = 30, h = 8, x = 34, y = 2})
            ask(desk, "desktop.close", {id = polite})
            window = wait_for(desk, polite, 2, function(found: any) return found == nil end)
            test.is_nil(window, "a window that answers close by closing goes before the grace")

            local opened: any = ask(desk, "desktop.open", {command = "sleep 30", w = 30, h = 8, x = 2, y = 12})
            test.is_true(opened.ok == true, "the PTY window did not open: " .. tostring(opened.error))
            local pty = opened.window and opened.window.id
            wait_for(desk, pty, 5, function(found: any) return found ~= nil and found.ready == true end)
            ask(desk, "desktop.close", {id = pty})
            local gone, after = wait_for(desk, pty, 5, function(found: any) return found == nil end)
            test.is_nil(gone, "a PTY window closes as before")
            test.is_true(tostring(after.notice):find("did not close", 1, true) == nil or after.notice == "Stubborn did not close",
                "and never as a refusal: " .. tostring(after.notice))

            process.registry.unregister(desk.watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("shutdown does not ask: a window that refuses is killed after the grace, a pending request too", function()
            local desk = boot("chicago.tui_desktop.test.close.quit")
            open(desk, {entry = "app:stubborn_window", w = 30, h = 8, x = 2, y = 2})
            local waiting = open(desk, {entry = "app:stubborn_window", w = 30, h = 8, x = 34, y = 2})
            -- A request already pending when shutdown comes: shutdown stops
            -- waiting for the answer and forces it too.
            ask(desk, "desktop.close", {id = waiting})
            desk.view:send({type = "key", action = "press", key_type = "runes", key = "q", ctrl = true})
            -- The compositor leaves once every window is gone: with the
            -- refusing one killed after the grace, well inside eight seconds.
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline and process.registry.lookup(desk.service) do
                pause("100ms")
            end
            test.is_nil(process.registry.lookup(desk.service), "shutdown finished: the refusing window was killed")
            process.registry.unregister(desk.watcher)
            desk.view:close()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
