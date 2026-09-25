//! fork, then exec: a process that starts another program without ceasing to
//! be itself.
//!
//! This is the shape every shell is built on and the thing this kernel could
//! not do. `fork` made a second process (#196) and `wait` let the first find
//! out how it went (#197) — but a forked child that called `exec` was killed
//! by it. `exec` leaves EL0 with a path and expects whoever entered the
//! program to load what it names and enter again, and the only loop that did
//! that was the boot path's own. A child's thread has one now.
//!
//! What this will not let pass:
//!
//!   - **a child that ends instead of being replaced.** The child's exit code
//!     has to be /bin/clarity-hello's, which nothing else on this boot uses.
//!     A child killed by its own `exec` comes back as a fault, and the parent
//!     says so.
//!
//!   - **a parent that does not survive.** The whole point is that the caller
//!     is still there afterwards. The probe leaves a number in x25 across
//!     both the fork and the wait and requires it on the other side, and it
//!     writes a line at the end that only a live parent can write.
//!
//!   - **an exec that leaks.** A child replacing its image gives back a
//!     *clone* — pages `clone_user` allocated one at a time, with no loader
//!     behind them — and then, at the end, gives back a *loaded image*, with
//!     ranges and a heap. Freeing either as if it were the other loses pages
//!     or frees them twice, and the page count says which.

const console = @import("arch/aarch64/console.zig");
const paging = @import("arch/aarch64/paging.zig");
const trap = @import("arch/aarch64/trap.zig");
const loader = @import("loader/load_aarch64.zig");
const sched = @import("sched/sched_aarch64.zig");
const heap = @import("mm/heap.zig");
const pmm = @import("mm/pmm.zig");

const FORKEXEC_ELF = @embedFile("forkexec_elf_aarch64");

var parent_ran: bool = false;
var parent_status: u64 = 0;
var parent_code: u64 = 0;

var proc: loader.Loaded = undefined;
var proc_p: ?*sched.Process = null;

fn run_parent(arg: u64) callconv(.C) noreturn {
    _ = arg;
    paging.activate(&proc.space);
    sched.set_current_process(proc_p);

    const out = trap.enter_user_full(proc.entry, proc.user_sp, 0);
    parent_status = out.status;
    parent_code = out.code;
    parent_ran = true;

    sched.set_current_process(null);
    sched.thread_exit(0);
}

pub fn run() void {
    if (pmm.stats().total_pages == 0) return;
    if (!sched.processes_started()) {
        console.println("  [FAIL] fork+exec: no process table");
        return;
    }

    const free_before = pmm.stats().free_pages;
    const asids_before = sched.asids_in_use();
    const execs_before = trap.execs;

    const asid = sched.alloc_asid() orelse {
        console.println("  [FAIL] fork+exec: no ASID left for the parent");
        return;
    };
    proc = loader.load(FORKEXEC_ELF, asid, heap.allocator()) catch |e| {
        console.print("  [FAIL] fork+exec: could not load the probe: ");
        console.println(@errorName(e));
        sched.free_asid(asid);
        return;
    };

    proc_p = sched.register_process("[forkexec]", proc.space, 1, proc.brk_start);
    if (proc_p == null) {
        console.println("  [FAIL] fork+exec: could not register the parent");
        loader.release(&proc, 0);
        sched.free_asid(asid);
        return;
    }

    const t = sched.spawn_kthread(run_parent, 0, "forkexec", .normal) orelse {
        console.println("  [FAIL] fork+exec: could not spawn the parent's thread");
        if (proc_p) |p| sched.exit_process(p, -1);
        loader.release(&proc, 0);
        return;
    };
    t.context.ttbr0 = paging.ttbr_value(&proc.space);

    sched.run_queued();

    var ok = true;

    if (!parent_ran or parent_status != trap.EXIT_DONE or parent_code != 50) {
        console.print("  [FAIL] fork+exec: the parent ran=");
        console.print_dec(@intFromBool(parent_ran));
        console.print(" status=");
        console.print_dec(parent_status);
        console.print(" code=");
        console.print_dec(parent_code);
        console.println(", wanted status=0 code=50");
        if (trap.last_fault) |f| trap.report_fault(f);
        ok = false;
    }

    // Exactly one, and it was the child's. More would mean the parent asked
    // too; none would mean the probe's child never reached its own `exec`,
    // which its exit code would not distinguish from a refusal.
    const execs = trap.execs - execs_before;
    if (execs != 1) {
        console.print("  [FAIL] fork+exec: ");
        console.print_dec(execs);
        console.println(" processes asked to be replaced, wanted exactly 1");
        ok = false;
    }

    const heap_end = if (proc_p) |p| p.brk else proc.brk_start;
    if (proc_p) |p| sched.exit_process(p, @intCast(parent_code)) else sched.free_asid(asid);
    proc_p = null;
    loader.release(&proc, heap_end);

    const asids_after = sched.asids_in_use();
    if (asids_after != asids_before) {
        console.print("  [FAIL] fork+exec: ASIDs leaked — ");
        console.print_dec(asids_before);
        console.print(" in use before, ");
        console.print_dec(asids_after);
        console.println(" after");
        ok = false;
    }

    const free_after = pmm.stats().free_pages;
    console.print("  fork+exec: pages free ");
    console.print_dec(free_before);
    console.print(" before, ");
    console.print_dec(free_after);
    console.println(" after");

    // Two images and a clone were built and given back here. The same bound
    // and the same reasoning as the other two gates: what does not come back
    // is the kernel heap growing a slab, not a process's memory — and the
    // memory is far larger than this, so a free that missed any of it lands
    // well outside.
    const LEAK_MAX: u64 = 4;
    if (free_before > free_after and free_before - free_after > LEAK_MAX) {
        console.print("  [FAIL] fork+exec: pages did not come back — ");
        console.print_dec(free_before - free_after);
        console.println(" lost");
        ok = false;
    }

    if (ok) {
        console.println("  [ok] fork+exec: a process started another program and was still there afterwards");
    }
}
