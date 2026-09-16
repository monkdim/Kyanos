//! /bin/clarity-init — the first user program, as a compiler builds it.
//!
//! This replaces 47 bytes of machine code written out by hand inside the
//! kernel. Those bytes proved the CPU could reach ring 3 and come back, but
//! they proved almost nothing about the loader: one segment, no BSS, and a
//! layout the kernel itself had chosen. A linker's output is the real test —
//! it decides how many segments there are, what permissions each gets, and
//! how much of the last page is file-backed rather than zero-filled.
//!
//! Freestanding, with no libc, because KyanOS has none yet. The syscalls
//! are written out directly, which doubles as the smallest possible statement
//! of the ABI a libc will eventually sit on.

const std = @import("std");

const NR_READ: u64 = 0;
const NR_WRITE: u64 = 1;
const NR_OPEN: u64 = 2;
const NR_BRK: u64 = 9;
const NR_EXIT: u64 = 12;

/// What the kernel answers for a pointer it will not follow.
const EFAULT: i64 = -14;

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

fn write(fd: u64, buf: []const u8) i64 {
    return syscall3(NR_WRITE, fd, @intFromPtr(buf.ptr), buf.len);
}

/// Minimal hex, because a userspace with no libc still has to be able to say
/// what a number was. Fixed 16 digits: no allocation, no formatting library,
/// and nothing that could itself be the thing that is broken.
fn write_hex(v: u64) void {
    const digits = "0123456789abcdef";
    var buf: [19]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const nib: u8 = @intCast((v >> @intCast(60 - i * 4)) & 0xF);
        buf[2 + i] = digits[nib];
    }
    buf[18] = '\n';
    _ = write(1, &buf);
}

fn exit(code: u64) noreturn {
    _ = syscall3(NR_EXIT, code, 0, 0);
    unreachable;
}

/// A mutable copy of the greeting, so the image has a writable segment as
/// well as a read-only one. A single read-only PT_LOAD would not exercise
/// the loader's per-segment permissions at all.
var greeting = "hello from /bin/clarity-init\n".*;

/// Zero-initialised, so it lands in .bss — where p_memsz exceeds p_filesz and
/// the loader has to zero the difference rather than copy it. Getting that
/// wrong leaves "uninitialised" globals holding whatever was in the page,
/// which stays invisible until it is a very confusing bug.
var bss_probe: u64 = 0;

