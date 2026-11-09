//! ELF64 parser + program loader.
//!
//! Reads an ELF64 little-endian executable from a byte buffer,
//! validates the header, walks the program headers, and returns a
//! `LoadedExecutable` describing the segments to map into a user
//! address space.
//!
//! Strict subset:
//!   * EI_CLASS == ELFCLASS64
//!   * EI_DATA  == ELFDATA2LSB
//!   * e_type   == ET_EXEC or ET_DYN (treated as a static PIE)
//!   * e_machine == this kernel's architecture
//!   * Loadable segments must be PT_LOAD; we ignore PT_NOTE /
//!     PT_DYNAMIC / PT_TLS / PT_GNU_* for now (loader hand-off
//!     doesn't need them yet — userspace is statically linked).
//!
//! Doesn't actually map pages. That's load.zig's job once it has a
//! target AddressSpace.

const std = @import("std");
const pmm = @import("../mm/pmm.zig");

pub const ELFMAG: [4]u8 = .{ 0x7F, 'E', 'L', 'F' };
pub const ELFCLASS64: u8 = 2;
pub const ELFDATA2LSB: u8 = 1;

pub const ET_EXEC: u16 = 2;
pub const ET_DYN: u16 = 3;
pub const EM_X86_64: u16 = 62;
pub const EM_AARCH64: u16 = 183;

/// The machine this kernel can run. An ELF for the other architecture is
/// rejected rather than loaded and jumped into, which is the difference
/// between an error message and a machine that stops.
pub const EM_NATIVE: u16 = switch (@import("builtin").cpu.arch) {
    .x86_64 => EM_X86_64,
    .aarch64 => EM_AARCH64,
    else => @compileError("no ELF machine number for this architecture"),
};

pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_NOTE: u32 = 4;
pub const PT_PHDR: u32 = 6;
pub const PT_TLS: u32 = 7;

pub const PF_X: u32 = 1;
pub const PF_W: u32 = 2;
pub const PF_R: u32 = 4;

pub const Header = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

pub const ProgramHeader = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub const Segment = struct {
    vaddr: u64,
    filesz: u64,
    memsz: u64,
    flags: u32,
    file_offset: u64,

    pub fn readable(self: Segment) bool { return (self.flags & PF_R) != 0; }
    pub fn writable(self: Segment) bool { return (self.flags & PF_W) != 0; }
    pub fn executable(self: Segment) bool { return (self.flags & PF_X) != 0; }
};

pub const LoadedExecutable = struct {
    entry: u64,
    is_dynamic: bool,
    segments: []const Segment,

    pub fn highest_address(self: LoadedExecutable) u64 {
        var max: u64 = 0;
        for (self.segments) |s| {
            // Saturating: `parse` refuses a segment whose end wraps, so this
            // cannot be reached with one -- but this is a public method on a
            // public type, and a sum that wraps here would read as a *low*
            // address, which is the dangerous direction.
            const end = s.vaddr +| s.memsz;
            if (end > max) max = end;
        }
        return max;
    }
};

pub const ParseError = error{
    Truncated,
    BadMagic,
    Not64Bit,
    NotLittleEndian,
    UnsupportedType,
    UnsupportedMachine,
    BadPhdrTable,
    OutOfMemory,
    Overflow,
    /// Nothing to load: no PT_LOAD segment at all.
    NoLoadableSegments,
    /// The entry point is not inside any segment the file asks to have
    /// loaded, so there would be nothing mapped at the address the process
    /// is supposed to start at.
    EntryNotMapped,
    /// Two segments' page-rounded ranges intersect. See `segments_overlap`.
    OverlappingSegments,
};

/// One fixed-size structure out of a byte slice, at any alignment.
///
/// The caller has already checked that `off + @sizeOf(T)` is within `bytes`.
fn read_struct(comptime T: type, bytes: []const u8, off: u64) T {
    var out: T = undefined;
    @memcpy(std.mem.asBytes(&out), bytes[@intCast(off)..][0..@sizeOf(T)]);
    return out;
}

