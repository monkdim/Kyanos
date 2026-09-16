//! procfs — /proc, synthesised on every read.
//!
//! Built-in entries:
//!   /proc/cpuinfo, /proc/meminfo, /proc/uptime, /proc/loadavg,
//!   /proc/version
//!
//! Per-process subtree:
//!   /proc/<pid>/status, /proc/<pid>/cmdline, /proc/<pid>/comm
//!
//! A read() materialises the content into a heap buffer, copies the
//! requested slice into the user buffer, and frees the heap copy
//! when the inode goes out of scope. `stdlib/procfs.clarity` is the
//! testable mirror.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const vfs = @import("vfs.zig");
const sched = @import("../sched/scheduler.zig");
const pmm = @import("../mm/pmm.zig");
const timer = @import("../arch/x86_64/timer.zig");

var procfs: vfs.Fs = undefined;
var procfs_root_inode: vfs.Inode = undefined;

pub fn mount() !void {
    procfs_root_inode = .{
        .num = 2000,
        .fs = &procfs,
        .file_type = .directory,
        .mode = 0o555 | 0x4000,
        .size = 0,
        .nlink = 1, .uid = 0, .gid = 0,
        .atime = 0, .mtime = 0, .ctime = 0,
        .private = null,
    };
    procfs = .{
        .name = "procfs",
        .root_inode = &procfs_root_inode,
        .ops = ops,
        .private = null,
    };
}

pub fn root() *vfs.Fs { return &procfs; }

const ops: vfs.FsOps = .{
    .mount = mount_unused,
    .unmount = unmount_noop,
    .lookup = op_lookup,
    .create = op_denied,
    .mkdir = op_mkdir_denied,
    .unlink = op_unlink_denied,
    .rmdir = op_rmdir_denied,
    .read = op_read,
    .write = op_write_denied,
    .truncate = op_truncate_noop,
    .readdir = op_readdir,
};

fn mount_unused() !*vfs.Fs { return &procfs; }
fn unmount_noop(_: *vfs.Fs) !void {}

fn op_lookup(_: *vfs.Fs, _: *vfs.Inode, name: []const u8) !?*vfs.Inode {
    // Top-level + per-PID synthetic inodes are returned as new
    // allocations because procfs content is generated on demand.
    if (std.mem.eql(u8, name, "cpuinfo") or
        std.mem.eql(u8, name, "meminfo") or
        std.mem.eql(u8, name, "uptime")  or
        std.mem.eql(u8, name, "loadavg") or
        std.mem.eql(u8, name, "version"))
    {
        return alloc_synth_inode(name) catch null;
    }
    // Numeric → /proc/<pid>
    if (parse_pid(name)) |pid| {
        if (sched.process_table.lookup(pid) != null) {
            return alloc_synth_inode(name) catch null;
        }
    }
    return null;
}

fn op_denied(_: *vfs.Fs, _: *vfs.Inode, _: []const u8, _: vfs.Mode) !*vfs.Inode {
    return error.PermissionDenied;
}
fn op_mkdir_denied(_: *vfs.Fs, _: *vfs.Inode, _: []const u8, _: vfs.Mode) !*vfs.Inode {
    return error.PermissionDenied;
}
fn op_unlink_denied(_: *vfs.Fs, _: *vfs.Inode, _: []const u8) !void {
    return error.PermissionDenied;
}
fn op_rmdir_denied(_: *vfs.Fs, _: *vfs.Inode, _: []const u8) !void {
    return error.PermissionDenied;
}
fn op_write_denied(_: *vfs.Fs, _: *vfs.Inode, _: u64, _: []const u8) !usize {
    return error.PermissionDenied;
}
fn op_truncate_noop(_: *vfs.Fs, _: *vfs.Inode, _: u64) !void {}

fn op_read(_: *vfs.Fs, inode: *vfs.Inode, offset: u64, buf: []u8) !usize {
    const synth: *SyntheticInode = @ptrCast(@alignCast(inode.private orelse return 0));
    const content = try synth.materialise();
    if (offset >= content.len) return 0;
    const n = @min(buf.len, content.len - offset);
    @memcpy(buf[0..n], content[offset..][0..n]);
    return n;
}

