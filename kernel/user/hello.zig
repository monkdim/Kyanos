//! /bin/clarity-hello — the smallest program that can be asked for by name.
//!
//! The x86_64 twin of user/hello_aarch64.zig, and deliberately the same
//! program: the two architectures should be able to fail the same test.
//!
//! It exists to be the *other* end of an exec: something a forked child can
//! turn into, whose voice and exit code nothing else on the boot produces, so
//! "the child became another program" is a statement about this program and
//! not about whatever happened to run next.
//!
//! It grows its heap by a page and writes to it before saying anything. That
//! is not decoration: a process that has just exec'd has a new address space,
//! a new break and a new entry in nothing that was written down before, and
//! the heap is the first thing that notices when any of those is stale.

const NR_WRITE: u64 = 1;
const NR_BRK: u64 = 9;
const NR_EXIT: u64 = 12;

/// Nothing else on this boot exits with it.
const CODE: u64 = 55;

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

/// A lump of .bss with a pattern in it, checked after the heap has been
/// grown and written.
///
/// A process that has just exec'd gets its break from the kernel, and the
/// kernel has to take it from the *new* image. Take it from the old one and
/// the new image's first allocation lands somewhere it does not own — inside
/// its own .bss if the old break was lower, which is what this would notice.
///
/// Would: this boot cannot make it fire, and that is worth saying rather than
/// implying otherwise. /bin/clarity-forkexec is the larger image, so its
/// break is *above* this one's and a stale break puts this program's heap
/// past its own memory rather than inside it. Taking the reset out was tried;
/// this check stayed quiet and the Clarity demo died instead, at its first
/// allocation — a user-mode write to address 8. The check is here because it
/// is the direct question, and it is the one that fires the day the image
/// being replaced is the smaller one.
var ballast: [4096]u8 = undefined;

export fn _start() callconv(.C) noreturn {
    for (&ballast, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);

    const brk0 = syscall3(NR_BRK, 0, 0, 0);
    if (brk0 <= 0) {
        write("hello: I was given no heap\n");
        exit(1);
    }
    const want: u64 = @as(u64, @intCast(brk0)) + 0x1000;
    if (syscall3(NR_BRK, want, 0, 0) < @as(i64, @intCast(want))) {
        write("hello: I could not grow my heap\n");
        exit(2);
    }
    const cell: *volatile u64 = @ptrFromInt(@as(usize, @intCast(brk0)));
    cell.* = 0x1234_5678_9ABC_DEF0;
    if (cell.* != 0x1234_5678_9ABC_DEF0) {
        write("hello: my heap did not keep what I put in it\n");
        exit(3);
    }

    for (&ballast, 0..) |b, i| {
        if (b != @as(u8, @truncate(i *% 7 +% 3))) {
            write("hello: my heap was put on top of my own memory\n");
            exit(4);
        }
    }

    write("hello: I am a different program than the one that asked for me\n");
    exit(CODE);
}
