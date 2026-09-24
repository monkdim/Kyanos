//! /bin/clarity-regprobe — what a program can see of the kernel before it has
//! done anything.
//!
//! The answer used to be "every general register". `enter_userland` ends
//! `movq %rsp; swapgs; iretq`, and `iretq` pops RIP, CS, RFLAGS, RSP and SS
//! — nothing else — so rax through r15 reached ring 3 holding whatever the
//! kernel last had in them: the CR3 it had just loaded, the frame pointer,
//! addresses the ELF loader had walked. None of that is anything ring 3 is
//! entitled to know, and none of it cost a fault to obtain.
//!
//! Nothing here read it. The programs on this machine are written by the same
//! people as the kernel, which is the reason to close it now rather than when
//! something arrives that was not.
//!
//! The floating-point side was already clean, because `fxrstor` loads the
//! process's own image over the kernel's registers. The probe reads the xmm
//! file anyway: a thing believed because of what a comment says is a thing
//! not yet measured.

const console = @import("arch/x86_64/console.zig");
const vfs = @import("fs/vfs.zig");
const sched = @import("sched/scheduler.zig");

pub const PATH = "/bin/clarity-regprobe";

const IMAGE: []const u8 = @embedFile("regprobe_elf");

fn install() !void {
    const fd = try vfs.open(PATH, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), IMAGE);
    try vfs.close(@intCast(fd));
    if (n != IMAGE.len) return error.ShortWrite;
}

/// Run it and require it to have found nothing.
pub fn run() void {
    install() catch |e| {
        console.print("  [FAIL] registers: could not install the probe: ");
        console.println(@errorName(e));
        return;
    };

    const t = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] registers: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };

    sched.run_queued();

    const code = sched.exit_code_of(t) orelse {
        console.println("  [FAIL] registers: the probe never finished");
        return;
    };
    if (code == 0) {
        console.println("  [ok] registers: ring 3 starts with a register file the kernel chose");
        return;
    }
    console.print("  [FAIL] registers: the probe came back with ");
    console.print_dec(@intCast(code));
    console.println(" — it wanted 0, and says above what it found");
}
