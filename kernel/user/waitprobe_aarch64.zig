//! /bin/clarity-waitprobe — does wait(2) wait?
//!
//! `fork` gave a parent a second process and no way to find out how it went.
//! This asks for the other half, and it asks in the order that makes the
//! answer mean something: the parent calls `wait` **immediately**, before the
//! child has done anything at all.
//!
//! That ordering is the whole test. A `wait` that reaps a zombie if one
//! happens to be lying about and answers ECHILD otherwise — which is what the
//! x86_64 side has — fails here and passes any test where the parent dawdles
//! first. So the child spends a long time at EL0 before it exits, and the
//! parent asks straight away.
//!
//! What the call owes the caller, and what is checked:
//!
//!   - it names the child. Not "a child": the PID `fork` returned.
//!   - it carries the exit code, through a pointer the caller supplied.
//!   - it says ECHILD once there is nothing left to wait for, rather than
//!     sleeping forever.
//!
//! The lines each half writes are in an order only a real wait produces: the
//! parent says it is waiting, the child then says it is running, and only
//! after that does the parent say it saw the child finish.
//!
//! Freestanding, no libc: number in x8, arguments in x0-x5, `svc #0`.

const NR_WRITE: u64 = 1;
const NR_FORK: u64 = 10;
const NR_EXIT: u64 = 12;
const NR_WAIT: u64 = 13;

const ECHILD: i64 = -10;

/// What the child exits with. Nothing else on this boot uses it, so the
/// parent seeing it is a statement about this child rather than about
/// whatever finished last.
const CHILD_CODE: i64 = 42;

/// Long enough that the parent is certainly inside `wait` before the child
/// exits. A tick is 10 ms and this runs at roughly a million iterations per
/// millisecond under TCG, so this is several ticks; the parent reaches its
/// `wait` within microseconds of the fork returning.
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
        // The child takes its time on purpose: the parent must be asleep in
        // `wait` by the time this finishes, or the test proves nothing.
        spin();
        write("waitprobe: the child is running\n");
        exit(@intCast(CHILD_CODE));
    }

    const child_pid = r;

    write("waitprobe: the parent is waiting\n");

    // Volatile so the second call cannot be given the first call's value: the
    // kernel writes this through the page tables, which the compiler has no
    // way to know about.
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
    // life of the machine, which is the failure a parent cannot recover from.
    const again = syscall3(NR_WAIT, @intFromPtr(&status), @bitCast(@as(i64, -1)), 0);
    if (again != ECHILD) {
        write("waitprobe: a second wait did not say there are no children left\n");
        exit(4);
    }

    exit(40);
}
