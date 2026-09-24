//! wait(2) on aarch64: a parent that sleeps until its child is done.
//!
//! `fork` made a second process. This is the call that tells the first one
//! how the second went — and it is the first system call on this machine that
//! does not return on the spot. The calling thread goes to sleep, something
//! else gets the CPU, and an event on another thread wakes it. `sched.wake`
//! has existed since the scheduler landed with a comment saying nothing
//! called it yet; this is what calls it.
//!
//! What this will not let pass:
//!
//!   - **a wait that does not wait.** The probe's parent calls `wait`
//!     immediately, before the child has run at all, and the child spends
//!     several ticks at EL0 before exiting. A `wait` that reaps a zombie if
//!     one happens to be lying about and answers ECHILD otherwise — which is
//!     what the x86_64 side has — fails on the spot. And `sched.wait_sleeps`
//!     counts the times a wait actually slept: zero means every check below
//!     was answered without anything ever waiting, which is a kernel that
//!     passes for the wrong reason.
//!
//!   - **the wrong child, or no exit code.** The parent requires the PID
//!     `fork` gave it and the code the child exited with, through a pointer
//!     it supplied. A `wait` that returned "a child finished" and nothing
//!     else would satisfy everything but this.
//!
//!   - **a wait with nothing to wait for.** The parent waits a second time
//!     and must be told ECHILD. Sleeping there is the one failure a program
//!     cannot recover from: it never runs again and the boot stops with no
//!     message.
//!
//!   - **a fork that leaks.** As with the fork gate: the child's pages,
//!     tables and ASID all come back.

const console = @import("arch/aarch64/console.zig");
const paging = @import("arch/aarch64/paging.zig");
const trap = @import("arch/aarch64/trap.zig");
const loader = @import("loader/load_aarch64.zig");
const sched = @import("sched/sched_aarch64.zig");
const heap = @import("mm/heap.zig");
const pmm = @import("mm/pmm.zig");

const WAIT_ELF = @embedFile("waitprobe_elf_aarch64");

var parent_ran: bool = false;
/// Whether the parent's thread still believed it was inside a system call
/// once its program was finished. Read on that thread, so it is that
/// thread's own counter and not a question about the machine.
var parent_still_in_syscall: bool = false;
var parent_status: u64 = 0;
var parent_code: u64 = 0;

var proc: loader.Loaded = undefined;
var proc_p: ?*sched.Process = null;

fn run_parent(arg: u64) callconv(.C) noreturn {
    _ = arg;
    paging.activate(&proc.space);
    sched.set_current_process(proc_p);
    trap.set_heap(&proc.space, proc.brk_start);

    const out = trap.enter_user_full(proc.entry, proc.user_sp, 0);
    // Asked here and on this thread, which is the only place it means
    // anything. Its program has left EL0, so nothing on this thread is inside
    // a system call, and the counter that says so has to agree.
    //
    // It did not, for as long as that counter was one variable for the whole
    // kernel. A parent asleep in `wait` is a thread mid-system-call; the
    // child's exit runs `enter_user_frame`, which *sets* the counter to zero
    // because a program that left through `exit` never ran the decrement; the
    // parent then wakes, finishes its call and subtracts one from zero.
    //
    // Which is why this check has never actually fired: putting the one
    // counter back does not reach it, it panics first —
    // `KERNEL PANIC (aarch64): integer overflow`, right here, with the boot
    // stopping at 50 [ok] markers. The check is for a build with the safety
    // checks off, where the same subtraction wraps to 0xFFFFFFFF instead and
    // the only symptom is that EL0 is never preempted again.
    parent_still_in_syscall = trap.in_syscall();
    parent_status = out.status;
    parent_code = out.code;
    parent_ran = true;

    sched.set_current_process(null);
    sched.thread_exit(0);
}

pub fn run() void {
    if (pmm.stats().total_pages == 0) return;
    if (!sched.processes_started()) {
        console.println("  [FAIL] wait: no process table to wait in");
        return;
    }

    const free_before = pmm.stats().free_pages;
    const asids_before = sched.asids_in_use();
    const slept_before = sched.wait_sleeps;

    const asid = sched.alloc_asid() orelse {
        console.println("  [FAIL] wait: no ASID left for the parent");
        return;
    };
    proc = loader.load(WAIT_ELF, asid, heap.allocator()) catch |e| {
        console.print("  [FAIL] wait: could not load the probe: ");
        console.println(@errorName(e));
        sched.free_asid(asid);
        return;
    };

    proc_p = sched.register_process("[waitprobe]", proc.space, 1, proc.brk_start);
    if (proc_p == null) {
        console.println("  [FAIL] wait: could not register the parent");
        loader.release(&proc, 0);
        sched.free_asid(asid);
        return;
    }

    const t = sched.spawn_kthread(run_parent, 0, "waitprobe", .normal) orelse {
        console.println("  [FAIL] wait: could not spawn the parent's thread");
        if (proc_p) |p| sched.exit_process(p, -1);
        loader.release(&proc, 0);
        return;
    };
    t.context.ttbr0 = paging.ttbr_value(&proc.space);

    sched.run_queued();

    var ok = true;

    if (!parent_ran or parent_status != trap.EXIT_DONE or parent_code != 40) {
        console.print("  [FAIL] wait: the parent ran=");
        console.print_dec(@intFromBool(parent_ran));
        console.print(" status=");
        console.print_dec(parent_status);
        console.print(" code=");
        console.print_dec(parent_code);
        console.println(", wanted status=0 code=40");
        if (trap.last_fault) |f| trap.report_fault(f);
        ok = false;
    }

    // The check that separates waiting from looking. Every other check here
    // passes on a kernel whose `wait` never sleeps, as long as the schedule
    // happens to put the child's exit first.
    if (parent_still_in_syscall) {
        console.println("  [FAIL] wait: the parent's thread was still inside a system call after its program finished — the depth counter is shared");
        ok = false;
    }

    const slept = sched.wait_sleeps - slept_before;
    if (slept == 0) {
        console.println("  [FAIL] wait: nothing ever slept — the parent was answered without waiting");
        ok = false;
    }

    if (proc_p) |p| sched.exit_process(p, @intCast(parent_code)) else sched.free_asid(asid);
    proc_p = null;
    loader.release(&proc, trap.heap_end());
    trap.clear_heap();

    const asids_after = sched.asids_in_use();
    if (asids_after != asids_before) {
        console.print("  [FAIL] wait: ASIDs leaked — ");
        console.print_dec(asids_before);
        console.print(" in use before, ");
        console.print_dec(asids_after);
        console.println(" after");
        ok = false;
    }

    const free_after = pmm.stats().free_pages;
    console.print("  wait: pages free ");
    console.print_dec(free_before);
    console.print(" before, ");
    console.print_dec(free_after);
    console.print(" after, slept ");
    console.print_dec(slept);
    console.println(" time(s)");

    // The same bound and the same reasoning as the fork gate: what does not
    // come back is the kernel heap growing a slab, not the child's memory.
    const LEAK_MAX: u64 = 4;
    if (free_before > free_after and free_before - free_after > LEAK_MAX) {
        console.print("  [FAIL] wait: the child's pages did not come back — ");
        console.print_dec(free_before - free_after);
        console.println(" lost");
        ok = false;
    }

    if (ok) {
        console.println("  [ok] wait: the parent slept until its child exited, and was told which child and with what");
    }
}
