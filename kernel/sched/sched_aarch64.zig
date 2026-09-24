//! The AArch64 scheduler: run queues, priorities, and a timer that drives
//! them.
//!
//! What was here before was the switching *primitive* and two hand-wired
//! contexts. `arch/aarch64/context.S` can put a thread back where it left
//! off, and `threadtest_aarch64.zig` drove it directly: two globals named
//! `ctx_pa` and `ctx_pb`, a `current` that was a `u8`, and a timer handler
//! that flipped between them. That is enough to prove the mechanism works
//! and not enough to run anything — a third thread had nowhere to go, a
//! thread that finished had no way to say so, and "which thread runs next"
//! was a hard-coded `if`.
//!
//! So: a `Thread` with a name, a priority and a state; three run queues; a
//! `yield` that picks a successor and switches to it; and a `preempt` the
//! timer calls. The ordering itself is `sched/runqueue.zig`, shared with the
//! x86_64 scheduler, because two copies of a scheduling policy are two
//! policies.
//!
//! **This is not `sched/scheduler.zig` with the architecture swapped.** That
//! one carries `fork`, `exec`, `waitpid`, an ELF loader, an IRET frame and a
//! process table, all of which are about *processes* and most of which are
//! x86-shaped. This is the thread half only, which is what this architecture
//! has needed since the first `switch_to` landed. Processes come next, and
//! when they do the two should become one file rather than three.
//!
//! **Interrupt safety.** Everything below runs either on a thread with
//! interrupts unmasked or inside the timer's handler with them masked, and
//! the run queues are touched from both. `sync/irqlock.zig` is what makes
//! that safe, the same guard the page allocator takes: on one core, masking
//! interrupts is the lock.
//!
//! The guard is held *across* the switch, which needs saying because the two
//! mechanisms interlock. `clarity_switch_to` masks interrupts itself, writes
//! the outgoing thread's DAIF onto that thread's own stack, and restores the
//! incoming thread's on its way out. So a thread resumed inside `yield`
//! comes back masked exactly as it left, its deferred release puts back what
//! it had before yielding, and a brand-new thread starts unmasked because
//! `init_kernel_thread` wrote a zero into that slot. Nothing is left holding
//! a mask that belongs to another thread.

const context = @import("../arch/aarch64/context.zig");
const runqueue = @import("runqueue.zig");
const irqlock = @import("../sync/irqlock.zig");
const pmm = @import("../mm/pmm.zig");
const heap = @import("../mm/heap.zig");
const vm = @import("../arch/aarch64/vm.zig");
const console = @import("../arch/aarch64/console.zig");
const paging = @import("../arch/aarch64/paging.zig");
const trap = @import("../arch/aarch64/trap.zig");
// The loader and the filesystem, because a thread running a user process has
// to be able to replace that process's image: `exec` leaves EL0 with a path
// and expects whoever is running the program to load what it names. On the
// boot path that is `run_until_done` in main_aarch64.zig; for a forked child
// it is `fork_child_entry` below, and there is nowhere else for it to be.
const loader = @import("../loader/load_aarch64.zig");
const vfs = @import("../fs/vfs.zig");

pub const Priority = enum(u8) {
    high = 0,
    normal = 1,
    idle = 2,

    pub fn count() usize {
        return 3;
    }
};

pub const State = enum(u8) {
    /// On a run queue, waiting for a turn.
    runnable,
    /// Has the CPU right now. Exactly one thread is in this state.
    running,
    /// Off the run queues until something wakes it.
    blocked,
    /// Finished. Its stack and its Thread are freed by whichever thread runs
    /// next — never by itself, because it is standing on the stack.
    zombie,
};

pub const Tid = i32;

/// The longest path a process may hand `exec`. `trap.PATH_MAX`, kept here
/// rather than imported to stop the Thread's size depending on a cycle.
pub const EXEC_PATH_MAX: usize = 256;

/// Sixteen kilobytes. A kernel thread here does very little, but a stack one
/// page short of enough does not report anything: it runs into whatever is
/// below it.
pub const STACK_PAGES: usize = 4;

pub const Thread = struct {
    tid: Tid,
    name: []const u8,
    priority: Priority,
    state: State,
    context: context.Context = .{},
    /// One past the highest byte of this thread's stack, as a direct-map
    /// address. Zero for the boot path, which did not allocate one.
    stack_top: u64 = 0,
    next: ?*Thread = null,
    ticks_run: u64 = 0,
    exit_code: i32 = 0,

    /// The process running at EL0 on this thread, if there is one.
    ///
    /// Per-thread and not a module variable, for the reason every other
    /// piece of this got moved onto the thread before it: two threads can be
    /// inside `enter_user` at once, so "the current process" is only a
    /// question with an answer once it is asked of a thread. `fork` is the
    /// first caller that needs it — a child has to know whose child it is,
    /// and the only thing that knows is the thread the parent's `svc` was
    /// serviced on.
    proc: ?*Process = null,

    /// Whether this thread is inside a system call: 0 or 1. Read by the
    /// timer's handler through `trap.in_syscall`, which is what decides
    /// whether a time slice may end here. Per-thread for the reason set out
    /// over `trap.syscall_depth` — one counter shared by two threads goes
    /// below zero the first time a program exits while another thread is
    /// mid-call, which panics this build and silently kills preemption in one
    /// without the safety checks.
    syscall_depth: u32 = 0,

    /// Which child this thread is blocked in `wait` for: a PID, or 0 for
    /// "any", or 0 when it is not waiting at all. Meaningful only while the
    /// thread is on the `waiters` list.
    /// What this thread's process last asked `exec` for.
    ///
    /// Per-thread for the same reason as everything else here: the path is
    /// copied out of the process inside the system call and read by whatever
    /// runs the process *after* it has left EL0, and a thread can be
    /// preempted between those two points. One buffer for the kernel means
    /// two processes exec'ing at once can each be handed the other's path,
    /// which `fork` plus `exec` is exactly the arrangement for. Nothing has
    /// been seen to do it; the buffer costs 264 bytes a thread and removes
    /// the question.
    exec_path: [EXEC_PATH_MAX]u8 = undefined,
    exec_path_len: usize = 0,

    wait_for: Pid = 0,
    /// The next thread on the `waiters` list. Separate from `next`, which
    /// belongs to the run queues: a waiting thread is on neither queue, and
    /// borrowing the same field would mean the two lists could never both be
    /// right.
    wait_next: ?*Thread = null,
};

