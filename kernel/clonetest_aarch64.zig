//! Copying an address space.
//!
//! The half of `fork` that can be asked about on its own: before a second
//! process can exist, a first one's memory has to be copyable — the same
//! bytes at the same addresses, allowed to do the same things, in pages of
//! its own.
//!
//! Every check here is one the x86_64 side got wrong and paid for, which is
//! why they are checks rather than assumptions:
//!
//!   - **the same bytes.** Obvious, and the only one that was never wrong.
//!
//!   - **the same permissions.** That clone built the child's mappings from a
//!     summary of the region rather than from the page tables, and the child
//!     got a code page it was not allowed to execute. So this compares the
//!     whole descriptor, not a re-derivation of it.
//!
//!   - **every page.** That clone walked a list of recorded regions, which did
//!     not include the stack, and the child ran with no stack at all. So this
//!     maps a page that no bookkeeping would know about and requires it to
//!     come across.
//!
//!   - **different pages.** Nothing had this wrong yet, and it is the one that
//!     would be silently fine for a long time: a "copy" that shared the
//!     original's frames passes every other check here and only shows up when
//!     one process writes and the other sees it. So the physical addresses are
//!     required to differ, and then the copy is written through and the
//!     original required not to move.
//!
//!   - **every page back.** A clone that leaked would be invisible until the
//!     machine ran out.

const console = @import("arch/aarch64/console.zig");
const sched = @import("sched/sched_aarch64.zig");
const paging = @import("arch/aarch64/paging.zig");
const pmm = @import("mm/pmm.zig");
const vm = @import("arch/aarch64/vm.zig");

/// Three pages, deliberately not adjacent: two in one 2 MiB block and one far
/// enough away to need a second level-2 table. A walker that only ever
/// descended one table would copy the first two and lose the third.
const A: u64 = 0x10_0000;
const B: u64 = 0x10_2000;
const C: u64 = 0x40_0000 + 0x3000;

fn write_pattern(phys: u64, seed: u8) void {
    const p = vm.ptr_to_phys(*[pmm.PAGE_SIZE]u8, phys);
    for (p, 0..) |*b, i| b.* = seed +% @as(u8, @truncate(i));
}

fn same_bytes(x: u64, y: u64) bool {
    const p = vm.ptr_to_phys(*const [pmm.PAGE_SIZE]u8, x);
    const q = vm.ptr_to_phys(*const [pmm.PAGE_SIZE]u8, y);
    for (p, q) |a, b| {
        if (a != b) return false;
    }
    return true;
}

