//! Preemption: prove the timer takes the CPU away from a thread that never
//! gives it up.
//!
//! `timer.init` was called from nowhere, so the PIT was never programmed and
//! no handler was ever installed on the timer vector — the scheduler's whole
//! preemptive half had never executed. The handler that would have run called
//! `sched.schedule()`, which picks the next thread without switching to it,
//! so had the timer been on it would have left `current` naming a thread that
//! was not running while the preempted one ran on, on the run queue and on
//! the CPU at the same time.
//!
//! The test has to be one that cooperative scheduling cannot pass. So neither
//! thread yields: A spins reading a flag, B sets it. B can only ever run if
//! something took the CPU away from A, and A can only observe the flag if the
//! CPU came back.

const std = @import("std");
const console = @import("arch/x86_64/console.zig");
const sched = @import("sched/scheduler.zig");
const timer = @import("arch/x86_64/timer.zig");

var b_ran: bool = false;

/// How long A waits before declaring preemption broken.
///
/// Counted in spins rather than timer ticks on purpose: if the timer is not
/// firing then `ticks` never advances, so a tick deadline would wait forever
/// for the very thing whose absence it is supposed to report. At 100 Hz a
/// tick is 10 ms, which is a few million spins even under TCG, so this leaves
/// a wide margin and still bounds the failure case to a couple of seconds.
const SPIN_LIMIT: u64 = 100_000_000;

fn thread_a(_: u64) callconv(.C) noreturn {
    var spins: u64 = 0;
    while (!@atomicLoad(bool, &b_ran, .seq_cst) and spins < SPIN_LIMIT) : (spins += 1) {
        asm volatile ("pause");
    }
    if (@atomicLoad(bool, &b_ran, .seq_cst)) {
        console.println("  [ok] preemption: B ran while A never yielded");
    } else {
        // Distinguishes the two ways this fails: no ticks at all means the
        // timer is not firing, ticks without B running means it fires but
        // does not switch.
        console.print("  [FAIL] preemption: B never ran, ticks=");
        console.print_dec(timer.ticks);
        console.println("");
    }
    sched.thread_exit(0);
}

fn thread_b(_: u64) callconv(.C) noreturn {
    @atomicStore(bool, &b_ran, true, .seq_cst);
    sched.thread_exit(0);
}

pub fn run() !void {
    _ = try sched.spawn_kthread(thread_a, 0, "[preempt-a]", .normal);
    _ = try sched.spawn_kthread(thread_b, 0, "[preempt-b]", .normal);
    console.println("  preempt: two threads queued, neither yields");

    // A is queued first, so A gets the CPU and holds it. Everything after
    // this depends on the timer prising it away.
    sched.run_queued();

    window();
}

// ── The window between deciding and switching ───────────────────────────
//
// `yield` sets `current = next` and then switches to it, and between those
// two the scheduler's belief and the machine disagree: the successor is
// named as running while the CPU is still on the predecessor's stack. A tick
// landing there calls `yield` again with `prev` set to a thread that is not
// running, and saves the caller's stack and resume address into that
// thread's context. Whatever switches to it later resumes on somebody else's
// stack, part way through an interrupt handler, and leaves through an
// `iretq` whose frame has been written over since.
//
// **That is not hypothetical, and it is also not reproducible by waiting.**
// It was seen once — a general protection fault at the `iretq` at the end of
// the timer handler, with RSP in low memory where no kernel thread's stack
// is — and then forty-nine further boots of the same image, and forty-eight
// of the one before it, produced nothing at all. A window a handful of
// instructions wide is hit about that often.
//
// So it is widened on purpose here, and only here: `preempt_window_spins`
// makes it thousands of instructions long. The check is direct rather than a
// proxy — the timer asks whether RSP is inside the stack of the thread
// `current` names — so what is counted is the disagreement itself.
//
// **What the zero below does and does not say.** With the guard in place,
// interrupts are masked across that window, so no tick can be delivered
// inside it and the count cannot be anything but zero. The zero is therefore
// the guard working, not luck — and on its own it would be just as
// consistent with a window that was never opened. What makes it mean
// something is the same build with the guard taken out: the first tick to
// land in the widened window reports RSP inside the *other* thread's stack,
// and the boot does not survive to print anything else. Measured, three
// boots out of three, against forty of the guarded build that all finish.

/// Long enough that a tick lands in the window nearly every time, short
/// enough that the two threads still finish inside a couple of seconds.
const WINDOW_SPINS: u32 = 20_000;

var w_a: u64 = 0;
var w_b: u64 = 0;
const W_ROUNDS: u64 = 200;

fn window_a(_: u64) callconv(.C) noreturn {
    var i: u64 = 0;
    while (i < W_ROUNDS) : (i += 1) {
        @atomicStore(u64, &w_a, i + 1, .seq_cst);
        sched.yield();
    }
    sched.thread_exit(0);
}

fn window_b(_: u64) callconv(.C) noreturn {
    var i: u64 = 0;
    while (i < W_ROUNDS) : (i += 1) {
        @atomicStore(u64, &w_b, i + 1, .seq_cst);
        sched.yield();
    }
    sched.thread_exit(0);
}

fn window() void {
    const before = sched.wrong_stack_ticks;
    const ticks_before = timer.ticks;

    w_a = 0;
    w_b = 0;
    _ = sched.spawn_kthread(window_a, 0, "[window-a]", .normal) catch {
        console.println("  [FAIL] preempt window: no thread");
        return;
    };
    _ = sched.spawn_kthread(window_b, 0, "[window-b]", .normal) catch {
        console.println("  [FAIL] preempt window: no second thread");
        return;
    };

    sched.preempt_window_spins = WINDOW_SPINS;
    sched.run_queued();
    sched.preempt_window_spins = 0;

    const bad = sched.wrong_stack_ticks - before;
    const ticks = timer.ticks - ticks_before;

    // A run that took no ticks at all would report zero and mean nothing, so
    // how many chances the window had is part of the pass.
    if (bad == 0 and ticks >= 2 and w_a == W_ROUNDS and w_b == W_ROUNDS) {
        console.print("  [ok] preempt window: ");
        console.print_dec(w_a + w_b);
        console.print(" switches with the choose-then-switch window held open for ");
        console.print_dec(WINDOW_SPINS);
        console.print(" spins, ");
        console.print_dec(ticks);
        console.println(" ticks, every one on the stack the scheduler named");
    } else {
        console.print("  [FAIL] preempt window: ");
        console.print_dec(bad);
        console.print(" of ");
        console.print_dec(ticks);
        console.print(" ticks found the CPU on another thread's stack (a=");
        console.print_dec(w_a);
        console.print(" b=");
        console.print_dec(w_b);
        console.println(") — yield is missing its guard");
    }
}