const Queues = runqueue.MultiQueue(Thread, 3);

var queues: Queues = .{};
var current: ?*Thread = null;
var next_tid: Tid = 1;

/// Threads that have exited and whose stacks nobody has been able to free
/// yet, because the thread was still standing on one when it said so. See
/// `reap`.
var dead: ?*Thread = null;

/// The context the boot path is running on.
///
/// `yield` needs somewhere to save the caller's registers before any Thread
/// exists, and this is it: the kernel's initial stack behaves as thread zero.
/// `x30` is zero until something has switched *away* from the boot path,
/// which is how `yield` knows whether there is a boot coroutine to go back
/// to — without that check, a thread that exits with nothing left to run
/// would "return to boot" by jumping to address zero.
var boot_context: context.Context = .{};

pub fn init() void {
    queues.clear();
    current = null;
    dead = null;
    next_tid = 1;
    boot_context = .{};
}

pub fn current_thread() ?*Thread {
    return current;
}

/// The process the boot path is running at EL0.
///
/// The boot path is not a Thread — it is the kernel's initial stack, running
/// before and between the run queue's turns — so it has a slot of its own,
/// exactly as it has one for the system-call depth. Most of the programs on
/// this machine still run from there.
var boot_proc: ?*Process = null;

/// The process whoever is asking is running at EL0, if any.
///
/// Null on a kernel thread that was never given a process, and on the boot
/// path before it loads one. A `fork` from either is refused rather than
/// guessed at: a child with an invented parent would be reparented to init
/// the moment anything exited, and nothing would say why.
pub fn current_process() ?*Process {
    if (current) |t| return t.proc;
    return boot_proc;
}

/// Say whose program is about to run here.
///
/// The one call that says it. It used to be two — this and `trap.set_heap`,
/// which said the same thing in different words and could disagree — and the
/// heap is a field of the Process now, so there is nothing left for the
/// second one to carry.
pub fn set_current_process(p: ?*Process) void {
    if (current) |t| {
        t.proc = p;
        return;
    }
    boot_proc = p;

    // And the boot context's address space, which is the same statement made
    // to the other half of the machine.
    //
    // A Thread carries its TTBR0 in its Context and `clarity_switch_to` puts
    // it back; the boot path's context carried a zero, which means "leave
    // TTBR0 alone". That was true for as long as the boot path never gave up
    // the CPU while it had a program at EL0 — and then `wait` did. The shell
    // runs from the boot path; its `run` forks, waits, and the wait yields to
    // the child's thread, which installs the child's address space. Coming
    // back, the core was still in it: the shell carried on at EL0 reading a
    // *copy* of its own memory, frozen at the fork and then freed.
    //
    // Measured, from the serial test: the shell's second `run` printed the
    // first one's path spliced with fragments of older lines —
    // "run: cannot run /nope", then "lo.txt", then "ial — no such file".
    boot_context.ttbr0 = if (p) |pp| paging.ttbr_value(pp.address_space) else 0;
}

pub fn queue_len(p: Priority) usize {
    return queues.len(@intFromEnum(p));
}

pub fn runnable_count() usize {
    return queues.total();
}

// ── Making threads ──────────────────────────────────────────────────────

/// Start a kernel thread at `entry`, which receives `arg`. It is runnable
/// the moment this returns; nothing runs it until something yields.
pub fn spawn_kthread(
    entry: *const fn (u64) callconv(.C) noreturn,
    arg: u64,
    name: []const u8,
    priority: Priority,
) ?*Thread {
    const raw = heap.alloc(@sizeOf(Thread)) orelse return null;
    const t: *Thread = @ptrCast(@alignCast(raw));

    const stack_phys = pmm.alloc_pages(STACK_PAGES) orelse {
        heap.free(raw, @sizeOf(Thread));
        return null;
    };
    const stack_top = vm.phys_to_virt(stack_phys) + STACK_PAGES * pmm.PAGE_SIZE;

    t.* = .{
        .tid = next_tid,
        .name = name,
        .priority = priority,
        .state = .runnable,
        .stack_top = stack_top,
    };
    next_tid += 1;
    context.init_kernel_thread(&t.context, stack_top, entry, arg);

    const guard = irqlock.acquire();
    defer guard.release();
    queues.enqueue(t, @intFromEnum(priority));
    return t;
}

