//! /bin/clarity-exec — a program whose whole job is to stop being itself.
//!
//! Everything else on this machine either runs to completion or is stopped.
//! This one asks the kernel to replace it, which is the one thing no program
//! here could do until now, and it is the only way the boot can show `exec`
//! working without somebody typing at a shell: the plain boot has no keyboard
//! and nothing to type with, so a gate that depended on the shell would only
//! run in the headless serial job.
//!
//! It writes a line first, and the line matters. After the exec, standard
//! output belongs to a different program in a different address space — so
//! seeing *both* lines, in order, from one process is what says the identity
//! survived and the image did not.
//!
//! Two calls that do not come back are checked here, and they fail
//! differently on purpose:
//!
//!   - `exec("/nope")` must return, with ENOENT. A program has to be able to
//!     ask for something that is not there and carry on; the kernel checks
//!     the path before it unwinds out of EL0, because once it has, there is
//!     no instruction after the `svc` left to return to.
//!   - `exec("/bin/clarity-demo")` must not return at all. If it does, this
//!     program says so and exits non-zero, which is a failure the boot
//!     reports rather than a silence it ignores.
//!
//! Freestanding, no libc, same ABI statement as init: number in x8,
//! arguments in x0-x5, `svc #0`, result back in x0.

const NR_WRITE: u64 = 1;
const NR_EXEC: u64 = 11;
const NR_EXIT: u64 = 12;

const ENOENT: i64 = -2;

fn syscall3(nr: u64, a0: u64, a1: u64, a2: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (nr),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
        : "memory"
    );
}

fn write(buf: []const u8) void {
    var done: usize = 0;
    while (done < buf.len) {
        const n = syscall3(NR_WRITE, 1, @intFromPtr(buf.ptr) + done, buf.len - done);
        if (n <= 0) return;
        done += @intCast(n);
    }
}

fn exec(path: [*:0]const u8) i64 {
    return syscall3(NR_EXEC, @intFromPtr(path), 0, 0);
}

fn exit(code: u64) noreturn {
    _ = syscall3(NR_EXIT, code, 0, 0);
    unreachable;
}

export fn _start() callconv(.C) noreturn {
    write("exec-test: this is the first image speaking\n");

    // A path that names nothing. This has to come back, or a program could
    // never recover from a typo.
    if (exec("/nope") != ENOENT) {
        write("exec-test: exec of a missing path did not answer ENOENT\n");
        exit(1);
    }
    write("exec-test: a missing path was refused and I am still here\n");

    // And one that does. This must not come back.
    _ = exec("/bin/clarity-demo");
    write("exec-test: exec returned, so nothing was replaced\n");
    exit(2);
}
