#!/usr/bin/env python3
"""Boot the aarch64 kernel, screenshot the display, and read the text back.

The kernel already reads its own framebuffer back and reports whether what it
drew is there. That proves the memory is writable and holds what was written;
it does not prove the memory is *the screen*. Only asking the machine for a
picture proves that QEMU accepted the ramfb configuration and is scanning out
that region — so this checks the half the kernel cannot.

What it checks is the boot log itself. The kernel mirrors its console to the
display, so the screen holds text, and this replays the same wrapping and
scrolling over the serial log to work out which character should be in which
cell — then compares every cell against the glyph, pixel by pixel.

That is deliberately not the same code. The kernel draws from
graphics/font8x8.zig; this draws from tools/font8x8.txt, which the generator
turns into it. A generator that dropped a row, a console that wrapped at the
wrong column, a scroll that sheared by a pixel, a stride the drawing code got
wrong — each of those makes the two disagree, and none of them is visible in
a check that looks at four solid rectangles.
"""

import os
import re
import socket
import subprocess
import sys
import tempfile
import time

WIDTH, HEIGHT = 1024, 768

# What graphics/console.zig is told to use in main_aarch64.zig. Repeated here
# on purpose: a check that read its expectations from the thing under test
# would agree with any picture at all.
SLATE = (0x11, 0x1A, 0x20)
WHITE = (0xFF, 0xFF, 0xFF)
SCALE = 2
GLYPH_W, GLYPH_H = 8, 8
CELL_W, CELL_H = GLYPH_W * SCALE, GLYPH_H * SCALE
COLS, ROWS = WIDTH // CELL_W, HEIGHT // CELL_H

BOOT_MARKER = b"KyanOS aarch64: EL1 boot ok"

# The first thing printed after the console starts mirroring to the screen.
# Everything from here on is on the display as well as the serial line, so it
# is where the replay begins.
MIRROR_MARKER = b"  [ok] console on screen:"

FONT_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "font8x8.txt")


def load_font():
    """Read tools/font8x8.txt into {char: [8 rows of 8 bools]}.

    The same file make_font.py reads, parsed again here rather than imported,
    so that a bug in the generator shows up as a disagreement instead of being
    shared by both sides.
    """
    glyphs = {}
    code, rows = None, []
    with open(FONT_SRC) as f:
        for line in f:
            line = line.rstrip("\n")
            if code is None and line.startswith("#"):
                continue
            if code is None:
                m = re.match(r"^(\d+) ", line)
                if m:
                    code, rows = int(m.group(1)), []
                continue
            if not line.strip():
                continue
            rows.append([c == "#" for c in line])
            if len(rows) == GLYPH_H:
                glyphs[chr(code)] = rows
                code = None
    if len(glyphs) != 95:
        raise SystemExit("fb_check: %s has %d glyphs, expected 95"
                         % (FONT_SRC, len(glyphs)))
    return glyphs


def expected_screen(log_bytes):
    """Replay the console over the mirrored part of the log.

    Returns (grid, scrolls), or None if the log never got as far as turning
    the screen console on. Mirrors graphics/console.zig: wrap at the right
    edge, tab to the next multiple of eight, backspace to the previous cell
    (across the left edge to the row above), scroll at the bottom.

    Bytes, not text. The kernel's messages contain em dashes, and the console
    draws one cell per *byte* — so a three-byte character occupies three
    cells, each showing the glyph for '?'. Decoding the log first made this
    check disagree with the screen from the first such message onward, which
    is how that was found.
    """
    start = log_bytes.find(MIRROR_MARKER)
    if start < 0:
        return None
    grid = [[b" "[0]] * COLS for _ in range(ROWS)]
    col = row = 0
    scrolls = 0

    def next_row():
        nonlocal row, grid, scrolls
        row += 1
        if row >= ROWS:
            grid.pop(0)
            grid.append([b" "[0]] * COLS)
            row = ROWS - 1
            scrolls += 1

    for ch in log_bytes[start:]:
        if ch == 0x0A:
            col = 0
            next_row()
        elif ch == 0x0D:
            col = 0
        elif ch == 0x08:
            # Backspace moves and draws nothing, the same as the console does
            # and the same as a terminal does. What erases is the sequence the
            # line editor sends — backspace, space, backspace — and that only
            # comes out right here if this half of it draws nothing.
            if col > 0:
                col -= 1
            elif row > 0:
                row -= 1
                col = COLS - 1
        elif ch == 0x09:
            stop = min((col + 8) & ~7, COLS)
            while col < stop:
                grid[row][col] = b" "[0]
                col += 1
            if col >= COLS:
                col = 0
                next_row()
        else:
            if col >= COLS:
                col = 0
                next_row()
            grid[row][col] = ch
            col += 1
    return grid, scrolls


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    # P6 <w> <h> <max>, whitespace-separated, then raw RGB triples.
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not m:
        raise SystemExit("fb_check: %s is not a binary PPM" % path)
    w, h, maxv = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if maxv != 255:
        raise SystemExit("fb_check: unexpected max value %d" % maxv)
    return w, h, data[m.end():]


