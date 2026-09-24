//! The scheduler, exercised by the boot.
//!
//! `threadtest_aarch64.zig` next door tests the switching *primitive*: two
//! contexts and a timer handler that flips between them by hand. Everything
//! here goes through `sched/sched_aarch64.zig` instead, and each check is one
//! that the hand-wired version could not have passed.
//!
//!   - **Three threads, not two.** The old test's "which thread next" was a
//!     hard-coded `if (current == 1) ... else ...`. A third thread had
//!     nowhere to go. This spawns three, requires all three to make progress
//!     and each to be seen running several separate times, so a scheduler
//!     that rotated between two of them and dropped the third would fail.
//!
//!   - **Priority means something.** One thread at `.high` and one at
//!     `.normal`, both spinning, neither yielding. The normal one must not
//!     advance *at all* while the high one is runnable. A flat round robin
//!     passes every other check in this file and fails this one, which is
//!     the point: it is the check that says the priority level is read
//!     rather than stored.
//!
//!   - **A thread can finish.** The old threads looped forever and were
//!     abandoned where they stood. These call `thread_exit`, the scheduler
//!     switches away from each for the last time, and their stacks come
//!     back — which the page count at the end requires, so a scheduler that
//!     forgot to reap would be a failure rather than a slow leak.
//!
//! Nothing here cooperates in the way that would make the first check easy:
//! the spinners do not call `yield`. They check one flag at the top of their
//! loop, which is how they are asked to finish, and a load from memory is
//! not a scheduling decision.

const console = @import("arch/aarch64/console.zig");
const sched = @import("sched/sched_aarch64.zig");
const pmm = @import("mm/pmm.zig");

/// Enough that every counter is well past zero within a tick or two.
const WANT: u64 = 1000;

/// How many separate times each thread has to be caught running. Three
/// threads and six turns each: a scheduler that rotates between two of them
/// reaches this for two and never for the third.
const MIN_TURNS: u64 = 6;

/// A ceiling in timer ticks, so a scheduler that does not preempt reports
/// rather than hanging the boot. Two seconds at 100 Hz, which is hundreds of
/// times what the checks need.
const TICK_LIMIT: u64 = 200;

// ── State shared with the tick handler ───────────────────────────────────

/// Which test the tick handler is supervising, if any.
const Phase = enum { none, rotate, priority, window };
var phase: Phase = .none;

/// Asked for by the supervisor, read by every spinner at the top of its loop.
var stop: bool = false;

var ticks_used: u64 = 0;
var gave_up: bool = false;

/// Per-thread counters, indexed by slot rather than by tid so the handler
/// does not have to search.
const SLOTS = 3;
var spins: [SLOTS]u64 = .{ 0, 0, 0 };
var turns: [SLOTS]u64 = .{ 0, 0, 0 };
var tids: [SLOTS]i32 = .{ 0, 0, 0 };

/// The running code's own account of which thread it is, written by that
/// code on every pass round its loop.
///
/// The scheduler's `current` is the kernel's *belief* about who is running.
/// They can disagree, and the way they disagree is specific to this
/// architecture: an exception from EL0 or EL1 puts the return address in
/// ELR_EL1 and the saved state in SPSR_EL1, one pair of registers for the
/// whole CPU. A vector entry that leaves them there across a thread switch
/// sends the next `eret` back into the *other* thread's code, running on
/// this thread's stack. Counters alone cannot see that — both loops would
/// still be executing and both counters still climbing. This can.
var who: i32 = 0;
var mismatches: u64 = 0;

fn slot_of(tid: i32) ?usize {
    for (tids, 0..) |t, i| {
        if (t == tid and t != 0) return i;
    }
    return null;
}

/// Called from the timer's handler before `sched.preempt`, so it sees the
/// thread that is about to be preempted rather than its successor.
pub fn on_tick() void {
    if (phase == .none) return;
    ticks_used += 1;

    const cur = sched.current_thread() orelse return;

    const w: *volatile i32 = &who;
    if (w.* != cur.tid) mismatches += 1;

    if (slot_of(cur.tid)) |i| turns[i] += 1;

    switch (phase) {
        .none => {},
        .rotate => {
            var done = true;
            for (0..SLOTS) |i| {
                const s: *volatile u64 = &spins[i];
                if (s.* < WANT or turns[i] < MIN_TURNS) done = false;
            }
            if (done or ticks_used > TICK_LIMIT) {
                gave_up = !done;
                stop = true;
                phase = .none;
            }
        },
        .priority, .window => {
            // Both of these stop themselves once they have done enough; this
            // is only the ceiling, so a scheduler that never runs them at all
            // reports instead of hanging.
            if (ticks_used > TICK_LIMIT) {
                gave_up = true;
                stop = true;
                phase = .none;
            }
        },
    }
}

// ── Three threads, rotating ─────────────────────────────────────────────

fn spinner(arg: u64) callconv(.C) noreturn {
    const i: usize = @intCast(arg);
    const s: *volatile u64 = &spins[i];
    const w: *volatile i32 = &who;
    const flag: *volatile bool = &stop;
    const me = tids[i];
    while (!flag.*) {
        w.* = me;
        s.* +%= 1;
    }
    sched.thread_exit(0);
}

