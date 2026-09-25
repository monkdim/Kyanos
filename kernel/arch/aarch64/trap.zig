//! What happens when a process traps into the kernel.
//!
//! Everything EL0 does that EL1 has to deal with — every `svc`, every fault —
//! arrives at one vector entry, which builds a trap frame and calls
//! `aarch64_sync_lower` below. The frame is not a record of what happened; it
//! is the process's registers, and writing to it is how the kernel answers.
//! A system call's result is a store to the saved x0. Resuming a process
//! somewhere else is a store to the saved ELR.
//!
//! The numbers are the ones in syscall/dispatch.zig, which are the ones
//! stdlib/kernel_abi.clarity defines — so a program built for this kernel
//! makes the same call whichever architecture it is running on. Only two are
//! implemented; the rest of that table follows once there is a VFS and a
//! process table on this architecture to implement them against.
//!
//! One rule shapes the whole file: **the kernel never dereferences an address
//! userspace gave it.** Not because the address might be wrong — though it
//! might — but because PSTATE.PAN makes an EL1 access to EL0-accessible
//! memory fault on any core that implements it. Every user pointer is
//! translated through the process's own page tables first and then reached
//! through the kernel's direct map, which both obeys that rule and makes
//! validation something the hardware does rather than something this code
//! remembers to.

const std = @import("std");
const console = @import("console.zig");
const timer = @import("timer.zig");
const mmu = @import("mmu.zig");
const vm = @import("vm.zig");
const paging = @import("paging.zig");
const pmm = @import("../../mm/pmm.zig");
const line = @import("../../drivers/line.zig");
const stdin = @import("../../drivers/stdin.zig");
const cmdline = @import("../../boot/cmdline.zig");
const vfs = @import("../../fs/vfs.zig");
const sched = @import("../../sched/sched_aarch64.zig");

/// The interrupted process's state, as the vector entry laid it out.
/// `extern` because the offsets are shared with assembly and must not be
/// reordered: x0-x30 at 0..248, ELR at 248, SPSR at 256, FPSR and FPCR at
/// 264 and 272, and the vector file at 288. The asserts below are what stops
/// this and vectors.S drifting apart.
pub const Frame = extern struct {
    x: [31]u64,
    elr: u64,
    spsr: u64,

    /// The floating-point status and control registers. One pair for the
    /// whole core, so they belong to whoever was interrupted: FPCR holds the
    /// rounding mode a program chose, FPSR the exception flags it has
    /// accumulated.
    fpsr: u64,
    fpcr: u64,

    /// So `v` lands 16-byte aligned, which `stp q0, q1` requires.
    _pad: u64,

    /// q0-q31, two words each, in register order.
    ///
    /// All of them, not the eight the context switch keeps. `clarity_switch_to`
    /// saves the low halves of d8-d15 because that is the whole of what
    /// AAPCS64 makes callee-saved — which is the right answer for a *call*,
    /// and an exception is not one. A program interrupted halfway through an
    /// expression has live values everywhere in here.
    v: [64]u64,
};

comptime {
    // vectors.S hard-codes every one of these.
    std.debug.assert(@offsetOf(Frame, "x") == 0);
    std.debug.assert(@offsetOf(Frame, "elr") == 248);
    std.debug.assert(@offsetOf(Frame, "spsr") == 256);
    std.debug.assert(@offsetOf(Frame, "fpsr") == 264);
    std.debug.assert(@offsetOf(Frame, "fpcr") == 272);
    std.debug.assert(@offsetOf(Frame, "v") == 288);
    std.debug.assert(@sizeOf(Frame) == 800);
}

/// Exception class, ESR_EL1 bits [31:26].
const EC_SVC64: u64 = 0x15; // `svc` from AArch64
pub const EC_INSTRUCTION_ABORT: u64 = 0x20;
pub const EC_DATA_ABORT: u64 = 0x24;

/// Why `enter_user` returned. A process leaves the CPU for exactly one of
/// these reasons, and the caller has to be able to tell them apart — "it came
/// back" is not an outcome. An unhandled system call is not among them: that
/// is ENOSYS, and the process keeps running.
pub const EXIT_DONE: u64 = 0;
pub const EXIT_FAULT: u64 = 1;
/// The process asked to be replaced by another image. Unlike the two above
/// this is not the end of anything: `exec_path` names what to load, and the
/// caller of `enter_user` is expected to load it into the same process and
/// enter again.
///
/// On x86_64 `exec` does not return because a process there is a scheduled
/// thread and the call can simply never come back. Here a program is a
/// *nested call* the kernel makes — `enter_user` returns a status when the
/// program is done — so "never returns" would mean unwinding a frame that
/// something still owns. Leaving with a third status instead keeps that
/// structure: exec becomes an iteration of the loop that runs programs,
/// which is what it already was for the boot path.
pub const EXIT_EXEC: u64 = 2;

