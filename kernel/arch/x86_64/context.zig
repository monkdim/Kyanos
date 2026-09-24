//! CPU context save/restore for cooperative + preemptive task
//! switching. We save the callee-saved register set (System V
//! AMD64 ABI: rbx, rbp, r12-r15) plus rsp + rip, since that's all
//! we need to resume a kernel thread from where it left off. User
//! threads add the full IRET frame on entry.

const std = @import("std");
const fpu_mod = @import("fpu.zig");

pub const Context = extern struct {
    rsp: u64 = 0,
    rbp: u64 = 0,
    rbx: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    /// x87 + SSE state, saved by FXSAVE in context.S. The alignment lives on
    /// the field, which is what makes `context + 64` a legal FXSAVE operand.
    ///
    /// Held inline rather than behind a pointer, and given a default rather
    /// than left to be filled in, because every way of doing it otherwise has
    /// a call site that can be forgotten — and a forgotten one is not a
    /// compile error, it is an FXRSTOR of zeroes at run time, which unmasks
    /// every SSE exception and turns the next division into a #XM. Every
    /// Context that exists is therefore born with a valid image.
    fpu: [fpu_mod.AREA_SIZE]u8 align(16) = fpu_mod.CLEAN,
    /// The address space this context runs in, as a CR3 value.
    ///
    /// A context switch has to switch address spaces, or a thread resumed
    /// after a preemption comes back with someone else's page tables. It was
    /// possible to do without while exactly one process existed and the only
    /// way into it was `enter_userland`, which loads CR3 itself — a second
    /// process makes it structural.
    ///
    /// Zero means "leave CR3 alone", which is what a context that has never
    /// been given an address space wants; every context the scheduler creates
    /// is given one.
    cr3: u64 = 0,
};

/// Switch from `prev` to `next`. Saves the callee-saved state onto `prev`'s
/// own stack, records where to resume, and restores `next`. After the call,
/// execution continues wherever `next.rip` points — for a brand-new thread
/// its entry point, for one that has run before the instruction after its own
/// switch_to.
///
/// Defined in context.S. It cannot be written here: manipulating %rsp and
/// returning through a saved instruction pointer requires `callconv(.Naked)`,
/// and Zig will not call a naked function because it has no ABI.
pub extern fn clarity_switch_to(prev: *Context, next: *const Context) callconv(.C) void;

pub const switch_to = clarity_switch_to;

comptime {
    std.debug.assert(IRET_FRAME_RESERVE >= @sizeOf(IretFrame));
    std.debug.assert(IRET_FRAME_RESERVE % 16 == 0);
    // context.S hardcodes these three offsets.
    std.debug.assert(@offsetOf(Context, "rsp") == 0);
    std.debug.assert(@offsetOf(Context, "rip") == 56);
    std.debug.assert(@offsetOf(Context, "fpu") == 64);
    std.debug.assert(@offsetOf(Context, "cr3") == 576);
    // FXSAVE and FXRSTOR fault unless the address is 16-byte aligned, and the
    // address is `context + 64` — so the Context itself has to be aligned,
    // wherever it is embedded and however it is allocated.
    std.debug.assert(@alignOf(Context) == 16);
}

/// The first thing a brand-new thread executes; see context.S.
extern fn clarity_thread_trampoline() callconv(.C) noreturn;

