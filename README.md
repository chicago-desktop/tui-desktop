# chicago/tui-desktop

Shared window contract: [Chicago shell SDK](https://github.com/chicago-desktop/shell/blob/master/docs/sdk.md).
The base holds `window_api`, `geometry`, `input` and `scroll`; the ready-made
declarative components and the skill are in the `chicago/shell` module.


A window manager for the terminal on the Wippy runtime.

One compositor process owns the physical screen and draws the windows; each
window is a separate process that writes to its own viewport through the
ordinary `tty` and believes it owns the whole terminal. No window knows it is a
window: that is why a real `bash`, `htop`, an editor or Claude Code runs inside
a window — without a single line written for this desktop.

An agent drives the same screen at the same time: the module has an HTTP
channel through which it can open a window, move it, type into it and **read
its screen**.

```
physical TTY → compositor surface → viewport → window process → PTY proxy → program
```

## What it is made of

Four parts, and the boundary between them is the reason the module is built
this way and not simpler.

- Part: **Mechanics**; What it is: `…desktop:library` — one function `run(options)`: windows in z-order, input, hit test, command channel, process hosting; Who writes it: this module
- Part: **Shell**; What it is: a process that calls `run` with its own theme, catalog and desktop layout; Who writes it: the application; here there are two — the stock one and the Chicago shell in `chicago/shell`
- Part: **Theme**; What it is: pure drawing functions: frames, bars, menus, icons. Returns the hit map; Who writes it: the shell
- Part: **Window**; What it is: a registry entry. Usually a process that writes to its viewport and does not know it is a window; it can also be a view without a process; Who writes it: the application

**The mechanics do not know what things look like, and the theme does not know
what is happening.** The compositor computes coordinates and state; the theme
lays down the paint and returns where a click lands. That is why a second shell
gets a different look without copying window hosting, the PTY or the command
channel — and that is also why this README says so much about who hands what
to whom.

A frame is assembled like this — and the order of the steps matters more than
it seems:

1. the compositor clears the canvas and asks the theme to fill the desktop (`fill`);
2. it lays down the window contents — in character mode the theme does this
   together with the frame, in pixel mode the compositor does it itself;
3. it asks the theme to draw the chrome: in cells — `window`, `bars`, `menu`; in
   pixels — a single `paint` that returns rasters;
4. it hands the frame to the surface: `present(rows)` or `present(rows, {images})`.

Where to start reading, depending on why you came:

- **declare a window in your application** — "The application brings the windows";
- **write a shell or a theme** — "The look is separate from the mechanics: the
  theme contract", and right after it "Pixel chrome" if you draw with rasters;
- **find out why something does not work** — "Development": the rules that
  catch it, and the symptoms that do not look like their causes.

## Requirements

- Wippy **0.3.40a** or newer — the `tty` module appeared there (#631, fixes in #637).
- A Kickside application that provides `app:api` (a router with authentication).

## Running

```bash
wippy run --host chicago.tui_desktop:terminal desktop
```

`--host` is required here, and this is not pedantry: the CLI's terminal host
autodetection is just a count of `terminal.host` entries in the whole registry,
and this module brings a second one. From the moment it is installed, **every**
command of the application needs an explicit `--host`; the other commands
choose the application's host (`--host wippy.terminal:host`).

A host of its own is needed for `hide_logs`. The surface differ considers itself
the only writer to the terminal, so a log line misaligns the frame for good —
unchanged rows are not redrawn. The application's host cannot be taken over for
this: the background processes live on it, and the application would lose its log.

### The Bash environment

The stock window runs `/bin/bash -i`, so it reads `~/.bashrc`: user paths, nvm
and other settings work inside the window too. `exec.native` passes only the
environment that is set explicitly. The application sets `HOME` and `PATH` for
the terminal window executor specifically, in `.wippy.yaml`:

```yaml
override:
  "chicago.tui_desktop:exec:default_env.HOME": "${env:HOME}"
  "chicago.tui_desktop:exec:default_env.PATH": "${env:PATH}"
```

These are values from the environment of the process that starts Wippy; user
names and paths to installed programs are not hardcoded in the module. `TERM`
is already set by the executor. After changing `.wippy.yaml` the application
needs a restart. Check inside a window: `command -v claude codex`. The programs
must be installed for the same OS user that Wippy runs as.

### Keys

- `alt+n` — a new window with an interactive bash
- `alt+o` — the menu of the windows the application declared
- `alt+w` — close the current window
- `alt+m` — minimize the current window
- `alt+tab` — the next window
- `ctrl+q` — close all windows and exit

In an open menu — the arrows and `enter`: `↑`/`↓` move the cursor through the
rows, `→` expands a folder, `←` returns one level up, `enter` opens, `esc`
closes. **The cursor moves over the HIT MAP, not over the catalog**: the theme
marks the selected row (`cursor = true`), the compositor opens the marked one.
Computing the selection on both sides would mean two opinions about what is
selected, and one day they would diverge.

When no window has the focus, the arrows move the selection over the desktop
icons, and `enter` opens the selected one. **With a window in focus the desktop
does not take the arrows** — otherwise an editor inside the window would lose
its arrows.

There are no digit shortcuts and there will be none: `alt+1`…`alt+9` and
"digit — open" in the menu were removed. The rule is **do not add keyboard paths
that are not visible in the interface**; and a visible path would need a column
of digits on the screen, which Windows 95 does not have.

Everything else goes into the window. The accelerators sit on `alt` on purpose:
`ctrl` and `tab` are needed by the programs themselves too often, and stealing
them means breaking the editor inside.

With the mouse you can drag a window by its title, pull the lower right corner,
press `[-]`, `[□]`, `[×]` and switch windows by a tab at the top. Mouse
reporting, once on, takes the terminal's ordinary text selection away — hold
Shift to copy.
The size handle is the last two cells of the bottom frame row, where a theme
draws the Windows 95 sizing grip; the window keeps the pointer's offset from
the corner while it is dragged, and a window with `resizable: false` ignores
the handle.

## Command channel

All endpoints live behind the application's authenticated router.

- `GET /tui-desktop/windows` — open windows, focus, screen size and desktop state (see below)
- `POST /tui-desktop/windows` — open a window: `entry`, `command`, `title`, `x`, `y`, `w`, `h`
- `POST /tui-desktop/windows/{id}/type` — type `text`, followed by a newline when `enter: true`
- `POST /tui-desktop/windows/{id}/key` — one key: `key`, `ctrl`, `alt`, `shift`
- `POST /tui-desktop/windows/{id}/screen` — the window's contents as rows
- `POST /tui-desktop/windows/{id}/move` — move: `x`, `y`
- `POST /tui-desktop/windows/{id}/resize` — size: `w`, `h`
- `POST /tui-desktop/windows/{id}/focus` — raise to the top
- `POST /tui-desktop/windows/{id}/minimize` — minimize or restore: `value`
- `POST /tui-desktop/windows/{id}/close` — close

The workshop — windows built on the fly:

- `POST /tui-desktop/apps` — build a window: `name`, `source`, `title`, `width`, `height`, `modules`, `group` (the menu folder, like `meta.group` of an entry from a file; empty — the shell chooses the folder). Beyond the code — the same fields as an entry from a file: `imports` (`{name = library id}`, the name `desktop` is taken), `pixel_render` (the library of the pixel view; `pixel_state` — the window itself), `image`, `icon`, `window_type` (`app | dialog | tool`), `resizable`, `in_menu`, `order`. This is how the workshop builds a window on the shell SDK: `imports = {app = "chicago.shell.sdk:app"}`, `pixel_render = "chicago.shell.sdk:render"`. A dead import and a non-library are rejected with the field's name
- `GET /tui-desktop/apps` — the saved windows and the `live` flag (whether a registry entry exists right now)
- command `desktop.tray` `{key, text, entry?, title?, ttl?}` of the command channel — a notification area item next to the clock; the same `key` updates it, `{key, remove: true}` removes it. At most 6 items and 16 characters in a label. An item not updated within `ttl` seconds is removed by the compositor itself. A click on an item opens `entry` or raises the window already open — like a click on the clock. From Lua — `window_api.tray(spec, service?)`; `desktop.list` returns `tray` with the owner and the remaining lifetime
- command `desktop.balloon` `{key?, title, text, icon?, image?, anchor?, entry?, args?, timeout?, bell?}` of the command channel — a balloon tip by the notification area: `icon` is `info`, `warning` or `error` (the picture left of the bold title), `image` a pack picture drawn instead of it, `anchor` the key of the tray item its tail points at (else the clock), `entry`/`args` the window a click on its body opens or raises (like a tray click; `args` a string), `timeout` seconds (default 10, clamped to 2..60), `bell` a request to ring the terminal bell once. One balloon is shown at a time and the others wait in order; the desktop holds at most 8, the shown one included, and a ninth is refused with its key named. The same `key` replaces a waiting or the shown balloon (the shown one restarts its timeout); without a key the compositor makes one up (`b<n>`) and the reply names it; `{key, remove: true}` dismisses it. A click on its × dismisses it, a click on its body opens `entry` and dismisses it, the timeout dismisses it, and the next one takes its place. It takes no keyboard focus. The reply is `{key, shown, queue, timeout}`. **The bell does not ring:** the runtime's surface writes frames only (rows, a cursor, images), so `bell` is carried to the theme and to `desktop.list` and nothing more. From Lua — `window_api.balloon(spec, service?)`
- command `desktop.flash` `{id?, count?, stop?}` of the command channel — FlashWindow: the window's taskbar button and its title bar swap between the lit and the plain look every half second until the window takes the focus. No `id` is the sender's own window, found by its process. `count` is a whole number of cycles (lit, then plain) after which the flash ends; `stop: true` ends it; the frame that first shows the window focused ends it. A window that has the focus flashes only with a count — "until it is focused" would never end — and the reply says `flashing: false` with the reason. The window record carries `flashing` and `flash_lit` for the theme; only the taskbar and the title bar change, so a swap repaints those rows and nothing else. From Lua — `window_api.flash(id | spec, service?)`
- command `desktop.notice` `{text, ttl?}` of the command channel — the taskbar notice line, open to modules: `text` for `ttl` seconds (default 5, clamped to 1..60, at most 256 characters); an empty text clears the line. The compositor's own notices keep working and the latest wins: the ttl clears the line only while it still shows that text. From Lua — `window_api.notice(text | spec, service?)`
- command `desktop.refresh` of the command channel also brings the desktop widgets in line with `options.widgets`: new entries are spawned, vanished ones stopped, stopped ones spawned again; `desktop.list` returns `widgets` — `{id, entry, title, opens, w, h, revision, waiting, stopped}` each, without the tree. See "Desktop widgets"
- command `desktop.workshop` `{name, remove?}` of the command channel — apply a saved window to the registry (or remove it) through the compositor: this is how the MCP tool, whose scope forbids `registry.apply`, builds a window
- `DELETE /tui-desktop/apps/{name}` — remove the window from the storage and the registry

The path prefix is set by the application's router, not by the module:
`/api/v1` on the kickside stand, `/api` in the harness. A miss returns the
facade page with code 200, so check by `content-type`, not by the code.

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"title":"build","command":"/bin/bash -i"}' \
  http://localhost:8099/api/v1/tui-desktop/windows

curl -X POST -H 'Content-Type: application/json' \
  -d '{"text":"make test","enter":true}' \
  http://localhost:8099/api/v1/tui-desktop/windows/w1/type

curl -X POST -H 'Content-Type: application/json' -d '{}' \
  http://localhost:8099/api/v1/tui-desktop/windows/w1/screen
```

There is no command without an answer: silence from the compositor cannot be
told apart from an applied command, and the caller would believe it succeeded.
A desktop that is not running and a desktop that is not responding are
different answers too.

**`GET /tui-desktop/windows` is also a dashboard.** Every field in it appeared
because without it two different states looked the same from outside, and
telling them apart saved an hour:

- Field: `notice`; What it tells apart: the status line — what the person sees. A refusal of a command nobody waited for is visible only here
- Field: `menu_open`; What it tells apart: "the click on the menu button did not arrive" versus "it arrived, but the menu was not drawn"
- Field: `menu_path`; What it tells apart: the expanded menu folder: "the right arrow did not work" versus "it worked, but the submenu was not drawn"
- Field: `menu_choices`, `menu_folders`; What it tells apart: how many rows the level has and how many of them expand. Zero folders means "nothing to expand", not "broken"
- Field: `menu_cursor`; What it tells apart: the number of the selected row on the current level, 0 — nothing selected: "hovering did not select" versus "it selected, but the theme did not draw it"
- Field: `selected`; What it tells apart: the selected desktop icon: "the arrow did not work" versus "the theme did not draw the selection"
- Field: `pixels`; What it tells apart: which mode the compositor draws in
- Field: `frame`; What it tells apart: the cost of the last frame: `changed_rows`, `bytes_written`, `images` and `placements_sent`. Wrongly sliced chrome draws the CORRECT screen, just slowly
- Field: `restore`; What it tells apart: what happened to the workshop windows at start: silence would read as "there were no windows"
- Field: `balloon`, `balloon_queue`; What it tells apart: the balloon on screen (`key`, `title`, `text`, `icon`, `image`, `anchor`, `entry`, `args`, `bell`, `owner`, `timeout`, `expires_in`) and how many wait: "not accepted", "waiting its turn" and "shown but not drawn" look the same on the screen
- Field: `flashing`; What it tells apart: the ids of the windows that flash; each window also reports `flashing` and `flash_lit` — "the flash did not start" versus "it runs, but the theme does not draw it"

A window in the list carries, besides its geometry: `window_type`, `opened_by`
(who opened it), `content` (`cells` or `pixels`), `waiting` and `state_revision` —
for a view window, whether it is still waiting for its first state.

A caveat about the checks: **no check calls this module's endpoints over
HTTP** — the harness starts the router only so that the entries resolve, and
it has no authentication. The shape of the endpoints is checked as wiring
(entry, handler, method, path, policy), and the compositor's answer by a live
compositor. The first real call of an endpoint always comes from a live stand.

## The application brings the windows

The module knows exactly one window of its own — a program under a PTY.
Everything else is declared by the application as a process entry that can
write to its `tty` port; the mark `meta.type: tui_desktop.window` puts it into
the `alt+o` menu, and `meta.title`, `meta.width` and `meta.height` say how to
open it. Not a single line of this module needs changing for a new window —
otherwise every application would need a desktop release.

Two more fields describe what the window is and where to find it:

- Field: `meta.window_type`; Default: `app`; Meaning: `app`, `dialog` or `tool` — the theme chooses the set of title bar buttons by it
- Field: `meta.in_menu`; Default: `true`; Meaning: `false` hides the program from Start without preventing it from being opened by a shortcut or from another window
- Compositor option `desktop_properties` (an entry id): the properties window of the desktop itself — "Properties" on a right click on an empty spot. `desktop.list` returns `screen`, `cell = {w, h}` in pixels and `pixels` — the frame mode; the display properties window shows the resolution from them
- Field: `meta.properties`; Default: none; Meaning: the entry id of the program's properties window — the "Properties" item in the context menu of its desktop icon (right click). No field — no item
- Field: `meta.resizable`; Default: `true`; Meaning: `false` — the size is fixed: the window opens at exactly the entry's `width`×`height`, even if the opener asked for another size or for none at all; the corner does not stretch, there is no "maximize" button, `desktop.resize` answers with a refusal. For windows whose layout is computed for one size

- **An unknown type is `app` plus a warning in the log**, not a hidden
  program: someone else declared the entry, and a typo in one field is no
  reason not to show a window that is otherwise sound.
- **A flag, not an inference from the type.** A dialog almost never belongs in
  the menu, but "almost" is expensive here: "About" is a dialog, and its place
  is exactly in the menu.
- **The menu entry is hidden, not the launch.** `in_menu: false` prevents
  neither a desktop shortcut, nor `desktop.open` from a neighboring window, nor
  the command channel.

```yaml
- name: window_calc
  kind: process.lua
  meta:
    type: tui_desktop.window
    title: Calculator
    width: 28
    height: 15
  source: file://window_calc.lua
  method: main
  modules: [channel, tty]
```

Such a window opens the surface of its own port and publishes frames — unlike
a window with a program, where the PTY session takes the port's lease. Through
the command channel it is opened by the entry name: `{"entry": "app.desktop:window_calc"}`.

## A window can be built in the running runtime

The registry changes live (`snapshot → changes → apply`), so a window does not
have to be a file: its code travels in the request body, and the window appears
in the menu at once — without a restart.

```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"name":"clock","title":"Clock","width":30,"height":6,
       "modules":["time"],"source":"…lua…"}' \
  http://localhost:8099/api/v1/tui-desktop/apps
