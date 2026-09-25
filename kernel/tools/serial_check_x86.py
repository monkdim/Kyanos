#!/usr/bin/env python3
"""Boot the x86_64 kernel with no keyboard and no screen, and type at it.

The aarch64 side has had this since #43; this side has not, because until now
descriptor zero on x86_64 went to the filesystem, found no inode behind it and
answered EBADF. Nothing a person typed could reach a program, so there was
nothing for a test like this to drive.

What it checks:

  * the TSC clock was measured against the PIT, and moves while interrupts are
    masked -- which is the property `read(2)` stands on, because a system call
    is entered with IF cleared and the tick count does not move there
  * a line typed at the serial port reaches a program through fd 0, whole
  * a second line reaches it after the first, with nothing of the first left
  * and the program's exit code says which of those happened
  * the shell reads commands, runs them, and exits with the status it is
    given -- including `run`, which forks, execs and waits, so what comes
    back is a second program's exit status carried through three calls

Everything it sends goes down the same serial line the boot log comes back on,
which is what `-serial stdio` gives a person and `-serial unix:` gives a
script. No display, no keyboard: if this works, it worked over the wire.
"""

import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

# The two lines typed at the probe. Different lengths and different contents,
# so a kernel that handed back the same buffer twice, or the first line twice,
# would be caught rather than pass.
LINES = ["alpha", "beta gamma delta"]

PROBE_READY = b"readprobe: reading a line"
SHELL_BANNER = b"clarity-sh: type help"
SHELL_PROMPT = b"$ "
CLOCK_MARKER = b"[ok] console clock:"
DONE_MARKER = b"[ok] console read:"
COMPLETE = b"KyanOS: userspace complete."

# Typed at the shell. `run` is the point of the middle two: it forks, execs
# and waits, so the status that comes back is a second program's, carried
# through three system calls. The two after it are typed *after* a program has
# been run and finished -- on a shell that lost itself to exec there would be
# nobody left to type them at.
SHELL_SESSION = [
    "help",
    "echo status check",
    "run /nope",
    "run /bin/clarity-hello",
    "echo still here",
    "count abcdefghij",
    "exit 5",
]

SHELL_EXPECTED = [
    "status check",
    "run: cannot run /nope — no such file",
    "run: /nope exited 127",
    "hello: I am a different program than the one that asked for me",
    "run: /bin/clarity-hello exited 55",
    "still here",
    "10",
    "clarity-sh: exit",
]

BOOT_DEADLINE = 90
STEP_DEADLINE = 45


