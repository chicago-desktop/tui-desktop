---
name: tui-desktop
description: Drive the windows of a live chicago/tui-desktop desktop through its command channel — open a window with a program, type into it, read its screen, move or close a window, start the desktop itself.
---

# Driving the desktop

The desktop holds windows with real programs. An agent drives them through the
command channel while a person works at the same screen: there is one
compositor, and it serializes keyboard input and commands itself.

Work through the channel, not through the person's keyboard: their terminal
does not belong to you.

## Address and access

The endpoints live behind the application's authenticated router, and **the
prefix is set by the application, not the module**: on the kickside stand it is
`/api/v1`, in the module's harness — `/api`. A mistake here does not look like
a mistake: an unknown path returns the facade page with code 200, so "there is
no endpoint" is indistinguishable from "the endpoint answered". The sign of a
hit is `application/json` in the response.

The token comes from the application's `.env.local` (`KICKSIDE_API_TOKEN`) and
lives for one day; `{"error":"Authentication required"}` means it expired, not
that something broke.

```bash
set -a; . ./.env.local; set +a
API="http://localhost:8099/api/v1/tui-desktop"     # the prefix comes from the application
AUTH="Authorization: Bearer $KICKSIDE_API_TOKEN"
```

## What you can do

Every command answers `{"success":true,...}` or the reason for a refusal. There
is no silence: a desktop that is not running, a desktop that does not respond
and a window that does not exist are three different answers.

```bash
curl -s -H "$AUTH" $API/windows                       # what is open, focus, screen size

curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{"title":"build","command":"/bin/bash --noprofile --norc","x":4,"y":3,"w":80,"h":20}' \
  $API/windows                                        # → {"window":{"id":"w1",...}}

curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{"entry":"app.desktop:window_calc"}' $API/windows   # an application window

curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{"text":"make test","enter":true}' $API/windows/w1/type

curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{}' $API/windows/w1/screen                      # → {"rows":[...]} — the window's screen
```

A window with a program is opened with `command`, an application window with
`entry` (a process entry declared by the application). What is declared is
visible in the desktop menu on `alt+o`; the same mark `meta.type:
tui_desktop.window` can be searched for in the registry.

The other actions have the same form: `key` (`key`, `ctrl`, `alt`, `shift`),
`move` (`x`, `y`), `resize` (`w`, `h`), `focus`, `minimize` (`value`), `close`.

## How to read the result

**The screen is the only evidence.** The return code of `type` only says that
the keys reached the window; what the program did with them is visible only in
`screen`. So after every meaningful input, read the screen and judge by it.

**A window does not respond instantly.** A fresh window returns `"ready":
false` until the program has drawn its first frame; input during that interval
is refused with a reason. Read `screen` repeatedly until the expected content
appears, not right after `type`.

**The screen is a snapshot, not a log.** `rows` holds what is visible now: long
output scrolls off the top for good. Give a command whose output you need in
full a file (`make test > /tmp/out.log 2>&1`) and read it separately.

## Building a new window

A window does not have to be written as a file: its code travels in the request
body, is applied to the registry and appears in the menu immediately.

```bash
curl -s -H "$AUTH" -H 'Content-Type: application/json' -X POST \
  -d '{"name":"clock","title":"Clock","width":30,"height":6,
       "modules":["time"],"source":"local tty = require(\"tty\") … return {main = main}"}' \
  ${API%/tui-desktop}/tui-desktop/apps
```

The code must return a table with `main`, and modules are taken from an
allowlist (`channel`, `time`, `tty`, `json`, `sql`, `env`; `tty` and `channel`
are always added). A saved window survives a restart: `GET /tui-desktop/apps`
shows the list and the `live` flag, `DELETE /tui-desktop/apps/{name}` removes
one.

Such a window is opened like any other — by the `entry` from the response.

## Starting the desktop

```bash
wippy run --host chicago.tui_desktop:terminal desktop
```

`--host` is required: the CLI's terminal host autodetection counts
`terminal.host` entries, and this module brings a second one. The command takes
over the whole terminal and starts the full runtime together with the gateway,
so a person must start it — an agent has no terminal, and without one
`screen_size()` answers with zeros.

Whether the desktop is up can be checked with a single `GET /windows`: it
answers with a list, not "not running".