def pixel(px, w, x, y):
    off = (y * w + x) * 3
    return tuple(px[off:off + 3])


def compare_cell(px, w, col, row, glyph):
    """Check one character cell against a glyph. Returns a complaint or None.

    Every pixel, not a sample: the whole point is that a cell drawn with the
    wrong glyph, or the right glyph one row out, differs somewhere.
    """
    ox, oy = col * CELL_W, row * CELL_H
    for gy in range(GLYPH_H):
        for gx in range(GLYPH_W):
            want = WHITE if glyph[gy][gx] else SLATE
            for sy in range(SCALE):
                for sx in range(SCALE):
                    got = pixel(px, w, ox + gx * SCALE + sx, oy + gy * SCALE + sy)
                    if got != want:
                        return ("pixel (%d,%d) is #%02X%02X%02X, want "
                                "#%02X%02X%02X" %
                                ((ox + gx * SCALE + sx, oy + gy * SCALE + sy)
                                 + got + want))
    return None


def wait_for_marker(log_path, deadline, proc=None):
    """Wait for the boot marker, or for the deadline, or for QEMU to die.

    Watching the process matters more than it looks. Without it, a QEMU that
    refused to start is indistinguishable from a kernel that booted slowly:
    both sit here until the deadline and report "never reached the boot
    marker", which names the one cause that is not what happened. That is not
    hypothetical — this check failed exactly that way once, and the message
    sent the search in the wrong direction.
    """
    while time.time() < deadline:
        try:
            with open(log_path, "rb") as f:
                if BOOT_MARKER in f.read():
                    return True
        except FileNotFoundError:
            pass
        if proc is not None and proc.poll() is not None:
            return False
        time.sleep(0.25)
    return False


def why_not(log_path, qemu_out, proc):
    """Everything known about a boot that did not get there, as text.

    Printed on the one failure that used to print nothing at all. How far the
    serial log got says whether the kernel died early or was merely slow;
    QEMU's own output says whether it ever started.
    """
    lines = []
    if proc.poll() is not None:
        lines.append("QEMU exited with %d before the marker appeared."
                     % proc.returncode)
    else:
        lines.append("QEMU is still running; the kernel did not get there in "
                     "time.")
    try:
        with open(log_path, "rb") as f:
            serial = f.read()
        lines.append("serial log: %d bytes, last lines:" % len(serial))
        tail = serial.decode("utf-8", "replace").splitlines()[-12:]
        lines.extend("  " + t for t in tail)
    except FileNotFoundError:
        lines.append("serial log: never created — QEMU wrote nothing at all.")
    try:
        with open(qemu_out, "rb") as f:
            out = f.read().decode("utf-8", "replace").strip()
        if out:
            lines.append("QEMU said:")
            lines.extend("  " + t for t in out.splitlines()[-12:])
    except FileNotFoundError:
        pass
    return "\n".join(lines)


def settled_screendump(sock_path, out_path, deadline):
    """Dump the screen until two dumps in a row are identical.

    ramfb hands QEMU a region of guest memory, and with `-display none` there
    is no user interface driving the refresh that copies that memory into the
    surface `screendump` writes out. So a single dump can be a frame or two
    behind what the kernel actually drew — which looks exactly like a console
    that scrolled the wrong number of times, and made this check fail on
    three runs out of three against a kernel that was drawing correctly.

    The kernel has halted by the time this runs, so the framebuffer is not
    changing: once two consecutive dumps agree, the surface has caught up.
    """
    previous = None
    for attempt in range(8):
        screendump(sock_path, out_path, deadline)
        if not os.path.exists(out_path):
            return False
        with open(out_path, "rb") as f:
            current = f.read()
        if previous is not None and current == previous:
            return True
        previous = current
        time.sleep(1.0)
    # Say so rather than checking a frame that is still moving: a flaky check
    # is worse than none.
    raise SystemExit("fb_check: the display never settled — eight dumps and "
                     "no two alike, with the kernel halted")