/// From syscall/dispatch.zig's `Nr`, which is stdlib/kernel_abi.clarity's
/// table. Deliberately the same numbers as the x86_64 side rather than a
/// convenient local set: a program that runs on one should make the same
/// call on the other.
const SYS_READ: u64 = 0;
const SYS_WRITE: u64 = 1;
const SYS_OPEN: u64 = 2;
const SYS_CLOSE: u64 = 3;
const SYS_BRK: u64 = 9;
const SYS_FORK: u64 = 10;
const SYS_EXEC: u64 = 11;
const SYS_EXIT: u64 = 12;
const SYS_WAIT: u64 = 13;
const SYS_READDIR: u64 = 34;

/// Negative errno, the way the x86_64 dispatcher returns them.
const EBADF: i64 = -9;
const ECHILD: i64 = -10;
const EAGAIN: i64 = -11;
const ENOMEM: i64 = -12;
const EFAULT: i64 = -14;
const ENOENT: i64 = -2;
const ENOTDIR: i64 = -20;
const EINVAL: i64 = -22;
const ENOSYS: i64 = -38;

/// A ceiling on one process's heap.
///
/// Without one, a single wild request — a garbage pointer, or a size computed
/// from an unchecked length — walks up through every physical page the machine
/// has before it can fail, and takes the machine with it. The caller sees the
/// same "you got less than you asked for" it already has to handle.
const HEAP_MAX: u64 = 64 * 1024 * 1024;

// The heap used to live here, as three module variables and a `set_heap`
// the loader called before entering a program. The comment above them said
// what it was waiting for: "it is the thing that has to become a per-process
// field the moment there are two." `fork` made two.
//
// It is `Process.brk` and `Process.brk_start` now — fields that have existed
// since the process table landed and that nothing filled in — reached through
// `sched.current_process()`. What that replaced was a guard comparing
// TTBR0_EL1 against the one break's address space, which could only ever
// refuse the second process rather than give it a heap of its own.

/// How much of a single `write` the kernel will copy in one go. A user
/// program can name any length it likes; this is the bound on what that can
/// cost, and it is the kernel's business rather than the caller's.
const WRITE_CHUNK: usize = 256;

pub const Fault = struct {
    ec: u64,
    esr: u64,
    far: u64,
    elr: u64,
};

/// What the last process to leave the CPU did. Read by the boot selftest;
/// replaced by per-process state once there is more than one process.
pub var last_fault: ?Fault = null;
pub var calls: u64 = 0;
pub var bytes_written: u64 = 0;
pub var exit_status: u64 = 0;

/// What the boot path's last `exec` asked for, copied out of the process
/// before its address space went away.
///
/// A thread keeps its own, in `Thread.exec_path`, because the path is written
/// inside the system call and read after the process has left EL0 — and a
/// thread can be preempted in between. This is the slot for the boot path,
/// which is not a thread, exactly as it has one for the system-call depth.
var boot_exec_path: [PATH_MAX]u8 = undefined;
var boot_exec_path_len: usize = 0;

/// How many times a process *asked* to be replaced, whether or not it was.
/// The boot compares this against the number of replacements that happened,
/// which is how it can say a refusal was refused by the kernel rather than
/// never attempted.
pub var execs: u64 = 0;

/// What the caller's own last `exec` asked for.
pub fn exec_path() []const u8 {
    if (sched.current_thread()) |t| return t.exec_path[0..t.exec_path_len];
    return boot_exec_path[0..boot_exec_path_len];
}

fn set_exec_path(path: []const u8) void {
    if (sched.current_thread()) |t| {
        @memcpy(t.exec_path[0..path.len], path);
        t.exec_path_len = path.len;
        return;
    }
    @memcpy(boot_exec_path[0..path.len], path);
    boot_exec_path_len = path.len;
}
pub var bad_call: u64 = 0;

/// The timer's tick count at the first system call and at the last one. Both
/// are read inside a trap from EL0, so any difference between them elapsed
/// while the process was running — which is how the kernel can tell that an
/// interrupt was delivered *to a process* and the process survived it, rather
/// than merely that time passed.
pub var ticks_entering: u64 = 0;
pub var ticks_leaving: u64 = 0;

pub fn reset() void {
    last_fault = null;
    calls = 0;
    bytes_written = 0;
    exit_status = 0;
    bad_call = 0;
    ticks_entering = 0;
    ticks_leaving = 0;
}

/// Run `entry` at EL0 with `user_sp` as its stack, and return when it stops
/// being the kernel's problem. The address space it runs in is whatever is
/// currently in TTBR0 — installing it is the caller's business, because the
/// caller is the one that knows which process this is.
pub fn enter_user(entry: u64, user_sp: u64) u64 {
    return enter_user_arg(entry, user_sp, 0);
}