/// Free the threads that have exited. Called from a thread that is not one
/// of them, which is the whole reason this is separate from `thread_exit`:
/// a thread cannot free the stack it is standing on.
fn reap() void {
    const guard = irqlock.acquire();
    var list = dead;
    dead = null;
    guard.release();

    while (list) |t| {
        const nxt = t.next;
        if (t.stack_top != 0) {
            const base = vm.virt_to_phys(t.stack_top - STACK_PAGES * pmm.PAGE_SIZE);
            var i: usize = 0;
            while (i < STACK_PAGES) : (i += 1) pmm.free_page(base + i * pmm.PAGE_SIZE);
        }
        heap.free(@as([*]u8, @ptrCast(t)), @sizeOf(Thread));
        list = nxt;
    }
}

// ── The window between choosing and switching ───────────────────────────
//
// `yield` sets `current = next` and then switches to it, and between those
// two the scheduler's belief and the machine disagree: the successor is
// named as running while the CPU is still on the predecessor's stack. A tick
// landing there re-enters `yield` with `prev` set to a thread that is not
// running, and saves the caller's stack and resume address into that
// thread's context.
//
// The guard in `yield` closes it. The x86_64 scheduler had the same window
// open, and it was not theoretical there: one boot in forty-nine died with a
// general protection fault at the `iretq` at the end of its timer handler.
// The window is a handful of instructions wide, so waiting for it is not a
// test. The same two pieces as on that side make it one.

/// Spins inserted between `current = next` and the switch that makes it
/// true. Only the boot selftest ever sets it.
pub var preempt_window_spins: u32 = 0;

/// Ticks that arrived while the CPU was not on the stack of the thread
/// `current` names. Counted on every tick of every boot, not only while the
/// selftest runs: it costs one compare, and an invariant that is checked
/// only when someone remembers to look is not an invariant.
pub var wrong_stack_ticks: u64 = 0;

fn widen_preempt_window() void {
    var i: u32 = 0;
    while (i < preempt_window_spins) : (i += 1) asm volatile ("" ::: "memory");
}

/// Ask, from the timer's handler, whether the thread the scheduler believes
/// is running is the one whose stack the CPU is standing on.
///
/// Called before `preempt`, so it sees the state the tick arrived in. The
/// boot path has no Thread, so `current` is null there and there is nothing
/// to disagree with.
pub fn check_on_stack() void {
    const c = current orelse return;
    if (c.stack_top == 0) return;
    const sp = asm volatile ("mov %[out], sp"
        : [out] "=r" (-> u64),
    );
    const bottom = c.stack_top - STACK_PAGES * pmm.PAGE_SIZE;
    if (sp < bottom or sp >= c.stack_top) wrong_stack_ticks +%= 1;
}

// ── Switching ───────────────────────────────────────────────────────────

/// Give up the CPU: pick the next runnable thread and switch to it. Returns
/// when something switches back to the caller.
///
/// The caller goes back on its own queue *before* a successor is chosen, so
/// a lone runnable thread yields to itself rather than finding nothing.
pub fn yield() void {
    // Held across the switch, and that is the interesting part. `switch_to`
    // saves the outgoing thread's DAIF on its own stack and restores the
    // *incoming* thread's on the way out, so a thread resumed here comes
    // back with interrupts masked exactly as it left them, and this deferred
    // release then puts back what the caller had before it yielded. Dropping
    // the guard before the switch instead would leave a window where
    // `current` already names the successor while the CPU is still on this
    // thread's stack — a tick landing there would save this thread's
    // registers into the successor's context.
    const guard = irqlock.acquire();
    defer guard.release();

    const prev = current;
    const prev_ctx: *context.Context = if (prev) |p| &p.context else &boot_context;

    if (prev) |p| {
        if (p.state == .running) {
            p.state = .runnable;
            queues.enqueue(p, @intFromEnum(p.priority));
        }
    }

    if (queues.pick()) |next| {
        next.state = .running;
        current = next;
        if (preempt_window_spins != 0) widen_preempt_window();
        context.switch_to(prev_ctx, &next.context);
        // Back here because something switched to this thread again. It is
        // now standing on its own stack, so any thread that died meanwhile
        // can have its stack taken away.
        reap();
        return;
    }

    // Nothing else is runnable.
    if (prev) |p| {
        if (p.state != .running and boot_context.x30 != 0) {
            // The caller is finished and there is no successor, so go back to
            // the boot path — the one that started the run queue, and which
            // can carry on without any of this.
            current = null;
            context.switch_to(&p.context, &boot_context);
            return;
        }
    }
    // The caller is still runnable and simply has the CPU to itself.
}

/// Preempt the running thread. Called from the timer's interrupt handler,
/// after the interrupt has been acknowledged and ended at the GIC.
///
/// Switching from inside a handler is safe because every thread has its own
/// stack: the exception frame stays on the preempted thread's, and when
/// something switches back, execution resumes in this call, returns through
/// the handler and leaves by that thread's own `eret` with its own frame.
///
/// Only threads are preempted. The boot path has no Thread, so switching
/// away from it would strand the boot sequence with nothing able to resume
/// it — which is why this checks rather than calling `yield` unconditionally.
pub fn preempt() void {
    const c = current orelse return;
    c.ticks_run +%= 1;
    yield();
}

