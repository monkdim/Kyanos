//! Two ways of taking the CPU away from a kernel thread on AArch64.
//!
//! Counterpart to threadtest.zig and preempttest.zig on the x86_64 side, and
//! kept together because both rest on the same piece of assembly: the
//! cooperative case is a thread calling `switch_to` itself, and the
//! preemptive case is the timer's interrupt handler calling it on the
//! thread's behalf. The second is the one that matters and the one that is
//! easy to fake — so it is built so that it cannot be.
//!
//! The preemption test's threads never yield. Neither one calls `switch_to`,
//! looks at a flag, or cooperates in any way; each spins incrementing its own
//! counter. The second counter can only move if something took the CPU away
//! from the first, which is the same principle the x86 test uses and the
//! reason two well-behaved threads cannot pass it by taking turns.

const console = @import("arch/aarch64/console.zig");
const context = @import("arch/aarch64/context.zig");
const pmm = @import("mm/pmm.zig");
const vm = @import("arch/aarch64/vm.zig");
const timer = @import("arch/aarch64/timer.zig");

/// Two pages each. A kernel thread here does very little, but a stack that is
/// one page short of enough does not report anything — it runs into whatever
/// is below it.
const STACK_PAGES: usize = 2;

// ── Cooperative ─────────────────────────────────────────────────────────

var ctx_main: context.Context = .{};
var ctx_a: context.Context = .{};
var ctx_b: context.Context = .{};

/// What ran, in order. An alternating sequence is the thing to check: a
/// switch that went nowhere would leave one letter repeated, and a switch
/// that lost the thread would leave the trace short.
var trace: [16]u8 = undefined;
var trace_len: usize = 0;

fn note(c: u8) void {
    if (trace_len < trace.len) {
        trace[trace_len] = c;
        trace_len += 1;
    }
}

const ROUNDS: usize = 3;

fn thread_a(_: u64) callconv(.C) noreturn {
    var i: usize = 0;
    while (i < ROUNDS) : (i += 1) {
        note('A');
        context.switch_to(&ctx_a, &ctx_b);
    }
    note('a');
    // Hand the CPU back to whoever started this. Looping rather than
    // returning because there is nowhere to return to: this thread was
    // entered through a trampoline that has no caller.
    while (true) context.switch_to(&ctx_a, &ctx_main);
}

fn thread_b(_: u64) callconv(.C) noreturn {
    while (true) {
        note('B');
        context.switch_to(&ctx_b, &ctx_a);
    }
}

// ── Preemptive ──────────────────────────────────────────────────────────

var ctx_pa: context.Context = .{};
var ctx_pb: context.Context = .{};

var running: bool = false;
var current: u8 = 0;
var spins_a: u64 = 0;
var spins_b: u64 = 0;
var preemptions: u64 = 0;
var ticks_used: u64 = 0;
var gave_up: bool = false;

/// Which thread's *code* is currently executing, written by that code itself
/// on every pass round its loop.
///
/// This is what makes the test able to tell a real preemption from a
/// plausible-looking one. `current` is the kernel's belief about who is
/// running; `who` is the running code's own account of itself. They can
/// disagree, and the way they disagree is specific: taking an exception from
/// EL0 or EL1 puts the return address in ELR_EL1 and the saved state in
/// SPSR_EL1, which are one pair of registers for the whole CPU. If the vector
/// entry leaves them there across a thread switch, the next thread to `eret`
/// returns to whatever address the most recent exception left behind —
/// somewhere in the *other* thread's code, running on this thread's stack.
///
/// Counters alone cannot see that: both threads' loops would still be
/// executing and both counters would still climb. This can.
var who: u64 = 0;
var mismatches: u64 = 0;

/// How far each thread has to get. Small: at 100 Hz each thread does millions
/// of increments per tick, so anything reachable at all is reached in the
/// first one.
const WANT: u64 = 1000;

/// How many times the CPU has to change hands before this counts as working.
///
/// Both counters pass WANT within a tick or two, so stopping there would
/// prove exactly one switch — enough to say the mechanism fired once, not
/// enough to say a thread can be preempted repeatedly and keep running. Six
/// is three turns each.
const MIN_SWITCHES: u64 = 6;

/// A ceiling in timer ticks, so that a preemption path that does not work
/// reports rather than hangs. Two seconds at 100 Hz — hundreds of times what
/// the test needs, and the difference between a failing boot log and a boot
/// that stops with nothing on the screen.
const TICK_LIMIT: u64 = 200;

