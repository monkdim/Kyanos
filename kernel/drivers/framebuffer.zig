//! Framebuffer driver — VESA / GOP linear framebuffer.
//!
//! The bootloader sets up the mode and hands us a BootInfo entry
//! describing the framebuffer (phys addr, pitch, dims, bpp). We map
//! it into the kernel address space, expose it as /dev/fb0, and let
//! the Clarity userspace draw into it via mmap().

const std = @import("std");
const heap = @import("../mm/heap.zig");
const multiboot = @import("../boot/multiboot2.zig");
const vmm = @import("../mm/vmm.zig");

pub var info: ?Info = null;
pub var pixels: ?[*]u32 = null;

pub const Info = struct {
    phys_addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
};

pub fn init(fb: multiboot.Framebuffer) !void {
    info = .{
        .phys_addr = fb.addr,
        .pitch = fb.pitch,
        .width = fb.width,
        .height = fb.height,
        .bpp = fb.bpp,
    };
    // Map the framebuffer into the kernel address space.
    const size = @as(u64, fb.pitch) * fb.height;
    const pages = (size + 0xFFF) / 0x1000;
    var i: u64 = 0;
    while (i < pages) : (i += 1) {
        const phys = fb.addr + i * 0x1000;
        const virt = 0xFFFF_C000_0000_0000 + i * 0x1000;
        try vmm.map_page(vmm.kernel(), virt, phys, vmm.PAGE_PRESENT | vmm.PAGE_WRITE);
    }
    pixels = @ptrFromInt(0xFFFF_C000_0000_0000);
}

pub fn put_pixel(x: u32, y: u32, bgra: u32) void {
    const fb_info = info orelse return;
    const px = pixels orelse return;
    if (x >= fb_info.width or y >= fb_info.height) return;
    const stride_pixels = fb_info.pitch / 4;
    px[y * stride_pixels + x] = bgra;
}

pub fn clear(bgra: u32) void {
    const fb_info = info orelse return;
    const px = pixels orelse return;
    const stride_pixels = fb_info.pitch / 4;
    var y: u32 = 0;
    while (y < fb_info.height) : (y += 1) {
        var x: u32 = 0;
        while (x < fb_info.width) : (x += 1) {
            px[y * stride_pixels + x] = bgra;
        }
    }
}

/// How many bytes the framebuffer occupies, or null if the bootloader did
/// not hand one up. `pitch` and `height` are both u32, so the product cannot
/// overflow the u64 it is computed in -- 0xFFFFFFFF squared is under 2^64.
pub fn byte_size() ?u64 {
    const fb_info = info orelse return null;
    return @as(u64, fb_info.pitch) * fb_info.height;
}

/// That size rounded up to whole pages, which is what actually gets mapped,
/// or null if there is no framebuffer or the rounding would not fit.
///
/// The rounding is checked rather than written as `(size + 0xFFF) & ~0xFFF`
/// because the geometry is the bootloader's, not the kernel's: `pitch` and
/// `height` each fill a u32, and their product can come within 0xFFF of the
/// top of a u64. That is not a reachable geometry on any real display, which
/// is exactly why it would sit here unnoticed, and the kernel does not get to
/// assume a tag it did not write is sensible.
pub fn mapped_size() ?u64 {
    const size = byte_size() orelse return null;
    const rounded = @addWithOverflow(size, 0xFFF);
    if (rounded[1] != 0) return null;
    return rounded[0] & ~@as(u64, 0xFFF);
}

pub const MapError = error{
    /// There is no framebuffer to map.
    NoFramebuffer,
    /// `user_virt` is not page-aligned, or the range it asks for is not
    /// wholly inside userspace.
    BadRange,
    OutOfMemory,
};