```

The source then goes into the `chicago_tui_desktop_windows` table, and at
start the compositor returns the saved windows to the registry. Without this a
built window would live exactly until the process ends.

It is the compositor that restores them, not a background service, and this is
not a matter of style: the platform deliberately forbids processes of the
`wippy.security:process` group to change the registry — the
`wippy.security:registry.no_write` policy overrides permissions with an
explicit `deny`, and such a service would silently do nothing. The compositor
runs under its own actor, and these windows are needed exactly when the
desktop is running.

The outcome of the restore is visible from outside — `GET /tui-desktop/windows`
returns the `restore` field (`restored`, `failed`, `names`, `error`). The
terminal host's log is muted, otherwise it would misalign the frame, so a
failure told only to the log is told to nobody.

- **One row per window, the name is the key.** A rebuild overwrites: no edit
  history is kept, and "name taken" would be a refusal to fix your own window.
- **One window build for both paths.** The workshop and the loader build the
  entry with the same code — if they diverged, a window would behave
  differently before and after a restart, and such a divergence shows up a day
  later.
- **Window modules are chosen from an allowlist**: `channel`, `time`, `tty`,
  `json`, `sql`; `tty` and `channel` are always added. `env` was in the list
  and was removed: the window has no `env.get` permission, and without that
  permission `env.get` returns nil instead of a loud refusal — and the
  neighboring `or default` turns a permission refusal into "nobody set
  anything". Granting the permission would be worse: the window's code arrives
  over HTTP, and the environment holds tokens. A requested
  module outside the list is a refusal that names it, not silent ignoring.
  The window has no means to spawn processes or run programs: the code comes
  over HTTP, and the permissions are granted exactly for drawing and reading data.
- **An import is any library in the registry, and this is not a hole.** A
  window's permissions come from its policy and from the scope under which the
  compositor spawned it; a library brings no permissions of its own. That is
  why a workshop window may import the shell SDK — and be drawn by the shared
  renderer, in pixels, like a window from a file. The description is stored in
  the `spec` column (migration 03) and built by the same `build_entry` as
  before; the body is parsed by `apps.prepare`, one for HTTP and for the MCP
  tool.
- **A library gets ITS OWN modules, not the window's.** The list on the window
  entry limits the window's own code; a library the window imports works with
  the list declared on the library. That is why `desktop` reads the
  compositor's name with the `ctx` module, which is not in the window's
  allowlist, and no existing window had to be changed. The comment in
  `apps.lua` about "the library needs process" reads the other way round — it
  is about the window's own convenience, not a requirement of the library. The
  proof is a test: `app:window_probe_bare` declares only `process` and still
  gets the name.
- **Removal does not kill open windows.** The process lives its own life; what
  is removed is the possibility to open a new one, and the answer says so
  directly.

## A window learns its compositor at start

The compositor's name travels to the window in the process context: the
compositor puts it there at `spawn` under the key `tui_desktop.service`, and
the `desktop` library reads it from there. The name used to be a constant, and
under a second shell a window addressed someone else's (nonexistent) process —
silently, because `desktop.open` does not wait for an answer.

- **One key for both sides.** The mechanics take it from `window_api` rather
  than repeating it as a string: if the two diverged, the window would take the
  stock name again, and exactly the defect fixed here would come back.
- **The `ctx` module is declared by the library, not by the window entry.** A
  library gets its own modules, so windows written before this field and
  workshop windows (the workshop has a narrow allowlist) get the name without
  a single edit. Verified by a test on a live run, not deduced.
- **A window started without a name works as before** — it takes the stock
  `chicago.tui_desktop.desktop`.
- **A refusal names the reason and goes to the log.** "Desktop so-and-so does
  not answer; the compositor's name did not arrive at start" — in the second
  return value and as a line in the log: `open` does not wait for an answer,
  and a window that did not check the return value would otherwise not report
  the refusal at all.

## A window can ask the desktop

Clicks and keys reach the window as they are — the compositor translates them
into the window's coordinates. The reverse path is given by the `desktop`
library, which the workshop attaches to every built window:

```lua
local desktop = require("desktop")

