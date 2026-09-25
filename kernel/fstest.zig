//! Filesystem: prove a path can be resolved before anything depends on it.
//!
//! tmpfs had working create, lookup, read and write the whole time, and
//! nothing could reach any of them, because `vfs.resolve` was:
//!
//!     fn resolve(path: []const u8) !?*Inode { _ = path; return null; }
//!
//! Every `open` fell through to "not found", and `read_file_into_heap` — the
//! one thing `spawn_user` needs to load an executable — could only ever
//! return error.NotFound. So the userspace path was blocked on a stub, not on
//! anything hard.
//!
//! This walks the whole round trip: make a directory, create a file in it,
//! write, read back through a fresh open by path, and list the directory. The
//! read-back is the part worth asserting — the backing buffer is rounded up to
//! a power of two, so a read bounded by the buffer instead of the file size
//! returns trailing slack as though it were content, and looks fine until
//! something compares bytes.

const std = @import("std");
const console = @import("arch/console.zig");
const vfs = @import("fs/vfs.zig");

const PATH = "/bin/hello.txt";
const CONTENT = "clarity";

pub fn run() !void {
    const root = try vfs.resolve_for_test("/");
    _ = try root.fs.ops.mkdir(root.fs, root, "bin", 0o755);

    // O_CREAT|O_WRONLY: the file does not exist yet, so this exercises the
    // create path, which needs resolve_parent to find /bin.
    const wfd = try vfs.open(PATH, 0x40 | 0x1, 0o644);
    const written = try vfs.write(@intCast(wfd), CONTENT);
    try vfs.close(@intCast(wfd));

    // A fresh open by the same path: this only finds anything if resolve
    // actually walked /bin/hello.txt rather than returning null.
    const rfd = try vfs.open(PATH, 0, 0);
    var buf: [64]u8 = undefined;
    const n = try vfs.read(@intCast(rfd), &buf);
    try vfs.close(@intCast(rfd));

    console.print("  fs: wrote ");
    console.print_dec(@as(u64, @intCast(written)));
    console.print(" read ");
    console.print_dec(@as(u64, @intCast(n)));
    console.print(" \"");
    console.print(buf[0..n]);
    console.println("\"");

    if (n != CONTENT.len or !std.mem.eql(u8, buf[0..n], CONTENT)) {
        return error.ReadBackMismatch;
    }

    const entries = try root.fs.ops.readdir(root.fs, root);
    console.print("  fs: / has ");
    console.print_dec(@as(u64, @intCast(entries.len)));
    console.println(" entries");

    console.println("  [ok] vfs: path resolve, create, write, read back");

    try readdir_round_trip();
}

/// The packed form a process reads, checked here rather than only through a
/// system call.
///
/// A filesystem's readdir hands back names that point into kernel memory;
/// vfs.readdir packs them into a caller's buffer as fixed headers plus the
/// name, so a process can walk them. The walk is what is checked: step by
/// each record's own length, and the names have to come out whole and in
/// order, ending with a call that returns zero rather than repeating the
/// last entry forever.
///
/// It also checks the two ways a caller can be misled: a buffer too small
/// for even one entry must be an error and not "no more entries", and a
/// second call must continue rather than start again.
fn readdir_round_trip() !void {
    const fd = try vfs.open("/bin", 0, 0);
    defer vfs.close(@intCast(fd)) catch {};

    var buf: [256]u8 = undefined;
    var names: usize = 0;
    var found_hello = false;
    while (true) {
        const n = try vfs.readdir(@intCast(fd), &buf);
        if (n == 0) break;
        var off: usize = 0;
        // Walked the way the format is documented and the way both shells
        // walk it -- by `DIRENT_HEADER`, not by `@sizeOf(vfs.Dirent)`.
        //
        // This is the whole reason the name offset could be wrong for as
        // long as it was. This reader used `@sizeOf` and so did the writer,
        // so the two agreed with each other and disagreed with everybody
        // else, and a test that shares a bug with the code under test cannot
        // see it. Reading it the documented way is what makes this a test of
        // the format rather than a test of the compiler's padding.
        while (off + vfs.DIRENT_HEADER <= n) {
            const reclen: usize = @as(usize, buf[off + 8]) | (@as(usize, buf[off + 9]) << 8);
            const name_len: usize = buf[off + 11];
            if (reclen == 0 or off + reclen > n) return error.MalformedDirent;
            const name = buf[off + vfs.DIRENT_HEADER ..][0..name_len];
            if (buf[off + vfs.DIRENT_HEADER + name_len] != 0) return error.NameNotTerminated;
            // Compared whole, which is the check that matters and was
            // always here. With the name read at the documented offset, a
            // writer that put it four bytes further along yields four NULs
            // and "hello" — which is not "hello.txt", so `found_hello` stays
            // false and this gate fails. That is exactly what it did when
            // the fix was first tried with the writer left wrong.
            //
            // Only `hello.txt` is in /bin at this point: `install_programs`
            // runs after this gate, which the first attempt at strengthening
            // this check got wrong by looking for a program that did not
            // exist yet.
            if (std.mem.eql(u8, name, "hello.txt")) found_hello = true;
            names += 1;
            off += reclen;
        }
    }
    if (!found_hello) return error.EntryMissing;

    // Too small for one entry: an error, never zero. A caller that read zero
    // here would report an empty directory.
    const small_fd = try vfs.open("/bin", 0, 0);
    defer vfs.close(@intCast(small_fd)) catch {};
    var tiny: [4]u8 = undefined;
    if (vfs.readdir(@intCast(small_fd), &tiny)) |_| {
        return error.TinyBufferAccepted;
    } else |e| {
        if (e != error.BufferTooSmall) return e;
    }

    // A file is not a directory, and saying so is the difference between a
    // useful error and an empty listing.
    const file_fd = try vfs.open(PATH, 0, 0);
    defer vfs.close(@intCast(file_fd)) catch {};
    if (vfs.readdir(@intCast(file_fd), &buf)) |_| {
        return error.FileListedAsDirectory;
    } else |e| {
        if (e != error.NotADirectory) return e;
    }

    console.print("  [ok] vfs: readdir packed ");
    console.print_dec(@as(u64, @intCast(names)));
    console.println(" entries, walked by record length");
}