/// Parse `bytes` as an ELF64 image. Allocates the segment slice
/// from `gpa`; caller frees with `release(gpa, exe)`.
pub fn parse(bytes: []const u8, gpa: std.mem.Allocator) ParseError!LoadedExecutable {
    if (bytes.len < @sizeOf(Header)) return error.Truncated;

    // Copied out of the bytes rather than read through a pointer into them.
    //
    // An ELF header is eight-byte aligned inside the file, but the *file* is
    // wherever it happens to be — and these arrive from @embedFile, which
    // makes no alignment promise at all. Casting the byte pointer to
    // *const Header therefore worked for two embedded programs and panicked
    // the kernel on the third, with "incorrect alignment", before it had
    // parsed a single field. Nothing about the ELF changed; only where the
    // linker put it.
    //
    // A copy has no such dependency, and costs sixty-four bytes once per
    // program load.
    const hdr = read_struct(Header, bytes, 0);
    if (!std.mem.eql(u8, hdr.e_ident[0..4], &ELFMAG)) return error.BadMagic;
    if (hdr.e_ident[4] != ELFCLASS64) return error.Not64Bit;
    if (hdr.e_ident[5] != ELFDATA2LSB) return error.NotLittleEndian;
    if (hdr.e_type != ET_EXEC and hdr.e_type != ET_DYN) return error.UnsupportedType;
    if (hdr.e_machine != EM_NATIVE) return error.UnsupportedMachine;
    if (hdr.e_phentsize != @sizeOf(ProgramHeader)) return error.BadPhdrTable;

    const phoff = hdr.e_phoff;
    const phnum = @as(u64, hdr.e_phnum);
    // Cannot overflow: `e_phnum` is a u16, so this is at most 65535 * 56.
    const ph_total = phnum * @sizeOf(ProgramHeader);
    // The sum can. Every bound in this function is an addition on a field
    // taken straight out of the file, and an addition that wraps compares
    // *below* the limit it was meant to enforce -- so the check lets the
    // image through and the read that follows goes wherever the field said.
    //
    // Measured on the revision before this: `e_phoff` of
    // 0xFFFFFFFFFFFFFFFF with everything else well-formed ended the boot
    // with "KERNEL PANIC: integer overflow" at this line, and a host build
    // of this same file panicked at the same line. It was the first thing
    // the loader did with the image.
    const ph_end = @addWithOverflow(phoff, ph_total);
    if (ph_end[1] != 0 or ph_end[0] > bytes.len) return error.Truncated;

    var loadable = std.ArrayList(Segment).init(gpa);
    errdefer loadable.deinit();

    var i: u64 = 0;
    while (i < phnum) : (i += 1) {
        const off = phoff + i * @sizeOf(ProgramHeader);
        const ph = read_struct(ProgramHeader, bytes, off);
        if (ph.p_type != PT_LOAD) continue;
        if (ph.p_filesz > ph.p_memsz) return error.BadPhdrTable;

        // Where the contents are in the file.
        const file_end = @addWithOverflow(ph.p_offset, ph.p_filesz);
        if (file_end[1] != 0 or file_end[0] > bytes.len) return error.Truncated;

        // Where the segment goes in memory. Checked here rather than left to
        // whoever maps it, because three places downstream add these two
        // together and two of them then round the sum up to a page -- so an
        // end that wraps becomes a *small* number before anybody compares it
        // to anything.
        const mem_end = @addWithOverflow(ph.p_vaddr, ph.p_memsz);
        if (mem_end[1] != 0) return error.Overflow;
        // And the rounding itself, for the same reason.
        if (mem_end[0] > std.math.maxInt(u64) - (pmm.PAGE_SIZE - 1)) return error.Overflow;

        try loadable.append(.{
            .vaddr = ph.p_vaddr,
            .filesz = ph.p_filesz,
            .memsz = ph.p_memsz,
            .flags = ph.p_flags,
            .file_offset = ph.p_offset,
        });
    }

    const segs = loadable.items;

    // Something to load. An image with no PT_LOAD used to produce a process
    // with an empty address space and a `brk_start` of zero, which was then
    // entered at whatever `e_entry` said.
    if (segs.len == 0) return error.NoLoadableSegments;

    // Somewhere to start. `e_entry` is the address the kernel hands to
    // `sysretq` (x86_64) or writes to ELR_EL1 (aarch64); nothing checked that
    // a page would be mapped there, so an entry point pointing anywhere at
    // all was loaded and jumped to. An address no segment covers cannot be
    // anything but a fault, and on x86_64 a non-canonical one is a #GP in
    // ring 0 rather than in the process.
    //
    // Checked against the segment's own extent rather than its page-rounded
    // one: the extra bytes in the last page of a segment are not part of the
    // program, and a linker that meant to start there would have said so.
    if (!address_in_segments(hdr.e_entry, segs)) return error.EntryNotMapped;

    // And one frame per page. See `segments_overlap`.
    if (segments_overlap(segs)) return error.OverlappingSegments;

    return .{
        .entry = hdr.e_entry,
        .is_dynamic = hdr.e_type == ET_DYN,
        .segments = try loadable.toOwnedSlice(),
    };
}