/// Initialise a brand-new kernel thread's context so that the first
/// switch_to lands at `entry` with `arg` in %rdi. The stack must be
/// allocated by the caller; `stack_top` points one byte past the highest
/// valid byte.
///
/// The thread does not start at `entry` but at a trampoline, which moves the
/// argument into the register the ABI passes arguments in. Jumping straight
/// at the entry point cannot work: %rdi is not in the set switch_to pops, so
/// it still holds that function's own first parameter — a pointer to some
/// other thread's context — where the new thread's argument should be. This
/// used to jump straight there and leave the argument in %rbp with a comment
/// claiming the entry's first instruction would move it, which is not
/// something a compiler does. Nothing noticed because every caller passed
/// zero, which scheduler.zig said so in as many words.
pub fn init_kernel_thread(ctx: *Context, stack_top: u64, entry: *const fn (u64) callconv(.C) noreturn, arg: u64) void {
    var rsp = stack_top & ~@as(u64, 0xF);
    // Pre-push exactly what switch_to pops, in the order it pops them: the
    // six callee-saved registers, then RFLAGS (pushed first, so popped last).
    rsp -= 8 * 7;
    const slots: [*]u64 = @ptrFromInt(rsp);
    slots[0] = 0;                        // r15
    slots[1] = 0;                        // r14
    slots[2] = 0;                        // r13
    slots[3] = 0;                        // r12
    slots[4] = @intFromPtr(entry);       // rbx — the trampoline jumps here
    slots[5] = arg;                      // rbp — the trampoline moves this to rdi
    // IF=1 (bit 9) and the reserved bit 1, which is always set. A thread that
    // started with interrupts off could never be preempted, and the first
    // switch into a new thread often comes from inside the timer's interrupt
    // gate, where IF is 0 — so this has to be stated, not inherited.
    slots[6] = 0x202;         // rflags
    ctx.rsp = rsp;
    ctx.rbp = 0;
    ctx.rbx = 0;
    ctx.r12 = 0; ctx.r13 = 0; ctx.r14 = 0; ctx.r15 = 0;
    ctx.rip = @intFromPtr(&clarity_thread_trampoline);
}

/// Build the IRET frame on `kstack_top` that returns to user mode
/// at `user_rip` with `user_rsp`. Returns the new rsp the kernel
/// should switch to before issuing iretq.
pub fn build_iret_frame(kstack_top: u64, user_rip: u64, user_rsp: u64, user_rflags: u64, user_cs: u16, user_ss: u16) u64 {
    var rsp = kstack_top & ~@as(u64, 0xF);
    rsp -= @sizeOf(IretFrame);
    const frame: *IretFrame = @ptrFromInt(rsp);
    frame.* = .{
        .rip = user_rip,
        .cs = user_cs,
        .rflags = user_rflags,
        .rsp = user_rsp,
        .ss = user_ss,
    };
    return rsp;
}

/// Bytes at the top of a kernel stack that belong to the IRET frame
/// build_iret_frame writes there.
///
/// A user thread's kernel stack carries two things before it first runs: the
/// IRET frame at the very top, and the scheduler's entry context below it. If
/// the second is laid out at the top as well, it writes straight through the
/// first, and the process enters ring 3 at whatever the pushed registers
/// happened to spell. Reserving the top explicitly is what keeps them apart.
pub const IRET_FRAME_RESERVE: u64 = 64;

