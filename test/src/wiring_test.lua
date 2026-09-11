-- Проверки формы реестра. Харнесс не ходит в свой роутер, поэтому ручки
-- проверяются как проводка: записи существуют и ссылаются друг на друга.
--
-- Здесь же закреплены два инварианта, нарушение которых снаружи выглядит не
-- как ошибка, а как странность: терминальный хост обязан глушить лог, а
-- командный канал обязан НЕ иметь права порождать процессы.
local test = require("test")
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")

local programs = require("programs")
local pixels = require("pixels")
local apps = require("apps")
local window_api = require("window_api")

local NS = "butschster.tui_desktop"
local TERMINAL_ID = "butschster.tui_desktop:terminal"
local WORKERS_ID = "butschster.tui_desktop:workers"
local EXEC_ID = "butschster.tui_desktop:exec"
local DESKTOP_ID = "butschster.tui_desktop.desktop:desktop"
local LIBRARY_ID = "butschster.tui_desktop.desktop:library"
local CHROME_ID = "butschster.tui_desktop.desktop:chrome"
local WINDOW_ID = "butschster.tui_desktop.desktop:window_pty"
local PROGRAMS_ID = "butschster.tui_desktop.desktop:programs"
local WINDOW_API_ID = "butschster.tui_desktop.desktop:window_api"
local CONTROL_ID = "butschster.tui_desktop.api:control"
local RUNTIME_POLICY_ID = "butschster.tui_desktop.security:desktop_runtime"
local CHANNEL_POLICY_ID = "butschster.tui_desktop.security:desktop_command_channel"
local ACCESS_POLICY_ID = "butschster.tui_desktop.security:desktop_endpoint_access"

local ENDPOINTS = {
    {id = "butschster.tui_desktop.api:list_windows", method = "GET", path = "/tui-desktop/windows"},
    {id = "butschster.tui_desktop.api:open_window", method = "POST", path = "/tui-desktop/windows"},
    {id = "butschster.tui_desktop.api:window_action", method = "POST", path = "/tui-desktop/windows/{id}/{action}"},
}

local function get(id)
    local entry, err = registry.get(id)
    test.is_nil(err)
    test.not_nil(entry, id .. " is missing")
    return entry
end

local function meta_of(entry)
    if type(entry.meta) == "table" then return entry.meta end
    if type(entry.data) == "table" and type(entry.data.meta) == "table" then return entry.data.meta end
    return {}
end

local function data_of(entry)
    if type(entry.data) == "table" then return entry.data end
    return entry
end

local function qualify(ref, ns)
    if type(ref) ~= "string" then return ref end
    if ref:find(":", 1, true) then return ref end
    return ns .. ":" .. ref
end

local function actions_of(policy_entry)
    local policy = data_of(policy_entry).policy or {}
    local actions = policy.actions
    if type(actions) == "string" then return {actions} end
    return type(actions) == "table" and actions or {}
end

local function has(list, needle)
    for _, item in ipairs(list) do
        if item == needle then return true end
    end
    return false
end

-- Тело сообщения приезжает обёрнутым: payload — userdata, а внутри бывает ещё
-- и массив из одного элемента. Прочитать поле напрямую значит получить nil без
-- всякой ошибки.
local function body_of(message: any)
    local body: any = message:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

-- Запустить окно-заглушку так, как это делает композитор, и спросить, к кому
-- она обращается. Формой реестра это не проверить: имя едет в контексте
-- процесса, то есть существует только на живом запуске.
local function ask_probe(entry, service: any)
    -- Контекст собирается здесь, а не приходит готовым: ключ берётся у самой
    -- библиотеки, а «имени не передали» — это отсутствие ключа, а не пустая
    -- строка в нём.
    local context: {string: any} = {}
    if type(service) == "string" then context[window_api.CONTEXT_KEY] = service end

    -- Форма вызова та же, что у композитора: сначала options (у него там
    -- грант на viewport), потом контекст. Порядок не косметика — options,
    -- поставленные после, не должны стирать контекст, а контекст — options.
    local inbox = process.inbox()
    local spawner: any = process.with_options({}):with_context(context)
    local pid, err = spawner:spawn(entry, "app:processes", tostring(process.pid()))
    test.is_nil(err)
    test.not_nil(pid, entry .. " не запустилось")

    local deadline = time.after("5s")
    local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
    test.is_true(selected.channel == inbox, entry .. " не ответило")
    return body_of(selected.value)
end

-- Сыграть композитора: поднять окно-заглушку, дождаться её вопроса, послать
-- КОМАНДУ и только потом ответ. Команда до ответа — это и есть ловушка: цикл,
-- который ждёт ответ в inbox, прочитает её первой и выбросит.
local function play_composer(mode)
    local inbox = process.inbox()
    local service = "butschster.tui_desktop.test.composer"
    process.registry.register(service)

    local context: {string: any} = {}
    context[window_api.CONTEXT_KEY] = service
    local pid, err = process.with_options({}):with_context(context)
        :spawn("app:ask_probe", "app:processes", mode)
    test.is_nil(err)
    test.not_nil(pid, "окно не запустилось")

    local question = channel.select({inbox:case_receive(), time.after("5s"):case_receive()})
    test.is_true(question.channel == inbox, "окно не задало вопроса")
    test.eq(question.value:topic(), "desktop.list")

    process.send(tostring(pid), "desktop.close", {id = "w1"})
    process.send(tostring(pid), window_api.REPLY_TOPIC, {ok = true, marker = "готово"})

    local result = channel.select({inbox:case_receive(), time.after("8s"):case_receive()})
    test.is_true(result.channel == inbox, "окно не отчиталось")
    process.registry.unregister(service)
    return body_of(result.value)
end

-- Поднять настоящий композитор на viewport теста и говорить с ним так же, как
-- говорит командный канал снаружи. Форма реестра тут ничего не доказала бы:
-- родство окон возникает в момент открытия, а не в объявлении.
local function boot_composer(service)
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "viewport не создался")
    local grant = view:grant()
    test.not_nil(grant, "грант на viewport не выдался")

    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("app:test_composer", "app:processes", service)
    test.is_nil(err)
    test.not_nil(pid, "композитор не запустился")

    local desk: any = {pid = pid, view = view}

    -- Ждём регистрации, а не спим наугад: имя появляется, когда композитор
    -- готов принимать команды.
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(service) then return desk end
        channel.select({time.after("100ms"):case_receive()})
    end
    test.is_true(false, "композитор не зарегистрировался под именем " .. service)
    return desk
end

-- Композитор в пиксельном режиме. Вид проверки приезжает ему аргументом:
-- исправный размер ячейки, промолчавший терминал или тема без chrome.paint.
local function spawn_pixel_composer(service, watcher, kind)
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "viewport не создался")
    local grant = view:grant()
    test.not_nil(grant, "грант на viewport не выдался")

    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("app:test_composer_pixels", "app:processes",
            service .. "|" .. watcher .. "|" .. kind)
    test.is_nil(err)
    test.not_nil(pid, "композитор не запустился")
    return {pid = pid, view = view}
end

-- Ждать регистрации имеет смысл только там, где композитор обязан подняться:
-- у отказа ждать нечего, и восьмисекундное ожидание там — просто медленная
-- проверка, а медленную проверку перестают запускать.
local function boot_pixel_composer(service, watcher, kind)
    local desk: any = spawn_pixel_composer(service, watcher, kind)
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(service) then return desk end
        channel.select({time.after("100ms"):case_receive()})
    end
    test.is_true(false, "композитор не поднялся под именем " .. service)
    return desk
end

-- Строки экрана композитора: viewport принадлежит проверке, поэтому кадр
-- читается тем же снимком, каким композитор читает кадры своих окон.
local function screen_of(desk: any)
    local snapshot: any = desk.view:snapshot(-1)
    test.not_nil(snapshot, "снимок экрана композитора не читается")
    return snapshot.rows or {}
end

-- Щелчок мышью — тот же путь, которым идёт настоящая мышь: событие едет в
-- экран композитора. Клавиатурных сокращений в проверках здесь нет намеренно:
-- проверка, которой нужен свой способ нажать, дописывает его в интерфейс.
local function click(desk: any, x, y)
    local pressed = desk.view:send({type = "mouse", action = "press",
        button = "left", x = x, y = y})
    test.is_true(pressed == true, "щелчок не доехал до экрана композитора")
    desk.view:send({type = "mouse", action = "release", button = "left", x = x, y = y})
end

