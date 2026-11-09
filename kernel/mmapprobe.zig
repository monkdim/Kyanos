//! Does `mmap` check the address userspace hands it?
//!
//! This kernel has one system call that takes an address from a user process
//! and installs a page-table entry for it: `mmap` with the framebuffer's fd.
//! Every other user address arrives as a pointer to *read through*, and
//! `uaccess` refuses those at or above `USER_TOP` before anything is read.
//! An address to *map* goes somewhere else entirely -- straight into
//! `vmm.map_page`, which walks the tables and writes a leaf.
//!
//! Why that matters here rather than in general: `vmm.share_kernel_half`
//! copies PML4 entries 256..511 out of the kernel's own table into every new
//! process, by value. The tables underneath those entries are therefore the
//! same tables, shared by the kernel and by every process at once. A leaf
//! written at a kernel-half address is written into the kernel's page tables,
//! and `map_page` widens U/S on every level of the path it walks so the leaf
//! is reachable from ring 3. One unprivileged process mapping there changes
//! what the kernel's own addresses mean, for everyone.
//!
//! So the probe runs in ring 3 and asks for ten things, and this gate reads
//! the answers out of its exit status, one bit each. Running it in ring 3 is
//! the point: calling `framebuffer.map_into_user` from here would exercise
//! the mapping loop without going near the dispatcher, where the checking
//! has to happen.
//!
//! And the return codes are not the only thing checked, because a return code
//! is the kernel's opinion of what it did. Two things are measured instead.
//!
//! The kernel's own PML4 entries 256..511, copied before the probe runs and
//! compared afterwards: those 256 entries are the whole of the kernel's half,
//! they are what every process shares, and nothing a user process asks for
//! may change one of them. That check does not care how the refusal was
//! worded, or whether it was worded at all.
//!
//! And the physical allocator's free count, for the other end of the same
//! mapping. A process that maps the framebuffer and exits used to have its
//! address space torn down by a walk that treats every present user leaf as a
//! page from `pmm` -- so the framebuffer's frames, which were never the
//! allocator's, went into the free list, and the next allocation got memory
//! -mapped I/O. The count going *up* across a process that mapped a device
//! and exited is that bug, and nothing else looks like it.
//!
//! The probe also asks for the geometry over `ioctl`, which is the way a
//! program is supposed to learn how big the framebuffer is before mapping
//! it. That makes this the first gate to call `ioctl` as well, so both
//! numbers come off the reachability probe's unexercised list -- on the
//! strength of this gate calling them, which the boot shows.

const std = @import("std");
const console = @import("arch/x86_64/console.zig");
const vfs = @import("fs/vfs.zig");
const sched = @import("sched/scheduler.zig");
const fb = @import("drivers/framebuffer.zig");
const vmm = @import("mm/vmm.zig");
const pmm = @import("mm/pmm.zig");

pub const PATH = "/bin/clarity-mmapprobe";

const IMAGE: []const u8 = @embedFile("mmapprobe_elf");

/// One per question the probe asks, in the order it asks them.
const Question = struct { bit: u4, what: []const u8 };

const QUESTIONS = [_]Question{
    .{ .bit = 0, .what = "a mapping at the first non-user address is refused" },
    .{ .bit = 1, .what = "a mapping at the kernel half is refused" },
    .{ .bit = 2, .what = "an unaligned address is refused" },
    .{ .bit = 3, .what = "an address whose end wraps past zero is refused" },
    .{ .bit = 4, .what = "an mmap fd too wide for i32 is refused, and the machine survives it" },
    .{ .bit = 5, .what = "an fd that is not the framebuffer's is refused" },
    .{ .bit = 6, .what = "an ioctl fd too wide for i32 is refused, and the machine survives it" },
    .{ .bit = 7, .what = "the highest placement below the stack is granted" },
    .{ .bit = 8, .what = "one page higher, overlapping the stack, is refused" },
    .{ .bit = 9, .what = "a valid request at a valid address is granted" },
    .{ .bit = 10, .what = "what the granted mapping reads back is what was written to it" },
    .{ .bit = 11, .what = "a second mapping over the same range is refused" },
    .{ .bit = 12, .what = "a mapping inside the live heap is refused" },
    .{ .bit = 13, .what = "the heap is refused when it would grow over a mapping" },
    .{ .bit = 14, .what = "a fork with the framebuffer mapped produced a child that was reaped" },
    .{ .bit = 15, .what = "two pages below the top, inside the stack's last page, is refused" },
};

const ALL: i32 = 0xFFFF;

/// The kernel's half: PML4 entries 256..511, the ones `share_kernel_half`
/// copies into every process.
const KERNEL_FIRST: usize = 256;
const HHDM_BASE: u64 = 0xFFFF_8000_0000_0000;

fn kernel_pml4() *const [512]u64 {
    return @ptrFromInt(HHDM_BASE + (vmm.kernel().pml4_phys & vmm.ADDR_MASK));
}

fn table_at(phys: u64) *const [512]u64 {
    return @ptrFromInt(HHDM_BASE + (phys & vmm.ADDR_MASK));
}

