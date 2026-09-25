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
    /// The next thread on the `waiters` list — the ones asleep in `wait(2)`.
    /// Separate from `next`, which belongs to the run queues: a waiting
    /// thread is on neither queue, and one field cannot hold both lists.
    wait_next: ?*Thread = null,
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
    const gs_kernel = @intFromPtr(&arch_syscall.per_cpu);
    if (t.fork_regs) |regs| {
        context.enter_userland_regs(t.context.cr3, t.iret_rsp, @intFromPtr(&t.context.fpu), regs, gs_kernel);
    }
    context.enter_userland(t.context.cr3, t.iret_rsp, @intFromPtr(&t.context.fpu), gs_kernel);
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
        if (next.kernel_stack_top != 0) {
            gdt.set_kernel_stack(next.kernel_stack_top);
            // And the stack `syscall` lands on, which is the same stack and
            // for the same reason.
            //
            // It was one 16 KiB array for the whole machine — `syscall_stack`
            // in arch/x86_64/syscall.zig, loaded from `per_cpu.kernel_rsp`,
            // set once at boot. That is correct for exactly as long as no
            // thread is ever *inside* a system call while another one runs,
            // which was true until `wait` could block. It stopped being true
            // the first time a parent slept in `wait(2)`: the child then made
            // its own calls on the same stack, wrote over the parent's frames,
            // and when the parent was resumed `clarity_switch_to` popped a
            // return address that was no longer there.
            //
            // Measured, on the first program to do it:
            //
            //   CPU EXCEPTION 14 (page fault) error_code=0x0
            //     rip=0xffffffff801750d0 cs=0x8 rflags=0x417
            //     rsp=0xffffffff8037eab0 ss=0x10 cr2=0x413000
            //
            // rip resolves to `fputest.a_done`, a .bss symbol — the kernel
            // jumped into data, because that is what the clobbered return
            // address pointed at.
            //
            // A thread's kernel stack is free while it is in ring 3, so a
            // system call starting at its top is right, and the two entries
            // cannot collide: `syscall` masks IF through IA32_FMASK, and an
            // interrupt from ring 3 lands on RSP0 of whichever thread was
            // running, which is that thread's own stack.
            arch_syscall.per_cpu.kernel_rsp = next.kernel_stack_top;
        }
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

/// Give a dying process's pages back, from the thread that is dying on them.
///
/// Every process on this architecture kept its whole image until the machine
/// stopped: `exit` marked the Thread and the Process zombies and nothing ever
/// walked the address space. The fork+exec gate is what put a number on it --
/// 48 pages that two finished processes still held.
///
/// **Off the address space before its tables are freed.** The kernel half is
/// shared -- entries 256..511 of every PML4 are copies of the kernel's own --
/// so the kernel's tree maps this code, this stack, and the direct map that
/// `free_user_half` writes through. Switching to it first is what makes
/// freeing the PML4 underneath safe: after the `mov`, not one page being
/// freed is a page the CPU is still translating through.
///
/// This is not AArch64's `paging.deactivate`, which sets TCR_EL1.EPD0 and so
/// takes the low half from every merely *preempted* process, because nothing
/// puts it back. CR3 is reloaded from the thread's own Context on every
/// switch, so this is a statement one thread makes about itself and it lasts
/// exactly as long as this thread does. The Context is set to match: a zombie
/// is never re-queued, but `free_user_half` leaves `pml4_phys` zero and a
/// zero CR3 is not something to leave lying in a live structure.
///
/// The gate does not catch the switch going missing, and that is worth saying
/// rather than implying otherwise. Taken out, three boots passed: interrupts
/// are masked for the rest of this block and nothing between here and the
/// `yield` below allocates, so the freed PML4 keeps its contents long enough
/// for the switch to happen anyway. What the switch is for is the window
/// *after* the guard is released, where a timer tick can run the allocator.
/// Held open on purpose -- one `alloc_page` and a `memset` put where such a
/// tick would land, in a build with the switch removed -- the machine stops
/// dead with no exception on the console, twice out of two, which is what a
/// triple fault looks like from outside. So: the switch closes the window
/// rather than narrowing it, and the evidence for it is that experiment and
/// not the boot gate.
fn release_user_memory(c: *Thread) void {
    const p = process_table.lookup(c.pid) orelse return;
    const space = p.address_space;
    // A kernel thread's process, if it has one, points at the kernel's own
    // tree. Freeing that frees the machine.
    if (space == vmm.kernel() or space.pml4_phys == 0) return;
    if (space.pml4_phys == vmm.kernel().pml4_phys) return;

    asm volatile ("mov %[cr3], %%cr3"
        :
        : [cr3] "r" (vmm.kernel().pml4_phys),
        : "memory"
    );
    vmm.free_user_half(space);
    c.context.cr3 = vmm.kernel().pml4_phys;
}