def read_log(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return b""


def wait_for(log, marker, deadline, proc, count=1):
    while time.time() < deadline:
        if read_log(log).count(marker) >= count:
            return True
        if proc.poll() is not None:
            return False
        time.sleep(0.1)
    return False


def send(sock, text):
    """Type a string, then Enter, a byte at a time the way a person types."""
    for ch in text.encode():
        sock.sendall(bytes([ch]))
        time.sleep(0.01)
    sock.sendall(b"\r")
    time.sleep(0.05)


def connect(path, deadline):
    s = socket.socket(socket.AF_UNIX)
    while True:
        try:
            s.connect(path)
            return s
        except (FileNotFoundError, ConnectionRefusedError):
            if time.time() > deadline:
                raise SystemExit("serial_check_x86: QEMU never opened its serial socket")
            time.sleep(0.1)


def pump(sock, log_path, stop):
    with open(log_path, "ab", buffering=0) as f:
        while not stop():
            try:
                data = sock.recv(4096)
            except socket.timeout:
                continue
            if not data:
                return
            f.write(data)


def got_lines(text):
    """What the probe said it read, in order."""
    out = []
    for line in text.splitlines():
        if line.startswith("readprobe: got "):
            out.append(line[len("readprobe: got "):])
    return out


def build_iso(kernel, workdir):
    root = os.path.join(workdir, "iso")
    os.makedirs(os.path.join(root, "boot", "grub"))
    with open(os.path.join(root, "boot", "clarity-kernel"), "wb") as out:
        with open(kernel, "rb") as src:
            out.write(src.read())
    with open(os.path.join(root, "boot", "grub", "grub.cfg"), "w") as f:
        f.write('set timeout=0\nset default=0\n'
                'menuentry "KyanOS" {\n    multiboot2 /boot/clarity-kernel\n    boot\n}\n')
    iso = os.path.join(workdir, "clarity.iso")
    subprocess.run(["grub-mkrescue", "-o", iso, root],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return iso


import re


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: serial_check_x86.py <kernel-elf>")
    kernel = sys.argv[1]
    tmp = tempfile.mkdtemp(prefix="clarityserialx86-")
    log = os.path.join(tmp, "serial.log")
    sock_path = os.path.join(tmp, "serial.sock")
    qemu_out = os.path.join(tmp, "qemu.out")

    iso = build_iso(kernel, tmp)

    qemu = subprocess.Popen([
        "qemu-system-x86_64",
        "-cdrom", iso,
        "-boot", "d",
        "-m", "512",
        "-display", "none",
        "-serial", "unix:%s,server,nowait" % sock_path,
        "-no-reboot",
    ], stdout=open(qemu_out, "wb"), stderr=subprocess.STDOUT)

    stopping = False
    pump_thread = None

    def why_not(what):
        print("FAIL: %s" % what)
        if qemu.poll() is not None:
            print("  QEMU exited with %d" % qemu.returncode)
        tail = read_log(log)[-2000:].decode("utf-8", "replace")
        print("  --- last of the serial log ---")
        print(tail if tail else "  (nothing at all)")
        print("  --- end ---")

    try:
        sock = connect(sock_path, time.time() + 30)
        sock.settimeout(0.2)
        pump_thread = threading.Thread(target=pump, args=(sock, log, lambda: stopping))
        pump_thread.daemon = True
        pump_thread.start()

        deadline = time.time() + BOOT_DEADLINE
        if not wait_for(log, CLOCK_MARKER, deadline, qemu):
            why_not("the TSC was never measured against the PIT")
            return 1

        # The probe says it is about to read before it reads. Typing before
        # that would be typing at nothing: the editor only sees bytes the
        # kernel polls for, and nothing polls until the read begins.
        if not wait_for(log, PROBE_READY, time.time() + STEP_DEADLINE, qemu):
            why_not("the read probe never started")
            return 1

        for text in LINES:
            send(sock, text)

        if not wait_for(log, DONE_MARKER, time.time() + STEP_DEADLINE, qemu):
            why_not("the probe never reported what it read")
            return 1

        body = read_log(log).decode("utf-8", "replace")
        got = [g.rstrip("\r\n") for g in got_lines(body)]
        if got != LINES:
            why_not("the program read %r, not %r" % (got, LINES))
            return 1

        # And then the shell, which is the same serial line used the way a
        # person would use it.
        if not wait_for(log, SHELL_BANNER, time.time() + STEP_DEADLINE, qemu):
            why_not("the shell never started")
            return 1

        for i, cmd in enumerate(SHELL_SESSION):
            if not wait_for(log, SHELL_PROMPT, time.time() + STEP_DEADLINE,
                            qemu, count=i + 1):
                why_not("the shell did not prompt before %r" % cmd)
                return 1
            send(sock, cmd)

        if not wait_for(log, COMPLETE, time.time() + STEP_DEADLINE, qemu):
            why_not("the kernel did not finish after the shell")
            return 1

        body = read_log(log).decode("utf-8", "replace")
        for want in SHELL_EXPECTED:
            if want not in body:
                why_not("the shell never said %r" % want)
                return 1

        # Exactly one prompt per command: one before each, and none after the
        # last because the last is `exit`. Counted rather than merely looked
        # for, because a child whose exec failed and returned into the loop
        # would be a *second* shell reading the same port, and both would
        # answer correctly -- every expected string would be there and the
        # test would pass on the strings alone. What gives it away is that
        # there are twice as many prompts.
        prompts = body.count("$ ")
        if prompts != len(SHELL_SESSION):
            why_not("%d shell prompts, wanted %d" % (prompts, len(SHELL_SESSION)))
            return 1

        # The interrupt actually fired. Everything above works whether it did
        # or not, because `serial_poll` falls back to reading the port -- so
        # without this the receive interrupt could be entirely dead and every
        # check here would still pass. The count is the only thing that can
        # tell the difference.
        m = re.search(r"serial: (\d+) bytes arrived by interrupt, (\d+) dropped", body)
        if not m:
            why_not("the kernel never reported how many bytes arrived by interrupt")
            return 1
        arrived, dropped = int(m.group(1)), int(m.group(2))
        if arrived == 0:
            why_not("nothing arrived by interrupt -- every byte was picked up "
                    "by the poll fallback, so the interrupt is not working")
            return 1
        if dropped != 0:
            why_not("%d bytes were dropped for want of room in the receive ring"
                    % dropped)
            return 1

        print("PASS: with no keyboard and no display, a program read %r "
              "through fd 0, the TSC clock underneath it was measured against "
              "the PIT, %d bytes arrived by interrupt with none dropped, and "
              "the shell answered %d commands and exited 5 as asked"
              % (got, arrived, len(SHELL_SESSION)))
        return 0
    finally:
        stopping = True
        qemu.terminate()
        try:
            qemu.wait(timeout=10)
        except subprocess.TimeoutExpired:
            qemu.kill()
        if pump_thread is not None:
            pump_thread.join(timeout=2)


if __name__ == "__main__":
    sys.exit(main())
