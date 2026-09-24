//! /bin/clarity-regprobe — a program that looks at the registers it was
//! started with.
//!
//! `aarch64_enter_user` erets to EL0 with the general and floating-point
//! register files holding whatever the kernel last put in them. A program's
//! first instruction could read them, and what it found was kernel virtual
//! addresses: the pointer to its own `UserSave`, the ELF image the loader had
//! just walked, whatever the heap allocator was holding. None of that is
//! anything EL0 is entitled to know, and none of it took a fault to obtain.
//!
//! It is not a gap anything here exploits — the programs on this machine are
//! written by the same people as the kernel — which is exactly the reason to
//! close it now rather than when something arrives that was not.
//!
//! The probe has to read the registers *before* anything else runs, and a
//! Zig function's prologue is already something else running: it can spill,
//! set up a frame pointer, and clobber the very registers under test. So the
//! entry point is naked, its first instruction is the measurement, and the
//! only thing it does is fold every register into one value and hand that to
//! a function that may do whatever it likes.
//!
//! Folding with `orr` rather than comparing one at a time is deliberate:
//! zero is the only value whose bitwise-or with anything leaves it unchanged,
//! so a single non-zero bit anywhere in thirty general registers and
//! thirty-two vector registers survives to the end. What it cannot say is
//! *which* register was dirty — but the fix is one instruction sequence, so
//! "one of them was" is the whole of what a gate needs.
//!
//! x0 is excluded, because x0 is the one register the kernel sets on purpose
//! — see `aarch64_enter_user`. It is also the accumulator here, which is why
//! this program ignores the number it is given.

const NR_WRITE: u64 = 1;
const NR_EXIT: u64 = 12;

fn syscall3(nr: u64, a0: u64, a1: u64, a2: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [nr] "{x8}" (nr),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
        : "memory"
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

/// Everything the program was handed, folded into one number.
///
/// Exported under a plain name because the naked entry point branches to it
/// by that name, which is the one thing the assembler has to be able to
/// resolve.
export fn regprobe_report(folded: u64) callconv(.C) noreturn {
    if (folded == 0) {
        write("regprobe: every register but x0 was zero at entry\n");
        exit(0);
    }
    write("regprobe: the kernel left something in a register — folded ");
    write_hex(folded);
    write("\n");
    exit(1);
}

/// Naked, because the measurement is the first instruction.
///
/// A normal function would be entitled to a prologue, and a prologue is
/// allowed to write to the registers this exists to read. There is no
/// arrangement of a normal Zig function that makes "what was in x9 when the
/// kernel eret-ed" answerable; there is only this.
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
    // The general registers, x1 through x30. x0 is the accumulator and is
    // also the one register the kernel sets deliberately.
        \\orr  x0, x1, x2
        \\orr  x0, x0, x3
        \\orr  x0, x0, x4
        \\orr  x0, x0, x5
        \\orr  x0, x0, x6
        \\orr  x0, x0, x7
        \\orr  x0, x0, x8
        \\orr  x0, x0, x9
        \\orr  x0, x0, x10
        \\orr  x0, x0, x11
        \\orr  x0, x0, x12
        \\orr  x0, x0, x13
        \\orr  x0, x0, x14
        \\orr  x0, x0, x15
        \\orr  x0, x0, x16
        \\orr  x0, x0, x17
        \\orr  x0, x0, x18
        \\orr  x0, x0, x19
        \\orr  x0, x0, x20
        \\orr  x0, x0, x21
        \\orr  x0, x0, x22
        \\orr  x0, x0, x23
        \\orr  x0, x0, x24
        \\orr  x0, x0, x25
        \\orr  x0, x0, x26
        \\orr  x0, x0, x27
        \\orr  x0, x0, x28
        \\orr  x0, x0, x29
        \\orr  x0, x0, x30
        // And the vector file, read a doubleword at a time through x1 —
        // which has already been folded in, so using it as scratch loses
        // nothing. Both halves of each register, because the kernel's own
        // context switch only ever saves the low halves of v8-v15 and the
        // upper halves are nobody's to leave behind either.
        \\fmov x1, d0
        \\orr  x0, x0, x1
        \\mov  x1, v0.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d1
        \\orr  x0, x0, x1
        \\mov  x1, v1.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d2
        \\orr  x0, x0, x1
        \\mov  x1, v2.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d3
        \\orr  x0, x0, x1
        \\mov  x1, v3.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d4
        \\orr  x0, x0, x1
        \\mov  x1, v4.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d5
        \\orr  x0, x0, x1
        \\mov  x1, v5.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d6
        \\orr  x0, x0, x1
        \\mov  x1, v6.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d7
        \\orr  x0, x0, x1
        \\mov  x1, v7.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d8
        \\orr  x0, x0, x1
        \\mov  x1, v8.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d9
        \\orr  x0, x0, x1
        \\mov  x1, v9.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d10
        \\orr  x0, x0, x1
        \\mov  x1, v10.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d11
        \\orr  x0, x0, x1
        \\mov  x1, v11.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d12
        \\orr  x0, x0, x1
        \\mov  x1, v12.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d13
        \\orr  x0, x0, x1
        \\mov  x1, v13.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d14
        \\orr  x0, x0, x1
        \\mov  x1, v14.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d15
        \\orr  x0, x0, x1
        \\mov  x1, v15.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d16
        \\orr  x0, x0, x1
        \\mov  x1, v16.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d17
        \\orr  x0, x0, x1
        \\mov  x1, v17.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d18
        \\orr  x0, x0, x1
        \\mov  x1, v18.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d19
        \\orr  x0, x0, x1
        \\mov  x1, v19.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d20
        \\orr  x0, x0, x1
        \\mov  x1, v20.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d21
        \\orr  x0, x0, x1
        \\mov  x1, v21.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d22
        \\orr  x0, x0, x1
        \\mov  x1, v22.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d23
        \\orr  x0, x0, x1
        \\mov  x1, v23.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d24
        \\orr  x0, x0, x1
        \\mov  x1, v24.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d25
        \\orr  x0, x0, x1
        \\mov  x1, v25.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d26
        \\orr  x0, x0, x1
        \\mov  x1, v26.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d27
        \\orr  x0, x0, x1
        \\mov  x1, v27.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d28
        \\orr  x0, x0, x1
        \\mov  x1, v28.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d29
        \\orr  x0, x0, x1
        \\mov  x1, v29.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d30
        \\orr  x0, x0, x1
        \\mov  x1, v30.d[1]
        \\orr  x0, x0, x1
        \\fmov x1, d31
        \\orr  x0, x0, x1
        \\mov  x1, v31.d[1]
        \\orr  x0, x0, x1
        \\b    regprobe_report
    );
}
