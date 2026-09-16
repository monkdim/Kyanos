# Running KyanOS

Two architectures, two machines. Both boot under QEMU; neither has run on
real hardware yet.

## Build

Needs Zig 0.13. From `kernel/`:

```sh
zig build            # x86-64  -> zig-out/bin/clarity-kernel
zig build aarch64    # aarch64 -> zig-out/bin/clarity-kernel-aarch64.img
zig build check      # compile the modules neither kernel imports
```

That third one exists because Zig never parses a file nothing imports, so
the first two say nothing whatever about `drivers/tty.zig`, `fs/devfs.zig`,
`fs/procfs.zig` or `boot/uefi.zig` — deliberate nonsense in any of them
builds clean. `check` compiles them through `checkonly.zig`. It is not a
claim that they work; nothing in them has ever run.

To just see one boot, without reading the rest of this file:

```sh
zig build run            # x86-64: builds a GRUB ISO, boots it, serial on stdout
zig build run-aarch64    # aarch64: boots the image, opens a window with the screen
```

Or from the repository root with a `clarity` binary, which does the same
thing for whichever architecture the machine is (`--arch` overrides):

```sh
clarity os build                 # dist/claritos.iso or dist/claritos-aarch64.img
clarity os run                   # serial console in this terminal; Ctrl-A then X quits
clarity os run --window          # the framebuffer and keyboard as well
clarity os run --boot-test       # headless; passes when the CI gate's marker appears
```

The x86 one goes through `tools/run_x86.sh` because QEMU's `-kernel` cannot
load a multiboot2 image; the script builds the same rescue ISO the boot gate
builds, so `zig build run` and CI boot the kernel identically. It needs
`grub-mkrescue` and `xorriso`, and says so by name if they are missing.

Both boots end by halting on purpose — the kernel has nothing left to do, so
it stops rather than resetting. Ctrl-A X quits QEMU.

The aarch64 build produces two files. The `.img` is the bootable one: a flat
binary carrying an ARM64 Linux Image header, which is what makes a bootloader
treat it as a kernel — and hand it a device tree. The ELF beside it has the
symbols, for a debugger or a disassembler; booting it works, but the kernel
comes up knowing nothing about the machine.

## aarch64 — the one with a screen

```sh
qemu-system-aarch64 \
  -M virt -cpu cortex-a72 -m 512 \
  -kernel zig-out/bin/clarity-kernel-aarch64.img \
  -device ramfb \
  -serial stdio
```

`-device ramfb` is what gives it a display. Without it the kernel says so and
carries on headless, which is why the flag is not optional if you want to see
anything. Drop `-serial stdio` for `-serial file:boot.log` if you would rather
have the log in a file than mixed into the QEMU window's terminal.

You should get a 1024×768 window. It shows a test pattern first — slate
background, blue border, four colour patches — and then the boot log itself,
in white on slate, 64 columns by 48 rows. Everything the kernel says from the
`[ok] console on screen` line onward appears there as well as on the serial
line.

That is what the boot gate checks: it screenshots the display and compares
*every character cell* against what the serial log says should be there,
rendering the glyphs itself from `tools/font8x8.txt`. The kernel draws from
`graphics/font8x8.zig`, which is generated from that file — so a generator
that dropped a row, a console that wrapped at the wrong column, or a scroll
that sheared by a pixel makes the two disagree.

The serial log should report the machine describing itself:

