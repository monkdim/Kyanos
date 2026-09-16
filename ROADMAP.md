# Clarity — Competitive Roadmap

> **North star:** make Clarity a language you can build *and ship* real applications in —
> compiled to standalone native binaries with **no runtime**, no Bun, no VM — with a
> deliberate specialty in **app building** and **gaming (RE tooling and game mods)**.

This is the strategic map. The tactical, near-term gap list lives in [GAPS.md](GAPS.md);
KyanOS-specific work lives in [ROADMAP_OS.md](ROADMAP_OS.md). This file is the "why" and the
"where next" across the whole language — read it top-down, pick a track, then find the concrete
task in GAPS.md.

Where a language wins today is rarely raw syntax — it's the *distance from `hello world` to a
shipped artifact a stranger can run*. Clarity is already 100% self-hosted and ships as a single
binary; the roadmap below is about closing that distance for the four kinds of software we
actually want to build, and doing it faster and with less ceremony than the incumbents.

---

## The state of play (September 2026)

- **Self-hosted, v1.0.** Lexer, parser, interpreter, bytecode VM, type checker, linter,
  formatter, debugger, profiler, doc generator, package manager, LSP, and shell — all written
  in Clarity. ~2,750 assertions in Clarity.
- **One binary, no external runtime for the *toolchain*.** `clarity` is a single Bun-compiled
  executable (macOS + Linux, x64 + ARM64).
- **Native compilation is real and growing.** `clarity cc <file>` compiles Clarity → C → a true
  native ELF/Mach-O binary with **no Bun and no VM**. As of stage 20 it covers the scalar core,
  collections, classes, closures, a reclaiming GC, strings, file I/O, process/exec, math, JSON,
  raw binary I/O + bitwise ops, native FFI (`ffi_open` + a generic word-arg caller + raw buffers),
  the RE byte toolkit (endianness readers/writers + AOB signature scanning), live-process memory
  read/write (`read_mem` / `write_mem` over `/proc/<pid>/mem`), 64-bit-capable bit manipulation
  (`bits.clarity`, correct to 2^53), inline function hooking (`hook.clarity`, x86-64 Linux), a binary-format DSL (`binformat.clarity`), and disassembly via a runtime libcapstone binding (`capstone.clarity`) — each capability verified by compiling the generated C and
  diffing its output against the tree-walking interpreter. Native `wc`, a native sysinfo tool, a
  native JSON transformer, a native `sigscan` AOB scanner, a native `memscan` live-memory scanner, a
  native `memtrainer` (find-and-poke a value), a native `elf64info` (decodes 64-bit ELF header
  fields), a native `ffi_libm` (loads libm at runtime), a native `ffi_buffer` (marshals raw
  memory through libc calls), a native `hookdemo` (patches a live function to force its return
  value), a native `binformat_demo` (declaratively parses an ELF64 header),
  and a native `disasm` (decodes machine code, incl. a live libc function, via libcapstone) all
  compile to standalone binaries.
- **Track B is now open.** With native FFI (stage 11), the byte toolkit + AOB scanning (stage 12),
  and live-process memory read/write (stages 13–14) landed, the gaming specialty is underway —
  **RE tooling first** (see the resolved sub-ordering under Track B below).

The bet: keep pushing `clarity cc` until *any* Clarity program compiles to a native binary, then
specialize hard into the two markets where a small, embeddable, native-compiling language has an
unfair advantage — **app tooling** and **games (mods + reverse engineering)**.

---

## Track A — Native app runtime (finish "build any app as a native binary")

The trunk everything else hangs off. Until an arbitrary Clarity program compiles and runs
natively, the specialty tracks can't ship. Driven stage-by-stage through `clarity cc`; each stage
lands with codegen tests that diff native output against the interpreter.

- **Stage 10 (done) — binary I/O + bitwise.** `read_bytes`/`write_bytes` for raw buffers and the
  bitwise operators (`& | ^ << >>`) — the gateway to Track B, since pattern scanning and format
  parsing both need raw bytes and bit-twiddling.
- **Stage 11 (done) — native FFI.** `ffi_sym`/`ffi_call` (`dlsym` + a typed C-call shim) so a
  compiled binary calls C directly.
