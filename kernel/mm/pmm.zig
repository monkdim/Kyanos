//! Physical memory manager — bitmap page-frame allocator.
//!
//! The kernel walks the boot memory map, marks every "available"
//! region as free, marks the pages occupied by the kernel image and
//! the bitmap itself as in-use, then hands out pages on demand.
//!
//! O(n) worst-case allocation in the number of frames. Acceptable
//! for the early stage; bumped to a buddy allocator in a later
//! phase. Intentionally simple — we want the failure modes to be
//! easy to reason about.

const std = @import("std");
const irqlock = @import("../sync/irqlock.zig");

/// How long to sit between testing a page's bit and setting it, in spins.
///
/// Zero everywhere except inside the selftest that exists to catch a missing
/// lock. The window this widens is real and about five instructions long, and
/// at 100 Hz a timer tick lands in five instructions out of a slice's half a
/// million roughly once in 1e5 slices — so a test that just ran two threads
/// against the allocator passed with and without the lock alike (57,605
/// allocations, no collision), which is a test that proves nothing.
///
/// Widening it is what makes the difference observable: with this set and the
/// guard below removed, two preempted threads are handed the same page within
/// a few thousand allocations. With the guard in place, interrupts are masked
/// across the whole of `alloc_page`, so the delay cannot be preempted and
/// there is nothing to observe — which is the result the selftest asserts.
///
/// A branch on the success path of an allocation is the cost, so that the
/// shipped binary is the one the test exercises rather than a debug build of
/// something adjacent to it.
pub var race_window_spins: u32 = 0;

fn widen_race_window() void {
    var i: u32 = 0;
    while (i < race_window_spins) : (i += 1) asm volatile ("" ::: "memory");
}

pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;

const MAX_PAGES = 1 << 24; // up to 64 GiB
var bitmap: [MAX_PAGES / 8]u8 = undefined;

/// One past the highest page index any region reached — the bound the
/// allocator scans within. Distinct from `total_pages` because a machine
/// whose RAM starts high (ARM's starts at 0x4000_0000) has a large gap of
/// indices below it that exist in the bitmap and are not memory.
var max_page: usize = 0;

/// Pages of real, usable memory. What the machine actually has.
var total_pages: usize = 0;
var free_pages: usize = 0;
var next_hint: usize = 0;

/// Start a fresh map. Everything is reserved until a region says otherwise,
/// so a page nobody described can never be handed out.
///
/// Building the map through these four calls, rather than by handing the
/// allocator a boot structure, is what makes it architecture-neutral: x86
/// learns its memory from a multiboot2 map and ARM from a device tree, and
/// neither format needs to be known here.
pub fn begin() void {
    @memset(&bitmap, 0xFF);
    max_page = 0;
    total_pages = 0;
    free_pages = 0;
    next_hint = 0;
}

/// Mark a range as usable RAM.
pub fn add_available(base: u64, len: u64) void {
    const first = base >> PAGE_SHIFT;
    if (first >= MAX_PAGES) return;
    const last = @min((base + len) >> PAGE_SHIFT, MAX_PAGES);
    var p = first;
    while (p < last) : (p += 1) {
        if (is_set(p)) {
            clear_bit(p);
            free_pages += 1;
            total_pages += 1;
        }
    }
    max_page = @max(max_page, last);
}

/// Mark a range as in use: the kernel image, a framebuffer, the device tree
/// itself — anything already occupying memory the map called available.
///
/// Rounds outward. A reservation that covered only whole pages inside the
/// range would leave the page holding its first byte allocatable, which is
/// the kind of overlap that corrupts something once and never reproduces.
pub fn reserve(base: u64, len: u64) void {
    if (len == 0) return;
    const first = base >> PAGE_SHIFT;
    if (first >= MAX_PAGES) return;
    const last = @min((base + len + PAGE_SIZE - 1) >> PAGE_SHIFT, MAX_PAGES);
    var p = first;
    while (p < last) : (p += 1) {
        if (!is_set(p)) {
            set_bit(p);
            free_pages -= 1;
        }
    }
}

