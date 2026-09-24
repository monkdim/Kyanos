//! Two programs at EL0 at once, and the timer taking the CPU from one and
//! giving it to the other.
//!
//! Everything before this ran one program at a time. `enter_user` was a
//! nested call the boot path made, the program ran to completion, and only
//! then did anything else happen — so a timer tick landing in EL0 was
//! handled, and then handed the CPU straight back to the same program,
//! because there was nothing else to give it to. That is not a scheduler
//! running processes; it is a scheduler that has never been asked.
//!
//! Here each copy of `/bin/clarity-spin` runs on its own kernel thread, in
//! its own address space, under its own ASID, and the run queue decides which
//! of them is on the CPU. Three things had to become per-thread for that to
//! be true rather than merely arranged:
//!
//!   - **the way home.** `aarch64_enter_user` used to save the kernel's
//!     callee-saved registers into one static block, with a comment saying
//!     nothing needed it to nest. Two threads inside `enter_user` do: the
//!     second to enter would write over the first's saved SP, and the first
//!     program to exit would unwind onto the other thread's stack. The area
//!     is now a local in the entering frame, and TPIDR_EL1 says whose.
//!
//!   - **the address space.** `clarity_switch_to` already carried TTBR0, so
//!     this only meant putting each thread's value in its Context — but the
//!     value was never set for a thread that runs a program, because no
//!     thread ever did.
//!
//!   - **the exit code.** `trap.exit_status` is one variable. `enter_user`
//!     returns with interrupts on, so a thread can be preempted between its
//!     own program exiting and its reading of that variable, and come back to
//!     find the other program's code in it. The code travels in the thread's
//!     save area now.
//!
//! **What this test will not let pass.** Both programs finishing is not the
//! claim — they would both finish if the kernel ran them one after the other,
//! which is exactly what it did before. The claim is that they *interleaved*,
//! and the evidence is the order of their writes: `AAAAAAAAAABBBBBBBBBB` is
//! the failure and `AABBAABBA…` is the pass. `trap.writer_trace` records that
//! order and nothing else.

const console = @import("arch/aarch64/console.zig");
const paging = @import("arch/aarch64/paging.zig");
const trap = @import("arch/aarch64/trap.zig");
const loader = @import("loader/load_aarch64.zig");
const sched = @import("sched/sched_aarch64.zig");
const heap = @import("mm/heap.zig");
const pmm = @import("mm/pmm.zig");

const SPIN_ELF = @embedFile("spin_elf_aarch64");

/// Two, because two is the smallest number that can interleave. More would
/// make the trace longer without making it say anything the two do not.
const COPIES: usize = 2;

const Copy = struct {
    proc: loader.Loaded = undefined,
    asid: u16 = 0,
    loaded: bool = false,
    ran: bool = false,
    status: u64 = 0,
    code: u64 = 0,
};

var copies: [COPIES]Copy = .{ .{}, .{} };

/// One kernel thread's whole life: run a program, record what it said, stop.
///
/// It does not `paging.deactivate()` on the way out, and that is deliberate
/// rather than forgotten. Deactivating switches off translation of the low
/// half for the *core*, not for this process — and the other copy may only be
/// preempted, not finished, in which case the next thing it touches at EL0
/// would fault on an address that was fine a moment ago. The boot path
/// deactivates once, after both are done.
fn run_copy(arg: u64) callconv(.C) noreturn {
    const i: usize = @intCast(arg);
    const c = &copies[i];

    // The first entry needs the space installed; every entry after a
    // preemption gets it from this thread's Context, which `spawn` set.
    paging.activate(&c.proc.space);

    // EXPERIMENT: 0x1000 apart, so the two programs' stack pointers are
    // distinguishable numbers. Both are inside the stack the loader mapped.
    const sp = c.proc.user_sp - @as(u64, i) * 0x1000;
    const out = trap.enter_user_full(c.proc.entry, sp, arg);
    c.status = out.status;
    c.code = out.code;
    c.ran = true;

    sched.thread_exit(0);
}

/// How many times the writer changed between one write and the next.
///
/// One transition is two programs run back to back. Anything more is the
/// timer having taken the CPU away from a program that never offered it,
/// which is the thing under test.
fn switches(trace: []const u8) usize {
    if (trace.len < 2) return 0;
    var n: usize = 0;
    var i: usize = 1;
    while (i < trace.len) : (i += 1) {
        if (trace[i] != trace[i - 1]) n += 1;
    }
    return n;
}

