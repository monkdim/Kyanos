#!/usr/bin/env python3
"""Boot the aarch64 kernel with no keyboard and no screen, and type at it.

This is the headless path, and until the PL011 could be read there was no such
thing: the only way into this machine was a virtio keyboard, which means a
graphical window, which means finding it, focusing it and letting it capture
the pointer before a text prompt would listen. That was reported from a real
Mac as "I can't type in there at all", and it was accurate.

So this test attaches no keyboard and no display. Everything it sends goes
down the same serial line the boot log comes back on, which is what
`-serial stdio` gives a person and what `-serial unix:` gives a script.

What it checks, in the order the boot produces it:

  * the kernel's own prompt reads the lines typed at it, corrections included
  * read(2) delivers a line to /bin/clarity-init, twice, in two address spaces
  * the shell runs commands and exits with the status it was told

A keyboard is what tools/key_check.py drives; this file drives the other one.
Either alone would leave the other free to break without anything noticing —
and the serial one is the one a person actually uses.
"""

import os
import socket
import subprocess
import sys
import tempfile
import time

PROMPT_MARKER = b"type at it"
DONE_MARKER = b"[ok] console input:"
INIT_PROMPT = b"init: type a line: "
SHELL_BANNER = b"clarity-sh: type help"
SHELL_PROMPT = b"$ "
BOOT_MARKER = b"KyanOS aarch64: EL1 boot ok"

# Typed at the kernel's own prompt. The second line is wrong and then fixed:
# the kernel must end up holding the correction rather than the keystrokes,
# which is the line discipline's whole job and is worth checking on this path
# too — backspace arrives as 0x7F from a terminal and as 8 from a keyboard,
# and only one of those is exercised by key_check.
KERNEL_LINES = [
    ("headless", "headless"),
    ("helxo\x7f\x7flo", "hello"),
]

# Typed all at once — forty-three characters, nearly three times what the
# PL011's FIFO holds — rather than a byte at a time.
#
# This passes with the receive interrupt and it passed without it: a build
# with the interrupt not routed at all reads the line whole. QEMU's chardev
# backend does not hand the model more than the guest has taken, so the
# emulated FIFO does not overrun however fast this writes. It is kept
# because it is worth knowing that a burst arrives complete and in order
# through the ring the interrupt fills, and because it is the shape that
# would catch a real overrun if one ever became reachable — not because it
# demonstrates one now. It does not, and it was tried.
BURST_LINE = "the quick brown fox jumps over the lazy dog"

INIT_WORDS = ["alpha", "beta"]

SHELL_SESSION = [
    ("echo typed over serial", "typed over serial"),
    ("count abcde", "5"),
    ("cat /bin/hello.txt", "clarity"),
    # ls, over the same line, through readdir(2): the root holds one
    # directory, /bin holds the file cat just read, and asking a file to be
    # listed says so rather than printing nothing. A directory is marked with
    # a trailing slash, which is why the first answer is "bin/" and not "bin".
    ("ls /", "bin/"),
    ("ls /bin", "hello.txt"),
    ("ls /bin/hello.txt", "clarity-sh: ls: not a directory: /bin/hello.txt"),
    ("frobnicate", "clarity-sh: unknown command: frobnicate"),
    # exec, refused. The successful case cannot be tested from here: it
    # replaces this shell, and everything after it in this list would be
    # typed at a program that does not read. The plain boot exercises that
    # half — /bin/clarity-exec replaces itself and the kernel says so — and
    # what this adds is the other half: the shell's own call reaches the
    # kernel, and a path that names nothing comes *back* as an error rather
    # than taking the shell with it.
    ("run /nope", "run: cannot run /nope"),
]
SHELL_EXIT_STATUS = 5

# Long enough that a slow TCG boot on a shared runner is not the thing being
# measured, short enough that a hang is reported rather than waited out.
BOOT_DEADLINE = 300
STEP_DEADLINE = 120

