# KyanOS — Path Forward

This document tracks **what's next for KyanOS**. The 1.0 development history (Phases 56–76) lives in git. Language-side gaps live in [GAPS.md](GAPS.md). This file covers the OS: kernel, freestanding runtime, compositor, window manager, desktop shell, default apps, ISO packer, QEMU launcher, themes, and the release pipeline.

---

## Where we are (September 2026)

KyanOS is **experimental and under active development**, but the boot path is
no longer hypothetical. Each claim below is backed by a CI gate that runs on
every pull request; anything not gated is called out as unverified.

- **The x86_64 kernel boots, verified on every PR.** GRUB loads the
  multiboot2 kernel, the boot stub switches to long mode, and the kernel runs
  its full init sequence to the `ClarityOS ready.` marker on serial:

  ```
  ClarityOS micro-kernel starting...
    [ok] GDT + IDT
    [ok] memory: pmm + vmm + heap
    [ok] scheduler
    [ok] syscalls
    [ok] vfs + rootfs
    [ok] drivers
  ClarityOS ready.
  ```

  The `OS boot (linux-x64, TCG)` job builds the kernel, wraps it in a GRUB
  rescue ISO, and boots it under QEMU **three times, requiring all three** to
  reach the marker — reliability is part of the gate, not a re-run away.
- **The AArch64 (Apple-Silicon-class) kernel runs programs, draws a screen,
  reads a keyboard, and can be typed at over a serial line.** The
  `OS boot (aarch64, TCG)` gate boots it three ways — 512 MiB with 32 required
  markers, then a PAN-capable CPU and 4 GiB with the thirteen and fourteen
  that those configurations exist to prove — then screenshots the display,
  types at the keyboard, and types at it again with no keyboard and no
  display at all. It has also been booted on an **Apple M5** and driven by
  hand through the shell; the transcript is in `kernel/RUNNING.md`. What is
  behind those markers:

  - higher-half kernel on TTBR1 at `0xFFFF_FF80_0000_0000` with the identity
    map **dropped**, checked by asking the MMU (`at s1e1w`) rather than by
    reading a bit back
  - a page allocator over the memory the device tree described, with the
    direct map extended to cover all of it — the 4 GiB boot exists because a
    machine that fits in the boot stub's one mapped gigabyte would pass with
    that code deleted
  - per-process address spaces in TTBR0, ASID-tagged, permissions verified by
    asking the MMU to translate as EL0 would
  - programs at EL0: `/bin/clarity-init` and `/bin/clarity-demo` are a
    compiler's and a linker's output, loaded from ELF, run twice in two
    address spaces. The second is a **Clarity program** whose output is byte
    for byte identical to the x86_64 side, floating point included
  - four system calls — `read`, `write`, `brk`, `exit`. User pointers are
    translated through the process's own page tables, never dereferenced, and
    Privileged Access Never is enabled where the CPU has it so the hardware
    enforces that rather than this kernel intending it
  - kernel threads switching, cooperatively and preemptively
  - a 1024×768 framebuffer with the boot log drawn on it, 64×48 characters,
    and a keyboard over virtio-input — on its own GIC interrupt, with a line
    discipline above it
  - tmpfs and the VFS, the same files the x86_64 kernel runs
  - a shell, reading its own input and running commands against that
    filesystem

  This is no longer "the start of the Apple Silicon track". It is not parity
  either: there is no scheduler on this side. See **Outstanding on aarch64**
  below.
- **The kernel reaches userspace.** It writes a small ELF to
  `/bin/clarity-init`, and `spawn_user` reads it back off the VFS, parses it,
  maps its segments into a fresh address space, switches CR3 and enters ring
  3. The program's `write` reaches the kernel with the arguments it passed,
  and its `exit` returns through `SYSRET`. All of it is on the boot gate:

  ```
  init: wrote 196 bytes to /bin/clarity-init
  init: entering userspace
  hello from /bin/clarity-init
    [exit] status=0
  ```

  What runs through it is no longer hand-assembled bytes. `/bin/clarity-init`
  is compiled and linked, and `/bin/clarity-demo` is a **Clarity** program
  through `clarity cc --freestanding`, linked against the freestanding libc
  in `kernel/user/libc`. Both are on the gate, on both architectures, and the
  demo's floating-point output is checked digit for digit because a subtly
  wrong `strtod` or `dtoa` still prints a plausible number.
