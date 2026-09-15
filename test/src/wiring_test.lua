-- Registry shape checks. The harness does not go through its router, so the
-- endpoints are checked as wiring: the entries exist and refer to each other.
--
-- Two invariants are also pinned here whose violation looks from outside not
-- like an error but like an oddity: the terminal host must mute the log, and
-- the command channel must NOT have the permission to spawn processes.
local test = require("test")
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")

local programs = require("programs")
local pixels = require("pixels")
local apps = require("apps")
local window_api = require("window_api")

local NS = "windows.tui_desktop"
local TERMINAL_ID = "windows.tui_desktop:terminal"
local WORKERS_ID = "windows.tui_desktop:workers"
local EXEC_ID = "windows.tui_desktop:exec"
local DESKTOP_ID = "windows.tui_desktop.desktop:desktop"
local LIBRARY_ID = "windows.tui_desktop.desktop:library"
local CHROME_ID = "windows.tui_desktop.desktop:chrome"
local WINDOW_ID = "windows.tui_desktop.desktop:window_pty"
local PROGRAMS_ID = "windows.tui_desktop.desktop:programs"
local WINDOW_API_ID = "windows.tui_desktop.desktop:window_api"
local CONTROL_ID = "windows.tui_desktop.api:control"
local RUNTIME_POLICY_ID = "windows.tui_desktop.security:desktop_runtime"
local CHANNEL_POLICY_ID = "windows.tui_desktop.security:desktop_command_channel"
local ACCESS_POLICY_ID = "windows.tui_desktop.security:desktop_endpoint_access"

local ENDPOINTS = {
    {id = "windows.tui_desktop.api:list_windows", method = "GET", path = "/tui-desktop/windows"},
    {id = "windows.tui_desktop.api:open_window", method = "POST", path = "/tui-desktop/windows"},
    {id = "windows.tui_desktop.api:window_action", method = "POST", path = "/tui-desktop/windows/{id}/{action}"},
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

-- A message body arrives wrapped: the payload is userdata, and inside it there
-- may also be an array of one element. Reading a field directly means getting
-- nil without any error.
local function body_of(message: any)
    local body: any = message:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

-- Launch a stub window the way the compositor does, and ask whom it
-- addresses. The registry's shape cannot check this: the name travels in the
-- process context, that is, it exists only in a live launch.
local function ask_probe(entry, service: any)
    -- The context is built here rather than arriving ready-made: the key is
    -- taken from the library itself, and "no name was passed" means the key is
    -- absent, not an empty string in it.
    local context: {string: any} = {}
    if type(service) == "string" then context[window_api.CONTEXT_KEY] = service end

    -- The call has the same shape as the compositor's: first options (it has
    -- the viewport grant there), then the context. The order is not cosmetic —
    -- options set afterwards must not wipe the context, nor the context the options.
    local inbox = process.inbox()
    local spawner: any = process.with_options({}):with_context(context)
    local pid, err = spawner:spawn(entry, "app:processes", tostring(process.pid()))
    test.is_nil(err)
    test.not_nil(pid, entry .. " did not start")

    local deadline = time.after("5s")
    local selected = channel.select({inbox:case_receive(), deadline:case_receive()})
    test.is_true(selected.channel == inbox, entry .. " did not answer")
    return body_of(selected.value)
end

-- Play the compositor: bring up a stub window, wait for its question, send a
-- COMMAND and only then the answer. A command before the answer is the trap itself:
-- a loop that waits for the answer in the inbox reads it first and throws it away.
local function play_composer(mode)
    local inbox = process.inbox()
    local service = "windows.tui_desktop.test.composer"
    process.registry.register(service)

    local context: {string: any} = {}
    context[window_api.CONTEXT_KEY] = service
    local pid, err = process.with_options({}):with_context(context)
        :spawn("app:ask_probe", "app:processes", mode)
    test.is_nil(err)
    test.not_nil(pid, "the window did not start")

    local question = channel.select({inbox:case_receive(), time.after("5s"):case_receive()})
    test.is_true(question.channel == inbox, "the window asked no question")
    test.eq(question.value:topic(), "desktop.list")

    process.send(tostring(pid), "desktop.close", {id = "w1"})
    process.send(tostring(pid), window_api.REPLY_TOPIC, {ok = true, marker = "ready"})

    local result = channel.select({inbox:case_receive(), time.after("8s"):case_receive()})
    test.is_true(result.channel == inbox, "the window did not report")
    process.registry.unregister(service)
    return body_of(result.value)
end

-- Bring up a real compositor on the test's viewport and talk to it the same way
-- the command channel talks from outside. The registry's shape would prove nothing
-- here: window kinship arises at the moment of opening, not in the declaration.
local function boot_composer(service)
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "the viewport was not created")
    local grant = view:grant()
    test.not_nil(grant, "the viewport grant was not issued")

    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("app:test_composer", "app:processes", service)
    test.is_nil(err)
    test.not_nil(pid, "the compositor did not start")

    local desk: any = {pid = pid, view = view}

    -- Wait for registration rather than sleeping at random: the name appears
    -- when the compositor is ready to take commands.
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(service) then return desk end
        channel.select({time.after("100ms"):case_receive()})
    end
    test.is_true(false, "the compositor did not register under the name " .. service)
    return desk
end

-- Compositor in pixel mode. The kind of check arrives to it as an argument:
-- a valid cell size, a terminal that stayed silent, or a theme without chrome.paint.
local function spawn_pixel_composer(service, watcher, kind)
    local view = tty.viewport({width = 80, height = 24})
    test.not_nil(view, "the viewport was not created")
    local grant = view:grant()
    test.not_nil(grant, "the viewport grant was not issued")

    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("app:test_composer_pixels", "app:processes",
            service .. "|" .. watcher .. "|" .. kind)
    test.is_nil(err)
    test.not_nil(pid, "the compositor did not start")
    return {pid = pid, view = view}
end

-- Waiting for registration makes sense only where the compositor must come up:
-- a refusal has nothing to wait for, and an eight-second wait there is just a
-- slow check, and people stop running slow checks.
local function boot_pixel_composer(service, watcher, kind)
    local desk: any = spawn_pixel_composer(service, watcher, kind)
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(service) then return desk end
        channel.select({time.after("100ms"):case_receive()})
    end
    test.is_true(false, "the compositor did not come up under the name " .. service)
    return desk
end

-- Rows of the compositor's screen: the viewport belongs to the check, so the frame
-- is read with the same snapshot the compositor uses to read its windows' frames.
local function screen_of(desk: any)
    local snapshot: any = desk.view:snapshot(-1)
    test.not_nil(snapshot, "the compositor's screen snapshot cannot be read")
    return snapshot.rows or {}
end

-- A mouse click takes the same path a real mouse takes: the event goes into the
-- compositor's screen. There are deliberately no keyboard shortcuts in these checks:
-- a check that needs its own way to press something adds it to the interface.
local function click(desk: any, x, y)
    local pressed = desk.view:send({type = "mouse", action = "press",
        button = "left", x = x, y = y})
    test.is_true(pressed == true, "the click did not reach the compositor's screen")
    desk.view:send({type = "mouse", action = "release", button = "left", x = x, y = y})
end