def screendump(sock_path, out_path, deadline):
    s = socket.socket(socket.AF_UNIX)
    while True:
        try:
            s.connect(sock_path)
            break
        except (FileNotFoundError, ConnectionRefusedError):
            if time.time() > deadline:
                raise SystemExit("fb_check: QEMU monitor never appeared")
            time.sleep(0.25)
    s.settimeout(5)
    try:
        s.recv(4096)          # banner
    except socket.timeout:
        pass
    s.sendall(("screendump %s\n" % out_path).encode())
    # The monitor echoes the command and prints any error; give it a moment
    # and then judge by whether the file arrived, which is unambiguous.
    time.sleep(2)
    try:
        s.recv(65536)
    except socket.timeout:
        pass
    s.close()


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fb_check.py <kernel-image>")
    kernel = sys.argv[1]
    tmp = tempfile.mkdtemp(prefix="clarityfb-")
    log = os.path.join(tmp, "serial.log")
    sock = os.path.join(tmp, "mon.sock")
    shot = os.path.join(tmp, "screen.ppm")
    # QEMU's own stdout and stderr, kept rather than discarded: when it
    # refuses to start, this is the only place that says why.
    qemu_out = os.path.join(tmp, "qemu.out")

    qemu = subprocess.Popen([
        "qemu-system-aarch64",
        "-M", "virt",
        "-cpu", "cortex-a72",
        "-m", "512",
        "-kernel", kernel,
        "-device", "ramfb",
        # No keyboard is attached here, but the serial line is readable now,
        # so the console opens for reading either way and every prompt on the
        # way to the marker below would otherwise wait out the default two
        # minutes. This test never types; it says so.
        "-append", "clarity.idle=3",
        "-serial", "file:" + log,
        "-display", "none",
        "-monitor", "unix:%s,server,nowait" % sock,
        "-no-reboot",
    ], stdout=open(qemu_out, "wb"), stderr=subprocess.STDOUT)

    failures = []
    scrolls = 0
    try:
        # Generous, and deliberately so. This boot has no keyboard attached,
        # which makes it the fastest configuration there is — nine seconds to
        # the marker on the machine this was written on. A number thirty times
        # that is not a margin being tuned; it is there so that when this does
        # fail, "too slow" is ruled out and the report below is about
        # something real.
        deadline = time.time() + 300
        if not wait_for_marker(log, deadline, qemu):
            raise SystemExit("fb_check: kernel never reached the boot marker\n"
                             + why_not(log, qemu_out, qemu))
        deadline = time.time() + 120
        settled_screendump(sock, shot, deadline)
        if not os.path.exists(shot):
            raise SystemExit(
                "fb_check: QEMU produced no screenshot — it has no display "
                "surface, which means the ramfb configuration was rejected")

        w, h, px = read_ppm(shot)
        cells = lit = 0
        if (w, h) != (WIDTH, HEIGHT):
            failures.append("screen is %dx%d, expected %dx%d" % (w, h, WIDTH, HEIGHT))
        else:
            font = load_font()
            with open(log, "rb") as f:
                replayed = expected_screen(f.read())
            if replayed is None:
                failures.append("the kernel never turned on the screen console")
                grid = None
            else:
                grid, scrolls = replayed
                # A log that fits on the screen never exercises scrolling, and
                # a check that does not notice would pass a console whose
                # scroll is broken. It did, once: the boot log filled 33 rows
                # of 48 and this said PASS with the scroll deliberately
                # sheared by a pixel.
                if scrolls < 1:
                    failures.append(
                        "the log never filled the screen, so scrolling was "
                        "not exercised at all")
            if grid is not None:
                for row in range(ROWS):
                    for col in range(COLS):
                        byte = grid[row][col]
                        # The kernel draws '?' for anything outside the font's
                        # range, so a multi-byte character shows as one '?'
                        # per byte. Matching that is what makes the two agree.
                        ch = chr(byte) if 32 <= byte <= 126 else "?"
                        bad = compare_cell(px, w, col, row, font[ch])
                        cells += 1
                        if any(font[ch][y][x] for y in range(GLYPH_H)
                               for x in range(GLYPH_W)):
                            lit += 1
                        if bad:
                            failures.append(
                                "cell (%d,%d) should be %r (byte %d): %s"
                                % (col, row, ch, byte, bad))
                            if len(failures) >= 8:
                                failures.append("... and more")
                                break
                    if len(failures) >= 8:
                        break
                # A screen of nothing but spaces would match a blank display
                # perfectly, so require that some of it is actually text.
                if lit < 100:
                    failures.append(
                        "only %d cells hold a visible character; the log did "
                        "not reach the screen" % lit)
    finally:
        qemu.terminate()
        try:
            qemu.wait(timeout=10)
        except subprocess.TimeoutExpired:
            qemu.kill()

    if failures:
        print("FAIL: the display is not showing what the kernel drew")
        for f in failures:
            print("  " + f)
        return 1
    print("PASS: %dx%d, %d character cells match the boot log after %d "
          "scrolls, %d of them with visible text"
          % (WIDTH, HEIGHT, cells, scrolls, lit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
