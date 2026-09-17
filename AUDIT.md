# Clarity & ClarityOS — Full Audit (July 2026)

> Superseded by the September 2026 audits: [audits/2026-09-claritycode.html](audits/2026-09-claritycode.html) and [audits/2026-09-kyanos.html](audits/2026-09-kyanos.html). Kept as the record of what was found and fixed between the two.

This is a complete, adversarial audit of the repository: language toolchain, OS userspace, kernel and boot path, distribution, docs, and CI. It was produced by bootstrapping the toolchain from a fresh clone, running the entire test suite, and then deep-reading every subsystem looking specifically for things that are broken, simulated, drifted, or dead.

**How to read this:** the point is not that the project is bad — the architecture is coherent, the test discipline is real, and several subsystems (rendering, parsing, the widget toolkit, the protocol state machines) are genuinely well built. The point is to know *exactly* where the floor is real and where it's painted, so the roadmap in [REBRAND.md](REBRAND.md) stands on facts.

Severity legend: **broken** (does not work as shipped) · **misleading** (docs/claims contradict code) · **simulated** (works only against test stubs) · **messy** (duplication, dead code) · **minor**.

---

## What checks out (verified green)

- **Bootstrap → transpile → test from a clean clone works.** `python3 native/transpile.py --bundle` produces a working bundle; `clarity test stdlib/` passes **39/39 test files, 0 failures** on linux-x64.
- **Branches are clean.** `main` == `origin/main`; no divergence, no unmerged work stranded on other branches.
- **CI is real** for what it covers: 3-target matrix (darwin-arm64, linux-x64, linux-arm64), transpile → compile → full test suite → smoke, on every PR.
- **All 8 examples parse** against the bootstrap parser; the README quickstart language claims hold.
- **The rendering core is real.** `graphics.clarity` is a genuine 32-bit BGRA software framebuffer with FFI-backed fills; `draw.clarity` has real Bresenham/midpoint/rounded-rect rasterizers; `font.clarity` really renders an embedded 8×8 bitmap font pixel-by-pixel and loads PSF v1. The compositor/window/WM stack does real per-window framebuffers, dirty rects, z-order, hit testing, drag/resize/snap/Alt-Tab.
- **The playground is deployed** (GitHub Pages) and works; the VS Code extension is a substantial real implementation (LSP client, commands, diagnostics), not a skeleton.

## The central finding

**The test suite is green because it tests simulations.** Almost every module is individually well-built and well-tested, but the layer *boundaries* — init↔services, display↔compositor, session↔windows, apps↔network, userspace↔kernel — are bridged only by test stubs. No non-test code path composes a desktop, delivers an input event end-to-end, or crosses the syscall boundary. The kernel-side mirrors (`vfs`, `scheduler`, `process_model`, `procfs`) describe themselves as pure-state simulations and are imported only by tests. Green CI currently proves the *design contract*, not the *system*.

Everything below is the itemized evidence.

---

## 1. Distribution & release — broken end-to-end

The single most urgent area: **no one can install Clarity today.**

| # | Finding | Severity |
|---|---|---|
| 1.1 | The latest GitHub release (tag `V1.0.0`, capital V) contains **zero binary assets** — only auto-generated source archives. Every download URL in `install.sh:51-69` 404s. The `curl \| bash` one-liner advertised in `README.md:66`, `docs/index.html:199`, and `docs/tutorial.html:87` fails for everyone. | broken |
| 1.2 | `Formula/clarity.rb` has four `sha256 "PLACEHOLDER"` values (lines 10, 13, 20, 23) and builds URLs with `v#{version}` (lowercase) against the real capital-`V` tag — a case-sensitive 404 even if assets existed. `brew install` cannot work. | broken |
| 1.3 | `registry/Dockerfile` bootstraps by downloading a release asset with **no fallback** → `docker build` always fails → `deploy-registry.yml` is guaranteed red whenever it triggers. | broken |
| 1.4 | CI's "bootstrap from latest release" step (`ci.yml:31-49`, `build.yml:63-82`) fails on every run for the same reason and silently always uses the Python fallback — the self-hosted bootstrap path is never actually exercised in CI. | misleading |
| 1.5 | `build.yml:47-52`: the Windows job's bootstrap downloads `clarity-windows-x64.tar.gz` but Windows is packaged as `.zip` (line 97) — Windows bootstrap can never succeed. | minor |
| 1.6 | `releases/` contains **126 MB of committed Mach-O binaries** (`clarity-macos-*`, `Clarity.app`) that nothing references and whose names don't even match the workflow's `clarity-darwin-*` convention. Dead weight in every clone. | messy |
| 1.7 | `build.yml:5-7` triggers on both `v*` and `V*` — which is how the miscased tag got a release in the first place. | minor |

