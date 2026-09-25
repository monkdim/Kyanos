//! /bin/clarity-faultprobe — a program that does the worst thing it can.
//!
//! Every other program on this boot is careful. This one is not: it writes
//! through a null pointer, which on x86_64 is a page fault taken in ring 3
//! with CR2 = 0 and no mapping to fix it with.
//!
//! What the kernel is supposed to do about that is kill *this program* and
//! carry on. What it did before was `cli; hlt` — the whole machine, for one
//! program's bad pointer. So this is not a test of the program; the program
//! is the instrument, and what is being measured is whether the boot gets
//! any further.
//!
//! It says so before it faults, because a program that produced no output at
//! all would be indistinguishable from one that never ran.

const NR_WRITE: u64 = 1;
const NR_EXIT: u64 = 12;

/// Nothing else on this boot exits with it. A boot where this appears is one
/// where the fault did not happen, which is its own failure.
const UNREACHED: u64 = 77;

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
    write("faultprobe: about to write through a null pointer\n");

    // `volatile` so the optimiser cannot decide a store nobody reads may be
    // dropped. At -OReleaseSmall it would, and the program would exit
    // cleanly having proved nothing. `allowzero` because Zig refuses a plain
    // pointer to address zero, and zero is the address — the point of the
    // program is to name the one address every operating system agrees is
    // not there.
    const nowhere: *allowzero volatile u64 = @ptrFromInt(0);
    nowhere.* = 0xDEAD;

    write("faultprobe: I am still here, which I should not be\n");
    _ = syscall3(NR_EXIT, UNREACHED, 0, 0);
    unreachable;
}