- **Threads are preempted.** A 100 Hz PIT tick takes the CPU from a thread
  that never yields and gives it back. Gated on a test cooperative scheduling
  cannot pass: two threads, neither of which calls `yield`.
- **One language above the syscall boundary.** ~50,000 lines of Clarity: the
  runtime, init, tmpfs/devfs/procfs, input pipeline, compositor, window
  manager, dock, launcher, and the default apps. The desktop is exercised by
  a large unit-test suite (60 test files, all green) and by render
  verification, but it runs hosted — it has not yet run *on* the kernel,
  because there is no userspace to host it.
- **The Kyan identity.** Obsidian (dark, default) and Quartz (light) share one
  violet→cyan signature; the spring themes remain as selectable legacy
  palettes. Switchable live in **Settings → Appearance**.
- **Performance targets, still not gates.** Under-5 s boot, 60 fps,
  under-256 MB idle, under-250 ms app launch. None is measured: there is no
  booting desktop to measure yet.

---

## Userspace runtime — no longer the blocker

A Clarity program compiled by the Clarity compiler now runs on ClarityOS in
ring 3, and the boot gate requires it. What follows is how that was reached
and what it rests on, kept because the reasoning is what makes the next
decision easier — not because it is still outstanding.

**The QuickJS route is not needed.** `runtime/freestanding` was built to embed
QuickJS and have it evaluate the transpiled Clarity bundle, which meant
supplying a freestanding libc broad enough for a JavaScript engine — the
printf family, `strtod`, `qsort`, `setjmp`, math, file I/O, and the C headers
none of it had. That was correctly described as "the bulk of the work". It is
also unnecessary: `clarity cc` compiles Clarity to C to a native binary, with
no JavaScript engine anywhere.

**Measured, not estimated.** `clarity cc --freestanding` compiles the C
prelude without its POSIX half — no files, sockets, process control, dynamic
loading or `/proc` — and reports what the object still needs. Two programs
bracket the range.

A small one (strings, a list, a loop, a function, `show`) needs sixteen:

```
fmod free getenv malloc memcpy printf qsort realloc
setjmp snprintf sprintf strcat strcmp strcpy strlen strtod
```

One exercising nearly all of what the profile keeps — classes and methods,
`try`/`catch`/`finally`, sorting, `hash`, `json_string`, the ctype and math
builtins — needs twenty-nine, adding:

```
ceil exit floor isdigit isspace longjmp memset
rand sqrt srand strstr strtol tolower toupper
```

So the number is a property of the program, not a fixed floor; thirty is the
honest ceiling for the profile as it stands. The printf surface across both is
five specifiers: `%ld`, `%s`, `%g`, `%.*g`, `%08lx`. `qsort` appears only in the
collector's index sort, `strtod` only in float round-tripping, `getenv` only
to read `CLARITY_GC`. A program using more float math would add the libm
functions it calls, and nothing else.

The check behind those numbers is a test, not a note: `test_c_codegen`
compiles the freestanding C with `-nostdinc` against a stub C library that
declares only these headers — `stdio.h`, `stdlib.h`, `string.h`, `math.h`,
`ctype.h`, `setjmp.h` — so the host's POSIX headers are unreachable. If the
profile ever reaches back for one, that test fails.

That is a few hundred lines, not a libc port, and `malloc` now has something
to sit on: the kernel grows a process heap through `brk`.

**The libc subset exists.** `kernel/user/libc` — 1,509 lines of C and x86-64
assembly — is that library, and a compiled Clarity program using classes,
closures, exceptions, maps, sorting, strings and floating point links against
it and runs with nothing underneath it but `write`, `brk` and `exit`. The
syscall numbers are in one header, so the same objects build for ClarityOS or
for a Linux host, and `stdlib/test_libc.clarity` builds each of its test
programs twice — once against the host's C library, once against this one —
and requires the outputs to match.

`printf("%g")` and `strtod` were the pair to get right, and they agree with
glibc exactly across 8,090 comparisons including 8,000 random bit patterns:
both are done on exact integers rather than on floating-point powers of ten,
because the runtime finds the shortest round-tripping float by printing at
increasing precision and parsing back, and that loop is only meaningful if
neither direction approximates. The transcendentals are series
approximations, bounded and measured — 1-2 ulp for sin, cos, exp and log,
6 for pow, with one honest gap for sine of a large angle, recorded in
`kernel/user/libc/README.md`.

