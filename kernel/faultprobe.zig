//! What happens to a program that faults — and to everything else.
//!
//! Every other gate on this boot runs a program that behaves. This one runs
//! `/bin/clarity-faultprobe`, which writes through a null pointer, and asks
//! the only two questions that matter about a kernel serving other people's
//! code:
//!
//!   - **did the program die?** It has to, and with something that says it
//!     was killed rather than that it chose to leave. Nothing else on this
//!     boot exits with the code it would have used had the store somehow
//!     worked, so "it faulted" and "it finished" are distinguishable.
//!
//!   - **did anything else?** This is the question the gate exists for.
//!     `idt.dispatch` used to treat every vector below 32 the same way,
//!     without looking at the ring the trap came from, and `report` ends in
//!     `cli; hlt`. So a user program's bad pointer stopped the machine. The
//!     check is not a marker printed by this file — it is that the boot has
//!     lines after it at all, which the workflow asserts by grepping for a
//!     marker printed later.
//!
//! The gate deliberately runs *before* the shell and the tally gates rather
//! than last, so that a regression takes those down with it and is impossible
//! to miss.

const console = @import("arch/x86_64/console.zig");
const vfs = @import("fs/vfs.zig");
const sched = @import("sched/scheduler.zig");
const pmm = @import("mm/pmm.zig");

pub const PATH = "/bin/clarity-faultprobe";

const IMAGE: []const u8 = @embedFile("faultprobe_elf");

/// What `sched.exit` is given when a process is killed rather than leaving of
/// its own accord. Negative because an exit code a program can produce is a
/// `u8` on every system that has one, so nothing a program says can be
/// mistaken for this.
const KILLED: i32 = -1;

/// `console.print_dec` takes a `u64`, and an exit code is signed — so the
/// code a killed process gets printed through it reads as 4294967295, which
/// is the right bits and the wrong number.
fn print_signed(v: i32) void {
    if (v < 0) {
        console.print("-");
        console.print_dec(@intCast(-@as(i64, v)));
        return;
    }
    console.print_dec(@intCast(v));
}

fn install() !void {
    const fd = try vfs.open(PATH, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), IMAGE);
    try vfs.close(@intCast(fd));
    if (n != IMAGE.len) return error.ShortWrite;
}

pub fn run() void {
    install() catch |e| {
        console.print("  [FAIL] fault: could not install the probe: ");
        console.println(@errorName(e));
        return;
    };

    // Drained before the sample below, and this is the difference between a
    // number about this process and a number about the boot. A gate that
    // ended a thread leaves its kernel stack on the dead list until somebody
    // reaches `yield`, and the somebody is this gate's own `run_queued` --
    // so without this the window closes 21 pages *up*, and the reading says
    // more about what the previous gate left than about what this one did.
    sched.run_queued();
    const free_before = pmm.stats().free_pages;

    const started = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] fault: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };
    // The id and not the pointer: `run_queued` can free the Thread.
    const tid = started.tid;
    const faults_before = sched.user_faults;

    sched.run_queued();

    // Reaching this line at all is most of the measurement. Before this
    // change the machine stopped inside `run_queued` and nothing below ever
    // ran, so there is no assertion here that could have failed -- the boot
    // simply ended.
    var ok = true;

    const faults = sched.user_faults - faults_before;
    if (faults != 1) {
        console.print("  [FAIL] fault: ");
        console.print_dec(faults);
        console.println(" processes were killed by a fault, wanted exactly 1");
        ok = false;
    }

    const code = sched.exit_code_of(tid);
    if (code == null or code.? != KILLED) {
        console.print("  [FAIL] fault: the program ended with ");
        if (code) |c| print_signed(c) else console.print("nothing");
        console.print(", wanted the code a killed process gets (");
        print_signed(KILLED);
        console.println(")");
        ok = false;
    }

    // And that killing a process is not a way of leaking one. `sched.exit`
    // hands the pages back whoever called it, which is an argument and not a
    // measurement — so the same question the fork+exec gate asks is asked
    // here, with the same bound and for the same reason: what does not come
    // back is the kernel heap holding a slab, and a process's own memory is
    // far larger than that, so a kill that skipped it lands well outside.
    const free_after = pmm.stats().free_pages;
    console.print("  fault: pages free ");
    console.print_dec(free_before);
    console.print(" before, ");
    console.print_dec(free_after);
    console.println(" after");

    const LEAK_MAX: u64 = 4;
    if (free_before > free_after and free_before - free_after > LEAK_MAX) {
        console.print("  [FAIL] fault: the killed program's pages did not come back — ");
        console.print_dec(free_before - free_after);
        console.println(" lost");
        ok = false;
    }

    if (ok) {
        console.println("  [ok] fault: a program wrote through a null pointer, the kernel killed it, the boot carried on, and its memory came back");
    }
}