/// What the timer's handler calls: check the invariant first, then preempt.
/// One call rather than two so the order cannot be got wrong — the check is
/// only meaningful before anything has been moved.
pub fn tick() void {
    check_on_stack();
    preempt();
}

/// End the calling thread. It never runs again, so this does not return.
pub fn thread_exit(code: i32) noreturn {
    {
        const guard = irqlock.acquire();
        defer guard.release();
        if (current) |c| {
            c.state = .zombie;
            c.exit_code = code;
            // Onto the dead list rather than freed here: this thread is
            // standing on the stack that would be freed.
            c.next = dead;
            dead = c;
        }
    }
    yield();
    // Only reached if there was nowhere at all to go, which means the boot
    // path is gone too and nothing is left to run.
    while (true) asm volatile ("wfi");
}

pub fn block() void {
    {
        const guard = irqlock.acquire();
        defer guard.release();
        if (current) |c| c.state = .blocked;
    }
    yield();
}

pub fn wake(t: *Thread) void {
    const guard = irqlock.acquire();
    defer guard.release();
    if (t.state != .blocked) return;
    t.state = .runnable;
    queues.enqueue(t, @intFromEnum(t.priority));
}

/// Is anything waiting to run? Under the guard, because the boot path asks
/// this with interrupts on while the timer's handler is moving threads
/// between `current` and the queues.
///
/// It is safe without it *today*, and that is exactly why it has it: the only
/// thing that can enqueue from an interrupt is `wake`, nothing calls `wake`
/// on this architecture yet, and `preempt` returns immediately when the boot
/// path is running because the boot path has no Thread. All three of those
/// are facts about other code. The guard makes the answer a property of this
/// function instead.
fn anything_runnable() bool {
    const guard = irqlock.acquire();
    defer guard.release();
    return queues.any();
}

/// Hand the CPU to the run queue and come back when it drains. This is how
/// the boot path runs kernel threads to completion before carrying on.
pub fn run_queued() void {
    while (anything_runnable()) yield();
    // The boot context is a resume point on *this* frame, and it stops being
    // one the moment this call returns. Left set, a thread that exits later
    // would find it, switch "back to boot", and resume inside a run_queued
    // that already finished — re-running whatever the boot path did next.
    boot_context.x30 = 0;
    reap();
}

/// Print what the scheduler is holding. Used by the selftest and by anything
/// trying to understand a boot that stopped.
pub fn dump(prefix: []const u8) void {
    console.print(prefix);
    console.print(" high=");
    console.print_dec(queue_len(.high));
    console.print(" normal=");
    console.print_dec(queue_len(.normal));
    console.print(" idle=");
    console.print_dec(queue_len(.idle));
    console.print(" current=");
    if (current) |c| console.print_dec(@intCast(c.tid)) else console.print("none");
    console.println("");
}

// ── Processes ───────────────────────────────────────────────────────────
//
// Threads are above; this is the other half. A process is an address space
// with an identity: a PID, a parent, the children it is answerable for, and
// a break that `brk` moves. The model itself is `sched/process.zig`, shared
// with the x86_64 scheduler and told here what an address space is on this
// architecture.
//
// Until now this side had no process identity at all. A program was loaded,
// entered, and released, and the ASID it ran under was a literal at the call
// site — 5 for the Clarity demo, 7 for the shell. Two programs alive at once
// with the same number would each see the other's cached translations, and
// nothing anywhere was keeping track. `arch/aarch64/paging.zig` says as much
// where it defines `AddressSpace`: the ASID "becomes a recycling problem
// ... That belongs with the process table, which does not exist on this
// architecture yet." It does now, and the recycling is below.

const procmodel = @import("process.zig").Model(paging.AddressSpace);
pub const Process = procmodel.Process;
pub const ProcessTable = procmodel.Table;
pub const Pid = @import("process.zig").Pid;

pub var processes: ProcessTable = undefined;
var processes_ready: bool = false;

// ── ASIDs ───────────────────────────────────────────────────────────────
//
// TCR_EL1.AS is clear in `boot.S` — TCR_VALUE sets no bit 36 — so an ASID is
// **eight bits**, and there are 256 of them, not 65,536. That is the whole
// reason this is an allocator rather than a counter: `next_asid += 1` is
// correct for exactly 255 processes and then silently hands the 256th an
// ASID that is still live, and two address spaces answer to one tag.
//
// Zero is not handed out. `paging.deactivate` writes TTBR0_EL1 = 0, which is
// ASID 0 with a null root, so zero means "no process" and giving it to one
// would make those two states indistinguishable.
//
// A free list is the right shape here and a generation counter is not. A
// generation counter exists for kernels with more live processes than ASIDs,
// where a number has to be taken back from a process that is still using it.
// With 255 available and a hard refusal at the 256th, no live process ever
// loses its ASID, so there is nothing to generation-stamp. If this machine
// ever needs a 256th process, the honest change is to set TCR_EL1.AS and get
// 16 bits, and only after that to recycle under generations.
const ASID_COUNT: usize = 256;
const ASID_FIRST: u16 = 1;

var asid_taken: [ASID_COUNT]bool = [_]bool{false} ** ASID_COUNT;
var asid_hint: u16 = ASID_FIRST;