```
  [ok] MMU on (39-bit VA, direct map at 0xffffff8000000000) sctlr.M=1 pc=0xffffff8040082eb4
  [ok] identity map dropped: 0x9000000 no longer translates, 0xffffff8009000000 -> 0x9000000; TTBR0 is free for userland
  [ok] device tree at 0x48000000, 1048576 bytes, #address-cells=2 #size-cells=2
  [ok] fw_cfg from the device tree at 0x9020000
  ram 0x40000000 + 512 MiB
  [ok] direct map covers all of RAM (0 GiB added beyond the boot stub's block)
  [ok] pmm: 512 MiB managed, 129347 pages free, allocated 0x402bd000 and it holds
  [ok] process address space: 0x10000000 -> 0x402c0000 for EL0 read and write, 0x400000 read-only (a write there faults), kernel unaffected, unmapped and torn down with every page returned
  -- below this line, EL0 is speaking through write(2) --
hello from EL0 on aarch64
  [ok] EL0: a program wrote 26 bytes through write(2), read 41 from its own memory, and exited with 42 — which the kernel found in the page it had left it
  [ok] EL0: the timer interrupted it 18 times while it ran, and it carried on afterwards
  [ok] EL0: and when it wrote to its read-only text at 0x400000, the kernel took the CPU back
  [ok] context switch: ABABABa — two threads alternated and handed the CPU back
  [ok] preemption: B ran (7583766) while A (9416843) never yielded — 6 switches in 7 ticks, each thread resuming in its own code
  init: 74208 bytes of ELF, embedded in the kernel image
  init: entry 0x40100000, stack 0x7fffffc0, 4 mapped ranges, heap from 0x40104000
  [ok] user .data came from the file
hello from /bin/clarity-init on aarch64
  [ok] user .bss zeroed
  [ok] user .data writable
  [ok] user fp: 355/113 in a v register
  [ok] user heap: brk grew and the memory holds
  ... the same five lines again, from the second run ...
  [ok] init: a compiled, linked ELF ran at EL0 twice, printed 216 bytes, exited 42 each time, and every page came back
  demo: 123232 bytes of Clarity, compiled to C and then to this machine
  ... the demo program's own output ...
  float 3.1415929203539825 1.4142135623730951 6.25
  clarity-demo: all checks passed
  [ok] demo: a Clarity program ran on aarch64, printed 209 bytes and used 192 KiB of heap
```

The spin counts and the tick count vary — it is however many times the 100 Hz
timer happened to fire during the process's delay loop, and the check is only
that it fired at all.

Change `-m 512` and the RAM line follows it — that is the kernel reading the
device tree rather than assuming a machine. Try `-m 4096` and the direct-map
line changes too: the boot stub can only map the gigabyte it was loaded into,
because it runs before anything has read the device tree, and the other three
are mapped afterwards by code that has.

The `pc=` on the first line and the addresses on the second are the whole of
the higher-half port in two lines. The kernel is linked at
`0xFFFF_FF80_0000_0000 + physical` and running there, and the low half is no
longer translated at all — those addresses are not printed from the linker
script, they come from the program counter and from asking the MMU to
translate an address (`at s1e1w`) and reporting what it said.

### On an Apple Silicon Mac

This is the reason the aarch64 side exists — and, as of now, the reason there
is more work to do.

**`-accel hvf` does not work with this kernel, and cannot until it speaks
GICv3.** Run on an M5:

```
$ qemu-system-aarch64 -M virt,gic-version=2 -accel hvf -cpu host ...
qemu-system-aarch64: HVF does not support GICv2 emulation
```

That is not a configuration mistake. Apple Silicon has no GIC at all — the
real interrupt controller is Apple's own AIC — so QEMU emulates one, and under
HVF it will only emulate a GICv3. `arch/aarch64/gic.zig` speaks GICv2 and
nothing else. There is no combination of flags that gets around it: dropping
`gic-version=2` lets QEMU pick GICv3, which QEMU accepts and this kernel then
hangs on, waiting for a timer interrupt it never sees. Native speed on Apple
hardware needs a GICv3 driver, and that is now the next piece of the ARM track
rather than a footnote.

Until then, the emulated path is the one to use, and it has now been run:
booted on an Apple M5, typed at by hand, all the way through the shell to
`exit 3`. On a Mac in particular, prefer the headless form — the graphical
window is awkward to type into and the terminal is not:

```sh
brew install qemu

qemu-system-aarch64 \
  -M virt,gic-version=2 \
  -cpu cortex-a72 \
  -m 512 \
  -kernel zig-out/bin/clarity-kernel-aarch64.img \
  -display none \
  -serial stdio
```

Add `-device ramfb -device virtio-keyboard-device -display default` when the
point is to see the framebuffer console rather than to use the machine.

That session, on an M5, abbreviated to the part a person drives — this is what
"it works on Apple hardware" currently means, and it is worth writing down as
a transcript rather than as an adjective:

```
  type at it; 120 seconds of quiet ends the read
  > help
  line 1: "help"
...
  init: type a line: yolo
  [ok] user read: a bad buffer was refused and kept the line
  init: read "yolo"
...
clarity-sh: type help
$ echo hello from my mac
hello from my mac
$ count abcde
5
$ cat /bin/hello.txt
clarity
$ cat /nope
clarity-sh: cat: cannot open /nope
$ frobnicate
clarity-sh: unknown command: frobnicate
$ exit 3
clarity-sh: exit
  [ok] shell: ran at EL0, read its own input, wrote 596 bytes and exited 3
KyanOS aarch64: EL1 boot ok
```