/// The same, with one number handed to the program in x0. See user.S for why
/// that is not argv and what it is for.
pub fn enter_user_arg(entry: u64, user_sp: u64, arg: u64) u64 {
    // On this thread's own kernel stack, and that is the whole of what makes
    // two threads able to be in EL0 at once. `aarch64_enter_user` puts its
    // address in TPIDR_EL1, `clarity_switch_to` carries that from thread to
    // thread, and `aarch64_leave_user` reads it back — so the way home a
    // process unwinds through belongs to the thread that started it, not to
    // whichever one entered EL0 most recently.
    //
    // It outlives this frame in the only sense that matters: `leave_user`
    // restores SP to the value saved here, so the frame is not gone until
    // after the last read of the area inside it.
    return enter_user_full(entry, user_sp, arg).status;
}

/// What a program left behind: why it stopped, and what it said on the way
/// out. Two values because they answer different questions — `EXIT_DONE`
/// with a code of 1 is a program that ran correctly and failed its own
/// checks, which is not the same as a fault.
pub const Exit = struct {
    status: u64,
    code: u64,
};

/// The whole answer, and the only one that is safe to read when more than one
/// program is running: `code` comes out of this thread's own save area rather
/// than the global below.
pub fn enter_user_full(entry: u64, user_sp: u64, arg: u64) Exit {
    var save: UserSave = undefined;
    save.exit_code = 0;
    const status = aarch64_enter_user(entry, user_sp, &save, arg);
    // Whatever the process was doing, it is not doing it any more. A call it
    // left through — `exit`, or a fault — never ran the code that undoes the
    // depth, so this is where it is undone.
    syscall_depth().* = 0;
    return .{ .status = status, .code = save.exit_code };
}

/// Resume a process at EL0 from a frame it was already stopped in, with
/// `user_sp` as its stack.
///
/// `enter_user_full` starts a program; this continues one. The frame is the
/// register file a vector entry recorded when the process trapped, so the
/// process comes back at the instruction after its `svc` with everything it
/// had there — which is what a forked child is: not a program that starts,
/// but a process that was running and now exists twice.
///
/// The address space is the caller's business, as it is for `enter_user`.
pub fn enter_user_frame(frame: *const Frame, user_sp: u64) Exit {
    // Copied onto this thread's stack with sixteen-byte alignment, because
    // `aarch64_enter_user_frame` reloads the vector file with `ldp q`, and an
    // unaligned pair access faults when SCTLR_EL1.A is set. That bit is not
    // set here, and its reset value is architecturally unknown, so the
    // guarantee is made rather than relied on — a caller holding the frame in
    // heap memory, which a forked child does, has no alignment to offer.
    var aligned: Frame align(16) = frame.*;
    var save: UserSave = undefined;
    save.exit_code = 0;
    const status = aarch64_enter_user_frame(&aligned, &save, user_sp);
    syscall_depth().* = 0;
    return .{ .status = status, .code = save.exit_code };
}

/// Where a thread's kernel state waits while its process runs at EL0.
///
/// The layout is user.S's, which addresses every field by a hard-coded
/// offset; the asserts below are what stops the two drifting apart. Nothing
/// in Zig ever reads a field — the type exists to give the area a size, an
/// alignment and a name, and to put that name somewhere a reader will find
/// it.
pub const UserSave = extern struct {
    /// x19-x30: the callee-saved set, which is exactly what `enter_user`'s
    /// caller is entitled to still have when it returns.
    regs: [12]u64,
    sp: u64,
    daif: u64,

    /// What the process passed to `exit`, written by `sys_exit` before it
    /// leaves EL0 — inside the system call, where nothing can preempt it.
    ///
    /// The global `exit_status` below says the same thing and cannot be
    /// trusted once two programs run at once: `enter_user` returns with
    /// interrupts on, so a thread can be preempted between its process
    /// exiting and its reading of that variable, and read the *other*
    /// program's exit code. Here the answer travels in the asking thread's
    /// own save area, which is what TPIDR_EL1 points at and what
    /// `clarity_switch_to` carries from thread to thread.
    ///
    /// Nothing in user.S touches it; it is past everything that file knows
    /// about, which is why the asserts stop at `daif`.
    exit_code: u64 = 0,
};

comptime {
    // user.S hard-codes the first three.
    std.debug.assert(@offsetOf(UserSave, "regs") == 0);
    std.debug.assert(@offsetOf(UserSave, "sp") == 96);
    std.debug.assert(@offsetOf(UserSave, "daif") == 104);
    std.debug.assert(@offsetOf(UserSave, "exit_code") == 112);
}

/// The running thread's save area, or null if this thread is not inside
/// `enter_user`. `aarch64_enter_user` sets TPIDR_EL1 and `aarch64_leave_user`
/// clears it, so "not null" means exactly "a process is running on this
/// thread".
fn current_save() ?*UserSave {
    const p = asm volatile ("mrs %[out], tpidr_el1"
        : [out] "=r" (-> u64),
    );
    if (p == 0) return null;
    return @ptrFromInt(p);
}

