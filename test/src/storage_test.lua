-- Storage of windows built at runtime.
--
-- What is checked is what would make a defect invisible: the "saved —
-- read — deleted" round trip on a live database and the rules for building a
-- registry entry, which decide what a window may do.
local test = require("test")
local repo = require("repo")
local apps = require("apps")

local NAME = "storage_probe"

local SOURCE = [[
local tty = require("tty")
local function main() end
return {main = main}
]]

local function define_tests()
    test.describe("windows.tui_desktop storage", function()
        test.it("survives the saved — read — deleted round trip", function()
            repo.delete(NAME)

            local saved, serr = repo.save({
                name = NAME, title = "Probe", width = 30, height = 8,
                source = SOURCE, modules = {"tty", "channel"},
                spec = {imports = {app = "some.module:app"}, image = "program"},
            })
            test.is_nil(serr)
            test.eq(saved, NAME)

            local window, gerr = repo.get(NAME)
            test.is_nil(gerr)
            test.not_nil(window, "a saved window must read back")
            test.eq(window.title, "Probe")
            test.eq(window.width, 30)
            test.eq(window.source, SOURCE)
            test.eq(window.spec.image, "program", "the description beyond the code survives the database")
            test.eq(window.spec.imports.app, "some.module:app")

            local listed, lerr = repo.list()
            test.is_nil(lerr)
            local found = false
            for _, item in ipairs(listed or {}) do
                if item.name == NAME then found = true end
            end
            test.is_true(found, "the window must be in the list")

            -- Deletion answers whether the row EXISTED: otherwise a typo in the
            -- name looks like a successful deletion.
            local existed = repo.delete(NAME)
            test.is_true(existed, "deleting an existing window returns true")
            test.is_false(repo.delete(NAME), "a repeated deletion returns false")
            test.is_nil(repo.get(NAME), "a deleted window does not read")
        end)

        test.it("a repeated name overwrites instead of duplicating", function()
            repo.delete(NAME)
            repo.save({name = NAME, title = "First", width = 10, height = 4,
                source = SOURCE, modules = {}})
            repo.save({name = NAME, title = "Second", width = 20, height = 6,
                source = SOURCE, modules = {}})

            local window = repo.get(NAME)
            test.not_nil(window)
            test.eq(window.title, "Second")

            local listed = repo.list()
            local count = 0
            for _, item in ipairs(listed or {}) do
                if item.name == NAME then count = count + 1 end
            end
            test.eq(count, 1, "the name is the key, there must be no second row")
            repo.delete(NAME)
        end)
    end)

    test.describe("windows.tui_desktop app entries", function()
        test.it("keeps foreign modules out of a window", function()
            -- The refusal must name the module: "the window does not work"
            -- without a name sends people looking for the error in the window's code.
            local refused = apps.rejected_modules({"tty", "exec", "httpclient", "os"})
            test.eq(#refused, 3)

            local allowed = apps.normalize_modules({"sql", "json"})
            local names = {}
            for _, name in ipairs(allowed) do names[name] = true end
            test.is_true(names.sql, "sql is allowed — without it there are no data widgets")
            test.is_true(names.json, "json is allowed")
        end)

        test.it("lets a window ask, but not launch", function()
            -- A window can reach the compositor (open a neighbouring window), but
            -- it has no way of its own to launch processes and programs. The window's
            -- code arrives over HTTP, and this boundary separates "ask the desktop"
            -- from "do anything at all".
            local names = {}
            for _, name in ipairs(apps.normalize_modules({})) do names[name] = true end
            test.is_true(names.process, "without process the window cannot reach the compositor")

            local entry = apps.build_entry({
                name = "probe", title = "Probe", width = 10, height = 4,
                source = "return {main = function() end}", modules = {},
            })
            test.eq((entry.data.imports or {}).desktop,
                "windows.tui_desktop.desktop:window_api",
                "the desktop library is attached to every window")
        end)

        test.it("carries the menu folder in the same field as an entry from a file, and does not write an empty one", function()
            -- "Not named" and "named empty" are different answers for the shell:
            -- an unnamed window it places where it decides, an empty one goes to the root.
            -- The workshop does not decide for the window, so an empty value does not get through at all.
            local placed = apps.build_entry({
                name = "probe", title = "Probe", width = 10, height = 4,
                source = SOURCE, modules = {}, group = "Programs/Content Machine",
            })
            test.eq(placed.meta.group, "Programs/Content Machine")
            local unnamed = apps.build_entry({
                name = "probe", title = "Probe", width = 10, height = 4,
                source = SOURCE, modules = {}, group = "",
            })
            test.is_nil(unnamed.meta.group, "an empty folder must not reach the entry")
        end)

        test.it("always adds tty and channel", function()
            -- Without them the window will not draw and will not wait for an event: it fails
            -- only after the person has decided it was created.
            local names = {}
            for _, name in ipairs(apps.normalize_modules({})) do names[name] = true end
            test.is_true(names.tty, "tty is required")
            test.is_true(names.channel, "channel is required")
        end)

        test.it("carries the description beyond the code: imports, icon, window type, pixel view", function()
            -- A window on the shell SDK declares an `app` import and a view library;
            -- all of it reaches the entry in the same fields as a window from a file.
            local entry = apps.build_entry({
                name = "probe", title = "Probe", width = 30, height = 8,
                source = SOURCE, modules = {}, spec = {
                    imports = {app = "some.module:app"},
                    image = "program", icon = "▸", window_type = "dialog",
                    resizable = false, in_menu = false, order = 5,
                    pixel_render = "some.module:render",
                    stray = "does not get through",
                },
            })
            test.eq(entry.data.imports.app, "some.module:app")
            test.eq(entry.data.imports.desktop, apps.DESKTOP_IMPORT, "the desktop library stays")
            test.eq(entry.meta.image, "program")
            test.eq(entry.meta.icon, "▸")
            test.eq(entry.meta.window_type, "dialog")
            test.eq(entry.meta.resizable, false)
            test.eq(entry.meta.in_menu, false)
            test.eq(entry.meta.order, 5)
            test.eq(entry.meta.pixel_render, "some.module:render")
            test.eq(entry.meta.pixel_state, "windows.tui_desktop.apps:probe", "the window publishes the view's state itself")
            test.is_nil(entry.meta.stray)
            -- Without a description — the entry as before.
            local plain = apps.build_entry({
                name = "probe", title = "Probe", width = 30, height = 8, source = SOURCE, modules = {},
            })
            test.is_nil(plain.meta.pixel_render)
            test.is_nil(plain.meta.window_type)
        end)

        test.it("prepare refuses by field name: dead import, taken name, wrong window type", function()
            local base = {name = "probe", source = SOURCE, modules = {}}
            local function with(extra: any): any
                local body = {}
                for k, v in pairs(base) do body[k] = v end
                for k, v in pairs(extra) do body[k] = v end
                return body
            end
            local _, dead = apps.prepare(with({imports = {app = "no.such:library"}}))
            test.is_true(tostring(dead):find("no.such:library", 1, true) ~= nil, "the refusal must name the entry")
            local _, taken = apps.prepare(with({imports = {desktop = apps.DESKTOP_IMPORT}}))
            test.is_true(tostring(taken):find("desktop", 1, true) ~= nil)
            local _, kind = apps.prepare(with({window_type = "popup"}))
            test.is_true(tostring(kind):find("window_type", 1, true) ~= nil)
            local _, render = apps.prepare(with({pixel_render = "no.such:render"}))
            test.is_true(tostring(render):find("pixel_render", 1, true) ~= nil)
            -- A live library passes: window_api is in the stand's registry.
            local window, err = apps.prepare(with({imports = {desk2 = apps.DESKTOP_IMPORT}, title = "", group = "Programs"}))
            test.is_nil(err)
            test.eq(window.title, "probe", "an empty title becomes the name")
            test.eq(window.spec.imports.desk2, apps.DESKTOP_IMPORT)
            test.eq(window.group, "Programs")
        end)

        test.it("builds the window entry under its own policy", function()
            local entry = apps.build_entry({
                name = "probe", title = "Probe", width = 30, height = 8,
                source = SOURCE, modules = {"tty"},
            })
            test.eq(entry.id, "windows.tui_desktop.apps:probe")
            test.eq(entry.kind, "process.lua")
            test.eq(entry.meta.type, "tui_desktop.window")
            test.eq(entry.meta.title, "Probe")
            test.eq(entry.data.method, "main")
            test.eq(entry.data.security.policies[1],
                "windows.tui_desktop.security:app_window_scope")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