/// Take an unused ASID, or nothing if all 255 are live.
pub fn alloc_asid() ?u16 {
    const guard = irqlock.acquire();
    defer guard.release();
    var tries: usize = 0;
    var a = asid_hint;
    while (tries < ASID_COUNT - 1) : (tries += 1) {
        if (a < ASID_FIRST) a = ASID_FIRST;
        if (!asid_taken[a]) {
            asid_taken[a] = true;
            asid_hint = if (a + 1 >= ASID_COUNT) ASID_FIRST else a + 1;
            return a;
        }
        a = if (a + 1 >= ASID_COUNT) ASID_FIRST else a + 1;
    }
    return null;
}

/// Give an ASID back, after throwing away every translation cached under it.
///
/// The invalidation is the part that matters and the part this boot cannot
/// prove it needs. `tlbi aside1is` drops every entry tagged with this ASID
/// across the inner-shareable domain; without it, the next process handed
/// the same number inherits whatever the last one left in the TLB and reads
/// its memory. QEMU under TCG does not model a TLB faithfully enough to
/// show that — the selftest below passes with this line removed — so it is
/// here because the architecture requires it, and that is said plainly
/// rather than implied by a test that would pass either way.
/// Throw away every translation cached under this ASID, without giving the
/// number back.
///
/// What `exec` needs: the process keeps its identity and its ASID — it is
/// the same process — but its address space is replaced wholesale, so every
/// entry the hardware cached for the old one is now a lie. Freeing and
/// re-allocating would do the same invalidation and then very likely hand
/// back the same number anyway; this says what is meant.
pub fn flush_asid(a: u16) void {
    if (a < ASID_FIRST or a >= ASID_COUNT) return;
    asm volatile (
        \\dsb ishst
        \\tlbi aside1is, %[op]
        \\dsb ish
        \\isb
        :
        : [op] "r" (@as(u64, a) << 48),
        : "memory"
    );
}

pub fn free_asid(a: u16) void {
    if (a < ASID_FIRST or a >= ASID_COUNT) return;
    asm volatile (
        \\dsb ishst
        \\tlbi aside1is, %[op]
        \\dsb ish
        \\isb
        :
        : [op] "r" (@as(u64, a) << 48),
        : "memory"
    );
    const guard = irqlock.acquire();
    defer guard.release();
    asid_taken[a] = false;
}

/// How many ASIDs are live. For the selftest, and for anything trying to
/// understand a refusal to start a process.
pub fn asids_in_use() usize {
    const guard = irqlock.acquire();
    defer guard.release();
    var n: usize = 0;
    for (asid_taken) |t| {
        if (t) n += 1;
    }
    return n;
}

/// Start the process table and the init process.
///
/// The allocator is handed over here rather than in a separate call that
/// something has to remember to make. On the x86_64 side that separate call
/// existed and nothing invoked it, so the table's `std.mem.Allocator` kept
/// its .bss value — a null vtable pointer — and the first spawn loaded a
/// function pointer from physical page 0 and jumped into the real-mode
/// interrupt vector table. One kernel heap, one place that says so.
pub fn init_processes() void {
    processes = ProcessTable.init(heap.allocator());
    asid_taken = [_]bool{false} ** ASID_COUNT;
    asid_hint = ASID_FIRST;
    processes_ready = true;

    // PID 1 has to exist before anything can be reparented to it:
    // `reparent_children` looks init up and gives up quietly if it is not
    // there, so without this an orphan would keep pointing at a dead parent
    // and nothing would say so.
    //
    // It stands for the boot path, which owns no user address space — root 0
    // and ASID 0, which is what `paging.deactivate` leaves in TTBR0_EL1 and
    // means "no process is current". That is why zero is never handed out.
    const gpa = processes.gpa;
    const held = gpa.create(paging.AddressSpace) catch return;
    held.* = .{ .root_phys = 0, .asid = 0 };
    const p = gpa.create(Process) catch {
        gpa.destroy(held);
        return;
    };
    p.* = .{
        .pid = processes.init_pid,
        .parent_pid = 0,
        .name = "init",
        .address_space = held,
        .state = .running,
    };
    processes.register(p) catch {
        gpa.destroy(p);
        gpa.destroy(held);
    };
}

pub fn processes_started() bool {
    return processes_ready;
}

/// Register a process for an address space the loader has already built.
///
/// `space` is copied into storage the Process owns, because the loader
/// returns its `AddressSpace` by value on this architecture and the caller's
/// copy goes out of scope.
pub fn register_process(
    name: []const u8,
    space: paging.AddressSpace,
    parent: Pid,
    brk_start: u64,
) ?*Process {
    if (!processes_ready) return null;
    const gpa = processes.gpa;
    const held = gpa.create(paging.AddressSpace) catch return null;
    held.* = space;
    const p = gpa.create(Process) catch {
        gpa.destroy(held);
        return null;
    };
    p.* = .{
        .pid = processes.alloc_pid(),
        .parent_pid = parent,
        .name = name,
        .address_space = held,
        .state = .runnable,
        .brk = brk_start,
        .brk_start = brk_start,
    };
    processes.register(p) catch {
        gpa.destroy(p);
        gpa.destroy(held);
        return null;
    };
    if (parent != 0) {
        if (processes.lookup(parent)) |par| {
            par.add_child(p.pid, gpa) catch {};
        }
    }
    return p;
}

