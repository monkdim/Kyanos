//! SYSCALL/SYSRET fast-path setup.
//!
//! Userspace sets %rax to the syscall number and the arguments in
//! %rdi/%rsi/%rdx/%r10/%r8/%r9, then issues `syscall`. The CPU stashes the
//! return address in %rcx and RFLAGS in %r11, loads CS/SS from IA32_STAR, and
//! jumps to IA32_LSTAR — all *without* switching stacks. Everything else is
//! ours to do.
//!
//! Two things about the entry path are easy to get subtly wrong and fail in
//! ways that look like random corruption rather than a clear fault:
//!
//!   - The argument registers overlap the System V ones. %rdi already holds
//!     the first syscall argument, so writing the syscall number into it
//!     before reading it destroys that argument. The trampoline builds the
//!     argument block on the kernel stack and passes a pointer instead, which
//!     removes the shuffle entirely.
//!   - The user %rsp must be restored *after* the saved %rcx and %r11 are
//!     popped, not before: popping into %rsp first moves the stack pointer to
//!     the user stack and the remaining pops then read user memory.

const std = @import("std");
const dispatch = @import("../../syscall/dispatch.zig");
const gdt = @import("gdt.zig");

const IA32_EFER: u32 = 0xC000_0080;
const IA32_STAR: u32 = 0xC000_0081;
const IA32_LSTAR: u32 = 0xC000_0082;
const IA32_FMASK: u32 = 0xC000_0084;
const IA32_GS_BASE: u32 = 0xC000_0101;
const IA32_KERNEL_GS_BASE: u32 = 0xC000_0102;

/// Per-CPU scratch reached through %gs. The trampoline hardcodes the offsets,
/// so they are asserted rather than trusted.
pub const PerCpu = extern struct {
    kernel_rsp: u64 = 0,
    user_rsp_save: u64 = 0,
    current_thread: u64 = 0,
    /// Which block this is. Read through %gs at every entry from ring 3, and
    /// compared -- see `gs_is_kernel`. A block is the only thing at the GS
    /// base, so this is the only way to ask what the base is without
    /// FSGSBASE, which this kernel does not enable.
    magic: u64 = 0,
};

comptime {
    std.debug.assert(@offsetOf(PerCpu, "kernel_rsp") == 0);
    std.debug.assert(@offsetOf(PerCpu, "user_rsp_save") == 8);
    // Read by the entry check, which hardcodes it.
    std.debug.assert(@offsetOf(PerCpu, "magic") == 24);
}

pub const KERNEL_GS_MAGIC: u64 = 0x4B59_414E_4B52_4E4C; // "KYANKRNL"
pub const USER_GS_MAGIC: u64 = 0x4B59_414E_5553_4552; // "KYANUSER"

pub var per_cpu: PerCpu align(16) = .{ .magic = KERNEL_GS_MAGIC };

/// What ring 3's GS base holds on this kernel.
///
/// Every kernel with a `swapgs` has a value here; on a kernel where programs
/// can set their own it is theirs, saved and restored per thread. This one
/// has no call for that yet, so the value is the kernel's own choice and the
/// same for every process -- which is what makes it a single variable rather
/// than a field of a thread, and the day a program can set its own, this has
/// to become the latter or two threads will trade GS bases at every switch.
///
/// It is shaped like a PerCpu and carries a different magic on purpose. A
/// missing `swapgs` then reads a legible wrong answer -- caught and named by
/// `gs_is_kernel` -- rather than whatever a wild base happens to point at.
pub var user_gs: PerCpu align(16) = .{ .magic = USER_GS_MAGIC };

/// How many times the kernel was entered from ring 3, and how many times %gs
/// did not hold the per-CPU block when it was.
///
/// Both numbers, because either alone says nothing. "It was never wrong" is
/// also what a boot that never entered from ring 3 reports, and that boot
/// exercised nothing: the `swapgs` pairs only run at a real ring boundary. So
/// the gate reads the count too, and a count of zero is a failure of the test
/// rather than a pass.
pub var entries_from_ring3: u64 = 0;
pub var entries_total: u64 = 0;
pub var gs_wrong: u64 = 0;