fn rotate() void {
    stop = false;
    gave_up = false;
    ticks_used = 0;
    mismatches = 0;
    spins = .{ 0, 0, 0 };
    turns = .{ 0, 0, 0 };
    tids = .{ 0, 0, 0 };

    var spawned: usize = 0;
    for (0..SLOTS) |i| {
        const t = sched.spawn_kthread(&spinner, i, "spin", .normal) orelse break;
        tids[i] = t.tid;
        spawned += 1;
    }
    if (spawned != SLOTS) {
        console.println("  [FAIL] scheduler: could not start three threads");
        stop = true;
        sched.run_queued();
        return;
    }
    // `who` starts as the thread the scheduler will pick first, so the very
    // first tick does not count a mismatch against a thread that has not yet
    // had a chance to write it.
    who = tids[0];

    phase = .rotate;
    sched.run_queued();
    phase = .none;

    const ok = !gave_up and mismatches == 0;
    if (ok) {
        console.print("  [ok] scheduler: three threads rotated — ");
        for (0..SLOTS) |i| {
            if (i != 0) console.print(", ");
            console.print_dec(spins[i]);
            console.print("/");
            console.print_dec(turns[i]);
        }
        console.println(" spins/turns, none of them yielding, all three finished");
    } else {
        console.print("  [FAIL] scheduler: spins=");
        for (0..SLOTS) |i| {
            if (i != 0) console.print(",");
            console.print_dec(spins[i]);
        }
        console.print(" turns=");
        for (0..SLOTS) |i| {
            if (i != 0) console.print(",");
            console.print_dec(turns[i]);
        }
        console.print(" wrong_thread_resumed=");
        console.print_dec(mismatches);
        console.print(" gave_up=");
        console.print_dec(@intFromBool(gave_up));
        console.println("");
    }
}

// ── Priority ────────────────────────────────────────────────────────────

var fg_spins: u64 = 0;
var bg_spins: u64 = 0;
/// What the background thread's counter read the moment the foreground one
/// finished. This is the measurement: a `.normal` thread must not have run
/// at all while a `.high` one was runnable.
var bg_when_fg_done: u64 = 0;

fn foreground(_: u64) callconv(.C) noreturn {
    const f: *volatile u64 = &fg_spins;
    const b: *volatile u64 = &bg_spins;
    const flag: *volatile bool = &stop;
    const w: *volatile i32 = &who;
    const me = tids[0];
    while (f.* < WANT and !flag.*) {
        w.* = me;
        f.* +%= 1;
    }
    bg_when_fg_done = b.*;
    sched.thread_exit(0);
}

fn background(_: u64) callconv(.C) noreturn {
    const b: *volatile u64 = &bg_spins;
    const w: *volatile i32 = &who;
    const me = tids[1];
    // Runs until the foreground thread is gone and it has done enough of its
    // own work to say it really was runnable the whole time.
    while (b.* < WANT) {
        w.* = me;
        b.* +%= 1;
    }
    sched.thread_exit(0);
}

fn priority() void {
    stop = false;
    gave_up = false;
    ticks_used = 0;
    mismatches = 0;
    fg_spins = 0;
    bg_spins = 0;
    bg_when_fg_done = 0;
    tids = .{ 0, 0, 0 };

    // The background thread is created *first* and at the lower priority, so
    // a queue that ignored priority and simply took the oldest would run it
    // first — which is exactly the mistake this is here to catch.
    const bg = sched.spawn_kthread(&background, 0, "bg", .normal) orelse {
        console.println("  [FAIL] scheduler priority: no thread");
        return;
    };
    tids[1] = bg.tid;
    const fg = sched.spawn_kthread(&foreground, 0, "fg", .high) orelse {
        console.println("  [FAIL] scheduler priority: no second thread");
        stop = true;
        sched.run_queued();
        return;
    };
    tids[0] = fg.tid;
    who = fg.tid;

    phase = .priority;
    sched.run_queued();
    phase = .none;

    if (!gave_up and fg_spins >= WANT and bg_spins >= WANT and bg_when_fg_done == 0) {
        console.print("  [ok] scheduler: a high-priority thread ran to ");
        console.print_dec(fg_spins);
        console.print(" while the normal one stayed at 0, then the normal one ran to ");
        console.print_dec(bg_spins);
        console.println("");
    } else {
        console.print("  [FAIL] scheduler priority: fg=");
        console.print_dec(fg_spins);
        console.print(" bg=");
        console.print_dec(bg_spins);
        console.print(" bg_when_fg_done=");
        console.print_dec(bg_when_fg_done);
        console.print(" gave_up=");
        console.print_dec(@intFromBool(gave_up));
        console.println("");
    }
}

