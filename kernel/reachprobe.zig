//! Which system calls does nothing exercise?
//!
//! Every other gate on this boot asks whether something works. This one asks
//! a question none of them can: of the calls the dispatcher implements, which
//! ones does no test ever make?
//!
//! That list matters here more than it would elsewhere, because this kernel
//! has a perfect record on it. Every implemented path found with no caller
//! has turned out to be broken:
//!
//!   fork       a stub that would have reset the machine
//!   wait       did not wait -- reaped a zombie or gave up
//!   exec       killed the forked child that called it
//!   nanosleep  blocked its caller for ever; nothing woke a sleeper
//!
//! Four for four. So this is not hygiene, it is a prediction: whatever is on
//! the danger list below is where the next one of those is.
//!
//! How it tells the three cases apart
//!
//! `dispatch` records, per number, how many times it was called and what the
//! last call answered. This gate takes a snapshot of the counts *before*
//! running `/bin/clarity-reachprobe`, which calls every number once. Then:
//!
//!   answered, and the snapshot was non-zero   implemented, and a gate uses it
//!   answered, and the snapshot was zero       implemented, and NOTHING does
//!   ENOSYS                                    declared but not implemented
//!   skipped                                   has its own gate; see below
//!
//! The snapshot is what makes the middle row possible. Without it the probe's
//! own call is indistinguishable from a real one, and every number would look
//! exercised the moment this gate existed -- a test that makes its own
//! subject pass.
//!
//! The numbers come from `@typeInfo(Nr)` rather than a list written out here,
//! so a syscall added to the enum appears without anyone remembering to add
//! it.

const std = @import("std");
const console = @import("arch/x86_64/console.zig");
const vfs = @import("fs/vfs.zig");
const sched = @import("sched/scheduler.zig");
const dispatch = @import("syscall/dispatch.zig");

pub const PATH = "/bin/clarity-reachprobe";

const IMAGE: []const u8 = @embedFile("reachprobe_elf");

/// What the probe exits with.
const DONE: i32 = 66;

/// What an unimplemented number answers.
const ENOSYS: i64 = -@as(i64, @intFromEnum(dispatch.Errno.enosys));

/// The four the probe leaves alone, and the gate that covers each.
///
/// Kept beside the probe's own copy on purpose: these are reported as "not
/// probed" rather than silently missing, so the two lists disagreeing shows
/// up as a number in neither column.
const Skipped = struct { nr: u32, why: []const u8 };
const SKIP = [_]Skipped{
    .{ .nr = 10, .why = "fork, covered by the fork gate" },
    .{ .nr = 11, .why = "exec, covered by the fork+exec gate" },
    .{ .nr = 12, .why = "exit, does not return; every gate relies on it" },
    .{ .nr = 13, .why = "wait, blocks with a child; covered by the wait gate" },
};

/// The system calls that are implemented and that nothing but this probe
/// calls. **This list is a to-do, not a target.**
///
/// It is asserted rather than merely printed, because a number that nothing
/// exercises is exactly the kind of fact that rots quietly. Two things have
/// to fail: a newly implemented call with no test (it appears here), and a
/// call that *had* a test which stopped running (same). Shrinking it is the
/// point; changing it without noticing is what this refuses.
/// Measured, not guessed. The first draft of this list was written from
/// reading the dispatcher and got half of it wrong: `stat`, `fstat`, `lseek`
/// and `munmap` are declared but *not* implemented, so they answer ENOSYS and
/// belong in no danger list, and four that are implemented were missed.
const UNEXERCISED = [_]u32{
    3, // close -- the kernel uses vfs.close directly; the call is untried
    7, // mmap
    14, // getpid
    15, // getppid
    16, // kill
    34, // readdir -- `ls` goes through it, but only when somebody types `ls`
    40, // ioctl
    41, // clock_gettime -- and it is a stub that answers 0, see below
};

fn install() !void {
    const fd = try vfs.open(PATH, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), IMAGE);
    try vfs.close(@intCast(fd));
    if (n != IMAGE.len) return error.ShortWrite;
}