/// A process is over: record it against its parent, hand its children to
/// init, give back its ASID, and take it out of the table.
///
/// The Process itself is not freed here — it is the zombie its parent will
/// reap, and `Table.remove` plus the parent's `reap_pid` is what ends it.
pub fn exit_process(p: *Process, code: i32) void {
    p.state = .zombie;
    p.exit_code = code;
    processes.reparent_children(p) catch {};
    if (processes.lookup(p.parent_pid)) |parent| {
        parent.record_zombie(p.*, processes.gpa) catch {};
        _ = parent.remove_child(p.pid);
    }
    // After the zombie is recorded rather than before.
    //
    // Which is an ordering this code cannot currently be caught getting
    // wrong, and that is worth saying rather than implying otherwise: moving
    // this line above the `record_zombie` was tried and the gate still
    // passed, because nothing between the two yields — the woken parent is
    // only marked runnable and does not get the CPU until well after the
    // record. It is written this way because the property the waiter needs
    // is "there is something to reap when you are told to look", and that
    // should not depend on which lines happen to be between these two.
    wake_waiters_for(p.parent_pid, p.pid);
    free_asid(p.address_space.asid);
    processes.remove(p.pid);
}

// ── fork ────────────────────────────────────────────────────────────────
//
// A child is not a program that starts. It is a process that was already
// running and now exists twice, and everything here follows from that.
//
// Three things make the second one: a copy of every page the first has
// (`paging.clone_user`), a copy of the register file it was stopped in
// (`trap.Frame`, handed over by the system call), and a kernel thread to run
// it on — because on this architecture a process at EL0 is a nested call some
// kernel thread is inside, so a second process needs a second thread to be
// inside that call.
//
// The only difference the kernel writes between the two is the saved x0: the
// child's `fork` returns zero and the parent's returns the child's PID. That
// one value is the entire mechanism by which a program can tell which half of
// itself it is.

/// What a forked child needs in order to start being itself, waiting on the
/// kernel heap for the thread that will run it.
///
/// The frame is first on purpose: `enter_user_frame` copies it to an aligned
/// stack local before the assembly touches it, so nothing here depends on
/// what the heap happens to return, but a reader looking for the vector file
/// should find it at a round offset.
const ForkChild = struct {
    frame: trap.Frame,
    user_sp: u64,
    proc: *Process,
};

/// fork(2): the calling process, twice. Returns the child's PID, or null if
/// the kernel could not make one.
///
/// Refused rather than guessed at when the caller has no process — the boot
/// path, or a kernel thread nobody told. A child invented with init for a
/// parent would be reparented the moment anything exited and nothing would
/// ever say why.
pub fn fork(frame: *const trap.Frame, user_sp: u64) ?Pid {
    if (!processes_ready) return null;
    const parent = current_process() orelse return null;

    const asid = alloc_asid() orelse return null;
    var space = paging.create(asid) orelse {
        free_asid(asid);
        return null;
    };
    paging.clone_user(parent.address_space, &space) catch {
        // Whatever was copied before it ran out. `free_user` frees by walking
        // the tables, so a half-built space gives back exactly the half it
        // has.
        paging.free_user(&space);
        free_asid(asid);
        return null;
    };

    const raw = heap.alloc(@sizeOf(ForkChild)) orelse {
        paging.free_user(&space);
        free_asid(asid);
        return null;
    };
    const c: *ForkChild = @ptrCast(@alignCast(raw));

    // `register_process` copies the space into storage the Process owns, so
    // from here on `child.address_space` is the one that counts and the local
    // is stale. Freeing through the local after this point would leave the
    // Process holding freed pages.
    const child = register_process(parent.name, space, parent.pid, parent.brk_start) orelse {
        heap.free(raw, @sizeOf(ForkChild));
        paging.free_user(&space);
        free_asid(asid);
        return null;
    };

    c.* = .{ .frame = frame.*, .user_sp = user_sp, .proc = child };
    // The whole of what makes the two processes distinguishable.
    c.frame.x[0] = 0;

    // Spawning and finishing the thread off are one step, with interrupts
    // held down across both.
    //
    // `spawn_kthread` puts the thread on a run queue, and the next tick can
    // pick it. If that happened before the two lines below, the child would
    // be resumed by `clarity_switch_to` with a Context whose `ttbr0` is still
    // zero — which means "leave TTBR0 alone", so the child would go back to
    // EL0 in *its parent's* address space and read its parent's memory
    // instead of faulting. A handful of instructions wide, and the kind of
    // wrong that does not announce itself.
    const guard = irqlock.acquire();
    defer guard.release();

    const t = spawn_kthread(fork_child_entry, @intFromPtr(c), "[fork]", .normal) orelse {
        unregister(child);
        heap.free(raw, @sizeOf(ForkChild));
        return null;
    };
    // The address space rides in the Context, so the child comes back into
    // its own tables after every preemption and not into whichever process
    // ran last.
    t.context.ttbr0 = paging.ttbr_value(child.address_space);
    t.proc = child;

    return child.pid;
}

/// Undo `register_process` for a child that never ran.
///
/// Not `exit_process`: that records a zombie against the parent, and a fork
/// that failed produced no process for the parent to reap. The parent is told
/// by the return value of `fork` and by nothing else.
fn unregister(p: *Process) void {
    const gpa = processes.gpa;
    if (processes.lookup(p.parent_pid)) |parent| _ = parent.remove_child(p.pid);
    processes.remove(p.pid);
    paging.free_user(p.address_space);
    free_asid(p.address_space.asid);
    gpa.destroy(p.address_space);
    gpa.destroy(p);
}

