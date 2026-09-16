# Clarity freestanding runtime

The Clarity runtime that ships in `/bin/clarity-init` on KyanOS.
One build path: embed QuickJS and run the same JS bundle the dev runtime
executes, with only the I/O surface different. It links against
`host_shim.zig`, the kernel-syscall bridge.

A second path, a pure-Zig bytecode VM under `runtime/native_vm/`, was a
484-line skeleton with 20 of 54 opcodes and no bundle loader. It was removed
in September 2026; the `clarity cc` C path superseded it (see
ROADMAP_OS.md).

## Layout

```
runtime/
├── freestanding/
│   ├── host.js               # Bun/Node ↔ KyanOS adapter
│   ├── runtime_freestanding.js  # runtime.js without Node imports
│   ├── host_shim.zig         # SYSCALL bridge
│   ├── quickjs_main.c        # QuickJS-backed entry point
│   ├── build.zig             # Zig build script
│   └── README.md
```

## Build (when zig is available)

```sh
cd runtime/freestanding
zig build              # → zig-out/bin/clarity-runtime  (QuickJS path)
```

The kernel's `kernel/main.zig` `spawn_user("/bin/clarity-init")`
loads whichever binary is installed at that path.

## How portability works

`stdlib/platform.clarity` is the cross-platform abstraction surface.
Stdlib code that touches I/O / processes / time should branch
through `platform.read_file()` / `platform.list_dir()` /
`platform.now_seconds()` rather than calling the runtime's
`read()` / `exec_full()` / `time()` directly. Those helpers detect
whether they're running on a host runtime (Bun/Node) or on the
bare-metal runtime (`CLARITY_HOST=claritos`) and dispatch
accordingly.

## Status (Phase 66)

- `host.js`           — done. Three concrete hosts (bun/node/claritos)
                        wired through one `HostInterface` shape.
- `runtime_freestanding.js` — done. No Node imports; uses host.js for
                        all I/O. Full type-conversion + display +
                        list/map/string runtime carried over from
                        native/runtime.js.
- `host_shim.zig`     — done. Wraps `SYS_*` numbers from
                        `stdlib/kernel_abi.clarity` as C-callable
                        functions plus a single dispatch entry the
                        JS engine binds.
- `quickjs_main.c`    — done. Tiny C shim — registers `print` +
                        `__claritos_syscall`, evaluates the bundled
                        JS, exits.
- `platform.clarity`  — done. Detection + override hooks + I/O
                        branches + audit (37 stdlib modules
                        classified as bare-metal-safe, 22 as
                        host-only).

`zig build` / `zig build run` only run in environments
that ship a Zig toolchain. None of the binaries here are produced in
this dev sandbox.