**And it runs.** `/bin/clarity-demo` is a Clarity program — a class and its
methods, `try`/`catch`/`finally`, a sorted map, higher-order functions over a
list, floating-point formatting, and four hundred allocations — compiled by
`clarity cc --freestanding`, linked against `kernel/user/libc`, written to the
filesystem, loaded by `spawn_user`, and printing from ring 3. Its output is
byte-identical to the interpreter's, and the boot gate requires it on all
three boots.

It is the *second* process, which is a claim of its own: the first one exits
and the kernel carries on. That needed two things the kernel did not have. A
user thread now gets a kernel-side entry context, so the scheduler dispatches
it like any other thread instead of the boot path entering ring 3 by hand and
never coming back. And the context switch now switches address spaces, which
it had never needed to do while exactly one process existed.

The generated C is checked in as `kernel/user/clarity_demo.c`, because the
OS-boot job installs Zig and QEMU and nothing else — a kernel build that had
to fetch a Clarity compiler would tie booting the OS to a network.
`stdlib/test_libc.clarity` regenerates it and fails if it has drifted, which
is the check that keeps that artifact honest and runs where the compiler does
exist.

**Not pursued, and why.** `runtime/native_vm` (a pure-Zig bytecode VM) was a
484-line skeleton, removed in September 2026; taking it to "runs the stdlib" means reimplementing
strings, maps, lists, classes, closures and GC in Zig, which is larger than
the thirty symbols above, not smaller. Building against static musl trades
"write a libc" for "implement the Linux syscall subset musl needs", which is
a bigger surface than the one measured here and pins the ABI to Linux's.

---

## Kernel — verified and outstanding

**Verified working** (exercised by the boot gate):

- Multiboot2 boot, higher-half link, long-mode entry, and page tables mapping
  the identity window, the HHDM (`0xFFFF_8000_…`, which the VMM depends on),
  and the kernel window.
- Physical page allocator over the firmware memory map, reserving the whole
  loaded kernel image so it cannot hand out its own pages.
- Slab heap, scheduler init, syscall MSR wiring, VFS + tmpfs root mount.
- Context switching, both cooperative and preemptive, and path resolution
  through the VFS — each proved by a boot self-test that fails loudly rather
  than a marker that merely says a function was called.
- Exception handlers that report: a fault prints vector, name, error code and
  a register dump. This is how the two faults in the userspace hand-off were
  diagnosed, from CI logs, without a debugger.
- Driver init: PS/2 (8042) with bounded status waits, framebuffer mapping
  through the real kernel address space.

**Outstanding on x86_64:**

- **`execve`.** `spawn_user` is exercised on every boot; `exec` — replacing a
  running process's image — shares its loader but has no caller yet, so it
  has never been analysed by the compiler, let alone run. Everything in this
  kernel that was in that state turned out to be broken, so assume it is.
- **The kernel heap and page allocator are not preemption-safe.** Nothing
  allocates from a thread today (every spawn happens on the boot path, where
  preemption is a no-op), so it is not reachable — but it is the next lock
  that has to exist, before anything that allocates runs as a thread.
- **User pointers are validated on both architectures now.** x86_64 had
  none of it: `sys_read`, `sys_write` and `sys_open` cast the argument to a
  pointer and used it, so a bad one was a page fault in ring 0. x86 has no
  `at s1e0r`, so `mm/uaccess.zig` walks the page tables the MMU would walk,
  from the loaded CR3, with the CPU's own rule (present and user at every
  level, writable at every level for a write, a huge page ending the walk),
  and every copy goes through the direct map of the frame, page by page.
  `read(2)` checks its whole destination for writing before it reads the
  file, so the program's own text as a target is refused and the file is not
  consumed. SMEP and SMAP are turned on where the CPU has them and the boot
  gate runs `-cpu max` as well as `qemu64`, for the same reason the aarch64
  job runs PAN: on the CPU without it, doing it the wrong way also works.
  What is still open is what happens to a process that faults on its own:
  the page-fault handler halts the machine on both architectures.
- **AHCI and virtio-net are skeletons.** Both scan PCI correctly, but
  `attach`/`send_frame`/`recv_frame` are `NotImplemented`. PCI enumeration
  itself is real.

