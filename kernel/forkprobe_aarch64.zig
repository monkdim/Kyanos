//! fork(2) on aarch64: one program, two processes.
//!
//! Everything this kernel has run at EL0 started at an entry point. `fork` is
//! the first call that has to put a process back where it already was — the
//! child is not a program that starts, it is the parent at the instruction
//! after the `svc`, with the parent's registers and a copy of the parent's
//! memory. Three mechanisms had to exist for that:
//!
//!   - **the memory.** `paging.clone_user`, gated separately: every page, at
//!     the same address, with the same rights, in a frame of its own.
//!
//!   - **the register file.** `aarch64_enter_user_frame`, new here. `eret`
//!     into a saved `Frame` rather than into an entry point, so the child
//!     resumes rather than starts.
//!
//!   - **somewhere to run.** A process at EL0 on this architecture is a
//!     nested call some kernel thread is inside, so the second process needs
//!     a second thread, its own ASID, and its own entry in the process table.
//!
//! What this will not let pass:
//!
//!   - **one return.** Both halves write a line naming themselves and exit
//!     with a different code. One line, or one exit code, is a `fork` that
//!     produced one process.
//!
//!   - **a child that starts rather than resumes.** Both halves lay a pattern
//!     into x19, x28, d0 and d20 before the call and check it after. A kernel
//!     that restored only the argument registers — which is all a *call*
//!     needs — passes everything else here and fails this.
//!
//!   - **one page pretending to be two.** The child writes its own number
//!     into the program's data page; the parent requires its own number to
//!     still be there. That check is only worth anything if the child ran
//!     first, so this file does not take the timing on faith: it records
//!     whether the child had already become a zombie at the moment the parent
//!     left EL0, and says so if it had not.
//!
//!   - **a child spending its parent's heap.** `brk` is one break for the
//!     whole kernel. The child asks and must be refused; the parent asks and
//!     must be answered.
//!
//!   - **a fork that leaks.** The child's pages, tables and ASID all come
//!     back, and the boot prints what it counted either way.

const console = @import("arch/aarch64/console.zig");
const paging = @import("arch/aarch64/paging.zig");
const trap = @import("arch/aarch64/trap.zig");
const loader = @import("loader/load_aarch64.zig");
const sched = @import("sched/sched_aarch64.zig");
const heap = @import("mm/heap.zig");
const pmm = @import("mm/pmm.zig");

const FORK_ELF = @embedFile("forkprobe_elf_aarch64");

/// What the parent's half of the run left behind. Filled by the thread that
/// runs it, read by `run` after the queue drains.
var parent_ran: bool = false;
var parent_status: u64 = 0;
var parent_code: u64 = 0;
/// How many children had already exited when the parent left EL0. The
/// ordering the "one page, not two" check depends on.
var zombies_at_parent_exit: usize = 0;

var proc: loader.Loaded = undefined;
var proc_p: ?*sched.Process = null;

/// The parent's whole life on its own kernel thread.
///
/// On a thread and not on the boot path because `fork` needs a current
/// process, and "the current process" is a question only a thread can answer:
/// two threads can be inside `enter_user` at once, so it is a field of the
/// thread and the boot path is not one.
fn run_parent(arg: u64) callconv(.C) noreturn {
    _ = arg;
    paging.activate(&proc.space);
    sched.set_current_process(proc_p);

    const out = trap.enter_user_full(proc.entry, proc.user_sp, 0);

    // Read before anything else can change it: the parent has just exited,
    // and if the child exited first its record is already here.
    if (proc_p) |p| zombies_at_parent_exit = p.zombies.items.len;

    parent_status = out.status;
    parent_code = out.code;
    parent_ran = true;

    // The break is left where the program put it: `run` needs it to know how
    // many heap pages to give back, and clears it afterwards.
    sched.set_current_process(null);
    sched.thread_exit(0);
}

