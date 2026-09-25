//! /bin/clarity-waitprobe — does wait(2) wait?
//!
//! The AArch64 side asked this first (#197) and the answer here was worse
//! than the answer there. `wait` reaped a zombie if one happened to be lying
//! about and gave up otherwise — and nothing ever put one there: `exit`
//! marked the *thread* dead and stopped, so a Process was recorded against
//! its parent only by `kill`. A child's exit status could not be learned by
//! any route at all.
//!
//! So this asks in the order that makes the answer mean something: the parent
//! calls `wait` **immediately**, before the child has done anything, and the
//! child spends a long time in userspace before it exits.
//!
//!   - it names the child. Not "a child": the PID `fork` returned.
//!   - it carries the exit code, through a pointer the caller supplied.
//!   - it says ECHILD once there is nothing left, rather than sleeping
//!     forever.
//!
//! The lines each half writes come out in an order only a real wait produces:
//! the parent says it is waiting, the child then says it is running, and only
//! after that does the parent say it saw the child finish.
//!
//! Freestanding, no libc: number in rax, arguments in rdi/rsi/rdx, `syscall`.

const NR_WRITE: u64 = 1;
const NR_FORK: u64 = 10;
const NR_EXIT: u64 = 12;
const NR_WAIT: u64 = 13;

const ECHILD: i64 = -10;

/// What the child exits with. Nothing else on this boot uses it.
const CHILD_CODE: i32 = 42;

/// Long enough that the parent is certainly inside `wait` before the child
/// exits. The parent reaches its call within microseconds of the fork
/// returning; this is hundreds of millions of instructions under TCG.
const SPIN: u64 = 0x400_0000;

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

fn spin() void {
    var i: u64 = 0;
    while (i < SPIN) : (i += 1) {
        asm volatile ("" ::: "memory");
    }
}

export fn _start() callconv(.C) noreturn {
    write("waitprobe: one process so far\n");

    const r = syscall3(NR_FORK, 0, 0, 0);
    if (r < 0) {
        write("waitprobe: fork was refused\n");
        exit(1);
    }

    if (r == 0) {
        // The child takes its time on purpose: the parent has to be asleep in
        // `wait` by the time this finishes, or the test proves nothing.
        spin();
        write("waitprobe: the child is running\n");
        exit(@intCast(CHILD_CODE));
    }

    const child_pid = r;
    write("waitprobe: the parent is waiting\n");

    var status: i32 = -1;
    const got = syscall3(NR_WAIT, @intFromPtr(&status), @bitCast(@as(i64, -1)), 0);
    if (got != child_pid) {
        write("waitprobe: wait named the wrong child\n");
        exit(2);
    }
    if (@as(*volatile i32, &status).* != CHILD_CODE) {
        write("waitprobe: wait did not carry the child's exit code\n");
        exit(3);
    }

    write("waitprobe: the parent saw its child finish\n");

    // And nothing is left. A wait here must answer rather than sleep for the
    // life of the machine, which is the one failure a program cannot recover
    // from.
    const again = syscall3(NR_WAIT, @intFromPtr(&status), @bitCast(@as(i64, -1)), 0);
    if (again != ECHILD) {
        write("waitprobe: a second wait did not say there are no children left\n");
        exit(4);
    }

    exit(40);
}