extern fn aarch64_enter_user(entry: u64, user_sp: u64, save: *UserSave, arg: u64) callconv(.C) u64;
extern fn aarch64_enter_user_frame(frame: *const Frame, save: *UserSave, user_sp: u64) callconv(.C) u64;
extern fn aarch64_leave_user(value: u64) callconv(.C) noreturn;

fn read_esr() u64 {
    return asm volatile ("mrs %[out], esr_el1"
        : [out] "=r" (-> u64),
    );
}

fn read_far() u64 {
    return asm volatile ("mrs %[out], far_el1"
        : [out] "=r" (-> u64),
    );
}

/// How deep the kernel is inside a system call, **on the calling thread**.
///
/// Not a lock and not a count of anything reentrant — a system call cannot
/// nest, so this is 0 or 1 per thread. It exists so the interrupt handler can
/// tell "the CPU was in the kernel on this thread's behalf" from "the CPU was
/// in userspace", which is the difference between a time slice it may end and
/// one it may not: switching threads out of a half-finished system call would
/// leave its frame on a stack nobody returns to until that thread is picked
/// again, and the kernel has no way yet to say what a system call interrupted
/// halfway through should do.
///
/// It was a module variable, which stopped being an answer the moment two
/// threads could be inside `enter_user` at once. Two things go wrong with one
/// counter, and the second is the dangerous one:
///
///   - two overlapping system calls on two threads count as one, so the
///     first to finish says nobody is in a system call while the other still
///     is.
///
///   - `enter_user_full` and `enter_user_frame` *set it to zero* when their
///     program leaves EL0, because a program that left through `exit` or a
///     fault never ran the decrement. With one counter that zeroing lands on
///     whichever thread happens to be mid-call, and its `-= 1` then takes an
///     unsigned zero below zero. Measured, by putting the one counter back:
///     `KERNEL PANIC (aarch64): integer overflow`, the moment the parent's
///     `wait` returns. That is this build, which has the safety checks on;
///     with them off it wraps to 0xFFFFFFFF instead, `in_syscall()` stays
///     true for the rest of the boot, EL0 is never preempted again and
///     nothing anywhere reports it.
///
///     Reachable from any program that forks — the child's exit need only
///     land while the parent is inside some other call — and unavoidable once
///     a parent can *block* in `wait`, because then it is inside a call for
///     the whole of its child's life.
///
/// The boot path has no Thread, so it has a slot of its own rather than
/// borrowing whichever thread was last current.
var boot_syscall_depth: u32 = 0;

fn syscall_depth() *u32 {
    if (sched.current_thread()) |t| return &t.syscall_depth;
    return &boot_syscall_depth;
}

/// Whether a system call is in flight on the thread that was interrupted.
pub fn in_syscall() bool {
    return @as(*const volatile u32, syscall_depth()).* != 0;
}

/// Let interrupts in. Returns the previous DAIF so it can be put back.
fn irq_unmask() u64 {
    const daif = asm volatile ("mrs %[out], daif"
        : [out] "=r" (-> u64),
    );
    asm volatile ("msr daifclr, #2" ::: "memory");
    return daif;
}

fn irq_restore(daif: u64) void {
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (daif),
        : "memory"
    );
}

/// Called from vector entry 8 with the process's registers on the kernel
/// stack. Returning from here resumes the process; calling
/// `aarch64_leave_user` does not.
///
/// Interrupts are unmasked for the length of the call. Exception entry from
/// EL0 sets PSTATE.I, and nothing used to clear it, so every system call ran
/// with the machine deaf — which was invisible while the timer was the only
/// source and fatal once the keyboard was one too: a program writing its
/// output was a program with nothing draining its keyboard, and everything
/// typed in that window past sixteen characters was gone. That was measured
/// at the shell before this line existed.
///
/// The syndrome registers are read *first*. ESR_EL1 and FAR_EL1 are one pair
/// for the whole core, and reading them after opening the door to another
/// exception would be reading whatever that one left behind.
export fn aarch64_sync_lower(frame: *Frame) callconv(.C) void {
    const esr = read_esr();
    const far = read_far();
    const ec = esr >> 26;

    if (ec == EC_SVC64) {
        syscall_depth().* += 1;
        const daif = irq_unmask();
        dispatch(frame);
        // Not reached when `dispatch` leaves through `aarch64_leave_user` —
        // `exit` does. That path does not return here at all, it returns
        // into `enter_user`'s caller, so the depth is cleared there instead.
        // Getting that wrong would not fail visibly: the count would stay at
        // one for the rest of the boot and preemption would quietly never
        // happen again.
        irq_restore(daif);
        syscall_depth().* -= 1;
        return;
    }

    // A fault. Nothing here can fix one — there is no demand paging, no
    // copy-on-write, nothing that would make retrying the instruction work —
    // so resuming would re-execute it and fault again, forever. The kernel
    // takes the CPU back instead, which is what killing a process is before
    // there is a process table to remove it from.
    last_fault = .{ .ec = ec, .esr = esr, .far = far, .elr = frame.elr };
    aarch64_leave_user(EXIT_FAULT);
}