/// Whether there is a per-CPU block to find yet.
///
/// The kernel takes interrupts before `init` below runs: `idt.init` ends with
/// `sti` and the PIT is already ticking, while GS.base is still the zero the
/// CPU booted with. Measured rather than assumed -- the check as first
/// written reported "1 of 75 entries" and the one was vector 32 at cs=0x8,
/// four lines into the boot log, exactly there.
///
/// That window is real and it is harmless: nothing reached from an interrupt
/// in it reads %gs, because the only things that do are the syscall
/// trampoline and this check, and neither can run yet. What it is not is
/// something to check, because there is nothing yet to be right about. The
/// invariant starts when the bases are written, so the counting does too.
pub var gs_ready: bool = false;

/// Does %gs name the kernel's block?
///
/// True on every entry into ring 0 if, and only if, the boundary did its
/// `swapgs`. There is no cheaper way to ask: reading a segment base needs
/// `rdgsbase`, which needs CR4.FSGSBASE, which this kernel does not set.
pub fn gs_is_kernel() bool {
    const magic = asm volatile ("movq %%gs:24, %[ret]"
        : [ret] "=r" (-> u64),
    );
    return magic == KERNEL_GS_MAGIC;
}

/// Stack the syscall trampoline switches to. Separate from the TSS's RSP0
/// because SYSCALL does not switch stacks itself and does not consult the TSS.
var syscall_stack: [16 * 1024]u8 align(16) = undefined;

pub fn init() void {
    per_cpu.kernel_rsp = @intFromPtr(&syscall_stack) + syscall_stack.len;

    // EFER.SCE — without this `syscall` is an invalid opcode.
    write_msr(IA32_EFER, read_msr(IA32_EFER) | 1);

    // STAR[47:32] is the kernel selector pair: SYSCALL loads CS from it and
    // SS from it+8, so 0x08/0x10. STAR[63:48] is the user base: SYSRET loads
    // SS from base+8 and CS from base+16, so 0x10 gives 0x18/0x20 — which is
    // why gdt.zig puts the user *data* descriptor first.
    write_msr(IA32_STAR, (@as(u64, gdt.KERNEL_CODE) << 32) |
        (@as(u64, gdt.STAR_USER_BASE) << 48));
    write_msr(IA32_LSTAR, @intFromPtr(&syscall_entry));

    // Clear TF, IF and DF on entry. IF especially: an interrupt taken between
    // the `syscall` and the stack switch would run on the user stack.
    write_msr(IA32_FMASK, 0x0000_0700);

    // The textbook arrangement, now that the interrupt stubs can hold it up.
    //
    // While the CPU is in ring 0, GS.base is the per-CPU block and the shadow
    // holds what ring 3 had; in ring 3 the two are the other way round, and
    // `swapgs` at every boundary is what turns one into the other. The boot
    // path is in ring 0, so it starts on the kernel side.
    //
    // This kernel spent a while with *both* bases set to the per-CPU block,
    // so that `swapgs` swapped a value for itself. That was not a design: it
    // was a workaround for interrupt entry doing no `swapgs` at all, which
    // meant a handler ran on whatever base ring 3 had. Harmless while one
    // process existed; with two it was a page fault at cr2=0x8 in ring 0, on
    // the instruction after the syscall path's `swapgs`, one boot in three --
    // a thread preempted in ring 3 was resumed from a context already in the
    // kernel, and its `iretq` carried the kernel's base back out with it.
    //
    // arch/x86_64/trap_entry.zig does the `swapgs` now, on entry from ring 3
    // and on the way back, which is what would have made this correct in the
    // first place. So the bases can differ again, and `user_gs` says what
    // ring 3 gets.
    write_msr(IA32_GS_BASE, @intFromPtr(&per_cpu));
    write_msr(IA32_KERNEL_GS_BASE, @intFromPtr(&user_gs));
    gs_ready = true;
}

fn read_msr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn write_msr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
          [msr] "{ecx}" (msr),
    );
}