fn op_readdir(_: *vfs.Fs, inode: *vfs.Inode) ![]const vfs.DirEntry {
    if (inode != &procfs_root_inode) return &.{};
    const out = struct {
        var entries: [32]vfs.DirEntry = undefined;
    };
    var n: usize = 0;
    const top = [_][]const u8{ "cpuinfo", "meminfo", "uptime", "loadavg", "version" };
    inline for (top) |name| {
        out.entries[n] = .{ .name = name, .inode_num = 2001 + n, .file_type = .regular };
        n += 1;
    }
    // pids
    var it = sched.process_table.map.iterator();
    while (it.next()) |entry| {
        if (n >= out.entries.len) break;
        const buf = heap.allocator().alloc(u8, 16) catch continue;
        const written = std.fmt.bufPrint(buf, "{d}", .{entry.key_ptr.*}) catch continue;
        out.entries[n] = .{ .name = written, .inode_num = 3000 + @as(u64, @intCast(entry.key_ptr.*)), .file_type = .directory };
        n += 1;
    }
    return out.entries[0..n];
}

// ── Synthetic inodes ────────────────────────────

const SyntheticInode = struct {
    name: []const u8,
    rendered: ?[]const u8 = null,

    fn materialise(self: *SyntheticInode) ![]const u8 {
        if (self.rendered) |r| return r;
        const text = try render(self.name);
        self.rendered = text;
        return text;
    }
};

fn parse_pid(name: []const u8) ?i32 {
    var v: i32 = 0;
    if (name.len == 0) return null;
    for (name) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + @as(i32, c - '0');
    }
    return v;
}

fn alloc_synth_inode(name: []const u8) !*vfs.Inode {
    const inode = try heap.allocator().create(vfs.Inode);
    const synth = try heap.allocator().create(SyntheticInode);
    synth.* = .{ .name = name };
    inode.* = .{
        .num = 2999,
        .fs = &procfs,
        .file_type = .regular,
        .mode = 0o444,
        .size = 0,
        .nlink = 1, .uid = 0, .gid = 0,
        .atime = 0, .mtime = 0, .ctime = 0,
        .private = synth,
    };
    return inode;
}

fn render(name: []const u8) ![]const u8 {
    const gpa = heap.allocator();
    if (std.mem.eql(u8, name, "cpuinfo")) return try render_cpuinfo(gpa);
    if (std.mem.eql(u8, name, "meminfo")) return try render_meminfo(gpa);
    if (std.mem.eql(u8, name, "uptime"))  return try render_uptime(gpa);
    if (std.mem.eql(u8, name, "loadavg")) return try render_loadavg(gpa);
    if (std.mem.eql(u8, name, "version")) return try render_version(gpa);
    return error.NotFound;
}

fn render_cpuinfo(gpa: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(gpa,
        "processor    : 0\nvendor_id    : KyanOS\nmodel name   : KyanOS Virtual CPU\ncpu MHz      : 2400.000\n", .{});
}

fn render_meminfo(gpa: std.mem.Allocator) ![]const u8 {
    const stats = pmm.stats();
    const total_kb = stats.total_pages * 4;
    const free_kb = stats.free_pages * 4;
    const used_kb = total_kb - free_kb;
    return try std.fmt.allocPrint(gpa,
        "MemTotal:    {d} kB\nMemFree:     {d} kB\nMemAvailable: {d} kB\nUsed:        {d} kB\n",
        .{ total_kb, free_kb, free_kb, used_kb });
}

fn render_uptime(gpa: std.mem.Allocator) ![]const u8 {
    const up = timer.uptime_seconds();
    return try std.fmt.allocPrint(gpa, "{d} 0\n", .{up});
}

fn render_loadavg(gpa: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(gpa, "0.00 0.00 0.00 1/1 1\n", .{});
}

fn render_version(gpa: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(gpa, "KyanOS 0.1 #1 SMP\n", .{});
}
