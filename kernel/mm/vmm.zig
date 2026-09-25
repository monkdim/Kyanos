//! Virtual memory manager — 4-level page tables for x86_64.
//!
//! Each user process owns its own PML4. The kernel's higher half
//! (>= 0xFFFF_8000_0000_0000) is shared across every address space
//! by sharing the upper 256 PML4 entries. Demand paging is handled
//! by the page-fault handler in idt.zig — when a page-fault hits an
//! address inside an mmap()'d region, the handler asks pmm for a
//! page and maps it in.

const std = @import("std");
const pmm = @import("pmm.zig");

pub const PAGE_PRESENT: u64 = 1 << 0;
pub const PAGE_WRITE: u64 = 1 << 1;
pub const PAGE_USER: u64 = 1 << 2;
pub const PAGE_NX: u64 = 1 << 63;
/// PS in a PDPT or PD entry: this entry maps a 1 GiB or 2 MiB page directly
/// rather than pointing at the next level.
pub const PAGE_HUGE: u64 = 1 << 7;

pub const ADDR_MASK: u64 = 0x000FFFFFFFFFF000;

/// One per process. Holds the root page table phys addr + a small
/// list of region descriptors so the kernel knows what's mapped at
/// what permissions. Region list is checked on page fault.
pub const AddressSpace = struct {
    pml4_phys: u64,
    regions: std.ArrayListUnmanaged(Region),

    pub const Region = struct {
        start: u64,
        end: u64,
        flags: u64,
        backing: Backing,
    };

    pub const Backing = union(enum) {
        anonymous,
        file: struct { inode_num: u64, offset: u64 },
        device: struct { phys_base: u64 },
    };
};

/// The kernel's own address space. The boot stub built the page tables
/// (identity + HHDM + kernel window) and loaded them into CR3; init()
/// adopts that tree so later kernel mappings — the framebuffer, MMIO —
/// target the live tables instead of an undefined address space.
var kernel_space: AddressSpace = .{ .pml4_phys = 0, .regions = .{} };