desktop.open({entry = "…:dataflow_detail", title = "Nodes", args = flow_id, w = 86, h = 18})
desktop.focus(id)
desktop.close(id)
```

A close is a **request**: the title bar's ×, ctrl+w and a plain `desktop.close`
send the window `close` and wait for it to close itself. A window may refuse —
an application with a changed document asks first — and when the grace (3 s)
runs out without it closing, it stays open and the status line says
"<title> did not close" (`desktop.list` reports it as `notice`). Shutdown
(ctrl+q, Shut Down) and `desktop.close{id, force = true}` do not ask: they kill
the window after the grace, as every close did before. A PTY window has no loop
to answer, so every close of it is forced. A window may also refuse at once: its
own process answers `close` with `desktop.close{refused = true}`
(`window_api.close(id, {refused = true})`; a cells window passes no id — its
process names it), the request is over without the notice, and a later ×
asks again; from any other process such a refusal is refused.

This is how a widget becomes interactive: a click on a row opens a neighboring
window with a parameter. An application window gets its parameter as `args`;
`command` stays the program of a PTY window — one field for both meanings would
read as "command", and the details window would be opened with the string
`/bin/bash`.

The boundary is narrow, and a test checks it: a window can **ask**
(`process.send` and finding the addressee), but it is not granted `spawn`,
`exec` or `registry.apply`. Code sent over HTTP can trigger exactly the desktop
commands that are already open from outside — and nothing more.

`desktop.open` deliberately does not wait for an answer: waiting for someone
else's answer would freeze the window's frame, and whether the window opened
is visible on the screen. When an answer is needed after all, there are
`desktop.open_wait` (the same, but with the description of the opened window,
including `id`), `desktop.ask` and `desktop.replies()`, see below: they do not
read the inbox and therefore do not eat other messages.

## A window can ask a question without losing a command

The window description in the answers of `desktop.open` and `desktop.list`
includes `image` — the picture name chosen at opening from `meta.image` or the
window's parameters. Application lists use the same one as the title bar and
the taskbar.

The window description also carries `args` — the argument the window was
opened with (`desktop.open{args = …}`), absent when there was none. An opener
finds a window already open for the same thing by `entry` and `args` and sends
`desktop.focus` instead of opening a second one: a folder window for the same
path is raised, as in Windows 95. A bash window's command stays in `command`.


A question with an answer is `desktop.ask` (waits) or `desktop.request` +
`desktop.replies()` (does not wait). The answer comes through **its own
channel**, not into the shared inbox, and that is the whole point.

```lua
local desktop = require("desktop")

-- a window with its own loop: the reply channel goes into select next to the events
local replies = desktop.replies()
desktop.request("desktop.list", {})

