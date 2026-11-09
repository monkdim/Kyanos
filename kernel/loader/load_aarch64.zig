//! Loading an ELF into an AArch64 process's address space.
//!
//! The counterpart to load.zig, and deliberately not a copy of it: the part
//! that walks a segment page by page, zeroes each frame, maps it and copies
//! the file-backed bytes lives in segments.zig and is the same code both
//! architectures run. What is here is what actually differs — how a page is
//! mapped (paging.zig rather than vmm.zig), where the kernel reaches physical
//! memory, and the two things this architecture needs that x86_64 does not.
//!
//! Those two are worth naming. The kernel writes a program's instructions
//! through the data cache and EL0 fetches them through the instruction cache,
//! which knows nothing about the stores — so every executable page has to be
//! made coherent before it is run. And the mapped pages have to be tracked to
//! be freed, because paging.destroy frees the tables and deliberately not the
//! memory they point at: the tables are the address space's, the frames are
//! whoever allocated them.

const std = @import("std");
const elf = @import("elf.zig");
const segments = @import("segments.zig");
const pmm = @import("../mm/pmm.zig");
const paging = @import("../arch/aarch64/paging.zig");
const mmu = @import("../arch/aarch64/mmu.zig");
const vm = @import("../arch/aarch64/vm.zig");

/// Where a process's stack ends. Two gigabytes: clear of where the linker
/// puts the program (user/user.ld starts it just above one gigabyte) and far
/// inside the 512 GiB TTBR0 translates.
pub const USER_STACK_TOP: u64 = 0x0000_0000_8000_0000;
pub const USER_STACK_PAGES: u64 = 8;

/// What segments.zig needs to know about this architecture.
pub const Ops = struct {
    pub const Space = paging.AddressSpace;

    pub fn map(space: *Space, virt: u64, phys: u64, writable: bool, executable: bool) !void {
        var flags: u32 = paging.MAP_USER;
        if (writable) flags |= paging.MAP_WRITE;
        if (executable) flags |= paging.MAP_EXEC;
        return paging.map_page(space, virt, phys, flags);
    }

    pub fn phys_to_virt(phys: u64) u64 {
        return vm.phys_to_virt(phys);
    }
};

pub const Range = struct { start: u64, end: u64 };

/// A loaded program, and enough to take it apart again.
pub const Loaded = struct {
    space: paging.AddressSpace,
    entry: u64,
    user_sp: u64,
    /// Where this program's heap starts: the first page-aligned address past
    /// everything the image occupies. A process's break begins here and only
    /// ever moves up from it, so a `brk` that asked for less would be asking
    /// the kernel to unmap the program's own .bss.
    brk_start: u64,
    /// Every page-aligned range mapped into the space, so `release` can
    /// return the frames. Eight is comfortably more than a static
    /// freestanding binary's segments plus its stack; a program with more is
    /// refused rather than partly freed later.
    ranges: [8]Range,
    range_count: usize,
};

pub const Error = error{
    OutOfMemory,
    TooManySegments,
    /// The executable asks for an address this machine's user half does not
    /// reach.
    BadExecutable,
};