/// Finish the map and point the allocator at the first free page, so the
/// first allocation on a machine whose RAM starts high does not scan a
/// quarter of a million reserved bits to find it.
pub fn finish() void {
    var p: usize = 0;
    while (p < max_page) : (p += 1) {
        if (!is_set(p)) {
            next_hint = p;
            return;
        }
    }
    next_hint = 0;
}

/// One page, or null.
///
/// Interrupts are masked across the whole of this. `is_set` and `set_bit` are
/// a test and a separate store, and `free_pages` and `next_hint` are both
/// read-modify-written after them: a timer tick anywhere in that sequence
/// hands the same page to two threads, and the two of them then write over
/// each other. Nothing allocated from a thread when this was written — every
/// spawn happened on the boot path, where preemption is a no-op — so the race
/// was unreachable rather than absent, and a scheduler is exactly the thing
/// that reaches it.
pub fn alloc_page() ?u64 {
    const guard = irqlock.acquire();
    defer guard.release();

    var i = next_hint;
    var scanned: usize = 0;
    while (scanned < max_page) : (scanned += 1) {
        if (i >= max_page) i = 0;
        if (!is_set(i)) {
            if (race_window_spins != 0) widen_race_window();
            set_bit(i);
            free_pages -= 1;
            next_hint = i + 1;
            return @as(u64, i) << PAGE_SHIFT;
        }
        i += 1;
    }
    return null;
}

/// `count` contiguous pages, or null.
///
/// Worse than `alloc_page` unguarded: the run is found in one loop and
/// claimed in a second, so the window between deciding and taking is as long
/// as the run. The guard nests — the `count == 1` case below calls
/// `alloc_page`, which takes it again — and that is safe by construction; see
/// sync/irqlock.zig.
pub fn alloc_pages(count: usize) ?u64 {
    if (count == 0) return null;
    if (count == 1) return alloc_page();

    const guard = irqlock.acquire();
    defer guard.release();

    // Linear scan for `count` contiguous free pages.
    var run: usize = 0;
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < max_page) : (i += 1) {
        if (!is_set(i)) {
            if (run == 0) run_start = i;
            run += 1;
            if (run == count) {
                var j: usize = 0;
                while (j < count) : (j += 1) set_bit(run_start + j);
                free_pages -= count;
                return @as(u64, run_start) << PAGE_SHIFT;
            }
        } else {
            run = 0;
        }
    }
    return null;
}

/// Give a page back.
///
/// Guarded for the same reason as the two above: `free_pages` and `next_hint`
/// are read-modify-written, and the double-free check is a test followed by a
/// separate clear.
pub fn free_page(phys_addr: u64) void {
    const guard = irqlock.acquire();
    defer guard.release();

    const page = phys_addr >> PAGE_SHIFT;
    if (page >= max_page) return;
    if (!is_set(page)) return; // double-free; ignore
    clear_bit(page);
    free_pages += 1;
    if (page < next_hint) next_hint = page;
}

pub fn stats() Stats {
    return .{
        .total_pages = total_pages,
        .free_pages = free_pages,
        .used_pages = total_pages - free_pages,
        .total_bytes = total_pages * PAGE_SIZE,
    };
}

pub const Stats = struct {
    total_pages: usize,
    free_pages: usize,
    used_pages: usize,
    total_bytes: usize,
};

inline fn set_bit(page: usize) void {
    bitmap[page >> 3] |= @as(u8, 1) << @as(u3, @intCast(page & 7));
}

inline fn clear_bit(page: usize) void {
    bitmap[page >> 3] &= ~(@as(u8, 1) << @as(u3, @intCast(page & 7)));
}

inline fn is_set(page: usize) bool {
    return (bitmap[page >> 3] & (@as(u8, 1) << @as(u3, @intCast(page & 7)))) != 0;
}
