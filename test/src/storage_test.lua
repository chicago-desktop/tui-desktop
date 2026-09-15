-- Хранилище окон, собранных в рантайме.
--
-- Проверяется то, из-за чего дефект был бы незаметен: круг «сохранил —
-- прочитал — удалил» на живой базе и правила сборки записи реестра, которые
-- решают, что окну можно.
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
        test.it("переживает круг сохранил — прочитал — удалил", function()
            repo.delete(NAME)

            local saved, serr = repo.save({
                name = NAME, title = "Проба", width = 30, height = 8,
                source = SOURCE, modules = {"tty", "channel"},
                spec = {imports = {app = "some.module:app"}, image = "program"},
            })
            test.is_nil(serr)
            test.eq(saved, NAME)

            local window, gerr = repo.get(NAME)
            test.is_nil(gerr)
            test.not_nil(window, "сохранённое окно должно читаться обратно")
            test.eq(window.title, "Проба")
            test.eq(window.width, 30)
            test.eq(window.source, SOURCE)
            test.eq(window.spec.image, "program", "описание сверх кода переживает базу")
            test.eq(window.spec.imports.app, "some.module:app")

            local listed, lerr = repo.list()
            test.is_nil(lerr)
            local found = false
            for _, item in ipairs(listed or {}) do
                if item.name == NAME then found = true end
            end
            test.is_true(found, "окно должно быть в списке")

            -- Удаление отвечает, БЫЛА ли строка: иначе опечатка в имени
            -- выглядит успешным удалением.
            local existed = repo.delete(NAME)
            test.is_true(existed, "удаление существующего окна возвращает true")
            test.is_false(repo.delete(NAME), "повторное удаление возвращает false")
            test.is_nil(repo.get(NAME), "удалённое окно не читается")
        end)

        test.it("повторное имя перезаписывает, а не задваивает", function()
            repo.delete(NAME)
            repo.save({name = NAME, title = "Первый", width = 10, height = 4,
                source = SOURCE, modules = {}})
            repo.save({name = NAME, title = "Второй", width = 20, height = 6,
                source = SOURCE, modules = {}})

            local window = repo.get(NAME)
            test.not_nil(window)
            test.eq(window.title, "Второй")

            local listed = repo.list()
            local count = 0
            for _, item in ipairs(listed or {}) do
                if item.name == NAME then count = count + 1 end
            end
            test.eq(count, 1, "имя — ключ, второй строки быть не должно")
            repo.delete(NAME)
        end)
    end)

    test.describe("windows.tui_desktop app entries", function()
        test.it("не пускает окну чужие модули", function()
            -- Отказ обязан называть модуль по имени: «окно не работает» без
            -- имени отправляет искать ошибку в коде окна.
            local refused = apps.rejected_modules({"tty", "exec", "httpclient", "os"})
            test.eq(#refused, 3)

            local allowed = apps.normalize_modules({"sql", "json"})
            local names = {}
            for _, name in ipairs(allowed) do names[name] = true end
            test.is_true(names.sql, "sql разрешён — без него не будет виджетов с данными")
            test.is_true(names.json, "json разрешён")
        end)

        test.it("даёт окну попросить, но не запустить", function()
            -- Окно умеет обратиться к композитору (открыть соседнее окно), но
            -- своего запуска процессов и программ у него нет. Код окна
            -- приходит по HTTP, и эта граница отделяет «попросить десктоп» от
            -- «сделать что угодно».
            local names = {}
            for _, name in ipairs(apps.normalize_modules({})) do names[name] = true end
            test.is_true(names.process, "без process окно не дотянется до композитора")

            local entry = apps.build_entry({
                name = "probe", title = "Проба", width = 10, height = 4,
                source = "return {main = function() end}", modules = {},
            })
            test.eq((entry.data.imports or {}).desktop,
                "windows.tui_desktop.desktop:window_api",
                "библиотека десктопа подключается каждому окну")
        end)

        test.it("папку меню несёт тем же полем, что запись из файла, а пустую не пишет", function()
            -- «Не названа» и «названа пустой» для оболочки — разные ответы:
            -- безымянное окно она кладёт куда решит сама, пустое — на корень.
            -- Мастерская за окно не решает, поэтому пусто не доезжает вовсе.
            local placed = apps.build_entry({
                name = "probe", title = "Проба", width = 10, height = 4,
                source = SOURCE, modules = {}, group = "Программы/Контент-машина",
            })
            test.eq(placed.meta.group, "Программы/Контент-машина")
            local unnamed = apps.build_entry({
                name = "probe", title = "Проба", width = 10, height = 4,
                source = SOURCE, modules = {}, group = "",
            })
            test.is_nil(unnamed.meta.group, "пустая папка не должна доезжать до записи")
        end)

        test.it("всегда добавляет tty и channel", function()
            -- Без них окно не нарисуется и не дождётся события: упадёт уже
            -- после того, как человек решит, что оно создано.
            local names = {}
            for _, name in ipairs(apps.normalize_modules({})) do names[name] = true end
            test.is_true(names.tty, "tty обязателен")
            test.is_true(names.channel, "channel обязателен")
        end)

        test.it("несёт описание сверх кода: импорты, значок, тип окна, пиксельный вид", function()
            -- Окно на SDK оболочки объявляет импорт `app` и библиотеку вида;
            -- всё это доезжает до записи теми же полями, что у окна из файла.
            local entry = apps.build_entry({
                name = "probe", title = "Проба", width = 30, height = 8,
                source = SOURCE, modules = {}, spec = {
                    imports = {app = "some.module:app"},
                    image = "program", icon = "▸", window_type = "dialog",
                    resizable = false, in_menu = false, order = 5,
                    pixel_render = "some.module:render",
                    stray = "не доезжает",
                },
            })
            test.eq(entry.data.imports.app, "some.module:app")
            test.eq(entry.data.imports.desktop, apps.DESKTOP_IMPORT, "библиотека десктопа остаётся")
            test.eq(entry.meta.image, "program")
            test.eq(entry.meta.icon, "▸")
            test.eq(entry.meta.window_type, "dialog")
            test.eq(entry.meta.resizable, false)
            test.eq(entry.meta.in_menu, false)
            test.eq(entry.meta.order, 5)
            test.eq(entry.meta.pixel_render, "some.module:render")
            test.eq(entry.meta.pixel_state, "windows.tui_desktop.apps:probe", "состояние вида публикует само окно")
            test.is_nil(entry.meta.stray)
            -- Без описания — запись как раньше.
            local plain = apps.build_entry({
                name = "probe", title = "Проба", width = 30, height = 8, source = SOURCE, modules = {},
            })
            test.is_nil(plain.meta.pixel_render)
            test.is_nil(plain.meta.window_type)
        end)

        test.it("prepare отказывает по имени поля: мёртвый импорт, чужое имя, не тот тип окна", function()
            local base = {name = "probe", source = SOURCE, modules = {}}
            local function with(extra: any): any
                local body = {}
                for k, v in pairs(base) do body[k] = v end
                for k, v in pairs(extra) do body[k] = v end
                return body
            end
            local _, dead = apps.prepare(with({imports = {app = "no.such:library"}}))
            test.is_true(tostring(dead):find("no.such:library", 1, true) ~= nil, "отказ обязан назвать запись")
            local _, taken = apps.prepare(with({imports = {desktop = apps.DESKTOP_IMPORT}}))
            test.is_true(tostring(taken):find("desktop", 1, true) ~= nil)
            local _, kind = apps.prepare(with({window_type = "popup"}))
            test.is_true(tostring(kind):find("window_type", 1, true) ~= nil)
            local _, render = apps.prepare(with({pixel_render = "no.such:render"}))
            test.is_true(tostring(render):find("pixel_render", 1, true) ~= nil)
            -- Живая библиотека проходит: window_api есть в реестре стенда.
            local window, err = apps.prepare(with({imports = {desk2 = apps.DESKTOP_IMPORT}, title = "", group = "Программы"}))
            test.is_nil(err)
            test.eq(window.title, "probe", "пустой заголовок — имя")
            test.eq(window.spec.imports.desk2, apps.DESKTOP_IMPORT)
            test.eq(window.group, "Программы")
        end)

        test.it("собирает запись окна под своей политикой", function()
            local entry = apps.build_entry({
                name = "probe", title = "Проба", width = 30, height = 8,
                source = SOURCE, modules = {"tty"},
            })
            test.eq(entry.id, "windows.tui_desktop.apps:probe")
            test.eq(entry.kind, "process.lua")
            test.eq(entry.meta.type, "tui_desktop.window")
            test.eq(entry.meta.title, "Проба")
            test.eq(entry.data.method, "main")
            test.eq(entry.data.security.policies[1],
                "windows.tui_desktop.security:app_window_scope")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
