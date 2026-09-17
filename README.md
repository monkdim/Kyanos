# Clarity & KyanOS

**Simple code. Real power.**

A modern programming language, and an operating system being written in it. One syntax, one toolchain, one design vocabulary, from the REPL on up. The language builds and runs today from a source checkout; the OS has two kernels that boot and run programs under QEMU, and a desktop that runs hosted and in the browser but not yet on those kernels.

![KyanOS boot splash, Obsidian, the Kyan identity](https://raw.githubusercontent.com/monkdim/Kyanos/main/website/screenshots/kyan_splash.png)

<sub>Rendered by Clarity's own software framebuffer: the faceted-K monogram, the signature violet-to-cyan progress bar, dark glass.</sub>

---

## Two projects, one story

### Clarity, the language

Clarity is what Python wishes it could be. It reads like English, runs like JavaScript, and ships as a single self-contained binary you can drop on any machine.

- **Readable by default.** Immutable variables, pattern matching, `|>` pipes that make data flow visible at a glance, `show "Hello {name}"` interpolation, `--` line comments. No semicolons, no type-juggling ceremony, no clever-but-cryptic operators.
- **Powerful where it counts.** Classes with inheritance and interfaces, async / await, generators, decorators, comprehensions, destructuring, null coalescing, optional chaining, pattern matching.
- **Self-hosted.** The lexer, parser, interpreter, bytecode VM, type checker, linter, formatter, debugger, profiler, doc generator, package manager, language server, transpiler and shell are all written in Clarity. **66 test files, more than 4,000 assertions, all in Clarity**, run in CI on macOS ARM64, Linux x64 and Linux ARM64. The self-hosted compiler rebuilds the toolchain alone: CI bundles it with the Python bootstrap, rebuilds it with the result, rebuilds it again with that, and checks the third build matches the second.
- **Compiles to native.** `clarity cc program.clarity` compiles Clarity to C and then to a real native binary with no Bun and no VM. It covers the scalar core, collections, classes, closures, a GC, strings, files, processes, math, JSON, bytes and bitwise operations, native FFI, live-process memory, hooking, a binary-format DSL and disassembly through libcapstone. It resolves imports natively too: the program and everything it imports are flattened into one translation unit, so `from "bytes.clarity" import hexdump` compiles.
- **Ships as a single binary.** Clarity transpiles to JavaScript and Bun compiles the bundle to a native executable for macOS and Linux, x64 and ARM64, and for Windows x64. The binary carries the standard library as source, so a program can import it from any directory. Nothing else is needed on the target machine.
- **Batteries included.** `clarity debug`, `clarity profile`, `clarity fmt`, `clarity lint`, `clarity test`, `clarity doc`, `clarity lsp`, `clarity cc`, `clarity install <pkg>`.

### KyanOS, the operating system

KyanOS is an experimental desktop operating system built around Clarity. Two Zig kernels, x86_64 and aarch64, handle paging, scheduling and system calls; a Clarity program compiled with `clarity cc --freestanding` runs on both with byte-identical output. Above the syscall boundary the desktop (compositor, window manager, dock, launcher, settings, the apps) is written in Clarity and runs today in two places: hosted in a window through `clarity desktop` (needs SDL2), and in the browser. It does not yet run on the kernels; on the kernels, `init` is Zig and one Clarity program runs.

- **What the boot gate proves, on every commit.** x86_64: multiboot2 into long mode, higher half, GDT, IDT, FPU, page allocator, four-level page tables, a slab heap, preemptive scheduling with FPU state across switches, a VFS over tmpfs, two processes loaded from ELFs in the filesystem (`/bin/clarity-init` in Zig and `/bin/clarity-demo` in Clarity), `brk`, SSE in userspace, `sysret`, and user pointers translated through the process's own tables (an unmapped buffer, a kernel address and the program's own text as a read target are each refused with EFAULT), with SMEP and SMAP enforced on a fourth boot. aarch64: device tree, higher half on TTBR1 with the identity map dropped and checked through the MMU, per-process address spaces, a GICv2 timer, preemption, ELF loading, a ramfb console whose pixels CI reads back out of a screenshot, a virtio keyboard on its own interrupt, a serial line you can type into, tmpfs, six system calls, and a shell. The gate types at the keyboard, types down the serial line with no keyboard attached, and checks every character cell on the screen.
- **Booted on Apple hardware.** The aarch64 kernel has been run on an Apple M5 under QEMU and driven by hand through the shell. It is emulated: `-accel hvf` refuses the kernel's GICv2, so native speed on Apple Silicon waits on a GICv3 driver. Transcript in [kernel/RUNNING.md](kernel/RUNNING.md).
- **Obsidian & neon, one identity, two modes.** Dark volcanic glass lit by a single signature: violet melting into cyan. **Obsidian** (dark, the default) and **Quartz** (light) are the same identity in two moods, switchable live in **Settings, Appearance**, with a user-tunable accent hue. The faceted-K monogram is cut like a gem with one edge lit by the signature.
- **Designed like macOS, accessible like Windows.** Hairline depth instead of heavy shadows. 12 px window radii, 8 px controls. A grotesk and mono type pairing. Abstract app-icon marks (a wave for the terminal, a stack for files, a prism for the game hub) that read at any size. The signature gradient appears only where it means something: the logo edge, boot progress, focus rings, selection.
- **One language, top to bottom.** An app for KyanOS is Clarity. The kernel's syscall table is defined in Clarity. A theme is a Clarity dict. The ISO packer is a Clarity module.