fn spin_a(_: u64) callconv(.C) noreturn {
    const p: *volatile u64 = &spins_a;
    const w: *volatile u64 = &who;
    while (true) {
        w.* = 1;
        p.* +%= 1;
    }
}

fn spin_b(_: u64) callconv(.C) noreturn {
    const p: *volatile u64 = &spins_b;
    const w: *volatile u64 = &who;
    while (true) {
        w.* = 2;
        p.* +%= 1;
    }
}

/// Called from the timer interrupt, after the interrupt itself has been
/// handled and acknowledged. Interrupts are masked here — the CPU masked them
/// on the way into the vector — which is what makes the bookkeeping below
/// safe without a lock.
pub fn on_tick() void {
    if (!running) return;
    ticks_used += 1;

    const a: *volatile u64 = &spins_a;
    const b: *volatile u64 = &spins_b;

    // Whoever the kernel thinks is running had better be the one whose code
    // is actually executing.
    const w: *volatile u64 = &who;
    if (w.* != current) mismatches += 1;

    const done = a.* >= WANT and b.* >= WANT and preemptions >= MIN_SWITCHES;

    if (done or ticks_used > TICK_LIMIT) {
        // The allocator's racers are not stopped where they stand; they are
        // asked, and stop at the top of their own loop. Until both have,
        // this tick's work is to keep handing them the CPU.
        if (in_race and !park_racers()) return;
        gave_up = !done;
        running = false;
        const leaving = if (current == 1) &ctx_pa else &ctx_pb;
        context.switch_to(leaving, &ctx_main);
        return;
    }

    preemptions += 1;
    switch_threads();
}

/// Hand the CPU from whichever of the two threads is running to the other.
fn switch_threads() void {
    if (current == 1) {
        current = 2;
        context.switch_to(&ctx_pa, &ctx_pb);
    } else {
        current = 1;
        context.switch_to(&ctx_pb, &ctx_pa);
    }
}

// ── The allocator under two threads ─────────────────────────────────────
//
// The page allocator's test-and-set was unguarded, and nothing could reach
// it: every allocation happened on the boot path, where preemption is a
// no-op. A scheduler is what reaches it, so the guard had to exist before
// the scheduler did — and a guard nothing can demonstrate the need for is
// indistinguishable from one that does nothing.
//
// So this runs the allocator from the two threads above, which the timer
// switches between, and looks for the failure itself rather than a proxy for
// it: each thread stamps its own byte into the page it was given, holds it,
// and reads it back. The other thread's byte means both were handed the same
// page while both still held it.
//
// **With pmm.race_window_spins at zero this test cannot fail, and that is
// measured, not assumed.** Two threads against the real allocator managed
// 57,605 allocations with no collision, because the window between the test
// and the set is about five instructions and a tick lands in it roughly once
// in 1e5 slices. A test built that way passes with the guard and without it.
// So the window is widened deliberately while the test runs, which makes the
// difference plain: with the widening and no guard, 24 pages out of 33,998
// allocations went to both threads at once.

/// Long enough that a tick lands in the window nearly every time, short
/// enough that the threads still get through thousands of allocations inside
/// the tick limit.
const RACE_WINDOW_SPINS: u32 = 3000;

var race_allocs: u64 = 0;
var race_collisions: u64 = 0;
var race_refused: u64 = 0;

/// Which of the two tests the tick handler is supervising. The racers stop
/// differently from the spinners, and only they need the extra step.
var in_race: bool = false;

/// Set when the racers are to stop; each sets its own `race_parked` entry
/// once it has, at the top of its loop.
var race_stopping: bool = false;
var race_parked: [2]bool = .{ false, false };
var race_unparked: bool = false;

/// How many extra ticks the racers get to reach the top of their loops. Each
/// needs at most one slice, so this is a wide margin — and a ceiling rather
/// than a wait, so a racer that somehow never parks reports instead of
/// hanging the boot.
const PARK_TICKS: u64 = 10;