/// SYSCALL entry. Naked: on entry %rsp still points at the *user* stack and
/// nothing may touch it before the switch.
///
/// Ten pushes before the call keeps the frame 16-byte aligned, which System V
/// requires at the call site; the saved %rax doubles as that padding.
///
/// The return path restores the argument registers rather than discarding
/// them. The ABI (System V AMD64, A.2.1) says a syscall destroys %rcx and
/// %r11 and *nothing else*, so a compiler is entitled to keep a live value in
/// %rsi or %rdx across one. This used to `addq $56, %rsp` over the saved
/// %rdi/%rsi/%rdx/%r10/%r8/%r9 and hand back whatever the kernel had left in
/// them, which is a program reading a garbage pointer out of a register it
/// had every right to trust. It went unnoticed while the only user program
/// made one call at a time and used nothing across them.
///
/// The tail needs no scratch register: %rcx and %r11 are loaded from the
/// kernel stack before %rsp is loaded from it, so the last read happens while
/// the stack is still there.
pub fn syscall_entry() callconv(.Naked) void {
    asm volatile (
        \\ swapgs
        \\ movq %rsp, %gs:8
        \\ movq %gs:0, %rsp
        \\ pushq %rcx
        \\ pushq %r11
        \\ pushq %gs:8
        \\ pushq %rax
        \\ pushq %r9
        \\ pushq %r8
        \\ pushq %r10
        \\ pushq %rdx
        \\ pushq %rsi
        \\ pushq %rdi
        \\ pushq %r15
        \\ pushq %r14
        \\ pushq %r13
        \\ pushq %r12
        \\ pushq %rbp
        \\ pushq %rbx
        \\ movq %rax, %rdi
        \\ movq %rsp, %rsi
        \\ call dispatch_syscall_c
        \\ popq %rbx
        \\ popq %rbp
        \\ popq %r12
        \\ popq %r13
        \\ popq %r14
        \\ popq %r15
        \\ popq %rdi
        \\ popq %rsi
        \\ popq %rdx
        \\ popq %r10
        \\ popq %r8
        \\ popq %r9
        \\ addq $8, %rsp
        \\ movq 16(%rsp), %rcx
        \\ movq 8(%rsp), %r11
        \\ movq (%rsp), %rsp
        \\ swapgs
        \\ sysretq
    );
}

/// Everything the trampoline pushed, in the order it pushed it, so a pointer
/// to the lowest one is a pointer to this struct.
///
/// It used to stop after the six argument registers, which was all any system
/// call needed to read. `fork` needs the rest: it has to build a child that
/// resumes where the parent will, and where the parent will resume is the
/// `rip`, `rsp` and `rflags` sitting at the top of this frame — the values
/// `sysretq` is about to put back.
pub const UserFrame = extern struct {
    // The callee-saved set, pushed last so it sits at the bottom of the
    // struct. The kernel preserves these for the *parent* by obeying the C
    // ABI, which is why they were never pushed — but a forked child has to be
    // given them, and by the time `fork` runs they are spilled somewhere on
    // the kernel stack rather than still in the registers. Six pushes and six
    // pops per system call is what it costs to be able to hand them over.
    rbx: u64,
    rbp: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

    a0: u64, // rdi
    a1: u64, // rsi
    a2: u64, // rdx
    a3: u64, // r10
    a4: u64, // r8
    a5: u64, // r9
    /// The system call number on the way in, and the return value on the way
    /// out — except that the trampoline pops it into nothing and `dispatch`'s
    /// return value in %rax is what the program sees. A forked child gets its
    /// zero from the IRET frame the kernel builds for it, not from here.
    rax: u64,
    /// The user stack, saved to the per-CPU area on entry and pushed here.
    rsp: u64,
    /// RFLAGS, which `syscall` puts in %r11.
    rflags: u64,
    /// Where the program resumes, which `syscall` puts in %rcx.
    rip: u64,
};

export fn dispatch_syscall_c(nr: u64, frame: *const UserFrame) callconv(.C) i64 {
    // The other ring boundary. `syscall_entry` has always swapped correctly,
    // so this has never been anything but true -- it is here because the
    // claim the gate makes is about every way into the kernel from ring 3,
    // and a boundary that is not counted is a boundary not claimed about.
    entries_from_ring3 += 1;
    entries_total += 1;
    if (!gs_is_kernel()) gs_wrong += 1;

    return dispatch.dispatch(nr, .{
        .a0 = frame.a0,
        .a1 = frame.a1,
        .a2 = frame.a2,
        .a3 = frame.a3,
        .a4 = frame.a4,
        .a5 = frame.a5,
        .user = frame,
    });
}
