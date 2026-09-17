-- Desktop widgets (FR-006) on a live compositor.
--
-- Widgets are registry entries the shell lists through `options.widgets`;
-- the compositor spawns each like the state provider of a view window. The
-- test composer (`app:test_composer_pixels`, kinds "widgets" and
-- "cells_widgets") starts with alpha (order 20, opens app:menu_target), beta
-- (order 10) and one 41 cells wide. The pixel test theme stands them at the
-- right edge from row 4 — beta in columns 69..80, rows 4..6; alpha in columns
-- 61..80, rows 8..11 — and writes what it was given about each on rows 14
-- and below.
--
-- A file of its own: every test here boots a compositor, and the harness
-- gives each file thirty seconds — the wiring suite already spends most of
-- its own.
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

local function boot(service: string, kind: string): any
    local watcher = service .. ".watcher"
    process.registry.register(watcher)
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "the viewport was not created")
    local grant = view:grant()
    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("app:test_composer_pixels", "app:processes", service .. "|" .. watcher .. "|" .. kind)
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

local function shut(desk: any)
    process.registry.unregister(desk.watcher)
    process.terminate(tostring(desk.pid))
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

local function listed(desk: any): any
    return ask(desk, "desktop.list", {})
end

local function wait_listing(desk: any, check: any, what: string): any
    local at: any = {}
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        at = listed(desk)
        if check(at) then return at end
        pause("100ms")
    end
    test.is_true(false, "never happened: " .. what)
    return at
end

-- The compositor's screen is the test's viewport, read the way the
-- compositor reads its windows' frames.
local function wait_row(desk: any, row: integer, text: string, what: string)
    local seen = ""
    local deadline = time.now():unix_nano() + 5000000000
    while time.now():unix_nano() < deadline do
        local snapshot: any = desk.view:snapshot(-1)
        seen = tostring(snapshot and snapshot.rows and snapshot.rows[row] or "")
        if seen:find(text, 1, true) ~= nil then return end
        pause("100ms")
    end
    test.is_true(false, what .. ": [" .. seen .. "]")
end

-- Mouse and keys go the way real ones do: as events into the compositor's
-- screen. No shortcut for tests: a check that needs its own way to press
-- would add that way to the interface.
local function click(desk: any, x: integer, y: integer)
    local pressed = desk.view:send({type = "mouse", action = "press", button = "left", x = x, y = y})
    test.is_true(pressed == true, "the click did not reach the compositor's screen")
    desk.view:send({type = "mouse", action = "release", button = "left", x = x, y = y})
end

local function right_click(desk: any, x: integer, y: integer)
    local pressed = desk.view:send({type = "mouse", action = "press", button = "right", x = x, y = y})
    test.is_true(pressed == true, "the click did not reach the compositor's screen")
end

local function press(desk: any, key_type: string)
    local sent = desk.view:send({type = "key", key = key_type, key_type = key_type, action = "press"})
    test.is_true(sent == true, "the key did not reach the compositor's screen")
end