**Fix order:** publish a correctly-cased `v1.0.0` (or `v1.0.1`) release **with assets attached** — that single action unbreaks install.sh, CI bootstrap, the registry Docker build, and the Formula URLs. Then fill the Formula sha256s and delete `releases/`.

## 2. Language toolchain — four headline commands don't survive first contact

All verified empirically against the committed dist build.

| # | Finding | Severity |
|---|---|---|
| 2.1 | **The REPL never executes code.** `repl.clarity:475-493` tokenizes and parses, then prints `[parsed: N statement(s)]` — the interpreter is never invoked. `let x = 5` does nothing. Both `clarity repl` and `clarity shell` route to this same function (`cli.clarity:358-364`) while help text sells them as different things. | broken |
| 2.2 | **`clarity fmt` destroys files.** (a) Comments are dropped — the lexer discards them and the formatter is AST-only; verified 17 comment lines deleted from `lexer.clarity`. (b) String escapes aren't re-escaped (`formatter.clarity:333` handles only `\\` and `\"`), so `"\n"` is emitted as a literal newline — formatted output fails `clarity check` with "Unterminated string". `fmt --write` on the stdlib would be catastrophic. | broken |
| 2.3 | **`clarity profile` and `clarity debug` are broken on every program**: `profiler.clarity:74,83` and `debugger.clarity:141,178,335,356` call `Interpreter.execute_stmt()`, a method that doesn't exist (it's `execute`, `interpreter.clarity:455`). Verified: trivial program → `Runtime error: {}`. | broken |
| 2.4 | **The self-hosted transpiler never emits `export`** (zero occurrences in `transpile.clarity`) while the Python bootstrap exports every top-level decl. Modules transpiled by `clarity transpile` fail at import time; `clarity transpile --bundle` cannot rebuild the toolchain — **only Python can**. This contradicts the "No Python dependency" header (`cli.clarity:2`) and the self-hosting claim. The committed JS is hand-maintained in practice despite "AUTO-GENERATED — do not edit" headers. | broken |
| 2.5 | **`--fast` (bytecode VM) fails on any program with imports** — `compile_ImportStatement` is a no-op expecting pre-resolution that `run_file_fast` never does (`bytecode.clarity:655-659`, `cli.clarity:162-183`). Verified. Also VM `try/catch` cannot catch engine-raised errors (division by zero, undefined variable) — only explicit `throw` — and even those escape enclosing handlers when raised inside called functions (`bytecode.clarity:1788-1803`). `await`/`yield` compile to plain expressions. | broken |
| 2.6 | **`gen-runtime` drift is worse than GAPS.md says**: 853 diff lines (verified byte-exact against a 1:1 port of the generator), not ~440 — and regenerating would silently **revert three behavioral fixes** present only in `native/runtime.js`: the `_clarityType` branch of `type()` (which `cli.clarity:292` depends on), FFI string/BigInt marshalling, and the `_ffi_read_view` GC-staleness workaround. | broken |
| 2.7 | `clarity lsp` and `clarity bench` only work when cwd == `stdlib/` (cwd-relative probe at `cli.clarity:777,996`). | broken |
| 2.8 | `for k in some_map` silently yields `null`s in **both** engines (integer-index iteration over dicts, `interpreter.clarity:680-685`, `bytecode.clarity:1112-1127`). No error, just wrong values. | broken |
| 2.9 | Latent: `repl.clarity:59,74` call a global `slice()` that exists nowhere in the runtime — fires once `~/.clarity_history` exceeds 1000 lines. REPL `.cd` runs `cd` in a subshell and changes nothing. `ask()` hard-requires `/dev/tty`, so no prompting tool can be scripted. | broken/minor |
| 2.10 | Silent degradation: transpiler/formatter fall back to emitting `/* TODO: nt */` comments into *output* for unknown AST nodes instead of erroring (`transpile.clarity:165,457`, `formatter.clarity:87`). `OP_MAKE_FN` recovers params via a "looks like a list of strings" heuristic while the compiler computes and discards the real index (`bytecode.clarity:1556-1573` vs `379,897`). | messy |