-- the simple case: wait for the answer in place
local answer, err = desktop.ask("desktop.list", {}, {timeout = "2s"})
```

Why not a loop over the inbox, as the command channel does from outside:
**such a loop takes everything from the inbox and throws away whatever is not
its answer**, while other messages reach the window through the same inbox.
Measured on a live run: a `desktop.close` command sent to a window while it was
waiting for an answer vanished without a trace — from outside this looks like a
window that stopped obeying the mouse, and people will search in the
compositor. A check for "the answer arrived" does not see such a loss: the
answer arrives in both cases. So the test checks the fate of the COMMAND, and
next to it lies a second test that shows the same scenario with a naive loop.

What the runtime does here is measured too, and it matters to the reader:

- **A message with nobody to take it is not lost.** It waits in the process
  queue until the window returns to its `select`. So it is enough NOT to take
  other messages from the inbox; nothing needs to be put back, because nothing
  was taken from there. The mechanism is `subs.match(topic)` in
  `runtime/lua/engine/process.go`: a message goes to a subscription on the
  EXACT topic, and the inbox is only a fallback for those without a
  subscription of their own; a message nobody takes stays in the queue. Hence
  the general rule to measure such bugs by: **it is user code that loses
  messages, not the runtime** — look for the loop that read and threw away.
- **Viewport events survive a busy window.** Keys sent to a window that read
  nothing for 1.2 s all arrived, in order. So `ask` loses neither input nor
  `close` — but the frame stands still while it waits, and the wait always has
  a deadline (`api.BUDGET`, 5 s by default).
- **An answer that was not waited for is thrown away before the next
  question.** Answers have no correlation, and if it were read as fresh, it
  would answer the previous question instead of the current one. Throwing away
  an answer is safe — unlike a command.

### A refusal reaches a sender that did not wait for an answer

`close`, `focus` and `open` do not wait for an answer — and still learn about a
refusal. The compositor knows the sender of the command, so "no window w404"
goes to THREE recipients, and each one is needed by its own reader: the status
line — by the person at the desktop, the log — by whoever investigates later,
and the sender itself — in its reply channel.

```lua
{ok = false, error = "no window w404", command = "desktop.focus", unsolicited = true}
```

- **`unsolicited` is mandatory.** A refusal that arrived on its own lands in
  the same channel where the window waits for answers. Without the mark it
  would be taken as the answer to the next question — that is, the fix for
  silence would give birth to lies. `ask` skips such messages, naming them in
  the log, and keeps waiting for its own.
- **Every answer names its command** (`command`). Matching by order alone
  breaks exactly when something uninvited enters the stream.
- **A window that has not created a channel** gets the refusal as an ordinary
  message in its inbox — the window's own loop reads it.

A window that calls `ask` or `replies()` stops receiving `desktop.reply` in its
inbox: the topic subscription takes it. A window that parsed answers with its
own inbox loop does not have to change — but mixing both ways in one window is
not allowed.

## A dialog belongs to the window that opened it

```lua
local dialog, err = desktop.dialog({entry = "app.desktop:props", title = "Properties"})
```

The compositor learns the parent **from the sender of the command**, not from a
number in the request: a window does not know its own number, and someone
else's number sent in a field cannot be verified — that way any window on the
desktop could be declared one's own dialog.

What follows from the link:

- Type: `dialog`, `tool`; Behavior: stands in the center of its window, stays on top of it, closes together with it
- Type: `app`; Behavior: nothing: a program opened from another window lives its own life

- **There is no modality, and this is a decision, not something unfinished.**
  Blocking the input of the other windows, where a window is someone else's
  process under a PTY, means being able to hang the whole desktop with one
  program that does not answer.
- **`opened_by` is always recorded**, even for an ordinary program: "who
  opened it" is a fact, and the behavior is chosen by the type. That is why a
  viewer opened from "My Computer" does not go away together with it.
- **The link is visible from outside**: `GET /tui-desktop/windows` returns
  `window_type` and `opened_by` on every window. Without it debugging goes
  blind: a dialog that did not close with its window and a dialog that was
  never linked look the same.
- **Explicit coordinates beat centering**: whoever asked named them.
- **The closing cascade lives in two places, and this is not a duplicate.** A
  polite close takes the dialogs away at once; the second cascade is for a
  window that died on its own, otherwise the dialog would stay tied to a number
  that no longer exists.

## View window: no process inside

The entry declares what draws its contents. The default is `cells`, that is,
as before: a process inside, writing to its viewport.

```yaml
meta:
  type: tui_desktop.window
  window_content: pixels                        # cells (default) | pixels
  render: chicago.shell.explorer:render_pixels # pure rendering library
  state:  chicago.shell.explorer:state     # provider process, its own actor
```

`pixels` means that **there is no process inside**: the theme draws by calling
`render`, and a separate process brings the data. The default is not a matter
of taste: someone else's program (bash, htop) can only produce cells, and a
window whose entry says nothing about this field must behave as before — erring
towards `cells` loses beauty, erring towards `pixels` loses bash.

- **Two names, not one: drawing in the compositor, permissions outside.**
  `render` is a pure function without the runtime and without permissions;
  `state` is a process with its own narrow actor that obtains the data. Merge
  them into one, and the explorer's reads would move to a process that can
  spawn processes and run programs.
- **The compositor does not call `render`, and it cannot.** It can neither
  create a raster (the `gfx` module is not declared for the mechanics, and
  cannot be — see "Pixel chrome") nor load a library by name from the registry:
  imports are declared by the entry. So the compositor carries the **state** to
  the theme, and `render` is called by the theme that imports it.
- **The provider pushes the state; the compositor does not ask for it.** The
  compositor does not know when the data got stale — whoever reads the data
  does; polling on every frame would mean `registry.find` sixty times a second
  for a list that changes once an hour. And a frame must not wait for someone
  else's process: a provider that stalls would freeze the whole desktop.
- **No state yet — the view says it is waiting** (`waiting` in `desktop.list`),
  instead of showing yesterday's state or hanging.
- **Someone else's state is rejected.** It is accepted only from the provider
  of THIS window: a view drawn from planted data cannot be told apart from the
  real one.
- **Input goes to the provider** — such a window has no other live part, and
  the view is a pure function and cannot accept a click. The coordinates are
  the same as for a window with a process: relative to the client area inside
  the frame.
- **The provider lives with the window**: it is started when the window opens,
  stopped when it closes, and its death is visible in the status line — a view
  frozen on its last state looks alive and lies the more convincingly the
  longer it hangs.
- **A dead reference refuses at once.** No `render`, or the entry it refers to
  does not exist — the window does not open and says why. Otherwise an empty
  window would look like the theme's fault.

For a program with two backends, instead of a mandatory `window_content: pixels`
one can declare `meta.pixel_render` and `meta.pixel_state` and keep the main
process in cells. The compositor chooses these references only in pixel mode,
and only if the theme confirms `chrome.renders(pixel_render)`. Without the
confirmation the ordinary window process starts.

The state provider gets `main(service, window_id, args, viewport)`: `args` is
the opening string, `viewport` is `{width, height, cell_w, cell_h}`. The
`window_api.CONTEXT_KEY` context holds the compositor's name. The public
`window_api.inputs()` and `input_event(message)` give `window.input` events;
`publish_state(id, state)` sends the state without asking for an answer. If
the state has a `title`, the window title is updated. A resize arrives as a
`resize` event with the same client area geometry.
A state's `image` (a picture name) replaces the window's title-bar picture the
same way, and `desktop.list` reports it; an absent or empty `image` keeps the
picture the window has — a folder window that navigates in place changes both.

## The look is separate from the mechanics: the theme contract

The compositor is the library `chicago.tui_desktop.desktop:library` with one
function `run(options)`. Everything that is drawn comes as a theme in
`options.chrome`; the chrome's geometry — how many rows are taken at the top
and at the bottom — is declared by the theme too. The stock shell
(`…:desktop`) calls `run` with its own theme; a second shell brings another one
and gets a different look without copying window hosting, the PTY or the
command channel.

```lua
local library = require("library")
local chrome = require("chrome")

local function main()
    -- This must not be written as a bare `return library.run(...)`: in go-lua
    -- v1.5.18 a tail call of a yield function from the base frame of a
    -- coroutine is not executed at all — silently, in 0 ms.
    local ok, err = library.run({chrome = chrome, service_name = "…"})
    return ok, err
