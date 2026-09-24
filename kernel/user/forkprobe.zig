//! /bin/clarity-forkprobe — does fork(2) produce a second process?
//!
//! The syscall has been dispatched since the process model landed, and
//! nothing has ever called it. This is the first program that does.
//!
//! What a working fork owes the caller is exactly two things, and this checks
//! both: it returns **twice**, once in each process, and the two returns are
//! told apart by the value — the child's PID to the parent, zero to the
//! child. Everything else a process needs (its own memory, its own writes
//! landing separately) follows from those two being true.
//!
//! Each half writes a line naming itself, so the boot log shows two
//! processes where one program ran, and each exits with a different code so
//! the kernel can say which half finished.
//!
//! Freestanding, no libc: number in rax, arguments in rdi/rsi/rdx,
//! `syscall`, result back in rax.

const NR_WRITE: u64 = 1;
const NR_FORK: u64 = 10;
const NR_EXIT: u64 = 12;

fn syscall3(nr: u64, a0: u64, a1: u64, a2: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
        : "rcx", "r11", "memory"
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
    write("forkprobe: one process so far\n");

    const r = syscall3(NR_FORK, 0, 0, 0);

    if (r < 0) {
        // A refusal is a legitimate answer and says so plainly. It is not the
        // same as a fork that claims to have worked and did not.
        write("forkprobe: fork was refused\n");
        exit(1);
    }

    if (r == 0) {
        // Writing from here at all means this process exists, has its own
        // mapped memory, and can reach the kernel.
        write("forkprobe: I am the child\n");
        exit(61);
    }

    write("forkprobe: I am the parent\n");
    exit(60);
}