export fn _start() callconv(.C) noreturn {
    _ = write(1, &greeting);

    // Through a volatile pointer, so the compiler cannot fold this. It can
    // otherwise see that bss_probe is declared zero and nothing else writes
    // it, prove the branch, and emit the success message unconditionally —
    // which would make this pass whether or not .bss was actually zeroed,
    // i.e. test nothing at all.
    const probe: *volatile u64 = &bss_probe;
    probe.* +%= 1;
    if (probe.* == 1) {
        _ = write(1, "  [ok] user .bss zeroed\n");
    } else {
        _ = write(1, "  [FAIL] user .bss held garbage\n");
    }

    // A heap. brk(0) reports the current break; asking for more maps pages
    // that were not there before. This is what malloc will sit on.
    const before = syscall3(NR_BRK, 0, 0, 0);
    if (before <= 0) {
        _ = write(1, "  [FAIL] user heap: brk(0) reported no break\n");
        exit(1);
    }
    const want = @as(u64, @intCast(before)) + 8192;
    const after = syscall3(NR_BRK, want, 0, 0);
    if (after < 0 or @as(u64, @intCast(after)) != want) {
        _ = write(1, "  [FAIL] user heap: brk did not grow\n");
        _ = write(1, "    before ");
        write_hex(@bitCast(before));
        _ = write(1, "    wanted ");
        write_hex(want);
        _ = write(1, "    got    ");
        write_hex(@bitCast(after));
        exit(1);
    }

    // Checking the return value alone would prove nothing — the kernel could
    // return the number without mapping anything. Write through the new
    // break and read it back, volatile so neither end can be folded away. If
    // the page is not mapped this faults instead, which the boot log shows.
    const cell: *volatile u64 = @ptrFromInt(@as(usize, @intCast(before)) + 16);
    cell.* = 0xC0FFEE;
    if (cell.* == 0xC0FFEE) {
        _ = write(1, "  [ok] user heap: brk grew and the memory holds\n");
    } else {
        _ = write(1, "  [FAIL] user heap: wrote to brk memory, read back wrong\n");
    }

    // Floating point in ring 3. A compiled Clarity program is C, and C on
    // x86-64 keeps every double in an xmm register — so until the kernel sets
    // CR0.EM=0 and CR4.OSFXSR, the first arithmetic in such a program raises
    // #UD and it dies before printing anything. This is the smallest thing
    // that would have failed.
    //
    // Read through volatile pointers so the compiler cannot fold the whole
    // computation at compile time and emit a constant — which would make the
    // check pass on a CPU where SSE was never enabled, i.e. test nothing.
    const a: *volatile f64 = &fp_a;
    const b: *volatile f64 = &fp_b;
    const q = a.* / b.*;
    const bits: u64 = @bitCast(q);
    // 355/113 is 3.14159292035398... The quotient is not exact, but rounding
    // it is: one specific double, every time, on every conforming CPU. So the
    // check is a bit pattern rather than a tolerance.
    if (bits == 0x400921FB78121FB8) {
        _ = write(1, "  [ok] user sse: 355/113 in xmm\n");
    } else {
        _ = write(1, "  [FAIL] user sse: wrong quotient ");
        write_hex(bits);
    }

    // Pointers the kernel must refuse. Each of these was a page fault taken
    // in ring 0, which halts the machine, until the kernel started
    // translating user addresses through the process's own tables instead
    // of following them. The answer for all three is EFAULT, and the
    // program is still running afterwards to say so.
    var bad: u32 = 0;

    // An address in the user half that nothing maps.
    const unmapped: u64 = 0x0000_7FFF_F000_0000;
    const r_unmapped = syscall3(NR_WRITE, 1, unmapped, 8);
    if (r_unmapped != EFAULT) {
        bad += 1;
        _ = write(1, "  [FAIL] user pointers: an unmapped buffer was not refused: ");
        write_hex(@bitCast(r_unmapped));
    }

    // The kernel's own half. A kernel that follows this pointer prints its
    // own memory on the program's behalf.
    const kernel_half: u64 = 0xFFFF_8000_0000_1000;
    const r_kernel = syscall3(NR_WRITE, 1, kernel_half, 8);
    if (r_kernel != EFAULT) {
        bad += 1;
        _ = write(1, "  [FAIL] user pointers: a kernel address was not refused: ");
        write_hex(@bitCast(r_kernel));
    }

    // This program's own text, as a buffer for read(2). The page is
    // readable, so a kernel that translated it for reading (what write does,
    // and the easy mistake) would find nothing wrong and copy the file over
    // these instructions. It has to be translated for writing and refused.
    // The file is the one the kernel's filesystem self-test left behind.
    const fd = syscall3(NR_OPEN, @intFromPtr("/bin/hello.txt"), 0, 0);
    if (fd < 0) {
        bad += 1;
        _ = write(1, "  [FAIL] user pointers: could not open /bin/hello.txt: ");
        write_hex(@bitCast(fd));
    } else {
        const text: u64 = @intFromPtr(&_start);
        const r_text = syscall3(NR_READ, @intCast(fd), text, 7);
        if (r_text != EFAULT) {
            bad += 1;
            _ = write(1, "  [FAIL] user pointers: read into read-only text was not refused: ");
            write_hex(@bitCast(r_text));
        }
        // And a refused read must not have consumed the file: the same read
        // into a real buffer gets the whole contents.
        var got: [16]u8 = undefined;
        const r_real = syscall3(NR_READ, @intCast(fd), @intFromPtr(&got), got.len);
        if (r_real != 7 or !std.mem.eql(u8, got[0..7], "clarity")) {
            bad += 1;
            _ = write(1, "  [FAIL] user pointers: the real read got ");
            write_hex(@bitCast(r_real));
        }
    }

    if (bad == 0) {
        _ = write(1, "  [ok] user pointers: unmapped, kernel-half and read-only buffers refused with EFAULT; a real one read the file\n");
    }

    exit(0);
}

var fp_a: f64 = 355.0;
var fp_b: f64 = 113.0;

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = write(2, "  [FAIL] user panic\n");
    exit(1);
}