fn address_in_segments(addr: u64, segs: []const Segment) bool {
    for (segs) |s| {
        // `parse` has already refused a segment whose end wraps.
        if (addr >= s.vaddr and addr < s.vaddr + s.memsz) return true;
    }
    return false;
}

/// Do any two segments share a page?
///
/// This matters because of how a segment is mapped: `segments.map_segment`
/// walks it page by page, takes a *fresh* physical frame for each page, zeroes
/// it, maps it, and copies the file bytes in. Two segments covering the same
/// page therefore get two different frames for it, and the second mapping
/// replaces the first -- discarding whatever had been copied into it, with no
/// error anywhere. The process starts with a page of one segment silently
/// missing.
///
/// user/user.ld already knows this. It aligns every section to a page and
/// says why: "if two PT_LOADs shared a page the second would be mapped over
/// the first and silently discard whatever had been copied into it". So the
/// layouts this loader supports are the page-disjoint ones, and that is not a
/// limitation being introduced here -- it is the one that already existed,
/// said out loud instead of producing a broken process.
///
/// Real linkers do emit page-sharing segments, and honouring them means
/// mapping a page once and copying both segments' bytes into it with the
/// union of their permissions. That is a larger change than refusing them,
/// and refusing is the safe direction in the meantime: a program that will
/// not start is better than one that starts with a hole in it.
fn segments_overlap(segs: []const Segment) bool {
    for (segs, 0..) |a, ai| {
        // A segment that occupies nothing cannot share a page with anything.
        // Skipped rather than measured, because its rounded range is empty
        // and an empty range sits *inside* a neighbour's -- which the test
        // below would call an overlap and refuse an image over.
        if (a.memsz == 0) continue;
        const a_start = a.vaddr & ~@as(u64, pmm.PAGE_SIZE - 1);
        const a_end = (a.vaddr + a.memsz + pmm.PAGE_SIZE - 1) & ~@as(u64, pmm.PAGE_SIZE - 1);
        for (segs[ai + 1 ..]) |b| {
            if (b.memsz == 0) continue;
            const b_start = b.vaddr & ~@as(u64, pmm.PAGE_SIZE - 1);
            const b_end = (b.vaddr + b.memsz + pmm.PAGE_SIZE - 1) & ~@as(u64, pmm.PAGE_SIZE - 1);
            if (a_start < b_end and b_start < a_end) return true;
        }
    }
    return false;
}

pub fn release(gpa: std.mem.Allocator, exe: LoadedExecutable) void {
    gpa.free(exe.segments);
}