Two things in there are worth pointing at. `[ok] user read: a bad buffer was
refused` is the `EFAULT` check firing on real Apple silicon — the program
deliberately passes a pointer into its own read-only text, and the kernel
translates a read buffer *for writing* and refuses it. And the demo's float
line comes out as `3.1415929203539825 1.4142135623730951 6.25`, the same
digits the x86_64 gate requires, from `strtod`, the library's own arithmetic,
a hardware square root and `dtoa` all agreeing on a machine none of them were
tested on.

What that session does **not** show is HVF. Everything above is emulated: the
M-series CPU is running QEMU, not this kernel. That is the gap GICv3 closes.

**Use the native Homebrew.** A Mac can have two: `/opt/homebrew` (arm64) and
`/usr/local` (Intel, under Rosetta). If `/usr/local/bin` comes first in
`PATH`, `brew install qemu` builds an x86-64 QEMU from source — twenty minutes
of compiling for a binary that runs under translation and could never use HVF
even once the GICv3 work lands. Check with `file $(which qemu-system-aarch64)`;
it must say `arm64`.

**`gic-version=2`** pins the interrupt controller, for the reason above. Recent
QEMU defaults this to `max` on `virt`, which selects GICv3, so it is worth
stating rather than leaving to the default. If the kernel stops after
`[ok] generic timer armed`, that is the first thing to suspect.

### Typing at it with no window at all

The simplest way to use this, and the one to reach for first:

```sh
qemu-system-aarch64 \
  -M virt -cpu cortex-a72 -m 512 \
  -kernel zig-out/bin/clarity-kernel-aarch64.img \
  -display none \
  -serial stdio
```

No display, no keyboard device, nothing to click. The boot log comes out in
the terminal that started QEMU and what is typed there goes back in. Ctrl-A
then X quits.

The PL011 was write-only until recently, which meant the only way into this
machine was the graphical window below — find it, focus it, let it capture the
pointer, and only then type at a text prompt. On a Mac that is enough friction
to make the difference between an operating system somebody can use and one
they can only watch; it was reported from an M5 as "I can't type in there at
all", and that was a fair description. A serial console needs no display
backend and no focus, which is why every other kernel is driven this way.

`tools/serial_check.py` is the gate for it: it boots with no keyboard and no
display, types down a Unix-socket serial line, and fails if a keyboard turns
out to be attached — because with one, every assertion in it would pass
without the serial line ever being read.

### A keyboard, and typing

```sh
qemu-system-aarch64 \
  -M virt -cpu cortex-a72 -m 512 \
  -kernel zig-out/bin/clarity-kernel-aarch64.img \
  -device ramfb \
  -device virtio-keyboard-device \
  -serial stdio
```

`virt` has no PS/2 controller — neither does the hardware this is aimed at —
so a key press arrives as a virtio-input event on the MMIO bus, and the extra
`-device` is what puts one there. The kernel finds it by walking the
thirty-two bus slots the device tree names and reading each one's registers,
then asks for input:

```
  [ok] keyboard: virtio-input on a bus of 32 slots
  type at it; 120 seconds of quiet ends the read
  > hello
  line 1: "hello"
  > 
  [ok] console input: 1 line, 5 characters, from 6 key presses (0 ignored, 0 dropped)
```

Type into the QEMU window and the characters appear after the `>`, on the
screen and on the serial line both. Backspace erases. Enter ends the line,
and the kernel prints back what it has — which is the point of the two lines
being separate: the echo shows what was *typed* and the `line` shows what the
kernel *holds*, and wherever something was corrected those differ.

Quiet ends it, and how much quiet is the one thing this machine can be told:

```sh
  -append "clarity.idle=3"
```

Two minutes by default, because that is what a person needs — long enough to
find the window, click it, and start typing. It was three seconds until an M5
Mac ran this and the shell had exited before a single key could reach it: the
number had been chosen so that a boot gate with nobody at the keyboard would
finish quickly, which is the test suite's convenience charged to whoever is
actually using the machine. The boot gate and `tools/key_check.py` now pass
`clarity.idle=3` themselves, and the default is the one that works by hand.

The boot log says which it got, and whether it was asked for:

```
  [ok] command line: read 120 seconds idle (default)
  [ok] command line: read 3 seconds idle (asked for)
```