**What still works well:** `run`, `check`/`--types`, `tokens`, `ast`, `lint` (real 7-rule linter), `doc`, `test`, single-file `transpile`, `smoke` — the everyday loop is solid.

## 3. OS userspace — real islands, no boot-to-desktop bridge

| # | Finding | Severity |
|---|---|---|
| 3.1 | **No non-test code constructs a desktop.** The kernel spawns `/bin/clarity-init` → the QuickJS bundle → whose entry runs `cli.clarity` — the developer CLI, not a desktop session. Nothing wires InitApp → DisplayServer → DesktopSession → apps. | broken |
| 3.2 | **DesktopSession and the Compositor speak incompatible window models.** `desktop_session.clarity:220-236` makes plain dicts (no framebuffer, no `focus()`); a real compositor throws `'null' is not callable` on launch, and `boot()`+`tick()` paints *only the wallpaper* (blit loop runs zero iterations). It works exclusively against `StubCompositor` in tests. | broken |
| 3.3 | **Input can't reach the WM through the DisplayServer**: it calls `this.wm.on_mouse(event)` but WindowManager only has `handle_mouse`, with incompatible event shapes — and the TypeError is swallowed by `try/catch` (`display_server.clarity:125` vs `window_manager.clarity:58`). Also expects `bus.drain()` which InputBus doesn't have. | broken |
| 3.4 | **Pixels can never reach hardware**: DisplayServer stores the `screen` framebuffer param but never writes to it; `framebuffer_from_mmap` throws "not implemented yet" (`display_server.clarity:31,50-65,211-217`) even though the kernel ioctl exists. | broken |
| 3.5 | `init_app.clarity:22-35` spawns `/bin/clarity-compositor`, `/bin/clarity-wm`, `/bin/clarity-shell`, `/bin/clarity-launcher` — binaries that `os_build.clarity` never builds or installs. The init→compositor "connection" is a string. | broken |
| 3.6 | The `claritos` syscall backend throws "not yet wired" (`syscall.clarity:83`); the host backend shells out to `stat`/`ls`/`curl`/`nc` subprocesses. There is no socket API anywhere; networking = `exec_full("curl …")` (`net.clarity:36,153-163`) — host-only, impossible on bare metal. | simulated |
| 3.7 | Mail, chat, websocket, IMAP/SMTP are correct protocol state machines with **no transport implementation except test fakes** — mail and chat cannot connect to anything. Terminal is a real VT100 grid emulator with no PTY (test-fed bytes only). Files/monitor/docs apps shell out to `ls`/`cp`/`/proc` — real on a Linux host, nonexistent on ClarityOS. | simulated |
| 3.8 | `scheduler`, `process_model`, `vfs`, `procfs` are self-described pure-state simulations of the Zig kernel, imported only by tests. `ipc.clarity` is in-process only. | simulated |
| 3.9 | The README hero "screenshot" (`meadow_desktop.png`, 1280×800) has **no in-repo rendering path** — nothing in the codebase can currently paint a full desktop, and no code references that resolution. | misleading |
| 3.10 | Duplication: two window models (Window class vs session dicts); two init systems each with its own topo-sort; three wallpaper modules; `boot_splash` vs `boot_splash_modern` and `branding` vs `branding_modern` (old ones effectively dead); `chrome.clarity` (window decorations!) imported only by tests — chrome is never drawn in any composed desktop. Meadow's theme is missing the `"font"` key and silently falls back to the 8×8 builtin. | messy |
| 3.11 | Renderer gaps that gate any visual redesign: **no alpha blending anywhere** (fills/blits overwrite — no translucency, shadows, or AA corners; theme `shadow_alpha` tokens are fiction), no gradient primitive (only slow per-pixel wallpaper loops), one font at one size (8×8, `measure_text` = `len*8`), no PNG/JPEG, `blit()` is a per-pixel interpreted double loop with no FFI fast path, and the animation/easing library is consumed only by splash screens. | broken (for the redesign) |

## 4. Kernel & boot path — pre-"hello world"

The honest summary: every layer exists as a well-commented skeleton that agrees on ABI on paper, but **nothing on the boot path has ever been compiled, linked, or booted**, and each layer has at least one independently fatal break. CI never compiles any of it (no zig/QEMU anywhere in the workflows), which is how these survive in-tree.

