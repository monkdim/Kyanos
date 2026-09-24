//! Process model — one Process per address space, many Threads
//! per Process. Phase 70 spawns one thread per process; SMP +
//! multi-threaded processes come later.
//!
//! Tracks parent/child relationships, exit code propagation,
//! zombie reaping, and reparents orphaned children to PID 1
//! (the init process) when a parent exits.
//!
//! **Generic over the address space, and that is the only thing here that
//! differs between the two architectures.** An x86_64 address space is a
//! PML4 that has to carry the kernel's upper half; an AArch64 one is a TTBR0
//! root and an ASID, and carries nothing but the process. Everything else —
//! what a PID is, whose child a process is, when a zombie is reaped, where an
//! orphan goes — is the same on both, and was about to be written out a
//! second time for AArch64. So the model takes the address-space type as a
//! parameter, the way `runqueue.zig` takes the thread type, and each
//! architecture names its own:
//!
//!     const process = @import("process.zig").Model(vmm.AddressSpace);
//!     const process = @import("process.zig").Model(paging.AddressSpace);

const std = @import("std");

/// Outside the model: a PID means the same thing whatever the address space
/// is made of, and `Model(A).Pid` and `Model(B).Pid` being different types
/// would make a process table impossible to talk about from shared code.
pub const Pid = i32;

pub fn Model(comptime Space: type) type {
    return struct {
    pub const Process = struct {
        pid: Pid,
        parent_pid: Pid,
        name: []const u8,
        address_space: *Space,
        state: State,
        exit_code: i32 = 0,
        main_thread_tid: i32 = 0,
        children: std.ArrayListUnmanaged(Pid) = .{},
        zombies: std.ArrayListUnmanaged(ZombieRecord) = .{},
        cwd: []const u8 = "/",
        fd_table: std.AutoHashMapUnmanaged(i32, *Fd) = .{},
        next_fd: i32 = 3,

        /// Top of the heap, and where it began. `brk_start` is the page after the
        /// last loaded segment; the break never goes below it. Both are zero for
        /// a process with no loaded image, which is every kernel thread.
        brk: u64 = 0,
        brk_start: u64 = 0,

        pub const State = enum { runnable, running, sleeping, zombie };

        pub const ZombieRecord = struct {
            pid: Pid,
            exit_code: i32,
            name: []const u8,
        };

        pub const Fd = struct {
            inode: u64,
            pos: u64 = 0,
            flags: u32,
            ref_count: u32 = 1,
        };

        pub fn add_child(self: *Process, child_pid: Pid, gpa: std.mem.Allocator) !void {
            try self.children.append(gpa, child_pid);
        }

        pub fn remove_child(self: *Process, child_pid: Pid) bool {
            for (self.children.items, 0..) |c, i| {
                if (c == child_pid) {
                    _ = self.children.swapRemove(i);
                    return true;
                }
            }
            return false;
        }

        pub fn record_zombie(self: *Process, child: Process, gpa: std.mem.Allocator) !void {
            try self.zombies.append(gpa, .{
                .pid = child.pid,
                .exit_code = child.exit_code,
                .name = child.name,
            });
        }

        pub fn reap_any(self: *Process) ?ZombieRecord {
            if (self.zombies.items.len == 0) return null;
            return self.zombies.swapRemove(0);
        }

        pub fn reap_pid(self: *Process, pid: Pid) ?ZombieRecord {
            for (self.zombies.items, 0..) |z, i| {
                if (z.pid == pid) return self.zombies.swapRemove(i);
            }
            return null;
        }
    };

    /// Process table: every live + zombie process keyed by PID.
    pub const Table = struct {
        map: std.AutoHashMapUnmanaged(Pid, *Process) = .{},
        next_pid: Pid = 2,                            // 1 is reserved for init
        init_pid: Pid = 1,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) Table {
            return .{ .gpa = gpa };
        }

        pub fn alloc_pid(self: *Table) Pid {
            const pid = self.next_pid;
            self.next_pid += 1;
            return pid;
        }

        pub fn register(self: *Table, p: *Process) !void {
            try self.map.put(self.gpa, p.pid, p);
        }

        pub fn lookup(self: *Table, pid: Pid) ?*Process {
            return self.map.get(pid);
        }

        pub fn remove(self: *Table, pid: Pid) void {
            _ = self.map.remove(pid);
        }

        /// When a process exits, its children get reparented to init
        /// so init can reap them. Linux does the same dance.
        pub fn reparent_children(self: *Table, dying: *Process) !void {
            const init_proc = self.lookup(self.init_pid) orelse return;
            for (dying.children.items) |child_pid| {
                if (self.lookup(child_pid)) |child| {
                    child.parent_pid = self.init_pid;
                    try init_proc.add_child(child_pid, self.gpa);
                }
            }
            dying.children.clearAndFree(self.gpa);
        }
        };
    };
}