fn count_of(trace: []const u8, ch: u8) usize {
    var n: usize = 0;
    for (trace) |c| {
        if (c == ch) n += 1;
    }
    return n;
}

pub fn run() void {
    if (pmm.stats().total_pages == 0) return;

    console.print("  two programs: ");
    console.print_dec(SPIN_ELF.len);
    console.println(" bytes, loaded twice, one kernel thread each");

    // Load both before either runs. Loading inside the thread would work, but
    // it would also mean a failure to load showed up as a thread that quietly
    // did nothing, and "the boot said nothing" is the one outcome a selftest
    // must never have.
    var i: usize = 0;
    while (i < COPIES) : (i += 1) {
        const c = &copies[i];
        c.asid = sched.alloc_asid() orelse {
            console.println("  [FAIL] two programs: no ASID left — the pool is 255 deep");
            return release(i);
        };
        c.proc = loader.load(SPIN_ELF, c.asid, heap.allocator()) catch |e| {
            console.print("  [FAIL] two programs: could not load copy ");
            console.print_dec(i);
            console.print(": ");
            console.println(@errorName(e));
            sched.free_asid(c.asid);
            c.asid = 0;
            return release(i);
        };
        c.loaded = true;
    }

    // Both threads at the same priority, so which one runs next is the round
    // robin's decision and not a ranking this test arranged.
    i = 0;
    while (i < COPIES) : (i += 1) {
        const t = sched.spawn_kthread(run_copy, i, "spin", .normal) orelse {
            console.print("  [FAIL] two programs: could not spawn thread ");
            console.print_dec(i);
            console.println("");
            return release(COPIES);
        };
        // The address space this thread comes back to after a preemption.
        // Without it `clarity_switch_to` leaves TTBR0 holding whichever space
        // was last installed, and the resumed program runs in the other
        // program's memory — reading its bytes rather than faulting, which is
        // the kind of wrong that does not announce itself.
        t.context.ttbr0 = paging.ttbr_value(&copies[i].proc.space);
    }

    trap.writer_trace_reset();
    sched.run_queued();
    const trace = trap.writer_trace_stop();

    console.println("");
    console.print("  two programs: wrote ");
    print_trace(trace);

    var ok = true;
    i = 0;
    while (i < COPIES) : (i += 1) {
        const c = &copies[i];
        const want: u64 = 70 + @as(u64, @intCast(i));
        if (!c.ran or c.status != trap.EXIT_DONE or c.code != want) {
            console.print("  [FAIL] two programs: copy ");
            console.print_dec(i);
            console.print(" ran=");
            console.print_dec(@intFromBool(c.ran));
            console.print(" status=");
            console.print_dec(c.status);
            console.print(" code=");
            console.print_dec(c.code);
            console.print(", wanted status=0 code=");
            console.print_dec(want);
            console.println("");
            ok = false;
        }
    }

    const a = count_of(trace, 'A');
    const b = count_of(trace, 'B');
    if (a != 10 or b != 10) {
        console.print("  [FAIL] two programs: each should have written ten times — A wrote ");
        console.print_dec(a);
        console.print(", B wrote ");
        console.print_dec(b);
        console.println("");
        ok = false;
    }

    // Two programs run one after the other change writer exactly once. This
    // is the assertion the whole change exists to satisfy, and the only one
    // that fails on a kernel that runs them both correctly but never
    // preempts either.
    const sw = switches(trace);
    if (sw < 2) {
        console.print("  [FAIL] two programs: they did not interleave — the writer changed ");
        console.print_dec(sw);
        console.println(" time(s), so one ran to the end before the other started");
        ok = false;
    }

    if (ok) {
        console.print("  [ok] two programs: ran at once, the writer changed ");
        console.print_dec(sw);
        console.println(" times — the timer moved the CPU between them");
    }

    release(COPIES);
}

fn print_trace(trace: []const u8) void {
    console.print(trace);
    console.println("");
}

/// Give back everything the first `n` copies took. Called on every exit from
/// `run`, including the ones that failed partway: an ASID that is never
/// released is invisible until the 256th process is refused.
fn release(n: usize) void {
    // Once, after both threads are finished with EL0 — see run_copy.
    paging.deactivate();

    var i: usize = 0;
    while (i < n and i < COPIES) : (i += 1) {
        const c = &copies[i];
        if (c.loaded) {
            loader.release(&c.proc, c.proc.brk_start);
            c.loaded = false;
        }
        if (c.asid != 0) {
            sched.free_asid(c.asid);
            c.asid = 0;
        }
    }
}