// ── The window between choosing a thread and switching to it ────────────
//
// `yield` sets `current = next` and then switches to it. Between those two
// the scheduler's belief and the machine disagree: the successor is named as
// running while the CPU is still on the predecessor's stack. A tick landing
// there re-enters `yield` with `prev` set to a thread that is not running,
// and saves the caller's stack and resume address into that thread's
// context; whatever switches to that thread later resumes on somebody else's
// stack, part way through an exception handler.
//
// The window is a handful of instructions wide, so waiting for it is not a
// test — on the x86_64 side, where the same window was open, it produced one
// general protection fault in forty-nine boots and nothing at all in the
// ninety before and after. So it is widened on purpose, and the timer asks
// the question directly rather than through a proxy: is SP inside the stack
// of the thread `current` names?
//
// **What a zero here does and does not say.** With the guard in place,
// interrupts are masked across that window, so no tick can be delivered
// inside it and the count cannot be anything but zero — the zero is the
// guard working, not luck, and on its own it would be just as consistent
// with a window that was never opened. What makes it mean something is the
// same build with the guard removed.

/// Long enough that a tick lands in the window nearly every time, short
/// enough that the two threads still finish well inside the tick limit.
const WINDOW_SPINS: u32 = 120_000;

var w_a: u64 = 0;
var w_b: u64 = 0;
const W_ROUNDS: u64 = 250;

/// How many ticks have to arrive during the test before its zero is worth
/// anything. A run that took two ticks would report zero and mean almost
/// nothing; this is measured rather than guessed — the numbers above give
/// about thirty under TCG.
const MIN_WINDOW_TICKS: u64 = 10;

fn window_a(_: u64) callconv(.C) noreturn {
    const p: *volatile u64 = &w_a;
    const w: *volatile i32 = &who;
    const me = tids[0];
    while (p.* < W_ROUNDS) {
        w.* = me;
        p.* +%= 1;
        sched.yield();
    }
    sched.thread_exit(0);
}

fn window_b(_: u64) callconv(.C) noreturn {
    const p: *volatile u64 = &w_b;
    const w: *volatile i32 = &who;
    const me = tids[1];
    while (p.* < W_ROUNDS) {
        w.* = me;
        p.* +%= 1;
        sched.yield();
    }
    sched.thread_exit(0);
}

fn window() void {
    stop = false;
    gave_up = false;
    ticks_used = 0;
    mismatches = 0;
    w_a = 0;
    w_b = 0;
    tids = .{ 0, 0, 0 };

    const before = sched.wrong_stack_ticks;

    const a = sched.spawn_kthread(&window_a, 0, "win-a", .normal) orelse {
        console.println("  [FAIL] scheduler window: no thread");
        return;
    };
    tids[0] = a.tid;
    const b = sched.spawn_kthread(&window_b, 0, "win-b", .normal) orelse {
        console.println("  [FAIL] scheduler window: no second thread");
        stop = true;
        sched.run_queued();
        return;
    };
    tids[1] = b.tid;
    who = a.tid;

    phase = .window;
    sched.preempt_window_spins = WINDOW_SPINS;
    sched.run_queued();
    sched.preempt_window_spins = 0;
    phase = .none;

    const bad = sched.wrong_stack_ticks - before;

    // A run that took no ticks at all would report zero and mean nothing, so
    // how many chances the window had is part of the pass.
    if (!gave_up and bad == 0 and ticks_used >= MIN_WINDOW_TICKS and w_a == W_ROUNDS and w_b == W_ROUNDS) {
        console.print("  [ok] scheduler window: ");
        console.print_dec(w_a + w_b);
        console.print(" switches with the choose-then-switch window held open for ");
        console.print_dec(WINDOW_SPINS);
        console.print(" spins, ");
        console.print_dec(ticks_used);
        console.println(" ticks, every one on the stack the scheduler named");
    } else {
        console.print("  [FAIL] scheduler window: ");
        console.print_dec(bad);
        console.print(" of ");
        console.print_dec(ticks_used);
        console.print(" ticks found the CPU on another thread's stack (a=");
        console.print_dec(w_a);
        console.print(" b=");
        console.print_dec(w_b);
        console.print(" gave_up=");
        console.print_dec(@intFromBool(gave_up));
        console.println(") — yield is missing its guard");
    }
}

// ── Running them ────────────────────────────────────────────────────────

fn nothing(_: u64) callconv(.C) noreturn {
    sched.thread_exit(0);
}

pub fn run() void {
    if (pmm.stats().total_pages == 0) {
        console.println("  [--] no physical memory; the scheduler is not exercised");
        return;
    }

    sched.init();

    // One thread that does nothing but exit, before anything is counted.
    // The first `spawn_kthread` is also the first caller of the kernel heap
    // for a Thread, and a heap that grows takes pages from the same
    // allocator the check below reads — so the snapshot is taken after the
    // heap has been made to grow, not before.
    if (sched.spawn_kthread(&nothing, 0, "warmup", .normal) == null) {
        console.println("  [FAIL] scheduler: could not start a thread at all");
        return;
    }
    sched.run_queued();

    const before = pmm.stats().free_pages;

    rotate();
    priority();
    window();

    const after = pmm.stats().free_pages;
    if (after != before) {
        console.print("  [FAIL] scheduler: thread stacks not reclaimed, ");
        console.print_dec(before);
        console.print(" -> ");
        console.print_dec(after);
        console.println("");
    }
}
