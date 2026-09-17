-- Compositor: the mechanics of a windowed desktop, called as a library.
--
-- There is no look here. Everything that is drawn comes from the theme in
-- options.chrome, and the chrome's geometry — how many rows are taken at the
-- top and at the bottom — is declared by the theme too. So a second shell
-- brings its own theme and gets a different look without copying the window
-- hosting, the PTY or the command channel.
--
-- It keeps the list of windows in z-order, lays their frames on a shared
-- canvas, dispatches input and takes commands from outside. The windows do
-- not know about it: each writes to its own viewport through the ordinary
-- `tty` and believes it owns the whole terminal.
--
-- Three rules whose violation gives a silent breakage:
--   * no yield call ends a function with a bare `return` — in go-lua
--     v1.5.18 such a tail call is not executed at all;
--   * `snapshot().rows` is the broker's shared immutable array; it must not
--     be edited in place;
--   * `viewport:send` before the window's `tty.start()` is an error, not a
--     loss, so input is held back until the first frame.

local channel = require("channel")
local process = require("process")
local registry = require("registry")
local time = require("time")
local tty = require("tty")

local logger = require("logger")

local repo = require("repo")
local apps = require("apps")

-- What a registry entry says about its program: the window type and the
-- "show in the menu" flag. A separate library because both the menu and the
-- open read it, and a default computed in two places will one day diverge.
local programs = require("programs")

-- Assembly of the pixel frame: blanks under the pictures, parsing of
-- placements and hits. A separate library because it is arithmetic — it is
-- tested without a terminal and without graphics.
local pixels = require("pixels")

-- The "window asks the desktop" protocol. From it the mechanics take the key
-- under which the compositor's name is put into the window's context: were
-- the key to differ between sender and receiver, the window would silently
-- address the default name.
local window_api = require("window_api")