/// Load what `exec` named, into a space of its own.
///
/// Returns null when the image cannot be had. `sys_exec` checked the path
/// resolves before it left EL0, so by the time this fails the process has
/// already asked to stop being what it was — but it has not been taken apart
/// yet, which is why the caller frees the old image only after this returns
/// something.
fn load_exec_image(path: []const u8, asid: u16) ?loader.Loaded {
    const image = vfs.read_file_into_heap(path, heap.allocator()) catch return null;
    defer heap.allocator().free(image);
    return loader.load(image, asid, heap.allocator()) catch null;
}

/// Give back whatever the process is currently running.
///
/// Two shapes, and they are freed differently. A forked child starts as a
/// *clone*: a space whose pages were allocated one at a time by `clone_user`,
/// with no loader behind them and no record of what they are except the
/// tables themselves. After an `exec` it is a `loader.Loaded`, with ranges
/// the loader wrote down and a heap that grew past them. Freeing one as if it
/// were the other loses pages or frees pages twice.
fn release_current_image(image: *?loader.Loaded, p: *Process) void {
    if (image.*) |*l| {
        loader.release(l, p.brk);
        image.* = null;
    } else {
        paging.free_user(p.address_space);
    }
}

/// One forked child's whole life on its own kernel thread.
fn fork_child_entry(arg: u64) callconv(.C) noreturn {
    const c: *ForkChild = @ptrFromInt(arg);
    const p = c.proc;

    if (current) |t| t.proc = p;
    paging.activate(p.address_space);
    p.state = .running;

    // What the child is running. Null while it is still its parent's copy.
    var image: ?loader.Loaded = null;

    var out = trap.enter_user_frame(&c.frame, c.user_sp);

    // And the loop that makes `exec` mean something here.
    //
    // A process at EL0 on this architecture is a nested call, so `exec`
    // cannot be a call that never returns the way it is on x86_64 — it leaves
    // EL0 with a third status and expects whoever entered the program to load
    // what it named and enter again. Until now the only such loop was the
    // boot path's, so a forked child that exec'd simply ended: it asked to
    // become something else and the kernel killed it instead. This is the
    // same loop, on the thread that owns the child.
    while (out.status == trap.EXIT_EXEC) {
        const next = load_exec_image(trap.exec_path(), p.address_space.asid) orelse {
            // Past the point of no return. The path resolved when `sys_exec`
            // checked it and does not now, or there is no memory for the
            // image; either way this process asked to stop being what it was
            // and there is nothing to make it into.
            out = .{ .status = trap.EXIT_FAULT, .code = 0 };
            break;
        };

        // The old image goes now and not before, so a load that failed above
        // still leaves a process to report on.
        paging.deactivate();
        release_current_image(&image, p);
        // Same process and same ASID, a wholly different address space — so
        // everything the hardware cached under that tag is a lie.
        flush_asid(p.address_space.asid);

        image = next;
        // The Process's own copy of the space, and its break. Both, and this
        // is where the boot path's loop got it wrong for as long as nothing
        // read them: a Process left pointing at the image it just replaced
        // maps its next heap page into freed tables.
        p.address_space.* = next.space;
        p.brk_start = next.brk_start;
        p.brk = next.brk_start;

        paging.activate(p.address_space);
        out = trap.enter_user_full(next.entry, next.user_sp, 0);
    }

    const code: i32 = switch (out.status) {
        trap.EXIT_DONE => @bitCast(@as(u32, @truncate(out.code))),
        else => -1,
    };

    // The pages go back without a `paging.deactivate()` first, and that is
    // the one thing about this function that is not obvious.
    //
    // Deactivating sets TCR_EL1.EPD0 as well as clearing TTBR0, and
    // `clarity_switch_to` restores TTBR0 and nothing else — so a thread that
    // deactivates on its way out takes the low half away from every process
    // that is merely *preempted*, and the next one to be resumed faults on
    // its own text. Measured, not reasoned about: with the deactivate here
    // the parent came back from its spin to an instruction abort at
    // pc=0x40100134 touching 0x40100134, which is the spin loop itself. The
    // comment on `paging.ttbr_value` says exactly this, and `run_copy` in
    // userpreempt_aarch64.zig already declined to deactivate for the same
    // reason. It is the boot path's business, once nothing is runnable.
    //
    // What is left behind is a TTBR0 naming tables that have just been freed,
    // until the next switch overwrites it. Nothing walks it in between: the
    // kernel lives in TTBR1 and never dereferences a user address — PSTATE.PAN
    // makes sure of it — and no EL0 runs on this thread again.
    release_current_image(&image, p);

    // The Process becomes a zombie its parent can reap, which is why the
    // pages go first: a zombie holds an exit code and a PID and no memory.
    const gpa = processes.gpa;
    exit_process(p, code);

    // And then the Process struct itself, because after `exit_process` there
    // is nothing left that can reach it: `record_zombie` copies the PID, the
    // exit code and the name into the parent's list *by value*, and
    // `Table.remove` drops the only other pointer. The thread's own is
    // cleared just below. Freed here rather than left for a reaper because a
    // fork that leaks one of these per child leaks it forever — the boot
    // path's own exit does the same and is a separate thing to fix.
    if (current) |t| t.proc = null;
    p.children.deinit(gpa);
    p.zombies.deinit(gpa);
    p.fd_table.deinit(gpa);
    gpa.destroy(p.address_space);
    gpa.destroy(p);

    heap.free(@as([*]u8, @ptrCast(c)), @sizeOf(ForkChild));
    thread_exit(0);
}