**Outstanding on aarch64.** Exception vectors, page tables, the generic timer,
per-process address spaces, EL0, system calls, the ELF loader, a framebuffer
console and a keyboard are all done and gated — see **Where we are** above.
What is left, in rough order:

- **A scheduler.** The switching primitive works, cooperatively and
  preemptively, and the boot selftest drives it directly. Nothing keeps run
  queues, priorities or a process table, so programs run one after another
  rather than at the same time.
- **A filesystem with something under it.** tmpfs and the VFS run here now,
  unchanged from the x86_64 side, and `cat` reads through them. There is
  still no disk, so the root is tmpfs and programs are still loaded from ELFs
  embedded in the kernel image — there is nowhere else to read one from.
- **A session.** The shell reads, parses and runs commands, and that is all
  it is: nothing holds a terminal, a process table or a working directory,
  and `exit` ends the boot's last program rather than returning to anything.
  The call it is most obviously missing has its own entry below.
- **`readdir` is a system call now, and the shell has `ls`.** ✅ The VFS packs
  a directory into a caller's buffer — inode, record length, type, name
  length, the name, a NUL, padded to eight — and `readdir(fd, buf, len)` is
  wired on both architectures, checking the destination for writing before it
  consumes anything so a bad pointer cannot cost the caller entries it never
  saw. `ls [PATH]` walks it, marks directories with a trailing slash, and says
  "not a directory" rather than printing nothing. Driven over the serial line
  by `tools/serial_check.py` on every PR: `ls /`, `ls /bin`, and `ls` on a
  file.
- **`exec`, so the shell can start a program.** Every program on this machine
  is loaded by the boot path from an ELF embedded in the kernel image and run
  to completion in a fixed order. The shell can run its own built-in commands and
  nothing else. This needs a process table before it needs anything else.
- **Preemption stops at the kernel's door.** System calls run with interrupts
  on, so devices are serviced during one, but a time slice that expires inside
  a system call is ignored rather than taken: suspending a half-finished call
  would leave its frame on a stack nothing returns to until that thread runs
  again, and there is no scheduler that could say what happens when it does.
  A program in a long system call cannot be preempted.
- **The PL011 is polled, not interrupt-driven.** The keyboard got its
  interrupt; the serial line did not. Its receive INTID is in the device tree
  and nothing reads it. It has not bitten yet — the UART holds sixteen bytes
  in its own FIFO and a person types slower than that — so this is a known
  asymmetry rather than a known bug, which is exactly the kind of thing that
  stops being true without warning.
- **Real blocking.** `read(2)` cannot block: there is no scheduler to block a
  thread on, so it spins and gives up after a while. How long is now the
  kernel command line's business — `clarity.idle=<seconds>`, two minutes by
  default — but a timeout is still a stand-in for blocking, and it is
  documented as one in `drivers/stdin.zig`.
- **GICv3, so Apple hardware can run this at native speed.** The emulated
  path has been run on an Apple M5 and driven by hand through the shell to
  `exit 3` — see the transcript in `kernel/RUNNING.md`. The accelerated one
  has not, and cannot. Measured on the same M5: `qemu-system-aarch64 -accel
  hvf` answers `HVF does not support GICv2 emulation` and refuses to start.
  `arch/aarch64/gic.zig` speaks GICv2 and nothing else, and Apple Silicon has
  no GIC at all — the real controller is Apple's AIC — so QEMU emulates one,
  and under HVF it emulates only a GICv3. There is no flag that avoids this.
  The emulated `cortex-a72` path works on a Mac and is what to use meanwhile.
- **Bare metal.** Everything above is QEMU `virt` — including the Apple M5
  session, where the Mac is running QEMU rather than running this kernel.
  Apple hardware proper needs m1n1, and then AIC rather than any GIC at all.

The shared subsystems (pmm, heap, VFS, scheduler) are mostly
architecture-neutral Zig already, but they reach into port I/O, GDT/IDT and
x86 4-level paging, so they cross over one phase at a time.

---

## CI gates (the developer workflow)

Both OS gates are live in `.github/workflows/os-boot.yml`:

- **`OS boot (linux-x64, TCG)`** — `zig build` the kernel, `grub-mkrescue` a
  kernel-only rescue ISO, boot it under `qemu-system-x86_64` three times,
  require `ClarityOS ready.` on all three.