- **Stage 12 (done) — RE byte toolkit.** `stdlib/bytes.clarity`: endianness readers/writers + AOB
  signature scanning, pure Clarity. First Track B increment (see below).
- **Module-level bindings (done).** A top-level `let`/`mut` is emitted at C file scope instead of
  as a local of `main()`, so functions can see it (previously any module constant referenced from
  a function simply failed to compile). Initialisers still run in source order at `main` entry, and
  the addresses are handed to the collector as explicit roots — the conservative GC scans the C
  stack, so a file-scope value is invisible to it without that.
- **Imports in native builds (done).** `clarity cc` emits one C translation unit, so an import
  cannot be a link-time reference — `stdlib/c_modules.clarity` flattens the program and its import
  graph into a single AST, resolving each module's own imports first. A module is included once
  however many times it is imported, a cycle terminates, and because C has one namespace a name
  defined in two modules is reported by name and file rather than silently resolved in favour of
  whichever was spliced last. Verified end to end: a program importing `sha256.clarity` (which
  itself imports `bits.clarity`) compiles and produces the published FIPS 180-4 digests.
  **Remaining:** a selective import still pulls in the whole module, since taking only the named
  symbols would break the module's internal references.
- **Expression forms the C backend rejected (done).** Compiling a real stdlib module for the first
  time found three pieces of core language surface missing from `clarity cc`: `if`/`else` in
  expression position, `??`, and `type()`. All three now compile and are diffed against the
  interpreter, including the two cases a careless implementation gets wrong — the untaken `if` arm
  must not run, and `??` must evaluate its left side exactly once.
- **Named functions as values (done).** `apply(twice, 5)` used to emit `v_twice`, a variable that
  does not exist. A bare mention of a top-level function now emits a closure wrapping it, with a
  thunk that unpacks the closure convention's argument array into the function's individual
  parameters. The emitter tracks the names each function binds — parameters, `let`/`mut`, loop
  variables — so a local shadowing a function name still resolves to the local, which is what the
  program meant.
- **Sockets (done).** `tcp_listen` / `tcp_port` / `tcp_accept` / `tcp_connect` / `tcp_send` /
  `tcp_recv` / `tcp_close` — blocking IPv4 TCP straight onto the C runtime, with failures reported
  as `-1` rather than aborting, because a compiled tool that dies on a refused connection is much
  less useful than one that can say so. Received data is a list of bytes, not a string: a Value
  string is a NUL-terminated `char*`, so any binary body would be silently truncated. Native-only
  by nature (the interpreter's I/O is Bun's, which has no synchronous socket call to diff
  against), so the tests assert the compiled binary's output the way the FFI ones do — a full
  round trip on loopback in a single process, including a payload with an embedded NUL.
- **HTTP (done).** `stdlib/http.clarity` — request building, response parsing, and the server
  side, on top of the sockets above. The first stdlib module that exists *because* native imports
  do: it is built on the `tcp_*` builtins, which the interpreter does not have, so it can only be
  reached by compiling. Bodies are byte lists for the same reason sockets return them. The server
  hands the caller the connection and the parsed request rather than taking a handler function —
  a better API, and it sidesteps the backend's inability to pass a named function as a value. One
  connection at a time; there are no threads yet. **Remaining:** keep-alive, chunked
  transfer-encoding, redirects, TLS.
- **Missing builtins (done).** Fifteen builtins that work under `clarity run` had no case in the
  C backend at all, so a program using one failed with an undeclared identifier in the generated C
  — a `v_print` that was never emitted. `print` among them, which put most real programs outside
  `clarity cc` entirely. Now: `print`, `pop`, `sort`, `reverse`, `unique`, `flat`, `zip`, `find`,
  `every`, `some`, `values`, `entries`, `merge`, `bool`, `pow`. Semantics match the host runtime
  deliberately — `sort` is a stable merge sort because `Array.prototype.sort` is required to be
  stable, `unique` keeps first occurrences, `flat` goes one level, `merge` lets later sources win.
  Measured, not guessed: each candidate was run through both paths, and five apparent gaps
  (`slice`, `insert`, `remove`, `now`, `json_str`) turned out not to be globals in either.
