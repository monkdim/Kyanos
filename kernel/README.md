# The KyanOS kernel

The only part of KyanOS that is not written in Clarity. About 9 000
lines of Zig across two architectures, plus 2 000 lines of C that are not
kernel at all — a freestanding libc, so that a program compiled by
`clarity cc` has something to link against. That library now builds for
both, which is what lets the same Clarity program run on both.

Two kernels share most of that Zig. The **x86-64** side is the mature one:
it boots, schedules, and runs real user processes, one of which is a
Clarity program compiled to C and then to a static ELF. The **aarch64**
side is younger and is where the project is going, because Apple Silicon
is the hardware this is aimed at; it now runs unprivileged code at EL0 in
its own address space.

Neither has run on real hardware. Both boot under QEMU on every commit,
and `RUNNING.md` has the commands.

## What actually runs

Every claim below is a marker in a boot log that CI greps for, on three
consecutive boots for x86 and two differently-sized machines for ARM. A
claim with no marker behind it is in "What does not run yet".

**x86-64**, from `.github/workflows/os-boot.yml`:

- multiboot2 boot into long mode, higher-half at `0xFFFF_FFFF_8000_0000`
- GDT, IDT, and the FPU enabled
- physical page allocator, 4-level page tables, a slab heap
- preemptive priority round-robin scheduling — the preemption test is one
  no amount of cooperation between threads could pass
- FPU state preserved across a context switch
- a VFS with tmpfs underneath it: path resolution, create, write, read back
- two processes run in sequence, each loaded from an ELF written into the
  filesystem: `/bin/clarity-init` (Zig) and `/bin/clarity-demo` (a Clarity
  program through `clarity cc --freestanding`, linked against the libc in
  `user/libc`)
- in userspace: `.bss` zeroed, `brk` grows a heap that holds, SSE
  registers survive, `exit` returns through `sysret`, and the kernel
  outlives both processes
- the kernel never dereferences an address userspace gave it, on this
  architecture too: x86 has no `at s1e0r`, so `mm/uaccess.zig` walks the
  page tables the MMU would walk, from the loaded CR3, with the CPU's own
  rule (present and user at every level, writable at every level for a
  write), and every copy goes through the direct map of the frame, page by
  page. The init program hands the kernel three buffers it must refuse
  (unmapped, in the kernel's half, and its own read-only text as a `read(2)`
  target) and gets EFAULT for each, then reads the file for real. SMEP and
  SMAP are enabled where the CPU has them, and the gate boots `-cpu max` as
  well as `qemu64`: on the CPU without them, a kernel that still touched a
  user address directly would work, and on the one with them it faults

**aarch64**, on QEMU `virt`:

- boots from an ARM64 Linux Image header, so a bootloader hands it a
  device tree — which is how it learns where its memory and devices are
- higher-half kernel at `0xFFFF_FF80_0000_0000` on TTBR1, with the
  identity map *dropped*: the low half is no longer translated, which is
  checked by asking the MMU (`at s1e1w`) rather than by reading a bit back
- physical page allocator over the memory the device tree described, with
  the direct map extended to cover all of it
- generic timer at 100 Hz through a GICv2, with interrupts proven to
  arrive rather than assumed
- a 1024×768 framebuffer through `ramfb`, checked twice: the kernel reads
  its own pattern back, and CI takes a screenshot through QEMU's monitor
  and inspects the pixels
- **the boot log on screen**: a text console over that framebuffer, 64×48
  characters, with the serial console mirrored to it. CI reads the text back
  out of a screenshot — replaying the console's own wrapping and scrolling
  over the serial log to work out what each cell should hold, then comparing
  every pixel against a glyph it renders itself from `tools/font8x8.txt`
- **a serial console that can be typed into**: the PL011 was write-only, so
  the only way into this machine was the graphical window — which has to be
  found, focused and allowed to capture the pointer before a text prompt will
  listen. Reported from an M5 Mac as being unusable by hand, and every test
  passed straight through it. `-display none -serial stdio` now works, which
  is how a kernel is normally driven; `tools/serial_check.py` boots with no
  keyboard and no display and fails if either turns up
- **a keyboard, on its own interrupt**: virtio-input over the virtio-mmio bus,
  found by walking the thirty-two slots the device tree names rather than by
  knowing where QEMU puts them, and delivered through the GIC on the SPI that
  same node names. Events land in a ring here, so typing survives a program
  that is busy — which it did not before: the device queue holds sixty-four
  events, four to a key press, and only a read used to empty it. Measured at
  the shell: forty characters typed while `help` printed arrived as nine, and
  now arrive as forty. `tools/key_check.py` types them and fails if fewer
  come back
