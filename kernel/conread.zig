//! The clock the console-read path stands on.
//!
//! The clock, reported as soon as it has been measured, because everything
//! that reads the console depends on it. What a program then read is
//! readprobe.zig's line to write.

const console = @import("arch/x86_64/console.zig");
const timer = @import("arch/x86_64/timer.zig");

/// The TSC measurement, and the property that made it necessary.
///
/// The check is not that the number looks plausible -- it is that the clock
/// *moves while interrupts are masked*, which is the whole reason it is the
/// TSC and not `timer.ticks`. So it is read twice across a spin with IF
/// clear, and the difference has to be non-zero.
pub fn report_clock() void {
    if (!timer.calibrated()) {
        console.println("  [FAIL] console clock: the TSC was never measured against the PIT");
        return;
    }

    const flags = asm volatile ("pushfq; popq %[out]"
        : [out] "=r" (-> u64),
        :
        : "memory"
    );
    asm volatile ("cli" ::: "memory");
    const before_ticks = timer.ticks;
    const t0 = timer.centiseconds();
    // Bounded by the raw counter rather than by a spin count, and deliberately
    // not by `centiseconds` -- a test whose escape hatch is the thing under
    // test has no escape hatch. Ten hundredths' worth of TSC is long enough
    // that a working clock has certainly moved and short enough that a
    // stopped one ends the loop rather than the boot: measured, the version
    // bounded by a spin count instead hung the boot here for as long as it
    // was left running.
    const give_up = timer.raw_tsc() + timer.tsc_rate() * 10;
    while (timer.centiseconds() == t0 and timer.raw_tsc() < give_up) {
        asm volatile ("pause");
    }
    const t1 = timer.centiseconds();
    const after_ticks = timer.ticks;
    if ((flags & 0x200) != 0) asm volatile ("sti" ::: "memory");

    if (t1 == t0) {
        console.println("  [FAIL] console clock: it did not move with interrupts masked");
        return;
    }
    if (after_ticks != before_ticks) {
        // The spin above is supposed to prove the TSC moves where the tick
        // count cannot. If the tick count moved too, interrupts were not
        // actually masked and the test proved nothing.
        console.println("  [FAIL] console clock: interrupts were not masked, so nothing was shown");
        return;
    }
    console.print("  [ok] console clock: ");
    console.print_dec(timer.tsc_rate());
    console.print(" TSC ticks to the hundredth of a second, measured against the PIT, and it moved ");
    console.print_dec(t1 - t0);
    console.println(" with interrupts masked and the tick count standing still");
}