/// A number that changes if anything in the kernel's half of the page tables
/// changes -- at any level, not just the root.
///
/// Comparing the 256 root entries was not enough, and saying it proved the
/// kernel's half untouched was a stronger claim than the measurement
/// supported. `map_page` widens U/S on every level of the path it walks, and
/// the levels it would widen are the PDPT and PD *under* those entries: the
/// root entry itself keeps its value, so a comparison of root entries alone
/// reads clean while the tables beneath it have been opened to ring 3.
///
/// So this walks the upper half to its leaves and folds every entry in. The
/// width is bounded by what the kernel actually maps, not by the address
/// space: the HHDM and the kernel image, a few gigabytes of 2 MiB pages, so
/// the walk stops at huge entries and does not descend 512 ways at every
/// level.
fn kernel_half_fingerprint() u64 {
    var acc: u64 = 0xcbf2_9ce4_8422_2325;
    const pml4 = kernel_pml4();
    var i: usize = KERNEL_FIRST;
    while (i < 512) : (i += 1) {
        acc = mix(acc, pml4[i]);
        if (pml4[i] & vmm.PAGE_PRESENT == 0) continue;
        fold_level(&acc, pml4[i] & vmm.ADDR_MASK, 1);
    }
    return acc;
}

fn fold_level(acc: *u64, table_phys: u64, level: usize) void {
    const table = table_at(table_phys);
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const e = table[i];
        acc.* = mix(acc.*, e);
        if (e & vmm.PAGE_PRESENT == 0) continue;
        if (level >= 3 or (e & vmm.PAGE_HUGE) != 0) continue;
        fold_level(acc, e & vmm.ADDR_MASK, level + 1);
    }
}

fn mix(acc: u64, v: u64) u64 {
    return (acc ^ v) *% 0x0000_0100_0000_01B3;
}

fn install() !void {
    const fd = try vfs.open(PATH, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), IMAGE);
    try vfs.close(@intCast(fd));
    if (n != IMAGE.len) return error.ShortWrite;
}

pub fn run() void {
    // Said before the probe runs, because a boot with no framebuffer tag
    // would fail every question for a reason that is not about checking.
    if (fb.info) |i| {
        console.print("  mmap: the framebuffer is at phys ");
        console.print_hex(i.phys_addr);
        console.print(", ");
        console.print_dec(@as(u64, i.pitch) * i.height);
        console.println(" bytes");
    } else {
        console.println("  [FAIL] mmap: this boot has no framebuffer, so there is nothing to map");
        return;
    }

    install() catch |e| {
        console.print("  [FAIL] mmap: could not install the probe: ");
        console.println(@errorName(e));
        return;
    };

    const fingerprint_before = kernel_half_fingerprint();
    const free_before = pmm.stats().free_pages;
    const fb_size = fb.mapped_size() orelse 0;
    const fb_base = if (fb.info) |i| i.phys_addr else 0;

    const started = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] mmap: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };
    const tid = started.tid;
    sched.run_queued();

    // The kernel's half, before anything is said about return codes. Any
    // entry that changed, at any level, changed for the kernel and for every
    // process.
    var moved: u32 = 0;
    if (kernel_half_fingerprint() != fingerprint_before) {
        moved = 1;
        console.println("  [FAIL] mmap: a user process changed the kernel's half of the page tables");
    }

    // The probe has exited, so its user half has been torn down.
    //
    // Both directions are checked, and they are different bugs. The count
    // going *up* means frames that were never the allocator's were added to
    // it -- memory-mapped I/O in the free list. Going *down* means frames
    // that were the allocator's were not given back. The first version of
    // this gate tested only the first direction, and so printed a reassuring
    // line while a fork with the framebuffer mapped lost two pages.
    const free_after = pmm.stats().free_pages;
    var leaked_frames = false;
    if (free_after != free_before) {
        leaked_frames = true;
        console.print("  [FAIL] mmap: the allocator went from ");
        console.print_dec(free_before);
        console.print(" free pages to ");
        console.print_dec(free_after);
        if (free_after > free_before) {
            console.println(" — frames that were never the allocator's were added to it");
        } else {
            console.println(" — frames that were the allocator's were not given back");
        }
    } else {
        console.print("  mmap: the allocator is back to ");
        console.print_dec(free_after);
        console.println(" free pages");
    }

    // And the question a count cannot answer: are the framebuffer's own
    // frames still outside the allocator?
    //
    // A net figure that comes out even does not say the right pages came
    // back: a device frame added and a RAM page lost cancel exactly. This
    // asks about the frames themselves.
    if (fb_size != 0) {
        var off: u64 = 0;
        var handed_out: u64 = 0;
        while (off < fb_size) : (off += 0x1000) {
            if (pmm.is_free(fb_base + off)) handed_out += 1;
        }
        if (handed_out != 0) {
            leaked_frames = true;
            console.print("  [FAIL] mmap: ");
            console.print_dec(handed_out);
            console.println(" of the framebuffer's own frames are now in the allocator's free pool");
        } else {
            console.print("  mmap: all ");
            console.print_dec(fb_size / 0x1000);
            console.println(" of the framebuffer's frames are still outside the allocator");
        }
    }

    const code = sched.exit_code_of(tid);
    if (code == null) {
        console.println("  [FAIL] mmap: the probe never exited, so no question was answered");
        return;
    }

    const answers = code.?;
    var failed: u32 = 0;
    for (QUESTIONS) |q| {
        const one = @as(i32, 1) << q.bit;
        if (answers & one == 0) {
            failed += 1;
            console.print("  [FAIL] mmap: ");
            console.println(q.what);
        }
    }

    if (failed == 0 and answers == ALL and moved == 0 and !leaked_frames) {
        console.println("  [ok] mmap: sixteen requests answered as they should be, the framebuffer's frames are still the framebuffer's, and the kernel's half is unchanged at every level");
    } else if (failed == 0 and moved == 0 and !leaked_frames) {
        // Bits outside the eight. Either the probe changed and this list did
        // not, or something returned a status nothing here wrote.
        console.print("  [FAIL] mmap: the probe answered ");
        console.print_hex(@as(u32, @bitCast(answers)));
        console.println(", which has bits no question in this gate owns");
    }
}