- **Language constructs the backend rejected (done).** `a..b`, `x |> f`, `match`/`when`, and
  `interface`. Six of the seventeen files in `examples/` would not compile because of them. The
  pipe form reuses the ordinary call emitter rather than adding a second call site, so it resolves
  builtins and named functions identically; `match` binds its subject to a temporary because it
  must be evaluated once however many arms are tested. `interface` emits nothing — it is a
  compile-time contract with no runtime effect on a *valid* program. The divergence that leaves,
  stated rather than hidden: a program that violates an interface is rejected by the interpreter
  and accepted by `clarity cc`.
- **Exceptions (done).** `try`/`catch`/`finally` and `throw`, on setjmp/longjmp: a stack of
  handlers and one slot for the value in flight, which is a GC root because during unwinding it is
  often the only reference to it. This was the blocker for compiling the compiler: every file in
  the chain uses try/catch, `c_codegen.clarity` itself twice, and 62 of the 218 stdlib modules do.
  The subtlety is that C leaves a non-volatile local of the function containing the setjmp
  indeterminate if the try modifies it, so functions containing a try get volatile locals —
  without that, a variable written in the try and read after the catch is correct at -O0 and wrong
  at -O2. `return` out of a try runs the finallys it leaves; `break`/`continue` across one are
  refused rather than silently skipping it. Known and matched rather than fixed: when a `catch`
  returns, neither the interpreter nor the backend runs the `finally` — an interpreter bug the
  backend now reproduces, to be changed in both at once.
- **The last builtins (done).** `cwd`, `encode64`, `decode64`, `hash` (SHA-256, asserted against
  the published FIPS 180-4 vectors), `random`.
- **Module-scoped names (next on the trunk).** A native build is one C translation unit, so two
  modules that define the same top-level name collide and the build stops — correctly and loudly,
  but it stops. Measured on the compiler's own import graph: **66 modules, 21 colliding names**,
  with `_quote` defined in seven of them. They are almost all module-private helpers, which is
  exactly what namespacing is for. This is what `clarity cc stdlib/cli.clarity` — compiling the
  Clarity compiler natively — currently stops on, and it is necessary but not sufficient for that.
  The fix is to mangle colliding top-level names per module in `c_modules.clarity`, rewriting
  references with a scope-aware walk so a local shadowing one is left alone. Both failure modes
  (a missed rename, a wrongly renamed local) are an undefined identifier in the generated C rather
  than silent misbehaviour, which is what makes it tractable.
- **Enums (done).** An enum is a compile-time table rather than a runtime object: its members
  become C globals initialised before any module-level binding, and `Colour.Red` resolves while
  compiling. `names()`, `values()`, `entries()` and `has()` are emitted as one C function each,
  building a fresh value per call the way the interpreter's do, so a caller that mutates the list
  it gets back does not change what the next call returns. Members with an explicit value take it;
  the rest take their index, as in the interpreter. Two divergences, stated rather than hidden:
  reading a member an enum does not have is a *compile* error here and a runtime one there — the
  same program refused earlier — and the enum name is not a value, so `let c = Colour` is refused
  rather than compiled into something that only looks like one. Eleven cases in the codegen suite
  diff the native output against the interpreter, including one under `CLARITY_GC=1`, because a
  member holding a string is heap-allocated and the collector has to see the global holding it.
- **Generators (done).** They needed no coroutines, because Clarity's generators are not lazy:
  a body that yields runs to the end and the call returns the list of what it yielded, which is
  what `for x in gen()` iterates. So `yield v` compiles to an expression worth v that also appends
  v to one list local per call — a local rather than anything global, so a recursive or nested
  generator keeps its own, which is what the interpreter's save-and-restore buys it. Every return
  in such a function hands back the collection when it is not empty, evaluating the returned
  expression first because the interpreter does. A closure or method written inside a generator is
  its own call with its own collection, and is scanned separately. Found on the way in: the
  *bytecode VM* did not implement generators at all — `yield` compiled to the value and collected
  nothing, so `counter(3)` was null under `run --fast` and a loop over it ran zero times — and the
  interpreter gave a generator *method* null while the same body worked as a free function. All
  three engines agree now, pinned by fourteen parity cases and fourteen codegen cases. Also found
  on the way in, and *not* fixed here: `clarity cc` evaluates a construct's operands in the order C
  chooses, which is the reverse of the interpreter's whenever two of them have side effects
  (`[bump(), bump()]` is `[1, 2]` interpreted and `[2, 1]` native). It is a defect in every
  multi-operand emission, not in generators, so it is written up in GAPS.md as its own change.