pub fn load(image: []const u8, asid: u16, gpa: std.mem.Allocator) !Loaded {
    const exe = try elf.parse(image, gpa);
    defer elf.release(gpa, exe);

    var out = Loaded{
        .space = paging.create(asid) orelse return Error.OutOfMemory,
        .entry = exe.entry,
        // AAPCS64 requires the stack pointer to be 16-byte aligned at all
        // times, not merely at a call. The pages below are zeroed, so the
        // headroom is also an empty argc/argv/envp frame for whenever
        // something starts reading one.
        .user_sp = USER_STACK_TOP - 64,
        .brk_start = 0,
        .ranges = undefined,
        .range_count = 0,
    };
    // No heap yet at this point: brk has not run, so there is nothing past
    // brk_start to give back.
    errdefer release(&out, 0);

    // Where every segment wants to go, before anything is mapped.
    //
    // `paging.map_page` already refuses an address at or above USER_VA_END,
    // so a segment asking for one could not be mapped -- but it would be
    // refused at its first page, with everything before it already mapped,
    // and reported as whatever that call returns. Asked up front, the answer
    // names the executable.
    //
    // USER_VA_END is 1 << 39: the first address TTBR0 does not cover with
    // T0SZ = 25. That is this machine's number, which is why the check lives
    // here and not in loader/elf.zig -- the x86_64 user half ends at 1 << 47
    // and the shared parser must not pick one of the two.
    for (exe.segments) |seg| {
        // `elf.parse` has refused anything whose end wraps.
        if (seg.vaddr + seg.memsz > paging.USER_VA_END) return Error.BadExecutable;
    }
    if (exe.entry >= paging.USER_VA_END) return Error.BadExecutable;

    for (exe.segments) |seg| {
        try segments.map_segment(Ops, &out.space, seg, image);
        const seg_end = segments.page_round_up(seg.vaddr + seg.memsz);
        try remember(&out, segments.page_round_down(seg.vaddr), seg_end);
        if (seg_end > out.brk_start) out.brk_start = seg_end;

        // The instructions were just written through the data cache, and EL0
        // is about to fetch them through the instruction cache. QEMU models
        // neither and would run correctly without this; hardware would not,
        // and loading a program is exactly where that difference bites.
        if (seg.executable()) {
            var addr = segments.page_round_down(seg.vaddr);
            const end = segments.page_round_up(seg.vaddr + seg.memsz);
            while (addr < end) : (addr += pmm.PAGE_SIZE) {
                const phys = paging.lookup(&out.space, addr) orelse continue;
                mmu.sync_instructions(vm.phys_to_virt(phys & ~@as(u64, pmm.PAGE_SIZE - 1)), pmm.PAGE_SIZE);
            }
        }
    }

    const stack_bottom = USER_STACK_TOP - USER_STACK_PAGES * pmm.PAGE_SIZE;
    var p: u64 = 0;
    while (p < USER_STACK_PAGES) : (p += 1) {
        const phys = pmm.alloc_page() orelse return Error.OutOfMemory;
        // Zeroed for two reasons: the allocator hands back whatever was last
        // in the frame, so an unzeroed stack lets a new process read what a
        // previous one wrote; and the empty initial frame described above
        // *is* zeroes.
        segments.zero(Ops, phys);
        paging.map_page(&out.space, stack_bottom + p * pmm.PAGE_SIZE, phys, paging.MAP_USER | paging.MAP_WRITE) catch
            return Error.OutOfMemory;
    }
    try remember(&out, stack_bottom, USER_STACK_TOP);

    return out;
}

/// Give back everything the load took: the frames behind every mapping, then
/// the tables that described them. In that order, because finding a frame
/// means asking the tables where it is.
///
/// `heap_end` is where the process's break finished, which the loader could
/// not know: those pages were mapped by brk while the program was running,
/// and are as much the process's as its segments are.
pub fn release(loaded: *Loaded, heap_end: u64) void {
    if (heap_end > loaded.brk_start) {
        var addr = loaded.brk_start;
        const end = segments.page_round_up(heap_end);
        while (addr < end) : (addr += pmm.PAGE_SIZE) {
            if (paging.lookup(&loaded.space, addr)) |phys| {
                paging.unmap_page(&loaded.space, addr);
                pmm.free_page(phys & ~@as(u64, pmm.PAGE_SIZE - 1));
            }
        }
    }

    var i: usize = 0;
    while (i < loaded.range_count) : (i += 1) {
        const r = loaded.ranges[i];
        var addr = r.start;
        while (addr < r.end) : (addr += pmm.PAGE_SIZE) {
            if (paging.lookup(&loaded.space, addr)) |phys| {
                paging.unmap_page(&loaded.space, addr);
                pmm.free_page(phys & ~@as(u64, pmm.PAGE_SIZE - 1));
            }
        }
    }
    loaded.range_count = 0;
    paging.destroy(&loaded.space);
}

fn remember(loaded: *Loaded, start: u64, end: u64) Error!void {
    if (loaded.range_count >= loaded.ranges.len) return Error.TooManySegments;
    loaded.ranges[loaded.range_count] = .{ .start = start, .end = end };
    loaded.range_count += 1;
}
