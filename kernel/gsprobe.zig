//! The %gs boundary check: did every entry from ring 3 find the kernel's
//! per-CPU block?
//!
//! Nothing here runs a test of its own. The counting happens on the paths
//! themselves -- `arch/x86_64/idt.zig`'s `check_gs` on every trap and
//! `dispatch_syscall_c` on every system call -- across the whole boot, and
//! this reads the two numbers at the end of it.
//!
//! That is the only shape this gate can have. A self-contained test cannot
//! enter the kernel from ring 3 on purpose without being the very thing it is
//! testing; what it can do is watch the boot's own crossings, of which there
//! are thousands: every timer tick that lands in a program, every write, every
//! read, every exit.
//!
//! **A count of zero is a failure.** "%gs was never wrong" is also what a boot
//! that never left ring 0 would report, and it would have proved nothing.

const console = @import("arch/x86_64/console.zig");
const arch_syscall = @import("arch/x86_64/syscall.zig");

pub fn run() void {
    const crossings = arch_syscall.entries_from_ring3;
    const total = arch_syscall.entries_total;
    const wrong = arch_syscall.gs_wrong;

    if (crossings == 0) {
        console.println("  [FAIL] swapgs: nothing ever entered the kernel from ring 3, so nothing was checked");
        return;
    }
    if (wrong != 0) {
        // Two denominators, because `wrong` is counted on every entry and
        // not only the ones from ring 3: a kernel that has the two bases the
        // wrong way round is wrong on the ring 0 ones instead, and saying
        // "339 of 76" would be arithmetic that cannot be true.
        console.print("  [FAIL] swapgs: %gs did not hold the per-CPU block on ");
        console.print_dec(wrong);
        console.print(" of ");
        console.print_dec(total);
        console.print(" entries into the kernel (");
        console.print_dec(crossings);
        console.println(" of them from ring 3)");
        return;
    }
    console.print("  [ok] swapgs: ");
    console.print_dec(total);
    console.print(" entries into the kernel, ");
    console.print_dec(crossings);
    console.println(" of them from ring 3, and %gs held the kernel's block on every one");
}