fn dispatch(frame: *Frame) void {
    calls += 1;
    const number = frame.x[8];
    switch (number) {
        SYS_READ => {
            frame.x[0] = @bitCast(sys_read(frame.x[0], frame.x[1], frame.x[2]));
        },
        SYS_OPEN => {
            frame.x[0] = @bitCast(sys_open(frame.x[0], frame.x[1], frame.x[2]));
        },
        SYS_CLOSE => {
            frame.x[0] = @bitCast(sys_close(frame.x[0]));
        },
        SYS_READDIR => {
            frame.x[0] = @bitCast(sys_readdir(frame.x[0], frame.x[1], frame.x[2]));
        },
        SYS_WRITE => {
            if (calls == 1) ticks_entering = timer.ticks();
            // The result goes back the way the arguments came: into the saved
            // registers, which the vector entry restores on its way out.
            frame.x[0] = @bitCast(sys_write(frame.x[0], frame.x[1], frame.x[2]));
        },
        SYS_BRK => {
            frame.x[0] = @bitCast(sys_brk(frame.x[0]));
        },
        SYS_FORK => {
            frame.x[0] = @bitCast(sys_fork(frame));
        },
        SYS_WAIT => {
            frame.x[0] = @bitCast(sys_wait(frame.x[0], frame.x[1]));
        },
        SYS_EXEC => {
            frame.x[0] = @bitCast(sys_exec(frame.x[0]));
        },
        SYS_EXIT => {
            ticks_leaving = timer.ticks();
            exit_status = frame.x[0];
            if (current_save()) |save| save.exit_code = frame.x[0];
            aarch64_leave_user(EXIT_DONE);
        },
        else => {
            // Every other number in the table exists and is not implemented
            // here yet, and a number outside it does not exist at all. Both
            // are ENOSYS and neither is fatal: a process asking for something
            // this kernel cannot do gets an answer and carries on, which is
            // what lets a program built against the full table run against a
            // partial one.
            bad_call = number;
            frame.x[0] = @bitCast(ENOSYS);
        },
    }
}

/// fork(2) — this process, twice.
///
/// Returns in both, which is the whole of what the call means and the only
/// thing a program can use to tell the two apart: the parent is told the
/// child's PID and the child is told zero. Everything else about them is
/// identical, because the child *is* the parent — the same registers, the
/// same stack pointer, the same next instruction, and a copy of every page.
///
/// The frame is handed over rather than anything read out of it here. It is
/// the parent's register file as the vector entry recorded it, and the child
/// resumes from exactly that; `sched.fork` copies it, writes zero into the
/// saved x0, and starts a kernel thread that erets into it.
///
/// SP_EL0 is read here and not there. It is one register for the whole core
/// and an exception from EL0 does not touch it, so at this instant it still
/// holds the parent's user stack pointer — which is the only place the child
/// can get its own from, the frame having no room for it.
fn sys_fork(frame: *const Frame) i64 {
    const pid = sched.fork(frame, read_sp_el0()) orelse return EAGAIN;
    return @intCast(pid);
}

/// wait(wstatus, pid) — sleep until a child has exited, then reap it.
///
/// The argument order is the x86_64 dispatcher's, which is stdlib's: the
/// status pointer first and the PID second. Deliberately the same rather than
/// the more natural way round, because a program built against this table
/// should make the same call on either machine.
///
/// `pid` of 0 or -1 means any child. `wstatus` may be null, for a caller that
/// only wants to know a child finished.
///
/// The first thing this does is the *last* thing that could be got wrong: the
/// status pointer is checked before the wait, not after. A child reaped and
/// then unreported because the pointer turned out to be bad would be gone —
/// the zombie is consumed by the reap and there is no way to put it back.
///
/// Four-byte alignment is required rather than handled. An i32 across a page
/// boundary is two translations of two unrelated frames for one store, and
/// refusing is both honest and what every caller already does.
fn sys_wait(wstatus: u64, pid_arg: u64) i64 {
    const target: i32 = @bitCast(@as(u32, @truncate(pid_arg)));

    if (wstatus != 0) {
        if (wstatus & 3 != 0) return EINVAL;
        if (mmu.translate_user_write(wstatus) == null) return EFAULT;
    }

    const w = sched.waitpid(target) orelse return ECHILD;

    if (wstatus != 0) {
        // Translated again rather than remembered. The wait slept, and while
        // it slept this process could have been preempted any number of
        // times; the mapping is re-asked for at the moment it is used.
        const phys = mmu.translate_user_write(wstatus) orelse return EFAULT;
        const dst: *u32 = @ptrFromInt(vm.phys_to_virt(phys));
        dst.* = @bitCast(w.exit_code);
    }
    return w.pid;
}