- **`OS boot (aarch64, TCG)`** — `zig build aarch64`, then boot under
  `qemu-system-aarch64 -M virt` **three times**: 512 MiB, 4 GiB, and on a
  PAN-capable `-cpu max`. The first requires all 28 markers; the other two
  require the subset each is for — that the direct map was extended over all
  4 GiB and the allocator manages it, and that a PAN-capable CPU reaches
  userspace with no exception logged. Then two tools that look at the machine
  from outside:
  - `kernel/tools/fb_check.py` screenshots the display through QEMU's
    monitor and compares **every character cell** against a replay of the
    serial log, rendering the glyphs itself from `tools/font8x8.txt`
  - `kernel/tools/key_check.py` types through the monitor and checks both
    what the kernel read and what ended up on screen — including a line
    typed wrong and corrected with backspace, which those two disagree about
    if the console echoes without erasing
- **`zig build check`** runs beside the x86 kernel build, compiling the
  modules no kernel imports (`drivers/tty.zig`, `fs/devfs.zig`,
  `fs/procfs.zig`, `boot/uefi.zig`). Zig never parses a file nothing
  imports, so without it those four were checked by nothing at all.

Both are deliberately **kernel-only**: they do not depend on the desktop
runtime, so they gate the kernel today rather than waiting on it. The "marker
printed from *Clarity* code" that this section used to call the real test now
exists on both architectures — `/bin/clarity-demo` is a Clarity program
through `clarity cc --freestanding`, and its `clarity-demo: all checks
passed` line is required on every boot. What is still missing is the *ISO*
gate: booting the full image with the desktop on top of it.

GitHub runners have no `/dev/kvm`, so both boot under TCG.

---

## Hardware & drivers

Things that work today are useful in QEMU. Real hardware coverage is shallow.

- **Input.** macOS IOKit input (real keyboard/mouse/trackpad on bare metal Macs) is its own programming model — deferred to a dedicated phase.
- **Multi-touch.** Slot tracking for true multi-touch surfaces.
- **Devices.** USB HID, NVMe, real Intel NIC drivers — the kernel's PCI enumeration is generic; concrete drivers are stubs.
- **Audio.** Real ALSA / PulseAudio / PipeWire streaming via FFI. `stdlib/audio.clarity` shells out to whichever stock player is installed (`paplay`, `aplay`, `afplay`, `ffplay`) and moves one master level through `amixer`. There is no stream API of our own, which is why the next entry is a feature and not a setting.
- **A volume per app, not one for the machine.** Every sound an app makes goes through a stream the mixer owns, each stream carries its own level, and Sound in Settings lists whatever is playing so you can turn one app down without touching the rest — the browser tab that shouts over your music, the game whose menu is louder than the game. macOS still has a single output slider and sends you to third-party software (Background Music, SoundSource) for per-app control; on a desktop OS that is a thing the system should own. It needs the PCM stream API above first: per-stream gain is a property of the mixer, and today there is no mixer to give it to.
- **GPU.** Vulkan/Metal FFI bindings for a hardware-accelerated framebuffer. Software framebuffer is the current path; this is the largest single-feature deferral.
- **Image decoders.** PNG (DEFLATE) and JPEG (DCT) decoders. Sizeable enough to be their own phase. Wallpapers and app icons currently use procedural Clarity drawing instead of bitmaps.

---

## Networking

- **WiFi.** Association, WPA2/3 handshake, scan UI in Settings.
- **DHCP / DNS / firewall.** Today's stack is `user`-mode QEMU networking; bare-metal needs the real thing.
- **IPC transport.** The system-services IPC API is shared-memory only. A Unix-domain-socket transport using the same API surface is the planned follow-up so apps can talk across machine boundaries (and across containers, if we ever go there).

---

## UI toolkit & desktop polish

The toolkit ships the widgets needed to build the eleven default apps. Filling out the long tail:

- **Widgets — done.** Dropdown, RadioButton, Toggle, Tabs, TreeView and Tooltip
  have all landed; the Phase 60 deferral list is clear.
- **Shipped since:** window controls (close/minimize/zoom) and dock restore,
  window resize by the corner handle, a scientific Calculator, a Files
  tree-view sidebar plus a details/preview pane, switchable Settings panes, a
  live System Monitor, a Prism game-detail view, an interactive Terminal echo
  shell, and a real text Editor with lexer-backed syntax highlighting.
