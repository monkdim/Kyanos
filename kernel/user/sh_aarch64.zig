//! /bin/clarity-sh — a shell.
//!
//! Read a line, work out what it says, do it, repeat. That loop is the
//! oldest interface an operating system has, and it is the first thing on
//! this architecture that treats the machine as something to be *told* rather
//! than something to be watched.
//!
//! Freestanding, no libc, four system calls: read, write, brk, exit. What it
//! can do is bounded by that, and the bound is honest rather than hidden —
//! there is no `ls` because there is no filesystem on this architecture yet,
//! and no `run` because nothing can exec. When those exist, this is where
//! they attach.
//!
//! It ends on end of input. On a machine with nobody at the keyboard that is
//! three seconds and then a clean exit, which is what lets a boot with no one
//! watching still finish — and it is also just what a shell does when its
//! input closes.
//!
//! **Typing while this shell is busy used to lose characters, and both the
//! loss and the fix are measured rather than suspected.** The keyboard was
//! polled, and the only code that polled it was a read — so while a command
//! ran or its output was written, nothing drained the device's queue, which
//! is sixty-four events deep, or sixteen key presses. Forty characters typed
//! at a prompt the shell was reading all arrived; the same forty sent while
//! it printed `help` arrived as nine, with the Enter lost too, so the shell
//! was left holding half a command and then gave up on end of input.
//!
//! Two things were wrong and both had to be fixed. The keyboard now has its
//! own interrupt, routed through the GIC from the SPI the device tree names,
//! which empties the queue into a ring in the driver. And system calls now
//! run with interrupts unmasked — exception entry from EL0 sets PSTATE.I,
//! and nothing used to clear it, so the interrupt would have been useless
//! for exactly the window that loses characters: the one where this shell is
//! inside `write`. The same forty now arrive as forty.
//!
//! `tools/key_check.py` types them, without waiting for a prompt, and fails
//! if fewer come back.

const std = @import("std");

const NR_READ: u64 = 0;
const NR_WRITE: u64 = 1;
const NR_OPEN: u64 = 2;
const NR_CLOSE: u64 = 3;
const NR_EXEC: u64 = 11;
const NR_EXIT: u64 = 12;
const NR_READDIR: u64 = 34;

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

/// Write all of it, however many calls that takes.
///
/// write(2) is allowed to accept less than it was offered and say so, and
/// this kernel's does: it caps a single call at 256 bytes. A caller that
/// ignores the return value therefore loses everything past the cap — which
/// is what happened to `help` the first time this shell ran, cut off in the
/// middle of the sentence explaining why there is no `ls`.
fn write(s: []const u8) void {
    var done: usize = 0;
    while (done < s.len) {
        const n = syscall3(NR_WRITE, 1, @intFromPtr(s.ptr) + done, s.len - done);
        if (n <= 0) return; // the console is gone; there is nowhere to complain
        done += @intCast(n);
    }
}

fn read_line(buf: []u8) i64 {
    return syscall3(NR_READ, 0, @intFromPtr(buf.ptr), buf.len);
}

/// open(2). The path has to be NUL-terminated for the kernel, which is why
/// this takes a buffer rather than a slice: a shell argument is a slice of
/// the line it was typed on, and there is nowhere in it to put the zero.
fn open(path: [*:0]const u8) i64 {
    return syscall3(NR_OPEN, @intFromPtr(path), 0, 0);
}

fn close(fd: u64) void {
    _ = syscall3(NR_CLOSE, fd, 0, 0);
}

fn read_fd(fd: u64, buf: []u8) i64 {
    return syscall3(NR_READ, fd, @intFromPtr(buf.ptr), buf.len);
}

fn readdir_fd(fd: u64, buf: []u8) i64 {
    return syscall3(NR_READDIR, fd, @intFromPtr(buf.ptr), buf.len);
}

fn exit(code: u64) noreturn {
    _ = syscall3(NR_EXIT, code, 0, 0);
    unreachable;
}

fn write_dec(v: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n = v;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
        if (n == 0) break;
    }
    write(buf[i..]);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The first word, and everything after it with the spaces between them