fn read_sp_el0() u64 {
    return asm volatile ("mrs %[out], sp_el0"
        : [out] "=r" (-> u64),
    );
}

/// exec(path) — replace this process's image with the one at `path`.
///
/// Returns only when it fails, and that is the whole design of it. Once the
/// kernel leaves EL0 there is no way back to the instruction after the
/// `svc`: `enter_user` starts a program at its entry point, not in the
/// middle of a system call. So everything a program could reasonably have
/// handled is checked *here*, before leaving — an unreadable pointer is
/// EFAULT and a path that names nothing is ENOENT, and in both cases the
/// caller carries on with the image it has, which is what POSIX promises.
///
/// Past the leave, failure is fatal to the process, and that is also what a
/// real kernel does: once the old image is gone there is nothing left to
/// return to.
///
/// The path is copied out while this process's address space is still the
/// current one. A moment later it will not be — the caller is about to
/// replace it — and a pointer into the old image would then name whatever
/// the new one put at that address.
fn sys_exec(path_ptr: u64) i64 {
    var buf: [PATH_MAX]u8 = undefined;
    const path = copy_user_path(path_ptr, &buf) orelse return EFAULT;
    // Counted before the check, not after: a refused exec is still an exec
    // the process asked for, and the difference between this and the number
    // of replacements that actually happened is what says the refusal
    // reached the kernel rather than being invented by the program.
    execs += 1;
    const fd = vfs.open(path, 0, 0) catch return ENOENT;
    vfs.close(@intCast(fd)) catch {};
    set_exec_path(path);
    aarch64_leave_user(EXIT_EXEC);
}

/// write(fd, buf, len) — the console, and nothing else yet.
///
/// `buf` is a user virtual address. It is not dereferenced: `mmu.translate_
/// The longest path a process may hand the kernel.
///
/// Bounded because the string is copied into kernel memory before it is
/// used: an unbounded copy from a pointer a process chose is how a kernel
/// gets a stack overflow from userspace.
pub const PATH_MAX: usize = 256;

/// Copy a NUL-terminated path out of the process's memory.
///
/// Page by page and translated for reading, the same way sys_write reads a
/// buffer, because a path may straddle a page boundary and the two halves are
/// unrelated frames. A path with no terminator inside PATH_MAX bytes is
/// rejected rather than truncated: a silently shortened path names a
/// different file, which is worse than an error.
fn copy_user_path(ptr: u64, out: []u8) ?[]const u8 {
    var len: usize = 0;
    while (len < out.len) {
        const va = ptr + len;
        const phys = mmu.translate_user_read(va) orelse return null;
        const page_left = PAGE_SIZE - (va & (PAGE_SIZE - 1));
        const src: [*]const u8 = @ptrFromInt(vm.phys_to_virt(phys));
        var i: usize = 0;
        while (i < page_left and len < out.len) : (i += 1) {
            const c = src[i];
            if (c == 0) return out[0..len];
            out[len] = c;
            len += 1;
        }
    }
    return null;
}

/// open(2), for real files.
///
/// The flags are Linux's, because that is what the VFS was written against
/// and what stdlib/kernel_abi.clarity records: 0x40 is O_CREAT, the low two
/// bits are the access mode.
fn sys_open(path_ptr: u64, flags: u64, mode: u64) i64 {
    var buf: [PATH_MAX]u8 = undefined;
    const path = copy_user_path(path_ptr, &buf) orelse return EFAULT;
    const fd = vfs.open(path, @truncate(flags), @truncate(mode)) catch return ENOENT;
    files_opened += 1;
    return fd;
}

fn sys_close(fd: u64) i64 {
    if (fd <= 2) return EBADF; // the console's three are not the VFS's to close
    vfs.close(@intCast(fd)) catch return EBADF;
    return 0;
}

/// Counted so the boot log can say the path was used rather than present.
pub var files_opened: u64 = 0;

/// How much of one readdir the kernel stages at a time. A directory can hold
/// more entries than this; the call returns what fits and the next one picks
/// up where it left off, which is why the shell's `ls` loops.
const DIRENT_CHUNK: usize = 512;

