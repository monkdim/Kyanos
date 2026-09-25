//! The gate for /bin/clarity-readprobe.
//!
//! Unlike every other gate on this boot, this one cannot decide on its own
//! whether the thing it tests worked: whether a line arrives depends on
//! whether somebody typed one. So it reports what happened and leaves the
//! judgement to whoever is watching -- `[ok]` when a line came through,
//! `[--]` when the console was silent, and `[FAIL]` only for the answers that
//! are wrong whether or not anyone typed.
//!
//! tools/serial_check_x86.py is the thing that types. On an ordinary boot
//! nobody does, and the `[--]` is the truthful line for that.

const console = @import("arch/x86_64/console.zig");
const sched = @import("sched/scheduler.zig");
const stdin = @import("drivers/stdin.zig");
const arch_timer = @import("arch/x86_64/timer.zig");
const vfs = @import("fs/vfs.zig");
const dispatch = @import("syscall/dispatch.zig");

const IMAGE = @embedFile("readprobe_elf");
const PATH = "/bin/clarity-readprobe";

const GOT_BOTH: i32 = 0;
const QUIET: i32 = 71;
const GOT_ONE: i32 = 72;

/// How many polls per hundredth of a second a waiting read may cost.
///
/// The wait wakes on interrupts, and the timer is the one that is always
/// there, so the natural answer is one poll per tick -- which is what both
/// architectures measure: 300 polls over 300 hundredths on x86_64, 291 over
/// 329 on aarch64. The bound is ten times that plus a hundred, because the
/// thing it exists to catch is not a slow drift but a loop that stopped
/// giving the CPU up at all, and that lands three to four orders of
/// magnitude away: 11,882,275 and 2,922,091 respectively. A tight bound here
/// would fail on a machine with a faster tick and catch nothing a loose one
/// misses.
const POLLS_PER_CENTI: u64 = 10;
const POLLS_SLACK: u64 = 100;

fn install(path: []const u8, bytes: []const u8) !void {
    const fd = try vfs.open(path, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), bytes);
    try vfs.close(@intCast(fd));
    if (n != bytes.len) return error.ShortWrite;
}

/// The byte count is part of it. "It read a line" and "it read nothing and
/// said so" are the same sentence without a number in it.
fn say_ok(what: []const u8) void {
    console.print("  [ok] console read: a program read ");
    console.print(what);
    console.print(" — ");
    console.print_dec(dispatch.console_bytes_read());
    console.println(" bytes in all");
}

pub fn run() void {
    install(PATH, IMAGE) catch |e| {
        console.print("  [FAIL] console read: could not install the probe: ");
        console.println(@errorName(e));
        return;
    };

    const started = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] console read: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };
    // The id and not the pointer: `run_queued` below can free the Thread now
    // that its stack goes back, so what survives to be asked about afterwards
    // has to be the number.
    const tid = started.tid;
    const polls_before = stdin.polls;
    const ticks_before = arch_timer.centiseconds();
    sched.run_queued();

    // What the wait cost. A read that waits by asking the keyboard as fast as
    // the CPU can ask is indistinguishable, in every other line this gate
    // prints, from one that sleeps — the bytes come back either way. This is
    // the difference, and it is the whole reason the number is here.
    const polls = stdin.polls - polls_before;
    const centis = arch_timer.centiseconds() - ticks_before;
    console.print("  console read: ");
    console.print_dec(polls);
    console.print(" polls of the keyboard over ");
    console.print_dec(centis);
    console.println(" hundredths of a second of waiting");

    const allowed = centis * POLLS_PER_CENTI + POLLS_SLACK;
    if (polls > allowed) {
        console.print("  [FAIL] console read: the wait spun — ");
        console.print_dec(polls);
        console.print(" polls where ");
        console.print_dec(allowed);
        console.println(" is the most a loop that gives the CPU up should need");
    }

    const code = sched.exit_code_of(tid) orelse {
        console.println("  [FAIL] console read: the probe never finished");
        return;
    };
    switch (code) {
        GOT_BOTH => say_ok("two lines from fd 0, each whole"),
        GOT_ONE => say_ok("one line from fd 0, and the console then went quiet"),
        QUIET => console.println("  [--] console read: nothing was typed, so fd 0 gave end of input"),
        else => {
            console.print("  [FAIL] console read: the probe exited ");
            console.print_dec(@intCast(@as(u32, @bitCast(code))));
            console.println(" — it says above what it found");
        },
    }
}
