//! Getting an ELF's PT_LOAD segments into an address space.
//!
//! The part of loading a program that is the same on every machine: walk each
//! segment page by page, take a fresh physical frame for each, zero it, map it
//! with the segment's permissions, and copy in whatever part of the file
//! belongs there.
//!
//! What differs is two things — how a page gets mapped, and how the kernel
//! reaches a physical frame to write into it — so those are the two things an
//! architecture supplies. Everything else was written once, on the x86_64
//! side, and it would have been rewritten from memory for aarch64 with the
//! same edge cases to get wrong a second time.
//!
//! Deliberately importing neither vmm.zig nor any arch/ module: x86_64 page
//! tables and AArch64 page tables have nothing to say to each other, and a
//! file that mentions both is a file neither architecture can compile.

const std = @import("std");
const elf = @import("elf.zig");
const pmm = @import("../mm/pmm.zig");

pub const Error = error{
    OutOfMemory,
    /// The segment's own numbers do not describe a mappable range: its
    /// virtual end wraps, or its contents are not inside the image.
    ///
    /// `elf.parse` refuses both before a Segment ever gets here. This exists
    /// because `map_segment` is public and takes a Segment, not a file: the
    /// next caller may build one itself, and the cost of saying so is two
    /// comparisons per segment against a silently truncated mapping.
    BadSegment,
};

/// `Ops` is a struct type providing:
///
///   pub const Space = ...;
///   pub fn map(space: *Space, virt: u64, phys: u64, writable: bool, executable: bool) !void
///   pub fn phys_to_virt(phys: u64) u64
///
/// Duck-typed at comptime rather than through a vtable, because this is
/// resolved when the kernel is built for one architecture and there is
/// nothing to dispatch on at run time.
pub fn map_segment(
    comptime Ops: type,
    space: *Ops.Space,
    seg: elf.Segment,
    image: []const u8,
) Error!void {
    const mem_end = @addWithOverflow(seg.vaddr, seg.memsz);
    if (mem_end[1] != 0) return Error.BadSegment;
    if (mem_end[0] > std.math.maxInt(u64) - (pmm.PAGE_SIZE - 1)) return Error.BadSegment;
    const file_end = @addWithOverflow(seg.file_offset, seg.filesz);
    if (file_end[1] != 0 or file_end[0] > image.len) return Error.BadSegment;

    const start = page_round_down(seg.vaddr);
    const end = page_round_up(mem_end[0]);

    // How far into the first page the segment actually begins. A linker is
    // free to start a segment mid-page, and the bytes before it belong to
    // whatever came earlier — so the copy has to land at an offset rather
    // than at the top of the frame.
    const segment_offset = seg.vaddr - start;

    var addr = start;
    while (addr < end) : (addr += pmm.PAGE_SIZE) {
        const phys = pmm.alloc_page() orelse return Error.OutOfMemory;

        // Zeroed before anything is copied in, which is what makes .bss work:
        // a segment's p_memsz exceeds its p_filesz and the difference has to
        // read as zero. It is also why a page is not handed to a process
        // holding whatever the last one left in it.
        zero(Ops, phys);

        Ops.map(space, addr, phys, seg.writable(), seg.executable()) catch {
            // The frame was taken a moment ago and nothing is pointing at it,
            // so it goes back here. Without this, every mapping that failed
            // lost a page for the life of the machine -- and the pages mapped
            // by earlier turns of this loop are the caller's to release,
            // which is what makes that the caller's job and this one ours.
            pmm.free_page(phys);
            return Error.OutOfMemory;
        };

        // The file-backed part of this page, if any. Past p_filesz there is
        // nothing to copy and the zeroing above is the answer.
        const page_off_in_segment = if (addr >= seg.vaddr) addr - seg.vaddr else 0;
        if (page_off_in_segment >= seg.filesz) continue;

        const file_remaining = seg.filesz - page_off_in_segment;
        const dst_offset = if (addr < seg.vaddr) segment_offset else 0;
        const copy_len = @min(file_remaining, pmm.PAGE_SIZE - dst_offset);
        const src = image[seg.file_offset + page_off_in_segment ..][0..copy_len];
        const dst: [*]u8 = @ptrFromInt(Ops.phys_to_virt(phys) + dst_offset);
        @memcpy(dst[0..copy_len], src);
    }
}

pub fn zero(comptime Ops: type, phys: u64) void {
    const p: [*]u8 = @ptrFromInt(Ops.phys_to_virt(phys));
    @memset(p[0..pmm.PAGE_SIZE], 0);
}

pub inline fn page_round_down(v: u64) u64 {
    return v & ~@as(u64, pmm.PAGE_SIZE - 1);
}

pub inline fn page_round_up(v: u64) u64 {
    return (v + pmm.PAGE_SIZE - 1) & ~@as(u64, pmm.PAGE_SIZE - 1);
}
