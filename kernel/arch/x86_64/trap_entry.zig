//! Interrupt and exception entry: one stub per vector, one common path.
//!
//! What this replaces is a gate per vector pointing straight at a Zig
//! `callconv(.Interrupt)` function. That convention is correct as far as it
//! goes -- the compiler saves the register file and leaves by `iretq` -- but
//! it owns the whole entry and exit, and there is no room in it for the two
//! instructions this architecture requires at a ring boundary.
//!
//! `swapgs` is those two instructions. The CPU does not do it: an interrupt
//! taken in ring 3 enters the kernel with ring 3's GS base still loaded, and
//! it is the handler's business to exchange it for the kernel's and to
//! exchange it back on the way out. A handler that does not is reading the
//! per-CPU block through an address userspace chose.
//!
//! So the stubs are naked and the common path is written out: test the CS the
//! CPU pushed, `swapgs` if it says ring 3, save the register file, call into
//! Zig, restore it, `swapgs` back if the same CS says so, `iretq`. The test is
//! on the frame rather than on a flag the kernel keeps, because the frame is
//! what the CPU itself will act on.

const std = @import("std");

/// Everything on the stack when `dispatch` is called, lowest address first.
///
/// The general registers are pushed in reverse so that `rax` -- the one a
/// handler is most likely to want -- sits at offset zero and the whole block
/// pops back in order. `vector` and `error_code` are the stub's doing; the
/// five above them are the CPU's, and in 64-bit mode it pushes `rsp` and `ss`
/// unconditionally, from ring 0 as well as ring 3.
pub const TrapFrame = extern struct {
    rax: u64,
    rcx: u64,
    rdx: u64,
    rbx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

comptime {
    // The common path hardcodes these, so they are asserted rather than
    // trusted. `cs` at 24 bytes above the stub's own two pushes is what both
    // `swapgs` tests read.
    std.debug.assert(@offsetOf(TrapFrame, "vector") == 15 * 8);
    std.debug.assert(@offsetOf(TrapFrame, "error_code") == 16 * 8);
    std.debug.assert(@offsetOf(TrapFrame, "cs") - @offsetOf(TrapFrame, "vector") == 24);
    std.debug.assert(@sizeOf(TrapFrame) == 22 * 8);
}

/// Vectors on which the CPU pushes an error code of its own.
///
/// The others get a zero pushed in its place, so that every vector arrives at
/// the common path with the same frame and the `iretq` at the end can drop a
/// fixed sixteen bytes. Getting this list wrong does not produce a wrong
/// number in a dump -- it misaligns the frame, and `iretq` returns to the
/// error code instead of to the program.
pub fn pushes_error_code(comptime vec: usize) bool {
    return vec == 8 or (vec >= 10 and vec <= 14) or vec == 17 or vec == 21 or vec == 29 or vec == 30;
}

/// Filled in by idt.zig. Declared here because the common path calls it.
pub var dispatch: *const fn (*TrapFrame) callconv(.C) void = undefined;

/// The shared tail of every vector.
///
/// Two things in it are not obvious.
///
/// **The `swapgs` pair is conditional on the frame, and both tests read the
/// same word.** `testb $3, 24(%rsp)` is the CS the CPU pushed: its low two
/// bits are the privilege the interrupt came from, and by the time of the
/// second test the register file has been popped back so the offset is the
/// same again. An interrupt taken in ring 0 must not `swapgs` -- GS already
/// holds the per-CPU block there, and swapping would install the user's value
/// for the length of the handler.
///
/// **`rbp` is the alignment scratch.** The System V ABI wants `%rsp` 16-byte
/// aligned at a `call`, and seventeen pushes onto a frame the CPU aligned for
/// itself does not land there. `rbp` can be clobbered because its user value
/// is already on the stack and is popped back below; nothing else here is
/// free.
export fn trap_common() callconv(.Naked) void {
    asm volatile (
        \\ testb $3, 24(%rsp)
        \\ jz 1f
        \\ swapgs
        \\1:
        \\ pushq %r15
        \\ pushq %r14
        \\ pushq %r13
        \\ pushq %r12
        \\ pushq %r11
        \\ pushq %r10
        \\ pushq %r9
        \\ pushq %r8
        \\ pushq %rbp
        \\ pushq %rdi
        \\ pushq %rsi
        \\ pushq %rbx
        \\ pushq %rdx
        \\ pushq %rcx
        \\ pushq %rax
        \\ movq %rsp, %rdi
        \\ movq %rsp, %rbp
        \\ andq $-16, %rsp
        \\ call trap_dispatch_c
        \\ movq %rbp, %rsp
        \\ popq %rax
        \\ popq %rcx
        \\ popq %rdx
        \\ popq %rbx
        \\ popq %rsi
        \\ popq %rdi
        \\ popq %rbp
        \\ popq %r8
        \\ popq %r9
        \\ popq %r10
        \\ popq %r11
        \\ popq %r12
        \\ popq %r13
        \\ popq %r14
        \\ popq %r15
        \\ testb $3, 24(%rsp)
        \\ jz 2f
        \\ swapgs
        \\2:
        \\ addq $16, %rsp
        \\ iretq
    );
}

export fn trap_dispatch_c(frame: *TrapFrame) callconv(.C) void {
    dispatch(frame);
}

/// One naked stub per vector: make the frame uniform, name the vector, jump.
///
/// The vector is written into the instruction stream rather than passed,
/// because there is nowhere to pass it -- every register still belongs to
/// whatever was interrupted.
fn Stub(comptime vec: usize) type {
    return struct {
        fn entry() callconv(.Naked) void {
            if (comptime pushes_error_code(vec)) {
                asm volatile (std.fmt.comptimePrint(
                        \\ pushq ${d}
                        \\ jmp trap_common
                    , .{vec}));
            } else {
                asm volatile (std.fmt.comptimePrint(
                        \\ pushq $0
                        \\ pushq ${d}
                        \\ jmp trap_common
                    , .{vec}));
            }
        }
    };
}

/// The address of vector `vec`'s stub, for the IDT gate.
pub fn stub_address(comptime vec: usize) u64 {
    return @intFromPtr(&Stub(vec).entry);
}
