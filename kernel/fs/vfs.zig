//! VFS — virtual filesystem layer.
//!
//! A filesystem is anything that implements the FsOps vtable below.
//! Inodes carry a back-pointer to their owning fs, plus an opaque
//! `private` slot the fs uses for its per-inode state. Dentries live
//! in the dcache and link parent <-> child by name; lookups walk
//! the cache first and fall through to FsOps.lookup() on miss.
//!
//! The kernel keeps a per-process fd table in syscall/dispatch.zig
//! that maps fd integers to File handles owned here.

const std = @import("std");
const heap = @import("../mm/heap.zig");

pub const InodeNum = u64;
pub const Mode = u32;

pub const FileType = enum(u8) {
    regular,
    directory,
    char_device,
    block_device,
    symlink,
    fifo,
    socket,
};

pub const Inode = struct {
    num: InodeNum,
    fs: *Fs,
    file_type: FileType,
    mode: Mode,
    size: u64,
    nlink: u32,
    uid: u32,
    gid: u32,
    atime: u64,
    mtime: u64,
    ctime: u64,
    private: ?*anyopaque,
};

pub const Dentry = struct {
    name: []const u8,
    inode: ?*Inode,
    parent: ?*Dentry,
    children: std.ArrayListUnmanaged(*Dentry) = .{},
    refcount: u32 = 1,
};

pub const File = struct {
    inode: *Inode,
    pos: u64,
    flags: u32,
};

pub const FsOps = struct {
    mount: *const fn () anyerror!*Fs,
    unmount: *const fn (fs: *Fs) anyerror!void,

    lookup: *const fn (fs: *Fs, parent: *Inode, name: []const u8) anyerror!?*Inode,
    create: *const fn (fs: *Fs, parent: *Inode, name: []const u8, mode: Mode) anyerror!*Inode,
    mkdir: *const fn (fs: *Fs, parent: *Inode, name: []const u8, mode: Mode) anyerror!*Inode,
    unlink: *const fn (fs: *Fs, parent: *Inode, name: []const u8) anyerror!void,
    rmdir: *const fn (fs: *Fs, parent: *Inode, name: []const u8) anyerror!void,

    read: *const fn (fs: *Fs, inode: *Inode, offset: u64, buf: []u8) anyerror!usize,
    write: *const fn (fs: *Fs, inode: *Inode, offset: u64, buf: []const u8) anyerror!usize,
    truncate: *const fn (fs: *Fs, inode: *Inode, size: u64) anyerror!void,

    readdir: *const fn (fs: *Fs, inode: *Inode) anyerror![]const DirEntry,
};

pub const Fs = struct {
    name: []const u8,
    root_inode: *Inode,
    ops: FsOps,
    private: ?*anyopaque,
};

pub const DirEntry = struct {
    name: []const u8,
    inode_num: InodeNum,
    file_type: FileType,
};

var root_dentry: ?*Dentry = null;

/// Per-process fd table, keyed by PID. `current_process_id_fn` is
/// installed by the scheduler at boot so VFS doesn't have to import
/// it directly (would be a circular dependency).
pub const PerProcessTable = struct {
    fds: [256]?*File = .{null} ** 256,

    pub fn alloc(self: *PerProcessTable, inode: *Inode, flags: u32) !i64 {
        var i: usize = 3;
        while (i < self.fds.len) : (i += 1) {
            if (self.fds[i] == null) {
                const file = @as(*File, @ptrCast(@alignCast(heap.alloc(@sizeOf(File)) orelse return error.OutOfMemory)));
                file.* = .{ .inode = inode, .pos = 0, .flags = flags };
                self.fds[i] = file;
                return @intCast(i);
            }
        }
        return error.TooManyOpenFiles;
    }

    pub fn slot(self: *PerProcessTable, fd: i32) !*?*File {
        if (fd < 0 or fd >= self.fds.len) return error.BadFd;
        return &self.fds[@intCast(fd)];
    }
};

var current_table_fn: ?*const fn () *PerProcessTable = null;

pub fn install_current_table_resolver(f: *const fn () *PerProcessTable) void {
    current_table_fn = f;
}

fn current_table() *PerProcessTable {
    if (current_table_fn) |f| return f();
    return &fallback_table;
}

/// Used during early boot before the first process exists; also a
/// safety net for the test path. The scheduler swaps in real
/// per-process tables once init has been spawned.
pub var fallback_table: PerProcessTable = .{};

pub fn init() void {
    root_dentry = null;
    fallback_table = .{};
}