- **a filesystem, shared with x86_64 and unchanged**: `fs/vfs.zig` and
  `fs/tmpfs.zig` import `std`, the heap and each other and nothing else, so
  they run here as written. The marker comes from `fstest.zig` — the *same
  file* the x86_64 kernel runs, not a copy — which is worth stating because a
  port that quietly forked its code produces an identical boot log
- **`open`, `close`, and `read` from a file**: six system calls now. A path
  arrives as a pointer the process chose, so it is copied into the kernel
  before use — page by page, translated for reading, bounded at 256 bytes,
  and rejected rather than truncated if it has no terminator, because a
  silently shortened path names a different file
- **`read(2)`**: a program at EL0 asks for a line and gets one. The buffer is
  translated through the process's own page tables **for writing** — a
  pointer into the program's own read-only text is refused with `EFAULT`,
  which the init program checks by passing one deliberately, because a kernel
  that translated it for reading (the same call `write` makes, and the easy
  mistake) would find the page perfectly readable and scribble through its own
  map into the program's instructions. A refused read also must not eat the
  line: the second read gets it back
- **typing, and seeing it**: a canonical-mode line discipline joins the two —
  characters are echoed to the screen as they arrive, backspace erases, Enter
  hands over a line. CI types at it: `tools/key_check.py` sends the alphabet
  twice through QEMU's monitor (fifty-two keys, over two hundred virtqueue
  events, which is what proves the driver recycles its buffers), then sends
  `helxo`, two backspaces and `lo`. The kernel must end up holding `hello`
  **and** the screenshot must show `hello` on a row of its own — two
  different claims, and a console that echoed the backspaces without erasing
  anything satisfies only the first. Typing at all is the part no marker in a
  log can establish: "0 lines" is exactly what a working driver reports when
  nobody is at the keyboard
- per-process address spaces in TTBR0 — three-level tables, ASID-tagged,
  with permissions verified by asking the MMU to translate as EL0 would
- **a program at EL0**: `hello from EL0 on aarch64` in the boot log is
  printed by a user program through `write(2)`, not by the kernel. It reads
  its own memory, is interrupted by the timer and carries on, writes its
  answer back where the kernel can see it, and exits with a status the kernel
  checks — and when it writes to its read-only text page, the kernel takes
  the CPU back
- the kernel never dereferences an address userspace gave it: a user pointer
  is translated through the process's own page tables and read through the
  kernel's direct map. Privileged Access Never is enabled where the CPU has
  it, so that is enforced rather than intended — and the boot gate runs a
  PAN-capable CPU as well as one without, because on the one without, doing
  it the wrong way also works
- kernel threads switching, cooperatively and preemptively — the preemption
  test's threads never yield, and it checks not only that both ran but that
  each resumed inside its own code, which counters alone cannot see
- **a program loaded from an ELF**: `/bin/clarity-init` for aarch64 is built
  by a compiler and laid out by a linker into three segments with different
  permissions and a `.bss` whose memory size exceeds its file size. It runs
  twice, in two address spaces, over frames the first run returned — so its
  own checks that `.bss` reads zero and `.data` came from the file are checks
  on the loader, and its exit status carries the verdict
- a heap: `brk` moves a process's break and maps the pages behind it, and the
  program writes through the new break and reads it back — because a kernel
  returning the number it was asked for proves nothing about what is mapped
- **a Clarity program**: `/bin/clarity-demo` is the same generated C the
  x86_64 side runs, linked against the same `kernel/user/libc`, and its
  output is byte for byte identical — `float 3.1415929203539825
  1.4142135623730951 6.25`, checked literally, because those come out of
  strtod, the library's arithmetic, a hardware square root and dtoa, and a
  subtly wrong one still prints a plausible number

## What does not run yet

Compiled by `zig build check`, and nothing has ever executed a line of it:

- `fs/devfs.zig`, `fs/procfs.zig`, `drivers/tty.zig`, `boot/uefi.zig`

These used to be compiled by *nothing*. Zig never parses a file nothing
imports, so a module outside every build is not "written and compiling" — it
is written and unread. That was measured, not supposed: a line of deliberate
nonsense appended to any of the four produced zero errors from `zig build`
and `zig build aarch64` alike. `checkonly.zig` imports them and
`zig build check` compiles it, which is on the boot gate; the same nonsense
test now fails that step for all four while both ordinary builds stay silent.

