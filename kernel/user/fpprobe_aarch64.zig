//! /bin/clarity-fpprobe — does the kernel give a program its floating-point
//! registers back?
//!
//! Two different questions, and this program is the one that can separate
//! them, because it runs **alone**:
//!
//!   - a *system call*. The program asks the kernel for something and expects
//!     to come back with its own registers. Nothing else is running, so if a
//!     value is gone the system call path is what took it.
//!
//!   - a *preemption*. That needs two programs to be interesting, and the
//!     two-copy spin test is where it is asked.
//!
//! The registers under test are the ones nothing saves: `clarity_switch_to`
//! keeps the low halves of d8-d15, because that is the whole of what AAPCS64
//! makes callee-saved, and everything else in the vector file is only dead
//! *across a call* — which an exception is not.
//!
//! So: d0 (caller-saved), d20 (outside the saved range), the upper half of
//! v8 (inside the saved range, but only its bottom 64 bits are kept), and
//! FPCR, which is one register for the whole core and holds the rounding
//! mode a program chose.
//!
//! Each value is distinct, so a report says which one moved rather than only
//! that something did.

const NR_WRITE: u64 = 1;
const NR_EXIT: u64 = 12;

const D0: u64 = 0x0102_0304_0506_0708;
const D20: u64 = 0x1112_1314_1516_1718;
const V8_HI: u64 = 0x2122_2324_2526_2728;

/// FPCR with the rounding mode set to "toward minus infinity" (RMode = 0b10,
/// bits 23:22). A program that chose a rounding mode and silently got the
/// default back would compute different numbers for the rest of its life.
const FPCR_RM: u64 = 0b10 << 22;

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

fn load() void {
    asm volatile (
        \\fmov d0, %[a]
        \\fmov d20, %[b]
        \\mov  v8.d[1], %[c]
        \\msr  fpcr, %[d]
        :
        : [a] "r" (D0),
          [b] "r" (D20),
          [c] "r" (V8_HI),
          [d] "r" (FPCR_RM),
        : "d0", "d20", "v8", "memory"
    );
}

const Seen = struct { d0: u64, d20: u64, v8_hi: u64, fpcr: u64 };

fn read_back() Seen {
    // Plain locals rather than the struct's fields: an inline-asm output
    // operand has to be a name, not a field access.
    var a: u64 = 0;
    var b: u64 = 0;
    var c: u64 = 0;
    var d: u64 = 0;
    asm volatile (
        \\fmov %[a], d0
        \\fmov %[b], d20
        \\mov  %[c], v8.d[1]
        \\mrs  %[d], fpcr
        : [a] "=r" (a),
          [b] "=r" (b),
          [c] "=r" (c),
          [d] "=r" (d),
    );
    return .{ .d0 = a, .d20 = b, .v8_hi = c, .fpcr = d };
}

export fn _start() callconv(.C) noreturn {
    load();

    // The system call. Everything above is the program's own doing; if what
    // comes back is different, the kernel is what changed it.
    write("fpprobe: asking the kernel for something\n");

    const s = read_back();
    if (s.d0 != D0) {
        write("fpprobe: d0 did not survive a system call\n");
        exit(1);
    }
    if (s.d20 != D20) {
        write("fpprobe: d20 did not survive a system call\n");
        exit(2);
    }
    if (s.v8_hi != V8_HI) {
        write("fpprobe: the top half of v8 did not survive a system call\n");
        exit(3);
    }
    if (s.fpcr != FPCR_RM) {
        write("fpprobe: FPCR did not survive a system call\n");
        exit(4);
    }

    write("fpprobe: the floating-point file came back from a system call\n");
    exit(0);
}