-- Conversation with the compositor: messages arrive interleaved (the compositor's
-- answer, a window's report and a refusal that came on its own), so the needed one
-- is taken by topic, and the rest is held back.
--
-- All checks share one process, so `held` is shared too: a message left over
-- from a previous check would otherwise become the answer to the next one's first question.
local function mailbox(inbox: any)
    local held = {}
    local box: any = {}
    box.unsolicited = {}
    -- Answers are taken by a TOPIC SUBSCRIPTION, not from the inbox, and this is
    -- not style: the inbox is unbuffered, and an answer that arrived before the
    -- asker started receiving waits in the process queue until the next event —
    -- that is, in the check it looks like "the compositor did not answer". A
    -- window listens for answers on exactly the same channel.
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
                -- The first thought here is "the message got lost", and it is
                -- almost always wrong: a crashed compositor looks exactly the
                -- same from outside. The name stays in the registry, the screen
                -- holds the last frame, no answers come. Look at its screen (`view:snapshot(-1)`).
                test.is_true(false, "did not receive " .. topic
                    .. " (the compositor may have crashed — look at its screen)")
                return {}
            end
            if picked.value:topic() == topic then return body_of(picked.value) end
            held[#held + 1] = picked.value
        end
    end

    -- The answer to THIS very command. A refusal marked `unsolicited` came on its
    -- own and is not an answer — it is set aside and can be checked
    -- separately. Without this sorting the check would take someone else's refusal
    -- for the answer: exactly the mistake the window library also guards against.
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
        test.is_true(false, "did not receive an answer to " .. tostring(command))
        return {}
    end

    return box
end

-- Press a key — the same way a real one arrives: as an event into the
-- compositor's screen. Keyboard paths not visible in the interface are not added
-- here, so the checks press exactly what a person sees drawn.
local function press(desk: any, key_type)
    local sent = desk.view:send({type = "key", key = key_type,
        key_type = key_type, action = "press"})
    test.is_true(sent == true, "the key did not reach the compositor's screen")
end

local function press_alt(desk: any, key)
    local sent = desk.view:send({type = "key", key = key, key_type = "runes",
        action = "press", alt = true})
    test.is_true(sent == true, "the key did not reach the compositor's screen")
end

-- A command WITHOUT a return address — that is how a window sends them: it does
-- not wait for an answer. A refusal of such a command used to be the silence the
-- status line was made for.
local function tell_desktop(service, topic, body: any)
    local payload: any = type(body) == "table" and body or {}
    local sent, serr = process.send(service, topic, payload)
    test.is_true(sent == true, "the command did not reach the compositor: " .. tostring(serr))
end

local function ask_desktop(service, box, topic, body: any)
    local payload: any = type(body) == "table" and body or {}
    payload.reply_to = tostring(process.pid())
    local sent, serr = process.send(service, topic, payload)
    test.is_true(sent == true, "the command did not reach the compositor: " .. tostring(serr))
    return box.reply(topic)
end

-- Ask any process and wait for the answer on its topic.
--
-- The subscription is created BEFORE sending and lives only for the question —
-- the same way a window waits for an answer: the topic takes the message for
-- itself, and the check's shared inbox does not depend on it.
local function ask_on(target, topic, body: any, reply_topic)
    local payload: any = type(body) == "table" and body or {}
    payload.reply_to = tostring(process.pid())
    local sent, serr = process.send(target, topic, payload)
    test.is_true(sent == true, "the command did not reach " .. tostring(target) .. ": " .. tostring(serr))

    local replies = process.listen(reply_topic, {message = true})
    local expiry = time.after("8s")
    local answer: any = {}
    while true do
        local picked = channel.select({replies:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then
            test.is_true(false, "did not receive an answer to " .. tostring(topic)
                .. " (the compositor may have crashed — look at its screen)")
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

-- Modules gated by permissions, and the actions that open them.
--
-- The point of the rule: a declared module without a permission does NOT refuse
-- loudly. `env.get` returns nil, and the neighbouring `or default` turns a
-- permission refusal into "nobody assigned anything"; `db.get` fails the read
-- later, at work, when the query looks to blame. So the permission is checked at
-- the declaration, not at the first call.
local GATED_MODULES = {
    {module = "env", actions = {"env.get"}},
    {module = "fs", actions = {"fs.get"}},
    {module = "sql", actions = {"db.get"}},
    {module = "registry", actions = {"registry.get", "registry.find", "registry.entry", "registry.apply"}},
    {module = "exec", actions = {"exec.get", "exec.run"}},
}

-- Policies the entry carries itself. For a process it is `security.policies`,
-- for a command the same list inside `meta.command.security`. A library carries
-- none of its own: it works with the permissions of its caller, and the rule does not apply to it.
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
        local policy = registry.get(qualify(id, "windows.tui_desktop.security"))
        if policy then
            for _, action in ipairs(actions_of(policy)) do granted[action] = true end
        end
    end
    return granted
end

local function define_tests()
    test.describe("windows.tui_desktop hosts", function()
        test.it("mutes the log on the terminal host", function()
            -- Without this a runtime log line shifts the frame for good: the
            -- surface differ considers itself the only writer.
            local terminal = data_of(get(TERMINAL_ID))
            test.eq(terminal.hide_logs, true)
        end)

        test.it("keeps a separate host for windows", function()
            local workers = data_of(get(WORKERS_ID))
            test.not_nil(workers.host, "process.host must declare its host block")
            test.is_true((workers.host.max_processes or 0) > 1,
                "the windows host must fit more than one window")
        end)

        test.it("declares an executor for programs in windows", function()
            get(EXEC_ID)
        end)
    end)

    test.describe("windows.tui_desktop processes", function()
        test.it("exposes the compositor as a command with its own actor", function()
            local entry = get(DESKTOP_ID)
            local command = meta_of(entry).command or {}
            test.eq(command.name, "desktop")
            test.not_nil(command.security, "the command must carry its own security context")

            local data = data_of(entry)
            test.eq(data.method, "main")
            test.eq(qualify((data.imports or {}).chrome, "windows.tui_desktop.desktop"), CHROME_ID)
            test.is_true(has(data.modules or {}, "tty"), "the compositor needs the tty module")
            test.is_true(has(data.modules or {}, "process"), "the compositor needs the process module")
        end)

        test.it("does not hard-code the window list: one of its own, the rest brought by the application", function()
            -- The compositor opens a window by the process entry and finds other
            -- windows by meta.type. A second kind of window appearing inside the
            -- module would mean that every new window requires editing the module.
            local source = data_of(get(DESKTOP_ID)).source
            test.not_nil(source, "the compositor process must carry a source")
            local windows = registry.find({["meta.type"] = "tui_desktop.window"})
            test.not_nil(windows, "the window catalog must be readable, even if empty")
        end)

        test.it("gives a window exec and tty, but not process", function()
            -- A window spawns nothing: it only hands its port to the program.
            local data = data_of(get(WINDOW_ID))
            test.is_true(has(data.modules or {}, "exec"), "the window needs the exec module")
            test.is_true(has(data.modules or {}, "tty"), "the window needs the tty module")
        end)
    end)

    test.describe("windows.tui_desktop command channel", function()
        test.it("wires each endpoint to its handler on the application router", function()
            for _, expected in ipairs(ENDPOINTS) do
                get(expected.id)
                local endpoint = get(expected.id .. ".endpoint")
                local data = data_of(endpoint)
                test.eq(qualify(data.func, "windows.tui_desktop.api"), expected.id)
                test.eq(data.method, expected.method)
                test.eq(data.path, expected.path)
                test.eq(meta_of(endpoint).router, "app:api")
            end
            get(CONTROL_ID)
        end)

        test.it("does not let the command channel spawn processes", function()
            -- The endpoint must only be able to find the compositor and talk to it.
            -- A spawn permission here would mean that an HTTP request launches
            -- programs itself, bypassing the only place that counts them.
            local actions = actions_of(get(CHANNEL_POLICY_ID))
            test.is_true(has(actions, "process.send"), "the channel needs the permission to send a command")
            test.is_true(has(actions, "process.registry"), "the channel needs to find the compositor by name")
            test.is_false(has(actions, "process.spawn"), "the channel must not have the permission to spawn processes")
            test.is_false(has(actions, "exec.run"), "the channel must not have the permission to run programs")
        end)

        test.it("gives the compositor exactly what windows need", function()
            local actions = actions_of(get(RUNTIME_POLICY_ID))
            for _, needed in ipairs({"process.spawn.monitored", "process.terminate",
                "process.registry.register", "exec.get", "exec.run"}) do
                test.is_true(has(actions, needed), "the compositor needs the permission " .. needed)
            end
        end)

        test.it("lets the compositor return saved windows to the registry", function()
            -- Restoring lives here, not in a background service: the platform
            -- forbids processes of the wippy.security:process group to change the
            -- registry, and such a service would silently do nothing.
            local actions = actions_of(get(RUNTIME_POLICY_ID))
            test.is_true(has(actions, "registry.apply"),
                "without registry.apply windows will not survive a restart")

            -- The storage is read by the compositor library, not by the shell: the
            -- look changed, while window restoring stayed shared.
            local data = data_of(get(LIBRARY_ID))
            test.is_true(has(data.modules or {}, "sql"),
                "the compositor needs sql to read the storage")
            local imports = data.imports or {}
            test.eq(qualify(imports.repo, "windows.tui_desktop.persist"),
                "windows.tui_desktop.persist:repo")
            test.eq(qualify(imports.apps, "windows.tui_desktop.persist"),
                "windows.tui_desktop.persist:apps")
        end)

        test.it("keeps the look separate from the window mechanics", function()
            -- This is what the delta was for: a second shell brings its own
            -- theme and gets a different look without copying window hosting, the
            -- PTY and the command channel. If the mechanics start importing a
            -- specific theme again, a copy becomes the only way to change the
            -- look — and it diverges from the original at the very first edit.
            local library = data_of(get(LIBRARY_ID))
            test.is_nil((library.imports or {}).chrome,
                "the compositor mechanics must not know about a specific theme")

            local shell = data_of(get(DESKTOP_ID))
            local imports = shell.imports or {}
            test.eq(qualify(imports.library, "windows.tui_desktop.desktop"),
                "windows.tui_desktop.desktop:library",
                "the shell calls the mechanics")
            test.eq(qualify(imports.chrome, "windows.tui_desktop.desktop"),
                "windows.tui_desktop.desktop:chrome",
                "the shell picks the theme")
        end)

        test.it("lets a window ask the desktop, but not launch anything", function()
            -- A window can address the compositor (open a neighbouring window), but
            -- it has no process or program launching of its own. The window's code
            -- arrives over HTTP, and this boundary separates "ask the desktop" from
            -- "do anything at all".
            local actions = actions_of(get("windows.tui_desktop.security:app_window_scope"))
            test.is_true(has(actions, "process.send"), "a window must be able to send a command")
            test.is_true(has(actions, "process.registry"), "and to find the addressee")
            test.is_false(has(actions, "process.spawn"), "a window cannot spawn processes")
            test.is_false(has(actions, "process.spawn.monitored"), "not this way either")
            test.is_false(has(actions, "exec.run"), "a window cannot run programs")
            test.is_false(has(actions, "registry.apply"), "a window cannot change the registry")
        end)

        test.it("gates the endpoints with a policy the application injects", function()
            local policy = data_of(get(ACCESS_POLICY_ID))
            local resources = policy.policy and policy.policy.resources
            test.not_nil(resources, "policy must list resources")
            if type(resources) == "string" then resources = {resources} end
            test.is_true(has(resources, "windows.tui_desktop.api:*"),
                "policy must cover windows.tui_desktop.api:*")
        end)
    end)

    test.describe("windows.tui_desktop compositor name", function()
        test.it("a window learns its compositor's name at launch", function()
            -- A constant here was a defect: under a second shell the compositor
            -- is registered under its own name, and the window addressed someone
            -- else's (nonexistent) process. Silently — `api.open` does not wait for an answer.
            local body = ask_probe("app:window_probe", "windows.shell:shell")
            test.eq(body.name, "windows.shell:shell")
            test.eq(body.source, "context")
        end)

        test.it("the name reaches even an entry that knows nothing about ctx", function()
            -- The module is declared by the library, not by the window entry: the
            -- library gets ITS OWN modules. So windows written before this field, and
            -- windows from the workshop (it has a narrow whitelist) get the name without
            -- a single edit. Measured, not inferred: the opposite would mean
            -- that the fix fixes only new windows.
            local body = ask_probe("app:window_probe_bare", "windows.shell:shell")
            test.eq(body.name, "windows.shell:shell")
            test.eq(body.source, "context")
        end)

        test.it("a window launched without this information works as before", function()
            -- An old compositor and a foreign launch do not put the name. Such a
            -- window must take the default name, not crash: before the fix it
            -- addressed exactly that one and worked on the default shell.
            local body = ask_probe("app:window_probe", nil)
            test.eq(body.name, window_api.DEFAULT_SERVICE)
            test.eq(body.source, "default")
        end)

        test.it("the mechanics and the window take the key from one place", function()
            -- Were the key to diverge between sender and receiver, the window would
            -- silently take the default name, that is, exactly the defect being fixed
            -- here would come back. So the compositor imports the window protocol
            -- rather than repeating the string.
            local imports = data_of(get(LIBRARY_ID)).imports or {}
            test.eq(qualify(imports.window_api, "windows.tui_desktop.desktop"), WINDOW_API_ID,
                "the mechanics must take the context key from the window protocol")

            local api = data_of(get(WINDOW_API_ID))
            test.is_true(has(api.modules or {}, "ctx"),
                "without the ctx module there is nothing to read the compositor's name with")
        end)
    end)

    test.describe("windows.tui_desktop waiting for an answer in a window", function()
        test.it("a window waits for the answer without losing the compositor's command", function()
            -- The command was sent while the window was waiting. The runtime does not
            -- lose it: it waits in the process queue until the window returns to its loop.
            -- This is what is checked, not "the answer arrived": a check for a single
            -- answer turns green even when the command is lost.
            local body = play_composer("ask")
            test.eq(body.answered, "ready", "the answer must arrive whole")
            test.eq(body.handled, "desktop.close",
                "a command sent during the wait must wait for the window's loop")
        end)

        test.it("naive waiting in the inbox eats the command — and the check sees it", function()
            -- The same scenario with the loop being fixed here. The test does not
            -- rest on words: if `ask` ever goes back to reading the inbox, the
            -- check above turns red exactly the way the expectation "the command
            -- arrived" turns red here.
            local body = play_composer("naive")
            test.eq(body.answered, "yes", "the naive loop does get the answer — which is why nobody noticed")
            test.eq(body.eaten, "desktop.close", "the command was read by the waiting loop")
            test.eq(body.handled, "", "and it no longer reaches the window")
        end)
    end)

    test.describe("windows.tui_desktop a dialog belongs to a window", function()
        test.it("a dialog remembers its window and leaves with it, while the neighbouring program stays", function()
            local service = "windows.tui_desktop.test.desktop"
            local watcher = "windows.tui_desktop.test.watcher"
            local inbox = process.inbox()
            local box = mailbox(inbox)
            process.registry.register(watcher)

            local desk = boot_composer(service)

            -- The window is opened by the command channel from outside: it has no parent.
            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:dialog_probe", args = watcher, w = 40, h = 12, x = 20, y = 6})
            test.is_true(opened.ok == true, "the window did not open: " .. tostring(opened.error))
            local parent_id = tostring(opened.window.id)
            test.is_nil(opened.window.opened_by, "a window opened from outside belongs to nobody")

            -- The window opened a dialog and an ordinary program from itself.
            local report = box.take("probe.opened")
            test.is_nil(report.dialog_error, "the dialog did not open: " .. tostring(report.dialog_error))
            test.is_nil(report.plain_error, "the program did not open: " .. tostring(report.plain_error))

            local listing = ask_desktop(service, box, "desktop.list", {})
            local windows = windows_by_id(listing.windows)
            local dialog = windows[tostring(report.dialog)]
            local plain = windows[tostring(report.plain)]
            test.not_nil(dialog, "the dialog is not in the list")
            test.not_nil(plain, "the program is not in the list")

            -- The link is visible from outside: through the same field the endpoint
            -- GET /tui-desktop/windows returns it with.
            test.eq(dialog.window_type, "dialog")
            test.eq(dialog.opened_by, parent_id, "a dialog must remember its window")
            test.eq(plain.window_type, "app")
            test.eq(plain.opened_by, parent_id, "who opened the program is a fact too")

            -- The dialog stood at the centre of its window, not in the common cascade.
            local parent = windows[parent_id]
            local pcx = parent.x + parent.width // 2
            local dcx = dialog.x + dialog.width // 2
            test.is_true(math.abs(dcx - pcx) <= 1,
                "a dialog must stand at the centre of its window: " .. tostring(dcx) .. " vs " .. tostring(pcx))

            -- And the control both were opened for: closing the window takes the
            -- dialog away and does NOT touch the neighbouring program. Without it the
            -- check would turn green even for a compositor that closes everything in sight.
            ask_desktop(service, box, "desktop.close", {id = parent_id})

            local left: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                local again = ask_desktop(service, box, "desktop.list", {})
                left = windows_by_id(again.windows)
                if left[parent_id] == nil and left[tostring(report.dialog)] == nil then break end
                channel.select({time.after("150ms"):case_receive()})
            end

            test.is_nil(left[parent_id], "the window should have closed")
            test.is_nil(left[tostring(report.dialog)], "a dialog must leave together with its window")
            test.not_nil(left[tostring(report.plain)],
                "an ordinary program does not belong to the window that opened it and stays")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("windows.tui_desktop notification area", function()
        -- The tray is checked through the command channel, the way providers call it:
        -- an application service sends `desktop.tray`, and `desktop.list` is the place
        -- where "item not accepted" differs from "accepted but not drawn".
        test.it("puts, updates, removes and itself clears expired items, naming every refusal", function()
            local service = "windows.tui_desktop.test.tray"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            local put = ask_desktop(service, box, "desktop.tray",
                {key = "weather", text = "+17°", entry = "app:idle_window", ttl = 60,
                 image = "weather_sun", icon = "☼"})
            test.is_true(put.ok == true, "item not accepted: " .. tostring(put.error))
            local shown: any = ask_desktop(service, box, "desktop.list", {})
            test.eq(shown.tray[1].image, "weather_sun", "the icon for pixels reaches the theme")
            test.eq(shown.tray[1].icon, "☼", "and the character for cells too")
            local wide = ask_desktop(service, box, "desktop.tray", {key = "weather", text = "x", icon = "ab"})
            test.is_true(wide.ok == false and tostring(wide.error):find("one character", 1, true) ~= nil,
                "an icon longer than one character is refused with a reason: " .. tostring(wide.error))
            local again = ask_desktop(service, box, "desktop.tray", {key = "weather", text = "+18°", ttl = 60})
            test.eq(again.items, 1, "the same key updates the item rather than adding a second one")

            local listing: any = ask_desktop(service, box, "desktop.list", {})
            test.eq(#listing.tray, 1)
            test.eq(listing.tray[1].text, "+18°")
            test.is_nil(listing.tray[1].image, "an update without image removes the icon too")
            test.is_nil(listing.tray[1].entry, "an update without entry removes the entry too: the item is what was sent last")
            test.eq(listing.tray[1].owner, tostring(process.pid()))
            test.is_true(listing.tray[1].expires_in > 0 and listing.tray[1].expires_in <= 60,
                "remaining lifetime: " .. tostring(listing.tray[1].expires_in))

            -- Every refusal comes with its own reason. A provider would take an item
            -- silently not shown for a shown one.
            local refusals: any = {
                {body = {text = "x"}, why = "no key"},
                {body = {key = "k"}, why = "no caption"},
                {body = {key = "k", text = string.rep("я", 17)}, why = "longer than 16"},
                {body = {key = "k", text = "x", ttl = 0}, why = "ttl"},
            }
            for _, case in ipairs(refusals) do
                local refused = ask_desktop(service, box, "desktop.tray", case.body)
                test.is_true(refused.ok == false, "must be refused: " .. case.why)
                test.is_true(tostring(refused.error):find(case.why, 1, true) ~= nil,
                    "reason not named: " .. tostring(refused.error))
            end
            -- Sixteen characters are characters, not bytes: Cyrillic passes.
            test.is_true(ask_desktop(service, box, "desktop.tray",
                {key = "wide", text = string.rep("я", 16)}).ok == true, "16 Cyrillic characters are within the limit")

            for index = 3, 6 do
                test.is_true(ask_desktop(service, box, "desktop.tray",
                    {key = "k" .. index, text = tostring(index)}).ok == true)
            end
            local full = ask_desktop(service, box, "desktop.tray", {key = "k7", text = "7"})
            test.is_true(full.ok == false and tostring(full.error):find("already holds 6", 1, true) ~= nil,
                "the seventh item must be refused: " .. tostring(full.error))

            test.is_true(ask_desktop(service, box, "desktop.tray", {key = "k3", remove = true}).ok == true)
            test.is_true(ask_desktop(service, box, "desktop.tray", {key = "absent", remove = true}).ok == true,
                "removing a nonexistent item is not an error: a provider's second pass must not turn red")

            -- Lifetime: an item not updated in time leaves on its own.
            test.is_true(ask_desktop(service, box, "desktop.tray", {key = "short", text = "…", ttl = 1}).ok == true)
            channel.select({time.after("1200ms"):case_receive()})
            listing = ask_desktop(service, box, "desktop.list", {})
            local keys = {}
            for _, item in ipairs(listing.tray) do keys[#keys + 1] = item.key end
            test.eq(table.concat(keys, ","), "weather,wide,k4,k5,k6",
                "the remaining items are in order of appearance, without the removed and the expired")

            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("windows.tui_desktop window order and focus", function()
        -- The compositor here is real, the screen is the test's viewport, and clicks
        -- go into it as real mouse events. This whole class of checks used to be
        -- considered reachable only by eye through the probe.
        test.it("a click raises a window, closing the top one gives focus to the neighbour", function()
            local service = "windows.tui_desktop.test.zorder"
            local inbox = process.inbox()
            local box = mailbox(inbox)
            local desk = boot_composer(service)

            -- Two overlapping windows, coordinates named explicitly: the click must
            -- go to the spot, not to wherever the cascade put them.
            local first = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "First", x = 2, y = 3, w = 30, h = 8})
            local second = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Second", x = 10, y = 5, w = 30, h = 8})
            test.is_true(first.ok == true and second.ok == true, "the windows did not open")
            local low = tostring(first.window.id)
            local high = tostring(second.window.id)

            local listing = ask_desktop(service, box, "desktop.list", {})
            test.eq(listing.focused, high, "a new window gets focus")
            test.eq(tostring(listing.windows[#listing.windows].id), high,
                "a new window lies on top of the others")

            -- A refusal nobody waits for: a command from a window arrives without
            -- a return address, and "no such window" used to go nowhere.
            tell_desktop(service, "desktop.focus", {id = "w404"})
            local told: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                told = ask_desktop(service, box, "desktop.list", {})
                if type(told.notice) == "string" and told.notice ~= "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(type(told.notice) == "string" and told.notice:find("w404", 1, true) ~= nil,
                "the refusal must be visible: the status line is silent about w404")
            test.is_true(#box.unsolicited > 0,
                "the same refusal must also reach the sender, not only the status line")
            test.eq(told.focused, high, "a miss by id does not move focus")

            -- A click on the empty desktop. It also serves as a milestone: the compositor
            -- clears the status line, and its disappearance shows that the event has
            -- been processed — no need to wait at random.
            click(desk, 60, 20)
            local cleared: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                cleared = ask_desktop(service, box, "desktop.list", {})
                if cleared.notice == "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(cleared.notice, "", "the click on the desktop was not processed — the milestone did not fire")
            test.eq(cleared.focused, high, "a click outside the windows raises nobody")

            -- A click on the lower window — on the part of it the upper one does not
            -- cover. This is what raising by mouse is.
            click(desk, 4, 8)
            local raised: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                raised = ask_desktop(service, box, "desktop.list", {})
                if raised.focused == low then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(raised.focused, low, "a click on a window must raise it")
            test.eq(tostring(raised.windows[#raised.windows].id), low,
                "the raised window becomes the top one in z order")

            -- Closing the top one: focus must go to the neighbour, not vanish.
            ask_desktop(service, box, "desktop.close", {id = low})
            local left: any = nil
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                left = ask_desktop(service, box, "desktop.list", {})
                if #left.windows == 1 then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(#left.windows, 1, "the closed window should have gone")
            test.eq(left.focused, high, "focus must go to the remaining window")

            process.terminate(tostring(desk.pid))
        end)

        test.it("a refusal reaches a window that did not wait for an answer", function()
            -- A window sends commands without a return address so as not to freeze the
            -- frame. Previously a window never learned of a refusal of such a command:
            -- the status line is for the person, the log is for later, and nothing for the sender.
            local service = "windows.tui_desktop.test.refusal"
            local watcher = "windows.tui_desktop.test.refusal.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_composer(service)

            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:refusal_probe", args = watcher, w = 30, h = 8})
            test.is_true(opened.ok == true, "the window did not open: " .. tostring(opened.error))

            local report = box.take("probe.refusals")

            -- The refusal of the miss must arrive first — marked, so that it cannot
            -- be taken for the answer to another question.
            test.is_true(report.first_unsolicited == true,
                "the refusal must be marked as having arrived on its own")
            test.eq(report.first_command, "desktop.focus", "the refusal must name the command")
            test.is_true(tostring(report.first_error):find("w404", 1, true) ~= nil,
                "the refusal must name the miss: " .. tostring(report.first_error))

            -- And the control: between the miss and the question the window sent a
            -- VALID command. The answer to the question came second — so the compositor
            -- sent nothing for the valid command, and "reaches" has not degenerated
            -- into "sends on everything". No waiting was needed for this: messages
            -- arrive in order.
            test.eq(report.second_command, "desktop.list",
                "the second must be the answer to the question, not a response to the valid command")
            test.is_true(report.second_ok == true, "the answer to desktop.list must be a success")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("a miss by id answers the asker with a refusal", function()
            -- The command channel has a return address, and the refusal comes to it
            -- as an answer. The check pairs with the status line: there the refusal
            -- is visible to the person, here to the asker.
            local service = "windows.tui_desktop.test.missing"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            local answer = ask_desktop(service, box, "desktop.focus", {id = "w404"})
            test.is_true(answer.ok == false, "a miss must be a refusal, not a success")
            test.is_true(tostring(answer.error):find("w404", 1, true) ~= nil,
                "the refusal must name the id")

            local unknown = ask_desktop(service, box, "desktop.wiggle", {})
            test.is_true(unknown.ok == false, "an unknown command is a refusal too")
            test.is_true(tostring(unknown.error):find("wiggle", 1, true) ~= nil,
                "the refusal must name the command")

            -- A command that names no window, and should not: re-read the desktop
            -- layout. While "no window" was checked first, it answered
            -- "no window nil" and did not run at all — and the shell calls it
            -- every time a person moves an icon.
            local refreshed = ask_desktop(service, box, "desktop.refresh", {})
            test.is_true(refreshed.ok == true,
                "desktop.refresh must run: " .. tostring(refreshed.error))

            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("windows.tui_desktop pixel chrome", function()
        test.it("without a cell size the mode does not turn on and names the reason", function()
            -- The guess "8×16" is right often enough to look correct, and wrong
            -- often enough to be taken for a drawing error.
            local watcher = "windows.tui_desktop.test.pixels.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)

            local silent = spawn_pixel_composer(
                "windows.tui_desktop.test.pixels.silent", watcher, "silent")
            local told = box.take("composer.refused")
            test.is_true(tostring(told.error):find("does not start", 1, true) ~= nil,
                "the refusal must call itself a refusal: " .. tostring(told.error))
            test.is_true(tostring(told.error):find("did not say how large a cell is", 1, true) ~= nil,
                "the refusal must carry the reason from the terminal: " .. tostring(told.error))
            process.terminate(tostring(silent.pid))

            -- And a shell that gave no means to ask at all.
            local mute = spawn_pixel_composer(
                "windows.tui_desktop.test.pixels.mute", watcher, "nothing")
            local second = box.take("composer.refused")
            test.is_true(tostring(second.error):find("cell_size", 1, true) ~= nil,
                "the refusal must name what was missing: " .. tostring(second.error))
            process.terminate(tostring(mute.pid))

            -- And a theme that cannot draw with rasters.
            local plain = spawn_pixel_composer(
                "windows.tui_desktop.test.pixels.cells", watcher, "cells_theme")
            local third = box.take("composer.refused")
            test.is_true(tostring(third.error):find("chrome.paint", 1, true) ~= nil,
                "the refusal must name what the theme lacks: " .. tostring(third.error))
            process.terminate(tostring(plain.pid))

            process.registry.unregister(watcher)
        end)

        test.it("a click works in all three hit groups, not only on the desktop", function()
            -- In this mode the mechanics call neither `bars` nor `menu`: the layout
            -- arrives in groups from `paint`. A group that did not reach the
            -- handler gives a click into the void — from outside indistinguishable
            -- from "the mouse does not work", and people will look anywhere except
            -- the shape of the theme's answer.
            local service = "windows.tui_desktop.test.pixels.hits"
            local watcher = "windows.tui_desktop.test.pixels.hits.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            local first = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "First", x = 2, y = 3, w = 30, h = 8})
            local second = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Second", x = 10, y = 5, w = 30, h = 8})
            test.is_true(first.ok == true and second.ok == true, "the windows did not open")
            local low = tostring(first.window.id)

            -- GROUP bars, a hit with a window number: a button on the taskbar
            -- raises the lower window.
            click(desk, 5, 24)
            local raised: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                raised = ask_desktop(service, box, "desktop.list", {})
                if raised.focused == low then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(raised.focused, low, "a bars hit with a window number must raise the window")

            -- GROUP bars, a hit with an action: the "Start" button opens the
            -- menu. Checked separately from the item: otherwise "the click did not arrive"
            -- and "the menu opened but the item did not work" would merge into one failure.
            click(desk, 62, 24)
            local opened_menu: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                opened_menu = ask_desktop(service, box, "desktop.list", {})
                if opened_menu.menu_open == true then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(opened_menu.menu_open == true,
                "a bars hit with an action must open the menu")

            -- GROUP menu, a folder: a click on a row with a path expands it.
            -- By mouse this is the same path as the right arrow, and until today
            -- neither of them had been checked.
            click(desk, 5, 7)
            local deepened: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                deepened = ask_desktop(service, box, "desktop.list", {})
                if tostring(deepened.menu_path) ~= "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(tostring(deepened.menu_path), "Programs",
                "a click on a folder must expand it")

            -- GROUP menu, a program: a click on an item inside the expanded folder
            -- opens it. The items of the second panel lie further right — per the
            -- layout the theme returned.
            click(desk, 40, 7)
            local after: any = nil
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                after = ask_desktop(service, box, "desktop.list", {})
                if #after.windows == 3 then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(#after.windows, 3, "a menu hit must open a program")
            test.eq(tostring(after.windows[#after.windows].entry), "app:menu_second",
                "and exactly the one clicked: the first row of the catalog")
            test.is_true(after.menu_open == false, "a chosen item closes the menu")

            -- Control: a click outside any layout opens nothing and raises
            -- nobody. Without it "works" would mean "something happens on any
            -- click".
            click(desk, 62, 24)
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                after = ask_desktop(service, box, "desktop.list", {})
                if after.menu_open == true then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(after.menu_open == true, "the menu is open again")

            click(desk, 40, 20)
            local closed: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                closed = ask_desktop(service, box, "desktop.list", {})
                if closed.menu_open == false then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(closed.menu_open == false, "a click outside the menu closes it")
            test.eq(#closed.windows, 3, "and opens nothing")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("arrows move the cursor through the menu, and enter opens the marked row", function()
            -- There are no more digit shortcuts in the menu: a keyboard path not
            -- visible in the interface must not be added. So the arrows must
            -- work — and work by the LAYOUT, not by the catalog.
            local service = "windows.tui_desktop.test.pixels.keys"
            local watcher = "windows.tui_desktop.test.pixels.keys.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            -- The harness catalog is visible in the menu as two entries, by title:
            -- "Another target", then "Menu target".
            local function open_menu()
                click(desk, 62, 24)
                local shown: any = nil
                local deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline do
                    shown = ask_desktop(service, box, "desktop.list", {})
                    if shown.menu_open == true then break end
                    channel.select({time.after("100ms"):case_receive()})
                end
                test.is_true(shown.menu_open == true, "the menu must open")
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
                test.is_true(#grown.windows > before, "the program did not open")
                return tostring(grown.windows[#grown.windows].entry)
            end

            -- Without arrows enter opens the first row.
            -- The first row is now a folder, so the program is one arrow away.
            open_menu()
            press(desk, "down")
            press(desk, "enter")
            test.eq(opened_after(0), "app:menu_second",
                "enter opens the row under the cursor")

            -- Right on a folder expands it, left returns. Checked by the
            -- PATH, not by the consequence: on the stand "right did not work" and
            -- "it worked but the submenu was not drawn" give the same zero
            -- bytes, and only this field can tell them apart.
            open_menu()
            local path: any = ask_desktop(service, box, "desktop.list", {})
            test.eq(tostring(path.menu_path), "", "the menu opens at the root")

            -- How many rows and how many folders are on the level — in the same answer.
            -- "Right is silent" may mean "nothing to expand", and on the stand
            -- this cost an hour of hunting for a defect that did not exist.
            test.eq(math.tointeger(path.menu_choices) or 0, 3,
                "at the root, a folder and two programs")
            test.eq(math.tointeger(path.menu_folders) or 0, 1,
                "and exactly one of them expands")

            press(desk, "right")
            local deepened: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                deepened = ask_desktop(service, box, "desktop.list", {})
                if tostring(deepened.menu_path) ~= "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(tostring(deepened.menu_path), "Programs",
                "right on a folder must expand it")
            test.eq(math.tointeger(deepened.menu_folders) or -1, 0,
                "inside the folder there is nothing more to expand — and this is visible, not silent")

            press(desk, "left")
            local back: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                back = ask_desktop(service, box, "desktop.list", {})
                if tostring(back.menu_path) == "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(tostring(back.menu_path), "", "left must return to the level above")

            -- And the control: right on a program row has nothing to expand, the
            -- path must stay the same. Otherwise "right works" would mean
            -- "right does something".
            press(desk, "down")
            press(desk, "right")
            channel.select({time.after("400ms"):case_receive()})
            test.eq(tostring(ask_desktop(service, box, "desktop.list", {}).menu_path), "",
                "right on a program expands nothing")
            press(desk, "esc")

            -- With the down arrow, the second one. This is the proof that the cursor
            -- moves: the same enter, a different result.
            open_menu()
            press(desk, "down")
            press(desk, "down")
            press(desk, "enter")
            test.eq(opened_after(1), "app:menu_target",
                "the down arrow must move the cursor to the next row")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("mouse hover highlights a menu row and expands a folder with a delay", function()
            -- The terminal reports motion without a press, and in Windows the row
            -- under the pointer is highlighted, while a folder under it expands by itself.
            -- Checked by the `menu_cursor` FIELD: "hover did not highlight" and
            -- "highlighted but the theme did not draw it" look the same on screen.
            local service = "windows.tui_desktop.test.pixels.hover"
            local watcher = "windows.tui_desktop.test.pixels.hover.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            local function hover(x, y)
                local sent = desk.view:send({type = "mouse", action = "motion", button = "none", x = x, y = y})
                test.is_true(sent == true, "the mouse motion did not reach the compositor's screen")
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
                "the menu must open")
            test.eq(math.tointeger(opened.menu_cursor) or -1, 1, "the menu opens with the cursor on the first row")

            -- A program row under the pointer is highlighted at once; the cascade is not touched.
            hover(5, 8)
            local moved = wait_for(function(shown) return (math.tointeger(shown.menu_cursor) or -1) == 2 end,
                "hover must highlight the row under the pointer")
            test.eq(tostring(moved.menu_path), "", "hover over a program expands nothing")

            -- The folder expands — but not on the very first event: only the delay
            -- tells "going into the submenu" from "passing by".
            hover(5, 7)
            local at_once: any = ask_desktop(service, box, "desktop.list", {})
            test.eq(tostring(at_once.menu_path), "", "the folder expands with a delay, not at the same instant")
            local deepened = wait_for(function(shown) return tostring(shown.menu_path) == "Programs" end,
                "hover over a folder must expand it")
            test.eq(math.tointeger(deepened.menu_cursor) or -1, 0, "nothing is chosen in a submenu expanded by hover")

            -- Moving to a root program closes the submenu and highlights the program.
            -- The harness theme rows are two cells each: the folder 6–7, programs 8–9 and 10–11.
            hover(5, 10)
            local back = wait_for(function(shown) return tostring(shown.menu_path) == "" end,
                "leaving the folder must close the submenu")
            test.eq(math.tointeger(back.menu_cursor) or -1, 3, "the row under the pointer is highlighted")

            -- Enter opens EXACTLY the row highlighted by hover.
            local before = #ask_desktop(service, box, "desktop.list", {}).windows
            press(desk, "enter")
            local grown = wait_for(function(shown) return #shown.windows > before end,
                "enter on a row highlighted by hover must open it")
            test.eq(tostring(grown.windows[#grown.windows].entry), "app:menu_target",
                "the row under the pointer opened, not the first one")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("a right click on an icon opens a context menu at the pointer, esc closes it", function()
            local service = "windows.tui_desktop.test.pixels.context"
            local watcher = "windows.tui_desktop.test.pixels.context.watcher"
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

            -- The test theme's first icon stands at 2,4. A right click on it
            -- selects it and opens a menu with an anchor — without "Start".
            desk.view:send({type = "mouse", action = "press", button = "right", x = 3, y = 4})
            local shown = wait_context(true)
            test.eq(shown.menu_context, true, "a right click on an icon must open the context menu")
            test.eq(tostring(shown.selected), "i1", "a right click selects the icon")
            test.eq(math.tointeger(shown.menu_choices) or 0, 1,
                "an icon without a properties window has one item, Open")

            press(desk, "esc")
            local closed = wait_context(false)
            test.eq(closed.menu_context, false, "esc closes the context menu")
            test.eq(#closed.windows, 0, "the closed menu opened nothing")

            -- Again, and enter opens "Open" — the same window as a double click.
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
            test.eq(#grown.windows, 1, "enter in the context menu must open the icon")
            test.eq(tostring(grown.windows[1].entry), "app:menu_target")
            test.eq(grown.menu_context, false, "after opening, the menu is closed")

            -- A right click on the empty desktop gives the desktop's "Properties", since
            -- the shell named a window (`desktop_properties`); the selection is cleared.
            desk.view:send({type = "mouse", action = "press", button = "right", x = 60, y = 20})
            local bare = wait_context(true)
            test.eq(bare.menu_context, true, "on the empty desktop — desktop properties")
            test.eq(math.tointeger(bare.menu_choices) or 0, 1)
            test.eq(bare.selected, nil, "a click on the empty desktop clears the selection")
            test.is_true((math.tointeger(bare.cell.w) or 0) > 0, "desktop.list names the cell size")
            test.eq(bare.pixels, true, "and the frame mode")
            press(desk, "esc")
            wait_context(false)

            desk.view:send({type = "key", action = "press", key_type = "runes", key = "q", ctrl = true})
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline and process.registry.lookup(service) do
                channel.select({time.after("20ms"):case_receive()})
            end
            desk.view:close()
        end)

        test.it("arrows move the selection across desktop icons, and enter opens it", function()
            -- The icons lie in a two-by-two grid; each has TWO hit rows, like a
            -- real theme with a caption. The down arrow must go to the
            -- neighbouring icon, not to the caption of the same one.
            local service = "windows.tui_desktop.test.pixels.icons"
            local watcher = "windows.tui_desktop.test.pixels.icons.watcher"
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

            -- The first arrow selects rather than moves: nothing is selected yet.
            test.eq(press_until("right", "i1"), "i1", "the first arrow must select the first icon")
            test.eq(press_until("right", "i2"), "i2", "right — the neighbouring icon in the row")
            test.eq(press_until("down", "i4"), "i4", "down — the icon one row below, not its own caption")
            test.eq(press_until("left", "i3"), "i3", "left — the neighbour on the left")

            -- Control: at the edge there is nowhere to move, and the selection must stay.
            -- Without it "arrows work" would mean "the selection jumps
            -- somewhere".
            press(desk, "left")
            channel.select({time.after("400ms"):case_receive()})
            test.eq(selection(), "i3", "at the grid's edge the selection does not move away")

            -- Enter opens the selected icon.
            press(desk, "enter")
            local grown: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                grown = ask_desktop(service, box, "desktop.list", {})
                if #grown.windows > 0 then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(#grown.windows, 1, "enter must open the selected icon")
            test.eq(tostring(grown.windows[1].entry), "app:menu_target")

            -- And now, with a window in focus, the arrows belong to IT: the desktop
            -- no longer takes them, otherwise an editor inside the window would lose
            -- its arrows.
            local before = selection()
            press(desk, "up")
            channel.select({time.after("400ms"):case_receive()})
            test.eq(selection(), before, "with a window in focus the desktop does not take the arrows")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("flat theme hits are not guessed, and the reason is visible to the person", function()
            -- "The mouse does not work" is how this looks on the stand; the terminal
            -- host's log is muted, so a complaint told only to it is told
            -- to nobody. So it must be in the status line — the only place
            -- a person sees.
            local service = "windows.tui_desktop.test.pixels.flat"
            local watcher = "windows.tui_desktop.test.pixels.flat.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "flat")

            local first = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "First", x = 2, y = 3, w = 30, h = 8})
            local second = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Second", x = 10, y = 5, w = 30, h = 8})
            test.is_true(first.ok == true and second.ok == true, "the windows did not open")
            local high = tostring(second.window.id)

            local told: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                told = ask_desktop(service, box, "desktop.list", {})
                if tostring(told.notice) ~= "" then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(tostring(told.notice):find("flat", 1, true) ~= nil,
                "the status line must name the reason: [" .. tostring(told.notice) .. "]")

            -- And the click really does not work in the meantime — otherwise the
            -- complaint would be about a nonexistent trouble.
            click(desk, 5, 24)
            channel.select({time.after("500ms"):case_receive()})
            local unchanged = ask_desktop(service, box, "desktop.list", {})
            test.eq(unchanged.focused, high,
                "a flat list gives no clicks, and this must not look like working")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)

        test.it("chrome as images, content as characters, spaces under images", function()
            local service = "windows.tui_desktop.test.pixels.live"
            local watcher = "windows.tui_desktop.test.pixels.live.watcher"
            local box = mailbox(process.inbox())
            process.registry.register(watcher)
            local desk = boot_pixel_composer(service, watcher, "ok")

            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:painter_window", x = 5, y = 4, w = 30, h = 8})
            test.is_true(opened.ok == true, "the window did not open: " .. tostring(opened.error))
            local first = tostring(opened.window.id)

            -- Wait for a frame with content: a window does not draw itself instantly,
            -- and the readiness sign is visible in the list.
            local listing: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                listing = ask_desktop(service, box, "desktop.list", {})
                if listing.windows[1] ~= nil and listing.windows[1].ready == true then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(listing.pixels == true, "the compositor must be in pixel mode")

            -- The background is filled by the theme, in this mode too: without the fill
            -- the window body shows the desktop through where the program inside wrote
            -- nothing — and on a snapshot of a PIECE this is not visible, only on the whole.
            local empty_row = tostring(screen_of(desk)[20] or "")
            test.is_true(empty_row:find("▒", 1, true) ~= nil,
                "the desktop must be filled in pixel mode too: [" .. empty_row .. "]")

            -- The window's content is placed by the COMPOSITOR: in character mode the
            -- theme did it together with the frame, and a raster theme does not write to the canvas at all.
            local content = tostring(screen_of(desk)[5] or "")
            test.is_true(content:find("CONTENT", 1, true) ~= nil,
                "the window's row must lie in the frame as characters: [" .. content .. "]")

            -- Now a second window whose TITLE lies exactly on this row.
            -- Without spaces under the image the character would stay in place and stick
            -- out from under it at the first redraw of the row — checking an empty
            -- row would be a check without evidence, it is empty there anyway.
            local second = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", x = 5, y = 5, w = 30, h = 8})
            test.is_true(second.ok == true, "the second window did not open")
            test.eq(ask_desktop(service, box, "desktop.list", {}).focused,
                tostring(second.window.id), "the new window is on top")

            local covered: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                covered = tostring(screen_of(desk)[5] or "")
                if covered:find("CONTENT", 1, true) == nil then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(covered:find("CONTENT", 1, true) == nil,
                "there must be spaces under a placement: [" .. covered .. "]")

            -- The frame's cost is visible from outside: badly sliced chrome draws a
            -- CORRECT screen, just a slow one, and there is nothing else to find it with.
            local costed = ask_desktop(service, box, "desktop.list", {})
            test.not_nil(costed.frame, "the compositor must report the frame cost")
            test.is_true((math.tointeger(costed.frame.images) or 0) >= 3,
                "the raster theme declared placements, they must be visible")
            -- `placements_sent` is deliberately not checked here: this check's theme
            -- creates no rasters at all, so a zero in that field would come
            -- out under any slicing error. The real measure is with a theme
            -- with real rasters; here the only thing checked is that the compositor
            -- reports the frame cost outward.

            click(desk, 5, 24)
            local raised: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                raised = ask_desktop(service, box, "desktop.list", {})
                if raised.focused == first then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(raised.focused, first,
                "a click on the raster theme's layout must raise the window")

            process.registry.unregister(watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("windows.tui_desktop frame cost in time", function()
        -- "It is slow" is not fixed without numbers: measure first. Bytes and rows
        -- say how much went to the terminal, but not where the time went, and the
        -- argument "rebuilding in Lua or present" would be settled by eye.
        test.it("the status carries the frame time, its trigger and a summary over recent frames", function()
            local service = "windows.tui_desktop.test.frame_time"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            -- The first frame is drawn before the loop takes commands: by the answer
            -- to the first question it is already there.
            local first: any = ask_desktop(service, box, "desktop.list", {})
            test.not_nil(first.frame, "the compositor must report the frame cost")
            local frame: any = first.frame or {}
            test.eq(type(frame.paint_ms), "number", "paint_ms must be a number")
            test.eq(type(frame.present_ms), "number", "present_ms must be a number")
            test.is_true((tonumber(frame.paint_ms) or -1) >= 0
                and (tonumber(frame.present_ms) or -1) >= 0, "frame time is never negative")
            test.is_true((tonumber(frame.total_ms) or -1) >= (tonumber(frame.paint_ms) or 0),
                "total_ms must include paint_ms")
            test.eq(frame.trigger, "start", "the first frame names start as its trigger")

            -- The next frame's trigger is the command that redrew the desktop. Without
            -- the trigger's name the summary would say "max 40 ms" and would not say
            -- what from.
            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:idle_window", title = "Measure", x = 2, y = 3, w = 30, h = 8})
            test.is_true(opened.ok == true, "the window did not open: " .. tostring(opened.error))

            local after: any = ask_desktop(service, box, "desktop.list", {})
            local window: any = after.frame and after.frame.window or {}
            test.is_true((math.tointeger(window.frames) or 0) >= 2,
                "both frames must be in the summary: start and opening")
            test.eq(math.tointeger(window.frames), math.tointeger(after.frame.frames_total),
                "while there are fewer frames than the summary window, it sees them all")
            local triggers: any = window.triggers or {}
            test.eq(math.tointeger(triggers.start), 1, "exactly one start in the summary")
            test.is_true((math.tointeger(triggers.command) or 0) >= 1,
                "a frame from a command must call itself a command")
            test.is_true(triggers.unknown == nil, "no branch of the loop is left nameless")
            for _, part in ipairs({"paint", "present", "total"}) do
                local stats: any = window[part] or {}
                test.eq(type(stats.p95_ms), "number", part .. ".p95_ms must be a number")
                test.is_true((tonumber(stats.max_ms) or -1) >= (tonumber(stats.avg_ms) or 0),
                    part .. ": the maximum is not less than the average")
                test.eq(type(stats.max_trigger), "string", part .. ".max_trigger names the trigger")
            end

            -- Raw frames only on request, and one per frame: the per-phase
            -- measurement joins them by seq, and a gap would read as
            -- "there was no frame".
            test.is_nil(after.frame.samples, "without a request raw frames do not go into the status")
            local raw: any = ask_desktop(service, box, "desktop.list", {frame_samples = true})
            local samples: any = raw.frame and raw.frame.samples or {}
            test.eq(#samples, math.tointeger(raw.frame.frames_total),
                "while there are fewer frames than the ring, there are as many raw frames as were drawn")
            for index, sample in ipairs(samples) do
                test.eq(math.tointeger(sample.seq), index, "seq goes consecutively from old to new")
                test.eq(type(sample.paint_ms), "number", "a raw frame has paint_ms")
                test.eq(type(sample.at_ms), "number", "a raw frame has a moment")
            end
            test.eq(samples[1] and samples[1].trigger, "start", "the first raw frame is start")

            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("windows.tui_desktop permissions for declared modules", function()
        test.it("a permission is granted for every module gated by permissions", function()
            -- This class cost three hours here and looked like four different
            -- problems in a row: the compositor declared `env`, had no permission for
            -- it, and the reassigned database name silently did not work.
            local entries = registry.find({})
            test.not_nil(entries, "the registry must be readable")

            local checked = 0
            for _, found in ipairs(entries :: {any}) do
                local entry: any = found
                local id = tostring(entry.id)
                if id:find("windows.tui_desktop", 1, true) == 1 then
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
                                test.is_true(ok, id .. " declares the module " .. gate.module
                                    .. ", but no permission is granted for it: it will stay silent rather than refuse")
                            end
                        end
                    end
                end
            end

            test.is_true(checked > 0, "the rule must check at least something, otherwise it is green for nothing")
        end)

        test.it("a workshop window does not ask for modules it has no means to open", function()
            -- A built window has one policy and it is known in advance, so the
            -- rule is checked right on the whitelist: a module the window may
            -- ask for must be opened by this policy.
            local granted = granted_actions({"windows.tui_desktop.security:app_window_scope"})
            for _, gate in ipairs(GATED_MODULES) do
                if apps.ALLOWED_MODULES[gate.module] then
                    local ok = false
                    for _, action in ipairs(gate.actions) do
                        if granted[action] then ok = true end
                    end
                    test.is_true(ok, "a window is allowed the module " .. gate.module
                        .. ", but app_window_scope has no permission for it")
                end
            end

            -- And the control that the rule has not degenerated into an empty loop:
            -- `sql` is in the list, and the permission for it is granted.
            test.is_true(apps.ALLOWED_MODULES.sql == true)
            test.is_true(granted["db.get"] == true)
        end)
    end)

    test.describe("windows.tui_desktop assembling a pixel frame", function()
        -- Arithmetic without a terminal and without graphics: what the theme returned
        -- arrives here, and here it is decided whether it gets into the frame.
        -- A witness canvas: records calls instead of drawing. As one table
        -- rather than two values — otherwise the checker counts the second
        -- value as absent.
        local function recorder()
            local box: any = {calls = {}}
            local canvas: any = {}
            function canvas:put(x, y, text, span)
                box.calls[#box.calls + 1] = {x = x, y = y, text = text, span = span}
            end
            box.canvas = canvas
            return box
        end

        test.it("erases characters exactly under the image", function()
            local box = recorder()
            local images = pixels.frame(box.canvas,
                {placements = {{id = "title", x = 5, y = 4, cols = 3, rows = 2}}})
            test.eq(#images, 1)
            test.eq(#box.calls, 2, "one row per row of the placement")
            test.eq(box.calls[1].x, 5)
            test.eq(box.calls[1].y, 4)
            test.eq(box.calls[1].text, "   ")
            test.eq(box.calls[2].y, 5)
        end)

        test.it("an invalid placement is dropped and named, and the frame does not fall", function()
            -- `present` rejects the WHOLE frame if even one placement is invalid,
            -- and the compositor calls it through assert: a theme with one
            -- typo would put out the whole desktop.
            local box = recorder()
            local images, complaints = pixels.frame(box.canvas, {placements = {
                {id = "", x = 1, y = 1, cols = 1, rows = 1},
                {id = "zero", x = 0, y = 1, cols = 1, rows = 1},
                {id = "empty", x = 1, y = 1, cols = 0, rows = 1},
                {id = "valid", x = 2, y = 2, cols = 2, rows = 1},
                {id = "valid", x = 9, y = 9, cols = 2, rows = 1},
            }})
            test.eq(#images, 1, "only the valid one must get into the frame")
            test.eq(images[1].id, "valid")
            test.eq(#complaints, 4, "and every invalid one must be named")
            test.is_true(tostring(complaints[4]):find("twice", 1, true) ~= nil,
                "a repeated id is a dispute over what to show, that is, flicker")
        end)

        test.it("every extracted function is called by at least one check", function()
            -- An uncalled function is green in any suite — today this cost a
            -- theme crash on the very first call of a function nobody had
            -- called before. So the export list is compared with the list of
            -- covered ones: a new function without a check turns the suite red.
            local covered: any = {
                pixels = {check = true, blank_under = true, hits = true, frame = true},
                programs = {window_type = true, in_menu = true, content = true,
                    item = true, menu = true, resizable = true},
            }

            for name, value in pairs(pixels) do
                if type(value) == "function" then
                    test.is_true(covered.pixels[name] == true,
                        "pixels." .. name .. " is not called by any check")
                end
            end
            for name, value in pairs(programs) do
                if type(value) == "function" then
                    test.is_true(covered.programs[name] == true,
                        "programs." .. name .. " is not called by any check")
                end
            end
        end)

        test.it("an unknown window_content counts as cells and is named", function()
            -- The same order as for the window type: a typo does not hide the program,
            -- but does not stay silent either.
            local kind, odd = programs.content({window_content = "tiles"})
            test.eq(kind, programs.DEFAULT_CONTENT)
            test.eq(odd, "tiles")

            local plain, quiet = programs.content({})
            test.eq(plain, "cells", "a silent entry behaves as before")
            test.is_nil(quiet)
        end)

        test.it("a fixed size is declared by the entry, the default is resizable", function()
            -- The string "false" is a refusal on a par with the boolean: an entry arrives
            -- both from YAML and from JSON, and "a string is truth" would give a resizable
            -- calculator exactly to whoever asked for the opposite.
            test.is_true(programs.resizable({}), "a silent entry is resizable, as before")
            test.is_true(programs.resizable(nil))
            test.is_false(programs.resizable({resizable = false}))
            test.is_false(programs.resizable({resizable = "false"}))
            test.is_true(programs.resizable({resizable = true}))

            local item = programs.item({id = "app:calc", meta = {resizable = false}})
            test.is_false(item.resizable, "the flag must reach the catalog item")
            local plain = programs.item({id = "app:bash", meta = {}})
            test.is_true(plain.resizable)
        end)

        test.it("a fixed size is taken from the entry, even if another one was requested", function()
            -- The clock from the taskbar opens without a size; a window that took the
            -- compositor's default would stand across the whole desktop with a dialog in the corner.
            local item = programs.item({id = "app:clock", meta = {resizable = false, width = 42, height = 18}})
            test.eq(item.w, 42)
            test.eq(item.h, 18)
            test.is_false(item.resizable)
        end)

        test.it("a flat hit list does not guess, it complains", function()
            -- Guessing is impossible here: `id` means different things for the desktop,
            -- the bars and the menu, and silently lost clicks look like a dead interface.
            local hits, quarrel = pixels.hits({hits = {{row = 1, from = 1, to = 3, id = "w1"}}})
            test.eq(#hits.bars, 0)
            test.not_nil(quarrel)

            local grouped = pixels.hits({hits = {bars = {{row = 1, from = 1, to = 3, id = "w1"}}}})
            test.eq(#grouped.bars, 1)
            test.eq(#grouped.desktop, 0)
            test.eq(#grouped.menu, 0)
        end)

        test.it("widget records pass through the desktop group unchanged", function()
            local hits = pixels.hits({hits = {desktop = {
                {row = 4, from = 79, to = 98, widget = "g1", entry = "app:window", title = "Memory"},
            }}})
            test.eq(#hits.desktop, 1)
            test.eq(hits.desktop[1].widget, "g1")
            test.eq(hits.desktop[1].entry, "app:window")
            test.eq(hits.desktop[1].title, "Memory")
        end)
    end)

    test.describe("windows.tui_desktop arrows in character mode", function()
        test.it("the menu cursor reaches the theme in cells too, not only in pixels", function()
            -- The mode that was not checked is the one where the arrows move something
            -- INVISIBLE: a person presses, something changes, and they do not see where.
            -- So the same path is checked with the default theme, where the cursor
            -- arrives as the seventh argument of chrome.menu.
            local service = "windows.tui_desktop.test.keys.cells"
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
                test.is_true(shown.menu_open == true, "alt+o must open the menu")
            end

            local function opened_after(before)
                local grown: any = nil
                local deadline = time.now():unix_nano() + 8000000000
                while time.now():unix_nano() < deadline do
                    grown = ask_desktop(service, box, "desktop.list", {})
                    if #grown.windows > before then break end
                    channel.select({time.after("100ms"):case_receive()})
                end
                test.is_true(#grown.windows > before, "the program did not open")
                return tostring(grown.windows[#grown.windows].entry)
            end

            open_menu()
            press(desk, "enter")
            test.eq(opened_after(0), "app:menu_second", "enter opens the row under the cursor")

            open_menu()
            press(desk, "down")
            press(desk, "enter")
            -- If the cursor did not reach the theme, it marks the first row, and the
            -- first one opens again — with the same enter, after the same arrow.
            test.eq(opened_after(1), "app:menu_target",
                "the cursor must reach the theme: otherwise the arrow moves something invisible")

            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("windows.tui_desktop pixel theme zoom", function()
        test.it("a cell size change updates the frame and the client even with the same grid", function()
            local service = "windows.tui_desktop.test.pixels.zoom"
            local watcher = service .. ".watcher"
            local provider = "windows.tui_desktop.test.provider"
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
                test.not_nil(report.resize, "the client did not get a resize after the cell size change")
                test.eq(report.resize.cell_w, expected.w)
                test.eq(report.resize.cell_h, expected.h)
                test.eq(report.resize.width, 28)
                test.eq(report.resize.height, 12 - expected.top - 1,
                    "the title inset must update before the client's resize")
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

    test.describe("windows.tui_desktop pixel theme insets", function()
        test.it("the background is drawn before the content, and the mouse is counted from the viewport", function()
            local service = "windows.tui_desktop.test.pixels.insets"
            local provider = "windows.tui_desktop.test.provider"
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
                "the compositor must call the theme's background")
            click(desk, 7, 7)
            local report: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                report = ask_on(provider, "probe.report", {}, "probe.state")
                if tostring(report.inputs):find("mouse:", 1, true) then break end
                channel.select({time.after("20ms"):case_receive()})
            end
            test.is_true(tostring(report.inputs):find("mouse:1,1", 1, true) ~= nil,
                "the first pixel of the viewport must get the first cell: " .. tostring(report.inputs))
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
            test.is_nil(process.registry.lookup(provider), "the provider must finish after the close")
            process.terminate(tostring(desk.pid))
            process.registry.unregister(watcher)
        end)
    end)

    test.describe("windows.tui_desktop view window without a process", function()
        test.it("a view waits for its provider instead of silently showing emptiness", function()
            local service = "windows.tui_desktop.test.view"
            local provider = "windows.tui_desktop.test.provider"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            -- Open without waiting for the answer, and the window number is taken from
            -- the list: what is checked is the desktop's state, not the shape of the
            -- answer to the open — neighbouring tests check that.
            tell_desktop(service, "desktop.open",
                {entry = "app:view_window", x = 5, y = 4, w = 30, h = 8})

            local opened: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                local listing = ask_desktop(service, box, "desktop.list", {})
                if listing.windows[1] ~= nil then opened = listing.windows[1] break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.not_nil(opened, "the view did not open")
            local id = tostring(opened.id)
            test.eq(opened.content, "pixels", "for a view the content is drawn by the theme")
            test.is_true(opened.waiting == true,
                "there is no state yet, and the view must say so")
            test.eq(math.tointeger(opened.state_revision) or -1, 0)

            -- The provider is brought up by the compositor and lives as its own process.
            local alive: any = nil
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                alive = process.registry.lookup(provider)
                if alive then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.not_nil(alive, "the state provider must be running")

            -- It knows whom to answer and about which window: the name and the number
            -- arrived to it as arguments at launch.
            local report = ask_on(provider, "probe.report", {}, "probe.state")
            test.eq(report.desktop, service, "the provider must know its compositor")
            test.eq(report.window, id, "and the number of the window it answers for")

            -- IT pushes the state; the compositor does not ask.
            process.send(provider, "probe.push", {})
            local listing: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                listing = ask_fresh(service, "desktop.list", {})
                if listing.windows[1] ~= nil and listing.windows[1].waiting == false then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(listing.windows[1].waiting == false, "the state arrived — nothing more to wait for")
            test.eq(math.tointeger(listing.windows[1].state_revision) or -1, 1)

            -- And the control: the state of SOMEONE ELSE'S process is not accepted. A
            -- view drawn from planted data is indistinguishable from a real one.
            local stolen = ask_fresh(service, "desktop.state",
                {id = id, state = {title = "forgery"}})
            test.is_true(stolen.ok == false, "someone else's state must be rejected")
            test.is_true(tostring(stolen.error):find("provider", 1, true) ~= nil,
                "the refusal must name the reason: " .. tostring(stolen.error))
            test.eq(math.tointeger(ask_fresh(service, "desktop.list", {})
                .windows[1].state_revision) or -1, 1, "the forgery must not move the counter")

            -- Input goes to the provider: the view no longer has a live part.
            click(desk, 10, 8)
            local seen: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                seen = ask_on(provider, "probe.report", {}, "probe.state")
                -- The click, not the first input: the provider also hears the
                -- compositor's focus event now, and it can arrive first.
                if tostring(seen.inputs):find("mouse:", 1, true) then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(tostring(seen.inputs):find("mouse:5,4", 1, true) ~= nil,
                "the click must reach the provider in window coordinates: [" .. tostring(seen.inputs) .. "]")

            -- Closing the window takes the provider away: it lives with the window.
            tell_desktop(service, "desktop.close", {id = id})

            -- The compositor must survive closing a view: a window without a process
            -- has nothing to put out except the provider, and "closed — died" would
            -- look on the stand like a random desktop crash.
            local emptied: any = nil
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                emptied = ask_fresh(service, "desktop.list", {})
                if #(emptied.windows or {}) == 0 then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.eq(#(emptied.windows or {}), 0, "the view should have closed, and the compositor should have survived")

            local gone = false
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                if not process.registry.lookup(provider) then gone = true break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(gone, "the provider must leave together with its window")

            process.terminate(tostring(desk.pid))
        end)

        test.it("a provider's death returns the view to waiting instead of leaving yesterday's state", function()
            -- A view frozen at its last state looks alive and lies the more
            -- convincingly the longer it hangs.
            local service = "windows.tui_desktop.test.view.orphan"
            local provider = "windows.tui_desktop.test.provider"
            local desk = boot_composer(service)

            tell_desktop(service, "desktop.open", {entry = "app:view_window"})
            local alive: any = nil
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                alive = process.registry.lookup(provider)
                if alive then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.not_nil(alive, "the provider must come up")

            process.send(provider, "probe.push", {})
            local ready: any = nil
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                ready = ask_fresh(service, "desktop.list", {})
                if ready.windows[1] ~= nil and ready.windows[1].waiting == false then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(ready.windows[1].waiting == false, "the state arrived")

            -- Put out the provider, keep the window.
            process.terminate(tostring(alive))
            local orphan: any = nil
            deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                orphan = ask_fresh(service, "desktop.list", {})
                if orphan.windows[1] ~= nil and orphan.windows[1].waiting == true then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_true(orphan.windows[1].waiting == true,
                "without a provider the view must return to waiting")
            test.is_true(tostring(orphan.notice):find("provider", 1, true) ~= nil,
                "and tell the person about it: [" .. tostring(orphan.notice) .. "]")

            process.terminate(tostring(desk.pid))
        end)

        test.it("a view survives a resize: it has no viewport", function()
            -- A window with a process changes size together with its viewport, a view
            -- has no viewport at all — and a path that does not know this crashes the
            -- compositor on the very first resize command.
            local service = "windows.tui_desktop.test.view.resize"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            local opened = ask_desktop(service, box, "desktop.open",
                {entry = "app:view_static", w = 30, h = 8})
            test.is_true(opened.ok == true, "the view did not open: " .. tostring(opened.error))

            local resized = ask_desktop(service, box, "desktop.resize",
                {id = tostring(opened.window.id), w = 44, h = 12})
            test.is_true(resized.ok == true, "a view's resize must work: " .. tostring(resized.error))
            test.eq(math.tointeger(resized.window.width) or 0, 44)
            test.eq(math.tointeger(resized.window.height) or 0, 12)

            -- And the compositor is alive: the next command answers.
            local after = ask_desktop(service, box, "desktop.list", {})
            test.eq(#after.windows, 1, "the compositor must survive a view's resize")

            process.terminate(tostring(desk.pid))
        end)

        test.it("a view with nothing to draw it with does not open and says why", function()
            -- A dead render reference stays silent until the first open, and then
            -- looks like an empty window — that is, the theme will be blamed.
            local service = "windows.tui_desktop.test.view.broken"
            local box = mailbox(process.inbox())
            local desk = boot_composer(service)

            local nameless = ask_desktop(service, box, "desktop.open",
                {entry = "app:view_without_render"})
            test.is_true(nameless.ok == false, "a view without render must not open")
            test.is_true(tostring(nameless.error):find("render", 1, true) ~= nil,
                "the refusal must name what was missing: " .. tostring(nameless.error))

            local dead = ask_desktop(service, box, "desktop.open",
                {entry = "app:view_with_dead_render"})
            test.is_true(dead.ok == false, "a view with a dead reference must not open")
            test.is_true(tostring(dead.error):find("app:nowhere", 1, true) ~= nil,
                "the refusal must name the reference itself: " .. tostring(dead.error))

            -- A view without a provider is a legitimate showcase: there is something
            -- to draw with, nothing to obtain, and nothing for it to wait for.
            local static = ask_desktop(service, box, "desktop.open", {entry = "app:view_static"})
            test.is_true(static.ok == true, "a view without a provider: " .. tostring(static.error))
            test.eq(static.window.content, "pixels")
            test.is_true(static.window.waiting == false, "nothing to wait for — there is no provider")

            -- And the control: an ordinary window next to it opens as it used to.
            local fine = ask_desktop(service, box, "desktop.open", {entry = "app:idle_window"})
            test.is_true(fine.ok == true, "the refusal must not touch ordinary windows")
            test.eq(fine.window.content, "cells", "the default is cells")

            process.terminate(tostring(desk.pid))
        end)
    end)

    test.describe("windows.tui_desktop window type and menu", function()
        test.it("hides an entry with in_menu: false from the menu, without ceasing to open it", function()
            -- The flag is about the menu, not about launching: a file viewer or a
            -- properties dialog opens from another window and from the desktop.
            local hidden = {id = "app:props", meta = {title = "Properties", in_menu = false}}
            local items = programs.menu({hidden, {id = "app:calc", meta = {title = "Calculator"}}})
            test.eq(#items, 1)
            test.eq(items[1].entry, "app:calc")

            local item = programs.item(hidden)
            test.not_nil(item, "a hidden entry remains a program")
            test.eq(item.entry, "app:props")
            test.is_false(item.in_menu)
        end)

        test.it("counts the string \"false\" as a refusal on a par with the boolean", function()
            -- An entry arrives both from YAML and from JSON. "A string is truth"
            -- would show in the menu exactly the windows that asked to be hidden.
            local items = programs.menu({{id = "app:props", meta = {title = "C", in_menu = "false"}}})
            test.eq(#items, 0)
        end)

        test.it("counts an unknown type as an ordinary window and does not hide the program", function()
            -- The type is declared by someone else; a typo in one field is no reason
            -- not to show a program that is otherwise sound. But staying silent about
            -- it is not allowed either, so it goes out as a warning.
            local records = {
                {id = "app:weird", meta = {title = "Weird", window_type = "widget"}},
                {id = "app:about", meta = {title = "About", window_type = "dialog"}},
            }
            local items, warnings = programs.menu(records)
            test.eq(#items, 2, "an unknown type is no reason to hide the program")
            local by_entry = {}
            for _, item in ipairs(items) do by_entry[item.entry] = item.window_type end
            test.eq(by_entry["app:weird"], "app")
            test.eq(by_entry["app:about"], "dialog")
            test.eq(#warnings, 1)
            test.eq(warnings[1].entry, "app:weird")
            test.eq(warnings[1].window_type, "widget")
        end)

        test.it("returns a dialog as a dialog, and the default as an ordinary window", function()
            local dialog = programs.item({id = "app:about", meta = {window_type = "dialog"}})
            test.eq(dialog.window_type, "dialog")
            test.is_true(dialog.in_menu, "a dialog belongs in the menu: About is a dialog")

            local plain = programs.item({id = "app:calc", meta = {title = "Calculator"}})
            test.eq(plain.window_type, programs.DEFAULT_TYPE)
            test.eq(plain.title, "Calculator")
        end)
    end)
    test.describe("taskbar launch and shell exit", function()
        test.it("raises one clock window and closes its provider through the Start menu", function()
            local service = "windows.tui_desktop.test.actions"
            local provider = "windows.tui_desktop.test.provider"
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
                local service = "windows.tui_desktop.test.quit." .. method
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
