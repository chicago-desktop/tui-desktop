-- A window whose entry names `meta.requires` opens only for a logged-on
-- identity whose scope allows that action.
--
-- The bash window runs under its entry's policy, not the person's: it is a
-- shell on the server. Under a terminal.ssh host anyone with an account can
-- log on, so a shell must be refused to a person the application did not
-- give it to — and the refusal must say why.
--
-- A file of its own: it boots two compositors, and the harness gives each
-- file thirty seconds.
local test = require("test")
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local WATCHER = "windows.tui_desktop.test.requires.watcher"

local function body_of(message: any): any
    local body: any = message:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function pause(duration: string)
    channel.select({time.after(duration):case_receive()})
end

-- boot(service, kind) -> the desktop, or fails with what the compositor said.
local function boot(service: string, kind: string): any
    local refusals = process.listen("composer.refused", {message = true})
    local view = tty.viewport({width = 80, height = 24})
    local pid, err = process.with_options({terminal = view:grant()})
        :spawn_monitored("app:test_composer_pixels", "app:processes", service .. "|" .. WATCHER .. "|" .. kind)
    test.is_nil(err)
    local refused: any = nil
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline and not process.registry.lookup(service) do
        local picked = channel.select({refusals:case_receive(), time.after("100ms"):case_receive()})
        if picked.channel == refusals and picked.ok then refused = body_of(picked.value).error; break end
    end
    process.unlisten(refusals)
    test.is_nil(refused, "the compositor refused to start: " .. tostring(refused))
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

local function define_tests()
    test.describe("windows.tui_desktop meta.requires", function()
        test.it("a shell is refused to a person without the right, and opens past the check for one with it", function()
            process.registry.register(WATCHER)

            local user = boot("windows.tui_desktop.test.requires.user", "user")
            local refused = ask(user, "desktop.open", {command = "/bin/true"})
            test.is_true(refused.ok == false, "a shell opened for a person without tui_desktop.pty")
            local reason = tostring(refused.error)
            test.is_true(string.find(reason, "tui_desktop.pty", 1, true) ~= nil,
                "the refusal must name what is missing: " .. reason)
            test.is_true(string.find(reason, "Tester", 1, true) ~= nil,
                "the refusal must name who was refused: " .. reason)
            process.terminate(tostring(user.pid))

            -- Past the check: whatever the spawn itself says afterwards, it is
            -- not this refusal.
            local admin = boot("windows.tui_desktop.test.requires.admin", "admin")
            local opened = ask(admin, "desktop.open", {command = "/bin/true"})
            test.is_true(string.find(tostring(opened.error), "may not open", 1, true) == nil,
                "a person whose scope allows tui_desktop.pty was refused: " .. tostring(opened.error))
            process.terminate(tostring(admin.pid))
            process.registry.unregister(WATCHER)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