end
```

`options`:

- Field: `chrome`; Meaning: the theme. Required: a compositor without a look is an empty screen with nothing to look for, so the refusal names the reason instead of silently substituting a theme
- Field: `pixels`; Meaning: whether to draw the chrome with rasters. No by default; see "Pixel chrome"
- Field: `cell_size`; Meaning: `() -> w, h` or `nil, reason` — the cell size in pixels. Needed only in pixel mode
- Field: `service_name`; Meaning: the name under which processes see the compositor
- Field: `hint`; Meaning: the hint on the empty desktop
- Field: `catalog`; Meaning: `() -> items, failure` — the program catalog. Internal and flat by default
- Field: `desktop_items`; Meaning: `() -> items, failure` — the desktop layout: shortcuts and folders. Empty by default
- Field: `move_desktop_item`; Meaning: `(id, x, y) -> ok, error` — record an icon's new place. The compositor does not write the layout, it asks: a refusal moves the icon back to where it was taken from
- Field: `restore`; Meaning: whether to return the workshop windows to the registry at start; yes by default
- Field: `logon`; Meaning: `(screen) -> identity | nil, reason` — logon before the first desktop frame. See "Logon"
- `widgets` — `() -> {{entry, title, w, h, order, opens}, …}, failure`: desktop widgets to spawn. None given — no widgets. See "Desktop widgets"

A theme is a library that returns a table. The compositor calls only this:

- Function: `layout(width, height)`; Must: return `{top = N, bottom = M}` — how many rows the chrome takes at the top and at the bottom. The desktop is rows `top + 1 .. height - bottom`
- Function: `fill(canvas, width, height, state)`; Must: fill the desktop and draw the icons; return a hit map or nothing
- Function: `window(canvas, window, focused)`; Must: draw the frame, the title and the contents of the window
- Function: `bars(canvas, width, height, state)`; Must: draw the bars (window bar, taskbar, status) and return a hit map
- Function: `menu(canvas, width, height, items, failure, open, cursor, anchor)`; Must: draw the program catalog and return a hit map; **mark** the row under the cursor with `cursor = true`. With `anchor = {x, y}` this is the context menu of a desktop icon: a flat list at the pointer, the item's caption is `label` (for "Open", `title` is the title of the window the item will open), `bold` — the default action, `separator_before` — a line above the item. In pixel mode the same arrives as the `menu.anchor` field of the frame state. The compositor opens it on a right click on an icon; the items are "Open" and, if the entry declared `meta.properties`, "Properties"; an icon hit (`hits.desktop`) must carry `properties`, otherwise the item will not be there
- Function: `empty_desktop(canvas, width, height, text)`; Must: the hint on the empty desktop
- Function: `farewell(canvas, width, height)`; Must: optional: the farewell screen after "Shut Down" from the menu — the compositor shows it, holds it for `FAREWELL_HOLD` seconds (5 by default) and only then exits; in pixel mode it may return `{placements}`. A theme without it exits at once; ctrl+q does not show the screen
- Function: `BUTTONS`, `BUTTONS_WIDTH`; Must: the table of title bar buttons for the hit test
- Function: `window_insets()`; Must: the frame thickness: `{top, bottom, left, right}`. One on every side by default
- Function: `icon_grid()`; Must: the desktop icon grid: `{w, h, left}` — the step to the right, the step down, the left edge of the first column
- Function: `paint(state, cell_w, cell_h)`; Must: **pixel mode only**: return raster placements and a hit map. A theme without it is not let into this mode — see "Pixel chrome"

The `state` of `bars` is `{windows, focused_id, menu_open, status, clock, tray, balloon}`;
`tray` is a list of `{key, text, entry, title}` in order of appearance; the
theme returns a hit on an item the same way as for the clock — `{row, from, to, entry}`;
`balloon` is the balloon tip on screen, `{key, title, text, icon, image, anchor,
entry, bell}`, or nil. It is drawn by `bars` because `bars` comes after the
windows, so it lies over them; the theme returns its hits among the bar hits,
`{row, from, to, bottom_row?, balloon = "close"}` for its × and
`balloon = "open"` for its body (the × first: the first hit under the pointer
wins), and the compositor dismisses it or opens its `entry`. A right press or
the wheel on a balloon hit reaches no window. A window in `windows` carries
`flashing` and `flash_lit`: a lit window draws its taskbar button and its title
bar highlighted, as FlashWindow does;
the `state` of `fill` is `{top, bottom, items, failure, selected, widgets}`; of `paint` — the union
of all of this, covered in "Pixel chrome".
`widgets` is the list of desktop widgets in display order, in both modes; the
stock theme of this module ignores it and draws none (see "Desktop widgets").

In pixel mode `window`, `bars`, `menu` and `empty_desktop` from this table are
not called: everything they drew comes as rasters from `paint`. The rest is
called as before — geometry and the hit test are shared by both modes.

The window that arrives in `window(canvas, window, focused)` carries
`window_type` — `app`, `dialog` or `tool`, as its entry declared — and
`opened_by`, the number of the window it was opened from (or `nil`). The theme
chooses the set of title bar buttons by it: the compositor only carries the
type from the entry to the theme and does not know what it turns into. A
catalog item carries the same field, so a theme with its own menu can show
dialogs differently even before they are opened.

Desktop icons: a single click selects (`state.selected` is the id of the
selected one) and picks the icon up, a double click opens, releasing puts it
down on the theme's grid.

**An icon without coordinates is placed by the compositor**, not by the shell:
only the compositor knows the screen width, and the layout is assembled before
the terminal has reported its size. The computed place is not written back —
otherwise the very first frame would turn an auto-placed icon into one placed
by hand. Hence the rule for the shell: absent `x`, `y` mean "nobody named a
place", and zero means a place. An icon placed by hand is never moved by the
compositor, even if the screen became narrower.
The theme declares the grid step with the function `icon_grid()` → `{w, h}` (or
with the fields `ICON_W`, `ICON_H`): it draws the icon and knows how much space
it takes. The compositor aligns a dropped icon — otherwise it would land
between the steps and be covered by its neighbor's hit.

A hit is a record `{row, from, to, …}` with one of: `id` (raise a window),
`index` (a menu item), `action = "menu"` (open or close the catalog), `entry`
(open a program; on the desktop — on a double click). On a bar, a hit with
`entry` opens the window with one press, and if such a window already exists,
it raises it and restores it from the minimized state. The optional `title`,
`w`, `h` and `args` are passed on opening.

The catalog may return an item `{action = "quit", title = "…"}`. Choosing it
with the mouse or Enter starts the same closing of windows as Ctrl+Q: first a
close request, then the usual grace period. On an empty desktop the exit
happens at once.

A mouse event `action = "wheel"` with the button `wheel_up` or `wheel_down` is
passed to the contents of the window under the pointer, taking the theme's
insets into account. The frame and an open menu do not let it through.

What is visible from outside about the menu (`desktop.list`): `menu_open`,
`menu_path` — the path of the expanded folder, `menu_choices` — how many rows
the current level has, `menu_folders` — how many of them expand. The last field
answers a question that otherwise costs an hour: **is `→` silent because it did
not work, or because there is nothing to expand?** Zero folders means the
second, and there is no defect.

**Menu rows carry three more fields, and the arrows walk by them**: `level`
(the panel number; the cursor walks in the deepest expanded one), `slot` (the
row number inside the panel) and `cursor` (the very row the theme drew as
selected). The compositor moves `cursor` in the menu state and hands it to the
theme, and it opens **the marked row**, not one computed anew.

**The mouse moves the cursor by hovering.** The terminal reports motion even
without a press (mode 1003), and the row under the pointer becomes selected at
once. The cascade changes with a delay (`HOVER_DELAY`, 300 ms): the folder
under the pointer expands, submenus deeper than the row under the pointer
close. The delay is not decoration: a mouse moving diagonally from a folder to
its submenu passes over the neighboring row, and without the delay it would
close what it is heading for. A click or a key cancels the pending change —
they decide on their own. A folder expanded by hovering selects nothing in its
submenu: `menu_cursor = 0`, enter is silent, the down arrow goes to the first row.

Plain motion also reaches windows, so an SDK menu inside a window can follow
the pointer the same way: a motion with no button held and nothing captured is
sent to the FOCUSED window as `{type = "mouse", action = "motion", x, y}` in
its client cells, only while the pointer is over its client, and at most once
per cell. Over the frame, the desktop or a window without the focus nothing
is sent; leaving the client forgets the cell, so returning to it is sent again.
While the Start menu is open the pointer is the menu's.

An icon with a caption gives several hits with ONE `id` — for the picture's row
and for the caption's rows. The compositor merges them into one icon by `id`
and takes the topmost row: otherwise the down arrow would move from the picture
to its own caption.

**The theme clips the window contents itself.** `canvas:put_rows` keeps to the
canvas boundary, not the window frame's: extra rows would land over the bottom
edge and below the window. Usually there are none — the viewport is made to fit
the frame exactly — but on a resize a frame of the previous geometry arrives,
and on the screen this looks like a broken window frame, not like a late frame.

**The hit map and the drawing are computed from one table.** A separate
formula for the click will one day drift away from the drawing, and the
"close" button will end up one character to the left of where it appears. The
same goes for geometry: while it was a constant inside the compositor, a
taskbar at the bottom required changing the compositor — that is, the
mechanics would again know about the look.

**The frame thickness is declared by the theme, not by the compositor.** It
determines the size of the viewport the window's program gets, the cursor
offset, and the minimum window size. A theme with a title bar inside the frame
takes three rows at the top; a window computed with a thickness of one would
give the program one row more than is visible, and a window smaller than its
own frame would give a viewport of zero size — that is, a refusal on opening,
not a crooked look.

A theme that asks for more rows than the screen has does not crash the
compositor: the compositor reduces the geometry to the screen and draws.
Otherwise windows would slide off the edge silently.

## Desktop widgets

A desktop widget (FR-006 in `chicago/shell`) is a view window without the
window: a registry entry whose process the compositor spawns like the state
provider of a view window, and whose published state the theme draws in a
panel on the desktop, under every window. The base discovers nothing and
draws nothing: the shell lists the entries, the theme draws them.

```lua
local ok, err = library.run({
    chrome = theme,
    -- The shell reads the registry (meta.type: chicago.widget) and hands the list over.
    widgets = function()
        return {{entry = "app.monitor:memory", title = "Memory", w = 20, h = 6,
                 order = 20, opens = "chicago.shell.taskman:window"}}, nil
    end,
})
```

- **Lifecycle.** The list is read after logon — so every widget runs under the
  logged-on user, like a window — and again on `desktop.refresh`. New entries
  are spawned, entries that vanished are stopped and forgotten, stopped ones
  are spawned again. Order: `order` (default 100), then the entry id. Ids are
  `g<n>` in the order of spawning; a respawned widget keeps its id. A provider
  that answers no list at all changes nothing: a registry hiccup must not
  blank the desktop.
- **Spawn.** `spawn_monitored(entry, workers host, compositor name, widget id,
  nil, {width, height, cell_w, cell_h})` — the call of a view window's state
  provider, with the compositor's name in the context. `width` and `height`
  are the widget's cells. A terminal resize and a changed size send the
  process a `resize` event on `window.input`, as a provider gets it.
- **Size.** `w` 10..40 and `h` 2..16 whole cells, 20×5 when not given.
  Outside the limits the widget is not spawned and not clamped — a tree laid
  out for another size would be another widget; the status line names the
  entry and the limit.
- **State.** The process publishes through `desktop.state` with its widget id,
  exactly as a view window's provider does, and only from the pid the
  compositor spawned for that widget: nobody else can draw into it. Each state
  bumps `state_revision` and redraws.
- **Stopped.** A widget whose process exits keeps its last state and gets
  `stopped = true`; the status line names the entry. `desktop.refresh` spawns
  it again.
- **Theme.** Both `fill` (cells) and `paint` (pixels) get `state.widgets`, a
  list in display order of `{id, entry, title, opens, w, h, waiting, stopped,
  content_state, state_revision}` — a view window's shape, so the SDK renderer
  takes a widget as it is. `waiting` stays true until the first state. The
  stock theme of this module does not draw widgets.
- **Hits.** A theme gives one record per widget row in `hits.desktop`: an icon
  row plus `widget = <id>`, with `entry` naming what a click opens (`opens`). A
  left press opens that window or raises the one already open, like a tray
  item — no selection, no drag, no double click. A right press offers Open,
  and without an entry nothing at all (not the desktop's Properties). The
  arrow keys walk icons only and skip widget records.
- **Status.** `desktop.list` returns `widgets = {{id, entry, title, opens, w,
  h, revision, waiting, stopped}}` — without the tree.

## Pixel chrome: frames as pictures, contents as characters

**This is a second mode of the same contract, not a second compositor.**
Layout, geometry, hit test, catalog, windows, dialogs and the command channel
are shared; what changes is the last layer — how the paint is laid down. A
theme with the field `chrome.pixel = true` and the function `paint` returns
rasters, the frame goes out as `present(rows, {images = placements})`, and the
rows of the window contents **remain characters**.

Why not the whole screen in pixels: bash and htop inside a window can only
produce cells and change on every key press, and a full screen costs 47 ms and
131 KB per frame. Chrome sliced by rows costs **two rasters per key press** —
the window's side edges, and nothing else; measured on the live stand. The
design and all the numbers are in `docs/rfcs/005-pixel-chrome.md`; described
here is what has been built.

```lua
local ok, err = library.run({
    chrome = pixel_theme,          -- a theme with chrome.pixel = true and chrome.paint
    pixels = true,                 -- a person's DECISION, not the presence of graphics
    cell_size = gfx.cell_size,     -- the shell asks, the mechanics decide
})
```

### How it is switched on and when it refuses

**The mode is switched on explicitly.** A terminal that can do sixel is no
reason to draw the interface differently from what the person asked for. That
is why this is a parameter of `run` and not an environment variable: both
shells can live in different modes at the same time.

`run` refuses to start rather than silently falling back to characters. The
refusal is the second return value, and each one names its own cause:

- What is wrong: the theme has no `chrome.paint`; What `run` answers: "the theme has no chrome.paint"
- What is wrong: the shell did not give `options.cell_size`; What `run` answers: "the shell gave nothing to learn the cell size with"
- What is wrong: `cell_size()` returned `nil`; What `run` answers: the terminal's reason in full ("the terminal did not say how large a cell is…")
- What is wrong: the cell size is zero or negative; What `run` answers: both numbers are named

A silent fallback would be the worst outcome here: a picture of the wrong size
looks like a drawing error, not like a question nobody asked.

For taskbar and menu hits, `bottom_row` sets the bottom row of the rectangle,
inclusive. Without the field the hit takes the one row `row`. One menu item
stays one hit with `level` and `slot`, even when its picture takes several
rows: the keyboard visits each item once.

### Frame order

The order is not cosmetic — swap two steps, and the screen will be wrong:

1. **Fill.** `chrome.fill(canvas, width, height, state)` draws the desktop
   background in cells. Called in both modes.
2. **Window contents.** In pixel mode, for each window that is not minimized,
   bottom to top, the compositor first calls the optional
   `chrome.window_background(canvas, window)`, then lays the window's contents
   inside the frame by the theme's insets, clipping extra rows. This call lets
   the theme cover the text of a lower window with the background of an upper
   one. Mouse input goes to the contents relative to the first cell of its
   viewport, taking `left` and `top` from `window_insets()` into account.
3. **`chrome.paint(state, cell_w, cell_h)`** — the theme returns the placements
   and the hit map.
4. **Spaces under placements.** Under every picture the canvas is wiped with
   spaces. A character left under a picture will come out at the first redraw
   of the row — and will not be visible on any partial snapshot.
5. **`present(rows, {cursor, images})`.**

### What the theme receives

`chrome.paint(state, cell_w, cell_h)`; `cell_w`, `cell_h` are the cell size in
pixels, exactly what `options.cell_size` returned. The theme does not ask for
it itself: on a terminal that gives no answer it would draw at the wrong size.

On every `resize` the compositor calls `options.cell_size` again, then
`window_insets` and `layout`, recomputes the client sizes and passes the new
`cell_w`/`cell_h` to the state providers. This is needed even when the number
of rows and columns stays the same: changing the terminal font changes the
cell's pixels. If the theme's geometry depends on the cell, the callback
updates it before returning the sizes. An invalid new size keeps the last
working geometry and shows the reason in the status.

`state` is the union of what arrives in character mode through three calls.
The field names are the same on purpose: a theme that can do both modes
recognizes them without translation.

- Field: `width`, `height`; What it is: the screen in cells
- Field: `top`, `bottom`; What it is: the first and the last row free for windows
- Field: `windows`; What it is: the windows in z-order; the last one is drawn on top
- Field: `focused_id`; What it is: the id of the focused window or `nil`
- Field: `items`, `failure`, `selected`; What it is: the desktop layout: shortcuts, the failure reason, the selected one
- Field: `menu`; What it is: `{items, failure, open}`, or `nil` — the menu is closed
- Field: `status`, `clock`; What it is: the status line and the clock
- Field: `hint`; What it is: the hint on the empty desktop
- `widgets` — desktop widgets in display order, each shaped like a view window; see "Desktop widgets"
- `balloon` — the balloon tip on screen or nil, the same table `bars` gets; its hits go into `hits.bars`

A window in `state.windows` carries: `id`, `title`, `x`, `y`, `w`, `h`, `window_type`
(`app` / `dialog` / `tool`), `opened_by`, `minimized`, `maximized`, `ready`, `flashing`, `flash_lit`,
`content` (`cells` / `pixels`), and for a view window — `render`, `waiting`,
`state_revision` and the `content_state` itself.

`paint` returns a table:

```lua
{
    placements = {
        {id = "win:w1:title", raster = <gfx.Raster>, x = 10, y = 3, cols = 60, rows = 2},
        {id = "win:w1:left",  raster = <gfx.Raster>, x = 10, y = 5, cols = 1,  rows = 20},
    },
    hits = {desktop = {…}, bars = {…}, menu = {…}},
}
```

- **Placement coordinates are in CELLS**, one-based, as everywhere here.
- **`id` must be stable between frames**: by it the surface recognizes the
  same picture, and a changed id is a delete plus an insert, that is, flicker.
- **The list is complete.** A placement missing from the list will not be on
  the screen; that is the way to remove a menu — do not draw it.
- **The raster is optional.** A placement without one means "this picture is
  already on the screen, leave it as it is". All the savings rest on this — and
  so do the checks of the mechanics, which have no rasters at all.
- **Hits come in GROUPS.** A flat list is not guessed at; it produces a
  complaint in the log: `id` means different things for the desktop, the bars
  and the menu, and parsing by guess would one day hand a click to the wrong
  one. The records inside the groups are the same as in character mode.
- **A click does not work — look at the status line first.** In this mode the
  mechanics call neither `bars` nor `menu`; everything that catches a click
  comes from `paint`. A theme that returned hits in the wrong shape gets a
  complaint — and it goes not only to the log (which is muted on the terminal
  host and will tell nobody anything) but also to the status line. "The mouse
  does not work" and "the hits were returned as a flat list" look the same on
  the screen right up to that line.
- **Both can return the desktop hit map** — `fill` and `paint`. In this mode
  the icons are drawn by `paint`, so its hit map takes precedence; if it did not
  return one, the one returned by the fill stays.

In pixel mode `chrome.window`, `chrome.bars`, `chrome.menu` and
`chrome.empty_desktop` are NOT called — `paint` draws all of that. Still called
as before: `chrome.layout`, `chrome.window_insets`, `chrome.icon_grid`,
`chrome.title_button_at` and `chrome.fill`: **geometry and the hit test are
shared**, they are about coordinates, not about paint. That is the reason the
transition is cheap.

### What the compositor does itself

- What: Lays the window rows onto the canvas; Why: a raster theme does not write to the canvas, and bash can only do cells
- What: Lays spaces under placements; Why: a character under a picture will come out when the row is redrawn
- What: Drops invalid placements, naming each one; Why: `present` rejects the whole FRAME, and the compositor calls it through `assert`: a theme with one typo would switch off the whole desktop
- What: Catches a repeated `id` in one frame; Why: two placements with one name are a dispute about what to show, and on the screen it looks like flicker
- What: Reports the frame cost in `desktop.list`; Why: wrongly sliced chrome draws the CORRECT screen, just slowly — and slowness has neither a stack trace nor a symptom

### What the compositor cannot do, and why

- **Create a raster.** A raster is the `gfx` module, and an entry that declares
  an unavailable module brings down the boot ENTIRELY: `node with ID {gfx :gfx} not found`.
  Measured on the installed build. If the mechanics declared `gfx`, they would
  become unusable everywhere there is no graphics, including for those who do
  not need pixels. The stand's rule: **`gfx` is declared only by whoever
  cannot exist without it.** The pixel theme — yes, the mechanics — no.
- **Load a library by name from the registry.** Imports are declared by the
  entry; there is no dynamic `require`. That is why a view window's `render` is
  called by the theme that imports it, and the compositor carries only the
  state to the theme.
- **Rasterize the window contents.** They stay characters; a rasterizer for
  styled rows is not needed here at all — and this is not an omission, it is
  the point of all the calculation: a full screen in pixels costs 47 ms per key
  press.

### Frame cost and how to measure it

`frame` in the `desktop.list` answer: `changed_rows`, `bytes_written`,
`images` — how many placements the frame declared, and `placements_sent` — how
many rasters the runtime actually sent. Older builds do not have the last
field, and **an empty field means "not measured", not zero**: otherwise an old
runtime would silently pass itself off as perfect.

Only a theme with real rasters can use it to measure a "quiet frame": a theme
without them gets zero with any slicing error. That is why this module
deliberately has no such check — it is a criterion for the pixel theme, not for
the mechanics.

### What is verified and what cannot be

There are three levels, and the first two are blind to each other. This is not
a caveat but the reason why, three times in one night, something turned up that
no green suite had shown:

- Level: Parts; What it sees: layout, overlaps, hits; Checked by: the theme probe, pure Lua
- Level: Whole state; What it sees: what opened, what got linked, where the focus went, that there are spaces under a picture; Checked by: a live compositor in a test (see "Development")
- Level: Whole look; What it sees: glyph, edge, color, whether the window body is filled; Checked by: human eyes or a PNG

A green suite of mechanics checks says nothing about the look: it has no
rasters and cannot have any. That is exactly why a snapshot of the WHOLE screen
once found three defects, none of which a partial snapshot had shown.

## Structure

Top to bottom — from the mechanics to what calls them:

- `src/desktop/library.lua` — **mechanics**: windows in z-order, input, hit test, commands, frame assembly. Knows nothing about the look
- `src/desktop/desktop.lua` — **stock shell**: chooses the theme and the name, nothing more
- `src/desktop/chrome.lua` — **stock theme**: frames, titles, buttons, window bar, menu; pure strings with no calls into the runtime
- `src/desktop/window_api.lua` — what a window can ask the desktop for: open, close, raise, ask. Takes the compositor's name from the process context
- `src/desktop/programs.lua` — what a registry entry says about its program: the window type, "show in the menu", what draws the contents. Pure tables
- `src/desktop/pixels.lua` — pixel frame assembly: spaces under pictures, parsing placements and hits. Pure arithmetic
- `src/desktop/window_pty.lua` — a window with a real program: hands its port to the PTY
- `src/api/` — the command channel, the workshop and their policies
- `src/persist/` — the window storage, registry entry building and the loader
- `src/migrations/` — the table of windows built at runtime
- `src/security/` — policies: for the compositor, the channel, the workshop, windows, access

Two libraries were taken out of the mechanics not for beauty: `programs` and
`pixels` are pure functions without the runtime, and are therefore checked
directly, without a terminal and without graphics. Everything left in
`library.lua` is checked only by a live compositor (see "Development").

Permissions are split on purpose. The compositor needs to spawn processes and
run programs; the command channel needs only to find the compositor and talk
to it. A `spawn` permission on an endpoint would mean that an HTTP request runs
programs bypassing the only place that keeps count of them.

## Development

```bash
make setup     # resolve the dependencies of the module and the harness
make lint      # wippy lint
make test      # standalone harness: registry shape AND live compositors
make verify    # all of the above
```

The suite is about fifty checks in a few seconds, and it is not limited to the
registry shape: half of them start a REAL compositor on a viewport, click into
it with the mouse and press keys. How this works is below, in "The compositor
starts right inside a test".

The sections after that are rules, and each one was bought with a specific
mistake. They read as a list of symptoms, none of which looks like its cause.

The harness in `test/` replaces the module with the working copy from `..`, so
it also starts the desktop without any application:

```bash
cd test && wippy run --host chicago.tui_desktop:terminal desktop
```

A full-screen program cannot be checked by an exit code: without a real
terminal it does not start at all, and once started it writes not lines but a
stream with absolute positioning. The probe [`tools/tui-probe.py`](tools/tui-probe.py)
gives a PTY of a given size, types by a script and parses the stream into a
text grid — the screen snapshot is the proof.

```bash
cd test && python3 ../tools/tui-probe.py --cols 100 --rows 26 --boot 60 \
    --send $'\033n' --send 'echo ok' --send-key enter --expect 'ok' \
    -- wippy run --host chicago.tui_desktop:terminal desktop