local function entries_of(listing: any): string
    local out = {}
    for _, item in ipairs(type(listing.widgets) == "table" and listing.widgets or {}) do
        out[#out + 1] = tostring(item.entry)
    end
    return table.concat(out, ",")
end

local function both_live(at: any): boolean
    local list: any = type(at.widgets) == "table" and at.widgets or {}
    return #list == 2 and list[1].waiting == false and list[2].waiting == false
end

local function define_tests()
    test.describe("desktop widgets", function()
        test.it("spawns the listed instances in order", function()
            local desk = boot("chicago.tui_desktop.test.widgets.spawn", "widgets")

            local listing = wait_listing(desk, both_live, "both widgets published their first state")
            test.eq(entries_of(listing), "app:widget_beta,app:widget_alpha", "order first, then the entry")
            local beta: any = listing.widgets[1]
            local alpha: any = listing.widgets[2]
            test.eq(beta.id, "g1", "ids in the order of spawning")
            test.eq(alpha.id, "g2")
            test.eq(alpha.title, "Alpha")
            test.eq(alpha.opens, "app:menu_target")
            test.eq(alpha.w, 20)
            test.eq(alpha.h, 4)
            test.is_nil(beta.opens)
            test.eq(beta.stopped, false)
            test.eq(math.tointeger(alpha.revision) or -1, 1, "one state published, one revision")
            test.is_nil(alpha.content_state, "the tree is what is drawn, not a status")

            -- The theme's `fill` got the list in display order, each with the
            -- state its process published — a state that names the id, the
            -- size and the cell the process was spawned with.
            wait_row(desk, 14, "W1:g1|12x3|Beta|nil|g1:12x3@10x20#1|live", "fill in pixel mode, beta")
            wait_row(desk, 15, "W2:g2|20x4|Alpha|app:menu_target|g2:20x4@10x20#1|live",
                "fill in pixel mode, alpha")
            shut(desk)
        end)

        test.it("takes a widget's state only from its process, marks a stopped one and respawns it on refresh", function()
            local desk = boot("chicago.tui_desktop.test.widgets.life", "widgets")
            local prefix = desk.service .. ".widget."
            wait_listing(desk, both_live, "both widgets published their first state")

            -- A stranger cannot draw into a widget.
            local forged = ask(desk, "desktop.state", {id = "g1", state = {note = "forged"}})
            test.is_true(forged.ok == false, "a state from a stranger must be refused")
            test.is_true(tostring(forged.error):find("only from its provider", 1, true) ~= nil,
                "the refusal names the rule: " .. tostring(forged.error))

            -- Its own process can, and every state is a new revision.
            process.send(prefix .. "g1", "probe.publish", {})
            local grown = wait_listing(desk, function(at: any)
                return (math.tointeger(at.widgets[1].revision) or 0) == 2
            end, "the second state of beta")
            test.eq(math.tointeger(grown.widgets[2].revision) or -1, 1, "alpha's revision did not move")
            wait_row(desk, 14, "g1:12x3@10x20#2|live", "the theme draws the new state")

            -- A stopped process: the last tree stays, marked stopped, and the
            -- status line names the entry.
            local beta_pid = process.registry.lookup(prefix .. "g1")
            test.not_nil(beta_pid, "beta's process is registered")
            process.terminate(tostring(beta_pid))
            local stopped = wait_listing(desk, function(at: any)
                return at.widgets[1].stopped == true
            end, "beta marked stopped")
            test.is_true(tostring(stopped.notice):find("app:widget_beta", 1, true) ~= nil,
                "the status line names the stopped entry: [" .. tostring(stopped.notice) .. "]")
            wait_row(desk, 14, "g1:12x3@10x20#2|stopped", "the last tree stays under the stopped mark")

            -- desktop.refresh follows the new list: beta comes back under its
            -- id, gamma is new, alpha is stopped and forgotten.
            process.send(desk.service, "test.widgets", {widgets = {
                {instance = "app:widget_beta", entry = "app:widget_beta", title = "Beta", w = 12, h = 3, order = 10},
                {instance = "app:widget_gamma", entry = "app:widget_gamma", title = "Gamma", w = 16, h = 2, order = 15},
            }})
            test.is_true(ask(desk, "desktop.refresh", {}).ok == true)
            local after = wait_listing(desk, function(at: any)
                local list: any = type(at.widgets) == "table" and at.widgets or {}
                return #list == 2 and list[1].stopped == false and list[2].waiting == false
                    and (math.tointeger(list[1].revision) or 0) >= 3
            end, "beta respawned and gamma spawned")
            test.eq(entries_of(after), "app:widget_beta,app:widget_gamma")
            test.eq(after.widgets[1].id, "g1", "a respawned widget keeps its id")
            test.eq(after.widgets[2].id, "g3", "a new entry takes the next id")
            local gone = false
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                if not process.registry.lookup(prefix .. "g2") then gone = true break end
                pause("100ms")
            end
            test.is_true(gone, "the process of a vanished widget is stopped")
            test.not_nil(process.registry.lookup(prefix .. "g1"), "beta runs again")
            shut(desk)
        end)

        test.it("reconciles independent instances, preserves resize and read failures, and replaces config", function()
            local desk = boot("chicago.tui_desktop.test.widgets.instances", "widgets")
            wait_listing(desk, both_live, "initial widgets")
            local function set(list: any, failure: any): any
                process.send(desk.service, "test.widgets", {widgets = list, failure = failure})
                return ask(desk, "desktop.refresh", {})
            end
            local function spec(id: string, value: string, width: integer): any
                return {instance = id, entry = "app:widget_alpha", w = width, h = 4, config = {value = value}}
            end
            test.is_true(set({spec("app:left", "left", 20), spec("app:right", "right", 20)}).ok)
            local first = wait_listing(desk, both_live, "two copies published")
            test.eq(first.widgets[1].instance, "app:left")
            test.eq(first.widgets[2].instance, "app:right")
            test.is_true(first.widgets[1].pid ~= first.widgets[2].pid, "separate processes")
            local left, right = first.widgets[1], first.widgets[2]
            wait_row(desk, 14, "#1:left|live", "left receives its own config")
            wait_row(desk, 15, "#1:right|live", "right receives its own config")
            test.is_true(set({spec("app:left", "left", 24), spec("app:right", "right", 20)}).ok)
            local resized = wait_listing(desk, function(at: any)
                return at.widgets[1].w == 24 and at.widgets[1].revision >= 2
            end, "resize delivered")
            test.eq(resized.widgets[1].pid, left.pid, "resize keeps process")
            test.eq(resized.widgets[2].pid, right.pid, "unrelated process stays")
            wait_row(desk, 14, "24x4@10x20#2:left|live", "provider sees new geometry")
            test.is_true(set({}, "registry unavailable").ok == false)
            test.eq(listed(desk).widgets[1].pid, left.pid, "failed read preserves composition")
            test.is_true(set({spec("app:left", "left", 41)}).ok == false)
            test.eq(#listed(desk).widgets, 2, "invalid size preserves composition")
            test.is_true(set({spec("app:left", "changed", 24), spec("app:right", "right", 20)}).ok)
            local changed = wait_listing(desk, both_live, "changed config published")
            test.eq(changed.widgets[1].instance, left.instance, "stable identity")
            test.is_true(changed.widgets[1].pid ~= left.pid, "config replaces only affected process")
            test.eq(changed.widgets[2].pid, right.pid)
            wait_row(desk, 14, "#1:changed|live", "replacement receives updated config")
            test.is_true(set({spec("app:right", "right", 20)}).ok)
            local removed = listed(desk)
            test.eq(#removed.widgets, 1)
            test.eq(removed.widgets[1].pid, right.pid)
            test.is_true(set({}).ok)
            test.eq(#listed(desk).widgets, 0, "valid empty composition removes all")
            pause("200ms")
            test.is_nil(process.registry.lookup(desk.service .. ".widget." .. right.id), "SDK close releases process")
            shut(desk)
        end)

        test.it("delivers effective content geometry and reports theme visibility without stopping hidden providers", function()
            local desk = boot("chicago.tui_desktop.test.widgets.geometry", "sized_widgets")
            local first = wait_listing(desk, both_live, "initial content sizes")
            test.eq(first.widgets[1].content_width, 10)
            test.eq(first.widgets[1].content_height, 1)
            test.eq(first.widgets[1].visible, true)
            test.eq(first.widgets[2].visible, false)
            test.not_nil(first.widgets[2].pid, "hidden providers remain independent live processes")
            wait_row(desk, 14, "g1:10x1@10x20#1|live", "spawn uses theme content dimensions")
            process.send(desk.service, "test.widgets", {widgets = {
                {instance = "app:widget_beta", entry = "app:widget_beta", w = 40, h = 8},
            }})
            test.is_true(ask(desk, "desktop.refresh", {}).ok)
            local resized = wait_listing(desk, function(at: any)
                return #at.widgets == 1 and at.widgets[1].revision >= 2
            end, "instance resize")
            test.eq(resized.widgets[1].pid, first.widgets[1].pid)
            test.eq(resized.widgets[1].w, 40, "requested width remains observable")
            test.eq(resized.widgets[1].rendered_width, 26)
            test.eq(resized.widgets[1].content_width, 24)
            wait_row(desk, 14, "g1:24x6@10x20#2|live", "resize uses actual content dimensions")
            desk.view:resize(60, 24)
            local narrowed = wait_listing(desk, function(at: any) return at.screen.width == 60 end, "terminal resize")
            test.eq(narrowed.widgets[1].content_width, 18)
            test.eq(narrowed.widgets[1].pid, first.widgets[1].pid)
            shut(desk)
        end)

        test.it("takes a widget's own close as its stop and refuses anyone else's", function()
            local desk = boot("chicago.tui_desktop.test.widgets.close", "widgets")
            local prefix = desk.service .. ".widget."
            wait_listing(desk, both_live, "both widgets published their first state")

            -- Another sender cannot close a widget.
            local foreign = ask(desk, "desktop.close", {id = "g2"})
            test.is_true(foreign.ok == false, "a close from a stranger must be refused")
            test.is_true(tostring(foreign.error):find("own process", 1, true) ~= nil,
                "the refusal names the rule: " .. tostring(foreign.error))

            -- The runner's close of its own id, sent without a reply address:
            -- the widget is stopped, not refused as an unknown window.
            process.send(prefix .. "g1", "probe.close", {})
            local closed = wait_listing(desk, function(at: any)
                return at.widgets[1].stopped == true
            end, "beta stopped by its own close")
            local notice = tostring(closed.notice)
            test.is_true(notice:find("no window", 1, true) == nil,
                "the close must not be refused as an unknown window: [" .. notice .. "]")
            test.is_true(notice:find("app:widget_beta stopped", 1, true) ~= nil,
                "the status line names the stopped entry: [" .. notice .. "]")
            test.eq(closed.widgets[2].stopped, false, "alpha is untouched by the stranger's close")
            wait_row(desk, 14, "g1:12x3@10x20#1|stopped", "the last tree stays under the stopped mark")

            local left = process.registry.lookup(prefix .. "g1")
            if left then process.terminate(tostring(left)) end
            shut(desk)
        end)

        test.it("open or raise their window on a click, offer Open only with it, and never act as icons", function()
            local desk = boot("chicago.tui_desktop.test.widgets.hits", "widgets")
            wait_listing(desk, both_live, "both widgets published their first state")

            -- The arrows walk icons only. From i2 (row 4) the one thing further
            -- right on that row is beta, whose records carry an id here.
            press(desk, "right")
            wait_listing(desk, function(at: any) return at.selected == "i1" end, "the first arrow selects i1")
            press(desk, "right")
            wait_listing(desk, function(at: any) return at.selected == "i2" end, "right moves to i2")
            press(desk, "right")
            pause("400ms")
            test.eq(tostring(listed(desk).selected), "i2", "the arrow must not walk onto a widget")

            -- A left press on alpha's last row opens what it names (`opens`),
            -- with the window's own title, and selects nothing.
            click(desk, 70, 11)
            local opened = wait_listing(desk, function(at: any) return #at.windows == 1 end,
                "a click on a widget opens its window")
            test.eq(tostring(opened.windows[1].entry), "app:menu_target")
            test.eq(tostring(opened.windows[1].title), "Menu target", "the window keeps its own title")
            test.eq(tostring(opened.selected), "i2", "a widget is never selected")

            -- Again, twice and fast: the open window is raised, not copied, and
            -- no double click opens anything.
            click(desk, 70, 11)
            click(desk, 70, 11)
            pause("400ms")
            local again: any = listed(desk)
            test.eq(#again.windows, 1, "a click raises the widget's open window instead of opening a copy")

            -- A minimised window comes back on a click.
            local id = tostring(again.windows[1].id)
            test.is_true(ask(desk, "desktop.minimize", {id = id, value = true}).ok == true)
            click(desk, 65, 9)
            local restored = wait_listing(desk, function(at: any)
                return #at.windows == 1 and at.windows[1].minimized == false
            end, "a click brings back the minimised window")
            test.eq(tostring(restored.windows[1].id), id)

            -- A widget that opens nothing does nothing on a click.
            click(desk, 75, 5)
            pause("400ms")
            local idle: any = listed(desk)
            test.eq(#idle.windows, 1, "a widget without opens opens nothing")
            test.eq(tostring(idle.selected), "i2", "and is not selected")

            -- Right press: Open only, and it raises, as the click does.
            right_click(desk, 65, 9)
            local context = wait_listing(desk, function(at: any) return at.menu_context == true end,
                "a right press on alpha opens a menu")
            test.eq(math.tointeger(context.menu_choices) or 0, 1, "Open only: a widget has no Properties")
            test.eq(tostring(context.selected), "i2", "a right press does not select a widget")
            press(desk, "enter")
            local chosen = wait_listing(desk, function(at: any) return at.menu_context == false end,
                "enter closes the menu")
            test.eq(#chosen.windows, 1, "Open raises the window the widget already opened")

            -- On a widget without opens: no menu — not the desktop's Properties.
            right_click(desk, 75, 5)
            pause("400ms")
            local none: any = listed(desk)
            test.eq(none.menu_context, false, "a widget that opens nothing has no menu")
            test.eq(tostring(none.selected), "i2")
            shut(desk)
        end)

        test.it("reach fill in cells mode too, and a click there opens the window", function()
            local desk = boot("chicago.tui_desktop.test.widgets.cells", "cells_widgets")
            local listing = wait_listing(desk, both_live, "both widgets published their first state")
            test.eq(listing.pixels, false, "this composer draws in cells")
            -- The stock theme drew these frames with `widgets` in its state; the
            -- test theme's `fill` wrote what it got. No cell size in cells mode.
            wait_row(desk, 15, "W2:g2|20x4|Alpha|app:menu_target|g2:20x4@0x0#1|live", "fill in cells mode, alpha")
            -- Records without an id here, the exact shape of FR-006 §5.
            click(desk, 70, 11)
            local opened = wait_listing(desk, function(at: any) return #at.windows == 1 end,
                "a click in cells mode opens the window")
            test.eq(tostring(opened.windows[1].entry), "app:menu_target")
            shut(desk)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