/// readdir(fd, buf, len) — directory entries, packed by the VFS.
///
/// The shell had no `ls` for want of this: `cat` needed open and read, and a
/// listing needs a call that returns names rather than bytes. The layout is
/// vfs.Dirent — inode, record length, type, name length, the name, a NUL —
/// and the caller walks it by record length.
///
/// Zero means the directory is finished. A buffer too small for even one
/// entry is EINVAL rather than zero, so a caller cannot mistake "your buffer
/// is too small" for "there is nothing more".
fn sys_readdir(fd: u64, buf: u64, len: u64) i64 {
    if (len == 0) return EINVAL;
    if (fd <= 2) return EBADF;

    var staging: [DIRENT_CHUNK]u8 = undefined;
    const want = @min(len, staging.len);

    // The destination is checked *before* the directory is read, not after.
    // Reading it advances the descriptor past the entries it returned, and
    // there is no way to put them back: a bad pointer discovered halfway
    // through the copy would cost the caller entries it never saw. Nothing
    // is consumed until the whole buffer is known to be writable.
    var checked: usize = 0;
    while (checked < want) {
        const va = buf + checked;
        if (mmu.translate_user_write(va) == null) return EFAULT;
        const page_left = PAGE_SIZE - (va & (PAGE_SIZE - 1));
        checked += @min(want - checked, page_left);
    }

    const n = vfs.readdir(@intCast(fd), staging[0..want]) catch |e| return switch (e) {
        error.NotADirectory => ENOTDIR,
        error.BufferTooSmall => EINVAL,
        else => EBADF,
    };
    if (n == 0) return 0;

    // Page by page, the same as sys_read: the process's buffer is its pages,
    // not the kernel's, and two consecutive pages of it are unrelated frames.
    var done: usize = 0;
    while (done < n) {
        const va = buf + done;
        const phys = mmu.translate_user_write(va) orelse return EFAULT;
        const page_left = PAGE_SIZE - (va & (PAGE_SIZE - 1));
        const m = @min(n - done, page_left);
        const dst: [*]u8 = @ptrFromInt(vm.phys_to_virt(phys));
        @memcpy(dst[0..m], staging[done..][0..m]);
        done += m;
    }
    dirents_read += 1;
    return @intCast(done);
}

/// Counted like the others, so the boot log can say a listing happened.
pub var dirents_read: u64 = 0;

/// Read a line from the console into the process's memory.
///
/// The mirror image of sys_write, and the difference is the whole point: this
/// asks the MMU to translate the user's buffer *for writing*. A page the
/// process may read but not write translates for sys_write and faults here,
/// which is the hardware refusing to let the kernel put data somewhere the
/// process itself could not — the case a kernel that dereferenced the pointer
/// directly would get wrong in the process's favour.
///
/// Returns 0 for end of input, which on a machine with no scheduler means
/// nobody typed anything for a few seconds. See drivers/stdin.zig.
fn sys_read(fd: u64, buf: u64, len: u64) i64 {
    if (len == 0) return 0;

    var staging: [line.MAX_LINE + 1]u8 = undefined;
    const want = @min(len, staging.len);

    // Descriptor zero is the console; anything above the three standard ones
    // is a file the process opened. The two differ in where the bytes come
    // from and in nothing else — both end up copied out below, through the
    // process's own page tables, translated for writing.
    const n = switch (fd) {
        0 => stdin.read(staging[0..want], cmdline.idle_ticks()),
        1, 2 => return EBADF, // stdout and stderr are not for reading
        else => vfs.read(@intCast(fd), staging[0..want]) catch return EBADF,
    };
    if (n == 0) return 0;

    // Page by page, for the reason sys_write is: two consecutive pages of the
    // process's buffer are two unrelated physical frames.
    var done: usize = 0;
    while (done < n) {
        const va = buf + done;
        const phys = mmu.translate_user_write(va) orelse {
            // Give back everything not yet delivered. A program that passes a
            // bad pointer should cost itself its input and nothing else; if
            // this line were dropped, the next program to read would find it
            // missing for a reason nothing in its own behaviour explains.
            stdin.unread(n);
            return EFAULT;
        };

        const page_left = PAGE_SIZE - (va & (PAGE_SIZE - 1));
        const m = @min(n - done, page_left);
        const dst: [*]u8 = @ptrFromInt(vm.phys_to_virt(phys));
        @memcpy(dst[0..m], staging[done..][0..m]);
        done += m;
    }
    bytes_read += done;
    return @intCast(done);
}

/// Counted for the same reason bytes_written is: so the boot log can say the
/// path was used rather than merely present.
pub var bytes_read: u64 = 0;

/// user_read` runs a stage-1 translation with EL0 permissions and reports the
/// physical address, which the kernel then reads through its own direct map.
/// A page the process cannot read is a fault the hardware reports here, as
/// EFAULT, rather than one the kernel takes on the process's behalf.
///
/// Page by page, because a buffer is only guaranteed contiguous in the
/// process's address space. Two consecutive user pages are two unrelated
/// physical frames, and copying across the boundary as though they were one
/// is a bug that needs a buffer to straddle a page to appear at all.
/// The first byte of each `write`, while `writer_trace_on` is set.
///
/// Who wrote, in what order — nothing else. It exists because "two programs
/// were preempted in favour of each other" is not visible in the console
/// output alone: a boot log holding `ABABAB` and one holding `AAABBB` look
/// alike to an assertion that only counts characters, and the second one is
/// the failure. The order is the measurement, so the order is what is kept.
///
/// Inert unless a selftest turns it on, which is why the buffer is small: it
/// is not a log, it is one experiment's worth of evidence.
pub var writer_trace: [64]u8 = undefined;
pub var writer_trace_len: usize = 0;
pub var writer_trace_on: bool = false;

