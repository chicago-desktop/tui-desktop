-- What a window can ask of the desktop.
--
-- A window draws itself and receives input, but does not command its
-- neighbours: to open, close or raise a window, it asks the compositor — the
-- same path the command channel takes from outside. The window has no access
-- of its own to processes and programs.
--
-- The library exists so that each widget does not rewrite the message
-- protocol anew: were these implementations to diverge, half of the windows
-- would one day start sending commands the compositor no longer understands.

local process = require("process")
local channel = require("channel")
local time = require("time")

-- The log here is not a luxury: `open` does not wait for a reply on purpose,
-- and a window that did not check the second return value would otherwise not
-- report a refusal at all. The terminal host routes the log into events, so
-- it does not scramble the frame.
local logger = require("logger")
local log = logger:named("tui_desktop.window")

-- The compositor's name arrives in the process context: the compositor puts it
-- there when it starts the window. One key for both sides — the compositor's
-- mechanics take it from here too, so that the key's name cannot silently
-- diverge.
local CONTEXT_KEY = "tui_desktop.service"

-- The fallback name is the standard shell. A window started by an old
-- compositor or by someone else's launch behaves as before instead of crashing.
local DEFAULT_SERVICE = "chicago.tui_desktop.desktop"

-- The module is declared by THIS library, not by the window's entry: a library
-- gets its own modules, so a window written before the name appeared in the
-- context works without a single edit. `require` of an unavailable module
-- throws, and a window must not die on its first line because of diagnostics —
-- hence pcall.
local has_ctx, ctx = pcall(require, "ctx")

local input = require("input")
local api = {}
api.normalize_event = input.normalize

api.CONTEXT_KEY = CONTEXT_KEY
api.DEFAULT_SERVICE = DEFAULT_SERVICE

-- Several desktops can run in one runtime: a terminal.ssh host gives every
-- connection its own. They answer to `name`, `name.2` … `name.<slots>`; a
-- compositor claims the first free one, and the registry releases a name
-- with its process, so a number is reused. The registry has no listing, so
-- whoever looks for every desktop asks each name — by this one rule.
api.DESKTOP_SLOTS = 16

