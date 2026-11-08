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
    .{ .bit = 4, .what = "an fd too wide for i32 is refused, and the machine survives it" },
    .{ .bit = 5, .what = "an fd that is not the framebuffer's is refused" },
    .{ .bit = 6, .what = "the last placement that fits under the top is granted" },
    .{ .bit = 7, .what = "a valid request at a valid address is granted" },
    .{ .bit = 8, .what = "what the granted mapping reads back is what was written to it" },
    .{ .bit = 9, .what = "a second mapping over the same range is refused" },
};

const ALL: i32 = 0x3FF;

/// The kernel's half: PML4 entries 256..511, the ones `share_kernel_half`
/// copies into every process.
const KERNEL_FIRST: usize = 256;
const HHDM_BASE: u64 = 0xFFFF_8000_0000_0000;

fn kernel_pml4() *const [512]u64 {
    return @ptrFromInt(HHDM_BASE + (vmm.kernel().pml4_phys & vmm.ADDR_MASK));
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

    var before: [512 - KERNEL_FIRST]u64 = undefined;
    for (kernel_pml4()[KERNEL_FIRST..], 0..) |e, i| before[i] = e;
    const free_before = pmm.stats().free_pages;

    const started = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] mmap: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };
    const tid = started.tid;
    sched.run_queued();

    // The kernel's half, before anything is said about return codes. An
    // entry that changed here changed for the kernel and for every process.
    var moved: u32 = 0;
    for (kernel_pml4()[KERNEL_FIRST..], 0..) |now, i| {
        if (now != before[i]) {
            moved += 1;
            if (moved <= 4) {
                console.print("  [FAIL] mmap: a user process changed the kernel's PML4[");
                console.print_dec(@intCast(KERNEL_FIRST + i));
                console.print("] from ");
                console.print_hex(before[i]);
                console.print(" to ");
                console.print_hex(now);
                console.println("");
            }
        }
    }
    if (moved != 0) {
        console.print("  [FAIL] mmap: ");
        console.print_dec(moved);
        console.println(" of the kernel's 256 upper-half page-table entries were changed from ring 3");
    }

    // The probe has exited, so its user half has been torn down.
    const free_after = pmm.stats().free_pages;
    var leaked_frames = false;
    if (free_after > free_before) {
        leaked_frames = true;
        console.print("  [FAIL] mmap: the allocator gained ");
        console.print_dec(free_after - free_before);
        console.println(" pages across a process that mapped the framebuffer — device frames were freed as RAM");
    } else {
        console.print("  mmap: the allocator went from ");
        console.print_dec(free_before);
        console.print(" free pages to ");
        console.print_dec(free_after);
        console.println(", so no device frame was handed back as RAM");
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
        console.println("  [ok] mmap: ten requests, the six that should have been refused were, the four that should not have been were granted, and the kernel's half is untouched");
    } else if (failed == 0 and moved == 0 and !leaked_frames) {
        // Bits outside the eight. Either the probe changed and this list did
        // not, or something returned a status nothing here wrote.
        console.print("  [FAIL] mmap: the probe answered ");
        console.print_hex(@as(u32, @bitCast(answers)));
        console.println(", which has bits no question in this gate owns");
    }
}
