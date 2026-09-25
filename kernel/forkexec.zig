//! fork, then exec: can a process on x86_64 start another program without
//! ceasing to be itself?
//!
//! Nothing has ever tried. `/bin/clarity-forkprobe` forks and both halves
//! exit without exec'ing, so this is an open question rather than a fix for a
//! known fault — and it is written as a measurement for that reason.
//!
//! The AArch64 side needed real work for this (#199), because a process at
//! EL0 there is a nested call the kernel makes and `exec` leaves EL0
//! expecting its caller to load the image. This architecture is shaped
//! differently: a process *is* a scheduled thread, and `sched.exec` never
//! returns — it loads the image and enters ring 3 from the calling thread. So
//! it may already work here. Whatever this boot prints is the answer.
//!
//! What it will not let pass, either way:
//!
//!   - **a child that ends instead of being replaced.** The child's exit code
//!     has to be /bin/clarity-hello's 55, which nothing else on this boot
//!     uses.
//!
//!   - **a parent that does not survive.** The probe leaves a number in %r15
//!     across both the fork and the wait and requires it on the other side,
//!     and writes a last line only a live parent can write.
//!
//!   - **an exec that keeps the image it replaced.** `exec`'s own comment
//!     said "tear down the old address space" over a line that only
//!     overwrote the pointer, so every replaced image stayed allocated for
//!     the life of the machine. Nothing counted, so nothing said so. This
//!     counts.

const console = @import("arch/x86_64/console.zig");
const vfs = @import("fs/vfs.zig");
const sched = @import("sched/scheduler.zig");
const pmm = @import("mm/pmm.zig");

pub const PATH = "/bin/clarity-forkexec";
pub const HELLO_PATH = "/bin/clarity-hello";

const IMAGE: []const u8 = @embedFile("forkexec_elf");
const HELLO: []const u8 = @embedFile("hello_elf");

fn install(path: []const u8, bytes: []const u8) !void {
    const fd = try vfs.open(path, 0x40 | 0x1, 0o755); // O_CREAT | O_WRONLY
    const n = try vfs.write(@intCast(fd), bytes);
    try vfs.close(@intCast(fd));
    if (n != bytes.len) return error.ShortWrite;
}

pub fn run() void {
    // The child reaches /bin/clarity-hello the way any program reaches
    // another: through the filesystem, by path.
    install(HELLO_PATH, HELLO) catch |e| {
        console.print("  [FAIL] fork+exec: could not install /bin/clarity-hello: ");
        console.println(@errorName(e));
        return;
    };
    install(PATH, IMAGE) catch |e| {
        console.print("  [FAIL] fork+exec: could not install the probe: ");
        console.println(@errorName(e));
        return;
    };

    const free_before = pmm.stats().free_pages;

    const t = sched.spawn_user(PATH) catch |e| {
        console.print("  [FAIL] fork+exec: could not spawn the probe: ");
        console.println(@errorName(e));
        return;
    };

    sched.run_queued();

    const free_after = pmm.stats().free_pages;

    const code = sched.exit_code_of(t) orelse {
        console.println("  [FAIL] fork+exec: the parent never finished");
        return;
    };
    if (code != 50) {
        console.print("  [FAIL] fork+exec: the parent came back with ");
        console.print_dec(@intCast(@as(u32, @bitCast(code))));
        console.println(" — it wanted 50, and says above what it found");
        return;
    }
    console.print("  fork+exec: pages free ");
    console.print_dec(free_before);
    console.print(" before, ");
    console.print_dec(free_after);
    console.println(" after");

    // What one fork and one exec are allowed to cost.
    //
    // Measured, not guessed. Five numbers, from five builds of this kernel:
    //
    //    4  the two processes' pages and the two threads' kernel stacks all
    //       given back, which is this build
    //    8  the stacks kept -- one of them, on the build where the dead-stack
    //       list was a single slot
    //   12  both stacks kept
    //   48  the images kept too, before `exit` freed anything
    //   65  and `exec` also keeping the image it replaced
    //
    // The remaining 4 are the kernel-heap allocations behind a Thread, a
    // Process and an AddressSpace, whose pages the heap does not hand back --
    // and the Thread deliberately outlives its stack, because the list of
    // stacks still to be freed is threaded through it. A heap that shrinks is
    // somebody else's gap.
    //
    // The bound sits between 4 and 12 with room on each side, because a bound
    // that only just catches its own negative is a bound that will pass the
    // next one by accident.
    const LEAK_MAX: u64 = 8;
    if (free_before > free_after and free_before - free_after > LEAK_MAX) {
        console.print("  [FAIL] fork+exec: ");
        console.print_dec(free_before - free_after);
        console.print(" pages did not come back, more than the ");
        console.print_dec(LEAK_MAX);
        console.println(" the kernel heap accounts for");
        return;
    }

    console.println("  [ok] fork+exec: a process started another program and was still there afterwards");
}