```

### A permission for every declared module — by a rule, not by eye

A declared module without a permission **does not refuse loudly**. `env.get`
returns `nil`, and the neighboring `or default` turns a permission refusal into
"nobody set anything"; `db.get` breaks a read only later, during work, when the
query looks guilty. Here this cost one silent setting: the compositor declared
`env`, had no permission, and the overridden name of the window database did
not work.

It is checked by a rule over the module's whole registry: an entry that carries
its own policies must have at least one opening action granted for every
permission-gated module it declares (`env`, `fs`, `sql`, `registry`, `exec`).
The refusal names the entry, the module and the consequence. A separate rule
checks the same for the module allowlist of a window built in the workshop: it
has one policy, known in advance.

The rule does not touch libraries: they carry no policies of their own and work
with the permissions of whoever called them.

### The compositor starts right inside a test

For a day and a half the assumption here was that the mechanics cannot be
checked without a real terminal, and the whole class of checks — z-order,
focus, the closing cascade, resize, dragging — was considered reachable only by
eye through the probe. That is wrong.

**The compositor's screen does not have to be a terminal.** A `tty.viewport` is
created right in the test function, `view:grant()` gives it to the spawned
process — by the same mechanism the compositor uses to hand screens to its
windows — and `library.run` runs inside it with the stock theme. From then on
the test talks to it the same way the command channel does from outside, and
clicks reach its screen as real mouse events through `view:send`.

```lua
local view = tty.viewport({width = 80, height = 24})
local pid = process.with_options({terminal = view:grant()})
    :spawn_monitored("app:test_composer", "app:processes", "compositor.name")