fn read_cr3() u64 {
    return asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

pub fn init() void {
    kernel_space.pml4_phys = read_cr3() & ADDR_MASK;
}

/// The kernel address space. Valid after init().
pub fn kernel() *AddressSpace {
    return &kernel_space;
}

/// Point a fresh address space's upper half at the kernel's.
///
/// PML4 entries 256..511 cover everything at or above
/// 0xFFFF_8000_0000_0000: the kernel image, the HHDM, every kernel stack.
/// Copying the entries themselves (rather than the tables beneath them) is
/// what makes the kernel mapping *shared* — a later kernel mapping shows up
/// in every address space, because they all point at the same next-level
/// tables.
///
/// Without this a new PML4 is entirely zero, and the instruction after the
/// `mov %rax, %cr3` that installs it is unmapped: the CPU triple-faults and
/// the machine resets with nothing on the console. `alloc_address_space` had
/// a comment saying it did this and then returned without doing it, which no
/// one had noticed because nothing had ever loaded a user CR3.
pub fn share_kernel_half(pml4_phys: u64) void {
    const dest = phys_to_table(pml4_phys);
    const src = phys_to_table(kernel_space.pml4_phys);
    var i: usize = 256;
    while (i < 512) : (i += 1) dest[i] = src[i];
}

pub fn map_page(space: *AddressSpace, virt: u64, phys: u64, flags: u64) !void {
    // Walk the four levels, allocating intermediate tables on demand.
    // Each table is one 4 KiB page from the pmm. Returns error.OutOfMemory
    // if we exhaust physical pages before the path completes.
    const indices = [_]u9{
        @intCast((virt >> 39) & 0x1FF),
        @intCast((virt >> 30) & 0x1FF),
        @intCast((virt >> 21) & 0x1FF),
        @intCast((virt >> 12) & 0x1FF),
    };
    var table_phys = space.pml4_phys;
    var level: usize = 0;
    while (level < 3) : (level += 1) {
        const table = phys_to_table(table_phys);
        const entry = &table[indices[level]];
        if (entry.* & PAGE_PRESENT == 0) {
            const new_table = pmm.alloc_page() orelse return error.OutOfMemory;
            zero_page(new_table);
            entry.* = new_table | PAGE_PRESENT | PAGE_WRITE | PAGE_USER;
        } else if (level > 0 and (entry.* & PAGE_HUGE) != 0) {
            // A 1 GiB or 2 MiB page already covers this address. Its frame
            // address is *not* a page table, so descending into it would
            // write page-table entries into whatever data lives there and
            // leave the mapping unchanged — silent corruption. The boot stub
            // identity-maps the first gigabyte with 2 MiB pages, so this is
            // the normal case for any 4 KiB mapping below 1 GiB, not an edge
            // case. Split it into a full table covering the same range with
            // the same permissions, then carry on down.
            try split_huge_page(entry, level);
        }
        // Permission at a leaf is the *intersection* down the whole path: the
        // CPU denies a user access if U/S is clear at any level, and refuses
        // an instruction fetch if NX is set at any level. Intermediate tables
        // this function created are already permissive, but ones it inherited
        // are not — the boot stub builds PML4[0] and PDPT[0] with present +
        // writable and no U/S, so a user page mapped anywhere beneath them
        // faults on first touch with error_code P=1,U=1 no matter what the
        // leaf says. Widen the path to match what the leaf is asking for; the
        // leaf entries still decide what is actually reachable, which is why
        // the supervisor-only identity map above stays supervisor-only.
        if ((flags & PAGE_USER) != 0 and (entry.* & PAGE_USER) == 0) {
            entry.* |= PAGE_USER;
            flush_tlb_entry(virt);
        }
        if ((flags & PAGE_NX) == 0 and (entry.* & PAGE_NX) != 0) {
            entry.* &= ~PAGE_NX;
            flush_tlb_entry(virt);
        }
        table_phys = entry.* & ADDR_MASK;
    }
    const leaf = phys_to_table(table_phys);
    leaf[indices[3]] = (phys & ADDR_MASK) | flags | PAGE_PRESENT;
    flush_tlb_entry(virt);
}

/// Replace a huge-page entry with a table of smaller entries covering exactly
/// the same range and permissions. `level` is 1 for a 1 GiB PDPT entry (split
/// into 512 × 2 MiB) and 2 for a 2 MiB PD entry (split into 512 × 4 KiB).
fn split_huge_page(entry: *u64, level: usize) !void {
    const old = entry.*;
    const base = old & ADDR_MASK;
    // Everything except the frame address and PS; PS stays set on the children
    // only when they are themselves huge (a 1 GiB split yields 2 MiB pages).
    // Note the PAT bit moves between huge (bit 12) and 4 KiB (bit 7) entries;
    // nothing here sets it, so it is dropped rather than translated.
    const flags = old & ~ADDR_MASK & ~PAGE_HUGE;
    const child_stride: u64 = if (level == 1) 2 * 1024 * 1024 else 4096;
    const child_huge: u64 = if (level == 1) PAGE_HUGE else 0;

    const table_phys = pmm.alloc_page() orelse return error.OutOfMemory;
    const table = phys_to_table(table_phys);
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        table[i] = (base + @as(u64, i) * child_stride) | flags | child_huge;
    }
    // The parent must stay as permissive as the widest child; the leaf entries
    // carry the real permissions.
    entry.* = table_phys | PAGE_PRESENT | PAGE_WRITE | PAGE_USER;
}

/// What this space maps `virt` to, and with what rights — or null if it maps
/// nothing there.
///
/// The counterpart of `map_page`, and the thing that had been missing: until
/// now nothing could ask an address space what it held, only tell it what to
/// hold. Copying one — which is what `fork` is — needs the question as much
/// as the answer.
///
/// Huge pages are followed rather than refused, because the boot stub
/// identity-maps the first gigabyte with 2 MiB pages and a walk that stopped
/// there would report "nothing mapped" for memory that plainly is. The
/// address returned is the frame plus the offset within it, so the caller
/// gets the physical address of `virt` itself and not of the page it sits in.
pub const Mapping = struct {
    /// The physical address `virt` translates to, frame plus offset.
    phys: u64,
    /// The leaf entry's permission bits, with the frame address and the
    /// huge-page bit removed — so it can be handed straight to `map_page`
    /// for a 4 KiB mapping of the same memory with the same rights.
    flags: u64,
};