Its first run found a real one — `boot/uefi.zig` discarded a parameter with
`_ = handle;` and then used `handle` twenty-eight lines later.

The check says they are valid Zig against the code they refer to. It says
nothing about whether they work, and they do not: `drivers/tty.zig` sketches
a line discipline, and the working one is `drivers/line.zig`, written fresh
rather than resurrected.

Compiled, but only on x86_64, and never executed past detection:

- `drivers/ahci.zig`, `drivers/virtio_net.zig` — both scan PCI correctly and
  every operation after that returns `NotImplemented`

Not written:

- The shell is one program with four commands, not a session. Nothing keeps a
  terminal, a process table or a working directory, and `exit` ends the boot's
  last program rather than returning to anything. Reading does not really
  block either: there is no scheduler to block a thread on, so a read spins
  and gives up after a while — a stand-in for blocking, not blocking. How
  long it waits comes from the kernel command line (`clarity.idle=<seconds>`,
  two minutes by default); it was a fixed three seconds until a Mac ran this
  by hand and the shell had exited before a key could reach it.
- The keycode table covers the main block only — no function keys, keypad,
  arrows or modifiers past shift, because nothing reads them yet and a table
  of untested entries is a table of guesses. The line editor has backspace and
  nothing else: no kill-line, no history, no cursor keys.
- Preemption stops at the kernel's door. System calls run with interrupts on,
  so devices are serviced during one, but a time slice that expires inside a
  system call is ignored rather than taken: suspending a half-finished call
  would leave its frame on a stack nothing returns to until that thread runs
  again, and there is no scheduler yet that could say what should happen when
  it does. A program in a long system call therefore cannot be preempted.
- On aarch64: a scheduler and a filesystem. Threads can be switched, but
  nothing keeps run queues, priorities or a process table — the boot selftest
  drives the switching primitive directly. Programs are loaded from an ELF
  embedded in the kernel image, because there is nowhere to read one from.
- On aarch64, six system calls exist — `read`, `write`, `open`, `close`,
  `brk`, `exit` — and every other number returns `ENOSYS`. There is no
  `getdents`, so the shell has `cat` and no `ls`; no `exec`, so nothing can
  start a program; no `stat`, `lseek` or `unlink`. The rest wait on a process
  table.
- Of the 41 syscall numbers in `syscall/dispatch.zig`, 16 are wired on x86_64:
  read, write, open, close, mmap, brk, exit, fork, exec, wait, kill,
  getpid, getppid, nanosleep, clock_gettime, ioctl. The rest return
  `ENOSYS` — sockets, pipes, dup, and most of the directory calls among
  them.
- No SMP on either architecture. One CPU; the others are parked in the
  boot stub.
- No disk. tmpfs is the root filesystem and there is nothing under it.

## Layout

