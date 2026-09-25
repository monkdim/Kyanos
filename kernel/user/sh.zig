//! /bin/clarity-sh — a shell, on x86_64.
//!
//! Read a line, work out what it says, do it, repeat. That loop is the oldest
//! interface an operating system has, and until now this architecture did not
//! have it: everything it could do, it did to itself on the way up, and there
//! was no point at which a person could tell it anything.
//!
//! The same shell as the AArch64 one, and deliberately the same file twice
//! rather than one file with two `syscall3`s. Sharing it would mean a
//! comptime switch on the architecture inside a *user program*, and a user
//! program that knows which kernel it is running on is the wrong shape --
//! this one is what a program compiled for this machine looks like, and the
//! day the two stop being the same shell, neither has to give.
//!
//! Freestanding, no libc. One architecture-specific line: `syscall` with the
//! number in rax and the arguments in rdi/rsi/rdx, where the other has `svc`
//! with x8 and x0-x2. Every number below comes from the shared dispatch
//! table, so they are the same on both.
//!
//! It ends on end of input. On a machine with nobody at the console that is
//! the read's idle timeout and then a clean exit, which is what lets a boot
//! with no one watching still finish -- and it is also just what a shell does
//! when its input closes.

const std = @import("std");

const NR_READ: u64 = 0;
const NR_WRITE: u64 = 1;
const NR_OPEN: u64 = 2;
const NR_CLOSE: u64 = 3;
const NR_FORK: u64 = 10;
const NR_EXEC: u64 = 11;
const NR_WAIT: u64 = 13;
const NR_EXIT: u64 = 12;
const NR_READDIR: u64 = 34;

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

/// run PATH — start the program at PATH *beside* this shell, and wait.
///
/// This used to be exec and nothing else, and the comment here used to say
/// why: "the program takes the shell's place. A shell that could start a
/// program beside itself needs a second process, which needs fork." It has
/// one now. Three calls, in the order every shell has made them since 1975:
/// fork, exec in the child, wait in the parent.
///
/// The child must not come back here under any circumstance. `exec` returns
/// only when it failed, and a child that returned into the loop below would
/// be a *second shell* reading the same keyboard — two prompts, every line
/// going to whichever process happened to be in `read` first. So the child's
/// only ways out of this function are becoming another program and exiting.
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

    const pid = syscall3(NR_FORK, 0, 0, 0);
    if (pid < 0) {
        write("run: cannot start another process\n");
        return;
    }

    if (pid == 0) {
        const rc = syscall3(NR_EXEC, @intFromPtr(&buf), 0, 0);
        write("run: cannot run ");
        write(path);
        if (rc == -2) write(" — no such file\n") else write(" — refused\n");
        // 127 is what a shell has always answered for a command it could not
        // run, and exiting rather than returning is what keeps there being
        // one shell.
        exit(127);
    }

    var status: i32 = -1;
    const got = syscall3(NR_WAIT, @intFromPtr(&status), @bitCast(pid), 0);
    if (got != pid) {
        write("run: lost track of it\n");
        return;
    }
    const code = @as(*volatile i32, &status).*;
    write("run: ");
    write(path);
    if (code == 0) {
        write(" finished\n");
    } else {
        write(" exited ");
        // Negative is how the kernel reports a program that faulted or was
        // killed, and it is worth not printing as four billion.
        if (code < 0) {
            write("-");
            write_dec(@intCast(-@as(i64, code)));
        } else {
            write_dec(@intCast(code));
        }
        write("\n");
    }
}

fn help() void {
    write(
        \\clarity-sh — the commands that exist
        \\  help          this
        \\  echo TEXT     write TEXT back
        \\  count TEXT    how many characters TEXT is
        \\  cat PATH      write out a file
        \\  ls [PATH]     list a directory, / if none is named
        \\  run PATH      run the program at PATH and wait for it
        \\  exit [N]      leave, with status N
        \\
        \\`run` forks: the program starts beside this shell rather than in
        \\its place, and the prompt comes back with what it exited.
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
