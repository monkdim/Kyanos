//! /bin/clarity-forkprobe for aarch64 — does fork(2) produce a second process?
//!
//! What a working fork owes the caller is exactly two things, and everything
//! else follows from them: it returns **twice**, once in each process, and
//! the two returns are told apart by the value — the child's PID to the
//! parent, zero to the child.
//!
//! On this architecture there is a third thing, and it is the one the whole
//! change is about. A program started here has always started at its entry
//! point with a register file the kernel chose; `fork` is the first time the
//! kernel has had to put a process back where it already was. So both halves
//! check that they came back with what they had: a pattern in x19 and x28,
//! which nothing but a full restore preserves, the same pattern in d0 and
//! d20, which are outside the eight registers a context switch keeps, and the
//! stack pointer they had before the call.
//!
//! And then that the two are really two. `shared` lives in this program's
//! data page. The child writes a different number into it; the parent spins
//! long enough to be preempted several times over, and then requires its own
//! number to still be there. A fork that handed both processes the same page
//! — which passes every other check here — fails this one.
//!
//! Freestanding, no libc, same ABI as the other programs here: number in x8,
//! arguments in x0-x5, `svc #0`, result back in x0.

const NR_WRITE: u64 = 1;
const NR_BRK: u64 = 9;
const NR_FORK: u64 = 10;
const NR_EXIT: u64 = 12;

/// The two halves' marks, in this program's data page.
///
/// A `var` and not a constant, and read through a volatile pointer, so the
/// compiler cannot decide it knows the answer: the whole question is what is
/// in the *page*, and a value folded into an immediate would be a question
/// about this program's compilation rather than about the kernel's copy.
const MARK_PARENT: u64 = 0x1111_2222_3333_4444;
const MARK_CHILD: u64 = 0x5555_6666_7777_8888;

/// The same question asked of the heap rather than the data page: two
/// different numbers, each written by one half into the first word of a page
/// it asked `brk` for.
const HEAP_PARENT: u64 = 0xAAAA_BBBB_CCCC_DDDD;
const HEAP_CHILD: u64 = 0xEEEE_FFFF_0101_2323;

var shared: u64 = MARK_PARENT;

fn read_shared() u64 {
    return @as(*volatile u64, &shared).*;
}

fn write_shared(v: u64) void {
    @as(*volatile u64, &shared).* = v;
}

/// Iterations the parent spends before it looks at its page.
///
/// A tick is 10 ms and this loop runs at roughly a million iterations per
/// millisecond under TCG, so 33 million is several ticks — long enough that
/// the child, which is runnable the moment `fork` returns and does almost
/// nothing before it writes, has certainly run. The kernel-side gate does not
/// take that on faith: it records when each half left EL0 and requires the
/// child's to have been first, so "the parent's page was untouched" is never
/// a statement about a child that had not started.
const SPIN: u64 = 0x200_0000;

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

fn read_sp() u64 {
    return asm volatile ("mov %[out], sp"
        : [out] "=r" (-> u64),
    );
}

fn spin() void {
    var i: u64 = 0;
    while (i < SPIN) : (i += 1) {
        asm volatile ("" ::: "memory");
    }
}

/// What `fork` answered, and what four registers held on the way back.
const Forked = struct {
    ret: i64,
    x19: u64,
    x28: u64,
    d0: u64,
    d20: u64,
};

