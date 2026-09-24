//! /bin/clarity-forkexec — fork, then exec in the child, then wait.
//!
//! This is what a shell does, and until now this kernel could not do it. The
//! two halves existed: `fork` made a second process and `wait` let the first
//! one find out how it went. What was missing is in between — a forked child
//! that calls `exec` was *killed* by it, because `exec` leaves EL0 with a
//! path and expects whoever entered the program to load what it names, and
//! the only thing that did was the boot path's own loop.
//!
//! So the parent here never becomes anything else. It forks, the child turns
//! into /bin/clarity-hello, and the parent is still itself afterwards and
//! says so. Three claims, and the third is the one that fails on a kernel
//! that can only exec by replacing the program that asked:
//!
//!   - the child really became the other program — it is the other program's
//!     exit code that comes back, and nothing else on this boot uses it.
//!   - the parent got that code, through `wait`, for the PID `fork` gave it.
//!   - the parent is still running, and still itself, after all of that.

const NR_WRITE: u64 = 1;
const NR_FORK: u64 = 10;
const NR_EXEC: u64 = 11;
const NR_EXIT: u64 = 12;
const NR_WAIT: u64 = 13;

/// What /bin/clarity-hello exits with.
const HELLO_CODE: i32 = 55;

const TARGET: []const u8 = "/bin/clarity-hello\x00";

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

fn exit(code: u64) noreturn {
    _ = syscall3(NR_EXIT, code, 0, 0);
    unreachable;
}

/// Something only this program does, in a register a `call` would not keep,
/// checked after the fork and again after the wait. The parent must come
/// through both still itself.
const MARK: u64 = 0x7E57_0000_0000_C0DE;

fn read_x25() u64 {
    return asm volatile ("mov %[out], x25"
        : [out] "=r" (-> u64),
    );
}

export fn _start() callconv(.C) noreturn {
    write("forkexec: one process so far\n");

    asm volatile ("mov x25, %[v]"
        :
        : [v] "r" (MARK),
        : "x25"
    );

    const r = syscall3(NR_FORK, 0, 0, 0);
    if (r < 0) {
        write("forkexec: fork was refused\n");
        exit(1);
    }

    if (r == 0) {
        // Everything past this line belongs to a program that does not exist
        // yet. `exec` returns only when it fails.
        _ = syscall3(NR_EXEC, @intFromPtr(TARGET.ptr), 0, 0);
        write("forkexec: the child's exec was refused, so it is still itself\n");
        exit(2);
    }

    if (read_x25() != MARK) {
        write("forkexec: the parent did not come back from fork intact\n");
        exit(3);
    }

    var status: i32 = -1;
    const got = syscall3(NR_WAIT, @intFromPtr(&status), @bitCast(@as(i64, -1)), 0);
    if (got != r) {
        write("forkexec: wait named the wrong child\n");
        exit(4);
    }
    if (@as(*volatile i32, &status).* != HELLO_CODE) {
        write("forkexec: the child did not become the other program\n");
        exit(5);
    }
    if (read_x25() != MARK) {
        write("forkexec: the parent did not come back from wait intact\n");
        exit(6);
    }

    write("forkexec: my child became another program and I am still me\n");
    exit(50);
}