pub const IretFrame = extern struct {
    rip: u64,
    cs: u64,        // 16-bit selector zero-extended into 64-bit slot
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Install the address space `cr3` and enter ring 3 with a frame already
/// built at `frame_rsp`.
///
/// Not `callconv(.Naked)`: a naked function has no ABI, so Zig refuses to
/// call one, and this was previously uncallable — it only compiled because
/// nothing reached it. A normal function works because the prologue is
/// irrelevant once %rsp is replaced and `iretq` leaves for good.
///
/// The CR3 load belongs here, in the same asm block, rather than at the call
/// site. The boot path runs on the stack the boot stub set up, which is a
/// low identity-mapped address; the process's address space maps its own
/// program and stack in the lower half and nothing else, so the moment CR3
/// changes that stack is gone. Any stack access before %rsp moves to the
/// thread's kernel stack — a push, a call, a spilled register — would fault,
/// and the fault handler would push its frame onto the same missing stack:
/// double fault, then triple, then a silent reset. Between these two
/// instructions there is no memory access at all, and both operands are
/// already in registers before the block begins.
///
/// `cli` for the same reason: an interrupt is taken *between* instructions,
/// so one arriving in that one-instruction window would push its frame onto
/// the stack CR3 had just taken away — a double fault, and then a triple.
/// The window is tiny, which makes it a rare boot failure rather than an
/// obvious one. `iretq` restores IF from the frame's RFLAGS, so ring 3 still
/// starts with interrupts on.
///
/// The kernel stack `frame_rsp` points into is an HHDM address in the upper
/// half, which every address space shares (see vmm.share_kernel_half), so it
/// survives the switch.
///
/// `fpu_area` is the thread's FXSAVE image, restored here for the same reason
/// clarity_switch_to restores one: this is the other way into a thread, and a
/// process must not start with whatever floating-point state the last thread
/// to run happened to leave in the registers. For a fresh process that image
/// is the clean one Context is born with, which is exactly the state the ABI
/// says a program starts in. It goes before the CR3 load only because it is
/// tidier to read that way — the area is an HHDM address, which every address
/// space maps, so either side would work.
/// Enter ring 3 with a register file taken from somewhere, rather than a
/// blank one.
///
/// `enter_userland` gives a program zeroes, which is what a program starting
/// at its ELF entry point is entitled to and all it can use. A forked child is
/// not starting: it is resuming, in the middle of a function, and the System V
/// ABI says a system call destroys %rcx and %r11 *and nothing else* — so the
/// program may be keeping live values in any other register across its call to
/// fork(2). Handing it zeroes would be the same bug this kernel fixed on the
/// AArch64 side, in the other direction.
///
/// %rax is not taken from the frame. It is the one register fork(2) is defined
/// to change, and zero is the child's answer.
///
/// %rcx and %r11 are zeroed rather than restored, because the ABI says a
/// system call is entitled to destroy them and the saved values are the
/// trampoline's own (the return address and RFLAGS `syscall` put there).
///
/// `regs` is reached after CR3 has changed, which is safe because it is a
/// kernel heap address and every address space maps the upper half.
pub fn enter_userland_regs(cr3: u64, frame_rsp: u64, fpu_area: u64, regs: *const Regs, gs_kernel_base: u64) noreturn {
    asm volatile (
        \\ cli
        // The GS bases, written rather than swapped. See enter_userland.
        \\ mov %%r10, %%rax
        \\ mov %%r10, %%rdx
        \\ shr $32, %%rdx
        \\ mov $0xC0000101, %%ecx
        \\ wrmsr
        \\ mov %%r10, %%rax
        \\ mov %%r10, %%rdx
        \\ shr $32, %%rdx
        \\ mov $0xC0000102, %%ecx
        \\ wrmsr
        \\ fxrstor (%%r8)
        \\ movq %%rdi, %%cr3
        \\ movq %%rsi, %%rsp
        \\ movq 0(%%r9), %%rbx
        \\ movq 8(%%r9), %%rbp
        \\ movq 16(%%r9), %%r12
        \\ movq 24(%%r9), %%r13
        \\ movq 32(%%r9), %%r14
        \\ movq 40(%%r9), %%r15
        \\ movq 48(%%r9), %%rdi
        \\ movq 56(%%r9), %%rsi
        \\ movq 64(%%r9), %%rdx
        \\ movq 72(%%r9), %%r10
        \\ movq 80(%%r9), %%r8
        \\ movq 88(%%r9), %%r9
        \\ xor %%eax, %%eax
        \\ xor %%ecx, %%ecx
        \\ xor %%r11d, %%r11d
        \\ iretq
        :
        : [cr3] "{rdi}" (cr3),
          [frame] "{rsi}" (frame_rsp),
          [fpu] "{r8}" (fpu_area),
          [regs] "{r9}" (regs),
          [gsk] "{r10}" (gs_kernel_base),
        : "memory"
    );
    unreachable;
}

/// The twelve registers a forked child is owed, in the order
/// `syscall_entry` pushes them — so a pointer to the saved frame is a
/// pointer to this. The offsets are hard-coded in the assembly above.
pub const Regs = extern struct {
    rbx: u64,
    rbp: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    r10: u64,
    r8: u64,
    r9: u64,
};

/// Save the live floating-point state into `area`, which must be 16-byte
/// aligned. Used when forking: the parent is mid-call with its own values in
/// the register file, and the child is owed a copy of them.
pub fn fxsave_into(area: *[512]u8) void {
    asm volatile ("fxsave (%[a])"
        :
        : [a] "r" (area),
        : "memory"
    );
}

pub fn enter_userland(cr3: u64, frame_rsp: u64, fpu_area: u64, gs_kernel_base: u64) noreturn {
    asm volatile (
        \\ cli
        // The GS bases, written rather than swapped.
        //
        // `swapgs` exchanges GS.base with IA32_KERNEL_GS_BASE, so what it
        // leaves behind depends on which way round they already were — and
        // getting here does not guarantee that. An interrupt taken in ring 3
        // does no swapgs, so the handler runs with the *user* base; if it
        // then switches threads and the new one enters ring 3 through here, a
        // swap would put the per-CPU pointer in ring 3's GS and zero in the
        // shadow. The next system call would swap back to zero and store the
        // user stack at address 8.
        //
        // That is not hypothetical: it is a page fault at cr2=0x8, in ring 0,
        // with %rsp still holding a user address, on one boot in three, as
        // soon as two processes existed at once to be switched between.
        //
        // Writing both explicitly costs two wrmsr and cannot be got wrong by
        // arriving from somewhere unexpected. Both get the per-CPU pointer —
        // see syscall.zig's init for why this kernel keeps them equal rather
        // than keeping a separate user value.
        \\ mov %%r10, %%rax
        \\ mov %%r10, %%rdx
        \\ shr $32, %%rdx
        \\ mov $0xC0000101, %%ecx
        \\ wrmsr
        \\ mov %%r10, %%rax
        \\ mov %%r10, %%rdx
        \\ shr $32, %%rdx
        \\ mov $0xC0000102, %%ecx
        \\ wrmsr
        \\ fxrstor (%%r8)
        \\ movq %%rdi, %%cr3
        \\ movq %%rsi, %%rsp
        // Every general register, because the register file is not the
        // kernel's to leave lying around. `iretq` pops RIP, CS, RFLAGS, RSP
        // and SS and nothing else, so without this rax through r15 reach
        // ring 3 holding what the kernel last had in them -- the CR3 just
        // loaded, the frame pointer, addresses the ELF loader walked. None
        // of it is anything ring 3 is entitled to know, and none of it costs
        // a fault to obtain.
        //
        // Here and not sooner: rax, rcx and rdx carry the three operands,
        // and nothing needs a register after RSP and CR3 are set. `swapgs`
        // reads none and `iretq` takes everything off the frame. The flags
        // these `xor`s write are replaced by the frame's RFLAGS.
        //
        // The three operands are pinned to named registers rather than left
        // to the compiler precisely because this clobbers all of them: which
        // register holds what has to be something this block knows.
        //
        // The vector file needs nothing, because `fxrstor` above has already
        // loaded the process's own image over it -- which user/regprobe.zig
        // checks rather than takes on trust.
        \\ xor %%eax, %%eax
        \\ xor %%ebx, %%ebx
        \\ xor %%ecx, %%ecx
        \\ xor %%edx, %%edx
        \\ xor %%esi, %%esi
        \\ xor %%edi, %%edi
        \\ xor %%ebp, %%ebp
        \\ xor %%r8d, %%r8d
        \\ xor %%r9d, %%r9d
        \\ xor %%r10d, %%r10d
        \\ xor %%r11d, %%r11d
        \\ xor %%r12d, %%r12d
        \\ xor %%r13d, %%r13d
        \\ xor %%r14d, %%r14d
        \\ xor %%r15d, %%r15d
        \\ iretq
        :
        : [cr3] "{rdi}" (cr3),
          [frame] "{rsi}" (frame_rsp),
          [fpu] "{r8}" (fpu_area),
          [gsk] "{r10}" (gs_kernel_base),
        : "memory"
    );
    unreachable;
}