---

## Why this matters

Most operating systems are written in languages designed in the seventies, glued together with build systems designed in the eighties, decorated with UI frameworks designed in the nineties, distributed through package managers designed in the two-thousands. Each layer hides the layer below behind a wrapper. Reading the source is an archaeology project.

KyanOS is the opposite bet. **One language. One toolchain. One palette. One radius scale. One typography ramp. One way to ship code.** The boot splash, the kernel syscall stub, the file-manager sidebar, the website's CSS, the package registry's HTTP handler: the same syntax, the same conventions, the same `clarity test` away from green.

That is the bet: **a programming language good enough to write its own operating system in, and an operating system simple enough that you would actually want to.** The language is there today; the OS is the road still being walked.

---

## At a glance

| | Clarity | KyanOS |
|---|---|---|
| **Status** | v1.0.1. Binaries for macOS (ARM64, x64), Linux (x64, ARM64) and Windows (x64) are attached to the release, built by CI and smoke-tested on macOS ARM64, Linux x64 and Linux ARM64; `install.sh` and the Homebrew formula install them. | Experimental. Two kernels boot and run programs under QEMU on every commit. The desktop runs hosted and in the browser; boot-to-desktop on the kernels is not yet built. |
| **Lines of code** | 72,505 lines of Clarity in `stdlib/` (55,209 outside tests), plus a 2,136-line Python bootstrap transpiler | about 14,200 lines of Zig and assembly across two architectures |
| **Tests** | 66 test files, more than 4,000 assertions, `clarity test stdlib/` on three targets | 17 boot markers on x86_64 (three boots, plus one with SMEP and SMAP enforced), 32 on aarch64 (three machine sizes), plus screenshot, keyboard and serial checks |
| **Boot time** | | 24 s to the end of an untouched aarch64 boot under TCG on a workstation; targets are goals, not measurements |
| **Dependencies on the target machine** | none for the toolchain binary | Zig 0.13 and QEMU for the developer workflow |

Every module and kernel file, with who imports it and which bundler ships it, is listed in [REPO_INDEX.md](REPO_INDEX.md), generated by `tools/repo_index.py`.

---

## Try Clarity

One line on macOS or Linux, x64 or ARM64:

```bash
curl -fsSL https://raw.githubusercontent.com/monkdim/Kyanos/main/install.sh | bash
```

Or with Homebrew, from the formula in this repository:

```bash
brew tap monkdim/clarity https://github.com/monkdim/Kyanos
brew install monkdim/clarity/clarity
```