pub fn set_root(fs: *Fs) void {
    const dent = @as(*Dentry, @ptrCast(@alignCast(heap.alloc(@sizeOf(Dentry)) orelse return)));
    dent.* = .{
        .name = "/",
        .inode = fs.root_inode,
        .parent = null,
    };
    root_dentry = dent;
}

pub fn open(path: []const u8, flags: u32, mode: Mode) !i64 {
    const inode = try resolve(path) orelse {
        if ((flags & 0x40) != 0) {
            const parent = try resolve_parent(path);
            const name = basename(path);
            const new_inode = try parent.fs.ops.create(parent.fs, parent, name, mode);
            return current_table().alloc(new_inode, flags);
        }
        return error.NotFound;
    };
    return current_table().alloc(inode, flags);
}

pub fn close(fd: i32) !void {
    const slot_ptr = try current_table().slot(fd);
    if (slot_ptr.* == null) return error.BadFd;
    heap.free(@ptrCast(slot_ptr.*.?), @sizeOf(File));
    slot_ptr.* = null;
}

pub fn read(fd: i32, buf: []u8) !usize {
    const slot_ptr = try current_table().slot(fd);
    const file = slot_ptr.* orelse return error.BadFd;
    const n = try file.inode.fs.ops.read(file.inode.fs, file.inode, file.pos, buf);
    file.pos += n;
    return n;
}

pub fn write(fd: i32, buf: []const u8) !usize {
    const slot_ptr = try current_table().slot(fd);
    const file = slot_ptr.* orelse return error.BadFd;
    const n = try file.inode.fs.ops.write(file.inode.fs, file.inode, file.pos, buf);
    file.pos += n;
    return n;
}

/// One entry as a process reads it.
///
/// A filesystem's own `readdir` hands back a slice of `DirEntry`, whose
/// `name` is a pointer into kernel memory — useless to a process. So the
/// entries are packed into a byte buffer the caller owns: a fixed header,
/// the name, a NUL, then padding to the next multiple of eight so the next
/// header is aligned however the reader walks it. `reclen` is the distance
/// to the next record, which is what makes the buffer self-describing: a
/// reader steps by it and never needs to know how the padding was computed.
pub const Dirent = extern struct {
    inode_num: u64,
    reclen: u16,
    file_type: u8,
    name_len: u8,
};

pub const DIRENT_ALIGN: usize = 8;

/// Where the name starts: after the four fields, and *not* after whatever
/// the compiler pads the struct to.
///
/// The two are not the same, and the difference was a bug. The fields sum to
/// twelve bytes; the `u64` gives the struct an alignment of eight, so
/// `@sizeOf(Dirent)` is **sixteen** — twelve of fields and four of tail
/// padding. This file wrote the name at `@sizeOf`, and every reader that
/// followed the layout described above read four bytes of padding followed
/// by all but the last four characters of the name:
///
///     $ ls /bin
///     hello          <- hello.txt
///     clarity-       <- clarity-init
///     clarit         <- clarity-sh
///     clarity-h      <- clarity-hello
///
/// Both shells had it right; this file had it wrong. The reason it survived
/// is in `fstest.zig`, whose own reader used `@sizeOf` too — so the gate
/// agreed with the writer and could not see a disagreement with anybody
/// else.
///
/// So the wire format gets a name of its own, and the asserts below stop it
/// drifting from the struct it describes.
pub const DIRENT_HEADER: usize = 12;

comptime {
    std.debug.assert(@offsetOf(Dirent, "inode_num") == 0);
    std.debug.assert(@offsetOf(Dirent, "reclen") == 8);
    std.debug.assert(@offsetOf(Dirent, "file_type") == 10);
    std.debug.assert(@offsetOf(Dirent, "name_len") == 11);
    std.debug.assert(@offsetOf(Dirent, "name_len") + 1 == DIRENT_HEADER);
}

fn dirent_reclen(name_len: usize) usize {
    const raw = DIRENT_HEADER + name_len + 1; // + the NUL
    return (raw + (DIRENT_ALIGN - 1)) & ~(DIRENT_ALIGN - 1);
}