pub fn run() void {
    if (pmm.stats().total_pages == 0) return;

    const free_before = pmm.stats().free_pages;

    const src_asid = sched.alloc_asid() orelse {
        console.println("  [FAIL] clone: no ASID left for the original");
        return;
    };
    var src = paging.create(src_asid) orelse {
        console.println("  [FAIL] clone: could not build a space to copy");
        sched.free_asid(src_asid);
        return;
    };

    // Three pages with three different sets of rights, so "the permissions
    // came across" is a statement about more than one bit.
    const pages = [_]struct { va: u64, flags: u32, seed: u8 }{
        .{ .va = A, .flags = paging.MAP_USER | paging.MAP_WRITE, .seed = 0x11 },
        .{ .va = B, .flags = paging.MAP_USER, .seed = 0x55 },
        .{ .va = C, .flags = paging.MAP_USER | paging.MAP_EXEC, .seed = 0x99 },
    };

    for (pages) |pg| {
        const phys = pmm.alloc_page() orelse {
            console.println("  [FAIL] clone: out of pages building the original");
            paging.destroy(&src);
            sched.free_asid(src_asid);
            return;
        };
        write_pattern(phys, pg.seed);
        paging.map_page(&src, pg.va, phys, pg.flags) catch {
            console.println("  [FAIL] clone: could not map the original");
            paging.destroy(&src);
            sched.free_asid(src_asid);
            return;
        };
    }

    const dst_asid = sched.alloc_asid() orelse {
        console.println("  [FAIL] clone: no ASID left for the copy");
        paging.destroy(&src);
        sched.free_asid(src_asid);
        return;
    };
    var dst = paging.create(dst_asid) orelse {
        console.println("  [FAIL] clone: could not build a space to copy into");
        paging.destroy(&src);
        sched.free_asid(dst_asid);
        sched.free_asid(src_asid);
        return;
    };

    paging.clone_user(&src, &dst) catch |e| {
        console.print("  [FAIL] clone: the copy failed: ");
        console.println(@errorName(e));
        paging.destroy(&dst);
        paging.destroy(&src);
        sched.free_asid(dst_asid);
        sched.free_asid(src_asid);
        return;
    };

    var ok = true;
    for (pages) |pg| {
        const s_entry = paging.lookup_entry(&src, pg.va) orelse {
            console.println("  [FAIL] clone: the original lost a page");
            ok = false;
            continue;
        };
        const d_entry = paging.lookup_entry(&dst, pg.va) orelse {
            console.print("  [FAIL] clone: nothing mapped at ");
            console.print_hex(pg.va);
            console.println(" in the copy");
            ok = false;
            continue;
        };

        // The rights, compared as the whole descriptor minus the address.
        if ((s_entry & ~paging.ADDR_MASK) != (d_entry & ~paging.ADDR_MASK)) {
            console.print("  [FAIL] clone: different rights at ");
            console.print_hex(pg.va);
            console.print(" — original ");
            console.print_hex(s_entry & ~paging.ADDR_MASK);
            console.print(", copy ");
            console.print_hex(d_entry & ~paging.ADDR_MASK);
            console.println("");
            ok = false;
        }

        const s_phys = s_entry & paging.ADDR_MASK;
        const d_phys = d_entry & paging.ADDR_MASK;
        if (s_phys == d_phys) {
            console.print("  [FAIL] clone: ");
            console.print_hex(pg.va);
            console.println(" is the same page in both — shared, not copied");
            ok = false;
            continue;
        }
        if (!same_bytes(s_phys, d_phys)) {
            console.print("  [FAIL] clone: the bytes at ");
            console.print_hex(pg.va);
            console.println(" did not come across");
            ok = false;
        }
    }

    // And that they are really separate: write through the copy and require
    // the original not to have moved. Two pages that hold the same bytes and
    // the same rights can still be one page.
    if (ok) {
        const s_phys = paging.lookup(&src, A).?;
        const d_phys = paging.lookup(&dst, A).?;
        write_pattern(d_phys, 0xEE);
        if (same_bytes(s_phys, d_phys)) {
            console.println("  [FAIL] clone: writing the copy changed the original");
            ok = false;
        }
    }

    // The leaves first, then the tables. `paging.destroy` frees the tables a
    // space is built from and nothing else — the pages a process's memory
    // actually lives in belong to whoever mapped them, which here is this
    // test and in a real process is the loader's `release`. Freeing only the
    // tables and then counting would report a leak that is this file's doing.
    for (pages) |pg| {
        if (paging.lookup(&src, pg.va)) |phys| pmm.free_page(phys);
        if (paging.lookup(&dst, pg.va)) |phys| pmm.free_page(phys);
    }
    paging.destroy(&dst);
    paging.destroy(&src);
    sched.free_asid(dst_asid);
    sched.free_asid(src_asid);

    const free_after = pmm.stats().free_pages;
    if (free_after != free_before) {
        console.print("  [FAIL] clone: pages leaked — ");
        console.print_dec(free_before);
        console.print(" free before, ");
        console.print_dec(free_after);
        console.println(" after");
        ok = false;
    }

    if (ok) {
        console.println("  [ok] clone: three pages copied with their rights, into pages of their own, and every page came back");
    }
}
