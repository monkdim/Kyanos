//! The shell, started at the end of the boot.
//!
//! Not a gate. Every other program on this boot is asked a question with a
//! right answer; this one is asked nothing -- it reads what somebody types,
//! and on a boot with nobody there it reads end of input and exits. What the
//! kernel can say about it afterwards is that it ran and what it exited with,
//! and that is what this says.
//!
//! It runs last on purpose. The gates above it are the things it stands on --
//! a console that can be read, fork, exec, a wait that waits -- and a shell
//! that started before them would fail for reasons that have nothing to do
//! with it.

const console = @import("arch/x86_64/console.zig");
const sched = @import("sched/scheduler.zig");
const vfs = @import("fs/vfs.zig");

const IMAGE = @embedFile("sh_elf");
const PATH = "/bin/clarity-sh";

fn install(path: []const u8, bytes: []const u8) !void {
    const fd = try vfs.open(path, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), bytes);
    try vfs.close(@intCast(fd));
    if (n != bytes.len) return error.ShortWrite;
}

pub fn run() void {
    install(PATH, IMAGE) catch |e| {
        console.print("  [FAIL] shell: could not install it: ");
        console.println(@errorName(e));
        return;
    };

    const started = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] shell: could not start it: ");
        console.println(@errorName(e));
        return;
    };
    // The id and not the pointer: `run_queued` below can free the Thread now
    // that its stack goes back, so what survives to be asked about afterwards
    // has to be the number.
    const tid = started.tid;
    sched.run_queued();

    const code = sched.exit_code_of(tid) orelse {
        console.println("  [FAIL] shell: it never finished");
        return;
    };
    console.print("  [ok] shell: ran and exited ");
    console.print_dec(@intCast(@as(u32, @bitCast(code))));
    console.println("");
}
