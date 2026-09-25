//! /bin/clarity-forkprobe — the first program on this machine to call fork(2).
//!
//! The syscall has been dispatched since the process model landed and nothing
//! has ever called it, which is why what follows had gone unnoticed. Whatever
//! this boot prints is a measurement, not a confirmation: the point is to find
//! out what the kernel actually does, not to watch it agree with a reading of
//! the source.

const console = @import("arch/x86_64/console.zig");
const vfs = @import("fs/vfs.zig");
const sched = @import("sched/scheduler.zig");

pub const PATH = "/bin/clarity-forkprobe";

const IMAGE: []const u8 = @embedFile("forkprobe_elf");

fn install() !void {
    const fd = try vfs.open(PATH, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), IMAGE);
    try vfs.close(@intCast(fd));
    if (n != IMAGE.len) return error.ShortWrite;
}

/// Run it and require both halves to have finished.
///
/// The parent exits 60 and the child 61, so "both were seen" is a statement
/// about these two and not about whatever ran last.
pub fn run() void {
    install() catch |e| {
        console.print("  [FAIL] fork: could not install the probe: ");
        console.println(@errorName(e));
        return;
    };

    const started = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] fork: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };
    // The id and not the pointer: `run_queued` below can free the Thread now
    // that its stack goes back, so what survives to be asked about afterwards
    // has to be the number.
    const tid = started.tid;

    sched.run_queued();

    const code = sched.exit_code_of(tid) orelse {
        console.println("  [FAIL] fork: the parent never finished");
        return;
    };
    if (code != 60) {
        console.print("  [FAIL] fork: the parent came back with ");
        console.print_dec(@intCast(code));
        console.println(" — it wanted 60, and says above what happened");
        return;
    }
    console.println("  [ok] fork: the parent forked and carried on");
}
