//! Per-process address spaces on AArch64.
//!
//! The kernel lives in TTBR1_EL1 and stays there across every switch; this
//! file builds what goes in TTBR0_EL1, which is the half the hardware
//! swaps per process. That split is the whole reason the kernel moved to the
//! high half — a kernel still using TTBR0 for itself has nowhere to put a
//! process.
//!
//! Three levels, because the VA space is 39 bits with a 4 KiB granule:
//!
//!   level 1   bits [38:30]   512 entries of 1 GiB
//!   level 2   bits [29:21]   512 entries of 2 MiB
//!   level 3   bits [20:12]   512 entries of 4 KiB   <- the pages
//!
//! Each table is one page from the physical allocator, reached through the
//! kernel's direct map. Only 4 KiB pages are produced; blocks at level 1 and
//! 2 are what the boot stub uses for the kernel's own map, and mixing the two
//! here would mean splitting blocks on demand for no benefit yet.
//!
//! The kernel never writes to user memory *through* the user mapping. It
//! writes through the direct map, at the physical address it just mapped.
//! That is not a style preference: PSTATE.PAN makes an EL1 access to an
//! EL0-accessible address fault on any core that implements it, so a kernel
//! that filled a process's pages through the process's own addresses would
//! work on some machines and fault on others. The x86_64 side does the same
//! thing through its HHDM.

const pmm = @import("../../mm/pmm.zig");
const vm = @import("vm.zig");

/// Bits [47:12] of a descriptor: the physical address of the next table or
/// of the page itself.
pub const ADDR_MASK: u64 = 0x0000_FFFF_FFFF_F000;

// Descriptor type. At levels 1 and 2, 0b11 means "a table follows" and 0b01
// means "a block of memory"; at level 3, 0b11 means "a page". Getting 0b01
// at level 3 is not a block — it is invalid, and reads as a translation
// fault.
const DESC_VALID: u64 = 1 << 0;
const DESC_TABLE_OR_PAGE: u64 = 1 << 1;

// Lower attributes.
const ATTR_NORMAL: u64 = 1 << 2; // MAIR slot 1, matching the boot stub's
const AP_RW_EL1: u64 = 0b00 << 6;
const AP_RW_ALL: u64 = 0b01 << 6; // readable and writable at EL0 too
const AP_RO_EL1: u64 = 0b10 << 6;
const AP_RO_ALL: u64 = 0b11 << 6;
const SH_INNER: u64 = 0b11 << 8;
const AF: u64 = 1 << 10; // access flag; without it every access faults
const NG: u64 = 1 << 11; // not global: tagged with the ASID, so a switch
//                          does not have to flush the whole TLB

// Upper attributes.
const PXN: u64 = 1 << 53; // privileged execute never
const UXN: u64 = 1 << 54; // unprivileged execute never

/// What a mapping is for. Kept as flags rather than an enum because the
/// combinations are the point: user + write + no-exec is a data page, user +
/// exec + no-write is a text page, and the two must be describable
/// separately.
pub const MAP_USER: u32 = 1 << 0;
pub const MAP_WRITE: u32 = 1 << 1;
pub const MAP_EXEC: u32 = 1 << 2;

pub const Error = error{
    /// The physical allocator had no page for an intermediate table.
    OutOfMemory,
    /// The address is not inside the 512 GiB TTBR0 covers, or is not page
    /// aligned. Refused rather than truncated: a silently masked address is
    /// a mapping at somewhere other than where the caller asked.
    BadAddress,
    /// Something is already mapped there. Overwriting would leak whatever
    /// the old entry pointed at.
    AlreadyMapped,
};

/// One process's low half.
///
/// `asid` tags this space's TLB entries so switching away and back does not
/// require flushing every translation the CPU has cached. Zero is reserved
/// for "no space"; the kernel's own mappings are global (nG clear) and are
/// not tagged at all, which is why they survive the switch.
///
/// Nothing allocates ASIDs yet — the caller picks one, and two live spaces
/// sharing a number would each see the other's cached translations. With
/// TCR_EL1.AS clear there are 256 of them, which is fewer than the number of
/// processes a real system has, so this becomes a recycling problem (bump the
/// generation, invalidate by ASID, hand it out again) rather than a counter.
/// That belongs with the process table, which does not exist on this
/// architecture yet.
pub const AddressSpace = struct {
    root_phys: u64,
    asid: u16,
};