-- claim_desktop_name(family, slots) -> name | nil, reason
--
-- Registers the first free name of the family (window_api.desktop_names). A
-- name is released with its process, so the number of a desktop that ended
-- goes to the next one.
local function claim_desktop_name(family: string, slots: any): (any, any)
    local first_error: any = nil
    local names: any = window_api.desktop_names(family, slots)
    for _, name in ipairs(names) do
        local ok, err = process.registry.register(tostring(name))
        if ok then return tostring(name), nil end
        first_error = first_error or err
    end
    return nil, "no desktop name of " .. family .. " is free (" .. tostring(#names)
        .. " tried): " .. tostring(first_error)
end

local WINDOW_HOST = "chicago.tui_desktop:workers"

-- A window is any process entry that can write to its tty port. The module
-- knows exactly one of its own (a program under a PTY); everything else is
-- brought by the application and named by an entry — otherwise every new
-- window would need a change to this module.
local PTY_WINDOW = "chicago.tui_desktop.desktop:window_pty"

-- The application's window catalog: the compositor finds entries marked with
-- this meta.type itself and shows them in the menu on alt+o.
local WINDOW_META_TYPE = programs.WINDOW_META_TYPE

-- The reply topic is taken from the window protocol rather than repeated as
-- a string: the window's subscription rests on it, and were they to differ,
-- the reply would land in the window's inbox, where another loop would eat
-- it.
local REPLY_TOPIC = window_api.REPLY_TOPIC

-- Commands addressed to a specific window. The list is needed to tell "no
-- such window" from "no such command": while only the order of the checks
-- told them apart, ANY unknown command answered "no window nil" — so the
-- sender went looking for a typo in an id it never sent, and the branch for
-- an unknown command was unreachable altogether.
local WINDOW_COMMANDS = {
    ["desktop.close"] = true,
    ["desktop.focus"] = true,
    ["desktop.move"] = true,
    ["desktop.resize"] = true,
    ["desktop.minimize"] = true,
    ["desktop.screen"] = true,
    ["desktop.type"] = true,
    ["desktop.key"] = true,
    -- The state of a view window, sent by its state provider. Also addressed to
    -- a window, so it lives here too: otherwise "no such window" and "no such
    -- command" would again split into different branches.
    ["desktop.state"] = true,
}

local DEFAULT_COMMAND = "/bin/bash -i"
local CLOSE_GRACE = "3s"


-- The taskbar clock must keep going even when nobody presses anything.
-- Without this tick the frame is updated only on an event, and the time on
-- the screen stops — a "the shell has hung" look with a working shell.
local CLOCK_TICK = "15s"
-- How many recent frames the timing meter remembers (`frame.window` in the
-- status). Two hundred is a few seconds under a stream of output and minutes
-- at rest: enough for p95, not enough for an old spike to hang in the summary
-- forever.
local FRAME_WINDOW = 200
-- The shortest gap between two frames, in milliseconds. A frame per mouse
-- motion and per pty chunk backed the loop up until nothing — the clock
-- included — was drawn (the owner's freeze, 2026-09-14: 2.4 cores and 1.8 MB/s
-- to the terminal during a resize). Requests inside the gap are one frame.
local FRAME_MS = 33

-- The delay with which hovering in the menu opens a folder or closes a
-- submenu. As in Windows: without it the mouse, going diagonally from a
-- folder to its submenu, passes over the neighbouring row and closes what it
-- is heading for. Highlighting the row itself does not wait for the delay.
local HOVER_DELAY = "300ms"

-- The notification area (tray). An item is a short caption by the clock, put
-- there by an application process (weather, mail, a service's state). The
-- limits are not decoration: an item wider than the clock eats the window
-- buttons, and a seventh item almost always means that the provider puts a
-- new key on every update instead of updating its own.
local TRAY_MAX = 6
local TRAY_TEXT = 16
local TRAY_KEY = 64

-- Balloon tips by the notification area (`desktop.balloon`). One is shown at
-- a time and the others wait their turn. The limit counts every balloon the
-- desktop holds, the shown one included: a ninth almost always means a
-- provider that posts a new key on every event instead of replacing its own,
-- and a queue of those would show stale news for minutes. The theme wraps and
-- ellipsizes the text; the lengths here only keep a runaway caller off the
-- frame.
local BALLOON_MAX = 8
local BALLOON_TIMEOUT, BALLOON_LEAST, BALLOON_MOST = 10, 2, 60
local BALLOON_TITLE, BALLOON_TEXT = 64, 512
local BALLOON_ICONS: {[string]: boolean} = {info = true, warning = true, error = true}

-- A flashing window (`desktop.flash`): its lit and plain looks swap every
-- FLASH_STEP_MS until it takes the focus, or for the cycles a count allows.
local FLASH_STEP_MS = 500

-- The notice line, opened to modules (`desktop.notice`): shown for a ttl in
-- seconds, then cleared unless a later notice replaced it.
local NOTICE_TTL, NOTICE_LEAST, NOTICE_MOST = 5, 1, 60
local NOTICE_TEXT = 256

-- Desktop widgets (FR-006 in chicago/shell): registry entries whose
-- process the compositor spawns like the state provider of a view window,
-- and whose published tree the theme draws in a panel under every window.
-- The base spawns, stops and hands the list to the theme; it draws nothing.
-- A size outside the limits is refused, not clamped: a tree laid out for
-- another size would be another widget.
local WIDGET_W, WIDGET_H = 20, 5
local WIDGET_MIN_W, WIDGET_MAX_W = 10, 40
local WIDGET_MIN_H, WIDGET_MAX_H = 2, 16
local WIDGET_ORDER = 100

-- Printable text an agent sends to a window is sent one key at a time: a
-- window has no "paste", and `paste` reaches the program only if it has
-- turned on bracketed paste.
local function runes(text)
    local out = {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = char
    end
    return out
end

-- A process message arrives wrapped: the payload is userdata, and inside
-- there may also be an array of one element. Reading a field directly gives
-- nil without any error.
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

-- clamp takes anything and always returns an integer: values come both from
-- the mouse and from a command's JSON, where anything may turn up as a
-- number.
local function clamp(value, low, high)
    local lo = math.floor(low)
    local hi = math.floor(high)
    if lo > hi then lo = hi end
    local number = tonumber(value)
    if not number then return lo end
    number = math.floor(number)
    if number < lo then return lo end
    if number > hi then return hi end
    return number
end

-- seconds(value, default, low, high) -> seconds within the bounds | nil
--
-- A duration a command names: absent is the default, a number is clamped,
-- anything else (a string, NaN) is nil — the caller refuses it by name.
local function seconds(value: any, default: number, low: number, high: number): number?
    if value == nil then return default end
    if type(value) ~= "number" or value ~= value then return nil end
    if value < low then return low end
    if value > high then return high end
    return value
end

-- after_seconds(value) -> a timer channel that fires once after `value` seconds.
local function after_seconds(value: number): any
    local ms = math.tointeger(math.floor(value * 1000)) or 1000
    return time.after(tostring(ms) .. "ms")
end

-- without(list, index) -> a new list without its `index`-th item, and that
-- item. `table.remove` wants a typed array, and the state tables here are
-- `any` (the logon pcall trap keeps them in tables).
local function without(list: any, index: integer): (any, any)
    local kept: any = {}
    local taken: any = nil
    for position, item in ipairs(list) do
        if position == index then taken = item else kept[#kept + 1] = item end
    end
    return kept, taken
end

-- run(options) — bring the compositor up on the current terminal.
--
-- options.chrome        — the theme (contract in the README). Required.
-- options.service_name  — the name under which processes see the compositor.
--   options.service_slots — how many desktops of that name may run at once
--                           (default window_api.DESKTOP_SLOTS); each claims
--                           the first free of name, name.2, …
-- options.hint          — the hint on an empty desktop. options.logon
-- — (screen) -> identity | nil, reason. Logon before the first frame:
-- identity = {actor, scope, context}, and every window is spawned under it.
-- Details in README.
--   options.widgets       — () -> {{instance, entry, title, w, h, order, opens, config}, …}, failure:
--                           desktop widgets to spawn (README, "Desktop widgets").
local function run(options: any)
    options = type(options) == "table" and options or {}

    -- The theme is required and is not substituted silently: a compositor
    -- without a look is an empty screen with nothing to look for in it. Let the
    -- refusal name the reason.
    local chrome: any = options.chrome
    if type(chrome) ~= "table" then
        return nil, "the compositor was given no theme (options.chrome)"
    end

    -- Pixel chrome: frames, titles, icons and the taskbar arrive as rasters,
    -- window content stays characters. It is turned on EXPLICITLY — by the
    -- same decision that picks the theme: a terminal capable of graphics is
    -- no reason to draw differently from what the person asked for.
    --
    -- The cell size is asked by the SHELL and passed here as a function. That
    -- is not a matter of taste: the `gfx` module is not in every runtime, and
    -- an entry that declared an unavailable module fails the whole boot
    -- ("node with ID {gfx :gfx} not found") — measured. Mechanics that
    -- declared `gfx` would become unusable wherever there is no graphics,
    -- including for those who do not need pixels. The decision still stays
    -- here: without a cell size the mode does NOT turn on and names the
    -- reason — a picture of the wrong size looks like a drawing error, not
    -- like an unasked question.
    local PIXELS = options.pixels == true
    local cell_w, cell_h = 0, 0
    if PIXELS then
        if type(chrome.paint) ~= "function" then
            return nil, "pixel mode does not start: the theme has no chrome.paint"
        end
        if type(options.cell_size) ~= "function" then
            return nil, "pixel mode does not start: the shell gave nothing to learn "
                .. "the cell size with (options.cell_size — usually gfx.cell_size)"
        end
    end
    local function refresh_cell_size()
        if not PIXELS then return true end
        local w, h = options.cell_size()
        if type(w) ~= "number" or type(h) ~= "number" then
            -- gfx.cell_size() answers (nil, reason): the second value here is
            -- exactly that reason.
            return nil, "pixel mode does not start: " .. tostring(h)
        end
        local next_w = math.tointeger(math.floor(w)) or 0
        local next_h = math.tointeger(math.floor(h)) or 0
        if next_w < 1 or next_h < 1 then
            return nil, "pixel mode does not start: a cell size of "
                .. tostring(w) .. "x" .. tostring(h) .. " is impossible"
        end
        cell_w, cell_h = next_w, next_h
        return true
    end
    local sized, size_error = refresh_cell_size()
    if not sized then return nil, size_error end

    -- The name this desktop answers to: the first free one of the family.
    -- Several run in one runtime when a terminal.ssh host gives every
    -- connection its own desktop.
    local SERVICE_FAMILY = type(options.service_name) == "string"
        and options.service_name ~= "" and options.service_name
        or "chicago.tui_desktop.desktop"
    local claimed, claim_error = claim_desktop_name(SERVICE_FAMILY, options.service_slots)
    if not claimed then return nil, claim_error end
    local SERVICE_NAME: string = tostring(claimed)

    local HINT = type(options.hint) == "string" and options.hint
        or "alt+n — bash window · alt+o — programs · ctrl+q — quit"

    -- Logon. The shell hands over a function that draws a dialog on this same
    -- terminal and returns an identity: {actor, scope, context = {...}}. The
    -- compositor spawns EVERY window under this identity — and that is the
    -- whole mechanism of the "current user": the compositor itself stays
    -- under its own actor, and a window's identity is fixed at the moment of
    -- the spawn. Switching the user means closing the windows and logging on
    -- again.
    local logon: any = type(options.logon) == "function" and options.logon or nil
    local IDENTITY: any = nil

    -- Spawning a window under the logged-on user. One function for both kinds
    -- of windows: the state provider and the process with a viewport get the
    -- same actor, otherwise a view window and a program window would live
    -- under different people, and the difference would surface at the very
    -- first "my agents".
    local function spawner(base: any, context: any): any
        if IDENTITY then
            for key, value in pairs(IDENTITY.context or {}) do
                if context[key] == nil then context[key] = value end
            end
        end
        local chain: any = base and base:with_context(context) or process.with_context(context)
        if IDENTITY then chain = chain:with_actor(IDENTITY.actor):with_scope(IDENTITY.scope) end
        return chain
    end

    -- The program catalog. The built-in one gives a flat list: the window
    -- mechanics have no business knowing about menu folders and icons. A shell
    -- that needs them brings its own — and answers for the shape itself.
    local read_catalog: any = type(options.catalog) == "function" and options.catalog or nil

    -- The desktop layout — shortcuts and folders. The mechanics neither store
    -- nor create them: this is the shell's state, moved by the user. The
    -- mechanics only show what they were given and say where the click went.
    local read_desktop: any = type(options.desktop_items) == "function" and options.desktop_items or nil
    -- The properties window of the desktop itself — the "Properties" item on a
    -- right click on an empty spot. An entry id; none — no menu either.
    local desktop_properties: any = type(options.desktop_properties) == "string" and options.desktop_properties or nil
    -- Desktop widgets (FR-006): `() -> {{instance, entry, title, w, h, order, opens, config}, …}, failure`.
    -- The shell reads the registry and hands the list over, as it does for
    -- desktop items; the base spawns the entries and draws nothing.
    local read_widgets: any = type(options.widgets) == "function" and options.widgets or nil

    -- Restoring the workshop windows needs the permission to change the
    -- registry. A shell under a different actor may not have it, and then it
    -- matters that the refusal is named rather than swallowed: it goes into
    -- restore_report.
    local RESTORE = options.restore ~= false

    -- The frame thickness. The compositor used to take it as one on every side
    -- — that is, it knew about the look. A theme with the title bar INSIDE the
    -- frame takes three rows at the top, and a window computed with one would
    -- give the program one row more than is visible.
    local insets: any = {}
    local FRAME_W, FRAME_H, MIN_W, MIN_H = 2, 2, 12, 5
    local function refresh_frame()
        insets = {top = 1, bottom = 1, left = 1, right = 1}
        if type(chrome.window_insets) == "function" then
            local given: any = chrome.window_insets()
            if type(given) == "table" then
                for _, side in ipairs({"top", "bottom", "left", "right"}) do
                    local value = math.tointeger(tonumber(given[side]) or 1) or 1
                    insets[side] = math.max(0, value)
                end
            end
        end
        FRAME_W = (math.tointeger(insets.left) or 1) + (math.tointeger(insets.right) or 1)
        FRAME_H = (math.tointeger(insets.top) or 1) + (math.tointeger(insets.bottom) or 1)
        MIN_W = math.max(12, FRAME_W + 4)
        MIN_H = math.max(5, FRAME_H + 3)
    end
    refresh_frame()

    -- Record a new place for an icon. The shell keeps the layout, so the
    -- compositor does not write it itself but asks — and rolls the icon back if
    -- the write failed. A refusal after which the icon stayed in its new place
    -- would lie: until the restart it is there, after it — not.
    local move_item: any = type(options.move_desktop_item) == "function"
        and options.move_desktop_item or nil

    local events = assert(tty.events())
    assert(tty.start())
    assert(tty.mouse(true))

    local lifecycle = assert(process.events())
    local inbox = process.inbox()

    -- Windows built in the runtime are returned to the registry here rather
    -- than by a background service: the platform deliberately forbids
    -- processes in the group `wippy.security:process` to change the registry,
    -- and such a service would silently do nothing. The compositor runs under
    -- its own actor with its own permissions — and these windows are needed
    -- exactly when the desktop is running.
    local log = logger:named("tui_desktop.desktop")

    -- The outcome of the restore is kept in state and given out through the
    -- command channel: the terminal host's log is muted (otherwise it would
    -- break the frame apart), and a refusal told only to the log is told to
    -- nobody.
    local restore_report: any = {restored = 0, failed = 0, error = nil, names = {}}

    local stored: any = nil
    local store_err: any = nil
    if RESTORE then stored, store_err = repo.list() end

    if not RESTORE then
        restore_report.skipped = true
    elseif store_err then
        restore_report.error = tostring(store_err)
        log:error("window storage unavailable", {error = tostring(store_err)})
    else
        local restored, failed = 0, {}
        for _, window in ipairs(stored or {}) do
            local ok, aerr = apps.apply(window)
            if ok then
                restored = restored + 1
            else
                failed[#failed + 1] = window.name .. ": " .. tostring(aerr)
                log:error("window did not come up", {window = window.name, error = tostring(aerr)})
            end
        end
        restore_report.restored = restored
        restore_report.failed = #failed
        restore_report.names = failed
        if restored > 0 or #failed > 0 then
            log:info("windows restored",
                {restored = restored, failed = #failed, names = table.concat(failed, ", ")})
        end
    end

    local out = assert(tty.surface({
        alternate_screen = true,
        hide_cursor = true,
        synchronized_output = true,
    }))

    -- There may be no size at all: a start not from a terminal (a script, CI, a
    -- pipe) answers with zeros, and the canvas rejects such a width — the
    -- process crashed on the very first line with "canvas width must be
    -- positive".
    local FALLBACK_W, FALLBACK_H = 80, 24
    local MIN_SCREEN_W, MIN_SCREEN_H = 8, 6

    local function screen_geometry()
        local w, h = tty.screen_size()
        w = math.floor(tonumber(w) or 0)
        h = math.floor(tonumber(h) or 0)
        if w < MIN_SCREEN_W then w = FALLBACK_W end
        if h < MIN_SCREEN_H then h = FALLBACK_H end
        return w, h
    end

    local width, height = screen_geometry()
    local canvas = tty.canvas(width, height)

    -- Logon comes before the first desktop frame and before the compositor
    -- starts reading commands: a window opened through the channel at that
    -- moment would be born without an identity. The shell draws the dialog on
    -- this same canvas; the compositor keeps the screen size and presents the
    -- frame — the same thing it does for the desktop.
    if logon then
        local screen: any = {
            events = events, pixels = PIXELS,
            width = width, height = height, canvas = canvas,
        }
        function screen.cell() return cell_w, cell_h end
        function screen.resize()
            width, height = screen_geometry()
            canvas = tty.canvas(width, height)
            screen.width, screen.height, screen.canvas = width, height, canvas
            return width, height
        end
        function screen.present(painted: any)
            local images: any = nil
            if PIXELS and type(painted) == "table" then
                images = pixels.frame(canvas, painted)
            end
            return out:present(canvas:rows(), {images = images})
        end
        -- A crashed dialog is a logon refusal with a reason, not a compositor
        -- that left the terminal in the alternate screen without a single
        -- word.
        local ok, identity, why = pcall(logon, screen)
        if not ok then identity, why = nil, "the logon dialog crashed: " .. tostring(identity) end
        if type(identity) ~= "table" or identity.actor == nil or identity.scope == nil then
            -- A logon refusal means exit, not a desktop under the service
            -- actor: a desktop without a user would look logged on, and the
            -- windows in it would act on behalf of the process.
            process.registry.unregister(SERVICE_NAME)
            assert(tty.mouse(false))
            assert(out:close())
            assert(tty.stop())
            return nil, type(why) == "string" and why or "logon failed"
        end
        IDENTITY = {actor = identity.actor, scope = identity.scope,
            context = type(identity.context) == "table" and identity.context or {}}
    end

    -- The first and last rows free for windows. Computed from the theme, not
    -- from a constant: one has a window bar at the top, another a taskbar at
    -- the bottom. math.floor rather than a literal: the linter tells integer
    -- from number, and further on these bounds go into clamp, which expects
    -- number.
    local desktop_top = math.floor(2)
    local desktop_last = math.floor(height - 1)

    local function apply_layout()
        local spec: any = chrome.layout(width, height)
        if type(spec) ~= "table" then spec = {} end
        local top = math.tointeger(tonumber(spec.top) or 1) or 1
        local bottom = math.tointeger(tonumber(spec.bottom) or 1) or 1
        if top < 0 then top = 0 end
        if bottom < 0 then bottom = 0 end
        -- A theme that asked for more screen than there is must not bring the
        -- compositor down: the windows would slide off the edge silently.
        if top + bottom >= height then
            top = 0
            if bottom >= height then bottom = math.tointeger(height - 1) or 0 end
            if bottom < 0 then bottom = 0 end
        end
        desktop_top = top + 1
        desktop_last = height - bottom
        if desktop_last < desktop_top then desktop_last = desktop_top end
    end

    apply_layout()

    -- windows — the z-order: the last one is drawn on top and holds the focus.
    local windows = {}
    local next_id = 0
    -- Dragging: one structure instead of "either nil or a table" — in the
    -- second form the offset fields do not exist for the checker.
    local drag: any = {active = false, id = "", mode = "move", dx = 0, dy = 0}
    -- The frame gate (`draw` / `draw_now` / `flush`): when the last frame was
    -- painted, whether one is owed, how many requests it merges, and the
    -- timer that paints it. A table, not locals: the loop and the closures
    -- share it (the go-lua pcall trap).
    local frame_gate: any = {last_ms = 0, dirty = false, merged = 0, timer = nil}
    -- Set when a frame could not be written: the terminal is gone (a remote
    -- session disconnected). The loop then shuts the desktop down.
    local terminal_state: any = {lost = nil, cancelled = false}
    -- While the menu is open all input belongs to it, digits included:
    -- otherwise choosing an item would go to the window under the menu.
    local menu: any = nil
    -- The hit layout the theme returned at the last paint. Both drawing and a
    -- click are computed from it alone.
    local catalog: any
    local bar_hits: any = {}
    local desk_hits: any = {}
    -- Desktop shortcuts are kept in state rather than read every frame: a frame
    -- is drawn dozens of times a second, while the layout is changed by hand.
    local desk: any = {items = {}, failure = nil}
    -- Double click: as in the shell the look is taken from. A single click that
    -- launches a program is a trap: people click an icon to select it.
    local last_click: any = {x = 0, y = 0, at = 0}
    local pointer: any = {x = nil, y = nil}
    -- The selection lives here, not in the layout: every click changes it, and
    -- the layout is what survives a restart.
    local selected_id: any = nil
    -- The reason of the last refusal. Shown instead of the status: the terminal
    -- shell has neither a log nor pop-up windows, and there is nowhere else to
    -- tell it.
    local notice = ""
    -- What the last frame cost. Given out through the command channel,
    -- because the cost of slicing the chrome cannot be seen otherwise:
    -- wrongly sliced chrome draws a CORRECT screen, just a slow one, and a
    -- slow one has neither a stack nor a symptom — over ssh it cannot be
    -- found by eye.
    local frame_cost: any = {}
    -- What the frame cost in TIME and what woke it. The bytes and rows above
    -- say how much went to the terminal, but not where the time went: in the
    -- theme rebuilding the canvas or in `present`. `trigger` is written by
    -- the loop and read by `draw`; `samples` is a ring of the last
    -- FRAME_WINDOW frames for avg/p95/max. A table rather than locals: higher
    -- up in this frame sits the logon pcall, and after an error under pcall a
    -- plain local diverges between the loop and a closure.
    local meter: any = {trigger = "start", snapshot_ms = nil, total = 0, next = 1, samples = {}}
    -- Which window was last told it has the keyboard. The composer keeps no
    -- focus field (focus is the top visible window, see `focused`), so a
    -- change is noticed by comparing after each frame. A table, like `meter`:
    -- the logon pcall sits above in this frame. `notify_focus` is assigned
    -- below `send_to`, which it needs; `draw` calls it through this name.
    local focus_seen: any = {id = nil}
    local notify_focus: any = nil
    local menu_hits: any = {}
    -- The menu hover timer: exists only while the cascade is waiting for its
    -- change, see `hover_menu`. Declared here because the loop puts it into
    -- select.
    local hover_timer: any = nil
    local clock = ""
    -- Tray items in the order they appeared. A table rather than a local list:
    -- see `meter` — after an error under pcall the owner no longer sees an
    -- assignment made to a local from a closure.
    local tray: any = {items = {}}

    -- What the tray gives the theme and the command channel. The theme gets
    -- only what it draws and what it turns a hit into; outside also gets the
    -- owner and the time left, without which "the item is stuck" cannot be
    -- explained.
    local function tray_view(detailed: boolean): any
        local out = {}
        local now = time.now():unix_nano()
        for _, item in ipairs(tray.items) do
            local view: any = {key = item.key, text = item.text, entry = item.entry, title = item.title,
                image = item.image, icon = item.icon}
            if detailed then
                view.owner = item.owner
                if item.expires ~= nil then
                    local left: integer = math.tointeger((tonumber(item.expires) or now) - now) or 0
                    view.expires_in = math.max(0, left // 1000000000)
                end
            end
            out[#out + 1] = view
        end
        return out
    end

    -- An expired item is removed. A provider that stopped updating its item has
    -- most likely stopped, and a caption that outlived it passes an old value
    -- off as the current one — the look of a working tray that lies.
    -- Answers whether the tray changed: only then is a redraw needed.
    local function prune_tray(): boolean
        local now = time.now():unix_nano()
        local kept, changed = {}, false
        for _, item in ipairs(tray.items) do
            if item.expires ~= nil and item.expires <= now then changed = true
            else kept[#kept + 1] = item end
        end
        if changed then tray.items = kept end
        return changed
    end

    -- set_tray(body, from) -> accepted, reason, whether the view changed
    --
    -- The provider picks the key: a repeated command with the same key updates
    -- the item rather than adding a second one. The item is deliberately not
    -- locked to its owner: a service provider comes back after a restart with a
    -- new pid, and a locked item would hang dead until the end of its term next
    -- to the new one. Someone else's caption can be replaced by any process,
    -- which can close any window with the `desktop.close` command anyway; an
    -- item's `entry` opens the same thing the menu does.
    local function set_tray(body: any, from: any): (boolean, any, boolean)
        local key = type(body.key) == "string" and body.key or ""
        if key == "" then return false, "the tray item has no key", false end
        if #key > TRAY_KEY then return false, "the tray item key is longer than " .. TRAY_KEY, false end
        local pruned = prune_tray()

        local index = 0
        for position, item in ipairs(tray.items) do
            if item.key == key then index = position end
        end
        if body.remove == true then
            if index == 0 then return true, nil, pruned end
            local kept = {}
            for position, item in ipairs(tray.items) do
                if position ~= index then kept[#kept + 1] = item end
            end
            tray.items = kept
            return true, nil, true
        end

        local text = type(body.text) == "string" and body.text or ""
        if text == "" then return false, "tray item " .. key .. " has no caption", pruned end
        if #runes(text) > TRAY_TEXT then
            return false, "the tray caption is longer than " .. TRAY_TEXT .. " characters", pruned
        end
        local entry = type(body.entry) == "string" and body.entry ~= "" and body.entry or nil
        local title = type(body.title) == "string" and body.title ~= "" and body.title or nil
        -- A picture beside the caption: `image` — a name from the theme's
        -- icon catalog (pixels), `icon` — one character for the cell theme.
        -- Both optional; the theme that has neither draws the caption alone.
        local image = type(body.image) == "string" and body.image ~= "" and body.image or nil
        if image ~= nil and #image > TRAY_KEY then
            return false, "the tray item image name is longer than " .. TRAY_KEY, pruned
        end
        local icon = type(body.icon) == "string" and body.icon ~= "" and body.icon or nil
        if icon ~= nil and #runes(icon) > 1 then
            return false, "the tray item icon is one character", pruned
        end
        local expires = nil
        if body.ttl ~= nil then
            local ttl: number = tonumber(body.ttl) or 0
            if ttl <= 0 then
                return false, "a tray item's ttl is a number of seconds above zero", pruned
            end
            expires = time.now():unix_nano() + math.floor(ttl * 1000000000)
        end
        if index == 0 and #tray.items >= TRAY_MAX then
            return false, "the tray already holds " .. TRAY_MAX .. " items", pruned
        end

        local item: any = {key = key, text = text, entry = entry, title = title,
            image = image, icon = icon,
            expires = expires, owner = from ~= nil and tostring(from) or nil}
        if index == 0 then
            tray.items[#tray.items + 1] = item
            return true, nil, true
        end
        local old = tray.items[index]
        tray.items[index] = item
        -- Extending the term without changing the caption is not worth a
        -- frame: the provider updates the item on a timer, and every such
        -- update would otherwise be a full redraw of the panel.
        local changed = old.text ~= text or old.entry ~= entry or old.title ~= title
            or old.image ~= image or old.icon ~= icon
        return true, nil, changed or pruned
    end

    -- Balloon tips (`desktop.balloon`). `shown` is the one on screen, `queue`
    -- the ones waiting in order, `timer` the shown one's timeout. A table,
    -- like `tray`: the logon pcall sits above in this frame.
    local balloons: any = {shown = nil, queue = {}, timer = nil, seq = 0}

    -- What the balloon gives the theme and the command channel. The theme
    -- gets what it draws and what a click turns into; the channel also gets
    -- the owner, the timeout and the time left.
    local function balloon_view(detailed: boolean): any
        local item: any = balloons.shown
        if item == nil then return nil end
        local view: any = {key = item.key, title = item.title, text = item.text, icon = item.icon,
            image = item.image, anchor = item.anchor, entry = item.entry, bell = item.bell}
        if detailed then
            view.args = item.args
            view.owner = item.owner
            view.timeout = item.timeout
            local left: integer = math.tointeger((tonumber(item.expires) or 0) - time.now():unix_nano()) or 0
            view.expires_in = math.max(0, left // 1000000000)
        end
        return view
    end

    -- show_balloon(item) — on screen, with its timeout running.
    --
    -- `bell` is carried, not rung: the runtime's surface writes frames only
    -- (rows, a cursor, images) and has no way to ring the terminal's bell.
    -- The flag reaches the theme and `desktop.list`, so the request is visible
    -- and a runtime that learns to ring finds it in place.
    local function show_balloon(item: any)
        balloons.shown = item
        item.expires = time.now():unix_nano() + math.floor(item.timeout * 1000000000)
        balloons.timer = after_seconds(tonumber(item.timeout) or BALLOON_TIMEOUT)
    end

    -- next_balloon() — the shown one goes; the first waiting one takes its place.
    local function next_balloon()
        balloons.shown, balloons.timer = nil, nil
        local rest, first = without(balloons.queue, 1)
        balloons.queue = rest
        if first ~= nil then show_balloon(first) end
    end

    -- set_balloon(body, from) -> accepted, reason, whether the view changed, key, item
    --
    -- The same key replaces a waiting or the shown balloon in its place (the
    -- shown one restarts its timeout); `remove = true` dismisses it. A refusal
    -- names the field or the limit: a provider whose balloon silently did not
    -- show would believe it had.
    local function set_balloon(body: any, from: any): (boolean, any, boolean, any, any)
        local key: any = body.key
        if key ~= nil and (type(key) ~= "string" or key == "") then
            return false, "a balloon's key is a non-empty string", false, nil, nil
        end
        if key ~= nil and #key > TRAY_KEY then
            return false, "the balloon key is longer than " .. TRAY_KEY, false, key, nil
        end
        local index = 0
        if key ~= nil then
            for position, item in ipairs(balloons.queue) do
                if item.key == key then index = position end
            end
        end
        local shown: any = balloons.shown
        local is_shown = key ~= nil and shown ~= nil and shown.key == key

        if body.remove == true then
            if key == nil then return false, "a balloon is removed by its key", false, nil, nil end
            if is_shown then
                next_balloon()
                return true, nil, true, key, nil
            end
            if index > 0 then balloons.queue = (without(balloons.queue, index)) end
            return true, nil, false, key, nil
        end

        local function required(name: string, limit: integer): (any, any)
            local value: any = body[name]
            if type(value) ~= "string" or value == "" then return nil, "a balloon needs its " .. name end
            if #runes(value) > limit then
                return nil, "the balloon " .. name .. " is longer than " .. limit .. " characters"
            end
            return value, nil
        end
        local function optional(name: string): (any, any)
            local value: any = body[name]
            if value == nil or value == "" then return nil, nil end
            if type(value) ~= "string" then return nil, "a balloon's " .. name .. " is a string" end
            return value, nil
        end

        local title, title_error = required("title", BALLOON_TITLE)
        if not title then return false, title_error, false, key, nil end
        local text, text_error = required("text", BALLOON_TEXT)
        if not text then return false, text_error, false, key, nil end
        local icon: any = body.icon
        if icon ~= nil and not (type(icon) == "string" and BALLOON_ICONS[icon]) then
            return false, "a balloon's icon is info, warning or error, not " .. tostring(icon), false, key, nil
        end
        local fields: any = {}
        for _, name in ipairs({"image", "anchor", "entry", "args"}) do
            local value, why = optional(name)
            if why then return false, why, false, key, nil end
            fields[name] = value
        end
        if fields.image ~= nil and #fields.image > TRAY_KEY then
            return false, "the balloon image name is longer than " .. TRAY_KEY, false, key, nil
        end
        local timeout = seconds(body.timeout, BALLOON_TIMEOUT, BALLOON_LEAST, BALLOON_MOST)
        if timeout == nil then return false, "a balloon's timeout is a number of seconds", false, key, nil end
        if body.bell ~= nil and type(body.bell) ~= "boolean" then
            return false, "a balloon's bell is true or false", false, key, nil
        end

        if key == nil then
            balloons.seq = balloons.seq + 1
            key = "b" .. balloons.seq
        end
        local item: any = {key = key, title = title, text = text, icon = icon,
            image = fields.image, anchor = fields.anchor, entry = fields.entry, args = fields.args,
            timeout = timeout, bell = body.bell == true, owner = from ~= nil and tostring(from) or nil}
        if is_shown then
            show_balloon(item)
            return true, nil, true, key, item
        end
        if index > 0 then
            balloons.queue[index] = item
            return true, nil, false, key, item
        end
        local held = #balloons.queue + (shown ~= nil and 1 or 0)
        if held >= BALLOON_MAX then
            return false, "balloon " .. tostring(key) .. " refused: the desktop already holds "
                .. BALLOON_MAX .. " balloons", false, key, nil
        end
        if shown == nil then
            show_balloon(item)
            return true, nil, true, key, item
        end
        balloons.queue[#balloons.queue + 1] = item
        return true, nil, false, key, item
    end

    -- The notice line opened to modules (`desktop.notice`). `text` is what
    -- the command put there: its timer clears the line only while the line
    -- still says it, so a notice of the compositor's own that came later wins.
    local notice_clock: any = {timer = nil, text = nil}

    -- Running widgets in display order. A table, like `tray`: the logon pcall
    -- sits above in this frame, and `sync_widgets` replaces the list.
    local widgets: any = {items = {}, spawned = 0, retired = {}, failure = nil}

    -- What widgets give the theme and the command channel. The theme gets a
    -- view window's shape (`id`, `content_state`, `state_revision`) so the
    -- SDK renderer takes a widget as it is; the channel gets the status
    -- without the tree — the tree is what is drawn, not a status.
    local function widget_view(detailed: boolean): any
        local out = {}
        for _, item in ipairs(widgets.items) do
            local view: any = {id = item.id, instance = item.instance, entry = item.entry, title = item.title, opens = item.opens,
                w = item.w, h = item.h, waiting = item.waiting == true, stopped = item.stopped == true}
            if detailed then
                view.revision = item.state_revision
                view.pid = item.pid and tostring(item.pid) or nil
                view.content_width, view.content_height = item.content_width, item.content_height
            else
                view.content_state = item.content_state
                view.state_revision = item.state_revision
            end
            out[#out + 1] = view
        end
        if detailed and type(chrome.widget_layout) == "function" then
            local visible: any = {}
            for _, spot in ipairs(chrome.widget_layout(out, width, desktop_top, desktop_last)) do
                visible[spot.id] = spot
            end
            for _, item in ipairs(out) do
                local spot: any = visible[item.id]
                item.visible = spot ~= nil
                if spot then
                    item.x, item.y = spot.x, spot.y
                    item.rendered_width, item.rendered_height = spot.w, spot.h
                end
            end
        end
        return out
    end

    local function widget_of(id: any): any
        for _, item in ipairs(widgets.items) do
            if item.id == id then return item end
        end
        return nil
    end

    -- A widget whose process ended — its exit, or its runner's own close: the
    -- last tree stays, `stopped` says so, the status line names the entry, and
    -- `desktop.refresh` spawns it again. One place for both, so the two ways
    -- a widget stops cannot leave two different states.
    local function stop_widget(item: any)
        item.pid, item.stopped = nil, true
        notice = "widget " .. tostring(item.entry) .. " stopped"
        log:warn("widget stopped", {widget = item.id, entry = tostring(item.entry)})
    end

    -- A size in whole cells within the limits, the default when not given,
    -- nil when refused. 12.5 and "20" are refused, not rounded or parsed.
    local function whole_cells(value: any, default: integer, low: integer, high: integer): integer?
        if value == nil then return default end
        if type(value) ~= "number" then return nil end
        local cells = math.tointeger(value)
        if cells == nil or cells < low or cells > high then return nil end
        return cells
    end

    -- The theme owns the frame inset and screen-width constraint. Providers
    -- receive the actual content rectangle, never the requested outer size.
    function widgets.geometry(item: any): any
        local result: any = {width = item.w, height = item.h}
        if type(chrome.widget_geometry) == "function" then result = chrome.widget_geometry(item, width) end
        item.content_width, item.content_height = result.width, result.height
        result.cell_w, result.cell_h = cell_w, cell_h
        return result
    end

    local function tell_widget_size(item: any)
        local geometry: any = widgets.geometry(item)
        if item.pid == nil then return end
        geometry.type = "resize"
        process.send(tostring(item.pid), "window.input", {id = item.id, event = geometry})
    end

    function widgets.equal(a: any, b: any): boolean
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for key, value in pairs(a) do if not widgets.equal(value, b[key]) then return false end end
        for key, _ in pairs(b) do if a[key] == nil then return false end end
        return true
    end

    function widgets.copy(value: any): any
        if type(value) ~= "table" then return value end
        local result: any = {}
        for key, child in pairs(value) do result[key] = widgets.copy(child) end
        return result
    end

    -- Removed/replaced providers get the SDK close event and a bounded grace.
    -- Detach immediately so a late publication cannot overwrite a replacement.
    function widgets.retire(item: any)
        if item.pid == nil then return end
        local pid = tostring(item.pid)
        process.send(pid, "window.input", {id = item.id, event = {type = "close"}})
        widgets.retired[pid] = time.after(CLOSE_GRACE)
        item.pid = nil
    end

    -- Spawned exactly like the state provider of a view window: under the
    -- logged-on user, with the compositor's name in the context, the widget id
    -- where a window id goes and the size as the fourth argument. Answers the
    -- reason when the spawn failed.
    local function spawn_widget(item: any): string?
        local pid, err = spawner(nil, {[window_api.CONTEXT_KEY] = SERVICE_NAME})
            :spawn_monitored(tostring(item.entry), WINDOW_HOST, SERVICE_NAME, tostring(item.id), item.config, widgets.geometry(item))
        if not pid then
            item.pid, item.stopped = nil, true
            return "widget " .. tostring(item.entry) .. " did not start: " .. tostring(err)
        end
        item.pid, item.stopped = pid, false
        -- A respawned widget keeps its last tree until the new process
        -- publishes: waiting means "never had a state", not "restarting".
        item.waiting = item.content_state == nil
        return nil
    end

    -- sync_widgets() — bring the running widgets in line with the shell's
    -- list (FR-006 §3): spawn new entries, respawn stopped ones, stop and
    -- forget those that vanished. Called after logon, so that every spawn
    -- carries the user's actor, and on `desktop.refresh`.
    --
    -- A size outside the limits is refused, not clamped; the reason names the
    -- entry in the status line, the one place a person sees it.
    local function sync_widgets()
        if not read_widgets then return end
        local listed, failure = read_widgets()
        if failure ~= nil or type(listed) ~= "table" then
            widgets.failure = "widgets: " .. tostring(failure or "provider did not return a list")
            notice = widgets.failure
            return widgets.failure
        end

        -- Validate before mutating: one invalid declaration cannot erase a
        -- previously working desktop or partially apply its replacement.
        local wanted, seen, problems = {}, {}, {}
        for _, spec in ipairs(listed) do
            local entry: any = type(spec) == "table" and spec.entry or nil
            local instance: any = type(spec) == "table" and spec.instance or nil
            if type(entry) ~= "string" or entry == "" or type(instance) ~= "string" or instance == "" then
                problems[#problems + 1] = "a widget requires an instance id and process entry"
            elseif seen[instance] then
                problems[#problems + 1] = "duplicate widget instance " .. instance
            else
                seen[instance] = true
                local w = whole_cells(spec.w, WIDGET_W, WIDGET_MIN_W, WIDGET_MAX_W)
                local h = whole_cells(spec.h, WIDGET_H, WIDGET_MIN_H, WIDGET_MAX_H)
                if w == nil or h == nil then
                    problems[#problems + 1] = "widget " .. instance .. ": size must be whole cells from 10 to 40 by 2 to 16"
                elseif spec.config ~= nil and type(spec.config) ~= "table" then
                    problems[#problems + 1] = "widget " .. instance .. ": config must be a table"
                else
                    wanted[#wanted + 1] = {instance = instance, entry = entry, w = w, h = h,
                        config = widgets.copy(spec.config or {}),
                        order = tonumber(spec.order) or WIDGET_ORDER,
                        title = type(spec.title) == "string" and spec.title ~= "" and spec.title or nil,
                        opens = type(spec.opens) == "string" and spec.opens ~= "" and spec.opens or nil}
                end
            end
        end
        if #problems > 0 then
            widgets.failure = table.concat(problems, "; ")
            notice = widgets.failure
            return widgets.failure
        end
        table.sort(wanted, function(left: any, right: any)
            if left.order ~= right.order then return left.order < right.order end
            return left.instance < right.instance
        end)

        local running: any = {}
        for _, item in ipairs(widgets.items) do running[item.instance] = item end
        local kept = {}
        for _, spec in ipairs(wanted) do
            local item: any = running[spec.instance]
            running[spec.instance] = nil
            if item ~= nil and (item.entry ~= spec.entry or not widgets.equal(item.config, spec.config)) then
                widgets.retire(item)
                -- New transient id also isolates late SDK close/state messages.
                item = nil
            end
            if item == nil then
                widgets.spawned = widgets.spawned + 1
                item = {id = "g" .. widgets.spawned, instance = spec.instance, entry = spec.entry, pid = nil,
                    config = spec.config, waiting = true, stopped = false, content_state = nil, state_revision = 0}
            end
            local resized = item.w ~= nil and (item.w ~= spec.w or item.h ~= spec.h)
            item.w, item.h, item.order = spec.w, spec.h, spec.order
            item.title, item.opens = spec.title, spec.opens
            if item.pid == nil then
                local why = spawn_widget(item)
                if why then problems[#problems + 1] = why end
            elseif resized then
                tell_widget_size(item)
            end
            kept[#kept + 1] = item
        end
        for _, gone in pairs(running) do widgets.retire(gone) end
        widgets.items = kept
        widgets.failure = #problems > 0 and table.concat(problems, "; ") or nil
        if widgets.failure then notice = widgets.failure end
        return widgets.failure
    end

    local quitting = false
    -- The farewell screen is asked for only through "Shut Down" in the menu:
    -- ctrl+q is an emergency exit, it has no use for five seconds of black
    -- screen.
    local farewell_wanted = false

    local function desktop_height() return math.max(1, desktop_last - desktop_top + 1) end

    local function index_of(id)
        for index, window in ipairs(windows) do
            if window.id == id then return index end
        end
        return 0
    end

    local function find(id)
        local index = index_of(id)
        if index == 0 then return nil end
        return windows[index]
    end

    -- The focus is the top window that is not minimised. There is
    -- deliberately no separate field: two sources of truth about the focus
    -- drift apart at the very first close.
    local function focused()
        for index = #windows, 1, -1 do
            if not windows[index].minimized and not windows[index].closing then
                return windows[index]
            end
        end
        return nil
    end

    -- The window this process belongs to. The compositor determines a dialog's
    -- parent by the SENDER, not by a number in the request: a window does not
    -- know its own number, and a foreign number sent in a field cannot be
    -- checked in any way — a link could then be declared to any window on the
    -- desktop.
    local function window_of(from: any)
        if from == nil then return nil end
        local key = tostring(from)
        for _, window in ipairs(windows) do
            if tostring(window.pid) == key or tostring(window.state_pid) == key then return window end
        end
        return nil
    end

    -- A dialog and a tool window live WITH their window: they close together
    -- with it and stay on top of it. An ordinary program opened from another
    -- window is just a program: it has no reason to leave along with it, and
    -- "My Computer", having opened a viewer, must not take it away with it.
    local function follows_parent(window: any)
        local kind: any = window and window.window_type or nil
        return kind == "dialog" or kind == "tool" or (window and window.presentation == true)
    end

    local function children_of(id)
        local out = {}
        for _, window in ipairs(windows) do
            if window.opened_by == id and follows_parent(window) then
                out[#out + 1] = window
            end
        end
        return out
    end

    local function raise(window)
        local index = index_of(window.id)
        if index ~= 0 and index ~= #windows then
            table.remove(windows, index)
            windows[#windows + 1] = window
        end
        -- A dialog stays on top of its window. Gone under it, it looks lost —
        -- and there is nothing to get it back with: there is deliberately no
        -- modality here, the input of the other windows is not blocked.
        for _, child in ipairs(children_of(window.id)) do raise(child) end
    end

    -- Flashing windows (`desktop.flash`), FlashWindow's semantics: the
    -- taskbar button and the title bar swap between their lit and plain looks
    -- until the window takes the focus. The window record carries `flashing`
    -- and `flash_lit` for the theme, and `flash_left` — the swaps a count
    -- still allows (nil: until the focus). One timer serves every window;
    -- `focused_id` is the focus the last frame drew, so the frame that first
    -- shows a flashing window focused ends its flash. A table: the logon pcall
    -- sits above in this frame.
    local flashes: any = {timer = nil, focused_id = nil}

    local function stop_flash(window: any)
        window.flashing, window.flash_lit, window.flash_left = false, false, nil
    end

    -- The timer runs while any window flashes, and only then.
    local function arm_flash()
        for _, window in ipairs(windows) do
            if window.flashing then
                if flashes.timer == nil then flashes.timer = time.after(tostring(FLASH_STEP_MS) .. "ms") end
                return
            end
        end
        flashes.timer = nil
    end

    -- start_flash(window, count) — lit at once; `count` cycles of lit and
    -- plain, or until the window takes the focus.
    local function start_flash(window: any, count: any)
        window.flashing, window.flash_lit = true, true
        window.flash_left = count ~= nil and count * 2 or nil
        -- A focused window flashes only with a count (the command refuses it
        -- otherwise); the focus it already has is not the focus that ends it.
        local top = focused()
        if top ~= nil and top.id == window.id then flashes.focused_id = window.id end
        arm_flash()
    end

    -- flash_step() -> whether a frame is owed. Every step the looks swap; a
    -- counted flash ends on its last swap, in the plain look.
    local function flash_step(): boolean
        flashes.timer = nil
        local changed = false
        for _, window in ipairs(windows) do
            if window.flashing then
                changed = true
                window.flash_lit = not window.flash_lit
                if window.flash_left ~= nil then
                    window.flash_left = window.flash_left - 1
                    if window.flash_left <= 0 then stop_flash(window) end
                end
            end
        end
        arm_flash()
        return changed
    end

    local function flashing_ids(): any
        local out = {}
        for _, window in ipairs(windows) do
            if window.flashing then out[#out + 1] = window.id end
        end
        return out
    end

    -- Declared in advance: the arranging computes the icon grid, and the grid
    -- is known below. Calling it after a reread must not be forgotten — an
    -- icon without coordinates is then not drawn at all.
    local arrange_desktop: any

    -- The layout is reread on command, not on a timer: it is changed by the
    -- shell's endpoints, and they are also what tell the compositor it is time
    -- to refresh.
    local function reload_desktop()
        if not read_desktop then
            desk = {items = {}, failure = nil}
            return
        end
        local items, failure = read_desktop()
        desk = {
            items = type(items) == "table" and items or {},
            failure = failure and tostring(failure) or nil,
        }
        arrange_desktop()
    end

    -- The icon grid step is declared by the theme: it draws the icon and knows
    -- how much room it takes. The compositor only aligns a dropped icon to it —
    -- otherwise the icon lands between steps and is covered by a neighbour's
    -- hit.
    local function icon_grid()
        local grid: any = nil
        if type(chrome.icon_grid) == "function" then grid = chrome.icon_grid() end
        if type(grid) ~= "table" then
            grid = {w = chrome.ICON_W, h = chrome.ICON_H, left = chrome.ICON_LEFT}
        end
        local gw = math.tointeger(tonumber(grid.w) or 12) or 12
        local gh = math.tointeger(tonumber(grid.h) or 4) or 4
        local gl = math.tointeger(tonumber(grid.left) or 1) or 1
        if gw < 1 then gw = 1 end
        if gh < 1 then gh = 1 end
        if gl < 1 then gl = 1 end
        return gw, gh, gl
    end

    local function snap(value: any, step: any, base: any)
        local origin = math.tointeger(tonumber(base) or 1) or 1
        local size = math.tointeger(tonumber(step) or 1) or 1
        if size < 1 then size = 1 end
        local point = math.tointeger(tonumber(value) or origin) or origin
        local offset = point - origin
        if offset < 0 then offset = 0 end
        local cell = math.tointeger((offset + size // 2) // size) or 0
        return origin + cell * size
    end

    -- An icon without coordinates is placed by the compositor: only it knows
    -- the screen width, while the shell composes the layout before the
    -- terminal has reported its size. The computed place is NOT written back
    -- — otherwise the very first frame would turn an auto-placed icon into a
    -- hand-placed one, and the person would lose the difference this is done
    -- for.
    --
    -- Not enough places — the icon goes to the last cell on top of a
    -- neighbour. Overlapping icons are visible and can be pulled apart; one
    -- lost beyond the edge reads as "I deleted it by accident".
    arrange_desktop = function()
        local gw, gh, gl = icon_grid()

        local rows = math.tointeger((desktop_last - desktop_top + 1) // gh) or 1
        if rows < 1 then rows = 1 end
        local columns = math.tointeger((width - gl + 1) // gw) or 1
        if columns < 1 then columns = 1 end

        local taken: any = {}
        for _, item in ipairs(desk.items) do
            if not item.auto and tonumber(item.x) and tonumber(item.y) then
                taken[tostring(item.x) .. ":" .. tostring(item.y)] = true
            end
        end

        local slot = 0
        for _, item in ipairs(desk.items) do
            if item.auto or tonumber(item.x) == nil or tonumber(item.y) == nil then
                local x, y = gl, desktop_top
                local steps = 0
                while steps <= columns * rows do
                    local column = math.tointeger(slot // rows) or 0
                    local row = math.tointeger(slot % rows) or 0
                    if column >= columns then break end
                    x = gl + column * gw
                    y = desktop_top + row * gh
                    slot = slot + 1
                    steps = steps + 1
                    if not taken[tostring(x) .. ":" .. tostring(y)] then break end
                end
                item.x, item.y = x, y
                item.auto = true
                taken[tostring(x) .. ":" .. tostring(y)] = true
            end
        end
    end

    local function desktop_item(id)
        for _, item in ipairs(desk.items) do
            if item.id == id then return item end
        end
        return nil
    end

    local function desktop_spot(x, y)
        for _, spot in ipairs(desk_hits) do
            if y == spot.row and x >= spot.from and x <= spot.to then return spot end
        end
        return nil
    end

    -- In pixel mode the window content is laid by the COMPOSITOR.
    --
    -- In character mode the window's rows are laid by the theme — it also
    -- draws the frame around them in one piece. A raster theme draws the
    -- frame with pictures and does not write to the canvas at all; the rows
    -- remain characters meanwhile (bash can only do those), and there is
    -- nobody else to lay them.
    local function put_content(window)
        if type(window.rows) ~= "table" or #window.rows == 0 then return end
        local left = window.presentation and 0 or (math.tointeger(insets.left) or 1)
        local top_inset = window.presentation and 0 or (math.tointeger(insets.top) or 1)
        local x = (math.tointeger(window.x) or 1) + left
        local y = (math.tointeger(window.y) or 1) + top_inset
        local span = (math.tointeger(window.w) or 0) - (window.presentation and 0 or FRAME_W)
        local room = (math.tointeger(window.h) or 0) - (window.presentation and 0 or FRAME_H)
        if span < 1 or room < 1 then return end

        -- Extra rows are cut here, as in the character theme: at the moment
        -- of a size change a frame of the previous geometry arrives, and an
        -- extra row would land below the window — on screen that reads as a
        -- broken window frame, not as a late frame.
        local rows: any = window.rows
        if #rows > room then
            local cut = {}
            for index = 1, room do cut[index] = rows[index] end
            rows = cut
        end
        if type(chrome.content_colors) == "function" then
            local defaults: any = chrome.content_colors(window)
            if type(defaults) == "table" then
                canvas:put_rows(x, y, rows :: {string}, span, {
                    foreground = type(defaults.foreground) == "string" and tostring(defaults.foreground) or nil,
                    background = type(defaults.background) == "string" and tostring(defaults.background) or nil,
                })
                return
            end
        end
        canvas:put_rows(x, y, rows :: {string}, span)
    end

    local function round_ms(value)
        return math.floor(value * 1000 + 0.5) / 1000
    end

    local function record_frame(cost: any, at)
        meter.total = meter.total + 1
        meter.samples[meter.next] = {
            paint = cost.paint_ms, present = cost.present_ms, total = cost.total_ms,
            bytes = tonumber(cost.bytes_written) or 0, trigger = cost.trigger, at = at,
            seq = meter.total,
        }
        meter.next = meter.next % FRAME_WINDOW + 1
    end

    -- The frame cost for the status: the last frame as it was, plus a summary
    -- over the ring. The percentile is computed here, on request: under a
    -- stream of output frames come dozens per second, while the status is
    -- asked for once every few seconds.
    local function frame_report(with_samples)
        local report: any = {}
        for key, value in pairs(frame_cost) do report[key] = value end
        report.frames_total = meter.total
        local samples: any = meter.samples
        local count = #samples
        if with_samples then
            -- Raw frames, oldest to newest. A per-phase measurement stitches
            -- them together by `seq` from neighbouring snapshots: the ring's
            -- summary at the end of a short phase would mix it with the
            -- frames of the previous one.
            local raw = {}
            for offset = 0, count - 1 do
                local sample = samples[(meter.next - 1 + offset) % count + 1]
                raw[#raw + 1] = {
                    seq = sample.seq, at_ms = math.floor(sample.at / 1000000),
                    paint_ms = sample.paint, present_ms = sample.present,
                    total_ms = sample.total, bytes = sample.bytes, trigger = sample.trigger,
                }
            end
            report.samples = raw
        end
        if count == 0 then return report end

        local function part(field)
            local values = {}
            local sum, max, max_trigger = 0, -1, nil
            for _, sample in ipairs(samples) do
                local value = tonumber(sample[field]) or 0
                values[#values + 1] = value
                sum = sum + value
                if value > max then max, max_trigger = value, sample.trigger end
            end
            table.sort(values)
            local rank = math.tointeger(math.max(1, math.ceil(#values * 0.95))) or 1
            return {avg_ms = round_ms(sum / #values), p95_ms = round_ms(values[rank]),
                max_ms = round_ms(max), max_trigger = max_trigger}
        end

        local oldest, newest = nil, nil
        local bytes_sum, bytes_max = 0, 0
        local triggers: any = {}
        for _, sample in ipairs(samples) do
            if oldest == nil or sample.at < oldest then oldest = sample.at end
            if newest == nil or sample.at > newest then newest = sample.at end
            bytes_sum = bytes_sum + sample.bytes
            if sample.bytes > bytes_max then bytes_max = sample.bytes end
            -- By kind, without the window: "pty:w3" and "pty:w4" are one
            -- question.
            local kind = tostring(sample.trigger):match("^[^:]+") or "?"
            triggers[kind] = (triggers[kind] or 0) + 1
        end
        report.window = {
            frames = count,
            span_s = round_ms(((newest or 0) - (oldest or 0)) / 1000000000),
            paint = part("paint"), present = part("present"), total = part("total"),
            bytes_avg = math.floor(bytes_sum / count + 0.5), bytes_max = bytes_max,
            triggers = triggers,
        }
        return report
    end

    -- The rect a move or resize drag would give. Windows 95 drags an OUTLINE:
    -- the window keeps its place and size until the release, and only the
    -- outline follows the pointer — a frame per motion then costs a dotted
    -- rectangle, not the whole window re-laid and re-sent at a new size.
    local function drag_outline(): any
        if drag.active and drag.mode ~= "icon" and drag.pending ~= nil then return drag.pending end
        return nil
    end

    -- The outline in cells for a theme without `chrome.outline`: a dotted frame.
    local function default_outline(target: any, rect: any)
        local x, y = math.tointeger(rect.x) or 1, math.tointeger(rect.y) or 1
        local w, h = math.tointeger(rect.w) or 0, math.tointeger(rect.h) or 0
        if w < 2 or h < 2 then return end
        target:put(x, y, string.rep("┄", w), w)
        target:put(x, y + h - 1, string.rep("┄", w), w)
        for row = y + 1, y + h - 2 do
            target:put(x, row, "┆", 1)
            target:put(x + w - 1, row, "┆", 1)
        end
    end

    -- draw_now() paints a frame at once; `draw()` (below) is how everything
    -- asks for one.
    local function draw_now()
        local started = time.now():unix_nano()
        canvas:clear(" ")

        local top = focused()
        -- The frame that first shows a flashing window focused ends its
        -- flash: FlashWindow's "until the window is activated". Before the
        -- painting, so this very frame draws it plain.
        if top ~= nil and top.flashing and flashes.focused_id ~= top.id then stop_flash(top) end
        flashes.focused_id = top and top.id or nil
        -- Computed before branching on `top`: after the if/else the linter
        -- keeps it narrowed, and the `id` field no longer exists for it.
        local focused_id = top and top.id or nil
        -- One list for both modes and every call of the frame: `fill` and
        -- `paint` must see the same widgets in the same order.
        local widget_list: any = widget_view(false)

        desk_hits = {}
        local presenting = top ~= nil and top.presentation == true
        if presenting then
            bar_hits,menu_hits = {},{}
            put_content(top)
        elseif not PIXELS then
            -- The background also draws the desktop icons, if the theme can:
            -- the compositor gives it the layout and the bounds of the free
            -- space, and takes back the hit layout — the click is computed
            -- from it as well.
            local painted = chrome.fill(canvas, width, height, {
                top = desktop_top,
                bottom = desktop_last,
                items = desk.items,
                failure = desk.failure,
                selected = selected_id,
                widgets = widget_list,
            })
            if type(painted) == "table" then desk_hits = painted end

            if #windows == 0 then
                chrome.empty_desktop(canvas, width, height, HINT)
            end

            for _, window in ipairs(windows) do
                if not window.minimized then
                    chrome.window(canvas, window, top ~= nil and window.id == top.id)
                end
            end
        else
            -- The background and the desktop are filled with CELLS in this
            -- mode too. Without that the window body shows the desktop
            -- through wherever the program inside has written nothing: in
            -- character mode the background was painted by `chrome.window`,
            -- while a raster theme does not write to the canvas at all. And
            -- the desktop itself would sit not on its own colour but on the
            -- terminal's.
            if type(chrome.fill) == "function" then
                local filled = chrome.fill(canvas, width, height, {
                    top = desktop_top,
                    bottom = desktop_last,
                    items = desk.items,
                    failure = desk.failure,
                    selected = selected_id,
                    widgets = widget_list,
                })
                if type(filled) == "table" then desk_hits = filled end
            end

            for _, window in ipairs(windows) do
                if not window.minimized then
                    if type(chrome.window_background) == "function" then
                        chrome.window_background(canvas, window)
                    end
                    put_content(window)
                end
            end
        end

        -- The taskbar carries only notices — an open that failed, a theme that
        -- returned a bad frame. Windows 95 has no key hint there (owner's rule,
        -- 2026-09-11); the keys are explained on the empty desktop (`hint`).
        -- `status` stays for older themes and carries the same text.
        local status = notice

        -- The state for a raster theme is the union of what arrives in
        -- character mode through three calls. The field names are the same on
        -- purpose: a theme that can do both modes recognises them without
        -- translation.
        local images: any = nil
        if PIXELS then
            local painted = chrome.paint({
                width = width, height = height,
                top = desktop_top, bottom = desktop_last,
                windows = windows, focused_id = focused_id,
                presentation = presenting and top or nil,
                items = desk.items, failure = desk.failure, selected = selected_id,
                menu = menu and {items = menu.items, failure = menu.failure,
                    open = menu.open, cursor = menu.cursor, anchor = menu.anchor} or nil,
                status = status, notice = notice, clock = clock, tray = tray_view(false), hint = HINT,
                -- The balloon tip by the notification area, or nil.
                balloon = balloon_view(false),
                widgets = widget_list,
                -- A move or resize drag's pending rect: the theme draws its
                -- outline over everything (a theme that does not know the
                -- field shows nothing until the release).
                outline = drag_outline(),
            }, cell_w, cell_h)

            local complaints
            -- The blanks under the pictures are laid by `frame`, and it does
            -- that AFTER the content: otherwise a window's row would stick
            -- out from under another window's frame.
            images, complaints = pixels.frame(canvas, painted)
            local hits, quarrel = pixels.hits(painted)
            bar_hits, menu_hits = hits.bars, hits.menu
            -- The desktop icons are drawn by `paint`, so its layout takes
            -- precedence. But if it did not return one, the one the fill
            -- returned stays: silently lost clicks on the desktop look like
            -- dead icons.
            if #hits.desktop > 0 then desk_hits = hits.desktop end
            if quarrel then complaints[#complaints + 1] = quarrel end
            for _, complaint in ipairs(complaints) do
                log:warn("the theme returned a bad frame", {reason = complaint})
            end
            -- And into the status line as well. The terminal host's log is
            -- muted — otherwise it would break the frame apart — so a
            -- complaint told only to it is told to nobody: on the stand this
            -- looks like "the mouse does not work", not like "the theme
            -- returned hits in the wrong shape".
            if #complaints > 0 then notice = tostring(complaints[1]) end
        elseif not presenting then
            bar_hits = chrome.bars(canvas, width, height, {
                windows = windows,
                focused_id = focused_id,
                -- "Start" is pressed while its cascade is open; an icon's
                -- context menu (with an anchor) is not Start's.
                menu_open = menu ~= nil and menu.anchor == nil,
                status = status,
                notice = notice,
                clock = clock,
                -- The tray stands by the clock. A theme without it simply
                -- does not draw it: the field is optional, as the clock
                -- itself is.
                tray = tray_view(false),
                -- The balloon tip, drawn by `bars` because `bars` comes after
                -- the windows: it lies over them. A theme without it draws
                -- nothing, and the balloon still times out.
                balloon = balloon_view(false),
            })
            if type(bar_hits) ~= "table" then bar_hits = {} end

            menu_hits = {}
            if menu then
                -- The cursor is handed to the theme rather than computed by
                -- it: the theme marks the selected row in the hit layout, and
                -- that same layout comes back here. So "what is selected"
                -- exists in one place — in what is drawn.
                local hits = chrome.menu(canvas, width, height, menu.items, menu.failure,
                    menu.open, menu.cursor, menu.anchor)
                if type(hits) == "table" then menu_hits = hits end
            end

            local outline = drag_outline()
            if outline then
                if type(chrome.outline) == "function" then chrome.outline(canvas, outline)
                else default_outline(canvas, outline) end
            end
        end

        -- There is one hardware cursor per screen, so only the focused window
        -- gets it — and offset by its frame, otherwise it would stand a row
        -- above its own text.
        local cursor = nil
        if top and top.cursor and not presenting then
            cursor = {
                x = clamp(top.x + (math.tointeger(insets.left) or 1) - 1 + top.cursor.x, 1, width),
                y = clamp(top.y + (math.tointeger(insets.top) or 1) - 1 + top.cursor.y, 1, height),
                visible = top.cursor.visible,
            }
        end

        -- A terminal that is gone fails the write. That is not a crash:
        -- nothing can be shown any more, so the loop shuts the desktop down
        -- as "Shut Down" does, and the windows are closed rather than left
        -- behind with nobody to see them.
        if terminal_state.lost then return end
        local painted_at = time.now():unix_nano()
        local stats, present_error = out:present(canvas:rows(), {cursor = cursor, images = images})
        if not stats then
            terminal_state.lost = tostring(present_error)
            frame_gate.dirty, frame_gate.merged = false, 0
            return
        end
        local presented_at = time.now():unix_nano()
        frame_cost = {
            changed_rows = stats.changed_rows,
            bytes_written = stats.bytes_written,
            -- How many rasters actually went out, as opposed to how many the
            -- frame declared. A runtime that does not count this leaves the
            -- field empty — and "not measured" will not pretend to be zero.
            placements_sent = stats.placements_sent,
            images = images and #images or 0,
            -- paint — the canvas and the theme (fill/window/bars/menu or
            -- paint+frame), present — the surface differ and the raster
            -- encoding.
            paint_ms = round_ms((painted_at - started) / 1000000),
            present_ms = round_ms((presented_at - painted_at) / 1000000),
            total_ms = round_ms((presented_at - started) / 1000000),
            trigger = meter.trigger,
            -- Only a window's frame has it: its viewport snapshot before
            -- `draw`.
            snapshot_ms = meter.snapshot_ms,
        }
        record_frame(frame_cost, presented_at)
        frame_gate.last_ms = presented_at // 1000000
        frame_gate.dirty, frame_gate.merged = false, 0
        if notify_focus then notify_focus() end
    end

    -- draw() — asks for a frame. The first request after FRAME_MS of quiet is
    -- painted at once, so a single click or key shows at once; the requests
    -- inside the gap only mark the frame owed, and the frame timer (in the
    -- loop's select) paints them as ONE frame: a drag's motions, a progress
    -- bar's lines and several windows' states cost a frame per FRAME_MS.
    local function draw()
        local now = time.now():unix_nano() // 1000000
        if frame_gate.timer == nil and now - frame_gate.last_ms >= FRAME_MS then
            draw_now()
            return
        end
        frame_gate.dirty = true
        frame_gate.merged = frame_gate.merged + 1
        if frame_gate.timer == nil then
            local wait = math.tointeger(math.max(1, FRAME_MS - (now - frame_gate.last_ms))) or 1
            frame_gate.timer = time.after(string.format("%dms", wait))
        end
    end

    -- flush() — an owed frame is painted now. What reads the frame — a
    -- press or a key (the hits), the `screen` command — must see the last
    -- state, not the one before the batch.
    local function flush()
        if not frame_gate.dirty then return end
        -- The frame is the owed batch's, and the report says so; the event
        -- being handled keeps its own name for the frame it may draw next.
        local was = meter.trigger
        meter.trigger = "batch:" .. tostring(frame_gate.merged)
        draw_now()
        meter.trigger = was
    end

    -- open_window(spec, from) — `from` is the sender of the command. If it
    -- turned out to be one of the windows, the opened one remembers who opened
    -- it.
    local function open_window(spec, from: any)
        spec = type(spec) == "table" and spec or {}

        local entry = type(spec.entry) == "string" and spec.entry ~= "" and spec.entry or PTY_WINDOW

        local opener = window_of(from)

        -- The type is needed before the geometry: a dialog is placed
        -- differently from an ordinary window.
        local record: any = registry.get(entry)
        local declared: any = nil
        local window_type = programs.DEFAULT_TYPE
        if record then
            local unknown
            declared, unknown = programs.item(record)
            if declared then window_type = declared.window_type end
            if unknown then
                log:warn("unknown window type", {
                    entry = entry, window_type = unknown, used = programs.DEFAULT_TYPE,
                })
            end
        end
        if type(spec.window_type) == "string" and programs.TYPES[spec.window_type] then
            window_type = spec.window_type
        end

        -- An entry may name the action a person needs to open it
        -- (`meta.requires`). A window whose own policy grants what the person
        -- lacks — a shell on the server — must not open for everyone who logs
        -- on. The question goes to the logged-on identity's scope; a desktop
        -- without logon runs under its own actor and asks nobody, as before.
        local requires: any = record and type(record.meta) == "table" and record.meta.requires or nil
        if type(requires) == "string" and requires ~= "" and IDENTITY ~= nil then
            local verdict = IDENTITY.scope:evaluate(IDENTITY.actor, requires, entry)
            if verdict ~= "allow" then
                local context: any = type(IDENTITY.context) == "table" and IDENTITY.context or {}
                local who = context.user_name or context.user_id or "the logged-on user"
                return nil, tostring(who) .. " may not open " .. entry .. " (it needs " .. requires .. ")"
            end
        end

        local presentation = declared ~= nil and declared.presentation == true
        if presentation and PIXELS and chrome.presentation ~= true then
            return nil, "This theme does not support full-screen presentations"
        end

        -- Size: for a fixed-size window — ONLY from the entry, whatever the
        -- opener asks for; otherwise a clock opened from the taskbar without
        -- a size would take the whole desktop with the dialog in a corner.
        -- For the others — the opener's request, then the entry, then the
        -- compositor's default.
        local declared_w = declared and tonumber(declared.w) or nil
        local declared_h = declared and tonumber(declared.h) or nil
        local fixed = declared ~= nil and declared.resizable == false
        local w = clamp((fixed and declared_w) or spec.w or declared_w or math.floor(width * 0.6), MIN_W, width)
        local h = clamp((fixed and declared_h) or spec.h or declared_h or math.floor(desktop_height() * 0.7),
            MIN_H, desktop_height())
        -- Cascade, so that a new window does not lie exactly over the
        -- previous one and look like no result.
        local step = (#windows % 6) * 2
        local x = clamp(spec.x or (2 + step), 1, math.max(1, width - w + 1))
        local y = clamp(spec.y or (desktop_top + step), desktop_top, math.max(desktop_top, height - h))

        -- A dialog of its own window is centred on it rather than put into
        -- the common cascade: searching the whole desktop by eye for a window
        -- you opened yourself is work that should not exist. Explicit
        -- coordinates win: they were named by whoever asked.
        if opener and spec.x == nil and spec.y == nil
            and (window_type == "dialog" or window_type == "tool") then
            local ox = math.tointeger(opener.x) or 1
            local oy = math.tointeger(opener.y) or desktop_top
            local ow = math.tointeger(opener.w) or w
            local oh = math.tointeger(opener.h) or h
            x = clamp(ox + (ow - w) // 2, 1, math.max(1, width - w + 1))
            y = clamp(oy + (oh - h) // 2, desktop_top, math.max(desktop_top, height - h))
        end

        if presentation then x,y,w,h = 1,1,width,height end
        local frame_w,frame_h = presentation and 0 or FRAME_W,presentation and 0 or FRAME_H

        -- A view window: there is no process inside at all. The theme draws
        -- it by calling the pure library `render`; the data is obtained by a
        -- separate provider process with its own narrow actor. The compositor
        -- executes neither — it carries the state from the provider to the
        -- theme.
        local content = declared and declared.content or programs.DEFAULT_CONTENT
        local render_ref = declared and declared.render or nil
        local state_ref = declared and declared.state or nil
        if PIXELS and declared and declared.pixel_render
            and type(chrome.renders) == "function" and chrome.renders(declared.pixel_render) then
            content, render_ref, state_ref = "pixels", declared.pixel_render, declared.pixel_state
        end
        if content == "pixels" then
            if not render_ref then
                return nil, "window " .. entry .. " declared its content as a view "
                    .. "but named no render — nothing to draw it with"
            end
            if not registry.get(render_ref) then
                return nil, "window " .. entry .. ": entry " .. render_ref .. " does not exist — "
                    .. "a dead render reference stays silent until the first open"
            end

            if state_ref and not registry.get(state_ref) then
                return nil, "window " .. entry .. ": entry " .. state_ref .. " does not exist — "
                    .. "the state provider is declared but missing"
            end

            next_id = next_id + 1
            local view_window: any = {
                id = "w" .. next_id,
                entry = entry,
                window_type = window_type,
                presentation = presentation,
                presentation_interactive = presentation and declared.presentation_interactive == true,
                opened_by = opener and opener.id or nil,
                title = type(spec.title) == "string" and spec.title ~= "" and spec.title
                    or (declared and declared.title or entry),
                content = content,
                render = render_ref,
                image = spec.image or (declared and declared.image),
                state_ref = state_ref,
                resizable = declared == nil or declared.resizable ~= false,
                -- No state yet: the view is drawn empty and SAYS that it is
                -- waiting, rather than showing yesterday's state or hanging.
                waiting = state_ref ~= nil,
                state_revision = 0,
                -- As for a process window: `desktop.list` reports it.
                args = type(spec.args) == "string" and spec.args ~= "" and spec.args or nil,
                x = x, y = y, w = w, h = h,
                view = nil, updates = nil, pid = nil,
                rows = {}, cursor = nil, revision = -1,
                ready = false, minimized = false, maximized = false,
                closing = false, deadline = nil,
                saved = {x = x, y = y, w = w, h = h},
            }

            if state_ref then
                -- The provider gets the compositor's name and the window
                -- number: it sends the state back itself when it has changed.
                -- Asking it every frame would mean reading the registry sixty
                -- times a second for a list that changes once an hour — and
                -- waiting for another process while the whole desktop stands
                -- still.
                -- Args retain their position; geometry is a separate fourth argument.
                local state_pid, serr = spawner(nil, {[window_api.CONTEXT_KEY] = SERVICE_NAME})
                    :spawn_monitored(tostring(state_ref), WINDOW_HOST, SERVICE_NAME, tostring(view_window.id),
                        type(spec.args) == "string" and spec.args ~= "" and spec.args or nil, {
                            width = w - frame_w, height = h - frame_h,
                            cell_w = cell_w, cell_h = cell_h,
                        })
                if not state_pid then
                    return nil, "the state provider did not start: " .. tostring(serr)
                end
                view_window.state_pid = state_pid
                view_window.ready = true
            end

            windows[#windows + 1] = view_window
            return view_window, nil
        end

        local view, verr = tty.viewport({width = w - frame_w, height = h - frame_h})
        if not view then return nil, tostring(verr) end

        local updates, uerr = view:updates()
        if not updates then return nil, tostring(uerr) end

        local grant, gerr = view:grant()
        if not grant then return nil, tostring(gerr) end

        local command = type(spec.command) == "string" and spec.command ~= ""
            and spec.command or DEFAULT_COMMAND

        -- An application window gets its parameter (`args`), a program window
        -- gets a command. One field for both meanings would read as
        -- "command", and a details window would be opened with the string
        -- "/bin/bash".
        local argument = type(spec.args) == "string" and spec.args ~= ""
            and spec.args or (entry == PTY_WINDOW and command or nil)

        -- The compositor's name travels to the window in the process context:
        -- under a second shell the desktop is registered under its own name,
        -- and a window that knows only the constant would address another
        -- process — silently, because `desktop.open` does not wait for a
        -- reply.
        local pid, perr = spawner(process.with_options({terminal = grant}), {[window_api.CONTEXT_KEY] = SERVICE_NAME})
            :spawn_monitored(entry, WINDOW_HOST, argument)
        if not pid then
            view:close()
            return nil, tostring(perr)
        end

        next_id = next_id + 1
        local window = {
            id = "w" .. next_id,
            entry = entry,
            -- The theme picks the set of title buttons by it; the compositor
            -- only carries it from the entry to the theme.
            window_type = window_type,
            presentation = presentation,
            presentation_interactive = presentation and declared.presentation_interactive == true,
            -- Who opened it. For a dialog and a tool window this is its
            -- window — hence the shared z and the shared close. For an
            -- ordinary program it is just a trace: who launched it.
            opened_by = opener and opener.id or nil,
            content = content,
            image = spec.image or (declared and declared.image),
            -- The entry said "fixed size" — the window is not dragged by its
            -- corner and not maximised; the theme removes the button by this
            -- same field.
            resizable = declared == nil or declared.resizable ~= false,
            title = type(spec.title) == "string" and spec.title ~= "" and spec.title
                or (entry == PTY_WINDOW and command or (declared and declared.title or entry)),
            command = command,
            -- The argument the window was opened with, as `desktop.list`
            -- reports it: an opener finds a window already open for the same
            -- thing (a folder window for the same path) and focuses it
            -- instead of opening a second one. A bash window's command is
            -- `command`, not this.
            args = type(spec.args) == "string" and spec.args ~= "" and spec.args or nil,
            x = x, y = y, w = w, h = h,
            view = view, updates = updates, pid = pid,
            rows = {}, cursor = nil, revision = -1,
            ready = false, minimized = false, maximized = false,
            closing = false, deadline = nil,
            saved = {x = x, y = y, w = w, h = h},
        }
        windows[#windows + 1] = window
        return window, nil
    end

    -- Declared in advance: closing a view calls `forget` at once (a view has
    -- no process whose death would call it on its own), and `forget` in turn
    -- closes the dialogs. Without this line `forget` inside `close_window` is
    -- a global variable, that is nil, and the compositor crashes exactly
    -- where a view window is closed.
    local forget: any

    -- Closing: politely first, then by the deadline. A window that has not yet
    -- called tty.start() does not take input — it is killed at once.
    -- `how` is "request" (the default: the ×, ctrl+w, a plain `desktop.close`)
    -- or "force" (shutdown, `desktop.close{force = true}`). A request sends
    -- `close` and waits: the window may refuse — Notepad asks to save a
    -- changed document — and when the grace runs out it stays open and the
    -- status line says so. A force kills after the grace, as before. A PTY
    -- window has no loop that could answer: every close of it is a force.
    local function close_window(window, how: any?)
        local mode = how == "force" and "force" or "request"
        if window.entry == PTY_WINDOW then mode = "force" end
        if window.closing then
            -- Shutdown over a pending request: it stops waiting for a yes.
            if mode == "force" then window.close_how = "force" end
            return
        end
        window.closing = true
        window.close_how = mode
        -- A dialog without its window is an orphan: it is declared as
        -- belonging to a number that no longer exists, and an object stays on
        -- the desktop whose origin nobody remembers.
        --
        -- The cascade here and in `forget` is not a duplicate: this one
        -- closes the dialogs AT ONCE, while that one catches a window that
        -- died on its own. Without this one a dialog would hang on the
        -- desktop for the whole polite grace — up to three seconds after its
        -- window was asked to close.
        for _, child in ipairs(children_of(window.id)) do close_window(child, mode) end

        -- Both transports receive close and the same grace period for cleanup.
        if window.content == "pixels" then
            if window.state_pid then
                process.send(tostring(window.state_pid), "window.input", {id = window.id, event = {type = "close"}})
                window.deadline = time.after(CLOSE_GRACE)
            else forget(window) end
            return
        end

        if window.ready then
            window.view:send({type = "close"})
            window.deadline = time.after(CLOSE_GRACE)
        else
            process.terminate(tostring(window.pid))
        end
    end

    forget = function(window)
        if type(chrome.forget) == "function" then chrome.forget(window.id) end
        local index = index_of(window.id)
        if index > 0 then table.remove(windows, index) end
        if window.view then window.view:close() end
        -- The window may have died on its own without waiting for the polite
        -- close: its dialogs would stay on the desktop tied to a number that
        -- does not exist.
        -- A dialog of a window that is gone may not refuse: force.
        for _, child in ipairs(children_of(window.id)) do close_window(child, "force") end
    end

    local function request_quit()
        quitting = true
        menu = nil
        drag.active = false
        -- Closing a view can remove it and its children synchronously.
        local closing = {}
        for _, window in ipairs(windows) do closing[#closing + 1] = window end
        -- Shutdown does not ask: a window that would refuse is killed after
        -- the grace, or the desktop would never go away.
        for index = #closing, 1, -1 do close_window(closing[index], "force") end
    end

    -- raise_open(entry) -> whether a window of that entry was already open
    --
    -- The tray, the taskbar clock and desktop widgets name a window rather
    -- than launch a program: a second click must bring back the window the
    -- first one opened, minimised or covered, not open a second copy.
    local function raise_open(entry: any): boolean
        for _, candidate in ipairs(windows) do
            if candidate.entry == entry and not candidate.closing then
                candidate.minimized = false
                raise(candidate)
                return true
            end
        end
        return false
    end

    local function activate_menu_item(item: any)
        if item.action == "quit" then
            farewell_wanted = true
            request_quit()
            return
        end
        -- `raise` marks an item that names a window rather than a program to
        -- start again: Open in a widget's context menu does what its click does.
        if item.raise == true and raise_open(item.entry) then return end
        local window, err = open_window({
            entry = item.entry, title = item.title, w = item.w, h = item.h,
            args = item.args, window_type = item.window_type, image = item.image,
        }, nil)
        if window then raise(window)
        else notice = "could not open: " .. tostring(err) end
    end

    -- balloon_click(part) — `close`, the ×, dismisses the balloon; `open`, its
    -- body, opens the window it names (or raises the one already open, as a
    -- tray item does) and dismisses it. The balloon has no focus to give.
    local function balloon_click(part: any)
        local item: any = balloons.shown
        if item == nil then return end
        if part == "open" and type(item.entry) == "string" and item.entry ~= "" then
            if not raise_open(item.entry) then activate_menu_item({entry = item.entry, args = item.args}) end
        end
        next_balloon()
    end

    -- The context menu of a desktop icon: "Open" — the same as a double click,
    -- and "Properties" if the program declared a properties window
    -- (`meta.properties` on the entry — the theme puts it into the icon's hit).
    -- The items are the same tables as in the "Start" catalog, so they are
    -- opened by the same `activate_menu_item` and walked by the same keyboard
    -- and the same hover. An item's caption is `label`; `title` stays the title
    -- of the window the item opens.
    local function context_items(spot: any): any
        local items = {}
        if type(spot.entry) == "string" and spot.entry ~= "" then
            items[#items + 1] = {label = "Open", bold = true,
                entry = spot.entry, title = spot.title, w = spot.w, h = spot.h,
                args = spot.args, window_type = spot.window_type, image = spot.image}
        end
        if type(spot.properties) == "string" and spot.properties ~= "" then
            items[#items + 1] = {label = "Properties", entry = spot.properties,
                separator_before = #items > 0 or nil}
        end
        return items
    end

    -- resized_rect(window, w, h) -> {x, y, w, h}: the window at that size,
    -- clamped to the screen. One rule for the resize itself and for the
    -- outline a resize drag shows before its release.
    local function resized_rect(window, w: any, h: any): any
        if window.presentation then return {x=1,y=1,w=width,h=height} end
        local nw = clamp(tonumber(w) or window.w, MIN_W, width)
        local nh = clamp(tonumber(h) or window.h, MIN_H, desktop_height())
        return {w = nw, h = nh, x = clamp(window.x, 1, math.max(1, width - nw + 1)),
            y = clamp(window.y, desktop_top, math.max(desktop_top, height - nh))}
    end

    local function resize_window(window, w: any, h: any)
        local rect = resized_rect(window, w, h)
        window.w, window.h, window.x, window.y = rect.w, rect.h, rect.x, rect.y
        -- A view has no viewport: its size is just numbers the theme draws by
        -- in the next frame.
        if window.view then
            window.view:resize(window.w - (window.presentation and 0 or FRAME_W), window.h - (window.presentation and 0 or FRAME_H))
        elseif window.state_pid then
            process.send(tostring(window.state_pid), "window.input", {id = window.id, event = {
                type = "resize", width = window.w - (window.presentation and 0 or FRAME_W), height = window.h - (window.presentation and 0 or FRAME_H),
                cell_w = cell_w, cell_h = cell_h,
            }})
        end
    end

    local function toggle_maximize(window)
        -- A fixed-size window is not maximised: its layout is computed for one
        -- size, and on the full screen it would show a grey field around the
        -- buttons. The theme does not draw the button; an alt key and a command
        -- from outside run into this same check, so there is no way around it.
        if window.resizable == false then return end
        if window.maximized then
            local saved = window.saved
            window.maximized = false
            window.x = saved.x
            window.y = saved.y
            resize_window(window, saved.w, saved.h)
        else
            window.saved = {x = window.x, y = window.y, w = window.w, h = window.h}
            window.maximized = true
            window.x, window.y = 1, desktop_top
            resize_window(window, width, desktop_height())
        end
    end

    local function send_to(window: any, event)
        if not window or not window.ready or window.closing then return false end

        -- Input to a view window goes to its state provider: such a window no
        -- longer has a live part, and the view is a pure function that cannot
        -- take a click. What to do with it is decided by the provider, which
        -- answers with a new state.
        if window.content == "pixels" then
            if not window.state_pid then return false end
            local sent = process.send(tostring(window.state_pid), "window.input",
                {id = window.id, event = event})
            return sent and true or false
        end

        local ok = window.view:send(event)
        return ok and true or false
    end

    -- Focus changes reach the windows as the runtime's own terminal event,
    -- `{type = "focus", focused = …}` — the shape `tty.events()` delivers when
    -- the physical terminal gains or loses focus — so a window reads one event
    -- whatever moved the keyboard. Without it a window never learns it lost
    -- the keyboard: an armed button or a captured scrollbar waits for a
    -- release that now goes to another window (shell sdk-review A11).
    --
    -- The loser hears first, then the winner. The winner is remembered only
    -- once the send succeeded: a window that has not drawn its first frame is
    -- not `ready`, `send_to` drops the event, and it is told on the next frame
    -- instead of never. A PTY window forwards the event to its session, and
    -- the runtime's PTY proxy writes \e[I / \e[O only when the program inside
    -- asked for focus reports (mode 1004): bash gets nothing, vim its report.
    notify_focus = function()
        local top = focused()
        local now = top and top.id or nil
        if now == focus_seen.id then return end
        if focus_seen.id ~= nil then
            local before = find(focus_seen.id)
            focus_seen.id = nil
            if before then send_to(before, {type = "focus", focused = false}) end
        end
        if top and send_to(top, {type = "focus", focused = true}) then focus_seen.id = now end
    end

    -- ─── input ───────────────────────────────────────────────────────────

    local function hit(x, y)
        for index = #windows, 1, -1 do
            local window = windows[index]
            if not window.minimized and not window.closing
                and x >= window.x and x <= window.x + window.w - 1
                and y >= window.y and y <= window.y + window.h - 1 then
                return window
            end
        end
        return nil
    end

    -- The button under a point of the title. The theme computes it: only it
    -- knows the title row, the frame thickness and the set of buttons — three
    -- numbers that would have to be repeated here. The repetition has already
    -- cost a defect: the title moved inside the frame, the check stayed on the
    -- top edge, and the buttons stopped being hit at all.
    local function title_button_at(window, x, y)
        if type(chrome.title_button_at) == "function" then
            return chrome.title_button_at(window, x, y)
        end
        -- Fallback for a theme that does not compute the hit test.
        local step = math.tointeger(tonumber(chrome.BUTTON_STEP) or 3) or 3
        local span = math.tointeger(tonumber(chrome.BUTTONS_WIDTH) or 9) or 9
        if step < 1 then step = 1 end
        if window.w < span + 6 then return nil end
        local from = window.x + window.w - 1 - span
        if x < from or x > from + span - 1 then return nil end
        local slot = math.tointeger((x - from) // step) or 0
        -- A theme without a button table is no reason to crash: only one that
        -- does not compute the hit test itself reaches this branch, and a
        -- missed button is cheaper than a blacked-out desktop.
        local set: any = chrome.BUTTONS
        local button: any = type(set) == "table" and set[slot + 1] or nil
        return button and button.id or nil
    end

    local client_capture: any = nil
    local function client_pointer(window: any, event: any)
        return send_to(window, {type = "mouse", action = event.action, button = event.button,
            x = event.x - window.x - (window.presentation and 0 or insets.left) + 1,
            y = event.y - window.y - (window.presentation and 0 or insets.top) + 1,
            alt = event.alt, ctrl = event.ctrl, shift = event.shift})
    end
    -- Plain motion — no button held, nothing captured — goes to the focused
    -- window when the pointer is over its client, once per cell: an SDK menu
    -- follows the pointer by it, as the Start menu does here. Over the frame,
    -- another window or the desktop nothing is sent, and leaving the client
    -- forgets the cell, so coming back to it is news again. The last cell lives
    -- on the window record, not in an upvalue: an error under pcall in go-lua
    -- splits upvalues from their owner.
    local function pointer_motion(event: any)
        local window: any = focused()
        if not window then return end
        local left = math.tointeger(insets.left) or 1
        local top = math.tointeger(insets.top) or 1
        if event.x < window.x + left or event.x >= window.x + window.w - (math.tointeger(insets.right) or 1)
            or event.y < window.y + top or event.y >= window.y + window.h - (math.tointeger(insets.bottom) or 1) then
            window.motion_cell = nil
            return
        end
        local x, y = event.x - window.x - left + 1, event.y - window.y - top + 1
        local cell = tostring(x) .. ":" .. tostring(y)
        if window.motion_cell == cell then return end
        if send_to(window, {type = "mouse", action = "motion", button = event.button, x = x, y = y,
            alt = event.alt, ctrl = event.ctrl, shift = event.shift}) then
            window.motion_cell = cell
        end
    end
    -- Hovering in an open menu. The row under the mouse becomes selected at
    -- once, while the cascade — a folder opens, a submenu deeper than the row
    -- closes — waits HOVER_DELAY: "going to the submenu" and "moved to the
    -- neighbouring row" are the same in the first motion event and differ
    -- only in where the mouse will be a moment later.
    --
    -- The cursor lives on the deepest open level — the same as with the
    -- arrows. So a folder that is already open does not take the cursor: the
    -- choice goes on in its panel, and the folder itself is drawn open.
    local function menu_spot_at(x, y)
        for _, spot in ipairs(menu_hits) do
            if spot.slot ~= nil and y >= spot.row and y <= (spot.bottom_row or spot.row)
                and x >= spot.from and x <= spot.to then
                return spot
            end
        end
        return nil
    end

    local function same_path(left: any, right: any)
        if type(left) ~= "table" or type(right) ~= "table" then return false end
        if #left ~= #right then return false end
        for index = 1, #left do
            if left[index] ~= right[index] then return false end
        end
        return true
    end

    local function hover_menu(x, y)
        local spot: any = menu_spot_at(x, y)
        if spot == nil then return end
        local level = math.tointeger(spot.level) or 1
        local open: any = type(menu.open) == "table" and menu.open or {}
        local folder = type(spot.open) == "table"
        -- What must be open while the mouse is over this row: for a folder —
        -- the folder itself, for an item — everything up to its level.
        local wanted: any = {}
        if folder then
            wanted = spot.open
        else
            for index = 1, level - 1 do wanted[index] = open[index] end
        end
        if same_path(open, wanted) then
            menu.pending = nil
            hover_timer = nil
            if not folder
                and (math.tointeger(menu.cursor) or 0) ~= (math.tointeger(spot.slot) or 0) then
                menu.cursor = spot.slot
                draw()
            end
            return
        end
        local pending: any = menu.pending
        if pending and same_path(pending.open, wanted) then return end
        -- A folder opened by hovering selects nothing in the submenu: cursor
        -- 0 is "no row", enter on it is silent, the down arrow goes to the
        -- first row.
        menu.pending = {open = wanted, cursor = folder and 0 or spot.slot}
        hover_timer = time.after(HOVER_DELAY)
    end

    local function settle_hover()
        hover_timer = nil
        if menu == nil then return end
        local pending: any = menu.pending
        menu.pending = nil
        if pending == nil then return end
        menu.open = pending.open
        menu.cursor = pending.cursor
        draw()
    end

    -- The balloon's hit under a point, or nil. The balloon lies over the
    -- windows: a right press or the wheel on it must not reach the window
    -- beneath.
    local function balloon_spot(x: any, y: any): any
        for _, spot in ipairs(bar_hits) do
            if spot.balloon ~= nil and y >= spot.row and y <= (spot.bottom_row or spot.row)
                and x >= spot.from and x <= spot.to then
                return spot
            end
        end
        return nil
    end

    local function handle_mouse(event)
        local top = focused()
        local moved = pointer.x ~= nil and (event.x ~= pointer.x or event.y ~= pointer.y)
        pointer.x,pointer.y = event.x,event.y
        if top and top.presentation then
            if top.presentation_interactive then
                client_pointer(top, event)
                return
            end
            -- The release that opened a preview and duplicate pointer reports
            -- do not dismiss it. The closing gesture never reaches its parent.
            if event.action == "press" or event.action == "wheel" or (event.action == "motion" and moved) then
                top.minimized = true
                close_window(top,"force")
                draw()
            end
            return
        end
        if client_capture and (event.action == "motion" or event.action == "release") then
            local target = find(client_capture)
            if target and not target.minimized then client_pointer(target, event) end
            if event.action == "release" or not target then client_capture = nil end
            return
        end
        if event.action == "motion" and drag.active and drag.mode == "icon" then
            local item = desktop_item(drag.id)
            if not item then drag.active = false; return end
            item.x = clamp(event.x - drag.dx, 1, width)
            item.y = clamp(event.y - drag.dy, desktop_top, desktop_last)
            draw()
            return
        end

        if event.action == "motion" and drag.active then
            local window = find(drag.id)
            if not window then drag.active = false; return end
            -- Only the outline follows the pointer (`drag_outline`); the
            -- window takes the rect on the release. The resize keeps G2's
            -- offset from the corner (`drag.dx`).
            if drag.mode == "move" then
                drag.pending = {w = window.w, h = window.h,
                    x = clamp(event.x - drag.dx, 1, math.max(1, width - window.w + 1)),
                    y = clamp(event.y - drag.dy, desktop_top, math.max(desktop_top, height - window.h))}
            else
                drag.pending = resized_rect(window, event.x + drag.dx - window.x + 1, event.y + drag.dy - window.y + 1)
            end
            draw()
            return
        end

        if event.action == "motion" then
            if menu and not drag.active and not quitting then hover_menu(event.x, event.y) end
            -- The Start menu lies over the windows: while it is open the
            -- pointer is its.
            if not menu and not quitting then pointer_motion(event) end
            return
        end

        if event.action == "release" then
            if drag.active and drag.mode == "icon" then
                drag.active = false
                local item = desktop_item(drag.id)
                if item then
                    local gw, gh, gl = icon_grid()
                    item.x = snap(item.x, gw, gl)
                    item.y = snap(item.y, gh, desktop_top)
                    -- A dragged icon stops being auto-placed — but only if
                    -- the place was written: otherwise it went back to the
                    -- old one, and the old one was auto-placed.
                    local was_auto = item.auto
                    item.auto = nil
                    if move_item then
                        local ok, err = move_item(drag.id, item.x, item.y)
                        if not ok then
                            item.auto = was_auto
                            -- The icon must go back where it was taken from:
                            -- otherwise until the restart it is in the new
                            -- place, and after it in the old one, and the
                            -- person decides that the restart lost it.
                            item.x, item.y = drag.from_x, drag.from_y
                            notice = "the icon did not move: " .. tostring(err)
                        end
                    end
                end
                draw()
                return
            end
            if drag.active then
                -- The release applies the outline: one move, one resize (and
                -- one resize event to the program inside), however long the drag.
                drag.active = false
                local window = find(drag.id)
                local pending: any = drag.pending
                drag.pending = nil
                if window and pending then
                    if drag.mode == "resize" then resize_window(window, pending.w, pending.h)
                    else window.x, window.y = pending.x, pending.y end
                end
                draw()
            end
            return
        end

        if event.action == "wheel" then
            if menu or quitting or balloon_spot(event.x, event.y) then return end
            local window = hit(event.x, event.y)
            if window and event.x >= window.x + insets.left
                and event.x < window.x + window.w - insets.right
                and event.y >= window.y + insets.top
                and event.y < window.y + window.h - insets.bottom then
                send_to(window, {
                    type = "mouse", action = "wheel", button = event.button,
                    x = event.x - window.x - insets.left + 1,
                    y = event.y - window.y - insets.top + 1,
                    shift = event.shift, alt = event.alt, ctrl = event.ctrl,
                })
            end
            return
        end
        if event.action ~= "press" or quitting then return end

        -- The chrome listens only to the LEFT button: the right one on the
        -- title closed the window, on "Start" it opened the menu. The right
        -- and middle buttons go to the window under the pointer, into its
        -- body — programs expect them there.
        if event.button ~= "left" then
            if menu or balloon_spot(event.x, event.y) then return end
            local window = hit(event.x, event.y)
            if window and event.x >= window.x + insets.left
                and event.x < window.x + window.w - insets.right
                and event.y >= window.y + insets.top
                and event.y < window.y + window.h - insets.bottom then
                send_to(window, {
                    type = "mouse", action = event.action, button = event.button,
                    x = event.x - window.x - (math.tointeger(insets.left) or 1) + 1,
                    y = event.y - window.y - (math.tointeger(insets.top) or 1) + 1,
                    alt = event.alt, ctrl = event.ctrl, shift = event.shift,
                })
                return
            end
            -- The right button on a desktop icon — a context menu at the
            -- pointer. It is the same menu as "Start", only with a flat list
            -- and an anchor: the theme puts the panel at the anchor, not
            -- above the taskbar.
            if event.button == "right" and not window then
                local spot: any = desktop_spot(event.x, event.y)
                local items: any = {}
                if spot and spot.widget ~= nil then
                    -- A widget (FR-006 §5): Open when it names a window, and
                    -- nothing otherwise — not the desktop's Properties, which
                    -- the empty-desktop branch below would give a widget
                    -- record without an id. No selection either.
                    if type(spot.entry) == "string" and spot.entry ~= "" then
                        items = {{label = "Open", bold = true, entry = spot.entry, raise = true}}
                    end
                elseif spot and spot.id then
                    selected_id = spot.id
                    items = context_items(spot)
                elseif event.y >= desktop_top and event.y <= desktop_last then
                    selected_id = nil
                    if type(options.desktop_menu) == "function" then
                        local ok, found, why = pcall(options.desktop_menu)
                        if ok and type(found) == "table" then items = found end
                        if not ok then notice = "Desktop menu: " .. tostring(found)
                        elseif why then notice = tostring(why) end
                    elseif type(desktop_properties) == "string" and desktop_properties ~= "" then
                        items = {{label = "Properties", entry = desktop_properties}}
                    end
                end
                if #items > 0 then
                    menu = {items = items, failure = nil, open = {}, cursor = 1,
                        anchor = {x = event.x, y = event.y}}
                end
                draw()
            end
            return
        end

        -- An open menu takes the whole click: an item hit — it is opened, a
        -- miss — the menu closes. Otherwise a click "past the menu" would go
        -- to the window under it, and the menu would stay hanging over the
        -- result.
        if menu then
            -- The click decides by itself: the cascade the hover was waiting
            -- for must not change right after it.
            menu.pending = nil
            hover_timer = nil
            for _, spot in ipairs(menu_hits) do
                if event.y >= spot.row and event.y <= (spot.bottom_row or spot.row)
                    and event.x >= spot.from and event.x <= spot.to then
                    -- A folder carries the FULL path from the root, so the
                    -- compositor does not need to parse the tree and remember
                    -- where it is: it puts the path and draws again.
                    if type(spot.open) == "table" then
                        menu.open = spot.open
                        draw()
                        return
                    end
                    local item = menu.items[spot.index]
                    if item then
                        -- The menu, a shortcut and alt+n are the compositor
                        -- itself, not a window: what is opened here belongs to
                        -- nobody.
                        activate_menu_item(item)
                    end
                    menu = nil
                    draw()
                    return
                end
            end
            menu = nil
            draw()
            return
        end

        -- The chrome bars: a window button raises and restores the window, the
        -- menu button opens and closes the catalog.
        for _, spot in ipairs(bar_hits) do
            if event.y >= spot.row and event.y <= (spot.bottom_row or spot.row)
                    and event.x >= spot.from and event.x <= spot.to then
                -- The balloon tip (`balloon = "close" | "open"`): the theme
                -- puts its hits among the bars, before the windows.
                if spot.balloon ~= nil then
                    balloon_click(spot.balloon)
                    draw()
                elseif spot.id then
                    local window = find(spot.id)
                    if window then
                        window.minimized = false
                        raise(window)
                        draw()
                    end
                elseif spot.action == "menu" then
                    if menu then
                        menu = nil
                    else
                        local items, failure = catalog()
                        menu = {items = items, failure = failure, open = {}, cursor = 1}
                    end
                    draw()
                elseif type(spot.entry) == "string" and spot.entry ~= "" then
                    if not raise_open(spot.entry) then activate_menu_item(spot) end
                    draw()
                end
                return
            end
        end

        local window = hit(event.x, event.y)
        if not window then
            -- An empty spot: under the windows lies the desktop with icons. A
            -- single click selects and picks up an icon, a double click opens
            -- it.
            notice = ""
            -- `any`: after the widget branch below the linter narrows a plain
            -- local to `false?` and then refuses every field of an icon.
            local spot: any = desktop_spot(event.x, event.y)
            -- A widget is not an icon (FR-006 §5): a press opens the window it
            -- names, or raises the one already open, as a tray caption does.
            -- No selection, no drag and no double-click bookkeeping.
            if spot and spot.widget ~= nil then
                if type(spot.entry) == "string" and spot.entry ~= "" and not raise_open(spot.entry) then
                    -- Only the entry: the record's title, w and h describe the
                    -- widget, not the window it opens.
                    activate_menu_item({entry = spot.entry})
                end
                draw()
                return
            end

            local moment = time.now():unix_nano()
            local repeated = last_click.x == event.x and last_click.y == event.y
                and (moment - last_click.at) < 500000000
            last_click = {x = event.x, y = event.y, at = moment}

            if not spot then
                if selected_id then selected_id = nil; draw() end
                return
            end

            if spot.id then selected_id = spot.id end

            if repeated then
                if type(spot.entry) == "string" and spot.entry ~= "" then
                    local opened = open_window({
                        entry = spot.entry, title = spot.title,
                        w = spot.w, h = spot.h, args = spot.args,
                        window_type = spot.window_type,
                    }, nil)
                    if opened then raise(opened) end
                end
                draw()
                return
            end

            local item = spot.id and desktop_item(spot.id) or nil
            if item then
                local at_x = math.tointeger(tonumber(item.x) or event.x) or event.x
                local at_y = math.tointeger(tonumber(item.y) or event.y) or event.y
                drag = {active = true, id = spot.id, mode = "icon",
                    dx = event.x - at_x, dy = event.y - at_y,
                    from_x = at_x, from_y = at_y}
            end
            draw()
            return
        end
        raise(window)

        -- The title bar takes the whole top inset: for a theme with a frame
        -- around the title that is not one row.
        if event.y < window.y + (math.tointeger(insets.top) or 1) then
            local button = title_button_at(window, event.x, event.y)
            if button == "close" then close_window(window)
            elseif button == "minimize" then window.minimized = true
            elseif button == "maximize" then toggle_maximize(window)
            elseif button then
                -- A button the compositor does not know — for example "help"
                -- on a dialog. There is nothing to do, but a drag must not
                -- start either: the window would move away from a click on a
                -- button.
                drag.active = false
            else
                drag = {active = true, id = window.id, mode = "move",
                    dx = event.x - window.x, dy = event.y - window.y}
            end
            draw()
            return
        end

        -- The bottom-right corner of the frame drags the size, if the entry
        -- allows it: the last TWO cells of the bottom row, where the theme
        -- draws the Windows 95 sizing grip (13×13 px reaches into the second
        -- cell at a 10×20 cell). `dx` is how far the press is from the corner,
        -- so a window taken by the second-to-last cell does not lose a column
        -- on the first motion.
        local corner_x = window.x + window.w - 1
        if window.resizable ~= false and event.y == window.y + window.h - 1
            and event.x >= corner_x - 1 and event.x <= corner_x then
            drag = {active = true, id = window.id, mode = "resize", dx = corner_x - event.x, dy = 0}
            draw()
            return
        end

        -- The window body: the click goes inside, in the window's own
        -- coordinates.
        if event.x < window.x + insets.left or event.x >= window.x + window.w - insets.right
            or event.y < window.y + insets.top or event.y >= window.y + window.h - insets.bottom then return end
        client_capture = window.id
        send_to(window, {
            type = "mouse", action = event.action, button = event.button,
            x = event.x - window.x - (math.tointeger(insets.left) or 1) + 1,
            y = event.y - window.y - (math.tointeger(insets.top) or 1) + 1,
            alt = event.alt, ctrl = event.ctrl, shift = event.shift,
        })
        draw()
    end

    -- Accelerators sit on alt: ctrl and tab are needed too often by the
    -- programs in the windows themselves, and stealing them means breaking
    -- the editor inside. The application's window catalog. Read when the menu
    -- opens, not at start: an application may declare a window without a
    -- desktop restart.
    catalog = function()
        if read_catalog then
            local items, failure = read_catalog()
            return type(items) == "table" and items or {}, failure
        end
        local found, err = registry.find({["meta.type"] = WINDOW_META_TYPE})
        if err then return {}, tostring(err) end
        if type(found) ~= "table" then return {}, "the registry did not answer with a list" end
        -- Hidden ones (`meta.in_menu: false`) do not get here, an unknown
        -- type counts as an ordinary window. A typo in the type is no reason
        -- not to show the program, but keeping quiet about it is not allowed
        -- either — otherwise it lives forever.
        local items, warnings = programs.menu(found)
        for _, warning in ipairs(warnings) do
            log:warn("unknown window type", {
                entry = warning.entry, window_type = warning.window_type,
                used = programs.DEFAULT_TYPE,
            })
        end
        return items, nil
    end

    -- ─── menu arrows ─────────────────────────────────────────────────────
    --
    -- The cursor walks the HIT LAYOUT, not the catalog: what gets selected is
    -- what is drawn. Computing the choice anew would mean keeping a second
    -- notion of where the rows are, and one day the cursor would move over rows
    -- that are not on the screen.

    -- The rows of the deepest open panel — those the cursor moves between. A
    -- panel further left is open, but the choice goes on in the one opened
    -- last.
    local function menu_rows()
        local deepest = 0
        for _, spot in ipairs(menu_hits) do
            local level = math.tointeger(spot.level) or 1
            if spot.slot ~= nil and level > deepest then deepest = level end
        end
        local rows = {}
        for _, spot in ipairs(menu_hits) do
            if spot.slot ~= nil and (math.tointeger(spot.level) or 1) == deepest then
                rows[#rows + 1] = spot
            end
        end
        table.sort(rows, function(left, right)
            return (math.tointeger(left.slot) or 0) < (math.tointeger(right.slot) or 0)
        end)
        return rows
    end

    -- The row under the cursor. First the one the theme MARKED, and only then
    -- the one whose number matched: the mark is the only thing that links our
    -- number to what is drawn.
    local function menu_cursor_spot()
        local rows = menu_rows()
        for _, spot in ipairs(rows) do
            if spot.cursor == true then return spot end
        end
        local wanted = math.tointeger(menu.cursor) or 1
        for _, spot in ipairs(rows) do
            if (math.tointeger(spot.slot) or 0) == wanted then return spot end
        end
        return nil
    end

    local function move_menu_cursor(step)
        local rows = menu_rows()
        if #rows == 0 then return false end
        local wanted = math.tointeger(menu.cursor) or 1
        local at = 0
        for index, spot in ipairs(rows) do
            if (math.tointeger(spot.slot) or 0) == wanted then at = index end
        end
        if at == 0 then at = step > 0 and 0 or 1 end
        local next_at = at + step
        if next_at < 1 then next_at = #rows end
        if next_at > #rows then next_at = 1 end
        menu.cursor = math.tointeger(rows[next_at].slot) or 1
        return true
    end

    local function open_menu_item(spot: any)
        local item: any = menu.items[math.tointeger(spot.index) or 0]
        if not item then return false end
        activate_menu_item(item)
        return true
    end

    -- ─── desktop arrows ──────────────────────────────────────────────────

    -- Icons from the hit layout: an icon with a caption has several hits (the
    -- picture row and the caption rows), but the icon is one — so they are
    -- merged by id, and the topmost row is taken as its place.
    local function icon_spots()
        local seen: any = {}
        local spots = {}
        for _, hit in ipairs(desk_hits) do
            local id = hit.id
            -- Widget records share the desktop group but are not icons: the
            -- arrows walk the icon grid only (FR-006 §5).
            if type(id) == "string" and id ~= "" and hit.widget == nil then
                local row = math.tointeger(hit.row) or 0
                local col = math.tointeger(hit.from) or 0
                local at = seen[id]
                if at == nil then
                    spots[#spots + 1] = {id = id, row = row, col = col, hit = hit}
                    seen[id] = #spots
                else
                    local kept: any = spots[at]
                    if row < kept.row then kept.row = row end
                end
            end
        end
        return spots
    end

    local function move_selection(dx, dy)
        local spots = icon_spots()
        if #spots == 0 then return false end

        local current: any = nil
        for _, spot in ipairs(spots) do
            if spot.id == selected_id then current = spot end
        end
        -- Nothing selected — the first arrow selects rather than moves.
        if current == nil then
            selected_id = spots[1].id
            return true
        end

        local best: any = nil
        local best_score = 0
        for _, spot in ipairs(spots) do
            if spot.id ~= current.id then
                local drow = spot.row - current.row
                local dcol = spot.col - current.col
                local forward = false
                local score = 0
                if dy ~= 0 and drow * dy > 0 then
                    forward = true
                    score = math.abs(drow) * 1000 + math.abs(dcol)
                elseif dx ~= 0 and dcol * dx > 0 and drow == 0 then
                    forward = true
                    score = math.abs(dcol) * 1000 + math.abs(drow)
                end
                if forward and (best == nil or score < best_score) then
                    best, best_score = spot, score
                end
            end
        end

        if best == nil then return false end
        selected_id = best.id
        return true
    end

    local function open_selected_icon()
        for _, hit in ipairs(desk_hits) do
            if hit.id == selected_id and hit.widget == nil
                and type(hit.entry) == "string" and hit.entry ~= "" then
                local opened = open_window({
                    entry = hit.entry, title = hit.title,
                    w = hit.w, h = hit.h, args = hit.args,
                    window_type = hit.window_type,
                }, nil)
                if opened then raise(opened) end
                return true
            end
        end
        return false
    end

    local function handle_key(event)
        local top = focused()
        if top and top.presentation then
            -- Interactive presentations own input; Esc always returns to the desktop.
            if top.presentation_interactive and event.key_type ~= "esc" then return "forward" end
            if event.action ~= "release" then top.minimized = true; close_window(top,"force"); draw() end
            return "handled"
        end
        if event.ctrl and event.key == "q" then
            request_quit()
            if #windows == 0 then return "quit" end
            draw()
            return "handled"
        end
        if quitting then return "handled" end
        -- Esc during a move or resize drops the outline: the window stays
        -- where it was, as in Windows 95.
        if drag.active and drag.mode ~= "icon" and event.key_type == "esc" then
            drag.active, drag.pending = false, nil
            draw()
            return "handled"
        end
        if menu then
            menu.pending = nil
            hover_timer = nil
            if event.key_type == "esc" then
                menu = nil
                draw()
                return "handled"
            end

            if event.key_type == "up" then
                if move_menu_cursor(-1) then draw() end
            elseif event.key_type == "down" then
                if move_menu_cursor(1) then draw() end
            elseif event.key_type == "right" then
                -- A folder opens to the right: the whole path is put, as on a
                -- click — the compositor does not remember the tree.
                local spot = menu_cursor_spot()
                if spot and type(spot.open) == "table" then
                    menu.open = spot.open
                    menu.cursor = 1
                    draw()
                end
            elseif event.key_type == "left" then
                local open: any = menu.open
                if type(open) == "table" and #open > 0 then
                    local shorter = {}
                    for index = 1, #open - 1 do shorter[index] = open[index] end
                    menu.open = shorter
                    menu.cursor = 1
                    draw()
                end
            elseif event.key_type == "enter" then
                local spot = menu_cursor_spot()
                if spot == nil then
                    -- The theme did not mark the selected row: enter would be
                    -- silent, and a silent key is indistinguishable from a
                    -- broken menu. Cursor 0 is different: no row is selected,
                    -- the folder was opened by hovering.
                    if (math.tointeger(menu.cursor) or 0) > 0 then
                        notice = "the theme did not mark the selected menu row"
                        draw()
                    end
                elseif type(spot.open) == "table" then
                    menu.open = spot.open
                    menu.cursor = 1
                    draw()
                else
                    if open_menu_item(spot) then menu = nil end
                    draw()
                end
            end

            -- An open menu takes all input: otherwise the key would go to the
            -- window under it.
            return "handled"
        end

        -- The arrows belong to the desktop only when no window has the focus.
        -- Otherwise the desktop would steal them from an editor inside a
        -- window — and that is exactly the key theft because of which the
        -- accelerators here sit on alt.
        if focused() == nil then
            if event.key_type == "up" then
                if move_selection(0, -1) then draw() end
                return "handled"
            elseif event.key_type == "down" then
                if move_selection(0, 1) then draw() end
                return "handled"
            elseif event.key_type == "left" then
                if move_selection(-1, 0) then draw() end
                return "handled"
            elseif event.key_type == "right" then
                if move_selection(1, 0) then draw() end
                return "handled"
            elseif event.key_type == "enter" and selected_id then
                if open_selected_icon() then draw() end
                return "handled"
            end
        end

        if event.alt then
            local top = focused()
            if event.key == "n" then
                local window, err = open_window({}, nil)
                if window then raise(window) end
                -- Said on the desktop, not only in the log: a person refused a
                -- shell would otherwise see a key that does nothing.
                if err then
                    notice = "could not open: " .. tostring(err)
                    log:error("window did not open", {error = tostring(err)})
                end
                draw()
                return "handled"
            elseif event.key == "w" and top then
                close_window(top); draw(); return "handled"
            elseif event.key == "m" and top then
                top.minimized = true; draw(); return "handled"
            elseif event.key == "o" then
                local items, failure = catalog()
                menu = {items = items, failure = failure, open = {}, cursor = 1}
                draw()
                return "handled"
            elseif event.key_type == "tab" and #windows > 1 then
                local bottom = windows[1]
                bottom.minimized = false
                raise(bottom); draw(); return "handled"
            end
        end

        return "forward"
    end

    -- ─── commands from outside ───────────────────────────────────────────

    local function describe(window)
        return {
            id = window.id, entry = window.entry, title = window.title, command = window.command,
            -- The window's process: whoever watches a desktop close can see
            -- its windows go, not only the desktop.
            pid = window.pid ~= nil and tostring(window.pid) or nil,
            image = window.image,
            args = window.args,
            window_type = window.window_type,
            opened_by = window.opened_by,
            -- What draws the content and whether it has got its data. From
            -- outside this is the only way to tell "the view is waiting for
            -- state" from "the view is drawn empty": on screen they are the
            -- same.
            content = window.content,
            waiting = window.waiting == true,
            state_revision = window.state_revision,
            -- The view's caption (`content_state.caption`) — the little a view
            -- tells about itself in words. From outside this is the only way to
            -- learn that a scroll or an expand reached the provider without
            -- looking at the pixels.
            caption = type(window.content_state) == "table"
                and type(window.content_state.caption) == "string"
                and window.content_state.caption or nil,
            resizable = window.resizable ~= false,
            x = window.x, y = window.y, width = window.w, height = window.h,
            ready = window.ready, minimized = window.minimized,
            maximized = window.maximized, closing = window.closing,
            presentation = window.presentation == true,
            presentation_interactive = window.presentation_interactive == true,
            -- A flashing window (`desktop.flash`) and which look it shows now.
            flashing = window.flashing == true, flash_lit = window.flash_lit == true,
        }
    end

    -- A reply always names the command it answers. Without this field the asker
    -- matches a reply to a question by order alone — and a refusal that arrived
    -- on its own (see `refuse`) breaks that order.
    -- The path of the open folder as a string: the command channel gives it
    -- out, and a person reads a string without parsing tables.
    local function menu_path_text()
        if menu == nil then return nil end
        local open: any = menu.open
        if type(open) ~= "table" then return "" end
        local parts = {}
        for _, name in ipairs(open) do parts[#parts + 1] = tostring(name) end
        return table.concat(parts, "/")
    end

    -- How many rows are on the deepest level and how many of them are folders.
    -- Computed from the HIT LAYOUT, like everything about the menu: it is what
    -- is drawn. Declared in advance because the command channel's reply calls
    -- them, and they compute from `menu_hits`, which is already assembled by
    -- then.
    local function menu_level_rows()
        local deepest = 0
        for _, spot in ipairs(menu_hits) do
            local level = math.tointeger(spot.level) or 1
            if spot.slot ~= nil and level > deepest then deepest = level end
        end
        local rows = {}
        for _, spot in ipairs(menu_hits) do
            if spot.slot ~= nil and (math.tointeger(spot.level) or 1) == deepest then
                rows[#rows + 1] = spot
            end
        end
        return rows
    end

    local function menu_choices_count()
        if menu == nil then return nil end
        return #menu_level_rows()
    end

    local function menu_folders_count()
        if menu == nil then return nil end
        local folders = 0
        for _, spot in ipairs(menu_level_rows()) do
            if type(spot.open) == "table" then folders = folders + 1 end
        end
        return folders
    end

    local function reply(body: any, to, topic)
        if to == "" then return end
        body.command = topic
        process.send(to, REPLY_TOPIC, body)
    end

    -- A refusal of a command nobody is waiting for.
    --
    -- Commands from a window come without a return address: the window does not
    -- wait for a reply, so as not to freeze its frame. So "no such window" and
    -- "unknown command" went NOWHERE, and a typo in an id looked like an
    -- executed command.
    --
    -- Now a refusal has three recipients, and each is needed by its own reader:
    -- the status line — by the person at the desktop, the log — by whoever
    -- investigates later, and THE SENDER ITSELF — because a window has a reply
    -- channel and can receive the refusal there without freezing. The
    -- `unsolicited` mark is required: without it a refusal that arrived on its
    -- own would be taken for the reply to the next question.
    local function refuse(reason, to, topic, from: any)
        if to ~= "" then
            reply({ok = false, error = reason}, to, topic)
            return false
        end
        if from ~= nil then
            process.send(tostring(from), REPLY_TOPIC, {
                ok = false, error = reason, command = topic, unsolicited = true,
            })
        end
        notice = reason
        log:warn("command refused and nobody asked",
            {reason = reason, command = tostring(topic)})
        return true
    end

    local function handle_command(topic, body, from: any)
        -- What reads the frame reads the last state: the list reports what
        -- the painted hits and the frame meter say, the screen what is shown.
        if topic == "desktop.list" or topic == "desktop.screen" then flush() end
        local to = ""
        if type(body.reply_to) == "string" then to = body.reply_to end
        local window = find(type(body.id) == "string" and body.id or "")

        if topic == "desktop.list" then
            -- Expired items are removed here too: otherwise the list would
            -- report an item that is no longer on the screen, until the next
            -- clock tick.
            local pruned = prune_tray()
            local list = {}
            for _, item in ipairs(windows) do list[#list + 1] = describe(item) end
            local top = focused()
            reply({ok = true, windows = list, focused = top and top.id or nil,
                screen = {width = width, height = height},
                -- The name this desktop claimed: several run at once under a
                -- terminal.ssh host, one per connection.
                service = SERVICE_NAME,
                -- The cell size in pixels and the frame mode: the "Display
                -- Properties" window shows the resolution from them and
                -- cannot take them itself — the terminal answers only the
                -- compositor.
                cell = {w = cell_w, h = cell_h},
                pixels = PIXELS,
                -- Who logged on. Without this field "windows under the user"
                -- and "windows under the service actor" are indistinguishable
                -- from outside.
                user = IDENTITY and {id = IDENTITY.context.user_id, name = IDENTITY.context.user_name} or nil,
                -- The status line: the only place where a refusal is visible
                -- to a person. It is given out so that "the refusal was
                -- shown" can be checked rather than examined by eye.
                notice = notice,
                -- Whether the menu is open. From outside this is the only way
                -- to tell "the click on the menu button did not arrive" from
                -- "it arrived, but the menu could not be drawn": on screen
                -- both look the same.
                menu_open = menu ~= nil,
                -- The selected desktop icon: the arrows move exactly it, and
                -- from outside "the arrow did not work" is otherwise
                -- indistinguishable from "the icon is selected, but the theme
                -- did not draw that".
                selected = selected_id,
                -- The open menu folder, as a path from the root. Without it
                -- "the right arrow did not work" and "it worked, but the
                -- theme did not draw the submenu" look the same — both as
                -- zero bytes on the screen.
                menu_path = menu_path_text(),
                -- How many rows are on the current level and how many of them
                -- open. A third form of the same question: "right is silent"
                -- may mean "nothing to open", and there is no other way to
                -- tell — an empty menu and a menu without folders look the
                -- same on the screen.
                menu_choices = menu_choices_count(),
                menu_folders = menu_folders_count(),
                menu_context = (menu ~= nil and menu.anchor ~= nil) or false,
                -- The number of the selected row on the current level; 0 —
                -- none selected. Without it "the hover did not highlight" and
                -- "it highlighted, but the theme did not draw it" are one and
                -- the same frame.
                menu_cursor = menu and (math.tointeger(menu.cursor) or 0) or nil,
                -- The cost of the last frame: changed rows, rasters sent,
                -- bytes. The measure for §8 of FR-005 and the only way to
                -- notice that the chrome is sliced wrongly.
                -- Plus time: paint_ms/present_ms of the last frame, its cause
                -- and an avg/p95/max summary over the last FRAME_WINDOW.
                frame = frame_report(body.frame_samples == true),
                pixels = PIXELS,
                -- The tray with owners and time left: "the item did not
                -- appear" and "it appeared, but the theme did not draw it"
                -- are otherwise indistinguishable.
                tray = tray_view(true),
                -- Widgets without their trees: "not spawned", "waiting for
                -- its first state" and "stopped" differ here and nowhere else.
                widgets = widget_view(true), widget_failure = widgets.failure,
                -- The balloon on screen with its owner and time left, and how
                -- many wait: "not accepted", "waiting its turn" and "shown but
                -- not drawn" differ here and nowhere else.
                balloon = balloon_view(true),
                balloon_queue = #balloons.queue,
                -- The ids of the windows that flash.
                flashing = flashing_ids(),
                restore = restore_report}, to, topic)
            return pruned
        end

        -- A notification area item: `{key, text, entry?, title?, ttl?}` puts
        -- or updates it, `{key, remove = true}` removes it. A refusal names
        -- the reason — a provider whose item the tray silently did not show
        -- would decide that it had.
        if topic == "desktop.tray" then
            local accepted, why, changed = set_tray(body, from)
            if not accepted then return refuse(tostring(why), to, topic, from) end
            reply({ok = true, key = body.key, items = #tray.items}, to, topic)
            return changed
        end

        -- A balloon tip by the notification area:
        -- `{key?, title, text, icon?, image?, anchor?, entry?, args?, timeout?,
        -- bell?}` shows or queues it, `{key, remove = true}` dismisses it. The
        -- reply names the key (made up when none was given), whether it is
        -- shown, how many wait, and the timeout after the clamp.
        if topic == "desktop.balloon" then
            local accepted, why, changed, key, item = set_balloon(body, from)
            if not accepted then return refuse(tostring(why), to, topic, from) end
            local shown: any = balloons.shown
            reply({ok = true, key = key, shown = shown ~= nil and shown.key == key,
                queue = #balloons.queue, timeout = item ~= nil and item.timeout or nil}, to, topic)
            return changed
        end

        -- A flashing window: `{id?, count?, stop?}`. No id is the sender's own
        -- window, found by its process as a refused close is. A window that
        -- has the focus flashes only with a count: "until it is focused"
        -- would never end.
        if topic == "desktop.flash" then
            if body.id ~= nil and type(body.id) ~= "string" then
                return refuse("desktop.flash names a window by its id, a string", to, topic, from)
            end
            local target: any = window
            if body.id == nil or body.id == "" then
                target = window_of(from)
                if target == nil then
                    return refuse("desktop.flash names no window, and its sender is not a window of this desktop",
                        to, topic, from)
                end
            elseif target == nil then
                return refuse("no window " .. tostring(body.id), to, topic, from)
            end
            if body.stop == true then
                local was = target.flashing == true
                stop_flash(target)
                reply({ok = true, id = target.id, flashing = false}, to, topic)
                return was
            end
            local count: any = nil
            if body.count ~= nil then
                count = type(body.count) == "number" and math.tointeger(body.count) or nil
                if count == nil or count < 1 then
                    return refuse("a flash count is a whole number of cycles above zero", to, topic, from)
                end
            end
            local top = focused()
            if count == nil and top ~= nil and top.id == target.id then
                stop_flash(target)
                reply({ok = true, id = target.id, flashing = false, reason = "the window has the focus"}, to, topic)
                return false
            end
            start_flash(target, count)
            reply({ok = true, id = target.id, flashing = true}, to, topic)
            return true
        end

        -- The notice line: `{text, ttl?}` shows the text for ttl seconds; an
        -- empty text clears the line. The compositor's own notices keep
        -- working, and the latest wins.
        if topic == "desktop.notice" then
            local text: any = body.text
            if text ~= nil and type(text) ~= "string" then
                return refuse("a notice's text is a string", to, topic, from)
            end
            if text == nil or text == "" then
                notice = ""
                notice_clock.timer, notice_clock.text = nil, nil
                reply({ok = true}, to, topic)
                return true
            end
            if #runes(text) > NOTICE_TEXT then
                return refuse("the notice is longer than " .. NOTICE_TEXT .. " characters", to, topic, from)
            end
            local ttl = seconds(body.ttl, NOTICE_TTL, NOTICE_LEAST, NOTICE_MOST)
            if ttl == nil then return refuse("a notice's ttl is a number of seconds", to, topic, from) end
            notice = text
            notice_clock.text = text
            notice_clock.timer = after_seconds(ttl)
            reply({ok = true, ttl = ttl}, to, topic)
            return true
        end

        if topic == "desktop.refresh" then
            reload_desktop()
            -- Widgets follow the registry on the same command: new entries
            -- are spawned, vanished ones stopped, stopped ones respawned.
            local widget_failure = sync_widgets()
            reply({ok = widget_failure == nil, items = #desk.items, failure = desk.failure,
                widget_failure = widget_failure, error = widget_failure,
                widgets = #widgets.items}, to, topic)
            return true
        end

        -- A workshop window into the registry — on request from outside, with
        -- the same code as the restore at start. The MCP tool asks: the MCP
        -- session's scope forbids `registry.apply` with an explicit deny, and
        -- a tool that applied the entry itself would silently do nothing. The
        -- compositor runs under its own actor — it has this permission, and
        -- by that moment the row is already in storage.
        if topic == "desktop.workshop" then
            local name = type(body.name) == "string" and body.name or ""
            if name == "" then return refuse("window name not given", to, topic, from) end
            local entry_id = apps.entry_id(name)
            if body.remove == true then
                local removed, rerr = apps.remove(name)
                if not removed then return refuse("removing from the registry: " .. tostring(rerr), to, topic, from) end
                reply({ok = true, name = name, entry = entry_id, live = false}, to, topic)
                return false
            end
            local stored_window, gerr = repo.get(name)
            if gerr then return refuse("storage: " .. tostring(gerr), to, topic, from) end
            if not stored_window then return refuse("window " .. name .. " is not in storage", to, topic, from) end
            local applied, aerr = apps.apply(stored_window)
            if not applied then return refuse("applying: " .. tostring(aerr), to, topic, from) end
            reply({ok = true, name = name, entry = entry_id, live = registry.get(entry_id) ~= nil}, to, topic)
            return false
        end

        if topic == "desktop.open" then
            local opened, err = open_window(body, from)
            if not opened then return refuse(tostring(err), to, topic, from) end
            raise(opened)
            reply({ok = true, window = describe(opened)}, to, topic)
            return true
        end

        -- From here on only commands addressed to a specific window. The
        -- order of the checks here is not style: while "no window" came
        -- first, ANY unknown command answered "no window nil", the sender
        -- went looking for a typo in an id it never sent, and the branch for
        -- an unknown command was unreachable altogether.
        -- The state of a widget (FR-006 §3), accepted only from the process
        -- the compositor spawned for it — the rule of view windows: nobody
        -- else can draw into a widget. Widget ids are `g<n>`, never `w<n>`.
        -- So is its close: the SDK runner sends `desktop.close` with its id
        -- when its loop ends. From the widget's own process that is the widget
        -- stopping; answered "no window" it would sit in the status line as a
        -- refusal nobody made a mistake to earn.
        local widget: any = (topic == "desktop.state" or topic == "desktop.close") and widget_of(body.id) or nil
        if widget then
            if widget.pid == nil or from == nil or tostring(widget.pid) ~= tostring(from) then
                if topic == "desktop.close" then
                    return refuse("widget " .. widget.id .. " is closed only by its own process", to, topic, from)
                end
                return refuse("the state of widget " .. widget.id .. " is accepted only from its provider",
                    to, topic, from)
            end
            if topic == "desktop.close" then
                stop_widget(widget)
                reply({ok = true}, to, topic)
                return true
            end
            widget.content_state = body.state
            widget.waiting = false
            widget.state_revision = (math.tointeger(widget.state_revision) or 0) + 1
            reply({ok = true, revision = widget.state_revision}, to, topic)
            return true
        end

        -- A refused close (C2): the window's own process answers the `close`
        -- it got by staying — a changed document to save — and the request is
        -- over, with no "did not close" on the taskbar. The sender names the
        -- window: a cells window's runner does not know its id. Only that
        -- process may refuse; a given `id` must name the same window, and a
        -- forced close (shutdown) is not refused.
        if topic == "desktop.close" and body.refused == true then
            local own: any = nil
            for _, candidate in ipairs(windows) do
                if from ~= nil and ((candidate.pid ~= nil and tostring(candidate.pid) == tostring(from))
                    or (candidate.state_pid ~= nil and tostring(candidate.state_pid) == tostring(from))) then
                    own = candidate
                    break
                end
            end
            if own == nil or (type(body.id) == "string" and body.id ~= "" and body.id ~= own.id) then
                return refuse("only a window's own process may refuse its close", to, topic, from)
            end
            if own.close_how == "force" then
                return refuse("a forced close is not refused", to, topic, from)
            end
            own.closing = false
            own.close_how = nil
            own.deadline = nil
            reply({ok = true}, to, topic)
            return true
        end

        if not WINDOW_COMMANDS[topic] then
            return refuse("unknown command " .. tostring(topic), to, topic, from)
        end
        if not window then
            -- A silent "no such thing" would turn a typo in an id into a
            -- successful command.
            return refuse("no window " .. tostring(body.id), to, topic, from)
        end

        if topic == "desktop.close" then
            -- A request unless the sender says `force`: a window may refuse a
            -- request (it answers the `close` it gets by not closing).
            close_window(window, body.force == true and "force" or "request")
            reply({ok = true}, to, topic); return true
        elseif topic == "desktop.focus" then
            window.minimized = false; raise(window); reply({ok = true}, to, topic); return true
        elseif topic == "desktop.move" then
            window.x = clamp(body.x, 1, math.max(1, width - window.w + 1))
            window.y = clamp(body.y, desktop_top, math.max(desktop_top, height - window.h))
            reply({ok = true, window = describe(window)}, to, topic)
            return true
        elseif topic == "desktop.resize" then
            if window.resizable == false then
                return refuse("window " .. window.id .. " declared a fixed size",
                    to, topic, from)
            end
            resize_window(window, body.w, body.h)
            reply({ok = true, window = describe(window)}, to, topic)
            return true
        elseif topic == "desktop.minimize" then
            window.minimized = not not body.value
            reply({ok = true, window = describe(window)}, to, topic)
            return true
        elseif topic == "desktop.state" then
            -- The state is accepted ONLY from this window's provider.
            -- Otherwise the content of someone else's window could be
            -- replaced by anyone who knows the number — and a view drawn from
            -- planted data is indistinguishable from the real one.
            if window.content ~= "pixels" then
                return refuse("window " .. window.id .. " draws itself; it takes no state",
                    to, topic, from)
            end
            if window.state_pid == nil or from == nil
                or tostring(window.state_pid) ~= tostring(from) then
                return refuse("the state of window " .. window.id
                    .. " is accepted only from its provider", to, topic, from)
            end
            window.content_state = body.state
            if type(body.title) == "string" and body.title ~= "" then window.title = body.title end
            -- The title-bar picture, the same way: a name replaces it, no name
            -- (or an empty one) keeps the one the window has.
            if type(body.image) == "string" and body.image ~= "" then window.image = body.image end
            window.waiting = false
            window.state_revision = (math.tointeger(window.state_revision) or 0) + 1
            reply({ok = true, revision = window.state_revision}, to, topic)
            return true
        elseif topic == "desktop.screen" then
            -- A copy, not the array itself: the snapshot's rows are the
            -- broker's shared memory.
            local rows = {}
            for index, row in ipairs(window.rows) do rows[index] = row end
            reply({ok = true, id = window.id, rows = rows, ready = window.ready}, to, topic)
            return false
        elseif topic == "desktop.type" then
            if not window.ready then
                return refuse("window " .. window.id .. " does not take input yet", to, topic, from)
            end
            local sent = 0
            for _, char in ipairs(runes(type(body.text) == "string" and body.text or "")) do
                if send_to(window, {type = "key", key = char, key_type = "runes", action = "press"}) then
                    sent = sent + 1
                end
            end
            if body.enter then
                send_to(window, {type = "key", key = "enter", key_type = "enter", action = "press"})
            end
            reply({ok = true, sent = sent}, to, topic)
            return false
        elseif topic == "desktop.key" then
            local key = type(body.key) == "string" and body.key or ""
            if key == "" then return refuse("key not named", to, topic, from) end
            local ok = send_to(window, {
                type = "key", key = key, key_type = body.key_type or key,
                action = "press", ctrl = not not body.ctrl,
                alt = not not body.alt, shift = not not body.shift,
            })
            if not ok then return refuse("window " .. window.id .. " did not take the input", to, topic, from) end
            reply({ok = true}, to, topic)
            return false
        end

        -- Only a window command someone forgot to handle above gets here: the
        -- WINDOW_COMMANDS list and the branches must match.
        return refuse("command " .. tostring(topic) .. " is declared but not handled", to, topic, from)
    end

    -- ─── loop ────────────────────────────────────────────────────────────

    local function tick_clock()
        local now = time.now()
        local text = now and now:format("15:04") or ""
        if text == clock then return false end
        clock = text
        return true
    end

    tick_clock()
    reload_desktop()
    -- After logon (above): a widget's process runs under the user, like a window.
    sync_widgets()
    draw()

    local ticker = time.after(CLOCK_TICK)

    while true do
        local cases = {
            events:case_receive(),
            lifecycle:case_receive(),
            inbox:case_receive(),
            ticker:case_receive(),
        }
        if hover_timer then cases[#cases + 1] = hover_timer:case_receive() end
        if frame_gate.timer then cases[#cases + 1] = frame_gate.timer:case_receive() end
        if balloons.timer then cases[#cases + 1] = balloons.timer:case_receive() end
        if flashes.timer then cases[#cases + 1] = flashes.timer:case_receive() end
        if notice_clock.timer then cases[#cases + 1] = notice_clock.timer:case_receive() end
        for _, deadline in pairs(widgets.retired) do cases[#cases + 1] = deadline:case_receive() end
        local watched = {}
        for _, window in ipairs(windows) do
            -- A view window has no frames: there is nobody to publish them.
            if window.updates then
                cases[#cases + 1] = window.updates:case_receive()
                watched[#watched + 1] = window
            end
            if window.deadline then
                if not window.updates then watched[#watched + 1] = window end
                cases[#cases + 1] = window.deadline:case_receive()
            end
        end

        local selected = channel.select(cases)
        if not selected.ok then break end
        -- The frame's cause: every branch below names itself, and `draw`
        -- writes it into the cost. "unknown" in the status is a branch
        -- someone forgot to name.
        meter.trigger, meter.snapshot_ms = "unknown", nil

        -- The clock tick is not a window event: it forwards nothing, it only
        -- updates the frame if the minute changed.
        local handled = false
        for pid, deadline in pairs(widgets.retired) do
            if selected.channel == deadline then
                process.terminate(tostring(pid))
                widgets.retired[pid] = nil
                handled = true
            end
        end
        if selected.channel == ticker then
            meter.trigger = "tick"
            ticker = time.after(CLOCK_TICK)
            -- Both questions are always asked: `a() or b()` would not ask the
            -- tray in the minute the clock changed.
            local ticked = tick_clock()
            local pruned = prune_tray()
            if ticked or pruned then draw() end
            handled = true
        end
        -- The owed frame: every request since the last one, painted once.
        if frame_gate.timer ~= nil and selected.channel == frame_gate.timer then
            frame_gate.timer = nil
            meter.trigger = "batch:" .. tostring(frame_gate.merged)
            if frame_gate.dirty then draw_now() end
            handled = true
        end
        if hover_timer ~= nil and selected.channel == hover_timer then
            meter.trigger = "hover"
            settle_hover()
            handled = true
        end
        -- The shown balloon timed out: the next one waiting takes its place.
        if balloons.timer ~= nil and selected.channel == balloons.timer then
            meter.trigger = "balloon"
            next_balloon()
            draw()
            handled = true
        end
        if flashes.timer ~= nil and selected.channel == flashes.timer then
            meter.trigger = "flash"
            if flash_step() then draw() end
            handled = true
        end
        -- A module's notice ran its ttl: cleared, unless a later notice
        -- (the compositor's own included) replaced it meanwhile.
        if notice_clock.timer ~= nil and selected.channel == notice_clock.timer then
            meter.trigger = "notice"
            notice_clock.timer = nil
            if notice == notice_clock.text then
                notice = ""
                draw()
            end
            notice_clock.text = nil
            handled = true
        end

        -- A window's frame. The notification is a watermark, not a frame: the
        -- state is always taken by snapshot.
        for _, window in ipairs(watched) do
            if selected.channel == window.updates then
                meter.trigger = "pty:" .. tostring(window.id)
                local asked = time.now():unix_nano()
                local snapshot = window.view:snapshot(window.revision)
                meter.snapshot_ms = round_ms((time.now():unix_nano() - asked) / 1000000)
                if snapshot then
                    window.rows = snapshot.rows
                    window.cursor = snapshot.cursor
                    window.revision = snapshot.revision
                    window.ready = true
                    if not window.minimized then draw() end
                end
                handled = true
                break
            end
            if window.deadline and selected.channel == window.deadline then
                meter.trigger = "deadline"
                window.deadline = nil
                -- One way to force: `close_how`. Shutdown sets it on every
                -- window, a pending request included (`close_window` raises it).
                if window.close_how == "force" then
                    process.terminate(tostring(window.state_pid or window.pid))
                else
                    -- A request the window did not answer by closing: it
                    -- refused (a document to save) or it hangs. Either way it
                    -- stays, and says so — killing it would lose the document,
                    -- and a silent stay would read as a dead ×.
                    window.closing = false
                    window.close_how = nil
                    notice = tostring(window.title or window.id) .. " did not close"
                    draw()
                end
                handled = true
                break
            end
        end

        if not handled then
            if selected.channel == inbox then
                local message = selected.value
                if message then
                    meter.trigger = "command:" .. tostring(message:topic())
                    local body = unwrap(message:payload())
                    -- The sender is needed to link a dialog to its window:
                    -- such a link in the body cannot be trusted.
                    if handle_command(message:topic(), body, message:from()) then draw() end
                end
            elseif selected.channel == lifecycle then
                local event = selected.value
                meter.trigger = "exit"
                if event.kind == process.event.CANCEL then
                    -- Asked to finish: the remote terminal left (terminal.ssh)
                    -- or the runtime is stopping. Shut down as "Shut Down"
                    -- does: the windows are closed, not left orphaned.
                    meter.trigger = "cancel"
                    -- The terminal may already be gone: the cleanup below
                    -- must not fail on it.
                    terminal_state.cancelled = true
                    if not quitting then
                        request_quit()
                        draw()
                    end
                    if #windows == 0 then break end
                end
                if event.kind == process.event.EXIT then
                    local gone = tostring(event.from)
                    widgets.retired[gone] = nil
                    -- A widget's process: the last tree stays, the theme says
                    -- "stopped" over it, and `desktop.refresh` spawns it again.
                    local widget_stopped = false
                    for _, item in ipairs(widgets.items) do
                        if item.pid ~= nil and tostring(item.pid) == gone then
                            stop_widget(item)
                            widget_stopped = true
                            break
                        end
                    end
                    for index = #windows, 1, -1 do
                        if widget_stopped then break end
                        local window = windows[index]
                        if window == nil then break end
                        if window.pid ~= nil and tostring(window.pid) == gone then
                            forget(window)
                            break
                        end
                        -- The state provider died: the view window stays, but
                        -- there is nothing to draw it with any more — and
                        -- that has to be said. A view frozen on its last
                        -- state looks alive and lies the more convincingly
                        -- the longer it hangs.
                        if window.state_pid ~= nil and tostring(window.state_pid) == gone then
                            if window.closing then forget(window); break end
                            window.state_pid = nil
                            window.waiting = true
                            window.ready = false
                            notice = "the state provider of window " .. window.id .. " stopped"
                            log:warn("state provider stopped",
                                {window = window.id, entry = tostring(window.state_ref)})
                            break
                        end
                    end
                    draw()
                    if quitting and #windows == 0 then break end
                end
            else
                local event = selected.value
                -- resize / mouse / key / paste…: the kind of event is the
                -- cause.
                meter.trigger = tostring(event.type)
                if event.type == "resize" then
                    -- Font zoom changes pixels per cell independently of the
                    -- grid. Refresh the theme before its layout/insets, then
                    -- resize every client and rebuild rasters at native size.
                    local refreshed, refresh_error = refresh_cell_size()
                    if refreshed then refresh_frame()
                    else notice = "cell size not refreshed: " .. tostring(refresh_error) end
                    -- A resize also comes with zeros when the terminal is
                    -- gone; a zero canvas would bring the compositor down
                    -- together with all the windows.
                    local w = math.floor(tonumber(event.width) or 0)
                    local h = math.floor(tonumber(event.height) or 0)
                    if w >= MIN_SCREEN_W then width = w end
                    if h >= MIN_SCREEN_H then height = h end
                    canvas = tty.canvas(width, height)
                    apply_layout()
                    arrange_desktop()
                    for _, window in ipairs(windows) do
                        if window.maximized then
                            window.x, window.y = 1, desktop_top
                            resize_window(window, width, desktop_height())
                        else
                            resize_window(window, window.w, window.h)
                        end
                    end
                    -- A widget keeps its cells, but the pixels of a cell may
                    -- have changed with the font.
                    for _, item in ipairs(widgets.items) do tell_widget_size(item) end
                    out:invalidate()
                    draw()
                elseif event.type == "mouse" then
                    -- A press or a release is aimed at what is on screen: an
                    -- owed frame is painted first, so the hits are its.
                    -- Motion and the wheel stay batched.
                    if event.action ~= "motion" and event.action ~= "wheel" then flush() end
                    handle_mouse(event)
                    if quitting and #windows == 0 then break end
                elseif event.type == "key" then
                    -- An open menu's keys read the painted menu (its hits
                    -- carry the marked row): its owed frame first. A key for a
                    -- window needs no frame — and one squeezed in before it put
                    -- a focus report into the window's pty just ahead of the key.
                    if menu ~= nil then flush() end
                    local verdict = handle_key(event)
                    if verdict == "quit" or (quitting and #windows == 0) then break end
                    if verdict == "forward" and not quitting then
                        send_to(focused(), event)
                    end
                elseif event.type ~= "start" then
                    if not quitting then send_to(focused(), event) end
                end
            end
        end
        if terminal_state.lost and not quitting then
            log:warn("the terminal is gone; shutting the desktop down", {error = terminal_state.lost})
            request_quit()
        end
        if terminal_state.lost and #windows == 0 then break end
    end

    -- Farewell: "It's now safe to turn off your computer." Drawn by the theme
    -- if it can (`chrome.farewell`), held for `chrome.FAREWELL_HOLD` seconds
    -- (five by default); input during that time is swallowed — the screen is
    -- not for interaction. A theme without a farewell exits at once, as
    -- before.
    if farewell_wanted and not terminal_state.lost and #windows == 0 and type(chrome.farewell) == "function" then
        canvas:clear(" ")
        local painted = chrome.farewell(canvas, width, height)
        local images: any = nil
        if PIXELS and type(painted) == "table" then
            images = pixels.frame(canvas, painted)
        end
        assert(out:present(canvas:rows(), {images = images}))
        local hold = tonumber(chrome.FAREWELL_HOLD) or 5
        local deadline = time.after(string.format("%dms", math.floor(hold * 1000)))
        while true do
            local picked = channel.select({deadline:case_receive(), events:case_receive()})
            if not picked.ok or picked.channel == deadline then break end
        end
    end

    for _, window in ipairs(windows) do
        if window.view then window.view:close() end
        if window.state_pid then process.terminate(tostring(window.state_pid)) end
    end
    for _, item in ipairs(widgets.items) do
        if item.pid then process.terminate(tostring(item.pid)) end
    end
    for pid, _ in pairs(widgets.retired) do process.terminate(tostring(pid)) end
    process.registry.unregister(SERVICE_NAME)
    if terminal_state.lost or terminal_state.cancelled then
        -- Nothing to restore on a terminal that is gone — lost, or the
        -- reason for the cancel: every write fails, and the desktop ended
        -- as asked, not with an error.
        tty.mouse(false)
        out:close()
        tty.stop()
    else
        assert(tty.mouse(false))
        assert(out:close())
        assert(tty.stop())
    end
end

return {run = run}