-- wait not at random but for the name to appear in the process registry:
process.registry.lookup("compositor.name")

view:send({type = "mouse", action = "press", button = "left", x = 4, y = 8})
process.send("compositor.name", "desktop.list", {reply_to = tostring(process.pid())})
```

This is how the following were checked: a dialog's link to its window, raising
a window by a click, the z-order, the focus passing on when the top window
closes, and the visibility of a refusal of a command without a return address.
The full live example is `test/src/wiring_test.lua` and
`test/src/test_composer.lua`.

Two things without which this does not work:

- **Wait for an event, not for time.** The compositor appears in the process
  registry when it is ready to accept commands — that is the signal. Readiness
  after a click is checked the same way: the compositor has a status line that
  a click on the empty desktop clears, and its disappearance is the milestone
  that shows the event was handled. Checks based on time lie.
- **A check must not add its own way to press things.** Buttons are opened
  with the mouse, because a person opens them with the mouse; digit shortcuts
  added to the interface for a check are a tool's limitation leaking into the
  product.

### A function nobody calls is green in any suite

A function that nobody calls passes any suite of checks — and fails on the
first real call, usually for another person. In one night this happened twice:
the desktop fill, which the compositor started calling, failed at once, while
before that it had been "working"; and three late `local`s (see below).

That is why the extracted libraries (`pixels`, `programs`) have a rule: the
list of exported functions is compared with the list of covered ones, and a new
function without a check turns the suite red. There is no such rule for the
paths inside the compositor — they have to be walked by eye; that is how three
unchecked ones were found: an unknown `window_content`, the death of a state
provider, and `resize` of a view window, which has no viewport.

### Everything a function calls is declared above it

This cost an hour on a false trail, and the symptom did not point to the cause:
`local function forget` stood BELOW `close_window`, which calls it — so inside
`close_window` it is a global variable, that is, `nil`. It crashed exactly on
closing a view window, the only path where `close_window` calls `forget` directly.

**From outside, a crashed compositor looks like a message delivery problem**:
the name stays in the registry, the screen holds the last frame, and there are
no answers — and an hour goes into looking for a race that does not exist.
Before looking for one, look at the compositor's SCREEN: in a test this is
`view:snapshot(-1)`, and it shows both the status line and the live windows at
once.

Mutual recursion is fixed with a forward declaration: `local forget: any` above
both functions, `forget = function(window)` below.

### Two traps that cost time here

**The tail call.** In go-lua v1.5.18 a call to a yield function that stands
last, as `return f(...)`, is not executed at all — silently, in 0 ms, with an
empty result. All calls of this stack have that form: `tty.start`,
`surface:present`, `viewport:send`, `session:send`. That is why they are wrapped
in `assert(...)`: this is not style, it is a workaround.

**A screen without a size.** A start not from a terminal (a script, CI, a pipe)
answers `screen_size()` with zeros, and the canvas rejects such a width — the
compositor crashed on the very first line. That is why the geometry is checked
rather than taken on trust.

## Publishing

```bash
make release-check
make publish            # private; VIS=public — only deliberately
```

See [AGENTS.md](AGENTS.md) — the development and release contract,
[CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

Themes can define `content_colors(window)`, which returns a table
`{foreground = "#c0c0c0", background = "#000000"}` or `nil`. The pixel
compositor applies these colors as defaults to the window's rows after ANSI
parsing, keeping explicitly set colors. The fill of the empty area is still
drawn by the theme in `window_background`; in character mode the theme passes
the same defaults to `canvas:put_rows(x, y, rows, width, defaults)`.

## Logon

The compositor runs under the service actor from `meta.command.security`, and
without a logon every window would run under that actor too. `options.logon`
is a shell function that the compositor calls **before the first desktop frame
and before reading commands**: a window opened through the channel before the
logon would be born without an identity.

```lua
library.run({chrome = theme, logon = function(screen) … end})
```

`screen` is what the dialog uses to draw itself on the same terminal: `events`
(the `tty` channel), `width`, `height`, `canvas`, `pixels` (the frame mode),
`cell()` — the cell size, `resize()` — reread the size and recreate the canvas
(call it on the `resize` event), `present(painted)` — show a frame; in pixel
mode `painted` carries `placements`, as with `paint`.

The function returns `{actor, scope, context}` or `nil, reason`. The compositor
spawns **every** window under `actor`/`scope` — both the state provider of a
view window and a process with a viewport; `context` is added to the context of
the window's process (usually `user_id`, `user_name`) and is read by the `ctx`
module. The compositor itself stays under its own actor: it touches the
registry and the window storage with its own permissions.

- **A logon refusal is an exit, not a desktop under the service actor.** A
  desktop without a user would look logged on, while the windows would work in
  the name of the process.
- **The identity is fixed at the moment of spawning.** Open windows do not
  "move over" when the user changes; changing the user means closing the
  windows and logging on again.
- **A window inherits the scope with an addition**: the policies of its entry
  are added to the user's scope. This applies to workshop windows too.
- The compositor needs the `process.security` permission — it is in `desktop_runtime`.
- `desktop.list` returns `user = {id, name}`: from outside this is the only way
  to tell windows under a user from windows under the service actor.

### A window that only some people may open: `meta.requires`

An entry may name the action a person needs to open it. The compositor asks
the logged-on identity's scope (`scope:evaluate(actor, action, entry)`) before
spawning, and refuses with the person, the entry and the action named — on
the desktop's notice line for alt+n and the menu, in the reply for
`desktop.open`. A desktop without logon asks nobody, as before.

`window_pty` declares `requires: tui_desktop.pty`: the program runs under the
entry's own policy (exec), that is, a shell on the server under the OS
account, whoever logged on. An application grants the action to the people
who may have it.

## Several desktops in one runtime

A runtime serving remote terminals (the `terminal.ssh` host) runs one desktop
per connection. They answer to one family of names: a compositor claims the
first free of `name`, `name.2` … `name.<service_slots>` (default
`window_api.DESKTOP_SLOTS`, 16), and the registry releases a name with its
process, so a number is reused. The process registry has no listing, so this
rule is the directory, and it lives in one place:

- `window_api.desktop_names(family, slots?)` — every name of the family;
- `window_api.desktops(name)` — the ones running now, `{name, pid}` each,
  the unnumbered first; a numbered name counts as its family
  (`window_api.desktop_family`);
- `desktop.list` answers `service` — the name this desktop claimed — and each
  window's `pid`.

Whoever addresses "the desktop" from outside (a tray item, a refresh, the
workshop) iterates `desktops(family)`: one name would reach the first
connection only.

### A desktop whose terminal went away closes its windows

A connection drops. The desktop ends as "Shut Down" does — windows closed,
not left running with nobody to see them (a bash among them) — on either of
two signals:

- **CANCEL** (`process.event.CANCEL`): the `terminal.ssh` host asks the
  program to finish when its client leaves; the runtime does the same when it
  stops.
- **A frame that could not be written.** `out:present` failing means the
  terminal is gone; the compositor stops drawing, closes its windows and
  exits. It used to `assert` there, and the windows outlived it.

The cleanup after either writes nothing to the terminal that is gone, so the
desktop ends with success, not with the error of a write nobody could read.

## Empty-desktop context menu

`library.run` accepts `desktop_menu = function() return items, reason end`.
The callback runs on each right click on empty desktop space. Items use the
ordinary menu format (`label`, `entry`, optional `args` and `image`) and the normal
window-opening/identity checks. Errors are shown as desktop notices. Icon and
widget menus retain their existing behavior. `desktop_properties` remains
supported when no callback is supplied. Chicago shell adapts registry entries
with `meta.type: chicago.desktop_menu` to this callback.

## Full-screen passive previews

Window metadata `presentation: true` requests a borderless full-terminal client,
including the taskbar rows. The compositor maintains the viewport on resize,
consumes a dismissing key/mouse gesture and closes the preview, restoring the
underlying desktop. It ignores the opening release and duplicate pointer reports.
A presentation follows its opener's lifetime. This is a passive preview mode,
not an idle detector or lock screen. Pixel themes opt in with
`chrome.presentation = true` and paint the `state.presentation` window without
chrome; unsupported pixel themes report a refusal. Cell mode needs no theme hook.