/// The first address TTBR0 does *not* cover, with T0SZ = 25.
pub const USER_VA_END: u64 = 1 << 39;

fn table(phys: u64) *[512]u64 {
    return vm.ptr_to_phys(*[512]u64, phys);
}

fn zero_table(phys: u64) void {
    const t = table(phys);
    for (t) |*e| e.* = 0;
}

fn page_descriptor(phys: u64, flags: u32) u64 {
    var d: u64 = (phys & ADDR_MASK) | AF | SH_INNER | ATTR_NORMAL |
        DESC_VALID | DESC_TABLE_OR_PAGE;

    const writable = (flags & MAP_WRITE) != 0;
    const executable = (flags & MAP_EXEC) != 0;

    if ((flags & MAP_USER) != 0) {
        d |= if (writable) AP_RW_ALL else AP_RO_ALL;
        d |= NG;
        // EL1 must never execute a user page, whatever the process asked
        // for: that is the privilege escalation the bit exists to prevent.
        d |= PXN;
        if (!executable) d |= UXN;
    } else {
        d |= if (writable) AP_RW_EL1 else AP_RO_EL1;
        d |= UXN;
        if (!executable) d |= PXN;
    }
    return d;
}

/// A fresh, entirely empty low half.
///
/// Empty is correct here and would be fatal on x86: an x86 process's page
/// tables have to carry the kernel's upper half or the instruction after the
/// CR3 load is unmapped. On AArch64 the kernel is in a different register
/// and is simply not this table's business.
pub fn create(asid: u16) ?AddressSpace {
    const root = pmm.alloc_page() orelse return null;
    zero_table(root);
    return AddressSpace{ .root_phys = root, .asid = asid };
}

/// Free every table this space owns.
///
/// The *mapped* pages are not freed: this space did not allocate them and
/// does not know whether anything else has them mapped too. Ownership of the
/// backing memory belongs to whoever called `map_page`.
pub fn destroy(space: *AddressSpace) void {
    const l1 = table(space.root_phys);
    for (l1) |e1| {
        if (!is_table(e1)) continue;
        const l2_phys = e1 & ADDR_MASK;
        const l2 = table(l2_phys);
        for (l2) |e2| {
            if (!is_table(e2)) continue;
            pmm.free_page(e2 & ADDR_MASK);
        }
        pmm.free_page(l2_phys);
    }
    pmm.free_page(space.root_phys);
    space.root_phys = 0;
}

fn is_table(entry: u64) bool {
    return (entry & (DESC_VALID | DESC_TABLE_OR_PAGE)) == (DESC_VALID | DESC_TABLE_OR_PAGE);
}

fn indices(virt: u64) [3]usize {
    return .{
        @intCast((virt >> 30) & 0x1FF),
        @intCast((virt >> 21) & 0x1FF),
        @intCast((virt >> 12) & 0x1FF),
    };
}

/// Map one 4 KiB page, allocating the intermediate tables it needs.
pub fn map_page(space: *AddressSpace, virt: u64, phys: u64, flags: u32) Error!void {
    if (virt >= USER_VA_END or virt % pmm.PAGE_SIZE != 0) return Error.BadAddress;
    if (phys % pmm.PAGE_SIZE != 0) return Error.BadAddress;

    const idx = indices(virt);
    var current = space.root_phys;
    var level: usize = 0;
    while (level < 2) : (level += 1) {
        const t = table(current);
        const entry = &t[idx[level]];
        if (entry.* == 0) {
            const next = pmm.alloc_page() orelse return Error.OutOfMemory;
            zero_table(next);
            entry.* = (next & ADDR_MASK) | DESC_VALID | DESC_TABLE_OR_PAGE;
        } else if (!is_table(entry.*)) {
            // A block descriptor, which nothing here produces — so this is a
            // table that has been corrupted rather than a case to handle.
            return Error.AlreadyMapped;
        }
        current = entry.* & ADDR_MASK;
    }

    const leaf = &table(current)[idx[2]];
    if (leaf.* != 0) return Error.AlreadyMapped;
    leaf.* = page_descriptor(phys, flags);

    // The table stores are ordinary cacheable writes through the same
    // attributes the walker uses, so publishing them is a barrier rather
    // than cache maintenance. A new mapping needs no TLB invalidate on a
    // previously-invalid entry in principle, but the architecture permits
    // caching of faulting translations, so it is not optional.
    invalidate(space, virt);
}

