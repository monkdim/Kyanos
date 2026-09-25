//! Does a thread that goes to sleep ever wake up?
//!
//! `sched.WaitReason` has had a `sleep_until: u64` variant since the process
//! model landed, and across the whole kernel there were exactly two mentions
//! of it: the declaration, and `sys_nanosleep` blocking a thread on it with a
//! deadline of zero. Nothing woke one. `wake` was called for `waitpid` and
//! for nothing else.
//!
//! So this gate asks the question directly, and the first thing it measures
//! is whether the boot gets past it at all: a program that sleeps and is
//! never woken takes its thread off the run queue forever, and `run_queued`
//! below does not return until the queue drains.
//!
//! Two numbers, because "it woke" and "it slept" are different claims and
//! only one of them is interesting on its own. A kernel that ignored the
//! request entirely would also report that the program woke.

const console = @import("arch/x86_64/console.zig");
const vfs = @import("fs/vfs.zig");
const sched = @import("sched/scheduler.zig");
const timer = @import("arch/x86_64/timer.zig");

pub const PATH = "/bin/clarity-sleepprobe";

const IMAGE: []const u8 = @embedFile("sleepprobe_elf");

/// What the probe exits with, and what it asked for. Both have to be here
/// rather than only in the program: a gate that takes the program's word for
/// how long it slept is measuring the program.
const WOKE: i32 = 64;
const NAP_CENTIS: u64 = 10;

fn install() !void {
    const fd = try vfs.open(PATH, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), IMAGE);
    try vfs.close(@intCast(fd));
    if (n != IMAGE.len) return error.ShortWrite;
}

pub fn run() void {
    install() catch |e| {
        console.print("  [FAIL] sleep: could not install the probe: ");
        console.println(@errorName(e));
        return;
    };

    const started = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] sleep: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };
    const tid = started.tid;
    const before = timer.centiseconds();
    const woken_before = sched.sleepers_woken;

    sched.run_queued();

    const elapsed = timer.centiseconds() - before;
    var ok = true;

    const code = sched.exit_code_of(tid);
    if (code == null or code.? != WOKE) {
        console.print("  [FAIL] sleep: the program ended with ");
        if (code) |c| console.print_dec(@intCast(@as(u32, @bitCast(c)))) else console.print("nothing");
        console.println(", wanted 64 — which only a program that woke can reach");
        ok = false;
    }

    // It has to have *taken* about that long. A kernel that returned from
    // nanosleep on the spot would satisfy every other check here, and the
    // whole request would be a no-op nobody noticed.
    if (elapsed < NAP_CENTIS) {
        console.print("  [FAIL] sleep: the whole thing took ");
        console.print_dec(elapsed);
        console.print(" hundredths of a second, and the sleep alone asked for ");
        console.print_dec(NAP_CENTIS);
        console.println(" — so it was not served");
        ok = false;
    }

    // And the timer has to be the thing that woke it. Without this a sleep
    // that some other path happened to cut short would read as a success.
    const woken = sched.sleepers_woken - woken_before;
    if (woken != 1) {
        console.print("  [FAIL] sleep: the timer woke ");
        console.print_dec(woken);
        console.println(" sleeping threads, wanted exactly 1");
        ok = false;
    }

    if (ok) {
        console.print("  [ok] sleep: a program asked for ");
        console.print_dec(NAP_CENTIS);
        console.print(" hundredths of a second, the timer woke it after ");
        console.print_dec(elapsed);
        console.println(", and it carried on");
    }
}