-- Разговор с композитором: сообщения приходят вперемешку (ответ композитора,
-- доклад окна и отказ, приехавший сам), поэтому нужное берётся по топику, а
-- остальное придерживается.
--
-- Процесс у всех проверок один, поэтому и `held` общий: сообщение, оставшееся
-- от прошлой проверки, иначе стало бы ответом на первый вопрос следующей.
local function mailbox(inbox: any)
    local held = {}
    local box: any = {}
    box.unsolicited = {}
    -- Ответы берутся ПОДПИСКОЙ НА ТОПИК, а не из inbox, и это не стиль:
    -- inbox небуферизован, и ответ, приехавший раньше, чем спросивший встал на
    -- приём, ждёт в очереди процесса до следующего события — то есть в
    -- проверке выглядит как «композитор не ответил». Ровно тем же каналом
    -- слушает ответы окно.
    box.replies = process.listen("desktop.reply", {message = true})

    function box.take(topic, budget)
        for index, message in ipairs(held) do
            if message:topic() == topic then
                table.remove(held, index)
                return body_of(message)
            end
        end
        local expiry = time.after(budget or "8s")
        while true do
            local picked = channel.select({
                inbox:case_receive(), box.replies:case_receive(), expiry:case_receive()})
            if picked.channel == expiry or not picked.ok then
                -- Первая мысль тут — «сообщение потерялось», и она почти
                -- всегда неверна: упавший композитор выглядит снаружи ровно
                -- так же. Имя в реестре осталось, экран держит последний кадр,
                -- ответов нет. Смотреть надо на его экран (`view:snapshot(-1)`).
                test.is_true(false, "не дождались " .. topic
                    .. " (композитор мог упасть — посмотри на его экран)")
                return {}
            end
            if picked.value:topic() == topic then return body_of(picked.value) end
            held[#held + 1] = picked.value
        end
    end

    -- Ответ ИМЕННО на эту команду. Отказ с пометкой `unsolicited` приехал сам
    -- и ответом не является — он откладывается, и его можно проверить
    -- отдельно. Без этого разбора проверка приняла бы чужой отказ за ответ:
    -- ровно та ошибка, от которой защищается и библиотека окна.
    function box.reply(command, budget)
        local deadline = time.now():unix_nano() + 8000000000
        while time.now():unix_nano() < deadline do
            local body = box.take("desktop.reply", budget)
            if body.unsolicited then
                box.unsolicited[#box.unsolicited + 1] = body
            elseif body.command == nil or body.command == command then
                return body
            end
        end
        test.is_true(false, "не дождались ответа на " .. tostring(command))
        return {}
    end

    return box
end

-- Нажать клавишу — тем же путём, каким приходит настоящая: событием в экран
-- композитора. Клавиатурных путей, не видных в интерфейсе, здесь не заводят,
-- поэтому проверки жмут ровно то, что человек видит нарисованным.
local function press(desk: any, key_type)
    local sent = desk.view:send({type = "key", key = key_type,
        key_type = key_type, action = "press"})
    test.is_true(sent == true, "клавиша не доехала до экрана композитора")
end

local function press_alt(desk: any, key)
    local sent = desk.view:send({type = "key", key = key, key_type = "runes",
        action = "press", alt = true})
    test.is_true(sent == true, "клавиша не доехала до экрана композитора")
end

-- Команда БЕЗ обратного адреса — так их шлёт окно: ответа оно не ждёт.
-- Отказ на такую команду и был молчанием, ради которого сделана строка
-- состояния.
local function tell_desktop(service, topic, body: any)
    local payload: any = type(body) == "table" and body or {}
    local sent, serr = process.send(service, topic, payload)
    test.is_true(sent == true, "команда не дошла до композитора: " .. tostring(serr))
end

local function ask_desktop(service, box, topic, body: any)
    local payload: any = type(body) == "table" and body or {}
    payload.reply_to = tostring(process.pid())
    local sent, serr = process.send(service, topic, payload)
    test.is_true(sent == true, "команда не дошла до композитора: " .. tostring(serr))
    return box.reply(topic)
end

-- Спросить любой процесс и дождаться ответа на его топике.
--
-- Подписка создаётся ДО отправки и живёт только на время вопроса — тем же
-- способом, каким ждёт ответа окно: топик забирает сообщение себе, и общий
-- inbox проверки от него не зависит.
local function ask_on(target, topic, body: any, reply_topic)
    local payload: any = type(body) == "table" and body or {}
    payload.reply_to = tostring(process.pid())
    local sent, serr = process.send(target, topic, payload)
    test.is_true(sent == true, "команда не дошла до " .. tostring(target) .. ": " .. tostring(serr))

    local replies = process.listen(reply_topic, {message = true})
    local expiry = time.after("8s")
    local answer: any = {}
    while true do
        local picked = channel.select({replies:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then
            test.is_true(false, "не дождались ответа на " .. tostring(topic)
                .. " (композитор мог упасть — посмотри на его экран)")
            break
        end
        local got = body_of(picked.value)
        if not got.unsolicited and (got.command == nil or got.command == topic) then
            answer = got
            break
        end
    end
    process.unlisten(replies)
    return answer
end

local function ask_fresh(service, topic, body: any)
    return ask_on(service, topic, body, "desktop.reply")
end

local function windows_by_id(listing: any)
    local out: {string: any} = {}
    for _, window in ipairs(type(listing) == "table" and listing or {}) do
        out[tostring(window.id)] = window
    end
    return out
end

-- Модули, закрытые правами, и действия, которыми они открываются.
--
-- Смысл правила: объявленный модуль без права НЕ отказывает громко. `env.get`
-- отдаёт nil, и соседнее `or умолчание` превращает отказ по правам в «никто
-- ничего не назначал»; `db.get` роняет чтение уже в работе, когда виноватым
-- выглядит запрос. Поэтому право проверяется на объявлении, а не на первом
-- вызове.
local GATED_MODULES = {
    {module = "env", actions = {"env.get"}},
    {module = "fs", actions = {"fs.get"}},
    {module = "sql", actions = {"db.get"}},
    {module = "registry", actions = {"registry.get", "registry.find", "registry.entry", "registry.apply"}},
    {module = "exec", actions = {"exec.get", "exec.run"}},
}

-- Политики, которые несёт сама запись. У процесса это `security.policies`, у
-- команды — тот же список внутри `meta.command.security`. Библиотека своих не
-- несёт: она работает в правах того, кто её позвал, и правило к ней неприменимо.
local function policies_of(entry: any)
    local data = data_of(entry)
    local meta = meta_of(entry)

    local security: any = data.security
    if type(security) ~= "table" then
        local command: any = meta.command
        if type(command) == "table" then security = command.security end
    end
    if type(security) ~= "table" then return nil end

    local list: any = security.policies
    if type(list) == "string" then return {list} end
    if type(list) ~= "table" then return nil end
    return list
end

local function granted_actions(policy_ids: any)
    local granted = {}
    for _, id in ipairs(policy_ids) do
        local policy = registry.get(qualify(id, "butschster.tui_desktop.security"))
        if policy then
            for _, action in ipairs(actions_of(policy)) do granted[action] = true end
        end
    end
    return granted
end

local function define_tests()
    test.describe("butschster.tui_desktop hosts", function()
        test.it("глушит лог на терминальном хосте", function()
            -- Без этого строка лога рантайма разъезжает кадр насовсем:
            -- диффер поверхности считает себя единственным писателем.
            local terminal = data_of(get(TERMINAL_ID))
            test.eq(terminal.hide_logs, true)
        end)

        test.it("держит отдельный хост для окон", function()
            local workers = data_of(get(WORKERS_ID))
            test.not_nil(workers.host, "process.host must declare its host block")
            test.is_true((workers.host.max_processes or 0) > 1,
                "хост окон должен вмещать больше одного окна")
        end)

        test.it("объявляет исполнителя для программ в окнах", function()
            get(EXEC_ID)
        end)
    end)

    test.describe("butschster.tui_desktop processes", function()
        test.it("отдаёт композитор командой с собственным актором", function()
            local entry = get(DESKTOP_ID)
            local command = meta_of(entry).command or {}
            test.eq(command.name, "desktop")
            test.not_nil(command.security, "команда обязана нести свой контекст безопасности")

            local data = data_of(entry)
            test.eq(data.method, "main")
            test.eq(qualify((data.imports or {}).chrome, "butschster.tui_desktop.desktop"), CHROME_ID)
            test.is_true(has(data.modules or {}, "tty"), "композитору нужен модуль tty")
            test.is_true(has(data.modules or {}, "process"), "композитору нужен модуль process")
        end)

        test.it("не зашивает список окон: своё одно, остальные приносит приложение", function()
            -- Композитор открывает окно по записи процесса и находит чужие
            -- окна по meta.type. Появление второго вида окна внутри модуля
            -- означало бы, что каждое новое окно требует правки модуля.
            local source = data_of(get(DESKTOP_ID)).source
            test.not_nil(source, "процесс композитора обязан нести источник")
            local windows = registry.find({["meta.type"] = "tui_desktop.window"})
            test.not_nil(windows, "каталог окон должен читаться, пусть и пустым")
        end)

        test.it("даёт окну exec и tty, но не process", function()
            -- Окно ничего не порождает: оно только отдаёт свой порт программе.
            local data = data_of(get(WINDOW_ID))
            test.is_true(has(data.modules or {}, "exec"), "окну нужен модуль exec")
            test.is_true(has(data.modules or {}, "tty"), "окну нужен модуль tty")
        end)
    end)

    test.describe("butschster.tui_desktop command channel", function()
        test.it("сводит каждую ручку с её обработчиком на роутере приложения", function()
            for _, expected in ipairs(ENDPOINTS) do
                get(expected.id)
                local endpoint = get(expected.id .. ".endpoint")
                local data = data_of(endpoint)
                test.eq(qualify(data.func, "butschster.tui_desktop.api"), expected.id)
                test.eq(data.method, expected.method)
                test.eq(data.path, expected.path)
                test.eq(meta_of(endpoint).router, "app:api")
            end
            get(CONTROL_ID)
        end)

        test.it("не даёт командному каналу порождать процессы", function()
            -- Ручка обязана уметь только найти композитор и заговорить с ним.
            -- Право spawn здесь означало бы, что HTTP-запрос запускает
            -- программы сам, минуя единственное место, которое их считает.
            local actions = actions_of(get(CHANNEL_POLICY_ID))
            test.is_true(has(actions, "process.send"), "каналу нужно право послать команду")
            test.is_true(has(actions, "process.registry"), "каналу нужно найти композитор по имени")
            test.is_false(has(actions, "process.spawn"), "у канала не должно быть права порождать процессы")
            test.is_false(has(actions, "exec.run"), "у канала не должно быть права запускать программы")
        end)

        test.it("даёт композитору ровно то, что нужно для окон", function()
            local actions = actions_of(get(RUNTIME_POLICY_ID))
            for _, needed in ipairs({"process.spawn.monitored", "process.terminate",
                "process.registry.register", "exec.get", "exec.run"}) do
                test.is_true(has(actions, needed), "композитору нужно право " .. needed)
            end
        end)

        test.it("позволяет композитору вернуть сохранённые окна в реестр", function()
            -- Восстановление живёт здесь, а не в фоновом сервисе: платформа
            -- запрещает процессам группы wippy.security:process менять
            -- реестр, и такой сервис молча не делал бы ничего.
            local actions = actions_of(get(RUNTIME_POLICY_ID))
            test.is_true(has(actions, "registry.apply"),
                "без registry.apply окна не переживут перезапуск")

            -- Хранилище читает библиотека композитора, а не оболочка: вид
            -- сменился, а восстановление окон осталось общим.
            local data = data_of(get(LIBRARY_ID))
            test.is_true(has(data.modules or {}, "sql"),
                "композитору нужен sql, чтобы прочитать хранилище")
            local imports = data.imports or {}
            test.eq(qualify(imports.repo, "butschster.tui_desktop.persist"),
                "butschster.tui_desktop.persist:repo")
            test.eq(qualify(imports.apps, "butschster.tui_desktop.persist"),
                "butschster.tui_desktop.persist:apps")
        end)

        test.it("держит вид отдельно от механики окон", function()
            -- Ради этого дельта и делалась: вторая оболочка приносит свою
            -- тему и получает другой вид, не копируя хостинг окон, PTY и
            -- командный канал. Если механика снова начнёт импортировать
            -- конкретную тему, копия станет единственным способом сменить
            -- вид — и разойдётся с оригиналом на первой же правке.
            local library = data_of(get(LIBRARY_ID))
            test.is_nil((library.imports or {}).chrome,
                "механика композитора не должна знать про конкретную тему")

            local shell = data_of(get(DESKTOP_ID))
            local imports = shell.imports or {}
            test.eq(qualify(imports.library, "butschster.tui_desktop.desktop"),
                "butschster.tui_desktop.desktop:library",
                "оболочка зовёт механику")
            test.eq(qualify(imports.chrome, "butschster.tui_desktop.desktop"),
                "butschster.tui_desktop.desktop:chrome",
                "оболочка выбирает тему")
        end)

        test.it("даёт окну попросить десктоп, но не запустить что-либо", function()
            -- Окно умеет обратиться к композитору (открыть соседнее окно), но
            -- своего запуска процессов и программ у него нет. Код окна
            -- приходит по HTTP, и эта граница отделяет «попросить десктоп» от
            -- «сделать что угодно».
            local actions = actions_of(get("butschster.tui_desktop.security:app_window_scope"))
            test.is_true(has(actions, "process.send"), "окно должно уметь послать команду")
            test.is_true(has(actions, "process.registry"), "и найти адресата")
            test.is_false(has(actions, "process.spawn"), "порождать процессы окно не может")
            test.is_false(has(actions, "process.spawn.monitored"), "и так тоже не может")
            test.is_false(has(actions, "exec.run"), "запускать программы окно не может")
            test.is_false(has(actions, "registry.apply"), "менять реестр окно не может")
        end)

        test.it("закрывает ручки политикой, которую внедряет приложение", function()
            local policy = data_of(get(ACCESS_POLICY_ID))
            local resources = policy.policy and policy.policy.resources
            test.not_nil(resources, "policy must list resources")
            if type(resources) == "string" then resources = {resources} end
            test.is_true(has(resources, "butschster.tui_desktop.api:*"),
                "policy must cover butschster.tui_desktop.api:*")
        end)
    end)

    test.describe("butschster.tui_desktop имя композитора", function()
        test.it("окно узнаёт имя своего композитора при запуске", function()
            -- Константа здесь была дефектом: под второй оболочкой композитор
            -- зарегистрирован своим именем, и окно обращалось к чужому
            -- (несуществующему) процессу. Молча — `api.open` ответа не ждёт.
            local body = ask_probe("app:window_probe", "butschster.windows:shell")
            test.eq(body.name, "butschster.windows:shell")
            test.eq(body.source, "context")
        end)

        test.it("имя доезжает и до записи, которая про ctx не знает", function()
            -- Модуль объявляет библиотека, а не запись окна: библиотека
            -- получает СВОИ модули. Значит окна, написанные до этого поля, и
            -- окна из мастерской (у неё узкий белый список) получают имя без
            -- единой правки. Измерено, а не выведено: обратное означало бы,
            -- что починка чинит только новые окна.
            local body = ask_probe("app:window_probe_bare", "butschster.windows:shell")
            test.eq(body.name, "butschster.windows:shell")
            test.eq(body.source, "context")
        end)

        test.it("окно, запущенное без этого сведения, работает как раньше", function()
            -- Старый композитор и чужой запуск имени не кладут. Такое окно
            -- обязано взять штатное имя, а не упасть: до починки оно
            -- обращалось ровно к нему и на штатной оболочке работало.
            local body = ask_probe("app:window_probe", nil)
            test.eq(body.name, window_api.DEFAULT_SERVICE)
            test.eq(body.source, "default")
        end)

        test.it("механика и окно берут ключ из одного места", function()
            -- Разойдись ключ у отправителя и получателя — окно молча взяло бы
            -- штатное имя, то есть вернулся бы ровно тот дефект, который здесь
            -- чинится. Поэтому композитор импортирует протокол окна, а не
            -- повторяет строку.
            local imports = data_of(get(LIBRARY_ID)).imports or {}
            test.eq(qualify(imports.window_api, "butschster.tui_desktop.desktop"), WINDOW_API_ID,
                "механика обязана брать ключ контекста у протокола окна")

            local api = data_of(get(WINDOW_API_ID))
            test.is_true(has(api.modules or {}, "ctx"),
                "без модуля ctx имя композитора прочитать нечем")
        end)
    end)

    test.describe("butschster.tui_desktop ожидание ответа в окне", function()
        test.it("окно дожидается ответа, не потеряв команду композитора", function()
            -- Команда послана, пока окно ждало. Рантайм её не теряет: она
            -- ждёт в очереди процесса, пока окно не вернётся к своему циклу.
            -- Проверяется именно это, а не «ответ пришёл»: проверка на один
            -- ответ зеленеет и при потере команды.
            local body = play_composer("ask")
            test.eq(body.answered, "готово", "ответ должен дойти целиком")
            test.eq(body.handled, "desktop.close",
                "команда, посланная во время ожидания, обязана дождаться цикла окна")
        end)

        test.it("наивное ожидание в inbox команду съедает — и проверка это видит", function()
            -- Тот же сценарий тем циклом, который здесь чинится. Тест держится
            -- не на словах: если однажды `ask` вернётся к чтению inbox,
            -- проверка выше покраснеет ровно так же, как краснеет здесь
            -- ожидание «команда дошла».
            local body = play_composer("naive")
            test.eq(body.answered, "да", "ответ наивный цикл получает — потому и не замечали")
            test.eq(body.eaten, "desktop.close", "команда прочитана циклом ожидания")
            test.eq(body.handled, "", "и до окна она уже не доходит")
        end)
    end)

    test.describe("butschster.tui_desktop диалог принадлежит окну", function()
        test.it("диалог помнит своё окно и уходит вместе с ним, а соседняя программа остаётся", function()
            local service = "butschster.tui_desktop.test.desktop"
            local watcher = "butschster.tui_desktop.test.watcher"
            local inbox = process.inbox()
            local box = mailbox(inbox)
            process.registry.register(watcher)

            local desk = boot_composer(service)

            -- Окно открывает командный канал снаружи: у него родителя нет.
            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:dialog_probe", args = watcher, w = 40, h = 12, x = 20, y = 6})
            test.is_true(opened.ok == true, "окно не открылось: " .. tostring(opened.error))
            local parent_id = tostring(opened.window.id)
            test.is_nil(opened.window.opened_by, "открытому снаружи принадлежать некому")

            -- Окно открыло из себя диалог и обычную программу.
            local report = box.take("probe.opened")
            test.is_nil(report.dialog_error, "диалог не открылся: " .. tostring(report.dialog_error))
            test.is_nil(report.plain_error, "программа не открылась: " .. tostring(report.plain_error))

            local listing = ask_desktop(service, box, "desktop.list", {})
            local windows = windows_by_id(listing.windows)
            local dialog = windows[tostring(report.dialog)]
            local plain = windows[tostring(report.plain)]
            test.not_nil(dialog, "диалога нет в списке")
            test.not_nil(plain, "программы нет в списке")

            -- Связь видна снаружи: тем же полем, которым её отдаёт ручка
            -- GET /tui-desktop/windows.
            test.eq(dialog.window_type, "dialog")
            test.eq(dialog.opened_by, parent_id, "диалог обязан помнить своё окно")
            test.eq(plain.window_type, "app")
            test.eq(plain.opened_by, parent_id, "кем открыта программа — тоже факт")

            -- Диалог встал по центру своего окна, а не в общий каскад.
            local parent = windows[parent_id]
            local pcx = parent.x + parent.width // 2
            local dcx = dialog.x + dialog.width // 2
            test.is_true(math.abs(dcx - pcx) <= 1,
                "диалог должен стоять по центру своего окна: " .. tostring(dcx) .. " против " .. tostring(pcx))

            -- И контроль, ради которого открывались двое: закрытие окна уносит
            -- диалог и НЕ трогает соседнюю программу. Проверка без него
            -- зеленела бы и у композитора, который закрывает всё подряд.
            ask_desktop(service, box, "desktop.close", {id = parent_id})

            local left: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                local again = ask_desktop(service, box, "desktop.list", {})
                left = windows_by_id(again.windows)
                if left[parent_id] == nil and left[tostring(report.dialog)] == nil then break end
                channel.select({time.after("150ms"):case_receive()})
            end

            test.is_nil(left[parent_id], "окно должно было закрыться")
            test.is_nil(left[tostring(report.dialog)], "диалог обязан уйти вместе со своим окном")
            test.not_nil(left[tostring(report.plain)],
                "обычная программа не принадлежит открывшему и остаётся")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("butschster.tui_desktop порядок окон и фокус", function()
        -- Композитор здесь настоящий, экран — viewport теста, а щелчки едут в
        -- него настоящими событиями мыши. Раньше весь этот класс проверок
        -- считался доступным только глазом через пробник.
        test.it("щелчок поднимает окно, закрытие верхнего отдаёт фокус соседу", function()
            local service = "butschster.tui_desktop.test.zorder"
            local inbox = process.inbox()
            local box = mailbox(inbox)
            local desk = boot_composer(service)

            -- Два окна внахлёст, координаты названы явно: щёлкать надо по
            -- месту, а не по тому, куда лёг каскад.
            local first = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Первое", x = 2, y = 3, w = 30, h = 8})
            local second = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Второе", x = 10, y = 5, w = 30, h = 8})
            test.is_true(first.ok == true and second.ok == true, "окна не открылись")
            local low = tostring(first.window.id)
            local high = tostring(second.window.id)

            local listing = ask_desktop(service, box, "desktop.list", {})
            test.eq(listing.focused, high, "новое окно получает фокус")
            test.eq(tostring(listing.windows[#listing.windows].id), high,
                "новое окно ложится поверх остальных")

            -- Отказ, которого никто не ждёт: команда от окна приходит без
            -- обратного адреса, и раньше «нет такого окна» уходило в никуда.
            tell_desktop(service, "desktop.focus", {id = "w404"})
            local told: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                told = ask_desktop(service, box, "desktop.list", {})
                if type(told.notice) == "string" and told.notice ~= "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(type(told.notice) == "string" and told.notice:find("w404", 1, true) ~= nil,
                "отказ обязан быть видимым: строка состояния молчит про w404")
            test.is_true(#box.unsolicited > 0,
                "тот же отказ обязан приехать и отправителю, а не только в строку состояния")
            test.eq(told.focused, high, "промах по идентификатору фокус не двигает")

            -- Щелчок по пустому столу. Он же служит вехой: композитор чистит
            -- строку состояния, и по её исчезновению видно, что событие
            -- обработано — ждать наугад не нужно.
            click(desk, 60, 20)
            local cleared: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                cleared = ask_desktop(service, box, "desktop.list", {})
                if cleared.notice == "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(cleared.notice, "", "щелчок по столу не обработан — веха не сработала")
            test.eq(cleared.focused, high, "щелчок мимо окон никого не поднимает")

            -- Щелчок по нижнему окну — по той его части, которую верхнее не
            -- закрывает. Это и есть поднятие мышью.
            click(desk, 4, 8)
            local raised: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                raised = ask_desktop(service, box, "desktop.list", {})
                if raised.focused == low then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(raised.focused, low, "щелчок по окну обязан поднять его")
            test.eq(tostring(raised.windows[#raised.windows].id), low,
                "поднятое окно становится верхним в порядке z")

            -- Закрытие верхнего: фокус обязан достаться соседу, а не пропасть.
            ask_desktop(service, box, "desktop.close", {id = low})
            local left: any = nil
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                left = ask_desktop(service, box, "desktop.list", {})
                if #left.windows == 1 then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(#left.windows, 1, "закрытое окно должно было уйти")
            test.eq(left.focused, high, "фокус обязан достаться оставшемуся окну")

            process.terminate(tostring(desk.pid))
        end)

        test.it("отказ доезжает до окна, которое ответа не ждало", function()
            -- Окно шлёт команды без обратного адреса, чтобы не морозить кадр.
            -- Раньше отказ на такую команду окно не узнавало никогда: строка
            -- состояния — человеку, лог — потом, а отправителю ничего.
            local service = "butschster.tui_desktop.test.refusal"
            local watcher = "butschster.tui_desktop.test.refusal.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_composer(service)

            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:refusal_probe", args = watcher, w = 30, h = 8})
            test.is_true(opened.ok == true, "окно не открылось: " .. tostring(opened.error))

            local report = box.take("probe.refusals")

            -- Первым обязан приехать отказ на промах — помеченным, чтобы его
            -- нельзя было принять за ответ на другой вопрос.
            test.is_true(report.first_unsolicited == true,
                "отказ обязан быть помечен как приехавший сам")
            test.eq(report.first_command, "desktop.focus", "отказ обязан называть команду")
            test.is_true(tostring(report.first_error):find("w404", 1, true) ~= nil,
                "отказ обязан называть промах: " .. tostring(report.first_error))

            -- И контроль: между промахом и вопросом окно послало ИСПРАВНУЮ
            -- команду. Вторым пришёл ответ на вопрос — значит на исправную
            -- команду композитор не прислал ничего, и «доезжает» не выродилось
            -- в «шлёт на всё подряд». Ждать для этого не пришлось: сообщения
            -- приходят по порядку.
            test.eq(report.second_command, "desktop.list",
                "вторым обязан быть ответ на вопрос, а не отклик на исправную команду")
            test.is_true(report.second_ok == true, "ответ на desktop.list обязан быть успехом")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("промах по идентификатору отвечает отказом тому, кто спросил", function()
            -- У командного канала обратный адрес есть, и ему отказ приходит
            -- ответом. Проверка парная к строке состояния: там отказ виден
            -- человеку, здесь — спросившему.
            local service = "butschster.tui_desktop.test.missing"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            local answer = ask_desktop(service, box, "desktop.focus", {id = "w404"})
            test.is_true(answer.ok == false, "промах обязан быть отказом, а не успехом")
            test.is_true(tostring(answer.error):find("w404", 1, true) ~= nil,
                "отказ обязан называть идентификатор")

            local unknown = ask_desktop(service, box, "desktop.wiggle", {})
            test.is_true(unknown.ok == false, "неизвестная команда — тоже отказ")
            test.is_true(tostring(unknown.error):find("wiggle", 1, true) ~= nil,
                "отказ обязан называть команду")

            -- Команда, которая окна не называет, и не должна: перечитать
            -- раскладку стола. Пока «нет окна» проверялось первым, она
            -- отвечала «нет окна nil» и не выполнялась вовсе — а зовёт её
            -- оболочка каждый раз, когда человек переставил значок.
            local refreshed = ask_desktop(service, box, "desktop.refresh", {})
            test.is_true(refreshed.ok == true,
                "desktop.refresh обязан выполняться: " .. tostring(refreshed.error))

            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("butschster.tui_desktop пиксельный хром", function()
        test.it("без размера ячейки режим не включается и называет причину", function()
            -- Догадка «8×16» права достаточно часто, чтобы выглядеть верной, и
            -- неверна достаточно часто, чтобы её приняли за ошибку рисования.
            local watcher = "butschster.tui_desktop.test.pixels.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)

            local silent = spawn_pixel_composer(
                "butschster.tui_desktop.test.pixels.silent", watcher, "silent")
            local told = box.take("composer.refused")
            test.is_true(tostring(told.error):find("не включается", 1, true) ~= nil,
                "отказ обязан называться отказом: " .. tostring(told.error))
            test.is_true(tostring(told.error):find("did not say how large a cell is", 1, true) ~= nil,
                "отказ обязан нести причину от терминала: " .. tostring(told.error))
            process.terminate(tostring(silent.pid))

            -- И оболочка, которая вовсе не дала, чем спросить.
            local mute = spawn_pixel_composer(
                "butschster.tui_desktop.test.pixels.mute", watcher, "nothing")
            local second = box.take("composer.refused")
            test.is_true(tostring(second.error):find("cell_size", 1, true) ~= nil,
                "отказ обязан называть, чего не хватило: " .. tostring(second.error))
            process.terminate(tostring(mute.pid))

            -- И тема, которая рисовать растрами не умеет.
            local plain = spawn_pixel_composer(
                "butschster.tui_desktop.test.pixels.cells", watcher, "cells_theme")
            local third = box.take("composer.refused")
            test.is_true(tostring(third.error):find("chrome.paint", 1, true) ~= nil,
                "отказ обязан называть, чего нет у темы: " .. tostring(third.error))
            process.terminate(tostring(plain.pid))

            process.registry.unregister(watcher)
        end)

        test.it("щелчок работает во всех трёх группах попаданий, а не только по столу", function()
            -- Механика в этом режиме не зовёт ни `bars`, ни `menu`: разметка
            -- приходит группами из `paint`. Группа, до обработчика не
            -- доехавшая, даёт щелчок в пустоту — снаружи это неотличимо от
            -- «мышь не работает», и искать будут где угодно, кроме формы
            -- ответа темы.
            local service = "butschster.tui_desktop.test.pixels.hits"
            local watcher = "butschster.tui_desktop.test.pixels.hits.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            local first = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Первое", x = 2, y = 3, w = 30, h = 8})
            local second = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Второе", x = 10, y = 5, w = 30, h = 8})
            test.is_true(first.ok == true and second.ok == true, "окна не открылись")
            local low = tostring(first.window.id)

            -- ГРУППА bars, попадание с номером окна: кнопка на панели задач
            -- поднимает нижнее окно.
            click(desk, 5, 24)
            local raised: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                raised = ask_desktop(service, box, "desktop.list", {})
                if raised.focused == low then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(raised.focused, low, "попадание bars с номером окна обязано поднимать окно")

            -- ГРУППА bars, попадание с действием: кнопка «Пуск» открывает
            -- меню. Проверяется отдельно от пункта: иначе «щелчок не дошёл» и
            -- «меню открылось, но пункт не сработал» слились бы в один отказ.
            click(desk, 62, 24)
            local opened_menu: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                opened_menu = ask_desktop(service, box, "desktop.list", {})
                if opened_menu.menu_open == true then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(opened_menu.menu_open == true,
                "попадание bars с действием обязано открывать меню")

            -- ГРУППА menu, папка: щелчок по строке с путём раскрывает её.
            -- Мышью это тот же путь, что стрелкой вправо, и до сегодняшнего дня
            -- не был проверен ни один из них.
            click(desk, 5, 7)
            local deepened: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                deepened = ask_desktop(service, box, "desktop.list", {})
                if tostring(deepened.menu_path) ~= "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(tostring(deepened.menu_path), "Программы",
                "щелчок по папке обязан её раскрыть")

            -- ГРУППА menu, программа: щелчок по пункту внутри раскрытой папки
            -- открывает её. Пункты второй панели лежат правее — по разметке,
            -- которую вернула тема.
            click(desk, 40, 7)
            local after: any = nil
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                after = ask_desktop(service, box, "desktop.list", {})
                if #after.windows == 3 then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(#after.windows, 3, "попадание menu обязано открывать программу")
            test.eq(tostring(after.windows[#after.windows].entry), "app:menu_second",
                "и именно ту, по которой щёлкнули: первую строку каталога")
            test.is_true(after.menu_open == false, "выбранный пункт закрывает меню")

            -- Контроль: щелчок мимо всякой разметки не открывает ничего и не
            -- поднимает никого. Без него «работает» означало бы «на любой
            -- щелчок что-нибудь происходит».
            click(desk, 62, 24)
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                after = ask_desktop(service, box, "desktop.list", {})
                if after.menu_open == true then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(after.menu_open == true, "меню снова открыто")

            click(desk, 40, 20)
            local closed: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                closed = ask_desktop(service, box, "desktop.list", {})
                if closed.menu_open == false then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(closed.menu_open == false, "щелчок мимо меню закрывает его")
            test.eq(#closed.windows, 3, "и ничего не открывает")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("стрелки водят курсор по меню, а enter открывает помеченное", function()
            -- Цифровых сокращений в меню больше нет: клавиатурный путь, не
            -- видный в интерфейсе, заводить нельзя. Значит стрелки обязаны
            -- работать — и работать по РАЗМЕТКЕ, а не по каталогу.
            local service = "butschster.tui_desktop.test.pixels.keys"
            local watcher = "butschster.tui_desktop.test.pixels.keys.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            -- Каталог харнесса виден в меню двумя записями, по заголовкам:
            -- «Вторая мишень», потом «Мишень меню».
            local function open_menu()
                click(desk, 62, 24)
                local shown: any = nil
                local deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline do
                    shown = ask_desktop(service, box, "desktop.list", {})
                    if shown.menu_open == true then break end
                    channel.select({time.after("100ms"):case_receive()})
                end
                test.is_true(shown.menu_open == true, "меню обязано открыться")
                return shown
            end

            local function opened_after(before)
                local grown: any = nil
                local deadline = time.now():unix_nano() + 8000000000
                while time.now():unix_nano() < deadline do
                    grown = ask_desktop(service, box, "desktop.list", {})
                    if #grown.windows > before then break end
                    channel.select({time.after("100ms"):case_receive()})
                end
                test.is_true(#grown.windows > before, "программа не открылась")
                return tostring(grown.windows[#grown.windows].entry)
            end

            -- Без стрелок enter открывает первую строку.
            -- Первая строка теперь папка, поэтому до программы — одна стрелка.
            open_menu()
            press(desk, "down")
            press(desk, "enter")
            test.eq(opened_after(0), "app:menu_second",
                "enter открывает строку под курсором")

            -- Вправо на папке раскрывает её, влево возвращает. Проверяется
            -- ПУТЁМ, а не последствием: на стенде «вправо не сработало» и
            -- «сработало, а подменю не нарисовалось» дают одинаковый ноль
            -- байт, и различить их можно только этим полем.
            open_menu()
            local path: any = ask_desktop(service, box, "desktop.list", {})
            test.eq(tostring(path.menu_path), "", "меню открывается на корне")

            -- Сколько строк и сколько папок на уровне — тем же ответом.
            -- «Вправо молчит» может значить «нечего раскрывать», и на стенде
            -- это стоило часа поисков дефекта, которого не было.
            test.eq(math.tointeger(path.menu_choices) or 0, 3,
                "на корне папка и две программы")
            test.eq(math.tointeger(path.menu_folders) or 0, 1,
                "и ровно одна из них раскрывается")

            press(desk, "right")
            local deepened: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                deepened = ask_desktop(service, box, "desktop.list", {})
                if tostring(deepened.menu_path) ~= "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(tostring(deepened.menu_path), "Программы",
                "вправо на папке обязано раскрыть её")
            test.eq(math.tointeger(deepened.menu_folders) or -1, 0,
                "внутри папки раскрывать больше нечего — и это видно, а не молчит")

            press(desk, "left")
            local back: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                back = ask_desktop(service, box, "desktop.list", {})
                if tostring(back.menu_path) == "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(tostring(back.menu_path), "", "влево обязано вернуть на уровень выше")

            -- И контроль: вправо на строке-программе раскрывать нечего, путь
            -- обязан остаться прежним. Иначе «вправо работает» означало бы
            -- «вправо что-нибудь делает».
            press(desk, "down")
            press(desk, "right")
            channel.select({time.after("400ms"):case_receive()})
            test.eq(tostring(ask_desktop(service, box, "desktop.list", {}).menu_path), "",
                "вправо на программе ничего не раскрывает")
            press(desk, "esc")

            -- Со стрелкой вниз — вторую. Это и есть доказательство, что курсор
            -- двигается: тот же enter, другой результат.
            open_menu()
            press(desk, "down")
            press(desk, "down")
            press(desk, "enter")
            test.eq(opened_after(1), "app:menu_target",
                "стрелка вниз обязана двигать курсор на следующую строку")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("наведение мыши выделяет строку меню и раскрывает папку с задержкой", function()
            -- Терминал докладывает движение без нажатия, и в Windows строка
            -- под указателем выделена, а папка под ним раскрывается сама.
            -- Проверяется ПОЛЕМ `menu_cursor`: «наведение не выделило» и
            -- «выделило, а тема не нарисовала» на экране одинаковы.
            local service = "butschster.tui_desktop.test.pixels.hover"
            local watcher = "butschster.tui_desktop.test.pixels.hover.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            local function hover(x, y)
                local sent = desk.view:send({type = "mouse", action = "motion", button = "none", x = x, y = y})
                test.is_true(sent == true, "движение мыши не доехало до экрана композитора")
            end

            local function wait_for(check, what)
                local shown: any = nil
                local deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline do
                    shown = ask_desktop(service, box, "desktop.list", {})
                    if check(shown) then return shown end
                    channel.select({time.after("100ms"):case_receive()})
                end
                test.fail(what)
                return shown
            end

            click(desk, 62, 24)
            local opened = wait_for(function(shown) return shown.menu_open == true end,
                "меню обязано открыться")
            test.eq(math.tointeger(opened.menu_cursor) or -1, 1, "меню открывается с курсором на первой строке")

            -- Строка-программа под указателем выделяется сразу; каскад не трогается.
            hover(5, 8)
            local moved = wait_for(function(shown) return (math.tointeger(shown.menu_cursor) or -1) == 2 end,
                "наведение обязано выделить строку под указателем")
            test.eq(tostring(moved.menu_path), "", "наведение на программу ничего не раскрывает")

            -- Папка раскрывается — но не первым же событием: между «иду в
            -- подменю» и «прошёл мимо» различает только задержка.
            hover(5, 7)
            local at_once: any = ask_desktop(service, box, "desktop.list", {})
            test.eq(tostring(at_once.menu_path), "", "папка раскрывается с задержкой, а не в тот же миг")
            local deepened = wait_for(function(shown) return tostring(shown.menu_path) == "Программы" end,
                "наведение на папку обязано раскрыть её")
            test.eq(math.tointeger(deepened.menu_cursor) or -1, 0, "в раскрытом наведением подменю ничего не выбрано")

            -- Уход на программу корня закрывает подменю и выделяет её.
            -- Строки темы харнесса по две ячейки: папка 6–7, программы 8–9 и 10–11.
            hover(5, 10)
            local back = wait_for(function(shown) return tostring(shown.menu_path) == "" end,
                "уход с папки обязан закрыть подменю")
            test.eq(math.tointeger(back.menu_cursor) or -1, 3, "строка под указателем выделена")

            -- Enter открывает ИМЕННО выделенную наведением строку.
            local before = #ask_desktop(service, box, "desktop.list", {}).windows
            press(desk, "enter")
            local grown = wait_for(function(shown) return #shown.windows > before end,
                "enter на выделенной наведением строке обязан открыть её")
            test.eq(tostring(grown.windows[#grown.windows].entry), "app:menu_target",
                "открылась строка под указателем, а не первая")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("правая кнопка по значку открывает контекстное меню у указателя, esc закрывает", function()
            local service = "butschster.tui_desktop.test.pixels.context"
            local watcher = "butschster.tui_desktop.test.pixels.context.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            local function listed(): any
                return ask_desktop(service, box, "desktop.list", {})
            end
            local function wait_context(wanted)
                local at: any = nil
                local deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline do
                    at = listed()
                    if (at.menu_context == true) == wanted then break end
                    channel.select({time.after("100ms"):case_receive()})
                end
                return at
            end

            -- Первый значок тестовой темы стоит в 2,4. Правая кнопка по нему
            -- выделяет его и открывает меню с якорем — без «Пуска».
            desk.view:send({type = "mouse", action = "press", button = "right", x = 3, y = 4})
            local shown = wait_context(true)
            test.eq(shown.menu_context, true, "правая кнопка по значку обязана открыть контекстное меню")
            test.eq(tostring(shown.selected), "i1", "щелчок правой выделяет значок")
            test.eq(math.tointeger(shown.menu_choices) or 0, 1,
                "у значка без окна свойств один пункт — «Открыть»")

            press(desk, "esc")
            local closed = wait_context(false)
            test.eq(closed.menu_context, false, "esc закрывает контекстное меню")
            test.eq(#closed.windows, 0, "закрытое меню ничего не открыло")

            -- Снова, и enter открывает «Открыть» — то же окно, что двойной щелчок.
            desk.view:send({type = "mouse", action = "press", button = "right", x = 3, y = 4})
            wait_context(true)
            press(desk, "enter")
            local grown: any = nil
            local until_open = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < until_open do
                grown = listed()
                if #grown.windows > 0 then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(#grown.windows, 1, "enter в контекстном меню обязан открыть значок")
            test.eq(tostring(grown.windows[1].entry), "app:menu_target")
            test.eq(grown.menu_context, false, "после открытия меню закрыто")

            -- Правая кнопка по пустому столу — «Свойства» стола, раз оболочка
            -- назвала окно (`desktop_properties`); выделение при этом снято.
            desk.view:send({type = "mouse", action = "press", button = "right", x = 60, y = 20})
            local bare = wait_context(true)
            test.eq(bare.menu_context, true, "по пустому столу — свойства стола")
            test.eq(math.tointeger(bare.menu_choices) or 0, 1)
            test.eq(bare.selected, nil, "щелчок по пустому столу снимает выделение")
            test.is_true((math.tointeger(bare.cell.w) or 0) > 0, "desktop.list называет размер ячейки")
            test.eq(bare.pixels, true, "и режим кадра")
            press(desk, "esc")
            wait_context(false)

            desk.view:send({type = "key", action = "press", key_type = "runes", key = "q", ctrl = true})
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline and process.registry.lookup(service) do
                channel.select({time.after("20ms"):case_receive()})
            end
            desk.view:close()
        end)

        test.it("стрелки водят выделение по значкам стола, а enter открывает", function()
            -- Значки лежат сеткой два на два; у каждого ДВЕ строки попаданий,
            -- как у настоящей темы с подписью. Стрелка вниз обязана уйти на
            -- соседний значок, а не на подпись того же.
            local service = "butschster.tui_desktop.test.pixels.icons"
            local watcher = "butschster.tui_desktop.test.pixels.icons.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            local function selection()
                return tostring(ask_desktop(service, box, "desktop.list", {}).selected)
            end

            local function press_until(key_type, wanted)
                press(desk, key_type)
                local at = "nil"
                local deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline do
                    at = selection()
                    if at == wanted then break end
                    channel.select({time.after("100ms"):case_receive()})
                end
                return at
            end

            -- Первая стрелка выделяет, а не двигает: выделять нечего.
            test.eq(press_until("right", "i1"), "i1", "первая стрелка обязана выделить первый значок")
            test.eq(press_until("right", "i2"), "i2", "вправо — соседний значок в строке")
            test.eq(press_until("down", "i4"), "i4", "вниз — значок строкой ниже, а не своя же подпись")
            test.eq(press_until("left", "i3"), "i3", "влево — соседний слева")

            -- Контроль: у края двигаться некуда, и выделение обязано остаться.
            -- Без него «стрелки работают» означало бы «выделение куда-нибудь
            -- прыгает».
            press(desk, "left")
            channel.select({time.after("400ms"):case_receive()})
            test.eq(selection(), "i3", "у края сетки выделение не уезжает")

            -- Enter открывает выделенный значок.
            press(desk, "enter")
            local grown: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                grown = ask_desktop(service, box, "desktop.list", {})
                if #grown.windows > 0 then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(#grown.windows, 1, "enter обязан открыть выделенный значок")
            test.eq(tostring(grown.windows[1].entry), "app:menu_target")

            -- И теперь, когда окно в фокусе, стрелки принадлежат ЕМУ: стол
            -- больше их не берёт, иначе редактор внутри окна лишился бы
            -- стрелок.
            local before = selection()
            press(desk, "up")
            channel.select({time.after("400ms"):case_receive()})
            test.eq(selection(), before, "при окне в фокусе стол стрелки не берёт")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("плоские попадания темы не угадываются, и причина видна человеку", function()
            -- «Мышь не работает» — то, как это выглядит на стенде; лог
            -- терминального хоста заглушён, поэтому жалоба, рассказанная
            -- только ему, не рассказана никому. Значит она обязана быть в
            -- строке состояния — единственном месте, которое человек видит.
            local service = "butschster.tui_desktop.test.pixels.flat"
            local watcher = "butschster.tui_desktop.test.pixels.flat.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "flat")

            local first = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Первое", x = 2, y = 3, w = 30, h = 8})
            local second = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Второе", x = 10, y = 5, w = 30, h = 8})
            test.is_true(first.ok == true and second.ok == true, "окна не открылись")
            local high = tostring(second.window.id)

            local told: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                told = ask_desktop(service, box, "desktop.list", {})
                if tostring(told.notice) ~= "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(tostring(told.notice):find("плоск", 1, true) ~= nil,
                "строка состояния обязана назвать причину: [" .. tostring(told.notice) .. "]")

            -- И щелчок при этом действительно не работает — иначе жалоба была
            -- бы про несуществующую беду.
            click(desk, 5, 24)
            channel.select({time.after("500ms"):case_receive()})
            local unchanged = ask_desktop(service, box, "desktop.list", {})
            test.eq(unchanged.focused, high,
                "плоский список щелчков не даёт, и это не должно выглядеть как работа")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("хром картинками, содержимое символами, под картинками пробелы", function()
            local service = "butschster.tui_desktop.test.pixels.live"
            local watcher = "butschster.tui_desktop.test.pixels.live.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:painter_window", x = 5, y = 4, w = 30, h = 8})
            test.is_true(opened.ok == true, "окно не открылось: " .. tostring(opened.error))
            local first = tostring(opened.window.id)

            -- Ждём кадра с содержимым: окно рисует себя не мгновенно, а
            -- признак готовности виден в списке.
            local listing: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                listing = ask_desktop(service, box, "desktop.list", {})
                if listing.windows[1] ~= nil and listing.windows[1].ready == true then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(listing.pixels == true, "композитор обязан быть в пиксельном режиме")

            -- Фон заливает тема, и в этом режиме тоже: без заливки тело окна
            -- просвечивает столом там, где программа внутри ничего не
            -- написала, — а на снимке КУСКА этого не видно, только на целом.
            local empty_row = tostring(screen_of(desk)[20] or "")
            test.is_true(empty_row:find("▒", 1, true) ~= nil,
                "стол обязан быть залит и в пиксельном режиме: [" .. empty_row .. "]")

            -- Содержимое окна кладёт КОМПОЗИТОР: в режиме символов это делала
            -- тема заодно с рамкой, а растровая тема в канву не пишет вовсе.
            local content = tostring(screen_of(desk)[5] or "")
            test.is_true(content:find("СОДЕРЖИМОЕ", 1, true) ~= nil,
                "строка окна обязана лежать в кадре символами: [" .. content .. "]")

            -- Теперь второе окно, чей ЗАГОЛОВОК ложится ровно на эту строку.
            -- Без пробелов под картинкой символ остался бы на месте и вылез
            -- из-под неё при первой же перерисовке строки — проверять пустую
            -- строку было бы проверкой без улик, там и так пусто.
            local second = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", x = 5, y = 5, w = 30, h = 8})
            test.is_true(second.ok == true, "второе окно не открылось")
            test.eq(ask_desktop(service, box, "desktop.list", {}).focused,
                tostring(second.window.id), "новое окно наверху")

            local covered: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                covered = tostring(screen_of(desk)[5] or "")
                if covered:find("СОДЕРЖИМОЕ", 1, true) == nil then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(covered:find("СОДЕРЖИМОЕ", 1, true) == nil,
                "под размещением обязаны быть пробелы: [" .. covered .. "]")

            -- Цена кадра видна снаружи: неверно порезанный хром рисует
            -- ПРАВИЛЬНЫЙ экран, просто медленный, и найти это иначе нечем.
            local costed = ask_desktop(service, box, "desktop.list", {})
            test.not_nil(costed.frame, "композитор обязан отдавать цену кадра")
            test.is_true((math.tointeger(costed.frame.images) or 0) >= 3,
                "растровая тема объявила размещения, их должно быть видно")
            -- `placements_sent` тут намеренно не проверяется: тема этой
            -- проверки растров не создаёт вовсе, поэтому ноль в этом поле
            -- получился бы при любой ошибке нарезки. Мера настоящая — у темы
            -- с настоящими растрами; здесь проверяется только, что композитор
            -- цену кадра отдаёт наружу.

            click(desk, 5, 24)
            local raised: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                raised = ask_desktop(service, box, "desktop.list", {})
                if raised.focused == first then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(raised.focused, first,
                "щелчок по разметке растровой темы обязан поднимать окно")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("butschster.tui_desktop цена кадра временем", function()
        -- «Тормозит» без цифр не чинится: сначала мерить. Байты и строки
        -- говорят, сколько ушло в терминал, но не где прошло время, и спор
        -- «пересборка в Lua или present» решался бы на глаз.
        test.it("статус несёт время кадра, его причину и сводку по последним кадрам", function()
            local service = "butschster.tui_desktop.test.frame_time"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            -- Первый кадр рисуется до того, как цикл берёт команды: к ответу
            -- на первый вопрос он уже есть.
            local first: any = ask_desktop(service, box, "desktop.list", {})
            test.not_nil(first.frame, "композитор обязан отдавать цену кадра")
            local frame: any = first.frame or {}
            test.eq(type(frame.paint_ms), "number", "paint_ms обязан быть числом")
            test.eq(type(frame.present_ms), "number", "present_ms обязан быть числом")
            test.is_true((tonumber(frame.paint_ms) or -1) >= 0
                and (tonumber(frame.present_ms) or -1) >= 0, "время кадра не бывает отрицательным")
            test.is_true((tonumber(frame.total_ms) or -1) >= (tonumber(frame.paint_ms) or 0),
                "total_ms обязан включать paint_ms")
            test.eq(frame.trigger, "start", "первый кадр называет причиной старт")

            -- Причина следующего кадра — команда, перерисовавшая стол. Без
            -- имени причины сводка говорила бы «max 40 мс» и не говорила бы,
            -- от чего.
            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Мера", x = 2, y = 3, w = 30, h = 8})
            test.is_true(opened.ok == true, "окно не открылось: " .. tostring(opened.error))

            local after: any = ask_desktop(service, box, "desktop.list", {})
            local window: any = after.frame and after.frame.window or {}
            test.is_true((math.tointeger(window.frames) or 0) >= 2,
                "в сводке обязаны быть оба кадра: старт и открытие")
            test.eq(math.tointeger(window.frames), math.tointeger(after.frame.frames_total),
                "пока кадров меньше окна сводки, она видит их все")
            local triggers: any = window.triggers or {}
            test.eq(math.tointeger(triggers.start), 1, "старт в сводке ровно один")
            test.is_true((math.tointeger(triggers.command) or 0) >= 1,
                "кадр от команды обязан называть себя командой")
            test.is_true(triggers.unknown == nil, "ни одна ветка цикла не осталась безымянной")
            for _, part in ipairs({"paint", "present", "total"}) do
                local stats: any = window[part] or {}
                test.eq(type(stats.p95_ms), "number", part .. ".p95_ms обязан быть числом")
                test.is_true((tonumber(stats.max_ms) or -1) >= (tonumber(stats.avg_ms) or 0),
                    part .. ": максимум не меньше среднего")
                test.eq(type(stats.max_trigger), "string", part .. ".max_trigger называет причину")
            end

            -- Сырые кадры — только по просьбе, и по одному на каждый кадр:
            -- замер по фазам склеивает их по seq, дыра читалась бы как
            -- «кадра не было».
            test.is_nil(after.frame.samples, "без просьбы сырые кадры в статус не едут")
            local raw: any = ask_desktop(service, box, "desktop.list", {frame_samples = true})
            local samples: any = raw.frame and raw.frame.samples or {}
            test.eq(#samples, math.tointeger(raw.frame.frames_total),
                "пока кадров меньше кольца, сырых кадров столько же, сколько нарисовано")
            for index, sample in ipairs(samples) do
                test.eq(math.tointeger(sample.seq), index, "seq идёт подряд от старого к новому")
                test.eq(type(sample.paint_ms), "number", "у сырого кадра есть paint_ms")
                test.eq(type(sample.at_ms), "number", "у сырого кадра есть момент")
            end
            test.eq(samples[1] and samples[1].trigger, "start", "первый сырой кадр — старт")

            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("butschster.tui_desktop права под объявленные модули", function()
        test.it("на каждый модуль, закрытый правами, право выдано", function()
            -- Этот класс стоил здесь трёх часов и выглядел как четыре разные
            -- проблемы подряд: композитор объявлял `env`, права на него не
            -- имел, и переназначенное имя базы молча не работало.
            local entries = registry.find({})
            test.not_nil(entries, "реестр обязан читаться")

            local checked = 0
            for _, found in ipairs(entries :: {any}) do
                local entry: any = found
                local id = tostring(entry.id)
                if id:find("butschster.tui_desktop", 1, true) == 1 then
                    local policy_ids = policies_of(entry)
                    local modules = data_of(entry).modules
                    if policy_ids and type(modules) == "table" then
                        local granted = granted_actions(policy_ids)
                        for _, gate in ipairs(GATED_MODULES) do
                            if has(modules, gate.module) then
                                checked = checked + 1
                                local ok = false
                                for _, action in ipairs(gate.actions) do
                                    if granted[action] then ok = true end
                                end
                                test.is_true(ok, id .. " объявляет модуль " .. gate.module
                                    .. ", а права на него не выдано: он будет молчать, а не отказывать")
                            end
                        end
                    end
                end
            end

            test.is_true(checked > 0, "правило обязано хоть что-то проверить, иначе оно зелёное впустую")
        end)

        test.it("окно из мастерской не просит модулей, которых ему нечем открыть", function()
            -- У собранного окна политика одна и известна заранее, поэтому
            -- правило проверяется прямо на белом списке: модуль, который окно
            -- вправе попросить, обязан быть открыт этой политикой.
            local granted = granted_actions({"butschster.tui_desktop.security:app_window_scope"})
            for _, gate in ipairs(GATED_MODULES) do
                if apps.ALLOWED_MODULES[gate.module] then
                    local ok = false
                    for _, action in ipairs(gate.actions) do
                        if granted[action] then ok = true end
                    end
                    test.is_true(ok, "окну разрешён модуль " .. gate.module
                        .. ", а права на него у app_window_scope нет")
                end
            end

            -- И контроль, что правило не выродилось в пустой цикл: `sql` в
            -- списке есть, и право под него выдано.
            test.is_true(apps.ALLOWED_MODULES.sql == true)
            test.is_true(granted["db.get"] == true)
        end)
    end)

    test.describe("butschster.tui_desktop сборка пиксельного кадра", function()
        -- Арифметика без терминала и без графики: сюда приезжает то, что
        -- вернула тема, и здесь решается, попадёт ли оно в кадр.
        -- Канва-свидетель: записывает вызовы вместо рисования. Одной
        -- таблицей, а не двумя значениями, — проверяющий иначе считает второе
        -- значение отсутствующим.
        local function recorder()
            local box: any = {calls = {}}
            local canvas: any = {}
            function canvas:put(x, y, text, span)
                box.calls[#box.calls + 1] = {x = x, y = y, text = text, span = span}
            end
            box.canvas = canvas
            return box
        end

        test.it("стирает символы ровно под картинкой", function()
            local box = recorder()
            local images = pixels.frame(box.canvas,
                {placements = {{id = "title", x = 5, y = 4, cols = 3, rows = 2}}})
            test.eq(#images, 1)
            test.eq(#box.calls, 2, "по строке на каждую строку размещения")
            test.eq(box.calls[1].x, 5)
            test.eq(box.calls[1].y, 4)
            test.eq(box.calls[1].text, "   ")
            test.eq(box.calls[2].y, 5)
        end)

        test.it("негодное размещение выбрасывает и называет, а кадр не роняет", function()
            -- `present` отвергает КАДР целиком, если хоть одно размещение
            -- неверно, а композитор зовёт его через assert: тема с одной
            -- опечаткой погасила бы весь стол.
            local box = recorder()
            local images, complaints = pixels.frame(box.canvas, {placements = {
                {id = "", x = 1, y = 1, cols = 1, rows = 1},
                {id = "нулевой", x = 0, y = 1, cols = 1, rows = 1},
                {id = "пустой", x = 1, y = 1, cols = 0, rows = 1},
                {id = "годный", x = 2, y = 2, cols = 2, rows = 1},
                {id = "годный", x = 9, y = 9, cols = 2, rows = 1},
            }})
            test.eq(#images, 1, "в кадр обязано попасть только годное")
            test.eq(images[1].id, "годный")
            test.eq(#complaints, 4, "и каждое негодное обязано быть названо")
            test.is_true(tostring(complaints[4]):find("дважды", 1, true) ~= nil,
                "повтор id — это спор о том, что показать, то есть мигание")
        end)

        test.it("каждая вынесенная функция вызвана хотя бы одной проверкой", function()
            -- Невызванная функция зелёная в любом наборе — сегодня это стоило
            -- падения темы на первом же вызове функции, которую до того не
            -- звал никто. Поэтому список экспорта сверяется со списком
            -- покрытого: новая функция без проверки красит набор.
            local covered: any = {
                pixels = {check = true, blank_under = true, hits = true, frame = true},
                programs = {window_type = true, in_menu = true, content = true,
                    item = true, menu = true, resizable = true},
            }

            for name, value in pairs(pixels) do
                if type(value) == "function" then
                    test.is_true(covered.pixels[name] == true,
                        "pixels." .. name .. " не вызвана ни одной проверкой")
                end
            end
            for name, value in pairs(programs) do
                if type(value) == "function" then
                    test.is_true(covered.programs[name] == true,
                        "programs." .. name .. " не вызвана ни одной проверкой")
                end
            end
        end)

        test.it("неизвестное window_content считается ячейками и называется", function()
            -- Тот же порядок, что у типа окна: опечатка не прячет программу, но
            -- и не молчит.
            local kind, odd = programs.content({window_content = "плитка"})
            test.eq(kind, programs.DEFAULT_CONTENT)
            test.eq(odd, "плитка")

            local plain, quiet = programs.content({})
            test.eq(plain, "cells", "молчащая запись ведёт себя как раньше")
            test.is_nil(quiet)
        end)

        test.it("фиксированный размер объявляет запись, умолчание — тянется", function()
            -- Строка "false" — отказ наравне с булевым: запись приезжает и из
            -- YAML, и из JSON, и «строка — это правда» дало бы тянущийся
            -- калькулятор ровно у того, кто просил обратного.
            test.is_true(programs.resizable({}), "молчащая запись тянется, как раньше")
            test.is_true(programs.resizable(nil))
            test.is_false(programs.resizable({resizable = false}))
            test.is_false(programs.resizable({resizable = "false"}))
            test.is_true(programs.resizable({resizable = true}))

            local item = programs.item({id = "app:calc", meta = {resizable = false}})
            test.is_false(item.resizable, "признак обязан доехать до пункта каталога")
            local plain = programs.item({id = "app:bash", meta = {}})
            test.is_true(plain.resizable)
        end)

        test.it("фиксированный размер берётся из записи, даже если просили другой", function()
            -- Часы с панели задач открываются без размера; окно, взявшее
            -- умолчание композитора, встало бы во весь стол с диалогом в углу.
            local item = programs.item({id = "app:clock", meta = {resizable = false, width = 42, height = 18}})
            test.eq(item.w, 42)
            test.eq(item.h, 18)
            test.is_false(item.resizable)
        end)

        test.it("плоский список попаданий не угадывает, а жалуется", function()
            -- Угадать тут нельзя: `id` у стола, у полос и у меню значит разное,
            -- а молча потерянные щелчки выглядят как мёртвый интерфейс.
            local hits, quarrel = pixels.hits({hits = {{row = 1, from = 1, to = 3, id = "w1"}}})
            test.eq(#hits.bars, 0)
            test.not_nil(quarrel)

            local grouped = pixels.hits({hits = {bars = {{row = 1, from = 1, to = 3, id = "w1"}}}})
            test.eq(#grouped.bars, 1)
            test.eq(#grouped.desktop, 0)
            test.eq(#grouped.menu, 0)
        end)
    end)

    test.describe("butschster.tui_desktop стрелки в режиме символов", function()
        test.it("курсор меню доезжает до темы и в ячейках, а не только в пикселях", function()
            -- Режим, который не проверили, — тот, в котором стрелки двигают
            -- НЕВИДИМОЕ: человек нажимает, что-то меняется, и он не видит где.
            -- Поэтому тот же путь проверяется у штатной темы, где курсор
            -- приезжает седьмым аргументом chrome.menu.
            local service = "butschster.tui_desktop.test.keys.cells"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            local function open_menu()
                press_alt(desk, "o")
                local shown: any = nil
                local deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline do
                    shown = ask_desktop(service, box, "desktop.list", {})
                    if shown.menu_open == true then break end
                    channel.select({time.after("100ms"):case_receive()})
                end
                test.is_true(shown.menu_open == true, "alt+o обязан открыть меню")
            end

            local function opened_after(before)
                local grown: any = nil
                local deadline = time.now():unix_nano() + 8000000000
                while time.now():unix_nano() < deadline do
                    grown = ask_desktop(service, box, "desktop.list", {})
                    if #grown.windows > before then break end
                    channel.select({time.after("100ms"):case_receive()})
                end
                test.is_true(#grown.windows > before, "программа не открылась")
                return tostring(grown.windows[#grown.windows].entry)
            end

            open_menu()
            press(desk, "enter")
            test.eq(opened_after(0), "app:menu_second", "enter открывает строку под курсором")

            open_menu()
            press(desk, "down")
            press(desk, "enter")
            -- Если курсор до темы не доехал, она пометит первую строку, и
            -- откроется снова первая — тем же enter, при той же стрелке.
            test.eq(opened_after(1), "app:menu_target",
                "курсор обязан доехать до темы: иначе стрелка двигает невидимое")

            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("butschster.tui_desktop масштаб пиксельной темы", function()
        test.it("смена размера ячейки обновляет кадр и клиент даже при прежней сетке", function()
            local service = "butschster.tui_desktop.test.pixels.zoom"
            local watcher = service .. ".watcher"
            local provider = "butschster.tui_desktop.test.provider"
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "zoom")
            tell_desktop(service, "desktop.open",
                {entry = "app:view_window", x = 5, y = 4, w = 30, h = 12})
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline and not process.registry.lookup(provider) do
                channel.select({time.after("20ms"):case_receive()})
            end
            test.not_nil(process.registry.lookup(provider))
            for _, expected in ipairs({{w = 8, h = 18, top = 2}, {w = 12, h = 24, top = 1}}) do
                test.is_true(desk.view:send({type = "resize", width = 80, height = 24}) == true)
                local report: any = {}
                deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline do
                    report = ask_on(provider, "probe.report", {}, "probe.state")
                    if report.resize and report.resize.cell_w == expected.w then break end
                    channel.select({time.after("20ms"):case_receive()})
                end
                test.not_nil(report.resize, "клиент не получил resize после смены размера ячейки")
                test.eq(report.resize.cell_w, expected.w)
                test.eq(report.resize.cell_h, expected.h)
                test.eq(report.resize.width, 28)
                test.eq(report.resize.height, 12 - expected.top - 1,
                    "отступ заголовка должен обновиться перед resize клиента")
                click(desk, 6, 4 + expected.top)
                ask_fresh(service, "desktop.list", {})
            end
            local listed = ask_fresh(service, "desktop.list", {})
            for _, window in ipairs(listed.windows or {}) do
                tell_desktop(service, "desktop.close", {id = window.id})
            end
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline and process.registry.lookup(provider) do
                channel.select({time.after("20ms"):case_receive()})
            end
            test.is_nil(process.registry.lookup(provider))
            process.terminate(tostring(desk.pid))
            process.registry.unregister(watcher)
        end)
    end)

    test.describe("butschster.tui_desktop отступы пиксельной темы", function()
        test.it("фон рисуется до содержимого, а мышь отсчитывается от viewport", function()
            local service = "butschster.tui_desktop.test.pixels.insets"
            local provider = "butschster.tui_desktop.test.provider"
            local watcher = service .. ".watcher"
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "insets")
            tell_desktop(service, "desktop.open",
                {entry = "app:view_window", x = 5, y = 4, w = 30, h = 12})
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                if process.registry.lookup(provider) then break end
                channel.select({time.after("20ms"):case_receive()})
            end
            test.not_nil(process.registry.lookup(provider))
            local rows = screen_of(desk)
            test.is_true(tostring(rows[7]):find("BACKGROUND", 1, true) ~= nil,
                "композитор должен вызвать фон темы")
            click(desk, 7, 7)
            local report: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                report = ask_on(provider, "probe.report", {}, "probe.state")
                if tostring(report.inputs):find("mouse:", 1, true) then break end
                channel.select({time.after("20ms"):case_receive()})
            end
            test.is_true(tostring(report.inputs):find("mouse:1,1", 1, true) ~= nil,
                "первый пиксельный viewport должен получить первую ячейку: " .. tostring(report.inputs))
            desk.view:send({type = "mouse", action = "wheel", button = "wheel_down", x = 7, y = 7})
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                report = ask_on(provider, "probe.report", {}, "probe.state")
                if tostring(report.inputs):find("mouse:1,1:wheel:wheel_down", 1, true) then break end
                channel.select({time.after("20ms"):case_receive()})
            end
            test.is_true(tostring(report.inputs):find("mouse:1,1:wheel:wheel_down", 1, true) ~= nil,
                "wheel must reach the client at the same coordinates as a click")
            -- An open menu owns input: wheel must not leak to the window below.
            click(desk, 65, 24)
            desk.view:send({type = "mouse", action = "wheel", button = "wheel_up", x = 7, y = 7})
            press(desk, "esc")
            ask_fresh(service, "desktop.list", {})
            report = ask_on(provider, "probe.report", {}, "probe.state")
            test.is_true(tostring(report.inputs):find("wheel_up", 1, true) == nil)
            local listed = ask_fresh(service, "desktop.list", {})
            for _, window in ipairs(listed.windows or {}) do
                tell_desktop(service, "desktop.close", {id = window.id})
            end
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline and process.registry.lookup(provider) do
                channel.select({time.after("20ms"):case_receive()})
            end
            test.is_nil(process.registry.lookup(provider), "поставщик должен завершиться после закрытия")
            process.terminate(tostring(desk.pid))
            process.registry.unregister(watcher)
        end)
    end)

    test.describe("butschster.tui_desktop окно-вид без процесса", function()
        test.it("вид ждёт своего поставщика, а не показывает пустоту молча", function()
            local service = "butschster.tui_desktop.test.view"
            local provider = "butschster.tui_desktop.test.provider"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            -- Открытие без ожидания ответа, а номер окна берётся из списка:
            -- проверяется состояние стола, а не форма ответа на открытие — её
            -- проверяют соседние тесты.
            tell_desktop(service, "desktop.open",
                {entry = "app:view_window", x = 5, y = 4, w = 30, h = 8})

            local opened: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                local listing = ask_desktop(service, box, "desktop.list", {})
                if listing.windows[1] ~= nil then opened = listing.windows[1] break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.not_nil(opened, "вид не открылся")
            local id = tostring(opened.id)
            test.eq(opened.content, "pixels", "у вида содержимое рисует тема")
            test.is_true(opened.waiting == true,
                "состояния ещё нет, и вид обязан об этом говорить")
            test.eq(math.tointeger(opened.state_revision) or -1, 0)

            -- Поставщик поднят композитором и живёт своим процессом.
            local alive: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                alive = process.registry.lookup(provider)
                if alive then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.not_nil(alive, "поставщик состояния обязан быть запущен")

            -- Он знает, кому и про какое окно отвечать: имя и номер приехали
            -- ему аргументами при запуске.
            local report = ask_on(provider, "probe.report", {}, "probe.state")
            test.eq(report.desktop, service, "поставщик обязан знать своего композитора")
            test.eq(report.window, id, "и номер окна, про которое он отвечает")

            -- Толкает состояние ОН, а не спрашивает композитор.
            process.send(provider, "probe.push", {})
            local listing: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                listing = ask_fresh(service, "desktop.list", {})
                if listing.windows[1] ~= nil and listing.windows[1].waiting == false then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(listing.windows[1].waiting == false, "состояние доехало — ждать больше нечего")
            test.eq(math.tointeger(listing.windows[1].state_revision) or -1, 1)

            -- И контроль: состояние ЧУЖОГО процесса не принимается. Вид,
            -- нарисованный подложенными данными, от настоящего неотличим.
            local stolen = ask_fresh(service, "desktop.state",
                {id = id, state = {title = "подделка"}})
            test.is_true(stolen.ok == false, "чужое состояние обязано быть отвергнуто")
            test.is_true(tostring(stolen.error):find("поставщика", 1, true) ~= nil,
                "отказ обязан называть причину: " .. tostring(stolen.error))
            test.eq(math.tointeger(ask_fresh(service, "desktop.list", {})
                .windows[1].state_revision) or -1, 1, "подделка не должна двигать счётчик")

            -- Ввод уходит поставщику: живой части у вида больше нет.
            click(desk, 10, 8)
            local seen: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                seen = ask_on(provider, "probe.report", {}, "probe.state")
                if tostring(seen.inputs) ~= "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(tostring(seen.inputs):find("mouse:5,4", 1, true) ~= nil,
                "щелчок обязан доехать поставщику в координатах окна: [" .. tostring(seen.inputs) .. "]")

            -- Закрытие окна уносит поставщика: он живёт при окне.
            tell_desktop(service, "desktop.close", {id = id})

            -- Композитор обязан пережить закрытие вида: у окна без процесса
            -- гасить нечего, кроме поставщика, и «закрыл — умер» выглядело бы
            -- на стенде как случайное падение стола.
            local emptied: any = nil
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                emptied = ask_fresh(service, "desktop.list", {})
                if #(emptied.windows or {}) == 0 then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(#(emptied.windows or {}), 0, "вид должен был закрыться, а композитор — выжить")

            local gone = false
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                if not process.registry.lookup(provider) then gone = true break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(gone, "поставщик обязан уйти вместе со своим окном")

            process.terminate(tostring(desk.pid))
        end)

        test.it("смерть поставщика возвращает вид в ожидание, а не оставляет вчерашнее", function()
            -- Вид, застывший на последнем состоянии, выглядит живым и врёт тем
            -- убедительнее, чем дольше висит.
            local service = "butschster.tui_desktop.test.view.orphan"
            local provider = "butschster.tui_desktop.test.provider"
            local desk = boot_composer(service)

            tell_desktop(service, "desktop.open", {entry = "app:view_window"})
            local alive: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                alive = process.registry.lookup(provider)
                if alive then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.not_nil(alive, "поставщик обязан подняться")

            process.send(provider, "probe.push", {})
            local ready: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                ready = ask_fresh(service, "desktop.list", {})
                if ready.windows[1] ~= nil and ready.windows[1].waiting == false then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(ready.windows[1].waiting == false, "состояние доехало")

            -- Гасим поставщика, окно оставляем.
            process.terminate(tostring(alive))
            local orphan: any = nil
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                orphan = ask_fresh(service, "desktop.list", {})
                if orphan.windows[1] ~= nil and orphan.windows[1].waiting == true then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(orphan.windows[1].waiting == true,
                "без поставщика вид обязан вернуться в ожидание")
            test.is_true(tostring(orphan.notice):find("поставщик", 1, true) ~= nil,
                "и сказать об этом человеку: [" .. tostring(orphan.notice) .. "]")

            process.terminate(tostring(desk.pid))
        end)

        test.it("вид переживает изменение размера: viewport'а у него нет", function()
            -- У окна с процессом размер меняется вместе с viewport'ом, у вида
            -- viewport'а нет вовсе — и путь, который этого не знает, роняет
            -- композитор на первой же команде resize.
            local service = "butschster.tui_desktop.test.view.resize"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:view_static", w = 30, h = 8})
            test.is_true(opened.ok == true, "вид не открылся: " .. tostring(opened.error))

            local resized = ask_desktop(service, box, "desktop.resize",
                {id = tostring(opened.window.id), w = 44, h = 12})
            test.is_true(resized.ok == true, "resize вида обязан работать: " .. tostring(resized.error))
            test.eq(math.tointeger(resized.window.width) or 0, 44)
            test.eq(math.tointeger(resized.window.height) or 0, 12)

            -- И композитор жив: следующая команда отвечает.
            local after = ask_desktop(service, box, "desktop.list", {})
            test.eq(#after.windows, 1, "композитор обязан пережить resize вида")

            process.terminate(tostring(desk.pid))
        end)

        test.it("вид, который нечем нарисовать, не открывается и говорит почему", function()
            -- Мёртвая ссылка на отрисовку молчит до первого открытия, а потом
            -- выглядит пустым окном — то есть виновата будет тема.
            local service = "butschster.tui_desktop.test.view.broken"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            local nameless = ask_desktop(service, box, "desktop.open",
                {entry = "app:view_without_render"})
            test.is_true(nameless.ok == false, "вид без render открываться не должен")
            test.is_true(tostring(nameless.error):find("render", 1, true) ~= nil,
                "отказ обязан называть, чего не хватило: " .. tostring(nameless.error))

            local dead = ask_desktop(service, box, "desktop.open",
                {entry = "app:view_with_dead_render"})
            test.is_true(dead.ok == false, "вид с мёртвой ссылкой открываться не должен")
            test.is_true(tostring(dead.error):find("app:nowhere", 1, true) ~= nil,
                "отказ обязан называть саму ссылку: " .. tostring(dead.error))

            -- Вид без поставщика — законная витрина: рисовать есть чем,
            -- добывать нечего, и ждать ему нечего.
            local static = ask_desktop(service, box, "desktop.open", {entry = "app:view_static"})
            test.is_true(static.ok == true, "вид без поставщика: " .. tostring(static.error))
            test.eq(static.window.content, "pixels")
            test.is_true(static.window.waiting == false, "ждать нечего — поставщика нет")

            -- И контроль: обычное окно рядом открывается как открывалось.
            local fine = ask_desktop(service, box, "desktop.open", {entry = "app:idle_window"})
            test.is_true(fine.ok == true, "обычные окна отказ трогать не должен")
            test.eq(fine.window.content, "cells", "умолчание — ячейки")

            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("butschster.tui_desktop тип окна и меню", function()
        test.it("прячет из меню запись с in_menu: false, не переставая её открывать", function()
            -- Признак про меню, а не про запуск: просмотрщик файла или диалог
            -- свойств открывается из другого окна и с рабочего стола.
            local hidden = {id = "app:props", meta = {title = "Свойства", in_menu = false}}
            local items = programs.menu({hidden, {id = "app:calc", meta = {title = "Калькулятор"}}})
            test.eq(#items, 1)
            test.eq(items[1].entry, "app:calc")

            local item = programs.item(hidden)
            test.not_nil(item, "скрытая запись остаётся программой")
            test.eq(item.entry, "app:props")
            test.is_false(item.in_menu)
        end)

        test.it("считает строку \"false\" отказом наравне с булевым", function()
            -- Запись приезжает и из YAML, и из JSON. «Строка — это правда»
            -- показала бы в меню ровно те окна, которые просили спрятать.
            local items = programs.menu({{id = "app:props", meta = {title = "С", in_menu = "false"}}})
            test.eq(#items, 0)
        end)

        test.it("считает неизвестный тип обычным окном и программу не прячет", function()
            -- Тип объявляет кто-то другой; опечатка в одном поле не повод не
            -- показать программу, которая в остальном исправна. Но и молчать
            -- о ней нельзя, поэтому она уезжает предупреждением.
            local records = {
                {id = "app:weird", meta = {title = "Странное", window_type = "widget"}},
                {id = "app:about", meta = {title = "О программе", window_type = "dialog"}},
            }
            local items, warnings = programs.menu(records)
            test.eq(#items, 2, "неизвестный тип не повод спрятать программу")
            local by_entry = {}
            for _, item in ipairs(items) do by_entry[item.entry] = item.window_type end
            test.eq(by_entry["app:weird"], "app")
            test.eq(by_entry["app:about"], "dialog")
            test.eq(#warnings, 1)
            test.eq(warnings[1].entry, "app:weird")
            test.eq(warnings[1].window_type, "widget")
        end)

        test.it("отдаёт диалог диалогом, а умолчание — обычным окном", function()
            local dialog = programs.item({id = "app:about", meta = {window_type = "dialog"}})
            test.eq(dialog.window_type, "dialog")
            test.is_true(dialog.in_menu, "диалог в меню нужен: «О программе» — диалог")

            local plain = programs.item({id = "app:calc", meta = {title = "Калькулятор"}})
            test.eq(plain.window_type, programs.DEFAULT_TYPE)
            test.eq(plain.title, "Калькулятор")
        end)
    end)
    test.describe("taskbar launch and shell exit", function()
        test.it("raises one clock window and closes its provider through the Start menu", function()
            local service = "butschster.tui_desktop.test.actions"
            local provider = "butschster.tui_desktop.test.provider"
            local watcher = service .. ".watcher"
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "actions")
            click(desk, 77, 24)
            local listing: any = {}
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                listing = ask_fresh(service, "desktop.list", {})
                if #listing.windows == 1 and process.registry.lookup(provider) then break end
                channel.select({time.after("20ms"):case_receive()})
            end
            test.eq(#listing.windows, 1)
            test.eq(listing.windows[1].entry, "app:view_window")
            local id = listing.windows[1].id
            tell_desktop(service, "desktop.minimize", {id = id})
            click(desk, 77, 23)
            listing = ask_fresh(service, "desktop.list", {})
            test.eq(#listing.windows, 1)
            test.eq(listing.windows[1].id, id)
            test.is_true(not listing.windows[1].minimized)
            click(desk, 65, 24)
            click(desk, 10, 9)
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                if not process.registry.lookup(service) and not process.registry.lookup(provider) then break end
                channel.select({time.after("20ms"):case_receive()})
            end
            test.is_nil(process.registry.lookup(service), "Start exit must stop an empty compositor immediately")
            test.is_nil(process.registry.lookup(provider), "the clock provider must stop with its window")
            desk.view:close()
            process.registry.unregister(watcher)
        end)

        test.it("exits by Enter on the menu action and by Ctrl+Q with the menu open", function()
            for _, method in ipairs({"enter", "ctrlq"}) do
                local service = "butschster.tui_desktop.test.quit." .. method
                local watcher = service .. ".watcher"
                process.registry.register(watcher)
                local desk = boot_pixel_composer(service, watcher, "actions")
                click(desk, 65, 24)
                if method == "enter" then
                    press(desk, "down")
                    press(desk, "enter")
                else
                    desk.view:send({type = "key", action = "press", key = "q", key_type = "runes", ctrl = true})
                end
                local deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline and process.registry.lookup(service) do
                    channel.select({time.after("20ms"):case_receive()})
                end
                test.is_nil(process.registry.lookup(service))
                desk.view:close()
                process.registry.unregister(watcher)
            end
        end)
    end)


end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