/// Copy every page one space has into another, each into a page of its own,
/// with exactly the attributes the source gave it.
///
/// Driven by the tables rather than by any record of what was mapped, which
/// is the lesson the x86_64 side paid for twice: a list of regions is
/// bookkeeping kept for something else, and it is incomplete — the user stack
/// is mapped there with no region to its name, so a clone driven by that list
/// handed a child its code and no stack. What a process has is what its
/// tables say it has.
///
/// The destination leaf is the source leaf with the frame address swapped.
/// Not flags re-derived from somewhere: every attribute bit — the access
/// permissions, the execute-never bits, the shareability, the memory type,
/// the not-global bit — comes across unchanged, because the copy is supposed
/// to be the same memory and the only thing about it that differs is where it
/// physically lives.
///
/// The destination must be empty. Nothing here merges into an existing space.
pub fn clone_user(src: *const AddressSpace, dst: *AddressSpace) Error!void {
    const l1 = table(src.root_phys);
    // `top`, `mid`, `low` rather than i1/i2/i3: those are Zig's one-, two-
    // and three-bit integer types, and a loop index may not shadow a type.
    for (l1, 0..) |e1, top| {
        if (!is_table(e1)) continue;
        const l2 = table(e1 & ADDR_MASK);
        for (l2, 0..) |e2, mid| {
            if (!is_table(e2)) continue;
            const l3 = table(e2 & ADDR_MASK);
            for (l3, 0..) |leaf, low| {
                if (leaf == 0) continue;
                const virt = (@as(u64, top) << 30) | (@as(u64, mid) << 21) | (@as(u64, low) << 12);
                const copy = pmm.alloc_page() orelse return Error.OutOfMemory;
                copy_page(copy, leaf & ADDR_MASK);
                try put_leaf(dst, virt, (copy & ADDR_MASK) | (leaf & ~ADDR_MASK));
            }
        }
    }
}

/// Write one leaf descriptor into a space, allocating the tables on the way
/// down. Like `map_page` except that the descriptor is given rather than
/// built, which is what lets `clone_user` carry the source's attributes
/// across untouched.
fn put_leaf(space: *AddressSpace, virt: u64, descriptor: u64) Error!void {
    if (virt >= USER_VA_END) return Error.BadAddress;
    const idx = indices(virt);
    var current = space.root_phys;
    var level: usize = 0;
    while (level < 2) : (level += 1) {
        const t = table(current);
        const entry = &t[idx[level]];
        if (entry.* == 0) {
            const next = pmm.alloc_page() orelse return Error.OutOfMemory;
            zero_table(next);
            entry.* = (next & ADDR_MASK) | DESC_VALID | DESC_TABLE_OR_PAGE;
        } else if (!is_table(entry.*)) {
            return Error.AlreadyMapped;
        }
        current = entry.* & ADDR_MASK;
    }
    const leaf = &table(current)[idx[2]];
    if (leaf.* != 0) return Error.AlreadyMapped;
    leaf.* = descriptor;
    invalidate(space, virt);
}

/// Copy 4 KiB from one physical page to another through the direct map.
///
/// Through the direct map and not through either process's own addresses:
/// PSTATE.PAN makes an EL1 access to an EL0-accessible address fault on any
/// core that implements it, so a kernel that copied a page through the
/// mapping it belongs to would work on some machines and fault on others.
fn copy_page(dst_phys: u64, src_phys: u64) void {
    const d = vm.ptr_to_phys(*[pmm.PAGE_SIZE]u8, dst_phys);
    const s = vm.ptr_to_phys(*const [pmm.PAGE_SIZE]u8, src_phys);
    @memcpy(d, s);
}

/// The raw leaf descriptor at `virt`, or null if nothing is mapped there.
///
/// `lookup` answers where a page lives; this answers what it is allowed to
/// do, which is the half a copy needs and nothing could ask for before.
pub fn lookup_entry(space: *const AddressSpace, virt: u64) ?u64 {
    if (virt >= USER_VA_END) return null;
    const idx = indices(virt);
    var current = space.root_phys;
    var level: usize = 0;
    while (level < 2) : (level += 1) {
        const entry = table(current)[idx[level]];
        if (!is_table(entry)) return null;
        current = entry & ADDR_MASK;
    }
    const leaf = table(current)[idx[2]];
    if (leaf == 0) return null;
    return leaf;
}

