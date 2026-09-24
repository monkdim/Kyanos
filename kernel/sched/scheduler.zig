//! Preemptive priority round-robin scheduler.
//!
//! Three priority levels (high / normal / idle). Each level has its
//! own runqueue. A timer interrupt every 10 ms calls preempt(), which
//! moves the running thread to the tail of its queue and switches to
//! the head of the highest non-empty one.
//!
//! Threads block by removing themselves from the runqueue and
//! pointing at a wait reason; when the reason fires (I/O completes,
//! a child exits, a timer expires), the waker calls wake() to put
//! them back on the runqueue.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");
const context = @import("../arch/x86_64/context.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const arch_syscall = @import("../arch/x86_64/syscall.zig");
const elf = @import("../loader/elf.zig");
const loader = @import("../loader/load.zig");
/// The process model, told what an address space is on this architecture.
/// The AArch64 scheduler names the same file with its own `AddressSpace`.
const process = @import("process.zig").Model(vmm.AddressSpace);
const irqlock = @import("../sync/irqlock.zig");
const runqueue = @import("runqueue.zig");
const vfs = @import("../fs/vfs.zig");
const console = @import("../arch/x86_64/console.zig");

pub const Priority = enum(u8) {
    high = 0,
    normal = 1,
    idle = 2,

    pub fn count() usize { return 3; }
};

pub const State = enum(u8) {
    runnable,
    running,
    blocked,
    zombie,
};

pub const WaitReason = union(enum) {
    none,
    io,
    sleep_until: u64,
    waitpid: i32,
    futex: usize,
    channel: usize,
};

pub const Pid = i32;
pub const Tid = i32;

pub const Thread = struct {
    tid: Tid,
    pid: Pid,
    name: []const u8,
    priority: Priority,
    state: State,
    wait: WaitReason = .none,
    // `.{}` rather than zeroes: Context's FXSAVE area has a default that is a
    // valid FPU image, and zeroing it would unmask every SSE exception.
    context: context.Context = .{},
    kernel_stack_top: u64 = 0,
    /// How big that stack is. Kept so `check_on_stack` has a range rather
    /// than a single address to compare against; zero means "no stack of its
    /// own", which is true of a Thread that has not been given one.
    kernel_stack_bytes: u64 = 0,
    iret_rsp: u64 = 0,                      // for first entry to userspace
    /// The register file a forked child resumes with, or null for a thread
    /// that starts at an ELF entry point and is owed nothing but zeroes.
    ///
    /// On the heap rather than inline because it is copied out of the
    /// *parent's* kernel stack, which is gone by the time the child runs.
    fork_regs: ?*context.Regs = null,
    next: ?*Thread = null,
    ticks_run: u64 = 0,
    exit_code: i32 = 0,
};

/// Per-CPU process table. Given its allocator by init(); see the note there
/// for why that is not a separate call any more.
pub var process_table: process.Table = undefined;

/// The queues themselves are `sched/runqueue.zig`, shared with the AArch64
/// scheduler. There was a private copy of exactly this here, and the AArch64
/// side was about to grow a second one — three priority FIFOs and "take the
/// head of the highest non-empty" written out twice, which is two scheduling
/// policies that agree today.
const Queues = runqueue.MultiQueue(Thread, Priority.count());

var queues: Queues = .{};
var current: ?*Thread = null;
var next_tid: Tid = 1;
var frozen: bool = false;

pub fn init() void {
    queues.clear();
    current = null;
    frozen = false;
    // The process table needs its allocator before anything can register a
    // process. This was an `init_process_table(gpa)` that nothing called, so
    // `process_table` stayed `undefined` — which for a .bss global means
    // zeroes, i.e. a std.mem.Allocator whose vtable pointer is null. The
    // first spawn_user called through it, loaded a function pointer from
    // physical page 0 (identity-mapped, and still holding the real-mode
    // interrupt vector table), and jumped to 0xf000ff53f000ff53. Setting it
    // here means it cannot be missed again: there is one kernel heap, and
    // anything with a run queue needs a process table to go with it.
    process_table = process.Table.init(heap.allocator());
    // The boot path's own address space. It matters more than the kernel
    // threads' does: the boot stack is a low identity-mapped address, not an
    // HHDM one, so it is the one stack a process's address space does *not*
    // map — and switching back to it with a process's CR3 still loaded faults
    // on the first pop.
    boot_context.cr3 = vmm.kernel().pml4_phys;
}

pub fn freeze() void {
    frozen = true;
}

/// Start a kernel thread at `entry`, which receives `arg`.
///
/// The entry takes its argument and uses the C calling convention, rather
/// than being a bare `fn () noreturn` cast into shape at the call below. The
/// cast was not free: it told the compiler a lie that happened to be
/// harmless only because the argument never arrived anywhere the callee
/// looked. Two threads that differ only in which one they are no longer need
/// to be two functions.
pub fn spawn_kthread(
    entry: *const fn (u64) callconv(.C) noreturn,
    arg: u64,
    name: []const u8,
    priority: Priority,
) !*Thread {
    const t = @as(*Thread, @ptrCast(@alignCast(heap.alloc(@sizeOf(Thread)) orelse return error.OutOfMemory)));
    t.* = .{
        .tid = next_tid,
        .pid = 0,
        .name = name,
        .priority = priority,
        .state = .runnable,
    };
    next_tid += 1;

    // 16 KiB kernel stack
    const stack_pages = 4;
    const stack_phys = pmm.alloc_pages(stack_pages) orelse return error.OutOfMemory;
    const stack_top = 0xFFFF_8000_0000_0000 + stack_phys + stack_pages * pmm.PAGE_SIZE;
    context.init_kernel_thread(&t.context, stack_top, entry, arg);
    // Kernel threads run in the kernel's address space, and say so rather than
    // inheriting whichever one happened to be loaded: with a user process in
    // the picture, "whatever CR3 was current" is sometimes a process's.
    t.context.cr3 = vmm.kernel().pml4_phys;
    t.kernel_stack_top = stack_top;
    t.kernel_stack_bytes = stack_pages * pmm.PAGE_SIZE;

    queues.enqueue(t, @intFromEnum(priority));
    return t;
}

pub fn spawn_user(path: []const u8) !*Thread {
    // 1. Read the ELF off the VFS.
    const image = try vfs.read_file_into_heap(path, heap.allocator());
    defer heap.allocator().free(image);
    // 2. Parse + load.
    const exe = try elf.parse(image, heap.allocator());
    defer elf.release(heap.allocator(), exe);
    const loaded = try loader.load_into_new_space(exe, image, heap.allocator());

    // 3. Allocate Process + main Thread.
    const proc = try process_table.gpa.create(process.Process);
    proc.* = .{
        .pid = process_table.alloc_pid(),
        .parent_pid = if (current) |c| c.pid else 0,
        .name = path,
        .address_space = loaded.address_space,
        .state = .runnable,
    };
    // The loader computed where this image's heap should start and nothing
    // kept it, so there was nowhere for brk to begin. Keep it.
    proc.brk_start = loaded.brk_start;
    proc.brk = loaded.brk_start;
    try process_table.register(proc);

    const t = @as(*Thread, @ptrCast(@alignCast(heap.alloc(@sizeOf(Thread)) orelse return error.OutOfMemory)));
    t.* = .{
        .tid = next_tid,
        .pid = proc.pid,
        .name = path,
        .priority = .normal,
        .state = .runnable,
    };
    next_tid += 1;
    proc.main_thread_tid = t.tid;

    // 16 KiB kernel stack for syscall + interrupt handling.
    const kstack_pages = 4;
    const kstack_phys = pmm.alloc_pages(kstack_pages) orelse return error.OutOfMemory;
    t.kernel_stack_top = 0xFFFF_8000_0000_0000 + kstack_phys + kstack_pages * pmm.PAGE_SIZE;
    t.kernel_stack_bytes = kstack_pages * pmm.PAGE_SIZE;
    t.context.cr3 = loaded.address_space.pml4_phys;

    // 4. Build the IRET frame so the first dispatch lands in user
    //    mode at the ELF entry point.
    const user_rflags: u64 = 0x202;            // IF=1, reserved bit 1 = 1
    // From the GDT, not written out: SYSRET fixes the order of the user
    // descriptor pair, so user *data* comes first and the numeric values are
    // the reverse of the obvious guess.
    const user_cs: u16 = gdt.USER_CODE;
    const user_ss: u16 = gdt.USER_DATA;
    t.iret_rsp = context.build_iret_frame(t.kernel_stack_top, loaded.entry_rip, loaded.user_rsp, user_rflags, user_cs, user_ss);

    // Give the thread a kernel-side context too, so the scheduler can reach
    // it the same way it reaches any other thread.
    //
    // Without this its Context is all zeroes, so a switch into it jumps to
    // address 0. The first process worked around that by never going through
    // the scheduler: the boot path took the thread back off the queue and
    // entered ring 3 by hand. That works exactly once. A second process needs
    // the first to be able to exit *back* to something, and there is nothing
    // to go back to when the entry was a one-way jump off the boot stack.
    //
    // The trampoline runs on the thread's own kernel stack, which is an HHDM
    // address every address space maps — so unlike the boot path, there is no
    // window where the stack under our feet is about to be unmapped.
    context.init_kernel_thread(&t.context, t.kernel_stack_top - context.IRET_FRAME_RESERVE, user_entry, 0);

    queues.enqueue(t, @intFromEnum(Priority.normal));
    return t;
}

/// First-run entry for a user thread, called by the scheduler like any other
/// kernel thread entry point.
///
/// It takes no argument, and reads `current` instead, because
/// init_kernel_thread's argument passing has never been exercised — every
/// caller passes zero — and a first user of it should not be the boot path.
/// `yield` sets `current` to this thread immediately before switching here,
/// under the same `cli` that protects the rest of the switch, so it is the
/// right thread by construction.
fn user_entry(_: u64) callconv(.C) noreturn {
    const t = current orelse {
        console.println("PANIC: user_entry with no current thread");
        while (true) asm volatile ("cli; hlt");
    };
    // A forked child is resuming, not starting, so it gets the register file
    // its parent had. Everything else starts at an ELF entry point, where
    // zeroes are what the ABI promises and all the program can use.
    if (t.fork_regs) |regs| {
        context.enter_userland_regs(t.context.cr3, t.iret_rsp, @intFromPtr(&t.context.fpu), regs);
    }
    context.enter_userland(t.context.cr3, t.iret_rsp, @intFromPtr(&t.context.fpu));
}

/// The context the boot path is running on. `yield` needs somewhere to save
/// the caller's registers even before any Thread exists, and this is it: the
/// kernel's initial stack behaves as thread zero.
var boot_context: context.Context = .{};

/// Pick the next runnable thread without switching to it.
///
/// This only updates `current` and the queues; the CPU carries on executing
/// whatever it was. That makes it useful for deciding, and wrong for
/// dispatching — the timer used to call it, which would have left `current`
/// naming a thread that was not running. Anything that means "stop running
/// this thread" wants yield() or preempt().
pub fn schedule() void {
    if (frozen) return;
    // Same reason as `yield`: this moves threads between `current` and the
    // queues, and the timer's handler does too.
    const guard = irqlock.acquire();
    defer guard.release();
    const prev = current;
    if (prev) |p| {
        if (p.state == .running) {
            p.state = .runnable;
            queues.enqueue(p, @intFromEnum(p.priority));
        }
    }
    if (queues.pick()) |next| {
        next.state = .running;
        current = next;
        return;
    }
    // Nothing runnable — leave `current` null and the caller halts.
    current = null;
}

/// Spins inserted between `current = next` and the switch that makes it
/// true, and nothing but a boot selftest ever sets it.
///
/// That window is where the scheduler's belief and the machine disagree:
/// `current` names the successor while the CPU is still on the predecessor's
/// stack. It is a handful of instructions wide, so a timer tick lands in it
/// once in tens of thousands of boots — which is exactly often enough to
/// produce one unexplained general protection fault and no way to reproduce
/// it. Widening it on purpose is how the guard below was shown to be
/// necessary rather than merely plausible.
pub var preempt_window_spins: u32 = 0;

/// Ticks that arrived while the CPU was not on the stack of the thread
/// `current` names. Counted on every tick of every boot, not only during the
/// selftest: it costs one compare, and an invariant that is only checked
/// when someone remembers to look is not an invariant.
pub var wrong_stack_ticks: u64 = 0;

fn widen_preempt_window() void {
    var i: u32 = 0;
    while (i < preempt_window_spins) : (i += 1) asm volatile ("pause" ::: "memory");
}

/// Check, from the timer's handler, that the thread the scheduler believes is
/// running is the one whose stack the CPU is standing on.
///
/// Called before `preempt`, so it sees the state the tick arrived in. A
/// thread with no stack of its own is skipped, and so is the boot path, which
/// has no Thread at all — `current` is null there and there is nothing to
/// disagree with.
pub fn check_on_stack() void {
    const c = current orelse return;
    if (c.kernel_stack_bytes == 0) return;
    const rsp = asm volatile ("movq %%rsp, %[out]"
        : [out] "=r" (-> u64),
    );
    const top = c.kernel_stack_top;
    const bottom = top - c.kernel_stack_bytes;
    if (rsp < bottom or rsp >= top) wrong_stack_ticks +%= 1;
}

/// Give up the CPU: pick the next runnable thread and actually switch to it.
///
/// Separate from `schedule`, which chooses a successor without moving to it.
/// This is the one that moves. It is also what the timer's handler calls, by
/// way of preempt(): each thread then resumes inside its *own* interrupt
/// handler and leaves through its own `iretq`, which works because every
/// thread has its own kernel stack for that frame to sit on.
///
/// Returns when something switches back to the caller.
pub fn yield() void {
    if (frozen) return;

    // Held across the switch, and the two mechanisms interlock. `switch_to`
    // does `pushfq; cli` on the way in and `popfq` on the way out, so it
    // writes the outgoing thread's interrupt state onto that thread's own
    // stack and restores the incoming thread's — which means a thread
    // resumed inside this call comes back masked, exactly as it left, and
    // this deferred release then puts back the flags the caller had before
    // it yielded. A brand-new thread starts unmasked because
    // `init_kernel_thread` writes 0x202 into that slot.
    //
    // Without it there is a window between `current = next` and the switch
    // that makes it true. A tick landing there calls back into this function
    // with `prev = current = next` — a thread that is not running — and
    // saves the *caller's* stack and resume address into that thread's
    // context. Whatever later switches to it resumes on a stack that belongs
    // to somebody else, halfway through an interrupt handler, and leaves
    // through an `iretq` whose frame has since been written over. That is a
    // general protection fault with a low RSP, which is what was seen once
    // in forty-nine boots before any of this was written down.
    const guard = irqlock.acquire();
    defer guard.release();

    const prev = current;
    const prev_ctx: *context.Context = if (prev) |p| &p.context else &boot_context;

    // The caller goes back on the run queue before we look for a successor,
    // so a lone thread yields to itself rather than finding nothing.
    if (prev) |p| {
        if (p.state == .running) {
            p.state = .runnable;
            queues.enqueue(p, @intFromEnum(p.priority));
        }
    }

    if (queues.pick()) |next| {
        next.state = .running;
        current = next;
        // The CPU takes an interrupt in ring 3 onto the stack named by the
        // TSS, so RSP0 has to follow whichever thread is running — a stale
        // one would push the frame onto a stack another thread is using.
        if (next.kernel_stack_top != 0) gdt.set_kernel_stack(next.kernel_stack_top);
        if (preempt_window_spins != 0) widen_preempt_window();
        context.switch_to(prev_ctx, &next.context);
        return;
    }
    // Nothing else is runnable.
    if (prev) |p| {
        // boot_context.rip is only set once something has switched *away*
        // from the boot path. Without that check this would jump to address
        // zero on any path that blocks before the run queue is ever entered.
        if (p.state != .running and boot_context.rip != 0) {
            // The caller is finished and there is no successor, so there is
            // no thread left to return to. Go back to the boot context — the
            // one that started the run queue — which can carry on without it.
            current = null;
            context.switch_to(&p.context, &boot_context);
            return;
        }
    }
    // The caller is still runnable and simply has the CPU to itself.
}

/// End the calling thread. It never runs again, so this does not return: the
/// switch away from it is the last thing that happens on its stack.
pub fn thread_exit(code: i32) noreturn {
    {
        const guard = irqlock.acquire();
        defer guard.release();
        if (current) |c| {
            c.state = .zombie;
            c.exit_code = code;
        }
    }
    yield();
    // Only reached if there was nowhere to go, which means nothing is left to
    // run at all.
    while (true) asm volatile ("cli; hlt");
}

/// Hand control to the run queue and come back when it drains. Used by the
/// boot path to run kernel threads to completion before carrying on.
pub fn run_queued() void {
    while (queues.any()) yield();
    // The boot context is a resume point on *this* frame, and it stops being
    // one the moment this call returns. Left set, a thread that exits later
    // would find it, "switch back to boot", and resume inside a run_queued
    // that already finished — re-running whatever the boot path did next.
    // Clearing rip is how yield knows there is no boot coroutine left.
    boot_context.rip = 0;
}


/// Preempt the running thread. Called from the timer IRQ.
///
/// This is a real switch, not `schedule`. `schedule` only *picks*: it moves
/// `current` to another thread and returns, leaving the CPU executing the old
/// one — so driving it from the timer would have left the scheduler's idea of
/// what is running disagreeing with what is running, with the preempted
/// thread simultaneously on the run queue and on the CPU. The timer never
/// actually ran (nothing called timer.init), which is the only reason that
/// never caused damage.
///
/// Switching from inside an interrupt handler is safe because every thread
/// has its own kernel stack: the interrupt frame stays on the preempted
/// thread's stack, and when something switches back, execution resumes in
/// this call, returns through the handler, and leaves by that thread's own
/// `iretq` with its own frame.
///
/// Only threads are preempted. The boot path has no Thread, so switching away
/// from it would strand the boot sequence with nothing able to resume it.
pub fn preempt() void {
    if (current == null) return;
    yield();
}

pub fn block(reason: WaitReason) void {
    {
        // Same reason as `yield`: the timer's handler moves threads between
        // `current` and the queues, and so does this.
        const guard = irqlock.acquire();
        defer guard.release();
        if (current) |c| {
            c.state = .blocked;
            c.wait = reason;
        }
    }
    // yield, not schedule: a blocked thread has to stop running, and until
    // now this only *chose* a successor without moving to it, so the caller
    // carried straight on as if it had never blocked. Marking the state
    // blocked first also keeps it off the run queue.
    yield();
}

pub fn wake(t: *Thread) void {
    const guard = irqlock.acquire();
    defer guard.release();
    if (t.state != .blocked) return;
    t.state = .runnable;
    t.wait = .none;
    queues.enqueue(t, @intFromEnum(t.priority));
}

pub fn exit(code: i32) noreturn {
    {
        const guard = irqlock.acquire();
        defer guard.release();
        if (current) |c| {
            c.state = .zombie;
            c.exit_code = code;
            // Reaping is the parent's responsibility via waitpid.
        }
    }
    // Switch away for real. This used to be `while (true) schedule()`, which
    // picks a successor but never moves to it — so a thread that called exit
    // carried straight on through the loop, dead and still running, forever.
    // A zombie is never re-queued, so yield returns only when there is
    // genuinely nothing left to run.
    yield();
    console.println("  [halt] nothing left to run");
    while (true) asm volatile ("cli; hlt");
}

pub fn run() noreturn {
    while (true) {
        schedule();
        // The dispatcher returns here when no thread is runnable;
        // hlt-loop until the next interrupt.
        asm volatile ("hlt");
    }
}

pub fn current_thread() ?*Thread {
    return current;
}

pub fn queue_len(p: Priority) usize {
    return queues.len(@intFromEnum(p));
}

// ── Process syscalls ─────────────────────────────

/// Clone the current process's address space + state into a new
/// child process. Returns child PID to the parent, 0 to the child.
/// Make a second process out of this one: same memory, same place in its own
/// code, told apart only by what `fork` answers.
///
/// `user` is the frame the system call trampoline pushed — the parent's
/// resume point. The child has to come back to the same instruction on its
/// own copy of the same stack, with zero in %rax instead of the child's PID,
/// and that is the whole of what makes the one call return twice.
pub fn fork(user: *const arch_syscall.UserFrame) !Pid {
    const cur = current orelse return error.NoCurrent;
    const parent = process_table.lookup(cur.pid) orelse return error.NoCurrent;

    // Every page the parent has, copied. See clone_address_space for why
    // eagerly rather than copy-on-write.
    const child_space = try clone_address_space(parent.address_space);
    const child = try process_table.gpa.create(process.Process);
    child.* = .{
        .pid = process_table.alloc_pid(),
        .parent_pid = parent.pid,
        .name = parent.name,
        .address_space = child_space,
        .state = .runnable,
        // The child's heap is where the parent's was: clone_address_space
        // copies the mappings, so the memory below the break is already
        // there. Leaving these at zero would let the child's first brk map
        // over pages it already owns.
        .brk = parent.brk,
        .brk_start = parent.brk_start,
    };
    try process_table.register(child);
    try parent.add_child(child.pid, process_table.gpa);

    // A thread for the child, built the way spawn_user builds one. This is
    // what was missing: the Thread used to get a tid, a pid, a name and a
    // CR3 and nothing else — no kernel stack, no IRET frame, a zero context —
    // so the first switch into it jumped to address 0 with no stack and no
    // kernel mapped, and the machine triple-faulted.
    const t = @as(*Thread, @ptrCast(@alignCast(heap.alloc(@sizeOf(Thread)) orelse return error.OutOfMemory)));
    t.* = .{
        .tid = next_tid,
        .pid = child.pid,
        .name = child.name,
        .priority = .normal,
        .state = .runnable,
    };
    next_tid += 1;

    const kstack_pages = 4;
    const kstack_phys = pmm.alloc_pages(kstack_pages) orelse return error.OutOfMemory;
    t.kernel_stack_top = 0xFFFF_8000_0000_0000 + kstack_phys + kstack_pages * pmm.PAGE_SIZE;
    t.kernel_stack_bytes = kstack_pages * pmm.PAGE_SIZE;
    t.context.cr3 = child_space.pml4_phys;

    // Where the child comes back to. The parent's rip and rsp, because the
    // child is the same program at the same point on a copy of the same
    // stack; the parent's rflags, because the child inherits the machine
    // state it forked in.
    //
    // Entering through an IRET frame rather than sysret is what lets the
    // child's registers be chosen: `sysretq` would hand back whatever
    // dispatch returned in %rax, which is the child's PID — the parent's
    // answer, given to the child.
    t.iret_rsp = context.build_iret_frame(
        t.kernel_stack_top,
        user.rip,
        user.rsp,
        user.rflags,
        gdt.USER_CODE,
        gdt.USER_DATA,
    );
    // The floating-point state, saved out of the live registers rather than
    // left at whatever a fresh Context is born with. The parent is mid-call
    // with its own values in the register file, and a child that started with
    // a blank one would silently compute something else — the same class of
    // wrong the aarch64 side just spent three changes closing.
    context.fxsave_into(&t.context.fpu);

    // The registers the child is owed. Everything except %rax, %rcx and %r11,
    // which fork(2) and the ABI between them say it may not rely on. Kept on
    // the heap because the frame it is copied from is on the *parent's*
    // kernel stack and will be gone by the time the child first runs.
    const regs = @as(*context.Regs, @ptrCast(@alignCast(heap.alloc(@sizeOf(context.Regs)) orelse return error.OutOfMemory)));
    regs.* = .{
        .rbx = user.rbx,
        .rbp = user.rbp,
        .r12 = user.r12,
        .r13 = user.r13,
        .r14 = user.r14,
        .r15 = user.r15,
        .rdi = user.a0,
        .rsi = user.a1,
        .rdx = user.a2,
        .r10 = user.a3,
        .r8 = user.a4,
        .r9 = user.a5,
    };
    t.fork_regs = regs;

    context.init_kernel_thread(&t.context, t.kernel_stack_top - context.IRET_FRAME_RESERVE, user_entry, 0);

    child.main_thread_tid = t.tid;
    queues.enqueue(t, @intFromEnum(Priority.normal));
    return child.pid;
}

/// Replace the current process's image with a new ELF. exec() does
/// not return on success.
pub fn exec(path: []const u8) !void {
    const cur = current orelse return error.NoCurrent;
    const proc = process_table.lookup(cur.pid) orelse return error.NoCurrent;

    const image = try vfs.read_file_into_heap(path, heap.allocator());
    defer heap.allocator().free(image);
    const exe_obj = try elf.parse(image, heap.allocator());
    defer elf.release(heap.allocator(), exe_obj);
    const loaded = try loader.load_into_new_space(exe_obj, image, heap.allocator());

    // Tear down the old address space; the new one replaces it.
    proc.address_space = loaded.address_space;
    cur.context.cr3 = loaded.address_space.pml4_phys;
    cur.iret_rsp = context.build_iret_frame(cur.kernel_stack_top, loaded.entry_rip, loaded.user_rsp, 0x202, gdt.USER_CODE, gdt.USER_DATA);
    proc.name = path;

    // Re-enter user mode with the new image. CR3 goes in with it — see
    // enter_userland for why they cannot be separate statements.
    context.enter_userland(cur.context.cr3, cur.iret_rsp, @intFromPtr(&cur.context.fpu));
}

pub const WaitResult = struct { pid: Pid, exit_code: i32 };

pub fn waitpid(target: i32) ?WaitResult {
    const cur = current orelse return null;
    const parent = process_table.lookup(cur.pid) orelse return null;
    const reaped = if (target <= 0) parent.reap_any() else parent.reap_pid(target);
    const z = reaped orelse return null;
    process_table.remove(z.pid);
    return .{ .pid = z.pid, .exit_code = z.exit_code };
}

/// What a thread exited with, for a caller that is not its parent.
///
/// `waitpid` is the real answer and cannot be used here: it reaps from
/// `current`, and the boot path has no `current` — it is not a thread. A
/// boot selftest that spawns a process and wants to know how it went has no
/// other way to ask.
///
/// Safe to read after the thread is dead because nothing on this
/// architecture frees a Thread: there is no dead list and no reap. The day
/// there is one, this becomes a use-after-free and has to move into it.
pub fn exit_code_of(t: *const Thread) ?i32 {
    if (t.state != .zombie) return null;
    return t.exit_code;
}

pub fn kill(target_pid: Pid, sig: i32) bool {
    const target = process_table.lookup(target_pid) orelse return false;
    // Signal handling is its own future phase; for now the only
    // signal we honour is SIGKILL, which terminates the target
    // immediately.
    if (sig == 9) {
        target.state = .zombie;
        target.exit_code = 128 + sig;
        if (process_table.lookup(target.parent_pid)) |parent| {
            parent.record_zombie(target.*, process_table.gpa) catch {};
        }
        return true;
    }
    // Other signals: queued, not yet delivered.
    return true;
}

/// Copy an address space: the same memory at the same addresses with the same
/// permissions, in pages of its own.
///
/// This used to allocate a PML4, copy the region *list*, and return — with a
/// comment saying "physical pages copied below" and nothing below. No page was
/// copied, no table entry written, and `share_kernel_half` never called, so
/// the child's PML4 did not even map the kernel. Nothing noticed because
/// nothing had ever called `fork`: the first program that did printed one line
/// as the parent and then the machine triple-faulted, which is what a boot
/// with `-d cpu_reset` says out loud.
///
/// No copy-on-write. Every page is copied eagerly, which is slower and simpler
/// and — more to the point — has no failure mode that only appears under
/// memory pressure. COW is worth having once there is a fault handler that can
/// be trusted to get it right, and a test that can tell a shared page from a
/// copied one.
fn clone_address_space(src: *vmm.AddressSpace) !*vmm.AddressSpace {
    const dst = try process_table.gpa.create(vmm.AddressSpace);
    errdefer process_table.gpa.destroy(dst);

    const new_pml4 = pmm.alloc_page() orelse return error.OutOfMemory;
    zero_phys_page(new_pml4);
    dst.* = .{ .pml4_phys = new_pml4, .regions = .{} };

    // The upper half, which every address space shares and which the loader
    // gives every space it builds. Without it the child's first instruction
    // fetch in the kernel — the one that returns from the switch — has no
    // page to fetch from.
    vmm.share_kernel_half(new_pml4);

    // The regions, which the page-fault and brk machinery read.
    for (src.regions.items) |r| try dst.regions.append(heap.allocator(), r);

    // And the memory itself, taken from the parent's page tables rather than
    // from that list — see vmm.clone_user_half for what driving it from the
    // list got wrong, twice.
    try vmm.clone_user_half(src, dst);
    return dst;
}

fn zero_phys_page(phys: u64) void {
    const HHDM: u64 = 0xFFFF_8000_0000_0000;
    const p: [*]u8 = @ptrFromInt(HHDM + phys);
    @memset(p[0..4096], 0);
}