Those have to differ. A parser that silently failed to read `-append` would
otherwise look exactly like a boot that was never given one.

Four lines at most, then it moves on. Shift works; the table is the main key
block only, so function keys, the keypad and the arrows type nothing — and
are counted as `ignored` rather than silently dropped.

Drop the `-device` and the kernel says so and carries on. It prints the bus
rather than a summary of it, because "no keyboard" is also what a driver
looking at the wrong addresses would say — with one non-keyboard device
attached, which is what produced this line, it is telling you the slot really
was read and what was in it:

```
  [--] 32 virtio slots, none of them a usable keyboard:
       slot 0xa003e00: transport version 1, device id 4
```

None of those lines can be an `[ok]`, and that is the whole difficulty with
testing an input device: reading nothing is exactly what a working driver
does when nobody types, so no marker in a log nobody typed into can tell that
from a queue the device never writes to.

### A program reading it

The lines above are read by the kernel. This one is read by a *program*:

```
  init: type a line: hello
  [ok] user read: a bad buffer was refused and kept the line
  init: read "hello"
```

### A shell

The last thing the boot runs is `/bin/clarity-sh`, and it waits for you:

```
clarity-sh: type help
$ cat /bin/hello.txt
clarity
$ echo hello from kyan
hello from kyan
$ count abcde
5
$ frobnicate
clarity-sh: unknown command: frobnicate
$ exit 0
```

Four commands, because six system calls is what there is. `cat` needs `open`
and `read`; there is no `ls` because listing a directory needs a call that
does not exist yet, and no way to start a program because nothing can `exec`.
`help` says both rather than leaving them to be discovered.

It ends when its input does — three seconds of nothing — so a boot with
nobody at the keyboard still finishes.

**Typing while it is busy used to lose characters.** The keyboard was polled
and only a read polled it, so nothing drained the device's 64-event queue
while a command ran. Forty characters typed at a waiting prompt all arrived;
the same forty sent while `help` was printing arrived as nine, and the Enter
with them. The keyboard now has its own GIC interrupt and system calls run
with interrupts unmasked, so all forty arrive — `tools/key_check.py` sends
them without waiting for the prompt and fails if fewer come back.

`/bin/clarity-init` — the compiled, linked ELF running at EL0 — calls
`read(0, ...)` twice. The first time it deliberately points at its own
read-only text. The kernel translates a read buffer through the process's own
page tables **for writing**, so that address is refused with `EFAULT`; a
kernel that translated it for reading, which is what `write` does and is the
easy mistake, would find the page perfectly readable and write through its own
map into the program's instructions. The second call passes a real buffer and
must get back the same line — a refused read that ate the line would cost the
next reader its input for a reason nothing in that reader could explain.

With nobody typing it says `init: nothing typed, end of input` and carries on.
That is not blocking: there is no scheduler to block a thread on yet, so a
read spins and gives up after three seconds, which is what a closed stdin
looks like to a caller. It is a stand-in, and the boot gate asserts it on all
three of its ARM boots precisely because that is the path a shell will meet
first.

`tools/key_check.py` is what closes it. It boots this same command line with
QEMU's monitor on a socket and types two lines, then checks two different
things about them:

- **the alphabet twice** — fifty-two keys, which QEMU turns into four events
  each, so well over two hundred through a virtqueue of sixty-four. A shorter
  line fits in the ring the driver hands the device at start-up and would
  pass whether or not buffers are ever given back. Breaking the refill makes
  this read exactly sixteen characters and stop.
- **`helxo`, backspace, backspace, `lo`** — the line discipline's own job.
  The kernel must end up holding `hello`, *and* the screenshot must show
  `  > hello` on a row of its own. Those are two claims: a console that
  echoed the backspaces without erasing anything satisfies the first and not
  the second.

The screen half uses `fb_check.py`'s model of the console, imported rather
than copied, so there is one description of how a character cell gets filled
in and both checks fail if it stops matching `graphics/console.zig`.

### What it does not do yet

It can now do the thing an operating system is for: run a program that is not
the kernel. Unprivileged code executes at EL0 in its own address space, prints
through `write(2)`, exits with a status, is preempted by the timer and carries
on, and is stopped by the kernel when it does something it is not allowed to.
Kernel threads switch, cooperatively and preemptively, carrying their address
space with them.