/// Remove a mapping. Silent about an address that was never mapped: the
/// caller unmapping a range does not have to know which pages in it existed.
pub fn unmap_page(space: *AddressSpace, virt: u64) void {
    if (virt >= USER_VA_END) return;
    const idx = indices(virt);
    var current = space.root_phys;
    var level: usize = 0;
    while (level < 2) : (level += 1) {
        const entry = table(current)[idx[level]];
        if (!is_table(entry)) return;
        current = entry & ADDR_MASK;
    }
    const leaf = &table(current)[idx[2]];
    if (leaf.* == 0) return;
    leaf.* = 0;
    invalidate(space, virt);
}

/// What is mapped at `virt` in this space, read out of the tables rather
/// than out of the MMU. Distinct from mmu.translate, which asks the hardware
/// about the *current* address space — this one answers for a space that is
/// not installed, which is how a process's memory can be inspected without
/// switching to it.
pub fn lookup(space: *const AddressSpace, virt: u64) ?u64 {
    if (virt >= USER_VA_END) return null;
    const idx = indices(virt);
    var current = space.root_phys;
    var level: usize = 0;
    while (level < 2) : (level += 1) {
        const entry = table(current)[idx[level]];
        if (!is_table(entry)) return null;
        current = entry & ADDR_MASK;
    }
    const leaf = table(current)[idx[2]];
    if ((leaf & DESC_VALID) == 0) return null;
    return (leaf & ADDR_MASK) | (virt & (pmm.PAGE_SIZE - 1));
}

/// Drop the cached translations for one page of one space.
///
/// `tlbi vae1is` takes the ASID in bits [63:48] and the page number in
/// [43:0], and reaches every core in the inner-shareable domain. Only this
/// space's entries go: the kernel's are global and are not tagged with an
/// ASID at all, so they are untouched.
fn invalidate(space: *const AddressSpace, virt: u64) void {
    const operand = (@as(u64, space.asid) << 48) | (virt >> 12);
    asm volatile (
        \\dsb ishst
        \\tlbi vae1is, %[op]
        \\dsb ish
        \\isb
        :
        : [op] "r" (operand),
        : "memory"
    );
}

/// This space as a TTBR0_EL1 value: the root table's physical address with
/// the ASID in the top sixteen bits.
///
/// `activate` installs it now; this is for putting it somewhere that installs
/// it later — a thread's Context, so that a thread resumed after a preemption
/// comes back to its own address space rather than to whichever one happened
/// to be in the register.
///
/// It does not touch TCR_EL1.EPD0, and `clarity_switch_to` does not either.
/// Walking the low half has to have been enabled by an `activate` somewhere
/// before a context switch can mean anything, and it has to stay enabled
/// while any process is still runnable: a `deactivate` while another process
/// is only preempted, not finished, takes that process's translations away
/// and the next thing it touches faults.
pub fn ttbr_value(space: *const AddressSpace) u64 {
    return (@as(u64, space.asid) << 48) | (space.root_phys & ADDR_MASK);
}

/// Install this space as the low half and start translating it.
///
/// Two writes, in this order and not the other: TTBR0 first, then clearing
/// TCR_EL1.EPD0. Enabling walks before the register they walk from would
/// point the hardware at whatever TTBR0 happened to hold.
pub fn activate(space: *const AddressSpace) void {
    const ttbr = ttbr_value(space);
    asm volatile (
        \\msr ttbr0_el1, %[ttbr]
        \\isb
        \\mrs x0, tcr_el1
        \\bic x0, x0, #(1 << 7)
        \\msr tcr_el1, x0
        \\isb
        :
        : [ttbr] "r" (ttbr),
        : "x0", "memory"
    );
}

/// Stop translating the low half entirely.
///
/// What the kernel runs with when no process is current. It is the same
/// state mmu.drop_identity leaves behind at boot, and it means a stray
/// dereference of a low address inside the kernel faults instead of landing
/// in whichever process ran last.
pub fn deactivate() void {
    asm volatile (
        \\mrs x0, tcr_el1
        \\orr x0, x0, #(1 << 7)
        \\msr tcr_el1, x0
        \\msr ttbr0_el1, xzr
        \\isb
        \\tlbi vmalle1is
        \\dsb ish
        \\isb
        ::: "x0", "memory");
}