pub fn run() void {
    if (pmm.stats().total_pages == 0) return;
    if (!sched.processes_started()) {
        console.println("  [FAIL] fork: no process table to fork into");
        return;
    }

    const free_before = pmm.stats().free_pages;
    const asids_before = sched.asids_in_use();

    const asid = sched.alloc_asid() orelse {
        console.println("  [FAIL] fork: no ASID left for the parent");
        return;
    };
    proc = loader.load(FORK_ELF, asid, heap.allocator()) catch |e| {
        console.print("  [FAIL] fork: could not load the probe: ");
        console.println(@errorName(e));
        sched.free_asid(asid);
        return;
    };

    proc_p = sched.register_process("[forkprobe]", proc.space, 1, proc.brk_start);
    if (proc_p == null) {
        console.println("  [FAIL] fork: could not register the parent");
        loader.release(&proc, 0);
        sched.free_asid(asid);
        return;
    }

    const t = sched.spawn_kthread(run_parent, 0, "forkprobe", .normal) orelse {
        console.println("  [FAIL] fork: could not spawn the parent's thread");
        if (proc_p) |p| sched.exit_process(p, -1);
        loader.release(&proc, 0);
        return;
    };
    t.context.ttbr0 = paging.ttbr_value(&proc.space);

    // Runs the parent, and the child too: `fork` puts the child's thread on
    // the same queue, so this does not return until both are finished.
    sched.run_queued();
    paging.deactivate();

    var ok = true;

    if (!parent_ran or parent_status != trap.EXIT_DONE or parent_code != 60) {
        console.print("  [FAIL] fork: the parent ran=");
        console.print_dec(@intFromBool(parent_ran));
        console.print(" status=");
        console.print_dec(parent_status);
        console.print(" code=");
        console.print_dec(parent_code);
        console.println(", wanted status=0 code=60");
        // Where, if it faulted. "status=1" on its own is a fact about the
        // kernel's bookkeeping; the exception class and the faulting address
        // are the thing a reader can act on.
        if (trap.last_fault) |f| trap.report_fault(f);
        ok = false;
    }

    // The child, as its parent sees it: a zombie with an exit code. This is
    // the whole of what a second process means from the kernel's side — a
    // second entry that lived, ran and finished.
    var child_code: i32 = -1;
    var child_pid: sched.Pid = 0;
    if (proc_p) |p| {
        if (p.reap_any()) |z| {
            child_code = z.exit_code;
            child_pid = z.pid;
        }
    }

    if (child_pid == 0) {
        console.println("  [FAIL] fork: no second process — the parent has no child to reap");
        ok = false;
    } else if (child_code != 61) {
        console.print("  [FAIL] fork: the child exited ");
        console.print_dec(@as(u64, @bitCast(@as(i64, child_code))));
        console.println(", wanted 61");
        ok = false;
    }

    // Without this the parent's "my page was untouched" is a statement about
    // a child that had not run yet, and would pass on a kernel that shared
    // one page between them.
    if (zombies_at_parent_exit == 0) {
        console.println("  [FAIL] fork: the child had not finished when the parent checked its page — the separation is unproven");
        ok = false;
    }

    // Where the parent's break finished, read while there is still a Process
    // to read it from: `loader.release` needs it to know how many heap pages
    // to give back, and the lines below are what end the process.
    const heap_end = if (proc_p) |p| p.brk else proc.brk_start;

    // One or the other, never both: `exit_process` gives the ASID back as
    // part of ending the process.
    if (proc_p) |p| sched.exit_process(p, @intCast(parent_code)) else sched.free_asid(asid);
    proc_p = null;
    loader.release(&proc, heap_end);

    const asids_after = sched.asids_in_use();
    if (asids_after != asids_before) {
        console.print("  [FAIL] fork: ASIDs leaked — ");
        console.print_dec(asids_before);
        console.print(" in use before, ");
        console.print_dec(asids_after);
        console.println(" after");
        ok = false;
    }

    // Pages. The child's image, its tables and its stack are the kernel's to
    // give back, and a fork that keeps them is invisible until the machine
    // runs out. Reported as a number either way rather than only on failure,
    // because "how much did one fork cost" is the question this is really
    // answering and a silent pass does not answer it.
    const free_after = pmm.stats().free_pages;
    console.print("  fork: pages free ");
    console.print_dec(free_before);
    console.print(" before, ");
    console.print_dec(free_after);
    console.println(" after");

    // What one fork is allowed to cost.
    //
    // Not zero, and the reason is worth being exact about: the two pages this
    // run does not give back are the *kernel heap* growing a slab, for the
    // child's Thread, its Process, its address-space record and the block the
    // frame travelled in. A slab, once grown, keeps its page — so this is a
    // cost of the first fork rather than of every one, and it is not the
    // child's memory.
    //
    // The child's memory is what the bound is for, and it is far larger than
    // this. Measured with `paging.free_user` removed: 128965 free before the
    // fork and 128948 after — seventeen pages, the child's image and stack
    // and the tables that described them, gone for the rest of the boot.
    const LEAK_MAX: u64 = 4;
    if (free_before > free_after and free_before - free_after > LEAK_MAX) {
        console.print("  [FAIL] fork: the child's pages did not come back — ");
        console.print_dec(free_before - free_after);
        console.print(" lost, more than the ");
        console.print_dec(LEAK_MAX);
        console.println(" the kernel heap accounts for");
        ok = false;
    }

    if (ok) {
        console.print("  [ok] fork: two processes from one program — the child (pid ");
        console.print_dec(@intCast(child_pid));
        console.println(") resumed with its parent's registers, in memory of its own, and gave every page back");
    }
}
