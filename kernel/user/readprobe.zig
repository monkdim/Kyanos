//! /bin/clarity-readprobe — can a program read what was typed at the console?
//!
//! Descriptor zero on this architecture was a descriptor like any other: it
//! went to `vfs.read`, found no inode behind it and answered EBADF. There was
//! no way for a program to read anything a person typed, which is most of
//! what stops this being an operating system somebody could use.
//!
//! What it asks, in an order that makes the answers mean something:
//!
//!   - a line arrives *whole*. The line editor hands back what it has when
//!     the newline comes, so a program that asks for a line gets a line and
//!     not the first keystroke.
//!   - a second line arrives after the first, from the same editor, with
//!     nothing of the first left in it.
//!   - and it says what it got, byte for byte, so the test that typed it can
//!     check the kernel did not quietly rearrange it.
//!
//! With nothing typed it exits QUIET rather than hanging: `read` gives back
//! zero once the console has been silent for the idle timeout, which is what
//! end of input means on a console nobody is at. That is the ordinary case on
//! a boot with no test driving it, and it must not cost the boot anything but
//! the timeout.
//!
//! Freestanding, no libc: number in rax, arguments in rdi/rsi/rdx, `syscall`.

const NR_READ: u64 = 0;
const NR_WRITE: u64 = 1;
const NR_EXIT: u64 = 12;

/// Exit codes. Distinct from every other program on this boot.
const GOT_BOTH: u64 = 0;
const QUIET: u64 = 71;
const GOT_ONE: u64 = 72;

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

fn write(text: []const u8) void {
    var done: usize = 0;
    while (done < text.len) {
        const n = syscall3(NR_WRITE, 1, @intFromPtr(text.ptr) + done, text.len - done);
        if (n <= 0) return;
        done += @intCast(n);
    }
}

fn exit(code: u64) noreturn {
    _ = syscall3(NR_EXIT, code, 0, 0);
    unreachable;
}

var buf: [256]u8 = undefined;

/// One line, or zero bytes if the console went quiet.
fn read_line() usize {
    const n = syscall3(NR_READ, 0, @intFromPtr(&buf), buf.len);
    if (n <= 0) return 0;
    return @intCast(n);
}

/// Echo what came back, with the newline the editor put on it left where it
/// is: a line that arrived without one would show up as two results run
/// together, which is a thing worth being able to see.
fn say(prefix: []const u8, n: usize) void {
    write(prefix);
    write(buf[0..n]);
}

export fn _start() callconv(.C) noreturn {
    write("readprobe: reading a line\n");
    const first = read_line();
    if (first == 0) {
        write("readprobe: nothing was typed\n");
        exit(QUIET);
    }
    say("readprobe: got ", first);

    const second = read_line();
    if (second == 0) {
        write("readprobe: only one line\n");
        exit(GOT_ONE);
    }
    say("readprobe: got ", second);
    exit(GOT_BOTH);
}