/// The system call, with a pattern laid into registers nothing else would
/// keep and read straight back out on the other side.
///
/// One assembly block rather than Zig around a syscall wrapper, because the
/// question is about specific registers and the compiler is entitled to use
/// them for anything between two statements. x19 and x28 are callee-saved, so
/// a kernel that restored only the argument registers would still look
/// correct to any program that did not ask; d0 and d20 are outside the eight
/// halves `clarity_switch_to` keeps. Both halves of the fork run this, so
/// both answer for themselves.
fn fork_with_pattern(pat: u64) Forked {
    var ret: i64 = undefined;
    var x19: u64 = undefined;
    var x28: u64 = undefined;
    var d0: u64 = undefined;
    var d20: u64 = undefined;
    asm volatile (
        \\fmov d0, %[pat]
        \\fmov d20, %[pat]
        \\mov x19, %[pat]
        \\mov x28, %[pat]
        \\mov x8, #10
        \\svc #0
        \\mov %[ret], x0
        \\mov %[a], x19
        \\mov %[b], x28
        \\fmov %[c], d0
        \\fmov %[d], d20
        : [ret] "=&r" (ret),
          [a] "=&r" (x19),
          [b] "=&r" (x28),
          [c] "=&r" (d0),
          [d] "=&r" (d20),
        : [pat] "r" (pat),
        : "x0", "x8", "x19", "x28", "d0", "d20", "memory"
    );
    return .{ .ret = ret, .x19 = x19, .x28 = x28, .d0 = d0, .d20 = d20 };
}

const PATTERN: u64 = 0xC0FF_EE00_1234_5678;

export fn _start() callconv(.C) noreturn {
    write("forkprobe: one process so far\n");

    const sp_before = read_sp();
    const f = fork_with_pattern(PATTERN);

    if (f.ret < 0) {
        // A refusal is a legitimate answer and says so plainly. It is not the
        // same as a fork that claims to have worked and did not.
        write("forkprobe: fork was refused\n");
        exit(1);
    }

    const child = f.ret == 0;

    if (f.x19 != PATTERN or f.x28 != PATTERN) {
        write("forkprobe: general registers did not survive the fork\n");
        exit(if (child) 2 else 3);
    }
    if (f.d0 != PATTERN or f.d20 != PATTERN) {
        write("forkprobe: vector registers did not survive the fork\n");
        exit(if (child) 4 else 5);
    }
    if (read_sp() != sp_before) {
        write("forkprobe: the stack pointer did not survive the fork\n");
        exit(if (child) 6 else 7);
    }

    // Whose heap is whose.
    //
    // Both halves have one, and they are not the same heap. Each asks where
    // its break is, grows it by a page, writes its own number into the first
    // word of that page and requires to read its own number back — and the
    // parent checks again at the end, after the child has certainly been and
    // gone.
    //
    // A kernel that keeps one break for the whole machine fails this, however
    // it fails: if the child is refused it cannot grow at all, and if it is
    // answered it grows the *parent's* heap, mapping pages into a space the
    // child cannot even reach and writing the child's number where the parent
    // will find it.
    const brk0 = syscall3(NR_BRK, 0, 0, 0);
    if (brk0 <= 0) {
        write("forkprobe: this half has no heap of its own\n");
        exit(if (child) 10 else 11);
    }
    const want: u64 = @as(u64, @intCast(brk0)) + 0x1000;
    const grown = syscall3(NR_BRK, want, 0, 0);
    if (grown < @as(i64, @intCast(want))) {
        write("forkprobe: this half could not grow its heap\n");
        exit(if (child) 12 else 13);
    }

    // The break points one past the last valid byte, so the page that was
    // just added starts exactly where the break used to be.
    const heap_cell: *volatile u64 = @ptrFromInt(@as(usize, @intCast(brk0)));
    const mine: u64 = if (child) HEAP_CHILD else HEAP_PARENT;
    heap_cell.* = mine;
    if (heap_cell.* != mine) {
        write("forkprobe: this half could not write its own heap\n");
        exit(if (child) 14 else 15);
    }

    if (child) {
        write_shared(MARK_CHILD);
        write("forkprobe: I am the child\n");
        if (read_shared() != MARK_CHILD) {
            write("forkprobe: the child could not write its own page\n");
            exit(8);
        }
        exit(61);
    }

    write("forkprobe: I am the parent\n");
    spin();
    if (read_shared() != MARK_PARENT) {
        write("forkprobe: the child's write reached the parent — one page, not two\n");
        exit(9);
    }
    if (heap_cell.* != HEAP_PARENT) {
        write("forkprobe: the child's heap is the parent's heap\n");
        exit(16);
    }
    exit(60);
}