/// preserved. Splitting further is the command's business: `echo` wants its
/// argument exactly as typed, spaces and all.
fn split(line: []const u8) struct { word: []const u8, rest: []const u8 } {
    var start: usize = 0;
    while (start < line.len and line[start] == ' ') start += 1;
    var end = start;
    while (end < line.len and line[end] != ' ') end += 1;
    var rest = end;
    while (rest < line.len and line[rest] == ' ') rest += 1;
    return .{ .word = line[start..end], .rest = line[rest..] };
}

/// How many commands were run and how many were not understood. Reported on
/// the way out, because a shell that silently did nothing and a shell that
/// ran everything look identical from a boot log otherwise.
var ran: u64 = 0;
var unknown: u64 = 0;

/// run PATH — hand this process over to the program at PATH.
///
/// It only returns when the kernel refused, and then it says why. There is
/// no fork, so this is exec and nothing else: the program takes the shell's
/// place. A shell that could start a program *beside* itself needs a second
/// process, which needs fork.
fn run(path: []const u8) void {
    if (path.len == 0) {
        write("run: which program?\n");
        return;
    }
    var buf: [128]u8 = undefined;
    if (path.len + 1 > buf.len) {
        write("run: that path is too long\n");
        return;
    }
    // The kernel reads a NUL-terminated path; a slice's length does not
    // survive the call.
    for (path, 0..) |c, i| buf[i] = c;
    buf[path.len] = 0;

    const rc = syscall3(NR_EXEC, @intFromPtr(&buf), 0, 0);
    // exec does not return when it works, so anything here is a refusal.
    write("run: cannot run ");
    write(path);
    if (rc == -2) write(" — no such file\n") else write(" — refused\n");
}

fn help() void {
    write(
        \\clarity-sh — the commands that exist
        \\  help          this
        \\  echo TEXT     write TEXT back
        \\  count TEXT    how many characters TEXT is
        \\  cat PATH      write out a file
        \\  ls [PATH]     list a directory, / if none is named
        \\  run PATH      replace this shell with the program at PATH
        \\  exit [N]      leave, with status N
        \\
        \\`run` is exec: the program takes this shell's place rather than
        \\starting beside it, because there is no fork yet. Nothing comes
        \\back here afterwards.
        \\
    );
}

/// cat, in the only shape four system calls allow.
fn cat(path_text: []const u8) void {
    if (path_text.len == 0) {
        write("clarity-sh: cat: no path\n");
        return;
    }
    // A NUL-terminated copy, because open(2) takes a C string and the
    // argument is a slice of the line it was typed on.
    var path: [96:0]u8 = undefined;
    if (path_text.len >= path.len) {
        write("clarity-sh: cat: path too long\n");
        return;
    }
    for (path_text, 0..) |c, i| path[i] = c;
    path[path_text.len] = 0;

    const fd = open(&path);
    if (fd < 0) {
        write("clarity-sh: cat: cannot open ");
        write(path_text);
        write("\n");
        return;
    }

    // Read until it stops giving anything, rather than once: a read may
    // return less than was asked for without being at the end.
    var buf: [128]u8 = undefined;
    var total: usize = 0;
    var last: u8 = 0;
    while (true) {
        const n = read_fd(@intCast(fd), &buf);
        if (n <= 0) break;
        const got: usize = @intCast(n);
        write(buf[0..got]);
        total += got;
        last = buf[got - 1];
    }
    close(@intCast(fd));

    // End the line if the file did not. Remembered as it goes rather than
    // looked up afterwards: `buf` holds only the last chunk read, so an index
    // computed from the running total points into the wrong place — which is
    // exactly the mistake the first version of this made.
    if (total > 0 and last != '\n') write("\n");
}

/// The record readdir(2) writes, from kernel/fs/vfs.zig. Read field by field
/// rather than as a struct: the buffer is a byte array a syscall filled, and
/// nothing guarantees the compiler's idea of the layout matches the kernel's.
/// The record length is what the walk steps by, so a record this shell does
/// not understand is skipped rather than fatal.
const DIRENT_HEADER: usize = 12;
const FILE_TYPE_DIRECTORY: u8 = 2;