pub fn lookup(space: *const AddressSpace, virt: u64) ?Mapping {
    const indices = [_]u9{
        @intCast((virt >> 39) & 0x1FF),
        @intCast((virt >> 30) & 0x1FF),
        @intCast((virt >> 21) & 0x1FF),
        @intCast((virt >> 12) & 0x1FF),
    };
    // How much of the address a leaf at this level does not cover.
    const level_shift = [_]u6{ 39, 30, 21, 12 };

    var table_phys = space.pml4_phys;
    var level: usize = 0;
    while (level < 4) : (level += 1) {
        const table = phys_to_table(table_phys);
        const entry = table[indices[level]];
        if (entry & PAGE_PRESENT == 0) return null;
        const frame = entry & ADDR_MASK;
        const leaf = level == 3 or (level > 0 and (entry & PAGE_HUGE) != 0);
        if (leaf) {
            const size: u64 = @as(u64, 1) << level_shift[level];
            return .{
                .phys = frame + (virt & (size - 1)),
                // The rights, not the summary a region keeps. A region records
                // only whether the process may write there; the entry records
                // what the hardware will actually allow, which is what a copy
                // of this page has to be given.
                .flags = entry & ~ADDR_MASK & ~PAGE_HUGE,
            };
        }
        table_phys = frame;
    }
    return null;
}

/// Copy every page the source has in the user half into the destination,
/// each into a page of its own, with the permissions the source's own page
/// tables give it.
///
/// Driven by the page tables rather than by the region list, and that is the
/// point. Regions are bookkeeping kept for the page-fault and brk machinery,
/// and they are *incomplete*: `loader` records one per ELF segment and none
/// for the user stack, which it maps directly. A clone driven by regions
/// therefore copied a program's code and data and left it with no stack, and
/// the child faulted on its first push — `error_code=0x6` at an address one
/// word below its own %rsp, measured.
///
/// What a process has is what its tables say it has. Ask them.
///
/// Only the user half: PML4 entries 0-255 are the addresses below the
/// canonical hole, and everything above is the kernel, which every space
/// already shares.
pub fn clone_user_half(src: *const AddressSpace, dst: *AddressSpace) !void {
    var top: usize = 0;
    while (top < 256) : (top += 1) {
        const pml4 = phys_to_table(src.pml4_phys);
        if (pml4[top] & PAGE_PRESENT == 0) continue;
        try clone_level(pml4[top] & ADDR_MASK, 1, @as(u64, top) << 39, dst);
    }
}

/// One level of the walk. `base` is the virtual address the entries under
/// this table start at.
fn clone_level(table_phys: u64, level: usize, base: u64, dst: *AddressSpace) !void {
    const shift: u6 = switch (level) {
        1 => 30,
        2 => 21,
        else => 12,
    };
    const table = phys_to_table(table_phys);
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const entry = table[i];
        if (entry & PAGE_PRESENT == 0) continue;
        const va = base + (@as(u64, i) << shift);
        const frame = entry & ADDR_MASK;

        if (level == 3 or (entry & PAGE_HUGE) != 0) {
            // A leaf. A huge one covers many 4 KiB pages and is copied as
            // that many, because the child is built out of 4 KiB mappings and
            // nothing here needs the larger ones.
            const flags = entry & ~ADDR_MASK & ~PAGE_HUGE;
            const span: u64 = @as(u64, 1) << shift;
            var off: u64 = 0;
            while (off < span) : (off += 4096) {
                const page = pmm.alloc_page() orelse return error.OutOfMemory;
                copy_phys_page(page, frame + off);
                try map_page(dst, va + off, page, flags);
            }
            continue;
        }
        try clone_level(frame, level + 1, va, dst);
    }
}

/// Give back every page the user half of a space holds, and the space itself.
///
/// The counterpart of `clone_user_half`, and the thing `exec` never had. Its
/// comment said "Tear down the old address space; the new one replaces it"
/// over a line that only overwrote the pointer: every page of every image a
/// process replaced stayed allocated for the life of the machine.
///
/// The user half only. Entries 256 and up are the kernel's own tables, shared
/// into every space by `share_kernel_half` — copies of pointers, not copies
/// of tables — so walking them would free the kernel out from under itself.
/// The PML4 page goes at the end, which is this space's and nobody else's.
pub fn free_user_half(space: *AddressSpace) void {
    var top: usize = 0;
    while (top < 256) : (top += 1) {
        const pml4 = phys_to_table(space.pml4_phys);
        if (pml4[top] & PAGE_PRESENT == 0) continue;
        free_level(pml4[top] & ADDR_MASK, 1);
        pml4[top] = 0;
    }
    pmm.free_page(space.pml4_phys);
    space.pml4_phys = 0;
}

