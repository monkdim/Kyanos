//! /bin/clarity-hello — the smallest program that can be asked for by name.
//!
//! It exists to be the *other* end of an exec: something a forked child can
//! turn into, whose voice and exit code nothing else on the boot produces, so
//! "the child became another program" is a statement about this program and
//! not about whatever happened to run next.
//!
//! It grows its heap by a page and writes to it before saying anything. That
//! is not decoration: a process that has just exec'd has a new address space,
//! a new break and a new entry in nothing that was written down before, and
//! the heap is the first thing that notices when any of those is stale.

const NR_WRITE: u64 = 1;
const NR_BRK: u64 = 9;
const NR_EXIT: u64 = 12;

/// Nothing else on this boot exits with it.
const CODE: u64 = 55;

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

export fn _start() callconv(.C) noreturn {
    const brk0 = syscall3(NR_BRK, 0, 0, 0);
    if (brk0 <= 0) {
        write("hello: I was given no heap\n");
        exit(1);
    }
    const want: u64 = @as(u64, @intCast(brk0)) + 0x1000;
    if (syscall3(NR_BRK, want, 0, 0) < @as(i64, @intCast(want))) {
        write("hello: I could not grow my heap\n");
        exit(2);
    }
    const cell: *volatile u64 = @ptrFromInt(@as(usize, @intCast(brk0)));
    cell.* = 0x1234_5678_9ABC_DEF0;
    if (cell.* != 0x1234_5678_9ABC_DEF0) {
        write("hello: my heap did not keep what I put in it\n");
        exit(3);
    }

    write("hello: I am a different program than the one that asked for me\n");
    exit(CODE);
}