/// Ask both racers to stop, and keep handing them the CPU until they have.
/// Returns true once neither is running any more.
///
/// The obvious thing is to switch away from whichever racer is running and
/// call the test over, which is what this did — and it left two pages out on
/// every boot. A racer is between its `alloc_page` and its `free_page` for
/// most of its loop, because holding the page is the whole point: that is
/// what gives the other thread time to collide with it. Stopped there, it
/// still owns a page and nothing else knows which. The boot said so —
/// `[FAIL] thread stacks leaked: 129232 -> 129230`, two pages, one per racer
/// — and the gate could not see it, because the gate only looked for the
/// markers it expected.
///
/// So the stop is asked for. Each racer checks the flag at the top of its
/// loop, which is the one point in it where it holds nothing, and parks
/// there. Recording the page in a global and freeing it afterwards would
/// have left a window of a couple of instructions between the allocation and
/// the record — the kind of rarely-wrong that a gate run thousands of times
/// finds eventually.
fn park_racers() bool {
    race_stopping = true;
    const parked: *volatile [2]bool = &race_parked;
    if (parked[0] and parked[1]) return true;
    if (ticks_used > TICK_LIMIT + PARK_TICKS) {
        race_unparked = true;
        return true;
    }
    switch_threads();
    return false;
}

/// Allocate, stamp, hold, check, free — forever, until the timer stops us.
fn racer(id: u8, mine: u64, counter: *volatile u64) noreturn {
    const w: *volatile u64 = &who;
    const total: *volatile u64 = &race_allocs;
    const bad: *volatile u64 = &race_collisions;
    const refused: *volatile u64 = &race_refused;
    const stopping: *volatile bool = &race_stopping;
    const parked: *volatile bool = &race_parked[mine - 1];
    while (true) {
        // The top of the loop is the only point in it where this thread
        // holds no page, so it is where it agrees to stop. It never runs
        // again afterwards: the supervisor switches away for the last time
        // once both racers are here.
        if (stopping.*) {
            parked.* = true;
            while (true) asm volatile ("" ::: "memory");
        }
        w.* = mine;
        counter.* +%= 1;
        const phys = pmm.alloc_page() orelse {
            refused.* +%= 1;
            continue;
        };
        const cell: *volatile u8 = @ptrFromInt(vm.phys_to_virt(phys));
        cell.* = id;
        // Holding the page is what gives the *other* thread's allocation time
        // to collide with this one. Without it the two would have to be
        // inside alloc_page simultaneously, which is a far narrower target.
        var k: usize = 0;
        while (k < 400) : (k += 1) asm volatile ("" ::: "memory");
        if (cell.* != id) bad.* +%= 1;
        pmm.free_page(phys);
        total.* +%= 1;
    }
}

fn race_a(_: u64) callconv(.C) noreturn {
    racer(0xA1, 1, &spins_a);
}

fn race_b(_: u64) callconv(.C) noreturn {
    racer(0xB2, 2, &spins_b);
}

fn allocator_race() void {
    const stack_a = alloc_stack() orelse {
        console.println("  [FAIL] allocator race: no stack");
        return;
    };
    const stack_b = alloc_stack() orelse {
        free_stack(stack_a);
        console.println("  [FAIL] allocator race: no stack");
        return;
    };

    spins_a = 0;
    spins_b = 0;
    who = 1;
    mismatches = 0;
    preemptions = 0;
    ticks_used = 0;
    gave_up = false;
    race_allocs = 0;
    race_collisions = 0;
    race_refused = 0;
    race_stopping = false;
    race_parked = .{ false, false };
    race_unparked = false;
    in_race = true;

    context.init_kernel_thread(&ctx_pa, stack_a, &race_a, 0);
    context.init_kernel_thread(&ctx_pb, stack_b, &race_b, 0);

    pmm.race_window_spins = RACE_WINDOW_SPINS;
    current = 1;
    running = true;
    context.switch_to(&ctx_main, &ctx_pa);
    // The timer handler switched back here.
    pmm.race_window_spins = 0;
    in_race = false;

    const allocs = race_allocs;
    const bad = race_collisions;

    // A run that allocated almost nothing would report zero collisions and
    // mean nothing, so the count it managed is part of the pass.
    const MIN_ALLOCS: u64 = 2000;
    if (race_unparked) {
        // At least one racer did not reach the top of its loop within
        // PARK_TICKS, so it is still holding a page and the leak check below
        // will say so. Said here as well, because "two pages short" on its
        // own does not name a cause.
        console.println("  [FAIL] allocator under two threads: a racer never parked");
    } else if (bad == 0 and allocs >= MIN_ALLOCS) {
        console.print("  [ok] allocator under two threads: ");
        console.print_dec(allocs);
        console.print(" alloc/free pairs with the race window held open, ");
        console.println("no page handed to two threads");
    } else {
        console.print("  [FAIL] allocator under two threads: ");
        console.print_dec(bad);
        console.print(" of ");
        console.print_dec(allocs);
        console.print(" allocations handed the same page to both (");
        console.print_dec(race_refused);
        console.println(" refused) — the page allocator is missing its lock");
    }

    free_stack(stack_a);
    free_stack(stack_b);
}