-- desktop_names(family, slots?) -> {family, family.2, …}
function api.desktop_names(family: string, slots: any?): any
    local count = math.tointeger(tonumber(slots)) or api.DESKTOP_SLOTS
    local names: any = {family}
    for index = 2, count do names[#names + 1] = family .. "." .. tostring(index) end
    return names
end

-- desktop_family("x.shell.3") -> "x.shell": the family a claimed name belongs to.
function api.desktop_family(name: string): string
    local family = string.match(name, "^(.-)%.%d+$")
    return family or name
end

-- desktops(name) -> {{name, pid}, …}: the desktops of that name's family
-- running now, the unnumbered one first.
function api.desktops(name: string): any
    local found: any = {}
    for _, candidate in ipairs(api.desktop_names(api.desktop_family(name))) do
        local name = tostring(candidate)
        local pid = process.registry.lookup(name)
        if pid then found[#found + 1] = {name = name, pid = pid} end
    end
    return found
end

-- The topic the compositor replies on. One constant for both sides: the
-- mechanics take it from here too.
api.REPLY_TOPIC = "desktop.reply"

-- How long to wait for a reply. The wait must end: a window that waits forever
-- neither draws nor accepts input, and from outside that is "hung", not
-- "waiting".
api.BUDGET = "5s"

-- service() -> the compositor's name, where it was taken from ("context" | "default")
--
-- A window has no need to know this — it calls open/close/focus. It is exposed
-- for tests and diagnostics: "whom does this window address" cannot be asked
-- otherwise.
function api.service()
    if has_ctx and type(ctx) == "table" then
        local name = ctx.get(CONTEXT_KEY)
        if type(name) == "string" and name ~= "" then return name, "context" end
    end
    return DEFAULT_SERVICE, "default"
end

-- Why the compositor was not found. The refusal must name both the name and
-- where it came from: silence here was the original defect — under the second
-- shell the window addressed a nonexistent process, and `api.open` does not
-- wait for a reply, so the "success" looked indistinguishable from a real open.
local function unreachable(name, source, lerr)
    local reason = "desktop \"" .. name .. "\" does not answer (" .. tostring(lerr) .. ")"
    if source ~= "default" then return reason end
    if has_ctx then
        return reason .. "; the compositor's name did not arrive at start — the context has no key "
            .. CONTEXT_KEY .. ", so the fallback was taken"
    end
    return reason .. "; there is nothing to read the compositor's name with — the ctx module is unavailable, "
        .. "so the fallback was taken"
end

-- `service` — the compositor's name given by the caller. Needed by whoever has
-- no window context: an application service that puts an item into the tray
-- was not started by the compositor and got no key in its context.
local function call(topic, body, service: string?)
    local name, source = api.service()
    if type(service) == "string" and service ~= "" then name, source = service, "argument" end
    local pid, lerr = process.registry.lookup(name)
    if not pid then
        local reason = unreachable(name, source, lerr)
        log:error("the window did not find its desktop",
            {service = name, source = source, topic = topic, error = reason})
        return nil, reason
    end
    local sent, serr = process.send(pid, topic, body or {})
    if not sent then
        return nil, "the command did not reach \"" .. name .. "\": " .. tostring(serr)
    end
    return true, nil
end

-- The reply arrives wrapped: the payload is userdata, and inside there is
-- sometimes also a one-element array. A field read directly comes out nil
-- without an error.
local function unwrap(value)
    if type(value) == "userdata" then
        local ok, decoded = pcall(function() return value:data() end)
        if ok and type(decoded) == "table" then return decoded end
        return {}
    end
    if type(value) ~= "table" then return {} end
    if value[1] ~= nil and #value > 0 then return unwrap(value[1]) end
    return value
end

-- The reply channel. A separate subscription to the topic, NOT reading the
-- shared inbox, and this is the main decision here.
--
-- A loop that waits for a reply in the inbox takes everything from there and
-- throws away what is not its own — measured: a `desktop.close` command sent
-- to a window while it was waiting vanished without a trace, and from outside
-- it looked like a window that stopped obeying the mouse. The runtime itself
-- lost nothing: a message with no one to be delivered to waits in the
-- process's queue. So it is enough not to take it — the reply arrives on its
-- own channel, the foreign command stays in the inbox and waits for the
-- window's loop.
local replies: any = nil

local function reply_channel()
    if replies then return replies, nil end
    -- The subscription is created BEFORE the question is sent: created after,
    -- it would miss a quick reply in the inbox, where a foreign loop would eat it.
    local opened = process.listen(api.REPLY_TOPIC, {message = true})
    if not opened then return nil, "the window could not subscribe to the desktop's replies" end
    replies = opened
    return replies, nil
end

-- replies() -> the desktop's reply channel
--
-- For a window with its own loop this is better than `ask`: it puts the channel
-- into its `channel.select` beside the events and the inbox and keeps drawing
-- while it waits. `ask` is more convenient, but while waiting the window reads
-- neither input nor commands — they will wait for it (verified), but the frame
-- stands still meanwhile.
function api.replies()
    local opened, err = reply_channel()
    return opened, err
end

-- A reply left over from a previous question, or a refusal that arrived on its
-- own. It is dropped before a new question: nobody waits for it, and read as
-- fresh it would answer the previous question instead of the current one.
-- Dropping a reply is safe — unlike a command, for whose sake all this was done.
local function drop_stale(ch)
    local dropped = 0
    while true do
        local picked = channel.select({ch:case_receive()}, true)
        if picked.default or not picked.ok then break end
        dropped = dropped + 1
    end
    return dropped
end

-- request(topic, body) -> true | nil, reason
--
-- Ask a question and do not wait: the reply arrives in `api.replies()`. Exactly
-- what a window needs that draws itself and has no right to freeze.
function api.request(topic, body)
    local name, source = api.service()
    local pid, lerr = process.registry.lookup(name)
    if not pid then
        local reason = unreachable(name, source, lerr)
        log:error("the window did not find its desktop",
            {service = name, source = source, topic = topic, error = reason})
        return nil, reason
    end

    local ch, cerr = reply_channel()
    if not ch then return nil, tostring(cerr) end

    body = type(body) == "table" and body or {}
    body.reply_to = tostring(process.pid())

    local sent, serr = process.send(pid, topic, body)
    if not sent then
        return nil, "the question did not reach \"" .. name .. "\": " .. tostring(serr)
    end
    return true, nil
end

-- ask(topic, body, opts) -> reply | nil, reason
--
-- opts.timeout — how long to wait (api.BUDGET by default).
function api.ask(topic, body, opts)
    local options: any = type(opts) == "table" and opts or {}
    local budget = type(options.timeout) == "string" and options.timeout ~= ""
        and options.timeout or api.BUDGET

    local ch, cerr = reply_channel()
    if not ch then return nil, tostring(cerr) end

    local stale = drop_stale(ch)
    if stale > 0 then
        log:warn("dropped a reply nobody was waiting for",
            {topic = topic, dropped = stale})
    end

    local ok, rerr = api.request(topic, body)
    if not ok then return nil, rerr end

    local expiry = time.after(budget)
    while true do
        local picked = channel.select({ch:case_receive(), expiry:case_receive()})
        if picked.channel == expiry then
            local name = api.service()
            return nil, "desktop \"" .. name .. "\" did not answer within " .. budget
        end
        if not picked.ok then
            return nil, "the reply channel closed while waiting for the desktop"
        end

        local answer = unwrap(picked.value:payload())
        if answer.unsolicited then
            -- A refusal of a command whose reply nobody awaited: it arrived on
            -- its own and is not the reply to THIS question. Taking it for the
            -- reply would mean lying about another command — so it is only
            -- named in the log, and the wait goes on.
            log:warn("the desktop refused a command sent without waiting",
                {command = tostring(answer.command), error = tostring(answer.error)})
        elseif type(answer.command) == "string" and answer.command ~= topic then
            log:warn("a reply to a different question",
                {asked = tostring(topic), answered = tostring(answer.command)})
        elseif answer.ok == false then
            return nil, tostring(answer.error or "the desktop refused without a reason")
        else
            return answer, nil
        end
    end
end

-- list(opts) -> {windows, focused, screen, restore} | nil, reason
function api.list(opts)
    local answer, err = api.ask("desktop.list", {}, opts)
    return answer, err
end

-- open{entry=…, title=…, args=…, x=…, y=…, w=…, h=…}
--
-- We do not wait for a reply on purpose: the window draws itself, and waiting
-- for someone else's reply would freeze the frame. That the window opened is
-- visible on screen; that the compositor was not found is visible in the second
-- return value, and it is worth checking.
function api.open(spec)
    spec = type(spec) == "table" and spec or {}
    return call("desktop.open", spec)
end

-- open_wait(spec, opts) -> description of the opened window | nil, reason
--
-- The same as `open`, but with a reply: the description has `id`, and without
-- it a window can neither close what it opened nor raise it. The frame stands
-- still while waiting — so by default `open` stays what it was.
function api.open_wait(spec, opts)
    local answer, err = api.ask("desktop.open", type(spec) == "table" and spec or {}, opts)
    if not answer then return nil, err end
    return answer.window, nil
end

-- dialog(spec, opts) -> description of the dialog | nil, reason
--
-- A dialog belongs to the window that opened it: the compositor learns the
-- parent from the sender, centers the dialog on its window, keeps it above it
-- and closes it together with it. There is no modality on purpose: blocking
-- the input of the other windows where a window is someone else's process
-- means being able to hang the whole desktop.
function api.dialog(spec, opts)
    local body: any = type(spec) == "table" and spec or {}
    body.window_type = "dialog"
    local answer, err = api.ask("desktop.open", body, opts)
    if not answer then return nil, err end
    return answer.window, nil
end

-- A refusal of a command sent without waiting arrives here too, marked
-- `unsolicited`: a window that keeps the channel in its `select` learns that
-- `close` or `focus` did not happen, and does not freeze itself for it. To a
-- window that did not create the channel, the refusal comes as an ordinary
-- message in the inbox.
-- A close is a request the window may refuse; `opts.force = true` kills it
-- after the grace instead (the compositor's shutdown path). `opts.refused =
-- true` is the window's own answer to a request: it stays, and the request is
-- over without a notice. The compositor knows the window by the sending
-- process, so a cells window's runner, which has no window id, passes nil.
function api.close(id, opts: any?)
    local given: any = type(opts) == "table" and opts or {}
    return call("desktop.close", {id = id, force = given.force == true or nil,
        refused = given.refused == true or nil})
end

function api.focus(id)
    return call("desktop.focus", {id = id})
end

-- State providers use the same owner and command channel as TTY windows.
-- No reply is requested for frames: feeding replies back into drawing would loop.
function api.publish_state(id, state: any)
    -- `title` and `image` of the state travel beside it: the compositor's
    -- window record takes them for the title bar (a folder window that
    -- navigates in place changes both).
    local ok, err = call("desktop.state", {id = id, state = state,
        title = type(state) == "table" and state.title or nil,
        image = type(state) == "table" and state.image or nil})
    return ok, err
end

-- tray{key=…, text=…, entry=…, title=…, ttl=…} [, service]
-- tray{key=…, remove=true} [, service]
--
-- An item of the notification area by the taskbar clock. The key is chosen by
-- the provider: the same key updates the item. `entry` — the window a click on
-- the item opens (or raises if it is already open). `ttl` in seconds: an item
-- not updated within this time is removed by the compositor itself — a label
-- that outlived its provider would pass an old value off as the current one.
--
-- Does not wait for a reply, like `open`: a refusal (no key, tray full) arrives
-- on its own in `api.replies()` marked `unsolicited`, and without the channel —
-- in the inbox.
function api.tray(spec, service: string?)
    local ok, err = call("desktop.tray", type(spec) == "table" and spec or {}, service)
    return ok, err
end

function api.inputs()
    local opened = process.listen("window.input", {message = true})
    return opened
end

function api.input_event(message: any)
    local body = unwrap(message:payload())
    return input.normalize(body.event)
end

return api
