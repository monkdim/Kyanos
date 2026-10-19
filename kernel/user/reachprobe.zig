//! /bin/clarity-reachprobe — a program that calls every system call there is.
//!
//! Not to see whether they work. To see which ones *answer*.
//!
//! The syscall table declares forty-four numbers and the dispatcher
//! implements seventeen. Neither of those two sets is where the bugs are.
//! The bugs are in the numbers that are implemented and that nothing on the
//! boot ever calls — every one of those found so far has turned out to be
//! broken, four for four: `fork` was a stub that would have reset the
//! machine, `wait` did not wait, `exec` killed the forked child that called
//! it, and `nanosleep` blocked its caller for ever.
//!
//! So this pokes each number once and lets the kernel write down what came
//! back. The kernel does the recording because it already has the number and
//! the result; a program reporting them would need a protocol, and a protocol
//! is a thing that can be wrong.
//!
//! Every argument is zero, which is chosen rather than lazy:
//!
//!   - the reads get `len` 0, so nothing waits on the console. A probe that
//!     blocked for the idle timeout on `read` would add three seconds to
//!     every boot and look like a hang.
//!   - the paths get a null pointer, which the user-pointer checks refuse as
//!     EFAULT before anything is opened or created.
//!   - `mmap` gets fd 0, which is not the framebuffer's fd, so it is EINVAL.
//!   - `nanosleep` gets 0 nanoseconds, which is a yield.
//!
//! Four numbers are left alone, and all four already have a gate of their
//! own, so nothing is lost by skipping them:
//!
//!   exit   does not return, so there would be nothing after it
//!   fork   makes a second process
//!   exec   replaces this image
//!   wait   blocks when the caller has a child

const NR_WRITE: u64 = 1;
const NR_EXIT: u64 = 12;

/// The four that are poked by their own gates instead. Keep this sorted and
/// keep it in step with the gate's own copy — `reachprobe.zig` prints these
/// as "not probed" rather than letting them read as unimplemented.
const SKIP = [_]u64{ 10, 11, 12, 13 }; // fork, exec, exit, wait

/// One past the highest number the kernel records. See `dispatch.TRACKED`.
const TRACKED: u64 = 64;

/// Nothing else on this boot exits with it.
const DONE: u64 = 66;

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

fn skipped(nr: u64) bool {
    for (SKIP) |s| {
        if (s == nr) return true;
    }
    return false;
}

export fn _start() callconv(.C) noreturn {
    write("reachprobe: calling every system call number once\n");

    var nr: u64 = 0;
    while (nr < TRACKED) : (nr += 1) {
        if (skipped(nr)) continue;
        _ = syscall3(nr, 0, 0, 0);
    }

    // Said last, so a boot where the loop above took the machine down is
    // distinguishable from one where it did not.
    write("reachprobe: every number answered and I am still here\n");
    _ = syscall3(NR_EXIT, DONE, 0, 0);
    unreachable;
}
