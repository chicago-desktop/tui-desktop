#!/usr/bin/env python3
"""TUI probe: runs a command in a real PTY and captures the screen as text.

Same idea as tools/probe.mjs for the browser: a full-screen program cannot be
checked by looking at its code or its exit code. `wippy run tui` does not
start at all without a real terminal, and once running it writes not lines
but an ANSI stream with absolute positioning.

The probe gives it a PTY of a given size, types according to a script, and
parses the stream into a character grid. It parses exactly what the runtime's
surface writes:
    \\x1b[<row>;<col>H  text  \\x1b[0m\\x1b[K
plus the alternate-screen switch and frame synchronization, which do not
affect the content.

    python3 tools/tui-probe.py --cols 100 --rows 30 -- wippy run tui
    python3 tools/tui-probe.py --send 'echo probe-ok' --send-key enter -- wippy run tui
"""

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

CSI = re.compile(rb"\x1b\[([0-9;?]*)([A-Za-z])")

KEYS = {
    "enter": b"\r",
    "tab": b"\t",
    "esc": b"\x1b",
    "space": b" ",
    "backspace": b"\x7f",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "right": b"\x1b[C",
    "left": b"\x1b[D",
    "ctrl+q": b"\x11",
    "ctrl+c": b"\x03",
    "ctrl+d": b"\x04",
}


def mouse(col, row, button=0, press=True):
    """A mouse event in SGR 1006 format — the one the compositor enables.

    Without it the probe can only use the keyboard, and then the shell grows
    keyboard paths that real Windows does not have: the interface starts
    adapting to the tool's limitation. Coordinates are 1-based, as on the
    screen.
    """
    tail = b"M" if press else b"m"
    return b"\x1b[<%d;%d;%d" % (button, col, row) + tail


class Ordered(argparse.Action):
    """Collects steps into ONE list in the order they were given.

    The script used to be assembled by type — all --send first, then resizes,
    then keys — and there was no way to express "click, then type": it came
    out as "type, then click", silently and wrong.
    """

    def __call__(self, parser, namespace, value, option_string=None):
        steps = getattr(namespace, "steps", None)
        if steps is None:
            steps = []
            setattr(namespace, "steps", steps)
        steps.append((self.dest, value))


class Screen:
    """A minimal screen: positioning, printing, erase to end of line."""

    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.grid = [[" "] * cols for _ in range(rows)]
        self.x = self.y = 0

    def _put(self, text):
        for ch in text:
            if ch == "\r":
                self.x = 0
            elif ch == "\n":
                self.y = min(self.y + 1, self.rows - 1)
            elif ch == "\b":
                self.x = max(0, self.x - 1)
            elif ch >= " ":
                if self.x < self.cols and self.y < self.rows:
                    self.grid[self.y][self.x] = ch
                self.x += 1

    def feed(self, data):
        pos = 0
        while pos < len(data):
            match = CSI.search(data, pos)
            if not match:
                self._put(data[pos:].decode("utf-8", "replace"))
                return
            if match.start() > pos:
                self._put(data[pos:match.start()].decode("utf-8", "replace"))
            params, final = match.group(1), match.group(2)
            self._apply(params, final)
            pos = match.end()

    def _apply(self, params, final):
        args = [int(p) for p in params.split(b";") if p.isdigit()]
        if final == b"H":
            row = args[0] if len(args) > 0 else 1
            col = args[1] if len(args) > 1 else 1
            self.y = max(0, min(self.rows - 1, row - 1))
            self.x = max(0, min(self.cols - 1, col - 1))
        elif final == b"K":
            mode = args[0] if args else 0
            if self.y < self.rows:
                start = self.x if mode == 0 else 0
                end = self.cols if mode in (0, 2) else self.x + 1
                for col in range(start, min(end, self.cols)):
                    self.grid[self.y][col] = " "
        elif final == b"J" and args and args[0] == 2:
            self.grid = [[" "] * self.cols for _ in range(self.rows)]
        # SGR, cursor modes, altscreen and synchronization do not change the content.

    def render(self):
        return "\n".join("".join(row).rstrip() for row in self.grid)