pub fn writer_trace_reset() void {
    writer_trace_len = 0;
    writer_trace_on = true;
}

pub fn writer_trace_stop() []const u8 {
    writer_trace_on = false;
    return writer_trace[0..writer_trace_len];
}

fn sys_write(fd: u64, buf: u64, len: u64) i64 {
    if (fd != 1 and fd != 2) return EBADF;
    if (len == 0) return 0;

    var done: usize = 0;
    const want = @min(len, WRITE_CHUNK);
    while (done < want) {
        const va = buf + done;
        const phys = mmu.translate_user_read(va) orelse return EFAULT;

        // Stop at the end of this page; the next one is somewhere else.
        const page_left = PAGE_SIZE - (va & (PAGE_SIZE - 1));
        const n = @min(want - done, page_left);

        const src: [*]const u8 = @ptrFromInt(vm.phys_to_virt(phys));
        console.print(src[0..n]);
        done += n;
    }
    bytes_written += done;

    // After the write rather than before it, and only once it got somewhere:
    // a trace entry for a write that returned EFAULT would record something
    // the program never actually said.
    if (writer_trace_on and done > 0 and writer_trace_len < writer_trace.len) {
        if (mmu.translate_user_read(buf)) |phys| {
            const first: [*]const u8 = @ptrFromInt(vm.phys_to_virt(phys));
            writer_trace[writer_trace_len] = first[0];
            writer_trace_len += 1;
        }
    }
    return @intCast(done);
}

/// brk(0) reports the current break; brk(addr) asks for it to move there and
/// reports where it ended up — which may be short of what was asked for, and
/// which every caller already has to check.
///
/// Same shape as the x86_64 dispatcher's, including the silence on success:
/// a compiled Clarity program's allocator calls this every 64 KiB, and a
/// kernel that narrates each one buries the output of the program it is
/// running. A refusal still reports, because a refused brk is a failure the
/// log has to explain.
fn sys_brk(requested: u64) i64 {
    // Whose heap this is: the calling *process's*, which is a question only
    // the thread running it can answer. A process with no image behind it —
    // nothing in the table, or a program the boot path entered without
    // registering one — has no break and is told so, rather than being handed
    // somebody else's.
    const p = sched.current_process() orelse return @bitCast(@as(u64, 0));
    if (p.brk_start == 0) return @bitCast(@as(u64, 0));
    const space = p.address_space;

    if (requested == 0) return @intCast(p.brk);
    if (requested < p.brk_start) return @intCast(p.brk);
    if (requested > p.brk_start +| HEAP_MAX) return @intCast(p.brk);

    if (requested <= p.brk) {
        // Shrinking moves the break without unmapping. The pages stay until
        // the process is torn down, which is what the x86_64 side does too:
        // a program that shrinks its heap almost always grows it again, and
        // handing the frames back only to take them straight out again costs
        // more than holding them.
        p.brk = requested;
        return @intCast(p.brk);
    }

    var addr = (p.brk + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    const end = (requested + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    while (addr < end) : (addr += PAGE_SIZE) {
        const phys = pmm.alloc_page() orelse {
            // Say why. The caller only sees "you got less than you asked
            // for", which is the same answer for out of memory as for a
            // broken mapping.
            console.print("  brk: no physical page for ");
            console.print_hex(addr);
            console.println("");
            return @intCast(p.brk);
        };
        const zeroed: [*]u8 = @ptrFromInt(vm.phys_to_virt(phys));
        @memset(zeroed[0..PAGE_SIZE], 0);
        paging.map_page(space, addr, phys, paging.MAP_USER | paging.MAP_WRITE) catch |err| {
            console.print("  brk: cannot map ");
            console.print_hex(addr);
            console.print(": ");
            console.println(@errorName(err));
            pmm.free_page(phys);
            return @intCast(p.brk);
        };
        p.brk = addr + PAGE_SIZE;
    }
    p.brk = requested;
    return @intCast(p.brk);
}

const PAGE_SIZE: u64 = 4096;

/// Human-readable name for an exception class, for the failure path. Only the
/// ones a process can plausibly produce; anything else prints as its number,
/// which is more useful than a wrong guess.
pub fn ec_name(ec: u64) []const u8 {
    return switch (ec) {
        EC_SVC64 => "svc",
        EC_INSTRUCTION_ABORT => "instruction abort",
        EC_DATA_ABORT => "data abort",
        0x0E => "illegal execution state",
        0x18 => "trapped system register access",
        else => "unknown",
    };
}

pub fn report_fault(f: Fault) void {
    console.print("    ");
    console.print(ec_name(f.ec));
    console.print(" (ec=");
    console.print_hex(f.ec);
    console.print(") at pc=");
    console.print_hex(f.elr);
    console.print(" touching ");
    console.print_hex(f.far);
    console.println("");
}