Or download a binary from the [latest release](https://github.com/monkdim/Kyanos/releases/latest). Then `clarity version` prints the version, `clarity smoke` runs 38 checks against the installed binary from any directory, and `clarity run hello.clarity` runs a program.

To build from source instead, you need [Bun](https://bun.sh) and Python 3 for the bootstrap.

```bash
git clone https://github.com/monkdim/Kyanos.git
cd Clarity
python3 native/transpile.py --bundle
(cd native/dist && bun build --compile clarity-entry.js --outfile clarity)
./native/dist/clarity run examples/hello.clarity
```

From here, `clarity shell` drops you into the interactive shell, `clarity help` lists every command, and `examples/` has seventeen programs covering classes, async, patterns, file I/O, FFI and the reverse-engineering toolkit. Run the suite with `./native/dist/clarity test stdlib/`.


## Try KyanOS (experimental)

> **Heads up:** KyanOS is experimental. What boots is a kernel with a shell, not a desktop.

You need Zig 0.13 exactly, and QEMU. On a Mac use the native Homebrew (`/opt/homebrew`); an Intel Homebrew under Rosetta builds an x86-64 QEMU that cannot use hardware acceleration.

```bash
brew install qemu            # macOS; on Linux: apt install qemu-system-arm
clarity os build             # the kernel and its boot image for this machine's architecture
clarity os run               # boots it under QEMU with the serial console in this terminal
```

`clarity os build` runs `zig build` in `kernel/` and writes `dist/claritos-aarch64.img` on an ARM machine or `dist/claritos.iso` (a GRUB rescue ISO, needs `grub-mkrescue` and `xorriso`) on x86_64; `--arch` picks the other one. `clarity os run --window` adds the framebuffer and keyboard, and `clarity os run --boot-test` boots headlessly and checks the same serial marker CI asserts. The commands underneath are these:

```bash
cd kernel && zig build aarch64

qemu-system-aarch64 \
  -M virt,gic-version=2 -cpu cortex-a72 -m 512 \
  -kernel zig-out/bin/clarity-kernel-aarch64.img \
  -display none -serial stdio
```

The boot log prints in your terminal and what you type there goes back in. When it says `clarity-sh: type help`, type `help`. Ctrl-A then X quits. Add `-device ramfb -device virtio-keyboard-device -display default` to see the framebuffer console instead. The x86_64 kernel builds with `zig build` and boots from a GRUB ISO; `kernel/RUNNING.md` has that command and the reasons behind every flag.

To see the desktop today, run it hosted (`clarity desktop`, needs SDL2) or open the browser build at [monkdim.github.io/Kyanos/os/](https://monkdim.github.io/Kyanos/os/).

---

## What KyanOS looks like

> Renders from the Clarity compositor, produced by `clarity run` against the theme, branding and compositor modules in `stdlib/`.

The desktop, the Obsidian identity composed live: an aurora wallpaper, Compositor windows with Kyan glass chrome (the focused window carries the signature violet-to-cyan rail), soft drop shadows, and the floating glass dock with the Prism game hub pinned first:

![KyanOS desktop, Obsidian](https://raw.githubusercontent.com/monkdim/Kyanos/main/website/screenshots/kyan_desktop.png)

**Voidrunner**, a playable game built in Clarity, launched from Prism. Dodge the neon debris (arrow keys to move, R to restart); it runs in the composed desktop, hosted or in the browser:

![KyanOS, Voidrunner](https://raw.githubusercontent.com/monkdim/Kyanos/main/website/screenshots/kyan_voidrunner.png)

Boot splash: the faceted-K monogram on void black, the KyanOS wordmark ("Kyan" in ink, "OS" in signature cyan), and a full-width violet-to-cyan progress bar:

![KyanOS boot splash, Obsidian](https://raw.githubusercontent.com/monkdim/Kyanos/main/website/screenshots/kyan_splash.png)

Marketing lockup: the gem-cut monogram with its signature-lit edge, and the wordmark:

![KyanOS lockup](https://raw.githubusercontent.com/monkdim/Kyanos/main/website/screenshots/kyan_lockup.png)

---

## What's inside

Clarity ships a self-hosted lexer, parser, AST, tree-walking interpreter, stack-based bytecode VM (64 opcodes), CLI dispatcher, REPL, shell, formatter, linter, type checker, debugger, profiler, doc generator, package manager and TOML parser, package registry server, language server (JSON-RPC 2.0), Clarity-to-JavaScript transpiler, Clarity-to-C native compiler, build pipeline and installer. Everything in `stdlib/`. Everything readable.

The KyanOS codebase adds two Zig kernels (x86_64: multiboot2, paging, scheduler, syscalls, fork/exec/wait/kill, timer, multiboot framebuffer; aarch64: device tree, TTBR1 higher half, GICv2, ramfb, virtio-input, PL011), a small C library for freestanding Clarity programs, and, in Clarity, a compositor, a window manager, a dock, a launcher, a settings panel, a notification centre, the theme protocol with the Kyan identity, procedural wallpapers, the faceted-K branding kit, a boot splash, a perf profiler, crash recovery, a pure-Clarity ISO9660 packer, a QEMU launcher, an installer, a website generator, a release pipeline, and eleven apps (terminal, files, editor, calc, viewer, monitor, browser, mail, chat, store, settings). The Clarity userspace runs hosted and in the browser; wiring it onto the kernels is the work that remains.

For the full file-by-file structure, see [REPO_INDEX.md](REPO_INDEX.md) and the **Project structure** section of [GETTING_STARTED.md](GETTING_STARTED.md).

---

## Roadmap, audits & history

- **Clarity**: [GAPS.md](GAPS.md) for the language's path forward, [ROADMAP.md](ROADMAP.md) for the strategy.
- **Reverse engineering & game mods**: [RE_TOOLING.md](RE_TOOLING.md) for the native RE toolkit (signature scanning, live-memory read and write, function hooking, disassembly via Capstone, a binary-format DSL), all compiling to standalone binaries.
- **KyanOS**: [ROADMAP_OS.md](ROADMAP_OS.md) for what runs, what does not, and what is next.
- **Audits**: [audits/2026-09-claritycode.html](audits/2026-09-claritycode.html) and [audits/2026-09-kyanos.html](audits/2026-09-kyanos.html), September 2026, each with a verified floor, gaps by tier, dead code and an ordered work list. [AUDIT.md](AUDIT.md) is the July audit they supersede.

The language is at v1.0 and runs from source today; KyanOS is an active, experimental work in progress. Issues, PRs, and theme contributions are welcome.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: write Clarity. Add a test. Run `clarity test stdlib/`. Open a PR. The toolchain is the dogfood; every contribution improves the language and the OS.

---

## License

GPL-3.0, see [LICENSE](LICENSE) for details.

---

<sub>Clarity is a self-hosted programming language. KyanOS is the operating system being written in it. Together, they are a bet that the simplest tools win, even at the level of an entire computer.</sub>
