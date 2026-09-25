//! wait(2) on x86_64: a parent that sleeps until its child is done.
//!
//! `fork` made a second process (#194). This is the call that tells the first
//! one how the second went, and two separate things were missing:
//!
//!   - **nothing was ever recorded to reap.** `sched.exit` marked the Thread
//!     a zombie and stopped. The only code that put a Process on its parent's
//!     zombie list was `kill`. So a child's exit status could not be learned
//!     here by any route.
//!
//!   - **`wait` did not wait.** It reaped if there was something and answered
//!     ECHILD otherwise, which is the wrong answer for the one case that
//!     matters: a parent that forks and waits.
//!
//! What this will not let pass:
//!
//!   - **a wait that does not wait.** The probe's parent calls `wait` before
//!     the child has run, and the child spends a long time in ring 3 before
//!     exiting. And `sched.wait_sleeps` counts the times a wait actually
//!     slept: zero means every check below was answered without anything ever
//!     waiting, which is a kernel that passes for the wrong reason.
//!
//!   - **the wrong child, or no exit code.** The parent requires the PID
//!     `fork` gave it and the code the child exited with, through a pointer
//!     it supplied.
//!
//!   - **a wait with nothing to wait for.** The parent waits a second time
//!     and must be told ECHILD. Sleeping there is the failure a program
//!     cannot recover from: it never runs again and the boot stops with no
//!     message.

const console = @import("arch/x86_64/console.zig");
const vfs = @import("fs/vfs.zig");
const sched = @import("sched/scheduler.zig");

pub const PATH = "/bin/clarity-waitprobe";

const IMAGE: []const u8 = @embedFile("waitprobe_elf");

fn install() !void {
    const fd = try vfs.open(PATH, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), IMAGE);
    try vfs.close(@intCast(fd));
    if (n != IMAGE.len) return error.ShortWrite;
}

pub fn run() void {
    install() catch |e| {
        console.print("  [FAIL] wait: could not install the probe: ");
        console.println(@errorName(e));
        return;
    };

    const slept_before = sched.wait_sleeps;

    const t = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] wait: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };

    sched.run_queued();

    var ok = true;

    const code = sched.exit_code_of(t) orelse {
        console.println("  [FAIL] wait: the parent never finished");
        return;
    };
    if (code != 40) {
        console.print("  [FAIL] wait: the parent came back with ");
        console.print_dec(@intCast(@as(u32, @bitCast(code))));
        console.println(" — it wanted 40, and says above what it found");
        ok = false;
    }

    // The check that separates waiting from looking. Every other check here
    // passes on a kernel whose `wait` never sleeps, as long as the schedule
    // happens to put the child's exit first.
    const slept = sched.wait_sleeps - slept_before;
    if (slept == 0) {
        console.println("  [FAIL] wait: nothing ever slept — the parent was answered without waiting");
        ok = false;
    }

    if (ok) {
        console.print("  [ok] wait: the parent slept until its child exited, and was told which child and with what (slept ");
        console.print_dec(slept);
        console.println(" time(s))");
    }
}