- **Destructuring and spread in native builds.** With generators done, what stops the last two
  files in `examples/` compiling is `DestructureLetStatement`, `MultiAssignStatement` (`let [a, b]
  = pair`, `a, b = b, a`) and `SpreadExpression` in a call or a list. Fifteen of the seventeen
  examples compile today.
- **Networking.** TLS, then keep-alive and chunked encoding, so the HTTP
  client can talk to real services rather than only to plaintext ones.
- **Stage 12+ — services stdlib.** Real crypto (not the toy cipher), a real embedded key/value or
  SQLite binding, CSV/YAML/TOML parsers. The "boring but load-bearing" tier for backends and data
  tools.
- **Precise GC.** Replace conservative C-stack scanning with an emitted shadow stack of live
  roots. Removes the optimiser/ABI fragility that keeps mid-run collection opt-in today, and makes
  default-on GC safe on every platform. Prerequisite for long-running native services.
  That fragility is not theoretical: the `global_gc_rooted` codegen test runs a compiled program
  under `CLARITY_GC=1`, and on darwin-arm64 the binary dies partway through its allocation loop —
  with or without the module-globals root table, so it is the scan itself, not the roots. The test
  therefore asserts on Linux and skips elsewhere. Mid-run collection stays opt-in until this is
  precise.
- **GUI, last.** Desktop/GUI needs a graphics stack; it comes after the headless tiers are solid,
  most likely as an FFI binding to an existing toolkit rather than a from-scratch renderer.

**Done when:** a non-trivial Clarity app — a web service, a CLI with subprocesses, a data
pipeline — compiles with `clarity cc` and runs as a single native binary with no Bun anywhere.

### Self-hosting: the compiler rebuilds itself (done)

"Self-hosted" was only half true. The Clarity→JS transpiler in `stdlib/transpile.clarity` could not
regenerate the compiler bundle: its output would not even parse. Nothing failed, because
`transpile --bundle` resolved the stdlib directory relative to the *current* directory, found no
sources when run from the repo root, and wrote an empty bundle while reporting success — so CI
quietly built from `native/transpile.py`, the Python reference implementation, instead.

Seven distinct defects were behind it, each found by building and running the result rather than
by reading:

1. A raw newline (or CR/tab/NUL) emitted inside a JS string literal — `split(x, "\n")` in
   `cli.clarity` alone was enough to make the compiler's own output unparseable.
2. JS reserved words that are legal Clarity identifiers (`function`, `enum`, `import`, …) emitted
   verbatim.
3. A module defining `fn max` emitting `function $max` next to the runtime's imported `$max` — a
   redeclaration ESM rejects. The shadowed import is now dropped.
4. No `export` on top-level declarations, so no module could satisfy another's import.
5. Property names run through reserved-word mangling, turning `env.set(...)` into `env.$set(...)`.
6. Closures emitted as `function` rather than arrows, losing the lexical `this` a Clarity closure
   inside a method depends on.
7. Imported class names unknown, so `Token(...)` lost its `new`. Rather than hardcode a class list
   (what the Python reference does), the emitter now parses the sibling module and reads its class
   declarations.

Four stdlib modules also reassigned `let` bindings — legal to the interpreter, which does not
enforce immutability, and to the Python backend, which emits `let` for everything, but not to the
self-hosted backend, which correctly emits `const`. Those are now `mut`.

Guarded by the **Self-hosting bootstrap** CI job: seed with the Python transpiler, have the
compiler regenerate its own bundle twice, require stage 2 and stage 3 to be byte-identical, and
then require the self-hosted build to pass the full suite and the smoke tests — because a fixpoint
on broken output is still broken. (That is not hypothetical: an intermediate fix reached a clean
fixpoint with a binary that failed all 61 test files.)