fn skip_reason(nr: u32) ?[]const u8 {
    for (SKIP) |s| {
        if (s.nr == nr) return s.why;
    }
    return null;
}

fn in_baseline(nr: u32) bool {
    for (UNEXERCISED) |u| {
        if (u == nr) return true;
    }
    return false;
}

fn name_of(nr: u32) []const u8 {
    inline for (@typeInfo(dispatch.Nr).Enum.fields) |f| {
        if (f.value == nr) return f.name;
    }
    return "?";
}

pub fn run() void {
    install() catch |e| {
        console.print("  [FAIL] reach: could not install the probe: ");
        console.println(@errorName(e));
        return;
    };

    // Before the probe runs, so the probe's own call does not count as
    // coverage. This is the whole mechanism.
    var before: [dispatch.TRACKED]u32 = undefined;
    for (dispatch.calls, 0..) |c, i| before[i] = c;

    const started = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] reach: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };
    const tid = started.tid;
    sched.run_queued();

    var ok = true;

    const code = sched.exit_code_of(tid);
    if (code == null or code.? != DONE) {
        console.print("  [FAIL] reach: the probe ended with ");
        if (code) |c| console.print_dec(@intCast(@as(u32, @bitCast(c)))) else console.print("nothing");
        console.println(", wanted 66 — so it did not get through the table");
        ok = false;
    }

    var exercised: u32 = 0;
    var unexercised: u32 = 0;
    var unimplemented: u32 = 0;
    var not_probed: u32 = 0;
    var unexpected: u32 = 0;
    var never_called: u32 = 0;

    inline for (@typeInfo(dispatch.Nr).Enum.fields) |f| {
        const nr: u32 = @intCast(f.value);
        if (nr < dispatch.TRACKED) {
            if (skip_reason(nr)) |_| {
                not_probed += 1;
            } else if (dispatch.calls[nr] == 0) {
                // Never dispatched at all, by the probe or anything else. The
                // probe is supposed to call every number it does not skip, so
                // this is the probe being wrong rather than a fact about the
                // kernel -- and it has to be said, because `last` for such a
                // number is still zero, which is not ENOSYS and would
                // otherwise read as "implemented and exercised by nothing".
                // A confident wrong answer is worse than a missing one.
                never_called += 1;
                console.print("  [FAIL] reach: nothing ever called ");
                console.print(f.name);
                console.print(" (");
                console.print_dec(nr);
                console.println(") — the probe skipped a number it should have poked");
            } else if (dispatch.last[nr] == ENOSYS) {
                unimplemented += 1;
            } else if (before[nr] == 0) {
                unexercised += 1;
                console.print("  reach: nothing but the probe calls ");
                console.print(f.name);
                console.print(" (");
                console.print_dec(nr);
                console.println(")");
                if (!in_baseline(nr)) {
                    unexpected += 1;
                    console.print("  [FAIL] reach: ");
                    console.print(f.name);
                    console.println(" is implemented and newly unexercised — it is not in the recorded list");
                }
            } else {
                exercised += 1;
                console.print("  reach: a gate exercises ");
                console.print(f.name);
                console.print(" (");
                console.print_dec(before[nr]);
                console.println(" calls before the probe)");
            }
        }
    }

    // And the other direction: something on the list that *is* exercised now.
    // Good news, and still a failure, because the list is what the next
    // reader will trust.
    for (UNEXERCISED) |u| {
        if (u < dispatch.TRACKED and before[u] != 0) {
            unexpected += 1;
            console.print("  [FAIL] reach: ");
            console.print(name_of(u));
            console.println(" is exercised now — take it off the recorded list");
        }
    }
    if (unexpected != 0 or never_called != 0) ok = false;

    console.print("  reach: ");
    console.print_dec(exercised);
    console.print(" of the syscall table's calls are exercised by a gate, ");
    console.print_dec(unexercised);
    console.print(" are implemented and exercised by nothing, ");
    console.print_dec(unimplemented);
    console.print(" answer ENOSYS, ");
    console.print_dec(not_probed);
    console.println(" have gates of their own");

    if (ok) {
        console.println("  [ok] reach: every implemented system call was accounted for, and the unexercised ones are the ones on the list");
    }
}
