//! /bin/clarity-demo — a Clarity program, compiled and run by KyanOS.
//!
//! Everything before this point in the boot ran code written for the kernel:
//! Zig for the kernel itself, and one small Zig user program written by hand
//! to exercise the loader. This is the first thing that is none of those — a
//! Clarity source file, compiled by `clarity cc --freestanding` to C, linked
//! against kernel/user/libc, loaded out of the filesystem and run in ring 3.
//!
//! It is the second process, which is why it is a separate module rather than
//! more of initprog.zig: reaching it at all means the first process exited
//! and the kernel carried on, which nothing had ever required.

const console = @import("arch/x86_64/console.zig");
const vfs = @import("fs/vfs.zig");
const sched = @import("sched/scheduler.zig");

pub const PATH = "/bin/clarity-demo";

/// The linked ELF, handed over by kernel/build.zig. Referenced as a slice and
/// written straight to the file — never copied into a local, because it is
/// tens of kilobytes and the boot stack is 16 KiB.
const IMAGE: []const u8 = @embedFile("demo_elf");

pub fn run() !void {
    const fd = try vfs.open(PATH, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), IMAGE);
    try vfs.close(@intCast(fd));
    if (n != IMAGE.len) return error.ShortWrite;

    console.print("  demo: wrote ");
    console.print_dec(@as(u64, @intCast(n)));
    console.print(" bytes to ");
    console.println(PATH);

    _ = try sched.spawn_user(PATH);
    sched.run_queued();
}
