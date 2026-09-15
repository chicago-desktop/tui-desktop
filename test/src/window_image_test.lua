-- A view window's published state carries `image` beside `title` (FR-008 §3
-- of chicago/shell): a folder window that navigates in place changes its
-- title-bar picture. The provider publishes through the real
-- `window_api.publish_state`; `desktop.list` shows what the window record
-- took. An absent or empty image keeps the picture the window has.
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

-- The provider's own messages, read from this process's inbox by topic.
local function await(inbox: any, topic: string): any
    local expiry = time.after("8s")
    while true do
        local picked = channel.select({inbox:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then
            test.is_true(false, "the provider did not say " .. topic)
            return {}
        end
        if picked.value:topic() == topic then return body_of(picked.value) end
    end
end

-- The window as desktop.list shows it once the compositor took the state
-- with this revision: the publish carries no reply.
local function listed(desk: any, id: string, revision: integer): any
    local deadline = time.now():unix_nano() + 5000000000
    local found: any = {}
    while time.now():unix_nano() < deadline do
        local listing: any = ask(desk, "desktop.list", {})
        for _, window in ipairs(listing.windows or {}) do
            if tostring(window.id) == id then found = window end
        end
        if (math.tointeger(found.state_revision) or 0) >= revision then return found end
        pause("50ms")
    end
    test.is_true(false, "the state " .. revision .. " did not reach the window")
    return found
end

local function define_tests()
    test.describe("chicago.tui_desktop published title-bar picture", function()
        test.it("a published image replaces the title-bar picture; an absent or empty one keeps it", function()
            local desk = boot("chicago.tui_desktop.test.image")
            local inbox = process.inbox()
            local opened: any = ask(desk, "desktop.open",
                {entry = "app:image_view", args = desk.watcher, w = 30, h = 8, x = 2, y = 2})
            test.is_true(opened.ok == true, "the view window did not open: " .. tostring(opened.error))
            local id = tostring(opened.window.id)
            test.eq(opened.window.image, "drive", "the entry's picture to start with")
            local provider = tostring(await(inbox, "probe.ready").pid)

            process.send(provider, "probe.publish", {title = "docs", image = "folder_open"})
            test.is_true(await(inbox, "probe.published").ok == true)
            local window = listed(desk, id, 1)
            test.eq(window.image, "folder_open", "the published picture is the window's now")
            test.eq(window.title, "docs", "and the title beside it")

            process.send(provider, "probe.publish", {title = "letters"})
            await(inbox, "probe.published")
            window = listed(desk, id, 2)
            test.eq(window.title, "letters")
            test.eq(window.image, "folder_open", "a state without a picture keeps the one there is")

            process.send(provider, "probe.publish", {title = "letters", image = ""})
            await(inbox, "probe.published")
            window = listed(desk, id, 3)
            test.eq(window.image, "folder_open", "an empty name keeps it too")

            process.registry.unregister(desk.watcher)
            process.terminate(tostring(desk.pid))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