pub fn exit(code: i32) noreturn {
    {
        const guard = irqlock.acquire();
        defer guard.release();
        if (current) |c| {
            c.state = .zombie;
            c.exit_code = code;
            // The memory goes first, so the zombie the parent reaps holds an
            // exit code and a PID and nothing else.
            release_user_memory(c);
            // And the *process*, which nothing did until now: this marked the
            // Thread dead and stopped, so a parent had nothing to reap and no
            // way to learn how its child went. One thread per process today,
            // so a thread ending is a process ending; the day a process has
            // two, this becomes "the last one out".
            end_process(c.pid, code);
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

    // The old address space goes back now, and not before: the load above can
    // fail, and a process whose image was freed first would have nothing left
    // to be refused with.
    //
    // This line used to be a comment saying "tear down the old address space"
    // over code that only overwrote the pointer. Every image a process
    // replaced stayed allocated for the life of the machine — and `exec` is
    // the call whose whole purpose is to replace one.
    //
    // Nothing is running in it: this thread is about to enter the new one,
    // and CR3 still holds the old until `enter_userland` swaps it, which is
    // fine because freeing a page does not unmap it.
    vmm.free_user_half(proc.address_space);

    proc.address_space = loaded.address_space;
    cur.context.cr3 = loaded.address_space.pml4_phys;
    cur.iret_rsp = context.build_iret_frame(cur.kernel_stack_top, loaded.entry_rip, loaded.user_rsp, 0x202, gdt.USER_CODE, gdt.USER_DATA);
    proc.name = path;

    // And the heap, which belongs to the image and not to the process that
    // used to be here. Without this the new image's break is wherever the old
    // one's happened to be: too high and it starts past its own memory, too
    // low and its first allocation lands inside its own .bss.
    proc.brk_start = loaded.brk_start;
    proc.brk = loaded.brk_start;

    // Re-enter user mode with the new image. CR3 goes in with it — see
    // enter_userland for why they cannot be separate statements.
    context.enter_userland(cur.context.cr3, cur.iret_rsp, @intFromPtr(&cur.context.fpu), @intFromPtr(&arch_syscall.per_cpu));
}

pub const WaitResult = struct { pid: Pid, exit_code: i32 };

// ── Waiting for a child ─────────────────────────────────────────────────
//
// Two things were missing here, and the second hid the first.
//
// `wait(2)` did not wait. It reaped a zombie if one happened to be lying
// about and answered ECHILD otherwise — so a parent that forked and waited,
// which is what a parent does, was told it had no children. It passes any
// test where the parent dawdles long enough for the child to finish first.
//
// And there was nothing to reap. `exit` marked the *Thread* a zombie and
// stopped; the only thing that ever recorded a Process against its parent was
// `kill`. So even a parent that dawdled found nothing: a child's exit status
// could not be learned on this architecture by any route at all.
//
// The AArch64 side grew the same two (#197), and the shape here is the same:
// a `waiters` list of threads asleep in the call, woken by the exit that
// records the zombie they are waiting for.

/// Threads asleep in `wait`, linked by `wait_next`.
var waiters: ?*Thread = null;

/// How many times a `wait` has actually gone to sleep. The difference between
/// this call and the one it replaces: a boot where this stays zero is a boot
/// where nothing ever waited, and every other check would still pass.
pub var wait_sleeps: u64 = 0;

fn reap_zombie(parent: *process.Process, target: i32) ?WaitResult {
    const z = (if (target <= 0) parent.reap_any() else parent.reap_pid(target)) orelse return null;
    return .{ .pid = z.pid, .exit_code = z.exit_code };
}

/// Does `p` still have a child worth waiting for? Asked only after
/// `reap_zombie` has said no, so a child that has exited and been recorded is
/// already out of this list.
fn has_child(p: *const process.Process, target: i32) bool {
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
/// loop, finds nothing and sleeps again — which is what the caller's loop is
/// for, and why a wake means "something happened" and never "your child is
/// ready".
fn wake_waiters_for(parent_pid: Pid, child_pid: Pid) void {
    const guard = irqlock.acquire();
    defer guard.release();

    var prev: ?*Thread = null;
    var it = waiters;
    while (it) |t| {
        const nxt = t.wait_next;
        const matches = t.pid == parent_pid and switch (t.wait) {
            .waitpid => |want| want <= 0 or want == child_pid,
            else => false,
        };
        if (matches) {
            if (prev) |pv| pv.wait_next = nxt else waiters = nxt;
            t.wait_next = null;
            wake(t);
        } else {
            prev = t;
        }
        it = nxt;
    }
}

/// A process is over: record it against its parent, hand its children to
/// init, and wake anybody waiting for it.
///
/// The Process is left in the table as the zombie its parent will reap;
/// `waitpid` is what takes it out.
fn end_process(pid: Pid, code: i32) void {
    const p = process_table.lookup(pid) orelse return;
    if (p.state == .zombie) return;
    p.state = .zombie;
    p.exit_code = code;
    process_table.reparent_children(p) catch {};
    if (process_table.lookup(p.parent_pid)) |parent| {
        parent.record_zombie(p.*, process_table.gpa) catch {};
        _ = parent.remove_child(p.pid);
    }
    // After the zombie is recorded, so a woken parent has something to find.
    wake_waiters_for(p.parent_pid, p.pid);
}

/// wait(2) — sleep until a child of this process has exited, then reap it.
///
/// `target` names a child, or is 0 or -1 for any. Returns null when there is
/// nothing to wait for, which the caller turns into ECHILD: a process with no
/// children that waited would otherwise sleep for the life of the machine.
pub fn waitpid(target: i32) ?WaitResult {
    const cur = current orelse return null;
    const parent = process_table.lookup(cur.pid) orelse return null;

    while (true) {
        const guard = irqlock.acquire();

        if (reap_zombie(parent, target)) |w| {
            guard.release();
            process_table.remove(w.pid);
            return w;
        }
        if (!has_child(parent, target)) {
            guard.release();
            return null;
        }

        // Onto the waiters list, into the blocked state, and then `yield` —
        // all three under the guard the whole way to the switch. Releasing
        // before any of them leaves a window where a child exits, walks a
        // list this thread is not on yet or finds it still `running`, and
        // skips the wake that would ever get it back.
        cur.wait_next = waiters;
        waiters = cur;
        cur.wait = .{ .waitpid = target };
        cur.state = .blocked;
        wait_sleeps +%= 1;
        yield();
        guard.release();
    }
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
