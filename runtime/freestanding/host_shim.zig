//! host_shim — bridges the freestanding JS engine to KyanOS
//! kernel syscalls (Phase 66 task 2).
//!
//! The freestanding runtime links this object against libquickjs.a,
//! registers __claritos_syscall, and evaluates the bundled JS. (A second
//! shape, a native bytecode VM, was removed in September 2026.)
//!
//! This file is the kernel-facing edge: it knows about the syscall
//! ABI, the memory layout of struct stat, and how to safely move
//! bytes between user/kernel buffers.

const std = @import("std");

// Syscall numbers — same values as stdlib/kernel_abi.clarity and
// kernel/syscall/dispatch.zig. Keep these three in sync.
pub const SYS_READ: u64 = 0;
pub const SYS_WRITE: u64 = 1;
pub const SYS_OPEN: u64 = 2;
pub const SYS_CLOSE: u64 = 3;
pub const SYS_STAT: u64 = 4;
pub const SYS_FSTAT: u64 = 5;
pub const SYS_LSEEK: u64 = 6;
pub const SYS_MMAP: u64 = 7;
pub const SYS_MUNMAP: u64 = 8;
pub const SYS_EXIT: u64 = 12;
pub const SYS_GETPID: u64 = 14;
pub const SYS_NANOSLEEP: u64 = 17;
pub const SYS_MKDIR: u64 = 30;
pub const SYS_RMDIR: u64 = 31;
pub const SYS_UNLINK: u64 = 32;
pub const SYS_RENAME: u64 = 33;
pub const SYS_READDIR: u64 = 34;
pub const SYS_CLOCK_GETTIME: u64 = 41;

/// Issue a raw syscall via the SYSCALL instruction. Returns the
/// kernel's return value verbatim; negative values are -errno.
pub inline fn syscall0(nr: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall1(nr: u64, a0: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall2(nr: u64, a0: u64, a1: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall3(nr: u64, a0: u64, a1: u64, a2: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
        : "rcx", "r11", "memory"
    );
}

// ── C-callable wrappers used by the JS engine binding ──

/// Read up to `len` bytes from `fd` into `buf`. Returns the byte
/// count on success or -errno on failure.
pub export fn claritos_read(fd: i32, buf: [*]u8, len: usize) callconv(.C) i64 {
    return syscall3(SYS_READ, @as(u64, @bitCast(@as(i64, fd))), @intFromPtr(buf), len);
}

pub export fn claritos_write(fd: i32, buf: [*]const u8, len: usize) callconv(.C) i64 {
    return syscall3(SYS_WRITE, @as(u64, @bitCast(@as(i64, fd))), @intFromPtr(buf), len);
}

pub export fn claritos_open(path: [*:0]const u8, flags: u32, mode: u32) callconv(.C) i64 {
    return syscall3(SYS_OPEN, @intFromPtr(path), flags, mode);
}

pub export fn claritos_close(fd: i32) callconv(.C) i64 {
    return syscall1(SYS_CLOSE, @as(u64, @bitCast(@as(i64, fd))));
}

pub export fn claritos_lseek(fd: i32, offset: i64, whence: u32) callconv(.C) i64 {
    return syscall3(SYS_LSEEK, @as(u64, @bitCast(@as(i64, fd))), @as(u64, @bitCast(offset)), whence);
}

pub export fn claritos_getpid() callconv(.C) i64 {
    return syscall0(SYS_GETPID);
}

pub export fn claritos_exit(code: i32) callconv(.C) noreturn {
    _ = syscall1(SYS_EXIT, @as(u64, @bitCast(@as(i64, code))));
    while (true) asm volatile ("hlt");
}

pub export fn claritos_clock_gettime() callconv(.C) i64 {
    return syscall0(SYS_CLOCK_GETTIME);
}

pub export fn claritos_nanosleep(ts_ptr: [*]const u8) callconv(.C) i64 {
    return syscall1(SYS_NANOSLEEP, @intFromPtr(ts_ptr));
}

pub export fn claritos_stat(path: [*:0]const u8, buf: [*]u8) callconv(.C) i64 {
    return syscall2(SYS_STAT, @intFromPtr(path), @intFromPtr(buf));
}

pub export fn claritos_mkdir(path: [*:0]const u8, mode: u32) callconv(.C) i64 {
    return syscall2(SYS_MKDIR, @intFromPtr(path), mode);
}

pub export fn claritos_unlink(path: [*:0]const u8) callconv(.C) i64 {
    return syscall1(SYS_UNLINK, @intFromPtr(path));
}

pub export fn claritos_rename(src: [*:0]const u8, dst: [*:0]const u8) callconv(.C) i64 {
    return syscall2(SYS_RENAME, @intFromPtr(src), @intFromPtr(dst));
}

// ── JS-engine binding hook ────────────────────────────

/// Single dispatch entry that the JS engine binds as
/// `__claritos_syscall(nr, ...args)`. The JS shim in host.js wraps
/// this with an idiomatic API. Argument marshalling happens on the
/// JS side; here we just route by syscall number.
pub export fn claritos_syscall(nr: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.C) i64 {
    _ = a3;
    _ = a4;
    _ = a5;
    return switch (nr) {
        SYS_READ => syscall3(SYS_READ, a0, a1, a2),
        SYS_WRITE => syscall3(SYS_WRITE, a0, a1, a2),
        SYS_OPEN => syscall3(SYS_OPEN, a0, a1, a2),
        SYS_CLOSE => syscall1(SYS_CLOSE, a0),
        SYS_STAT => syscall2(SYS_STAT, a0, a1),
        SYS_LSEEK => syscall3(SYS_LSEEK, a0, a1, a2),
        SYS_GETPID => syscall0(SYS_GETPID),
        SYS_EXIT => syscall1(SYS_EXIT, a0),
        SYS_NANOSLEEP => syscall1(SYS_NANOSLEEP, a0),
        SYS_CLOCK_GETTIME => syscall0(SYS_CLOCK_GETTIME),
        SYS_MKDIR => syscall2(SYS_MKDIR, a0, a1),
        SYS_RMDIR => syscall1(SYS_RMDIR, a0),
        SYS_UNLINK => syscall1(SYS_UNLINK, a0),
        SYS_RENAME => syscall2(SYS_RENAME, a0, a1),
        SYS_READDIR => syscall1(SYS_READDIR, a0),
        else => -38, // ENOSYS
    };
}