def set_size(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cols", type=int, default=100)
    parser.add_argument("--rows", type=int, default=30)
    parser.add_argument("--boot", type=float, default=45.0,
                        help="how long to wait for the first frame, seconds")
    parser.add_argument("--settle", type=float, default=2.0,
                        help="pause between script actions, seconds")
    parser.add_argument("--tail", type=float, default=None,
                        help="how long to wait after the last step, seconds "
                             "(default: one pause; shutting down the whole "
                             "runtime takes noticeably longer)")
    parser.add_argument("--send", action=Ordered, default=[],
                        help="type a string (repeatable)")
    parser.add_argument("--send-key", action=Ordered, default=[],
                        help="send a key: " + ", ".join(sorted(KEYS)))
    parser.add_argument("--expect", action="append", default=[],
                        help="a substring that must appear on the screen")
    parser.add_argument("--click", action=Ordered, default=[],
                        help="mouse click at COL,ROW (1-based coordinates)")
    parser.add_argument("--dblclick", action=Ordered, default=[],
                        help="double click at COL,ROW")
    parser.add_argument("--move", action=Ordered, default=[],
                        help="move the mouse to COL,ROW without pressing (SGR 1003, button 35)")
    parser.add_argument("--wheel", action=Ordered, default=[],
                        help="mouse wheel at COL,ROW,up|down (SGR 1006, buttons 64 and 65)")
    parser.add_argument("--drag", action=Ordered, default=[],
                        help="drag with the left button from COL1,ROW1 to COL2,ROW2: press, motion row by row, release")
    parser.add_argument("--resize", action=Ordered, default=[],
                        help="resize the terminal to COLSxROWS (repeatable)")
    parser.add_argument("--raw", help="file for the raw stream")
    parser.add_argument("cmd", nargs=argparse.REMAINDER)
    opts = parser.parse_args()

    cmd = opts.cmd[1:] if opts.cmd and opts.cmd[0] == "--" else opts.cmd
    if not cmd:
        parser.error("no command given")

    child, fd = pty.fork()
    if child == 0:
        os.execvp(cmd[0], cmd)

    set_size(fd, opts.cols, opts.rows)
    screen = Screen(opts.cols, opts.rows)
    raw = open(opts.raw, "wb") if opts.raw else None

    # Script: [(moment, what to send)] in the order the steps were given on
    # the command line. The first step comes after boot.
    def point(spec, what):
        match = re.fullmatch(r"\s*(\d+)\s*,\s*(\d+)\s*", spec)
        if not match:
            parser.error(what + " is given as COL,ROW, got: " + spec)
        return int(match.group(1)), int(match.group(2))

    script = []
    moment = opts.boot
    for kind, value in getattr(opts, "steps", []):
        if kind == "send":
            script.append((moment, value.encode()))
        elif kind == "send_key":
            if value not in KEYS:
                parser.error("unknown key: " + value)
            script.append((moment, KEYS[value]))
        elif kind == "click":
            col, row = point(value, "a click")
            script.append((moment, mouse(col, row, press=True) + mouse(col, row, press=False)))
        elif kind == "dblclick":
            col, row = point(value, "a double click")
            # Two full clicks in a row as one chunk: a double click is detected
            # by the interval between them, and a script pause between steps
            # would break it.
            single = mouse(col, row, press=True) + mouse(col, row, press=False)
            script.append((moment, single + single))
        elif kind == "move":
            col, row = point(value, "a move")
            # Motion without a button is code 35 (32 "motion" + 3 "no button");
            # the runtime enables mode 1003, so the terminal sends it anyway.
            script.append((moment, mouse(col, row, button=35, press=True)))
        elif kind == "drag":
            match = re.fullmatch(r"(\d+),(\d+),(\d+),(\d+)", value)
            if not match:
                parser.error("a drag is given as COL1,ROW1,COL2,ROW2, got: " + value)
            c1, r1, c2, r2 = (int(match.group(i)) for i in range(1, 5))
            # As one chunk: press, motion with the button held (SGR: button + 32)
            # through every intermediate row, release at the end point.
            chunk = mouse(c1, r1, press=True)
            steps = max(abs(r2 - r1), abs(c2 - c1), 1)
            for i in range(1, steps + 1):
                col = c1 + (c2 - c1) * i // steps
                row = r1 + (r2 - r1) * i // steps
                chunk += mouse(col, row, button=32, press=True)
            chunk += mouse(c2, r2, press=False)
            script.append((moment, chunk))
        elif kind == "wheel":
            match = re.fullmatch(r"(\d+),(\d+),(up|down)", value)
            if not match:
                parser.error("the wheel is given as COL,ROW,up|down, got: " + value)
            button = 64 if match.group(3) == "up" else 65
            # The wheel has no release: the terminal sends only the press.
            script.append((moment, mouse(int(match.group(1)), int(match.group(2)), button=button, press=True)))
        elif kind == "resize":
            match = re.fullmatch(r"(\d+)x(\d+)", value)
            if not match:
                parser.error("a size is given as COLSxROWS, got: " + value)
            script.append((moment, ("resize", int(match.group(1)), int(match.group(2)))))
        moment += opts.settle

    deadline = time.time() + moment + (opts.settle if opts.tail is None else opts.tail)
    started = time.time()
    step = 0
    bytes_seen = 0

    try:
        while time.time() < deadline:
            if step < len(script) and time.time() - started >= script[step][0]:
                action = script[step][1]
                if isinstance(action, tuple):
                    # Resize: the kernel itself sends SIGWINCH to the terminal's
                    # process group, and we rebuild the screen for the new size.
                    _, cols, rows = action
                    set_size(fd, cols, rows)
                    screen = Screen(cols, rows)
                    opts.cols, opts.rows = cols, rows
                else:
                    os.write(fd, action)
                step += 1
            ready, _, _ = select.select([fd], [], [], 0.2)
            if not ready:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            bytes_seen += len(chunk)
            if raw:
                raw.write(chunk)
            screen.feed(chunk)
    finally:
        # Whether it exited on its own is the only way to tell a clean exit on
        # ctrl+q from a program that had to be killed from outside.
        exited_on_its_own, exit_code = False, None
        try:
            done_pid, status = os.waitpid(child, os.WNOHANG)
            if done_pid == child:
                exited_on_its_own = True
                exit_code = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            exited_on_its_own = True
        if not exited_on_its_own:
            try:
                os.kill(child, signal.SIGTERM)
            except ProcessLookupError:
                pass
        os.close(fd)
        if raw:
            raw.close()

    print("=" * opts.cols)
    print(screen.render())
    print("=" * opts.cols)
    print(f"[probe] bytes read: {bytes_seen}, script steps: {step}/{len(script)}")
    if exited_on_its_own:
        print(f"[probe] the program exited on its own, code {exit_code}")
    else:
        print("[probe] the program did not exit — had to send SIGTERM")

    rendered = screen.render()
    failed = [needle for needle in opts.expect if needle not in rendered]
    for needle in opts.expect:
        print(f"[probe] {'MISSING' if needle in failed else 'found  '}: {needle!r}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
