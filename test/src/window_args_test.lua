-- The window description reports `args` (FR-008 §3 of windows/shell).
--
-- A folder window opens with its path in `args`; opening the same folder
-- again must raise that window, not open a second one, and the opener can
-- tell only from `desktop.list`. So both kinds of window keep the argument
-- they were opened with — a process window and a view window, two records
-- built in two places — and `describe` reports it.
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

-- A command with a reply, heard on the reply topic subscribed BEFORE sending.
-- A refusal that arrived by itself (`unsolicited`) is not the answer.
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
    test.describe("windows.tui_desktop window args", function()
        test.it("desktop.open and desktop.list report the args a window was opened with, for both kinds of window", function()
            local desk = boot("windows.tui_desktop.test.args")

            local with: any = ask(desk, "desktop.open",
                {entry = "app:idle_window", args = "drive/app:fs/ui", w = 30, h = 8, x = 2, y = 2})
            test.is_true(with.ok == true, "the window did not open: " .. tostring(with.error))
            test.eq(with.window.args, "drive/app:fs/ui", "the open reply reports the args")

            local without: any = ask(desk, "desktop.open", {entry = "app:idle_window", w = 30, h = 8, x = 34, y = 2})
            test.is_true(without.ok == true, "the window did not open: " .. tostring(without.error))
            test.is_nil(without.window.args, "no args, none reported — not an empty string")

            -- A view window WITHOUT a state provider: `app:view_window`'s
            -- provider registers one shared name, and a second one here would
            -- answer the view test running beside this file.
            local shown: any = ask(desk, "desktop.open",
                {entry = "app:args_view", args = "drive/app:fs", w = 30, h = 8, x = 2, y = 12})
            test.is_true(shown.ok == true, "the view window did not open: " .. tostring(shown.error))
            test.eq(shown.window.args, "drive/app:fs", "a view window keeps its args too")

            local listing: any = ask(desk, "desktop.list", {})
            local by_id: any = {}
            for _, window in ipairs(listing.windows or {}) do by_id[tostring(window.id)] = window end
            test.eq(by_id[tostring(with.window.id)].args, "drive/app:fs/ui")
            test.is_nil(by_id[tostring(without.window.id)].args)
            test.eq(by_id[tostring(shown.window.id)].args, "drive/app:fs")

            process.registry.unregister(desk.watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