// ── Running them ────────────────────────────────────────────────────────

fn alloc_stack() ?u64 {
    const phys = pmm.alloc_pages(STACK_PAGES) orelse return null;
    return vm.phys_to_virt(phys) + STACK_PAGES * pmm.PAGE_SIZE;
}

fn free_stack(stack_top: u64) void {
    const base = vm.virt_to_phys(stack_top - STACK_PAGES * pmm.PAGE_SIZE);
    var i: usize = 0;
    while (i < STACK_PAGES) : (i += 1) pmm.free_page(base + i * pmm.PAGE_SIZE);
}

pub fn run() void {
    if (pmm.stats().total_pages == 0) {
        console.println("  [--] no physical memory; thread switching not exercised");
        return;
    }
    const before = pmm.stats();

    cooperative();
    preemptive();
    allocator_race();

    const after = pmm.stats();
    if (after.free_pages != before.free_pages) {
        console.print("  [FAIL] thread stacks leaked: ");
        console.print_dec(before.free_pages);
        console.print(" -> ");
        console.print_dec(after.free_pages);
        console.println("");
    }
}

fn cooperative() void {
    const stack_a = alloc_stack() orelse {
        console.println("  [FAIL] context switch: no stack for thread A");
        return;
    };
    const stack_b = alloc_stack() orelse {
        console.println("  [FAIL] context switch: no stack for thread B");
        return;
    };

    trace_len = 0;
    context.init_kernel_thread(&ctx_a, stack_a, &thread_a, 0);
    context.init_kernel_thread(&ctx_b, stack_b, &thread_b, 0);

    context.switch_to(&ctx_main, &ctx_a);

    // Back here only because thread A switched to ctx_main, which it does
    // only after both threads have taken their turns.
    const want = "ABABABa";
    var ok = trace_len == want.len;
    if (ok) {
        for (want, 0..) |c, i| {
            if (trace[i] != c) ok = false;
        }
    }

    if (ok) {
        console.print("  [ok] context switch: ");
        console.print(trace[0..trace_len]);
        console.println(" — two threads alternated and handed the CPU back");
    } else {
        console.print("  [FAIL] context switch: trace was \"");
        console.print(trace[0..trace_len]);
        console.print("\", wanted \"");
        console.print(want);
        console.println("\"");
    }

    free_stack(stack_a);
    free_stack(stack_b);
}

fn preemptive() void {
    const stack_a = alloc_stack() orelse {
        console.println("  [FAIL] preemption: no stack");
        return;
    };
    const stack_b = alloc_stack() orelse {
        console.println("  [FAIL] preemption: no stack");
        return;
    };

    spins_a = 0;
    spins_b = 0;
    who = 1;
    mismatches = 0;
    preemptions = 0;
    ticks_used = 0;
    gave_up = false;
    in_race = false;

    context.init_kernel_thread(&ctx_pa, stack_a, &spin_a, 0);
    context.init_kernel_thread(&ctx_pb, stack_b, &spin_b, 0);

    const ticks_before = timer.ticks();
    current = 1;
    running = true;
    context.switch_to(&ctx_main, &ctx_pa);
    // The timer handler switched back here.

    const a = spins_a;
    const b = spins_b;
    const ticks_after = timer.ticks();

    if (!gave_up and a >= WANT and b >= WANT and preemptions >= MIN_SWITCHES and mismatches == 0) {
        console.print("  [ok] preemption: B ran (");
        console.print_dec(b);
        console.print(") while A (");
        console.print_dec(a);
        console.print(") never yielded — ");
        console.print_dec(preemptions);
        console.print(" switches in ");
        console.print_dec(ticks_after - ticks_before);
        console.println(" ticks, each thread resuming in its own code");
    } else {
        console.print("  [FAIL] preemption: a=");
        console.print_dec(a);
        console.print(" b=");
        console.print_dec(b);
        console.print(" switches=");
        console.print_dec(preemptions);
        console.print(" wrong_thread_resumed=");
        console.print_dec(mismatches);
        console.print(" gave_up=");
        console.print_dec(@intFromBool(gave_up));
        console.println("");
    }

    free_stack(stack_a);
    free_stack(stack_b);
}
