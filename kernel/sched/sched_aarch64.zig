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
    free_asid(p.address_space.asid);
    processes.remove(p.pid);
}