| # | Finding | Severity |
|---|---|---|
| 4.1 | **The kernel cannot link**: everything is linked at the higher-half VMA (0xFFFFFFFF80000000) but the 32-bit boot stub uses 32-bit moves/jumps on higher-half symbols → R_X86_64_32 relocation truncation (`boot/start.S:49,95-96`, `boot/linker.ld:19`). No low-VMA `.boot` section exists; the stub identity-maps 1 GiB (comment says 4) and never maps the higher half. | broken |
| 4.2 | **The kernel cannot compile**: `std.heap.page_allocator` on a freestanding target (`sched/scheduler.zig:163,317`, `loader/load.zig:92`, `drivers/framebuffer.zig:80`, `native_vm/gc.zig:23`) and `@intFromEnum` on an untyped enum literal (`scheduler.zig:202,307`) are compile errors — contradicting `kernel/README.md:96-97` "the structure compiles standalone". | broken |
| 4.3 | If it booted anyway: `idt.zig:25` does `lidt; sti` with an all-zero IDT and fully unmasked PIC → the PIT fires into a null gate within ~55 ms → **triple fault**. `timer.init()` is never called from `main.zig`. | broken |
| 4.4 | **Syscalls are never wired**: `dispatch.init()` is an empty TODO; the real MSR programming in `arch/x86_64/syscall.zig:36` is dead code nothing imports; the trampoline clobbers arg a0 and mis-passes the 7th argument. | broken |
| 4.5 | **The scheduler never context-switches**: `arch_switch_to` is commented out (`sched/scheduler.zig:220`); `run()` is a `hlt` loop; `context.switch_to`/`enter_userland` are never invoked. `fork()` copies zero pages and gives the child no iret frame. A user process would get an empty page table (`loader/load.zig:100-114` relies on a `vmm.kernel_pml4_template()` that doesn't exist). | broken |
| 4.6 | IRQ handlers are plain functions installed directly into IDT gates — no register save, `ret` instead of `iretq`, no EOI from kbd/mouse. No TSS exists (ring3→ring0 interrupts impossible) and the STAR/sysret selector layout is wrong for the GDT order. | broken |
| 4.7 | `main.zig:37` takes `*const BootInfo` (Zig struct with slices) but start.S passes the raw multiboot2 blob; `ParsedBootInfo.parse` is never called anywhere — `pmm.init` would read garbage. The multiboot2 header requests no framebuffer tag, so a graphical mode would never be granted. | broken |
| 4.8 | **The ISO is not bootable by anything**: `os_build.clarity:93` sets the raw kernel ELF as the El Torito no-emulation boot image — BIOS would execute ELF header bytes in real mode. Multiboot2 requires GRUB *in* the image; none is staged. The generated `grub.cfg` is decoration. Meanwhile `clarity os run` on Linux auto-enables OVMF/UEFI (`qemu.clarity:45`) against an ISO with **no** EFI entry → UEFI shell. The packer and the launcher don't meet in the middle anywhere. (`mkiso.clarity`'s `grub-mkrescue` branch could produce a bootable ISO but is unreachable from the CLI.) | broken |
| 4.9 | **`clarity os build` fails deterministically on every machine**: QuickJS is not vendored (`runtime/freestanding/third_party/` has only a fetch script, which pins quickjs-ng 0.5.0 with a file list that doesn't match ng releases), `build.zig` silently skips the runtime when absent, and the CLI then dies at "expected runtime artifact missing". Even after fetching: compiling `quickjs.c` with `-ffreestanding` and a ~25-symbol libc shim (no stdio/math/setjmp) is not plausible as designed; the bundle embed has a symbol-name mismatch (`clarity_bundle_js` vs `clarity_bundle_js_data`) and an `@embedFile` path that escapes the module root (both fatal at link/compile). **The freestanding QuickJS strategy is likely a dead end and needs a rethink** — which strengthens the case for the native Clarity VM. | broken |
| 4.10 | `native_vm/`: README says ~10 of 58 opcodes; actually ~19 handled of 57 defined — but moot, since `load_bundle` is `error.NotImplemented` and the bundle symbol is never provided, so the VM always exits 2. | misleading |
| 4.11 | `run_vm.clarity:5-7` claims CI pipelines call it with `--headless --boot-test` — no such pipeline exists. `procfs.zig`, `devfs.zig`, `tty.zig` are dead code never imported by `main.zig`. `iso9660.clarity` nits: `..` points at self, El Torito sector count overflows u16 for any real kernel, and the byte-list builder is O(n·256) per char — a multi-MB ISO would take a very long time. | misleading/messy |

## 5. Docs — contradictions and time capsules

| # | Finding | Severity |
|---|---|---|
| 5.1 | **`ROADMAP_OS.md:9-14` claims "ClarityOS 1.0 has shipped… boots on bare metal… boot to desktop under five seconds… performance gate green"** — directly contradicting `README.md:31,49-55,78` (all labeled goals/unverified) and the code reality in §3–4. `GETTING_STARTED.md:50` also states "It runs on bare metal" as fact. Worst-in-class credibility risk. | misleading |
| 5.2 | **`BEGINNERS_GUIDE.md` is from a different era**: installs via `pip install clarity-lang`, requires Python 3.8, targets v0.4.0 (line 1670), lists three examples that don't exist. Cannot work. | broken/stale |
| 5.3 | `website/serve.clarity` is hand-written 0.4.0-era content (`pip install`, "self_hosting: in progress") — *not* the output of `website_gen.clarity` — and isn't deployed. Two websites, both wrong. | stale |
| 5.4 | Numbers disagree everywhere: tests "~430" (README) vs "550+" (GETTING_STARTED) vs "120+ OS tests" (ROADMAP_OS); opcodes "48" (README, GETTING_STARTED, website) vs 58 actual; kernel "~2K skeleton" (kernel README) vs "~4,500-line" (README) vs 3,684 actual. | stale |
| 5.5 | `GETTING_STARTED.md:23-31` "Pre-built binary (recommended)" is circular — it tells you to run `clarity build --install`, which requires clarity to be installed, and never mentions install.sh. `CONTRIBUTING.md:8` points to Releases, which has no binaries. | misleading |
| 5.6 | The unregistered `clarityos.dev` domain is baked into `website_gen.clarity` and asserted in `test_polish.clarity:229` (already tracked in GAPS.md — still open). | minor |
| 5.7 | VS Code extension packaging is broken: `vscode-languageclient` in devDependencies but imported at runtime; icon files referenced that don't exist; calls `clarity fmt --stdout`, a flag the CLI doesn't support. | broken |
| 5.8 | The playground contains a **second, from-scratch JS implementation** of a Clarity interpreter that can silently drift from the real language. | messy |

---

## Priority ladder (recommended fix order)

1. **P0 — Unbreak distribution.** Publish a correctly-cased release *with binaries*; fix Formula/registry/Windows-bootstrap; delete the 126 MB `releases/` directory.
2. **P0 — Tell one story in the docs.** Reconcile ROADMAP_OS/GETTING_STARTED to the README's honest framing; retire or rewrite BEGINNERS_GUIDE and `website/serve.clarity`; fix the stale numbers.
3. **P1 — Restore the toolchain's headline features.** REPL execution, fmt (comments + escapes), profile/debug (`execute_stmt` → `execute`), map iteration, `--fast` imports + try/catch, cwd-independent lsp/bench.
4. **P1 — Close the self-hosting gap for real.** `export` emission in the self-hosted transpiler (so `clarity transpile --bundle` can rebuild the toolchain without Python) and reconcile `runtime_spec` ↔ `runtime.js` so `gen-runtime` is safe to run. *(Both done: the self-hosted bundler rebuilds the toolchain, and the reconciliation went the other way — the spec was a stale copy of the runtime, so the generator was retired and `runtime.js` is the source of truth.)*
5. **P2 — Compose the desktop.** One window model, one init path, DisplayServer→WM input wiring, screen blit-out. Target: a `clarity desktop` command that runs the full session *hosted* on macOS/Linux/Windows (SDL/minifb-style window via FFI). This makes the OS demoable on every Mac and PC **today** and is the foundation of the VM-first distribution track.
6. **P2 — Renderer upgrades for the new design system** (alpha blending, gradient primitive with FFI fast path, multi-size font, AA) — prerequisites for the KyanOS identity; see [REBRAND.md](REBRAND.md).
7. **P3 — The real boot track.** Make the kernel compile in CI (zig build as a required check), fix link/IDT/TSS/context-switch, wire SYSCALL, stage GRUB via `mkiso`'s grub-mkrescue path, and land the headless `--boot-test` smoke in CI. Replace the freestanding-QuickJS bet with the **native Clarity VM** as the userspace runtime strategy.
8. **P3+ — Self-hosting endgame.** Finish the native VM opcode set against the real bytecode suite, then take on native compilation (Clarity → C/LLVM) as the v2.0 flex.

The test suite stays the crown jewel throughout: every fix above should convert one simulated boundary into a real one *without* losing the simulation tests — they become the contract tests for the real implementations.
