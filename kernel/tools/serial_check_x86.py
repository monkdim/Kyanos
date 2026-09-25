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
CLOCK_MARKER = b"[ok] console clock:"
DONE_MARKER = b"[ok] console read:"
COMPLETE = b"KyanOS: userspace complete."

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

        if not wait_for(log, COMPLETE, time.time() + STEP_DEADLINE, qemu):
            why_not("the kernel did not finish after the read")
            return 1

        print("PASS: with no keyboard and no display, a program read %r "
              "through fd 0, and the TSC clock underneath it was measured "
              "against the PIT" % (got,))
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
