#!/usr/bin/env python3
"""Boot the x86_64 kernel with no serial input at all, and type at the keyboard.

The serial test (tools/serial_check_x86.py) drives the other way in. This one
sends key events to the PS/2 controller through QEMU's monitor, which is the
same path a person at a physical keyboard uses, and requires the characters to
come out of `read(2)` in a program.

It is a separate file from the serial one on purpose: either alone would leave
the other free to break without anything noticing, and the two paths share only
the line editor.

What it found when it was first written is why it exists. The keyboard
interrupt had never fired -- the controller's configuration byte was written
with a mask that cleared the first port's interrupt-enable bit on the line
after it was set -- and nothing anywhere reported a problem. The scancodes
piled up in the 8042's output buffer and the ring stayed empty.
"""

import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

PROBE_READY = b"readprobe: reading a line"
DONE_MARKER = b"[ok] console read:"
COMPLETE = b"KyanOS: userspace complete."

# Typed on the keyboard, a key at a time. Letters only and one space: QEMU's
# monitor names keys, not characters, and the point here is the path rather
# than the breadth of the table -- `drivers/keymap.zig` is shared with the
# AArch64 side, whose own key test covers the rest of it.
LINES = ["hello", "keys work"]

KEYNAMES = {" ": "spc"}

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


def sendkey(mon, name):
    mon.sendall(("sendkey %s\n" % name).encode())
    time.sleep(0.12)
    try:
        mon.recv(4096)
    except socket.timeout:
        pass


def type_line(mon, text):
    for ch in text:
        sendkey(mon, KEYNAMES.get(ch, ch))
    sendkey(mon, "ret")


def connect(path, deadline):
    s = socket.socket(socket.AF_UNIX)
    while True:
        try:
            s.connect(path)
            return s
        except (FileNotFoundError, ConnectionRefusedError):
            if time.time() > deadline:
                raise SystemExit("key_check_x86: QEMU never opened its socket")
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
    out = []
    for line in text.splitlines():
        if line.startswith("readprobe: got "):
            out.append(line[len("readprobe: got "):].rstrip("\r\n"))
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
        raise SystemExit("usage: key_check_x86.py <kernel-elf>")
    kernel = sys.argv[1]
    tmp = tempfile.mkdtemp(prefix="claritykeyx86-")
    log = os.path.join(tmp, "serial.log")
    ser_path = os.path.join(tmp, "serial.sock")
    mon_path = os.path.join(tmp, "monitor.sock")

    iso = build_iso(kernel, tmp)

    # The serial line carries the log out and nothing in: every byte the
    # kernel reads on this boot came from the keyboard.
    qemu = subprocess.Popen([
        "qemu-system-x86_64",
        "-cdrom", iso,
        "-boot", "d",
        "-m", "512",
        "-display", "none",
        "-serial", "unix:%s,server,nowait" % ser_path,
        "-monitor", "unix:%s,server,nowait" % mon_path,
        "-no-reboot",
    ], stdout=open(os.path.join(tmp, "qemu.out"), "wb"), stderr=subprocess.STDOUT)

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
        ser = connect(ser_path, time.time() + 30)
        ser.settimeout(0.2)
        mon = connect(mon_path, time.time() + 30)
        mon.settimeout(0.3)
        pump_thread = threading.Thread(target=pump, args=(ser, log, lambda: stopping))
        pump_thread.daemon = True
        pump_thread.start()

        if not wait_for(log, PROBE_READY, time.time() + BOOT_DEADLINE, qemu):
            why_not("the read probe never started")
            return 1

        for text in LINES:
            type_line(mon, text)

        if not wait_for(log, DONE_MARKER, time.time() + STEP_DEADLINE, qemu):
            why_not("the probe never reported what it read")
            return 1

        body = read_log(log).decode("utf-8", "replace")
        got = got_lines(body)
        if got != LINES:
            why_not("the program read %r, not %r" % (got, LINES))
            return 1

        if not wait_for(log, COMPLETE, time.time() + STEP_DEADLINE, qemu):
            why_not("the kernel did not finish after the read")
            return 1

        print("PASS: with nothing sent down the serial line, a program read %r "
              "typed on the PS/2 keyboard" % (got,))
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
