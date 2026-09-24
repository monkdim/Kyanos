//! Kernel heap — slab allocator over the page allocator.
//!
//! Slabs of fixed-size objects (32, 64, 128, 256, 512, 1024, 2048,
//! 4096 bytes). Allocations larger than 4 KiB go through the page
//! allocator directly.
//!
//! Each slab is a linked list of pages, where each page is a list of
//! free chunks. Allocation pulls the head of a free list; free pushes
//! back onto it.

const std = @import("std");
const pmm = @import("pmm.zig");
const irqlock = @import("../sync/irqlock.zig");

/// Where physical memory appears in the kernel's address space.
///
/// Both architectures keep a direct map of all of physical memory; they put
/// it at different addresses, because each is constrained by its own paging
/// structure — x86_64's canonical upper half, and the first address AArch64's
/// TTBR1 translates with a 39-bit VA space. This file only needs to turn a
/// frame the page allocator returned into something it can write to, so the
/// address is the only part that differs.
///
/// Was 0xFFFF_8000_0000_0000 written out three times, which was correct for
/// exactly as long as there was one architecture.
const DIRECT_MAP: usize = switch (@import("builtin").cpu.arch) {
    // Matches mm/vmm.zig and boot/start.S.
    .x86_64 => 0xFFFF_8000_0000_0000,
    // Taken from the definition rather than copied, so the two cannot drift.
    .aarch64 => @import("../arch/aarch64/vm.zig").KERNEL_VA_BASE,
    else => @compileError("no direct map defined for this architecture"),
};

const SLAB_CLASSES = [_]usize{ 32, 64, 128, 256, 512, 1024, 2048, 4096 };
const SLAB_COUNT = SLAB_CLASSES.len;

const SlabFreeNode = struct {
    next: ?*SlabFreeNode,
};

const Slab = struct {
    object_size: usize,
    free_list: ?*SlabFreeNode = null,
    pages_owned: usize = 0,
};

var slabs: [SLAB_COUNT]Slab = undefined;

pub fn init() void {
    for (SLAB_CLASSES, 0..) |size, i| {
        slabs[i] = .{ .object_size = size };
    }
}

// ── std.mem.Allocator interface over the slab ────────────
// So the rest of the kernel can hand a real Allocator to ArrayList /
// AutoHashMap / the loader — using OUR heap, not std.heap.page_allocator
// (which is mmap-backed and doesn't exist on a freestanding target).
pub fn allocator() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &vtable };
}

const vtable = std.mem.Allocator.VTable{
    .alloc = vt_alloc,
    .resize = vt_resize,
    .free = vt_free,
};

// Pick a slab class big enough for both the length and the alignment, so
// the class-aligned chunk we return also satisfies the requested align.
fn need_size(len: usize, log2_align: u8) usize {
    const alignment = @as(usize, 1) << @as(u6, @intCast(log2_align));
    return if (alignment > len) alignment else len;
}

fn vt_alloc(_: *anyopaque, len: usize, log2_align: u8, _: usize) ?[*]u8 {
    return alloc(need_size(len, log2_align));
}

fn vt_resize(_: *anyopaque, buf: []u8, _: u8, new_len: usize, _: usize) bool {
    return new_len <= buf.len;
}

fn vt_free(_: *anyopaque, buf: []u8, log2_align: u8, _: usize) void {
    free(buf.ptr, need_size(buf.len, log2_align));
}

/// A chunk of at least `size` bytes, or null.
///
/// Guarded for the same reason the page allocator is: pulling the head off a
/// free list is a read of `slab.free_list`, a read of `node.next` and a store
/// back, and two threads interrupted between them are handed the same chunk.
/// `grow_slab` reaches the page allocator, which takes the guard again; that
/// nests safely, see sync/irqlock.zig.
pub fn alloc(size: usize) ?[*]u8 {
    const guard = irqlock.acquire();
    defer guard.release();

    if (size == 0) return null;
    if (size > 4096) {
        const pages = (size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
        const phys = pmm.alloc_pages(pages) orelse return null;
        return @ptrFromInt(DIRECT_MAP + phys);
    }
    const class_idx = pick_class(size) orelse return null;
    const slab = &slabs[class_idx];
    if (slab.free_list == null) {
        if (!grow_slab(slab)) return null;
    }
    const node = slab.free_list.?;
    slab.free_list = node.next;
    return @ptrCast(node);
}

/// Give a chunk back.
///
/// Pushing onto the free list is the mirror of the pull above — a read of the
/// head, a store into the node, a store back — and races the same way.
pub fn free(ptr: [*]u8, size: usize) void {
    const guard = irqlock.acquire();
    defer guard.release();

    if (size > 4096) {
        const pages = (size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
        var i: usize = 0;
        while (i < pages) : (i += 1) {
            const virt: u64 = @intFromPtr(ptr) + i * pmm.PAGE_SIZE;
            const phys = virt - DIRECT_MAP;
            pmm.free_page(phys);
        }
        return;
    }
    const class_idx = pick_class(size) orelse return;
    const slab = &slabs[class_idx];
    const node: *SlabFreeNode = @ptrCast(@alignCast(ptr));
    node.next = slab.free_list;
    slab.free_list = node;
}

fn pick_class(size: usize) ?usize {
    for (SLAB_CLASSES, 0..) |class_size, i| {
        if (size <= class_size) return i;
    }
    return null;
}

fn grow_slab(slab: *Slab) bool {
    const phys = pmm.alloc_page() orelse return false;
    slab.pages_owned += 1;
    const base: usize = @intCast(DIRECT_MAP + phys);
    var offset: usize = 0;
    while (offset + slab.object_size <= pmm.PAGE_SIZE) : (offset += slab.object_size) {
        const node: *SlabFreeNode = @ptrFromInt(base + offset);
        node.next = slab.free_list;
        slab.free_list = node;
    }
    return true;
}
