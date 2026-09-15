# Agent instructions

Read and follow [AGENTS.md](AGENTS.md) in full before changing this repository.
It defines the implementation, verification, security, and publishing
requirements.

The module's design and its command channel are described in [README.md](README.md).
Below is what you need to know before the first edit and what the code does not
show.

## Changes have to be checked by eye

A full-screen program cannot be checked by its exit code: without a real
terminal it does not start at all, and once running it writes not lines but a
stream with absolute positioning. `make test` checks the shape of the registry —
it will not see a shifted border, lost input, or a cursor that ended up one row
above its text.

The harness starts the desktop without any application, and the probe gives it a
PTY of a given size, types according to a script and parses the stream into a
text grid:

```bash
cd test && python3 ../tools/tui-probe.py \
    --cols 100 --rows 26 --boot 60 --settle 3 \
    --send $'\033n' --send 'echo ok' --send-key enter --expect 'ok' \
    -- wippy run --host chicago.tui_desktop:terminal desktop
```

Take `--boot` of at least 60 seconds: the whole runtime starts before the first
frame. **Show a rendering or input change with a screen snapshot** — checked by
your own eye or someone else's, but with a snapshot.

## `make test` requires `--host`

The module declares its own `terminal.host` — it needs `hide_logs` — and from
then on the CLI's autodetection refuses to choose: it counts `terminal.host`
entries, and there are two. The Makefile has this built in (`TEST_HOST`); when
running `wippy test` by hand you have to name the flag yourself.

## `wippy lint` strictly distinguishes `integer` and `number`

Drawing calls (`canvas:put`, `string.rep`, `tty.text.truncate`) require
`integer`, while `math.floor`, `math.max`, `//` and any numeric comparison give
`number`. Ordinary arithmetic on screen sizes therefore does not pass. What
works:

- **`: any` on the parameter** — `function f(width: any)`; the runtime supports
  annotations too. `any` passes where `number` is rejected, but
  `tty.text.truncate` requires exactly `integer`.
- **`math.tointeger(x) or 0`** — a reliable way to get an `integer` from a value
  that came from the runtime.
- **Choose a bound with an expression** (`w < 1 and 1 or w`): reassignment
  returns the type to `number`.
- **Keep one structure with the full set of fields**: a field added to a table
  later does not exist for the checker — hence "arithmetic on never".

Without this, an edit turns into a dozen lint runs of guesswork.

## Two runtime traps

The tail call of a yield function and the screen without a size are described in
the README, in the section "Two traps that cost time here". Both are silent: the
first does not perform the call at all, the second crashes the compositor on its
first line. New code in `src/desktop/` must wrap `tty` calls in `assert(...)` and
check the geometry.
