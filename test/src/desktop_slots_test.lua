-- Several desktops in one runtime (a terminal.ssh host gives every connection
-- its own) answer to `name`, `name.2`, …: each claims the first free name, a
-- name is released with its desktop, and window_api.desktops finds every one
-- running — the registry has no listing, so this rule is the directory.
--
-- A file of its own: it boots three compositors, and the harness gives each
-- file thirty seconds.
local test = require("test")
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")
local desktop = require("desktop")

local FAMILY = "butschster.tui_desktop.test.slots"
local WATCHER = FAMILY .. ".watcher"

local function body_of(message: any): any
    local body: any = message:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function pause(duration: string)
    channel.select({time.after(duration):case_receive()})
end

-- Wait until `ready()` holds, or eight seconds.
local function until_true(ready: any): boolean
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        if ready() then return true end
        pause("50ms")
    end
    return ready() == true
end

local function spawn(): any
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "the viewport was not created")
    local pid, err = process.with_options({terminal = view:grant()})
        :spawn_monitored("app:test_composer_pixels", "app:processes", FAMILY .. "|" .. WATCHER .. "|ok")
    test.is_nil(err)
    test.not_nil(pid, "the compositor did not start")
    return {pid = pid, view = view}
end

local function ask(service: string, topic: string): any
    local replies = process.listen("desktop.reply", {message = true})
    local sent, serr = process.send(service, topic, {reply_to = tostring(process.pid())})
    test.is_true(sent == true, "the command did not reach " .. service .. ": " .. tostring(serr))
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
    test.describe("butschster.tui_desktop desktop names", function()
        test.it("each desktop claims the first free name, and a freed one is taken again", function()
            process.registry.register(WATCHER)
            local first = spawn()
            test.is_true(until_true(function() return process.registry.lookup(FAMILY) ~= nil end),
                "the first desktop did not take " .. FAMILY)
            local second = spawn()
            test.is_true(until_true(function() return process.registry.lookup(FAMILY .. ".2") ~= nil end),
                "a second desktop of the same name did not take " .. FAMILY .. ".2")

            local running: any = desktop.desktops(FAMILY)
            test.eq(#running, 2, "the directory must see both desktops")
            test.eq(running[1].name, FAMILY)
            test.eq(running[2].name, FAMILY .. ".2")
            test.eq(#desktop.desktops(FAMILY .. ".2"), 2, "a numbered name belongs to its family")
            test.eq(ask(FAMILY .. ".2", "desktop.list").service, FAMILY .. ".2",
                "the desktop names itself by the name it claimed")

            process.terminate(tostring(first.pid))
            test.is_true(until_true(function() return process.registry.lookup(FAMILY) == nil end),
                "the name was not released with its desktop")
            local third = spawn()
            test.is_true(until_true(function() return process.registry.lookup(FAMILY) ~= nil end),
                "the freed name was not taken again")
            test.eq(#desktop.desktops(FAMILY), 2)
            test.is_nil(process.registry.lookup(FAMILY .. ".3"), "a free lower number goes first")

            process.terminate(tostring(second.pid))
            process.terminate(tostring(third.pid))
            process.registry.unregister(WATCHER)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
