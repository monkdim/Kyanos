//! The run-queue discipline, with no architecture in it.
//!
//! Both kernels want the same thing from a scheduler: some number of
//! priority levels, each a FIFO of threads, and "pick the next one" means
//! take the head of the highest non-empty level. What differs between the
//! two is what a thread *is* — an x86_64 context is a 512-byte FXSAVE area
//! and a CR3, an AArch64 one is ten registers and a TTBR0 — and what it
//! takes to switch to one. That belongs to the architecture.
//!
//! The order threads run in does not, and a second copy of it is a second
//! scheduler that will eventually disagree with the first about something
//! nobody is testing. So the ordering lives here once, generic over the
//! thread type, and each architecture's scheduler supplies the thread and
//! the switch.
//!
//! The lists are intrusive: the link is a field of the thread rather than a
//! node allocated beside it, so enqueueing cannot fail and a scheduler
//! holding a thread pointer can always find it. `T` therefore has to have a
//! `next: ?*T` field, which is checked at compile time rather than left to
//! produce a confusing error inside a method.

const std = @import("std");

/// One priority level: a FIFO of threads, linked through `T.next`.
pub fn Queue(comptime T: type) type {
    comptime {
        if (!@hasField(T, "next")) {
            @compileError(@typeName(T) ++ " has no `next` field, so it cannot go on a run queue");
        }
        if (std.meta.fieldInfo(T, .next).type != ?*T) {
            @compileError(@typeName(T) ++ ".next must be `?*" ++ @typeName(T) ++ "`");
        }
    }

    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,

        pub fn enqueue(self: *Self, t: *T) void {
            t.next = null;
            if (self.tail) |tail| {
                tail.next = t;
                self.tail = t;
            } else {
                self.head = t;
                self.tail = t;
            }
        }

        pub fn dequeue(self: *Self) ?*T {
            const t = self.head orelse return null;
            self.head = t.next;
            if (self.head == null) self.tail = null;
            t.next = null;
            return t;
        }

        pub fn is_empty(self: *const Self) bool {
            return self.head == null;
        }

        /// Take `target` out of this queue wherever it is. Returns false if
        /// it was not on this queue at all, which is how a caller that does
        /// not know which level a thread is on can try each.
        pub fn remove(self: *Self, target: *T) bool {
            var prev: ?*T = null;
            var cur = self.head;
            while (cur) |t| : ({
                prev = t;
                cur = t.next;
            }) {
                if (t == target) {
                    if (prev) |p| p.next = t.next else self.head = t.next;
                    if (self.tail == t) self.tail = prev;
                    t.next = null;
                    return true;
                }
            }
            return false;
        }

        pub fn len(self: *const Self) usize {
            var n: usize = 0;
            var cur = self.head;
            while (cur) |t| : (cur = t.next) n += 1;
            return n;
        }
    };
}

/// `levels` priority levels, 0 highest. `pick` takes the head of the highest
/// non-empty one, which is the whole of the policy: a level with anything on
/// it starves every level below it, and within a level it is round robin
/// because a preempted thread goes back on the tail.
pub fn MultiQueue(comptime T: type, comptime levels: usize) type {
    comptime {
        if (levels == 0) @compileError("a run queue needs at least one priority level");
    }

    return struct {
        const Self = @This();
        pub const Level = Queue(T);
        pub const level_count = levels;

        levels: [levels]Level = .{.{}} ** levels,

        pub fn clear(self: *Self) void {
            for (&self.levels) |*q| q.* = .{};
        }

        pub fn enqueue(self: *Self, t: *T, level: usize) void {
            self.levels[level].enqueue(t);
        }

        pub fn pick(self: *Self) ?*T {
            for (&self.levels) |*q| {
                if (q.dequeue()) |t| return t;
            }
            return null;
        }

        /// True if anything anywhere is waiting to run.
        pub fn any(self: *const Self) bool {
            for (&self.levels) |*q| {
                if (!q.is_empty()) return true;
            }
            return false;
        }

        /// Take `t` off whichever level it is on.
        pub fn remove(self: *Self, t: *T) bool {
            for (&self.levels) |*q| {
                if (q.remove(t)) return true;
            }
            return false;
        }

        pub fn len(self: *const Self, level: usize) usize {
            return self.levels[level].len();
        }

        pub fn total(self: *const Self) usize {
            var n: usize = 0;
            for (&self.levels) |*q| n += q.len();
            return n;
        }
    };
}
