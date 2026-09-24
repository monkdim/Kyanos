//! /bin/clarity-spin — a program that takes its time, so another one can have
//! some of it.
//!
//! Every program this kernel has run at EL0 so far has had the machine to
//! itself: the boot calls `enter_user`, the program runs to completion, and
//! only then does anything else happen. A timer tick landing in EL0 was
//! handled, but there was never anything to switch *to*, so nothing ever did.
//!
//! Two copies of this run side by side, one per kernel thread. Each writes a
//! character, then spends long enough at EL0 that the 100 Hz timer is certain
//! to fire there rather than in the kernel, then writes again. If the two
//! never interleave, the kernel ran them one after the other and nothing was
//! preempted; the boot says so and fails. The spin is the point of the
//! program, the same way it is the point of `__user_probe`'s loop in user.S.
//!
//! It also leaves a number of its own in d0 and d20 and checks after every
//! spin that it is still there — the registers nothing saved before the trap
//! frame started carrying the whole vector file. The two copies use different
//! numbers, because the stack-pointer bug this test missed the first time hid
//! precisely behind two copies holding the same value.
//!
//! The character comes from x0, which is what the kernel now tells a program
//! about itself — see `aarch64_enter_user`. Without it the two copies would
//! be indistinguishable, and "they interleaved" would be unobservable from
//! outside the kernel.
//!
//! Freestanding, no libc, same ABI as the other programs here: number in x8,
//! arguments in x0-x5, `svc #0`, result back in x0.

const NR_WRITE: u64 = 1;
const NR_EXIT: u64 = 12;

/// How many times each copy speaks. Ten is enough that "they interleaved" is
/// a statement about the schedule rather than about one lucky tick.
const ROUNDS: usize = 10;

/// Iterations between one write and the next.
///
/// A tick is 10 ms. Under TCG this loop runs at roughly a million iterations
/// per millisecond, so 16.7 million is more than one tick's worth — which is
/// what makes a preemption inside the spin a certainty rather than a
/// coincidence. A slower machine only makes it more certain.
const SPIN: u64 = 0x100_0000;

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

/// Burn time at EL0 without asking the kernel for anything.
///
/// `volatile` because the loop has no other effect and an optimiser is
/// entitled to delete it — and a program that skipped its own spin would
/// finish before the first tick and make the whole test pass or fail on
/// timing nobody chose.
fn spin() void {
    var i: u64 = 0;
    while (i < SPIN) : (i += 1) {
        asm volatile ("" ::: "memory");
    }
}

/// `id` arrives in x0 from the kernel: 0 for the first copy, 1 for the
/// second. It picks the character and the exit code, so the boot can tell
/// which copy said what and that each one got its own number.
fn read_sp() u64 {
    return asm volatile ("mov %[out], sp"
        : [out] "=r" (-> u64),
    );
}

export fn _start(id: u64) callconv(.C) noreturn {
    const ch: u8 = if (id == 0) 'A' else 'B';
    const line = [_]u8{ch};

    // EXPERIMENT: does this program's stack pointer survive being preempted?
    // SP_EL0 is one register for the whole core and the kernel writes it at
    // every `enter_user`; nothing saves it across a thread switch. Two copies
    // of one image cannot see that, because their stacks are at the same
    // virtual address — so the kernel starts these two at addresses 0x1000
    // apart, and this remembers which one it got.
    const sp_at_start = read_sp();

    // And whether the vector file survives one. d0 is caller-saved and d20 is
    // outside the d8-d15 `clarity_switch_to` keeps, so both are registers
    // nothing saved until the trap frame started carrying the whole file.
    //
    // The two copies use *different* numbers. That is the lesson of the
    // stack-pointer bug this test missed the first time: two copies of one
    // image had their stacks at the same virtual address, so the wrong value
    // was numerically the right one and the test could not tell. A value that
    // differs per copy cannot hide that way.
    const mine: u64 = 0xF00D_0000_0000_0000 + id;
    asm volatile (
        \\fmov d0, %[v]
        \\fmov d20, %[v]
        :
        : [v] "r" (mine),
        : "d0", "d20"
    );

    var round: usize = 0;
    while (round < ROUNDS) : (round += 1) {
        write(&line);
        spin();
        const sp_now = read_sp();
        // The frame is the same one each time round, so the only thing that
        // can change this is the kernel.
        var d0_now: u64 = 0;
        var d20_now: u64 = 0;
        asm volatile (
            \\fmov %[a], d0
            \\fmov %[b], d20
            : [a] "=r" (d0_now),
              [b] "=r" (d20_now),
        );
        if (d0_now != mine or d20_now != mine) {
            write("\nFP CHANGED under this program\n");
            exit(80 + id);
        }
        if (sp_now != sp_at_start) {
            write("\nSP CHANGED under this program\n");
            exit(90 + id);
        }
    }

    // 70 and 71, which nothing else on this boot exits with — so "both
    // programs finished" is a statement about these two and not about
    // whatever ran last.
    exit(70 + id);
}
