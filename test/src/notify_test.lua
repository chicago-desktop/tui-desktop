-- Notifications on a live compositor: balloon tips, flashing windows and the
-- notice line, driven through the command channel the way a module drives
-- them, and read back from `desktop.list` — the dashboard is where "not
-- accepted", "waiting its turn" and "shown but not drawn" differ.
--
-- The questions go through `window_api.ask` with a named desktop, the path a
-- sender that is not a window takes (the shell's notifications).
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local desktop = require("desktop")

local function wait(duration: string)
    channel.select({time.after(duration):case_receive()})
end

local function now_ms(): integer
    return time.now():unix_nano() // 1000000
end

-- A question to the desktop by name: the answer, or nil and the refusal.
local function ask(service: string, topic: string, body: any): (any, any)
    local answer, err = desktop.ask(topic, type(body) == "table" and body or {}, {service = service, timeout = "8s"})
    return answer, err
end

local function list(service: string): any
    local answer, err = ask(service, "desktop.list", {})
    test.not_nil(answer, "desktop.list did not answer: " .. tostring(err))
    return answer or {}
end

-- The first listing `check` accepts within `budget` ms, or the last one.
local function until_list(service: string, check: any, budget: integer): any
    local deadline = now_ms() + budget
    local last: any = {}
    while now_ms() < deadline do
        last = list(service)
        if check(last) then return last end
        wait("100ms")
    end
    return last
end

-- A compositor on the test's viewport: the stock cell theme, or the pixel
-- test theme (`kind`), whose balloon has hits to click.
local function boot(service: string, kind: string?): any
    local view = assert(tty.viewport({width = 80, height = 24}))
    local grant = assert(view:grant())
    local pid: any, err: any
    if kind then
        -- The argument is split on "|", and a pid has one inside: the watcher
        -- (told only of a refused start) is a name, never registered here.
        pid, err = process.with_options({terminal = grant}):spawn_monitored("app:test_composer_pixels",
            "app:processes", service .. "|" .. service .. ".watcher|" .. kind)
    else
        pid, err = process.with_options({terminal = grant}):spawn_monitored("app:test_composer",
            "app:processes", service)
    end
    test.is_nil(err)
    local deadline = now_ms() + 8000
    while now_ms() < deadline do
        if process.registry.lookup(service) then return {pid = pid, view = view} end
        wait("100ms")
    end
    test.is_true(false, "the compositor did not register as " .. service)
    return {pid = pid, view = view}
end

local function stop(desk: any)
    process.terminate(tostring(desk.pid))
end

-- A left click, the way a real mouse gives it: into the compositor's screen.
local function click(desk: any, x: integer, y: integer)
    local pressed = desk.view:send({type = "mouse", action = "press", button = "left", x = x, y = y})
    test.is_true(pressed == true, "the click did not reach the compositor's screen")
    desk.view:send({type = "mouse", action = "release", button = "left", x = x, y = y})
end

local function window_by_entry(listing: any, entry: string): any
    local found: any = {}
    for _, window in ipairs(listing.windows or {}) do
        if window.entry == entry then found[#found + 1] = window end
    end
    return found
end

local function window_by_id(listing: any, id: any): any
    for _, window in ipairs(listing.windows or {}) do
        if window.id == id then return window end
    end
    return nil
end

local function define_tests()
    test.describe("chicago.tui_desktop balloon tips", function()
        test.it("shows one, queues the rest, replaces by key, removes, clamps the timeout and names every refusal", function()
            local service = "chicago.tui_desktop.test.balloon"
            local desk = boot(service)

            local first, first_error = ask(service, "desktop.balloon", {key = "a", title = "aICQ",
                text = "Anna: hi", icon = "info", image = "app:pack/face", anchor = "icq",
                entry = "app:menu_target", args = "anna", bell = true, timeout = 1})
            test.not_nil(first, "not accepted: " .. tostring(first_error))
            test.eq(first.key, "a")
            test.is_true(first.shown == true, "the first balloon is shown at once")
            test.eq(first.timeout, 2, "a timeout under 2 s is clamped to 2")

            local second = ask(service, "desktop.balloon", {key = "b", title = "Mail", text = "One new",
                timeout = 100})
            test.eq(second.shown, false, "a second balloon waits")
            test.eq(second.queue, 1)
            test.eq(second.timeout, 60, "a timeout over 60 s is clamped to 60")

            local shown = list(service)
            test.eq(shown.balloon.key, "a")
            test.eq(shown.balloon.title, "aICQ")
            test.eq(shown.balloon.icon, "info")
            test.eq(shown.balloon.image, "app:pack/face")
            test.eq(shown.balloon.anchor, "icq")
            test.eq(shown.balloon.entry, "app:menu_target")
            test.eq(shown.balloon.args, "anna")
            test.is_true(shown.balloon.bell == true, "the bell request is carried to the dashboard")
            test.eq(shown.balloon.owner, tostring(process.pid()))
            test.eq(shown.balloon_queue, 1)

            -- The same key replaces a waiting balloon in its place.
            test.not_nil(ask(service, "desktop.balloon", {key = "b", title = "Mail", text = "Two new"}))
            test.eq(list(service).balloon_queue, 1, "the same key replaces, it does not add")

            -- The same key replaces the shown one, and its timeout starts again.
            test.not_nil(ask(service, "desktop.balloon", {key = "a", title = "aICQ",
                text = "Anna: are you there?", timeout = 60}))
            local replaced = list(service)
            test.eq(replaced.balloon.text, "Anna: are you there?")
            test.is_true(replaced.balloon.expires_in > 50,
                "the replaced balloon restarts its timeout: " .. tostring(replaced.balloon.expires_in))

            -- Removing the shown one: the next one takes its place.
            test.not_nil(ask(service, "desktop.balloon", {key = "a", remove = true}))
            local next_up = list(service)
            test.eq(next_up.balloon.key, "b")
            test.eq(next_up.balloon.text, "Two new", "the waiting one kept its replacement")
            test.eq(next_up.balloon_queue, 0)
            test.not_nil(ask(service, "desktop.balloon", {key = "absent", remove = true}),
                "removing an unknown key is not an error: a provider's second pass must not turn red")

            local unnamed = ask(service, "desktop.balloon", {title = "Unnamed", text = "x"})
            test.is_true(tostring(unnamed.key):match("^b%d+$") ~= nil,
                "a balloon without a key gets one, and the reply names it: " .. tostring(unnamed.key))

            local refusals: any = {
                {body = {text = "x"}, why = "needs its title"},
                {body = {title = "t"}, why = "needs its text"},
                {body = {title = "t", text = "x", icon = "question"}, why = "info, warning or error"},
                {body = {title = "t", text = "x", timeout = "10"}, why = "timeout"},
                {body = {title = "t", text = "x", args = 5}, why = "args"},
                {body = {title = "t", text = "x", bell = "yes"}, why = "bell"},
                {body = {key = 7, title = "t", text = "x"}, why = "key"},
                {body = {remove = true}, why = "removed by its key"},
                {body = {title = string.rep("я", 65), text = "x"}, why = "longer than 64"},
            }
            for _, case in ipairs(refusals) do
                local answer, err = ask(service, "desktop.balloon", case.body)
                test.is_nil(answer, "must be refused: " .. case.why)
                test.is_true(tostring(err):find(case.why, 1, true) ~= nil,
                    "the reason is not named (" .. case.why .. "): " .. tostring(err))
            end

            -- Held now: the shown "b" and the waiting unnamed one. Six more make
            -- eight, and the ninth is refused with its key named.
            for index = 1, 6 do
                test.not_nil(ask(service, "desktop.balloon", {key = "c" .. index, title = "t", text = "x"}))
            end
            local ninth, why = ask(service, "desktop.balloon", {key = "ninth", title = "t", text = "x"})
            test.is_nil(ninth, "the ninth balloon must be refused")
            test.is_true(tostring(why):find("balloon ninth refused", 1, true) ~= nil
                and tostring(why):find("holds 8", 1, true) ~= nil, "the refusal names the key and the limit: " .. tostring(why))
            test.eq(list(service).balloon_queue, 7)
            stop(desk)
        end)

        test.it("a balloon whose timeout ran gives way to the next one", function()
            local service = "chicago.tui_desktop.test.balloon_timeout"
            local desk = boot(service)
            test.not_nil(ask(service, "desktop.balloon", {key = "t1", title = "First", text = "x", timeout = 2}))
            test.not_nil(ask(service, "desktop.balloon", {key = "t2", title = "Second", text = "y"}))
            wait("600ms")
            test.eq(list(service).balloon.key, "t1", "the first one is still up before its timeout")
            local after = until_list(service, function(l: any) return l.balloon ~= nil and l.balloon.key == "t2" end, 4000)
            test.eq(after.balloon and after.balloon.key, "t2", "the timeout dismissed the first, the second took its place")
            test.eq(after.balloon_queue, 0)
            test.is_true(after.balloon.expires_in <= 10, "the second one runs its own default timeout")
            stop(desk)
        end)

        test.it("a click on the × dismisses it, on its body opens or raises its window; the windows under it keep the focus", function()
            local service = "chicago.tui_desktop.test.balloon_click"
            local desk = boot(service, "ok")
            -- A window under the balloon's box, and one elsewhere that holds the focus.
            local under = ask(service, "desktop.open", {entry = "app:idle_window", title = "Under",
                x = 40, y = 14, w = 41, h = 9})
            local top = ask(service, "desktop.open", {entry = "app:idle_window", title = "Top",
                x = 2, y = 3, w = 30, h = 8})
            test.not_nil(under, "the window under the balloon did not open")
            test.not_nil(top, "the window on top did not open")
            local top_id = top.window.id
            test.not_nil(ask(service, "desktop.balloon", {key = "x", title = "Close me", text = "x"}))
            test.not_nil(ask(service, "desktop.balloon", {key = "y", title = "Open me", text = "y",
                entry = "app:menu_target"}))

            -- The same rectangle the test theme draws it in.
            local close_x, row = 80, 19
            click(desk, close_x, row)
            local dismissed = until_list(service, function(l: any) return l.balloon ~= nil and l.balloon.key == "y" end, 3000)
            test.eq(dismissed.balloon and dismissed.balloon.key, "y", "the × dismissed x and y took its place")
            test.eq(dismissed.focused, top_id, "a click on the balloon raises no window under it")

            click(desk, 55, 20)
            local opened = until_list(service, function(l: any) return l.balloon == nil end, 3000)
            test.is_nil(opened.balloon, "a click on the body dismisses the balloon")
            local targets = window_by_entry(opened, "app:menu_target")
            test.eq(#targets, 1, "the body opened the window the balloon names")

            -- Its window already open and covered: the body raises it, it does not open a second.
            test.not_nil(ask(service, "desktop.focus", {id = top_id}))
            test.not_nil(ask(service, "desktop.balloon", {key = "z", title = "Again", text = "z",
                entry = "app:menu_target"}))
            click(desk, 55, 20)
            local raised = until_list(service, function(l: any) return l.balloon == nil end, 3000)
            test.eq(#window_by_entry(raised, "app:menu_target"), 1, "the open window is raised, not opened twice")
            test.eq(raised.focused, targets[1].id)
            stop(desk)
        end)
    end)

    test.describe("chicago.tui_desktop flashing windows", function()
        test.it("flashes until the window takes the focus, ends after a count, ends on stop, and names every refusal", function()
            local service = "chicago.tui_desktop.test.flash"
            local desk = boot(service)
            local a = ask(service, "desktop.open", {entry = "app:idle_window", title = "A", x = 2, y = 3, w = 30, h = 8})
            local b = ask(service, "desktop.open", {entry = "app:idle_window", title = "B", x = 34, y = 5, w = 30, h = 8})
            local a_id, b_id = a.window.id, b.window.id

            local started = ask(service, "desktop.flash", {id = a_id})
            test.not_nil(started)
            test.is_true(started.flashing == true, "a window without the focus flashes")

            -- The look swaps: both looks are seen within a second and a half.
            local seen: any = {lit = false, plain = false}
            local deadline = now_ms() + 1600
            while now_ms() < deadline do
                local listing = list(service)
                local window = window_by_id(listing, a_id)
                test.is_true(window.flashing == true, "the window keeps flashing until it is focused")
                if window.flash_lit then seen.lit = true else seen.plain = true end
                test.eq(listing.flashing[1], a_id)
                wait("100ms")
            end
            test.is_true(seen.lit and seen.plain, "the lit and the plain look must swap")

            test.not_nil(ask(service, "desktop.focus", {id = a_id}))
            local focused = until_list(service, function(l: any) return #l.flashing == 0 end, 2000)
            test.eq(#focused.flashing, 0, "focusing the window ends its flash")
            test.is_false(window_by_id(focused, a_id).flash_lit, "and leaves it in the plain look")

            local no = ask(service, "desktop.flash", {id = a_id})
            test.is_false(no.flashing, "the focused window does not flash without a count")
            test.is_true(tostring(no.reason):find("focus", 1, true) ~= nil, "and the reply says why: " .. tostring(no.reason))

            local counted = ask(service, "desktop.flash", {id = b_id, count = 1})
            test.is_true(counted.flashing == true)
            test.eq(list(service).flashing[1], b_id)
            local ended = until_list(service, function(l: any) return #l.flashing == 0 end, 3000)
            test.eq(#ended.flashing, 0, "one cycle and the flash ends by itself")

            test.is_true(ask(service, "desktop.flash", {id = b_id}).flashing == true)
            test.not_nil(ask(service, "desktop.flash", {id = b_id, stop = true}))
            test.eq(#list(service).flashing, 0, "stop ends the flash")

            local refusals: any = {
                {body = {id = "w404"}, why = "no window w404"},
                {body = {id = b_id, count = 0}, why = "whole number of cycles"},
                {body = {id = b_id, count = 1.5}, why = "whole number of cycles"},
                {body = {}, why = "names no window"},
                {body = {id = 5}, why = "a string"},
            }
            for _, case in ipairs(refusals) do
                local answer, err = ask(service, "desktop.flash", case.body)
                test.is_nil(answer, "must be refused: " .. case.why)
                test.is_true(tostring(err):find(case.why, 1, true) ~= nil,
                    "the reason is not named (" .. case.why .. "): " .. tostring(err))
            end
            stop(desk)
        end)

        test.it("no id is the sender's own window: a window flashes itself through window_api.flash", function()
            local service = "chicago.tui_desktop.test.flash_self"
            local desk = boot(service)
            local opened = ask(service, "desktop.open", {entry = "app:flash_probe", w = 30, h = 8})
            test.not_nil(opened, "the probe did not open")
            local id = opened.window.id
            local listing = until_list(service, function(l: any) return l.flashing[1] == id end, 3000)
            test.eq(listing.flashing[1], id, "the calling window flashes, found by its process")
            stop(desk)
        end)
    end)

    test.describe("chicago.tui_desktop the notice line", function()
        test.it("shows a module's notice for its ttl, clamps the ttl, clears on empty text, and the latest notice wins", function()
            local service = "chicago.tui_desktop.test.notice"
            local desk = boot(service)

            local put = ask(service, "desktop.notice", {text = "Backup finished", ttl = 1})
            test.not_nil(put)
            test.eq(put.ttl, 1)
            test.eq(list(service).notice, "Backup finished")
            local cleared = until_list(service, function(l: any) return l.notice == "" end, 3000)
            test.eq(cleared.notice, "", "the ttl ran out and the line is clear")

            test.eq(ask(service, "desktop.notice", {text = "short", ttl = 0.2}).ttl, 1, "a ttl under 1 s is clamped to 1")
            test.eq(ask(service, "desktop.notice", {text = "long", ttl = 100}).ttl, 60, "a ttl over 60 s is clamped to 60")
            test.eq(list(service).notice, "long", "the latest notice is the one shown")
            test.not_nil(ask(service, "desktop.notice", {text = ""}))
            test.eq(list(service).notice, "", "an empty text clears the line")

            -- A notice of the compositor's own that came later is not cleared by
            -- the module's ttl: "no window w404", a command nobody waited for.
            test.not_nil(ask(service, "desktop.notice", {text = "mine", ttl = 1}))
            process.send(service, "desktop.focus", {id = "w404"})
            wait("1500ms")
            local later = list(service)
            test.is_true(tostring(later.notice):find("w404", 1, true) ~= nil,
                "the compositor's later notice stays: " .. tostring(later.notice))

            local refusals: any = {
                {body = {text = 5}, why = "text is a string"},
                {body = {text = "x", ttl = "5"}, why = "ttl"},
                {body = {text = string.rep("я", 257)}, why = "longer than 256"},
            }
            for _, case in ipairs(refusals) do
                local answer, err = ask(service, "desktop.notice", case.body)
                test.is_nil(answer, "must be refused: " .. case.why)
                test.is_true(tostring(err):find(case.why, 1, true) ~= nil,
                    "the reason is not named (" .. case.why .. "): " .. tostring(err))
            end

            -- window_api from a process that is not a window: the desktop by name.
            test.is_true(desktop.notice({text = "from Lua", ttl = 5}, service) == true)
            test.eq(until_list(service, function(l: any) return l.notice == "from Lua" end, 3000).notice, "from Lua")
            test.is_true(desktop.balloon({key = "lua", title = "From Lua", text = "x"}, service) == true)
            local ballooned = until_list(service, function(l: any) return l.balloon ~= nil end, 3000)
            test.eq(ballooned.balloon and ballooned.balloon.key, "lua")
            stop(desk)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
