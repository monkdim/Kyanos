//! /bin/clarity-regprobe — a program that looks at the registers it was
//! started with.
//!
//! The counterpart of user/regprobe_aarch64.zig, asking the same question of
//! the other architecture, and the answer used to be worse in one way and
//! better in another.
//!
//! Worse: `enter_userland` ends `movq %rsp; swapgs; iretq`, and `iretq` pops
//! RIP, CS, RFLAGS, RSP and SS — nothing else. Every general register reached
//! ring 3 holding whatever the kernel last put in it: the CR3 it had just
//! loaded, the frame pointer, addresses the ELF loader had walked.
//!
//! Better: the floating-point side was already clean, because `fxrstor` loads
//! the process's own FXSAVE image rather than leaving the kernel's registers
//! behind. This probe reads the xmm registers anyway — a thing believed
//! because of what a comment says is a thing not yet measured.
//!
//! The entry point is naked for the reason it is naked on the other side: a
//! Zig prologue is allowed to write to the registers under test, so a normal
//! function cannot answer the question at all. The first instruction is the
//! measurement.
//!
//! Folding with `or` rather than comparing one at a time: zero is the only
//! value whose bitwise-or with anything leaves it unchanged, so a single
//! non-zero bit anywhere in fifteen general registers and sixteen vector
//! registers survives to the end. What it cannot say is *which* register was
//! dirty — but the fix is one instruction sequence, so "one of them was" is
//! the whole of what a gate needs.
//!
//! Unlike the AArch64 side there is no register the kernel sets on purpose
//! here, so nothing is excluded: rax is the accumulator and its own incoming
//! value is folded in by the first instruction.

const NR_WRITE: u64 = 1;
const NR_EXIT: u64 = 12;

fn syscall3(nr: u64, a0: u64, a1: u64, a2: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
        : "rcx", "r11", "memory"
    );
}

fn write(buf: []const u8) void {
    var done: usize = 0;
    while (done < buf.len) {
        const n = syscall3(NR_WRITE, 1, @intFromPtr(buf.ptr) + done, buf.len - done);
        if (n <= 0) return;
        done += @intCast(n);
    }
}

fn exit(code: u64) noreturn {
    _ = syscall3(NR_EXIT, code, 0, 0);
    unreachable;
}

fn write_hex(v: u64) void {
    const digits = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        buf[2 + i] = digits[@intCast((v >> shift) & 0xF)];
    }
    write(&buf);
}

/// Everything the program was handed, folded into one number. Exported under
/// a plain name because the naked entry point jumps to it by that name.
export fn regprobe_report(folded: u64) callconv(.C) noreturn {
    if (folded == 0) {
        write("regprobe: every register was zero at entry\n");
        exit(0);
    }
    write("regprobe: the kernel left something in a register — folded ");
    write_hex(folded);
    write("\n");
    exit(1);
}

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
    // The general registers. rax is the accumulator, and the first `or`
    // folds in its own incoming value, so all fifteen are covered. rsp is
    // not among them: it is set from the IRET frame on purpose.
        \\ or %%rbx, %%rax
        \\ or %%rcx, %%rax
        \\ or %%rdx, %%rax
        \\ or %%rsi, %%rax
        \\ or %%rdi, %%rax
        \\ or %%rbp, %%rax
        \\ or %%r8,  %%rax
        \\ or %%r9,  %%rax
        \\ or %%r10, %%rax
        \\ or %%r11, %%rax
        \\ or %%r12, %%rax
        \\ or %%r13, %%rax
        \\ or %%r14, %%rax
        \\ or %%r15, %%rax
        // And the vector file, both halves of each register, through rbx —
        // which has already been folded in, so using it as scratch loses
        // nothing. `movhlps` moves the high half down over the low one,
        // which destroys the register; that is fine, it has been read.
        \\ movq %%xmm0, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm0, %%xmm0
        \\ movq %%xmm0, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm1, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm1, %%xmm1
        \\ movq %%xmm1, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm2, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm2, %%xmm2
        \\ movq %%xmm2, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm3, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm3, %%xmm3
        \\ movq %%xmm3, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm4, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm4, %%xmm4
        \\ movq %%xmm4, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm5, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm5, %%xmm5
        \\ movq %%xmm5, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm6, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm6, %%xmm6
        \\ movq %%xmm6, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm7, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm7, %%xmm7
        \\ movq %%xmm7, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm8, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm8, %%xmm8
        \\ movq %%xmm8, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm9, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm9, %%xmm9
        \\ movq %%xmm9, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm10, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm10, %%xmm10
        \\ movq %%xmm10, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm11, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm11, %%xmm11
        \\ movq %%xmm11, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm12, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm12, %%xmm12
        \\ movq %%xmm12, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm13, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm13, %%xmm13
        \\ movq %%xmm13, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm14, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm14, %%xmm14
        \\ movq %%xmm14, %%rbx
        \\ or %%rbx, %%rax
        \\ movq %%xmm15, %%rbx
        \\ or %%rbx, %%rax
        \\ movhlps %%xmm15, %%xmm15
        \\ movq %%xmm15, %%rbx
        \\ or %%rbx, %%rax
        // System V passes the first argument in rdi.
        \\ mov %%rax, %%rdi
        \\ jmp regprobe_report
    );
}
