//! /bin/clarity-sleepprobe — a program that asks to be woken up later.
//!
//! `nanosleep` has been in the syscall table since the process model landed
//! and nothing has ever called it. Whatever this boot does is a measurement
//! and not a confirmation: the point is to find out what the kernel actually
//! does with a sleeping thread, not to watch it agree with a reading of the
//! source.
//!
//! It says so on both sides of the sleep, because a program that printed
//! nothing would not distinguish "it never woke" from "it never ran".

const NR_WRITE: u64 = 1;
const NR_EXIT: u64 = 12;
const NR_NANOSLEEP: u64 = 17;

/// Long enough that a sleep rounded to the timer's resolution is still
/// clearly a sleep, and short enough that a boot waiting for it is not a
/// boot that looks hung. Ten hundredths of a second, in nanoseconds.
const NAP_NS: u64 = 100_000_000;

/// Nothing else on this boot exits with it.
const WOKE: u64 = 64;

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

export fn _start() callconv(.C) noreturn {
    write("sleepprobe: going to sleep\n");
    _ = syscall3(NR_NANOSLEEP, NAP_NS, 0, 0);
    write("sleepprobe: and I woke up again\n");
    _ = syscall3(NR_EXIT, WOKE, 0, 0);
    unreachable;
}