The last block is the one the rest of it was for: a Clarity program, compiled
to C by `clarity cc --freestanding`, linked against `kernel/user/libc`, and
running on an Apple-Silicon-class machine. Its output is byte for byte the
same as on x86-64, floating-point digits included — the same generated C, the
same library, only the three architecture-specific pieces differ.

Two other lines came from user programs rather than from the kernel:
`hello from EL0 on aarch64`, from a probe assembled into the kernel image, and
`hello from /bin/clarity-init on aarch64`, from an ELF that a compiler built
and a linker laid out into three segments.

The second runs twice, in two address spaces, and that is not repetition. The
second run gets the frames the first one just gave back, so `.bss zeroed` and
`.data came from the file` hold only if the loader really re-zeroed and
re-copied them — removing the zeroing passes the first run and fails the
second.

Try it on a CPU that implements Privileged Access Never — `-cpu max` instead
of `-cpu cortex-a72` — and it still works, because the kernel never touches a
user address directly. It translates the pointer through the process's own
page tables and reads through its own map. On cortex-a72, which has no PAN,
doing it the wrong way also works, which is exactly why the boot gate runs
both.

What is missing is everything above that. There is no *scheduler* — the
switching primitive exists and the boot selftest drives it directly, but
nothing keeps run queues, priorities, or a process table, so programs run one
after another rather than at the same time. They are loaded from ELFs embedded
in the kernel image rather than read from anywhere: no filesystem, no shell.
`write` goes straight to the serial console because there is no VFS to route
it through. Text on screen and the keyboard are joined now — typing echoes,
backspace erases, Enter hands over a line, and `read(2)` delivers that line to
a program at EL0. What is missing above it is a shell: nothing keeps a
terminal, a session or a process table, and a read does not really block. That
is the next thing.

## x86-64 — the one that runs programs

QEMU's `-kernel` cannot load this one directly: it is a multiboot2 image, and
`-kernel` on x86 wants a Linux bzImage or a PVH ELF. It boots from a GRUB
rescue ISO, which is also what the boot gate builds:

```sh
mkdir -p isodir/boot/grub
cp zig-out/bin/clarity-kernel isodir/boot/clarity-kernel
cat > isodir/boot/grub/grub.cfg <<'CFG'
set timeout=0
set default=0
menuentry "KyanOS" {
    multiboot2 /boot/clarity-kernel
    boot
}
CFG
grub-mkrescue -o clarity.iso isodir

qemu-system-x86_64 -cdrom clarity.iso -boot d -m 512 \
  -serial stdio -display none -no-reboot
```

Needs `grub-pc-bin`, `grub-common`, `xorriso` and `mtools` alongside QEMU.

This is the mature side: memory management, preemptive scheduling, a
filesystem, ELF loading, and two processes run in sequence — the second of
them a Clarity program compiled by `clarity cc --freestanding`. It has no
display.

## The checks

```sh
python3 tools/fb_check.py zig-out/bin/clarity-kernel-aarch64.img
python3 tools/key_check.py zig-out/bin/clarity-kernel-aarch64.img
python3 tools/make_font.py --png /tmp/font.png   # look at the font
python3 tools/make_font.py --check               # is the generated .zig stale?
```

`fb_check.py` boots the ARM kernel, takes a screendump through QEMU's monitor,
and reads the text back out of it — replaying the console's own wrapping and
scrolling over the serial log to work out what each cell should hold, then
comparing every pixel.

`key_check.py` boots it with a keyboard attached and a monitor socket, types
through `sendkey`, and compares both what the kernel says it read and what
ends up on the screen against what was sent. Between them the two scripts
check the console in both directions without a person looking at anything.

`make_font.py` regenerates `graphics/font8x8.zig` from `tools/font8x8.txt`.
The `.zig` is checked in, so building needs no Python; `--check` is what stops
the two drifting, and `--png` draws the font out so it can be looked at, which
is the only way to proofread eight bytes per glyph. The rest of the boot
assertions live in `.github/workflows/os-boot.yml`, which boots the x86 image
three times and requires all fifteen markers on every attempt, and boots the
ARM image three times — with 512 MiB, with 4 GiB, and on a PAN-capable CPU.
The 4 GiB one is not repetition: a machine that fits inside the boot stub's
single mapped gigabyte would pass with the code that maps the rest of RAM
deleted. All three attach a keyboard and require the kernel to find it, and
then `key_check.py` boots a fourth time to type at one.