/// Map the framebuffer's physical pages into `space` at `user_virt`
/// with PAGE_USER + PAGE_WRITE so a userspace compositor can blit
/// directly. Returns the byte length of the framebuffer on success
/// (caller-side: that's the size to mmap-track in its region list).
///
/// `user_virt` comes from a user process, so it is checked here as well as in
/// the caller. Not for the sake of belt and braces: this is a public function
/// that installs user-reachable page-table entries, and the next caller to be
/// written will not necessarily be a system call that has already checked.
/// The checks are the cheap part; the expensive part is that the range is
/// derived from the framebuffer's own geometry rather than from anything the
/// caller said about length, so there is no second length to disagree.
///
/// A failure part-way through leaves nothing mapped. The loop used to stop at
/// the failing page and return the error with every page before it still
/// installed and no region recorded -- a range the process could read and the
/// kernel had no record of, so nothing would ever unmap it.
pub fn map_into_user(space: *vmm.AddressSpace, user_virt: u64) MapError!u64 {
    const fb_info = info orelse return error.NoFramebuffer;
    const size = @as(u64, fb_info.pitch) * fb_info.height;
    // Whole pages, by the one function that does that rounding, so the
    // length checked here and the length `sys_mmap` checked are the same
    // number and not two computations of it.
    const span = mapped_size() orelse return error.NoFramebuffer;
    const pages = span / 0x1000;
    if (pages == 0) return error.NoFramebuffer;

    if (user_virt & 0xFFF != 0) return error.BadRange;
    // Checked, not assumed: `user_virt + span` on an address near the top of
    // the 64-bit space wraps round past zero, and a wrapped end compares
    // below any limit. Measured before this check existed: a request at
    // 0xFFFF_FFFF_FFFF_F000 ended the boot with "integer overflow".
    const end = @addWithOverflow(user_virt, span);
    if (end[1] != 0) return error.BadRange;
    if (end[0] > vmm.USER_TOP) return error.BadRange;

    var i: u64 = 0;
    while (i < pages) : (i += 1) {
        const phys = fb_info.phys_addr + i * 0x1000;
        const virt = user_virt + i * 0x1000;
        vmm.map_page(space, virt, phys, vmm.PAGE_PRESENT | vmm.PAGE_WRITE | vmm.PAGE_USER) catch |err| {
            unmap_range(space, user_virt, i);
            // `map_page` refuses a user mapping in the kernel's half. The
            // checks above mean this range has already been found to be
            // inside userspace, so reaching it would be the two disagreeing
            // -- but it is reported as what it is rather than as running out
            // of memory, which is what a caller would otherwise be told.
            return switch (err) {
                error.NotUserAddress => error.BadRange,
                else => error.OutOfMemory,
            };
        };
    }
    // Track the mapping as a region so munmap + COW (later) work.
    space.regions.append(heap.allocator(), .{
        .start = user_virt,
        .end = end[0],
        .flags = vmm.PAGE_WRITE,
        .backing = .{ .device = .{ .phys_base = fb_info.phys_addr } },
    }) catch {
        // A mapping the kernel has no record of is worse than no mapping.
        unmap_range(space, user_virt, pages);
        return error.OutOfMemory;
    };
    return size;
}

/// Take back the first `pages` pages of a mapping this module installed.
/// The frames are the framebuffer's own, so they are not returned to the
/// physical allocator -- only the page-table entries go.
fn unmap_range(space: *vmm.AddressSpace, user_virt: u64, pages: u64) void {
    var i: u64 = 0;
    while (i < pages) : (i += 1) vmm.unmap_page(space, user_virt + i * 0x1000);
}

/// Geometry inquiry — userspace asks what the framebuffer looks
/// like before mapping.
pub const FbInfoForUser = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
    fb_type: u8,
    pad: u16,
};

pub fn user_info() ?FbInfoForUser {
    const fb_info = info orelse return null;
    return .{
        .width = fb_info.width,
        .height = fb_info.height,
        .pitch = fb_info.pitch,
        .bpp = fb_info.bpp,
        .fb_type = 1,
        .pad = 0,
    };
}
