//! Kernel thread contexts on AArch64.
//!
//! Counterpart to arch/x86_64/context.zig, and the same shape: a Context is
//! everything needed to put a thread back exactly where it left off, and
//! `switch_to` swaps one for another. The difference is what "everything"
//! means on this architecture — see context.S.
//!
//! The address space rides along in the Context, as it does on x86, and for
//! the same reason: a thread resumed after a preemption that came back with
//! someone else's page tables is a bug that only appears once there are two
//! processes, which is exactly when it is hardest to find. The mechanism is
//! easier here, though. On x86 one register holds both halves of the address
//! space, so changing it while the kernel is running on it has to be timed
//! precisely; here the kernel lives in TTBR1 and only TTBR0 moves.

const std = @import("std");

/// Layout is fixed: context.S addresses every field by a hard-coded offset,
/// and the asserts below are what stops the two drifting apart.
pub const Context = extern struct {
    sp: u64 = 0,

    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    /// Frame pointer.
    x29: u64 = 0,
    /// Link register: where this thread resumes. For a thread that has run
    /// before, the instruction after its own call to `switch_to`; for a new
    /// one, the trampoline.
    x30: u64 = 0,

    /// The callee-saved floating-point registers, d8 through d15 — the low 64
    /// bits of v8-v15, which is all the ABI makes callee-saved. Everything
    /// else in the vector file is dead across a call, so there is nothing
    /// there to keep.
    d: [8]u64 = [_]u64{0} ** 8,

    /// The address space this thread runs in, as a TTBR0_EL1 value: the root
    /// table's physical address with the ASID in the top sixteen bits.
    ///
    /// Zero means "leave TTBR0 alone", which is what a kernel thread that
    /// was never given a process wants — and what stops a switch between two
    /// kernel threads from turning the low half back on while the kernel is
    /// deliberately running with it off.
    ttbr0: u64 = 0,

    /// TPIDR_EL1, which on this kernel points at the `UserSave` the thread's
    /// own `enter_user` laid down on its kernel stack — where the kernel goes
    /// back to when the process it is running stops being the kernel's
    /// problem. Zero for a thread that is not inside `enter_user`.
    ///
    /// It rides in the Context for the same reason `ttbr0` does, and the
    /// reason is worth stating plainly: a thread resumed with someone else's
    /// user save area would, at its process's next `exit`, unwind onto
    /// *another thread's* stack. Putting it anywhere the scheduler has to
    /// remember to swap by hand would mean every switch site has to remember
    /// — `yield`, the exit path, the way back to the boot context — and the
    /// one that forgot would be the one that only fails with two processes.
    tpidr: u64 = 0,
};

comptime {
    // context.S hard-codes every one of these.
    std.debug.assert(@offsetOf(Context, "sp") == 0);
    std.debug.assert(@offsetOf(Context, "x19") == 8);
    std.debug.assert(@offsetOf(Context, "x21") == 24);
    std.debug.assert(@offsetOf(Context, "x23") == 40);
    std.debug.assert(@offsetOf(Context, "x25") == 56);
    std.debug.assert(@offsetOf(Context, "x27") == 72);
    std.debug.assert(@offsetOf(Context, "x29") == 88);
    std.debug.assert(@offsetOf(Context, "d") == 104);
    std.debug.assert(@offsetOf(Context, "ttbr0") == 168);
    std.debug.assert(@offsetOf(Context, "tpidr") == 176);
}

/// Switch from `prev` to `next`. Saves `prev`'s callee-saved state and the
/// place to resume it, then restores `next` — including its address space,
/// if it has one.
///
/// Defined in context.S. It cannot be written here: moving SP and returning
/// through a restored link register has no expressible calling convention.
pub extern fn clarity_switch_to(prev: *Context, next: *const Context) callconv(.C) void;

pub const switch_to = clarity_switch_to;

/// The first thing a brand-new thread executes; see context.S.
extern fn clarity_thread_trampoline() callconv(.C) noreturn;

/// Set a context up so the first switch into it lands at `entry` with `arg`
/// as its argument. `stack_top` is one past the highest valid byte of a stack
/// the caller allocated.
pub fn init_kernel_thread(
    ctx: *Context,
    stack_top: u64,
    entry: *const fn (u64) callconv(.C) noreturn,
    arg: u64,
) void {
    // Sixteen bytes of stack holding the interrupt state `switch_to` reads
    // back on its way out — the same slot the outgoing thread wrote, which a
    // thread that has never run has to be given. Sixteen rather than eight
    // because SP must stay 16-byte aligned on this architecture; a misaligned
    // SP faults on the next stack access, not here.
    const sp = (stack_top & ~@as(u64, 0xF)) - 16;
    const daif_slot: *u64 = @ptrFromInt(sp);

    // Zero: interrupts unmasked. A thread that started with them masked could
    // never be preempted, and the first switch into a new thread usually
    // comes from inside the timer's own interrupt handler, where they are
    // masked — so this has to be stated rather than inherited.
    daif_slot.* = 0;

    ctx.* = .{};
    ctx.sp = sp;
    ctx.x19 = @intFromPtr(entry);
    ctx.x20 = arg;
    ctx.x30 = @intFromPtr(&clarity_thread_trampoline);
}