fn read_u16(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

/// ls, now that there is a call that returns names.
///
/// One `readdir` returns as many whole entries as fit in the buffer and no
/// partial one, so the loop is the same shape `cat`'s is: ask again until it
/// answers zero. A directory bigger than one bufferful is the ordinary case
/// this handles, not an edge one.
fn ls(path_text: []const u8) void {
    var path: [96:0]u8 = undefined;
    const wanted = if (path_text.len == 0) "/" else path_text;
    if (wanted.len >= path.len) {
        write("clarity-sh: ls: path too long\n");
        return;
    }
    for (wanted, 0..) |c, i| path[i] = c;
    path[wanted.len] = 0;

    const fd = open(&path);
    if (fd < 0) {
        write("clarity-sh: ls: cannot open ");
        write(wanted);
        write("\n");
        return;
    }

    var buf: [256]u8 = undefined;
    var listed: u64 = 0;
    var failed = false;
    while (true) {
        const n = readdir_fd(@intCast(fd), &buf);
        if (n == 0) break;
        if (n < 0) {
            failed = true;
            // ENOTDIR is the one worth naming: `ls` on a file is a mistake
            // someone makes, and "not a directory" tells them what to do.
            if (n == -20) {
                write("clarity-sh: ls: not a directory: ");
                write(wanted);
                write("\n");
            } else {
                write("clarity-sh: ls: cannot read the directory\n");
            }
            break;
        }

        const got: usize = @intCast(n);
        var off: usize = 0;
        while (off + DIRENT_HEADER <= got) {
            const reclen: usize = read_u16(&buf, off + 8);
            if (reclen == 0 or off + reclen > got) break;
            const file_type = buf[off + 10];
            const name_len: usize = buf[off + 11];
            const name = buf[off + DIRENT_HEADER ..][0..name_len];
            write(name);
            // A trailing slash rather than a column of types: it is the one
            // distinction that changes what you type next.
            if (file_type == FILE_TYPE_DIRECTORY) write("/");
            write("\n");
            listed += 1;
            off += reclen;
        }
    }
    close(@intCast(fd));

    // An empty directory says so. Printing nothing at all is what a broken
    // listing looks like too, and the two should not be the same output —
    // but a failure has already said what went wrong, and following it with
    // "is empty" would describe the directory rather than the error. That
    // was measured with the system call stubbed out: the listing reported
    // both at once.
    if (listed == 0 and !failed) {
        write("clarity-sh: ls: ");
        write(wanted);
        write(" is empty\n");
    }
}

export fn _start() callconv(.C) noreturn {
    write("clarity-sh: type help\n");

    var line: [128]u8 = undefined;
    while (true) {
        write("$ ");
        const n = read_line(&line);

        // Anything but a positive count ends the session. Zero is end of
        // input — nobody is typing — and negative is an error the kernel
        // reported, which a shell cannot do anything useful about.
        if (n <= 0) {
            write("\nclarity-sh: end of input after ");
            write_dec(ran);
            write(if (ran == 1) " command" else " commands");
            if (unknown > 0) {
                write(", ");
                write_dec(unknown);
                write(" not understood");
            }
            write("\n");
            exit(0);
        }

        // read(2) returns the newline that ended the line; it terminates the
        // line rather than belonging to it.
        var len: usize = @intCast(n);
        if (len > 0 and line[len - 1] == '\n') len -= 1;

        const parts = split(line[0..len]);
        if (parts.word.len == 0) continue;

        ran += 1;
        if (eql(parts.word, "help")) {
            help();
        } else if (eql(parts.word, "echo")) {
            write(parts.rest);
            write("\n");
        } else if (eql(parts.word, "cat")) {
            cat(split(parts.rest).word);
        } else if (eql(parts.word, "ls")) {
            ls(split(parts.rest).word);
        } else if (eql(parts.word, "count")) {
            write_dec(parts.rest.len);
            write("\n");
        } else if (eql(parts.word, "run")) {
            run(split(parts.rest).word);
        } else if (eql(parts.word, "exit")) {
            const parsed = split(parts.rest);
            var status: u64 = 0;
            for (parsed.word) |c| {
                if (c < '0' or c > '9') {
                    status = 0;
                    break;
                }
                status = status * 10 + (c - '0');
            }
            write("clarity-sh: exit\n");
            exit(status);
        } else {
            // Named, not swallowed. A shell that ignores what it does not
            // understand teaches you nothing about what it does.
            unknown += 1;
            ran -= 1;
            write("clarity-sh: unknown command: ");
            write(parts.word);
            write("\n");
        }
    }
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    write("clarity-sh: panic\n");
    exit(1);
}