/// One level of the walk down, freeing leaves and then the table that held
/// them.
fn free_level(table_phys: u64, level: usize) void {
    const shift: u6 = switch (level) {
        1 => 30,
        2 => 21,
        else => 12,
    };
    const table = phys_to_table(table_phys);
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const entry = table[i];
        if (entry & PAGE_PRESENT == 0) continue;
        const frame = entry & ADDR_MASK;
        if (level == 3 or (entry & PAGE_HUGE) != 0) {
            // A leaf. A huge one covers many 4 KiB pages and the allocator
            // knows only 4 KiB pages, so it goes back as the pages it is
            // made of — the same arithmetic `clone_level` uses to copy one.
            const span: u64 = @as(u64, 1) << shift;
            var off: u64 = 0;
            while (off < span) : (off += 4096) pmm.free_page(frame + off);
            continue;
        }
        free_level(frame, level + 1);
    }
    pmm.free_page(table_phys);
}

fn copy_phys_page(dst_phys: u64, src_phys: u64) void {
    const HHDM: u64 = 0xFFFF_8000_0000_0000;
    const d: [*]u8 = @ptrFromInt(HHDM + dst_phys);
    const s: [*]const u8 = @ptrFromInt(HHDM + src_phys);
    @memcpy(d[0..4096], s[0..4096]);
}

pub fn unmap_page(space: *AddressSpace, virt: u64) void {
    const indices = [_]u9{
        @intCast((virt >> 39) & 0x1FF),
        @intCast((virt >> 30) & 0x1FF),
        @intCast((virt >> 21) & 0x1FF),
        @intCast((virt >> 12) & 0x1FF),
    };
    var table_phys = space.pml4_phys;
    var level: usize = 0;
    while (level < 3) : (level += 1) {
        const table = phys_to_table(table_phys);
        const entry = table[indices[level]];
        if (entry & PAGE_PRESENT == 0) return;
        table_phys = entry & ADDR_MASK;
    }
    const leaf = phys_to_table(table_phys);
    leaf[indices[3]] = 0;
    flush_tlb_entry(virt);
}

fn phys_to_table(phys: u64) *[512]u64 {
    // The boot stub identity-mapped physical memory at the high
    // half offset. Adjust when we move to a recursive map.
    const HHDM_BASE: u64 = 0xFFFF_8000_0000_0000;
    return @ptrFromInt(HHDM_BASE + phys);
}

fn zero_page(phys: u64) void {
    const ptr: [*]u8 = @ptrFromInt(0xFFFF_8000_0000_0000 + phys);
    @memset(ptr[0..pmm.PAGE_SIZE], 0);
}

fn flush_tlb_entry(virt: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : "memory"
    );
}

// ── Page-fault decision logic ─────────────────────

pub const PageFaultError = error{
    OutOfMemory,
    NotMapped,
    Protection,
    Unaligned,
};

pub const FaultCause = enum {
    not_present,
    write_to_readonly,
    user_access_to_kernel,
    reserved_bit_set,
    instruction_fetch,
};

pub fn classify_fault(error_code: u64) FaultCause {
    if ((error_code & 0x10) != 0) return .instruction_fetch;
    if ((error_code & 0x08) != 0) return .reserved_bit_set;
    if ((error_code & 0x04) != 0 and (error_code & 0x01) == 0) return .user_access_to_kernel;
    if ((error_code & 0x02) != 0 and (error_code & 0x01) != 0) return .write_to_readonly;
    return .not_present;
}

/// Walk the address space's region list; if `addr` falls inside a
/// known region, allocate a page (or COW a shared one) and map it.
/// Returns `error.NotMapped` for true segfaults.
pub fn handle_page_fault(space: *AddressSpace, faulting_addr: u64, error_code: u64) PageFaultError!void {
    const cause = classify_fault(error_code);
    const region = find_region(space, faulting_addr) orelse return error.NotMapped;
    if (cause == .write_to_readonly and (region.flags & PAGE_WRITE) == 0) {
        return error.Protection;
    }
    const phys = pmm.alloc_page() orelse return error.OutOfMemory;
    var flags: u64 = PAGE_PRESENT | PAGE_USER;
    if ((region.flags & PAGE_WRITE) != 0) flags |= PAGE_WRITE;
    const aligned = faulting_addr & ~@as(u64, pmm.PAGE_SIZE - 1);
    map_page(space, aligned, phys, flags) catch return error.OutOfMemory;
}

fn find_region(space: *AddressSpace, addr: u64) ?*const AddressSpace.Region {
    for (space.regions.items) |*r| {
        if (addr >= r.start and addr < r.end) return r;
    }
    return null;
}