- **Still open — window animations.** Drag-to-reorder in the dock;
  minimize-to-dock animation.
- **Still open — Files.** Drag-and-drop between panes; PDF/image previews
  (image previews are gated on the decoders below).
- **Still open — Editor.** Tabs, minimap, and wiring the editor to the LSP for
  diagnostics (highlighting is done, via the lexer).

---

## Runtime & terminal

- **PTY — done on the hosted build.** `stdlib/pty.clarity` drives a real PTY
  via `openpty` + `posix_spawn` through FFI (`posix_spawn` rather than
  `forkpty` so the Bun runtime is never left forked), and the Terminal app
  runs a live shell on it where `pty_supported()` is true. What remains is a
  PTY inside *ClarityOS*, which is gated on the freestanding runtime existing
  at all. Hosts without a PTY fall back to the built-in echo shell.
- **Hot reload.** The app framework supports module reload at the protocol
  level; the runtime hook that actually swaps modules in a live process is the
  gap.
- **Native bytecode VM.** `runtime/native_vm/` was a Zig implementation of
  the Clarity bytecode VM that would have let the runtime ditch QuickJS.
  Measured state when it was removed (September 2026): 54 opcodes defined,
  **20 implemented** (not half), `load_bundle` still returned
  `error.NotImplemented`, 484 lines in total. Note the real
  cost: finishing it means reimplementing Clarity's runtime semantics —
  strings, maps, lists, classes, closures, GC — in Zig, which is a *larger*
  job than porting a freestanding libc, since the JavaScript runtime already
  provides those semantics. Treat as a stretch goal for 1.x.

---

## Distribution & polish

- **Installer.** A Clarity-driven installer that writes the ISO to a USB stick with progress, partitioning, and an EFI fallback. The CLI surface (`clarity os install`) is reserved; the implementation isn't.
- **Update channel.** Signed deltas via the package registry transport. No design yet.
- **Crash report upload.** The crash dialog collects journal + watchdog state into a bug report; nothing receives it. A minimal sink is part of the same work as the registry's HTTP surface in [GAPS.md](GAPS.md).
- **Branding hygiene.** `stdlib/test_polish.clarity` still asserts the literal `"clarityos.dev"`; the website generator (`stdlib/website_gen.clarity`) bakes that domain into `iso_url`, `og:image`, and `og:url`. Nothing breaks at runtime — the site isn't deployed — but a future domain swap touches all three files in lockstep.

---

## Hearth — a local-AI base app (long-term, after the desktop is solid)

A first-class, private, on-device AI studio shipped *with* KyanOS — port of the existing PC "Hearth" (Python/PySide6 cockpit over local model engines). Not near-term: this waits until boot-to-desktop and the UI toolkit are in a nice spot. Captured here so the shape is on record.

**Architecture (proven by the PC build).** Hearth is a *cockpit*, not a model — it drives model engines that run as separate concerns and talks to them locally. That decoupling is what makes a Clarity port sane: rebuild the cockpit, not the math.

- **App layer → 100% Clarity.** The launcher/panel UI, chat with markdown + syntax-highlighted code, model management, prompt/style config, projects, tools, settings, the OpenAI-compatible API surface, and the pipeline orchestration are all ordinary Clarity + KyanOS-toolkit work. This is the bulk of the app and it is entirely writable in Clarity.
- **LLM brain → Clarity + `llama.cpp` via FFI.** `brain.py` is ~250 lines of prompt templates over a thin `POST /v1/chat/completions`; the Clarity version FFIs `llama.cpp` (portable C, GGUF models) instead of HTTP-to-Ollama. This is the one AI engine with a real path to running **CPU-only inside bare-metal KyanOS** (slow on large models, usable on small quantized ones). Everything *we* write stays Clarity; `llama.cpp` is a linked dependency doing the SIMD matmuls, the way numpy backs Python.
- **Image generation (SDXL) → stays external.** Nobody reimplements SDXL in Clarity — it needs a GPU and a Metal/Vulkan-class compute stack. On a *hosted* KyanOS desktop the Clarity app talks to ComfyUI over HTTP (works today in principle); *inside* bare-metal KyanOS it is gated on GPU drivers + a compute stack, i.e. an OS-level prerequisite, not app work. This is the honest ceiling.
- **Pipelines (upscale / video / PDF / marketing / 3D-print / mods) → split.** Orchestration, templating, and **customizable branding** (swap the hardcoded brand names for user config — the clean, easy part) port to Clarity; the heavy compute does not (ESRGAN is a neural net, cv2 MP4 is a codec → FFI, Blender parametric 3D is effectively a CAD kernel). Each heavy pipeline is its own sub-project.