```
kernel/
├── boot/
│   ├── start.S             x86 multiboot2 entry, switch to long mode
│   ├── multiboot2.zig      boot-info parser
│   ├── fdt.zig             flattened device tree parser (ARM)
│   ├── uefi.zig            UEFI loader stub — nothing calls it
│   ├── linker.ld           x86 higher-half link layout
│   └── linker_aarch64.ld   ARM higher-half link layout
├── arch/x86_64/
│   ├── console.zig         COM1 + optional VGA
│   ├── port.zig  gdt.zig  idt.zig  paging.zig
│   ├── syscall.zig         SYSCALL/SYSRET entry
│   ├── context.zig/.S      thread switch, including CR3 and FPU state
│   ├── fpu.zig             FXSAVE area and a clean initial image
│   └── timer.zig           PIT
├── arch/aarch64/
│   ├── boot.S              Image header, EL2→EL1, MMU on, branch high
│   ├── vectors.S           the 16 exception vectors
│   ├── user.S              enter and leave EL0; the EL0 probe
│   ├── context.zig/.S      kernel thread switch, including the address space
│   ├── vm.zig              physical ↔ kernel-virtual, in one place
│   ├── mmu.zig             translation after the boot stub; cache upkeep
│   ├── paging.zig          per-process TTBR0 page tables
│   ├── trap.zig            trap frame, system calls, faults, user pointers
│   ├── console.zig         PL011
│   ├── virtio_mmio.zig     the virtio MMIO transport, legacy and modern
│   ├── virtio_input.zig    virtio-input: one event virtqueue
│   ├── keyboard.zig        Linux keycodes into characters
│   ├── gic.zig  timer.zig  fwcfg.zig  ramfb.zig
├── mm/
│   ├── pmm.zig             bitmap page-frame allocator (both architectures)
│   ├── vmm.zig             x86 4-level page tables, AddressSpace
│   └── heap.zig            slab allocator over the pmm
├── drivers/line.zig        characters into lines — echo, backspace, Enter
├── drivers/stdin.zig       one editor, shared by the selftest and read(2)
├── arch/console.zig        the console, whichever machine this is
├── sched/
│   ├── process.zig         one Process per address space, many Threads
│   └── scheduler.zig       preemptive priority round-robin
├── syscall/dispatch.zig    syscall number → handler
├── fs/
│   ├── vfs.zig             path resolution, inodes, an FsOps vtable
│   ├── tmpfs.zig           the root filesystem
│   └── devfs.zig procfs.zig — written, unreached
├── loader/
│   ├── elf.zig             ELF64 parser
│   ├── segments.zig        map PT_LOADs into a space — shared by both
│   ├── load.zig            x86_64: page tables, regions, brk
│   └── load_aarch64.zig    aarch64: page tables, I-cache, page ownership
├── drivers/                framebuffer, ps2, pci wired; ahci, virtio_net stubs
├── graphics/
│   ├── fb.zig              architecture-independent drawing surface
│   ├── console.zig         a text console over it — one for both machines
│   └── font8x8.zig         generated from tools/font8x8.txt; do not edit
├── user/
│   ├── init.zig            /bin/clarity-init (x86_64)
│   ├── init_aarch64.zig    /bin/clarity-init (aarch64)
│   ├── clarity_demo.clarity → clarity_demo.c, the compiled Clarity program
│   ├── libc/               a freestanding libc: stdio, string, math, malloc.
│   │                       Portable C, plus three files with an #ifdef in
│   │                       them: sys.c, start.S, setjmp.S
│   └── user.ld             static user link layout, both architectures
├── tools/
│   ├── fb_check.py         boots ARM, screenshots it, reads the text back
│   ├── key_check.py        boots ARM, types at it, checks the lines and pixels
│   ├── font8x8.txt         the console font, as 95 glyphs of ASCII art
│   ├── make_font.py        turns that into font8x8.zig, and into a picture
│   └── run_x86.sh          builds the GRUB ISO `zig build run` boots
├── checkonly.zig           imports the modules no kernel does, so they compile
├── main.zig                x86 entry
├── main_aarch64.zig        ARM entry
└── RUNNING.md              how to build and boot both
```

The `*test.zig` files at the top level (`threadtest`, `preempttest`,
`fputest`, `fstest`, `threadtest_aarch64`) and `initprog.zig` /
`clarityprog.zig` are the boot selftests. They are not a test framework: each one is a thing the kernel
does at boot, printing a marker that CI requires. That is deliberate — a
kernel subsystem that is never executed looks exactly like one that works,
and most of the bugs found in this kernel were in code that had never run.

## Build

Zig 0.13. From this directory:

```sh
zig build              # x86-64  -> zig-out/bin/clarity-kernel
zig build aarch64      # aarch64 -> zig-out/bin/clarity-kernel-aarch64.img
zig build run          # boot the x86-64 kernel (builds a GRUB ISO first)
zig build run-aarch64  # boot the aarch64 kernel, with a screen
```

`RUNNING.md` has the QEMU command lines, what the output should look like,
and the Apple Silicon path.

## Talking to the kernel from Clarity

`stdlib/kernel_abi.clarity` is the source of truth for syscall numbers,
errno values, file mode bits, mmap flags, and signals; the Zig enums in
`syscall/dispatch.zig` and `fs/vfs.zig` carry the same values.

`stdlib/syscall.clarity` is the userspace wrapper. On Linux and macOS it
delegates to the host runtime; the same signatures issue real syscall
instructions when running on KyanOS.

`stdlib/scheduler.clarity` and `stdlib/vfs.clarity` are pure-state mirrors
of the kernel's scheduler and VFS, so the design contracts (priority
ordering, block and wake, path resolution, tmpfs read/write/truncate) can
be exercised by `stdlib/test_kernel.clarity` without booting QEMU. They
are models, not the kernel: passing them says the design is consistent,
not that the kernel implements it. Only the boot log says that.