/// Read directory entries from `fd` into `out`, continuing where the last
/// call left off.
///
/// Returns the number of bytes written: zero means the directory is
/// finished, which is how a caller knows to stop. `file.pos` counts entries
/// rather than bytes for a directory, so a partial read resumes at the next
/// entry and never re-reports one.
///
/// A buffer too small to hold even the first entry is an error rather than
/// zero bytes: zero means "no more entries", and a reader that could not
/// tell the two apart would stop early and report a short directory as a
/// complete one.
pub fn readdir(fd: i32, out: []u8) !usize {
    const slot_ptr = try current_table().slot(fd);
    const file = slot_ptr.* orelse return error.BadFd;
    if (file.inode.file_type != .directory) return error.NotADirectory;

    const entries = try file.inode.fs.ops.readdir(file.inode.fs, file.inode);
    var written: usize = 0;
    var index: usize = @intCast(file.pos);
    while (index < entries.len) : (index += 1) {
        const entry = entries[index];
        const name_len = @min(entry.name.len, 255);
        const reclen = dirent_reclen(name_len);
        if (written + reclen > out.len) {
            if (written == 0) return error.BufferTooSmall;
            break;
        }
        const header = Dirent{
            .inode_num = entry.inode_num,
            .reclen = @intCast(reclen),
            .file_type = @intFromEnum(entry.file_type),
            .name_len = @intCast(name_len),
        };
        // The fields, and not the struct: `asBytes` hands back sixteen bytes,
        // the last four of which are padding that is no part of the format.
        @memcpy(out[written..][0..DIRENT_HEADER], std.mem.asBytes(&header)[0..DIRENT_HEADER]);
        @memcpy(out[written + DIRENT_HEADER ..][0..name_len], entry.name[0..name_len]);
        // The NUL and the padding are written rather than left as whatever
        // the buffer held: a process reading its own stale stack through a
        // name that was not terminated is the kind of leak that only shows
        // up on someone else's machine.
        @memset(out[written + DIRENT_HEADER + name_len ..][0 .. reclen - DIRENT_HEADER - name_len], 0);
        written += reclen;
    }
    file.pos = index;
    return written;
}

fn alloc_fd(inode: *Inode, flags: u32) !i64 {
    return current_table().alloc(inode, flags);
}

/// Walk `path` from the root, one component at a time, and return the inode
/// it names — or null if some component does not exist.
///
/// This returned null unconditionally, which is why `vfs.open` could never
/// find anything and `spawn_user` could never load an executable: tmpfs had
/// working create/lookup/read/write the whole time, with nothing able to
/// reach them.
///
/// Only absolute paths, because there is no per-process working directory
/// yet. "" and "/" are the root. Empty components — a trailing slash, or a
/// doubled one — are skipped rather than treated as a lookup of "".
fn resolve(path: []const u8) !?*Inode {
    const root = root_dentry orelse return error.NoRoot;
    // Dentry.inode is optional (a negative dentry caches a name that is known
    // not to exist); the root's is always present once set_root has run.
    const root_inode = root.inode orelse return error.NoRoot;
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return root_inode;
    if (path[0] != '/') return error.NotAbsolute;

    var current: *Inode = root_inode;
    var it = std.mem.splitScalar(u8, path[1..], '/');
    while (it.next()) |component| {
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, ".")) continue;
        // A component can only be walked *through* if it is a directory;
        // otherwise "/etc/passwd/x" would silently resolve to passwd.
        if (current.file_type != .directory) return error.NotADirectory;
        current = (try current.fs.ops.lookup(current.fs, current, component)) orelse return null;
    }
    return current;
}

/// `resolve`, exposed for the boot self-test. Errors rather than returning
/// null so a caller that expects the path to exist gets a diagnosable failure.
pub fn resolve_for_test(path: []const u8) !*Inode {
    const inode = (try resolve(path)) orelse return error.NotFound;
    return inode;
}

/// Read the entire file at `path` into a freshly-allocated buffer.
/// Used by sched.spawn_user when loading the executable for a new
/// process. Caller frees with `gpa.free`.
pub fn read_file_into_heap(path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const inode = (try resolve(path)) orelse return error.NotFound;
    const out = try gpa.alloc(u8, inode.size);
    var off: u64 = 0;
    while (off < out.len) {
        const n = try inode.fs.ops.read(inode.fs, inode, off, out[off..]);
        if (n == 0) break;
        off += n;
    }
    return out[0..off];
}

/// The directory that would contain `path` — everything up to the last
/// component. Needed by open(O_CREAT), which has to hand the new name to the
/// parent directory.
fn resolve_parent(path: []const u8) !*Inode {
    var end: usize = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1; // ignore a trailing slash
    var cut: usize = end;
    while (cut > 0 and path[cut - 1] != '/') cut -= 1;
    // cut now sits just after the separator; drop it to name the directory,
    // except at the root where the separator *is* the directory.
    const dir = if (cut <= 1) "/" else path[0 .. cut - 1];
    const inode = (try resolve(dir)) orelse return error.NotFound;
    return inode;
}

fn basename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
}