**Honest verdict.** *Can Hearth be written and used entirely in Clarity?* The **app**: yes, fully. The **LLM brain**: yes in practice as Clarity + a `llama.cpp` FFI (and *technically* even as pure Clarity — a GGUF loader + transformer loop compiled via `clarity cc` produces correct tokens, just far too slow without SIMD/GPU to be more than a proof). **Image/3D**: no — they stay external until KyanOS grows a GPU/compute story. So the LLM half is genuinely reachable OS-native long-term; the image/3D half rides on the same track as GPU support landing in the kernel.

**Phasing when the time comes.** (1) Hosted Clarity Hearth on the KyanOS desktop — Clarity cockpit + `llama.cpp` FFI chat + HTTP to an existing ComfyUI — proves the whole spine. (2) Generalize the pipelines (branding → config) and port the non-GPU parts. (3) Chase the OS-native endgame: `llama.cpp` built for KyanOS → CPU chat inside the OS, with image/3D hosted until the GPU stack exists.

**Ties to the language track.** The Clarity→C native compiler (see [GAPS.md](GAPS.md)) is the enabler for any pure-Clarity inference experiment — as it grows SIMD intrinsics / a BLAS FFI, a Clarity-native inference path gets progressively less absurd. A fun north-star, not a dependency.

---

## The long goal — Apple hardware, and PC games

The stated ambition is a Mac-quality desktop that runs well on Apple hardware
while still being able to play PC games. Those two halves pull in opposite
directions, and it is worth writing down why.

**Apple hardware means AArch64.** Apple Silicon is ARM64, so it needs the
aarch64 kernel (now booting at EL1 under QEMU) taken all the way: MMU, timers,
interrupts, then Apple-specific bring-up — the M-series boot protocol, device
tree, AIC interrupt controller, and Apple's own display/USB/NVMe blocks, none
of which are PC-standard. Running under virtualization on Apple hardware
(Virtualization.framework) is a far shorter path to "runs on a Mac" and is
worth doing first: it exercises the same aarch64 kernel without needing a
single Apple hardware driver.

**PC games mean x86 plus a Windows compatibility layer plus a GPU.** A native
PC game needs, at minimum: an x86_64 userspace, a Win32/DirectX translation
layer of Wine/Proton scale, a real GPU driver, and a graphics API
(Vulkan/Metal). Each of those is a multi-year project in its own right, and
the GPU driver is the single largest deferral in this document. On Apple
Silicon it additionally needs x86→ARM binary translation, i.e. a Rosetta-class
translator.

**Honest sequencing.** Nothing here starts before the userspace runtime
exists — an OS that cannot run its own init cannot run a game. The realistic
order is: userspace → desktop running on the kernel → GPU/graphics stack →
virtualized-on-Mac → Apple-native aarch64 → any game-compatibility work. The
gaming ambition is best treated as a direction, not a milestone, until the
graphics stack is real.

---

## Out of scope

Decisions that should stay decisions.

- **A second window-system protocol.** Wayland/X11 compatibility shims are not on the path. KyanOS apps target the Clarity compositor protocol; cross-OS apps run in QEMU.
- **POSIX userspace shim.** `bash`, `coreutils`, and the BSD utilities are not coming. The Clarity shell + the eleven default apps are the userspace.
- **A separate kernel language.** The kernel stays in Zig. Self-hosting the kernel in Clarity is not a 1.x goal.

---

## How to contribute

1. The single highest-value task is the **`clarity os` developer workflow** above. It unblocks everything else.
2. After that, anything in **Hardware & drivers** or **Networking** is high-impact and well-scoped.
3. UI toolkit work is good for surface-area familiarity; pick one widget or animation and ship it end-to-end with a test.
4. `clarity test stdlib/` runs all 120+ OS tests. Add a test for any change that isn't trivially visible.
5. Open an issue tagged `os` describing the approach before you start.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the developer workflow.
