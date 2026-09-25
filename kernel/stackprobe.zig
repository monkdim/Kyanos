//! Did every thread that exited get its kernel stack back?
//!
//! Like gsprobe.zig, a tally of the boot rather than a test of its own: a
//! thread's stack can only be freed by some *other* thread, so the question
//! is whether the reap points the scheduler has are enough for the threads
//! this boot actually creates -- which is a property of the whole boot and
//! not of anything a self-contained test could set up.
//!
//! The fork+exec gate counts pages, but only inside its own window. This
//! counts every thread, which is what says the list is drained rather than
//! drained often enough for one measurement to come out right.

const console = @import("arch/x86_64/console.zig");
const sched = @import("sched/scheduler.zig");

pub fn run() void {
    const exited = sched.threads_exited;
    const reaped = sched.stacks_reaped;
    const outstanding = sched.dead_stacks_outstanding();

    if (exited == 0) {
        console.println("  [FAIL] thread stacks: no thread exited, so nothing was checked");
        return;
    }
    if (outstanding != 0 or reaped != exited) {
        console.print("  [FAIL] thread stacks: ");
        console.print_dec(exited);
        console.print(" threads exited but ");
        console.print_dec(reaped);
        console.print(" stacks came back, ");
        console.print_dec(outstanding);
        console.println(" still waiting");
        return;
    }
    console.print("  [ok] thread stacks: ");
    console.print_dec(exited);
    console.println(" threads exited and every one gave its kernel stack back");
}