**Still open:** the interpreter does not enforce `let` immutability, so reassigning one is caught
only when it reaches a backend that emits `const`.

---

## Track B — Gaming specialty: RE tooling & game mods

The differentiator. This is where a small language that compiles to native code, calls C
directly, and can be *embedded* has a genuine edge over Python (slow, needs an interpreter shipped)
and C++ (heavy, slow to iterate). Two sub-directions share the same primitives (raw memory + FFI +
a small embeddable core):

**RE / tooling direction** — *now the active sub-track (see the resolved ordering below).*
- **Raw memory + pattern scanning.** ✅ *Stage 12:* `stdlib/bytes.clarity` gives byte buffers,
  endianness helpers (unsigned + signed, LE + BE), and AOB/signature scanning with `??`/`*`
  wildcards, all pure-Clarity; `examples/sigscan.clarity` is a standalone compiled AOB scanner.
  (It inlines the byte helpers, which predates native import support and no longer needs to.) **Remaining:** pointer arithmetic against a live target's
  address space (needs the process-memory piece below).
- **Binary-format DSL.** ✅ *Stage 19:* `stdlib/binformat.clarity` — describe a layout as a list of
  field specs, then `parse` bytes into a map and `emit` a map back to bytes (`sizeof` too). Pure
  Clarity over `bytes.clarity`; `examples/binformat_demo.clarity` parses a real ELF64 header
  declaratively. **Remaining:** variable-length/among-field-dependent fields (a length field driving
  a later array), bitfields, and nested/repeated sub-formats.
- **Process & memory access.** ✅ *Stages 13–14:* `read_mem(pid, addr, len)` and
  `write_mem(pid, addr, bytes)` read and poke another process's `/proc/<pid>/mem` (pid≤0 = self),
  and pure-Clarity `mem_regions` / `find_region` / `scan_process` / `patch_first` (in
  `stdlib/procmem.clarity`) enumerate and scan regions from `/proc/<pid>/maps`;
  `examples/memscan.clarity` (live AOB scanner) and `examples/memtrainer.clarity` (find-and-poke a
  value) are compiled demos. **Remaining:** module-enumeration niceties and non-Linux backends
  (mach/`task_for_pid`, Windows `ReadProcessMemory`/`WriteProcessMemory`).
- **Hooking / detours.** ✅ *Stage 18 (inline patch):* `stdlib/hook.clarity` patches a live
  function's code to force a return value (via `write_mem` through `/proc/<pid>/mem`, which reaches
  read-only executable pages); `examples/hookdemo.clarity` is a compiled demo. x86-64 Linux for now.
  **Remaining:** trampoline detours (jump to a replacement, preserving the original), GOT/PLT
  redirection, arm64 (needs i-cache maintenance), and Windows.
- **Disassembly / analysis on-ramp.** ✅ *Stage 20:* `stdlib/capstone.clarity` binds libcapstone at
  runtime (via `ffi_open` + buffers) and decodes machine code into `{addr, size, mnemonic, op_str}`;
  `examples/disasm.clarity` disassembles a static snippet and a live libc function. **Remaining:**
  richer detail (registers/groups/operands from `cs_detail`), more architectures wired, and a
  higher-level analysis layer (basic-block / control-flow) on top.

**Mods / embedding direction**
- **Embeddable runtime.** A small C-callable core so a game or host app can embed Clarity as its
  scripting layer — `clarity_eval`, value marshalling, host-function registration. The native
  compiler and the C value model already point at this.
- **Overlays & input.** Drawing/overlay and input-hook primitives (again FFI-first) for in-game
  tools and mod UIs.
- **Windows as a first-class target.** RE and modding live on Windows. `clarity cc` currently
  targets ELF/Mach-O; a PE/COFF path (via mingw/clang) is on this track, not an afterthought.