# The kernel is asked for a short idle timeout, the same way every other test
# asks: the default is two minutes because that is what suits a person, and
# nothing here is a person.
IDLE = "clarity.idle=3"


def read_log(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return b""


def wait_for(log, marker, deadline, proc, count=1):
    """Wait until `marker` has appeared at least `count` times.

    Counting rather than testing for presence, because every prompt here
    appears more than once: the init program runs twice and the shell prompts
    after every command, so "it is in the log" stops meaning anything after
    the first one.
    """
    while time.time() < deadline:
        if read_log(log).count(marker) >= count:
            return True
        if proc.poll() is not None:
            return False
        time.sleep(0.1)
    return False


def send(sock, text):
    """Type a string, then Enter.

    Byte at a time with a pause, the way a person types. `send_burst` below
    is the same thing without the pauses, for the cases that care.
    """
    for ch in text.encode():
        sock.sendall(bytes([ch]))
        time.sleep(0.01)
    sock.sendall(b"\r")
    time.sleep(0.05)


def send_burst(sock, text):
    """Type a string and Enter in one write, with no pauses at all.

    Hands the PL011 more bytes than its FIFO holds, in one go. What that
    proves is narrower than it looks — see BURST_LINE — but a burst that
    arrived reordered or short would fail here and nothing else would catch
    it.
    """
    sock.sendall(text.encode() + b"\r")
    time.sleep(0.1)


def connect(path, deadline):
    s = socket.socket(socket.AF_UNIX)
    while True:
        try:
            s.connect(path)
            return s
        except (FileNotFoundError, ConnectionRefusedError):
            if time.time() > deadline:
                raise SystemExit("serial_check: QEMU never opened its serial socket")
            time.sleep(0.1)


def pump(sock, log_path, stop):
    """Copy everything QEMU sends into the log file until `stop` says so.

    A Unix-socket serial port has no file behind it, so this is what makes one:
    the rest of the test reads the log exactly as it would with `-serial file:`.
    """
    with open(log_path, "ab", buffering=0) as f:
        while not stop():
            try:
                data = sock.recv(4096)
            except socket.timeout:
                continue
            if not data:
                return
            f.write(data)


def reported_lines(text):
    out = []
    for line in text.splitlines():
        if line.startswith("  line ") and line.count('"') >= 2:
            out.append(line.split('"')[1])
    return out


def program_lines(text):
    out = []
    for line in text.splitlines():
        if line.startswith("  init: read ") and line.count('"') >= 2:
            out.append(line.split('"')[1])
    return out


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: serial_check.py <kernel-image>")
    kernel = sys.argv[1]
    tmp = tempfile.mkdtemp(prefix="clarityserial-")
    log = os.path.join(tmp, "serial.log")
    sock_path = os.path.join(tmp, "serial.sock")
    qemu_out = os.path.join(tmp, "qemu.out")

    # No -device virtio-keyboard-device and no display at all. That is the
    # point: if anything below works, it worked over the serial line.
    qemu = subprocess.Popen([
        "qemu-system-aarch64",
        "-M", "virt",
        "-cpu", "cortex-a72",
        "-m", "512",
        "-kernel", kernel,
        "-append", IDLE,
        "-display", "none",
        "-serial", "unix:%s,server,nowait" % sock_path,
        "-no-reboot",
    ], stdout=open(qemu_out, "wb"), stderr=subprocess.STDOUT)

    import threading
    stopping = False
    pump_thread = None

    def why_not(what):
        print("FAIL: %s" % what)
        if qemu.poll() is not None:
            print("  QEMU exited with %d" % qemu.returncode)
        tail = read_log(log)[-1500:].decode("utf-8", "replace")
        print("  --- last of the serial log ---")
        print(tail if tail else "  (nothing at all)")
        with open(qemu_out, "rb") as f:
            out = f.read()[-500:].decode("utf-8", "replace")
        if out:
            print("  --- QEMU said ---")
            print(out)

    try:
        deadline = time.time() + BOOT_DEADLINE
        s = connect(sock_path, deadline)
        s.settimeout(0.2)
        pump_thread = threading.Thread(target=pump, args=(s, log, lambda: stopping))
        pump_thread.daemon = True
        pump_thread.start()

        if not wait_for(log, PROMPT_MARKER, deadline, qemu):
            why_not("the kernel never asked for input")
            return 1
        for typed, _ in KERNEL_LINES:
            send(s, typed)
        send_burst(s, BURST_LINE)

        if not wait_for(log, DONE_MARKER, time.time() + STEP_DEADLINE, qemu):
            why_not("the kernel never reported what it read")
            return 1

        for i, word in enumerate(INIT_WORDS):
            if not wait_for(log, INIT_PROMPT, time.time() + STEP_DEADLINE,
                            qemu, count=i + 1):
                why_not("the init program never asked for line %d" % (i + 1))
                return 1
            send(s, word)

        if not wait_for(log, SHELL_BANNER, time.time() + STEP_DEADLINE, qemu):
            why_not("the shell never started")
            return 1

        for i, (command, _) in enumerate(SHELL_SESSION):
            if not wait_for(log, SHELL_PROMPT, time.time() + STEP_DEADLINE,
                            qemu, count=i + 1):
                why_not("the shell stopped prompting before %r" % command)
                return 1
            send(s, command)

        if not wait_for(log, SHELL_PROMPT, time.time() + STEP_DEADLINE, qemu,
                        count=len(SHELL_SESSION) + 1):
            why_not("the shell stopped prompting before exit")
            return 1
        send(s, "exit %d" % SHELL_EXIT_STATUS)

        if not wait_for(log, BOOT_MARKER, time.time() + STEP_DEADLINE, qemu):
            why_not("the kernel read the input but never finished booting")
            return 1
        time.sleep(0.5)
    finally:
        stopping = True
        if pump_thread is not None:
            pump_thread.join(timeout=2)
        qemu.terminate()
        try:
            qemu.wait(timeout=10)
        except subprocess.TimeoutExpired:
            qemu.kill()

    text = read_log(log).decode("utf-8", "replace")

    got = reported_lines(text)
    want = [expected for _, expected in KERNEL_LINES] + [BURST_LINE]
    if got != want:
        print("FAIL: typed %r over the serial line, the kernel read %r"
              % ([t for t, _ in KERNEL_LINES] + [BURST_LINE], got))
        if got and got[-1] != BURST_LINE and BURST_LINE.startswith(got[-1]):
            print("  the burst arrived truncated at %d of %d characters, so"
                  % (len(got[-1]), len(BURST_LINE)))
            print("  something between the socket and the line editor is"
                  " dropping bytes under load")
        return 1

    from_program = program_lines(text)
    if from_program != INIT_WORDS:
        print("FAIL: typed %r at the program, read(2) gave it %r"
              % (INIT_WORDS, from_program))
        return 1

    for command, answer in SHELL_SESSION:
        if answer not in text:
            print("FAIL: sent %r to the shell, but %r is not in its output"
                  % (command, answer))
            for candidate in text.splitlines():
                if candidate.startswith("$ ") or "clarity-sh" in candidate:
                    print("  " + candidate)
            return 1

    if ("exited %d" % SHELL_EXIT_STATUS) not in text:
        print("FAIL: `exit %d` did not reach the kernel as the exit status"
              % SHELL_EXIT_STATUS)
        return 1

    # And that this really was the headless path. A keyboard that had somehow
    # been attached would make every check above pass without the serial line
    # ever being read, which is the one way this test could quietly stop
    # testing what it is named after.
    if "[ok] keyboard: virtio-input" in text:
        print("FAIL: a keyboard was found — this test is meant to run without "
              "one, so nothing above proves the serial line was read")
        return 1

    print("PASS: with no keyboard and no display, the kernel read %r, "
          "read(2) gave the program %r, and the shell answered %d commands "
          "and exited %d as asked"
          % (got, from_program, len(SHELL_SESSION), SHELL_EXIT_STATUS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