// ── wait ────────────────────────────────────────────────────────────────
//
// `fork` gave a parent a second process and no way to find out how it went.
// This is the other half: a call that does not return until a child has
// exited, and then says which one and with what.
//
// "Does not return" is the whole of what is new. Every system call this
// kernel has had could be answered on the spot; this one has to put the
// calling thread to sleep and let something else have the CPU, and be woken
// by an event on another thread. `sched.wake` has existed since the scheduler
// landed with a comment saying nothing called it yet. Something does now.

/// Threads asleep in `wait`, linked by `wait_next`. Not a queue — the order
/// does not matter, and there is no fairness question while a parent can have
/// only one thread.
var waiters: ?*Thread = null;

pub const Waited = struct { pid: Pid, exit_code: i32 };

/// How many times a `wait` has actually gone to sleep.
///
/// The difference between this call and the one the x86_64 side has, which
/// reaps a zombie if there happens to be one and answers ECHILD otherwise. A
/// parent that waits immediately after forking finds no zombie, so a boot
/// where this is still zero is a boot where `wait` never waited — and every
/// other check a test could make would pass on such a kernel.
pub var wait_sleeps: u64 = 0;

/// Reap a child of `p`: the named one, or any if `target` is not positive.
fn reap_zombie(p: *Process, target: Pid) ?Waited {
    const z = (if (target <= 0) p.reap_any() else p.reap_pid(target)) orelse return null;
    return .{ .pid = z.pid, .exit_code = z.exit_code };
}

/// Does `p` still have a child worth waiting for?
///
/// Asked only after `reap_zombie` has already said no, so a child that has
/// exited and been recorded is not in this list any more — `exit_process`
/// takes it out when it records the zombie.
fn has_child(p: *const Process, target: Pid) bool {
    if (target <= 0) return p.children.items.len > 0;
    for (p.children.items) |c| {
        if (c == target) return true;
    }
    return false;
}

/// Wake every thread waiting for this child.
///
/// Every, rather than the first: two threads of one process may both be in
/// `wait`, and only one of them will win the reap. The loser goes round its
/// loop, finds nothing and sleeps again, which is what a spurious wake-up is
/// for and why the caller's loop re-checks rather than trusting the wake.
fn wake_waiters_for(parent_pid: Pid, child_pid: Pid) void {
    const guard = irqlock.acquire();
    defer guard.release();

    var prev: ?*Thread = null;
    var it = waiters;
    while (it) |t| {
        const nxt = t.wait_next;
        const matches = blk: {
            const tp = t.proc orelse break :blk false;
            if (tp.pid != parent_pid) break :blk false;
            break :blk t.wait_for <= 0 or t.wait_for == child_pid;
        };
        if (matches) {
            if (prev) |pv| pv.wait_next = nxt else waiters = nxt;
            t.wait_next = null;
            t.wait_for = 0;
            wake(t);
        } else {
            prev = t;
        }
        it = nxt;
    }
}

/// wait(2) — sleep until a child of this process has exited, then reap it.
///
/// `target` names a child, or is 0 or -1 for any. Returns null when there is
/// nothing to wait for, which the caller turns into ECHILD: a process with no
/// children that waits would otherwise sleep for the life of the machine.
///
/// The loop is not belt-and-braces. A wake-up means "something happened",
/// never "your child is ready" — another thread of the same process may have
/// reaped it first — so the answer is always re-derived from the zombie list
/// rather than carried in the wake.
pub fn waitpid(target: Pid) ?Waited {
    const p = current_process() orelse return null;

    while (true) {
        const guard = irqlock.acquire();

        if (reap_zombie(p, target)) |w| {
            guard.release();
            return w;
        }
        if (!has_child(p, target)) {
            guard.release();
            return null;
        }

        // The boot path waits by hand.
        //
        // It is not a Thread — it is the kernel's initial stack — so there is
        // nothing to put on a run queue and nothing for `wake` to find. What
        // it can do is give the CPU to the run queue and look again, which is
        // exactly what `run_queued` does and the only thing "waiting" can
        // mean here. Most of the programs on this machine still run from the
        // boot path, the shell among them, so this is not a corner: it is how
        // the shell's own `run` waits for the program it started.
        //
        // If nothing is runnable and no child has finished, nobody is going
        // to make one finish, and yielding again would spin forever. Saying
        // so is better than hanging: the caller gets the same answer it would
        // for a child that never existed, and the boot carries on.
        const t = current orelse {
            guard.release();
            if (!anything_runnable()) return null;
            yield();
            continue;
        };

        // Nothing yet, and something to wait for. Going to sleep is three
        // steps, and all three are under the guard the whole way to the
        // switch: onto the waiters list, into the blocked state, and then
        // `yield`. Releasing before any of them would leave a window where a
        // child exits, walks a list this thread is not on yet or finds it
        // still `running`, and skips the wake that would ever get it back.
        //
        // `yield` takes the same guard again, which nests; it saves this
        // thread's masked DAIF on its own stack and restores it when
        // something switches back, so the release below puts back what the
        // caller had.
        t.wait_for = target;
        t.wait_next = waiters;
        waiters = t;
        t.state = .blocked;
        wait_sleeps +%= 1;
        yield();
        guard.release();
    }
}