> **Sub-ordering (resolved, Sept 2026): RE tooling first.** Within Track B we lead with
> *native-RE-tooling* (make Clarity the language you write cheats/trainers/analyzers in) before
> *embeddable-scripting-for-mods*. Stage 12 (byte toolkit + AOB scanning) is the first increment;
> stages 13–14 add live-process memory *reads and writes* (`read_mem`/`write_mem` +
> `/proc/<pid>/maps` enumeration + `patch_first`), stage 15 adds 64-bit-capable bit math, and stage
> 16 adds `ffi_open` (bind any shared library). The path from here is hooking/detours → a
> disassembly on-ramp (now that `ffi_open` can load a Capstone-class engine). The mods/embedding
> direction (embedding API + Windows PE) follows once the RE primitives are solid.

**Done when:** you can write a memory scanner / trainer, *or* embed Clarity as a game's mod
scripting language, entirely in Clarity, compiled native.

---

## Track C — Language maturity (compete on the fundamentals)

The table stakes that keep Clarity credible next to modern languages while the specialty tracks
land. Mostly hardening of things that already exist.

- **Concurrency that's real.** Today's concurrency is cooperative/faked. Native threads or an
  async runtime with a real scheduler — needed for servers and for responsive tools.
- **Performance.** Benchmark interpreter vs. VM vs. native across the example suite; close hot-path
  regressions. The native path should be the fast path.
- **Error model.** Runtime errors get a column + caret like parse errors already do; a documented
  story for errors-as-values vs. exceptions.
- **Type system.** A written soundness audit of the gradual-typing escape hatches — catalogue
  what's intentionally loose vs. an actual hole.
- **Tooling tail.** `clarity test` ergonomics (`--only`, `--watch`, parallel runner); LSP rename +
  cross-file go-to-definition + code actions; debugger conditional breakpoints/watch expressions;
  profiler flamegraphs.

---

## Track D — Ecosystem (so other people can ship too)

A language is only as strong as the distance from "I want to use it" to "it's in production."

- **Package manager, client side.** Lockfile spec, integrity hashes, offline mode, mirror support.
  The registry server exists; the client is the gap.
- **Distribution.** `clarity build` producing a native binary as the *default, documented* path —
  cross-compilation, static linking, small binaries.
- **Docs & learning.** Cross-referenced doc generator with search; a real tutorial track for each
  of the four app types; example apps that double as proof points.
- **WASM target.** `clarity build --target wasm` for the browser, so the web story doesn't depend
  on the JS transpile.

---

## Sequencing

1. **Done:** Track A stages 10–11 (binary I/O + bitwise, then native FFI) — the shared
   prerequisites for the whole Track B specialty.
2. **In progress:** Track B, **RE-tooling first** (sub-ordering resolved above). Stage 12 (byte
   toolkit + AOB scanning), stages 13–14 (live-process memory read/write), stage 15 (64-bit-capable
   bit manipulation to 2^53), stage 16 (`ffi_open` — bind any shared library), and stage 17
   (pointer/buffer FFI + generic word-arg caller), stage 18 (inline function hooking), and stage 19
   (binary-format DSL), and stage 20 (disassembly via a runtime libcapstone binding) shipped; the RE
   primitive set (scan / read+write memory / hook / disassemble / describe formats / bind libraries)
   is now broadly complete. Next: trampoline detours, richer disassembly detail, and consolidation
   (an umbrella "RE in Clarity" module + tutorial). Then the mods/embedding direction. (Making the
   bitwise *operators* themselves 64-bit, and full bit-63 u64, remain larger deliberate
   numeric-tower efforts — see GAPS.md.)
3. **In parallel, opportunistically:** Track A networking/services stages as specific apps need
   them, and Track C hardening as friction shows up.
4. **Track D** rides along — every stage ships with tests and docs so the ecosystem can follow.

---

## Explicitly out of scope

Carried over from GAPS.md — decided *no* so the roadmap stays focused:

- **Macros / metaprogramming.** Pattern matching + decorators + the AST module cover the cases.
- **Generics with monomorphisation.** Gradual typing + duck-typed runtime covers polymorphism.
- **A second syntax.** One syntax, one toolchain. No "Clarity Lite," no s-expr front-end, no
  significant-whitespace mode.
