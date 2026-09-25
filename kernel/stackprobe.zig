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
//!
//! The structure is counted as well as the stack. Freeing it does not move
//! the fork+exec page count -- the heap reuses chunks and does not return
//! pages, which was measured in its own right ("15 slab pages held, 0 ever
//! returned") -- so a page count is the wrong instrument for it, and this
//! counter is the right one: it says the Thread went back to the allocator,
//! which is what stops a machine that runs programs for a week from holding
//! one structure per program it has ever run.

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
    const freed = sched.threads_freed;
    if (freed != exited) {
        console.print("  [FAIL] thread stacks: ");
        console.print_dec(exited);
        console.print(" threads exited, ");
        console.print_dec(reaped);
        console.print(" stacks came back but only ");
        console.print_dec(freed);
        console.println(" Thread structures did");
        return;
    }
    const ended = sched.processes_ended;
    const p_freed = sched.processes_freed;
    if (ended == 0 or p_freed != ended) {
        console.print("  [FAIL] thread stacks: ");
        console.print_dec(ended);
        console.print(" processes ended but ");
        console.print_dec(p_freed);
        console.println(" were freed");
        return;
    }

    console.print("  [ok] thread stacks: ");
    console.print_dec(exited);
    console.print(" threads exited and every one gave back its kernel stack and its own structure, and all ");
    console.print_dec(ended);
    console.println(" processes gave back theirs");
}
