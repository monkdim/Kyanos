//! Periodic timer driving the scheduler.
//!
//! Uses the legacy 8254 PIT for now (channel 0, mode 2 = rate
//! generator). Once we have ACPI parsing for the LAPIC frequency,
//! the LAPIC timer will replace this — the API stays the same.
//!
//! Default tick: 100 Hz (10 ms quantum).

const std = @import("std");
const port = @import("port.zig");
const idt = @import("idt.zig");
const sched = @import("../../sched/scheduler.zig");

const PIT_CMD: u16 = 0x43;
const PIT_CH0: u16 = 0x40;
const PIT_BASE_FREQ: u32 = 1_193_182;
const TIMER_VECTOR: u8 = 0x20;

pub var ticks: u64 = 0;
pub var hz: u32 = 100;

pub fn init(target_hz: u32) void {
    hz = target_hz;
    const divisor: u16 = @intCast(PIT_BASE_FREQ / target_hz);
    port.out8(PIT_CMD, 0b00110100);                    // ch0, lobyte/hibyte, rate generator
    port.out8(PIT_CH0, @truncate(divisor));
    port.out8(PIT_CH0, @truncate(divisor >> 8));
    idt.set_handler(TIMER_VECTOR, timer_irq);
}

// An ordinary function now. The vector's stub saves the register file, calls
// this, restores it and leaves by `iretq` -- see arch/x86_64/trap_entry.zig,
// which had to take that over so a ring boundary could `swapgs`.
fn timer_irq(frame: *idt.TrapFrame) callconv(.C) void {
    _ = frame;
    ticks += 1;
    // Acknowledge before switching away. The PIC will not raise another
    // timer interrupt until it sees this, and the switch may not come back
    // for a whole round of the run queue — acknowledging afterwards would
    // stop the clock at the first preemption.
    idt.end_of_interrupt(TIMER_VECTOR);
    // Before the switch, and before anything is moved: does the thread the
    // scheduler believes is running match the stack the CPU is on? This is
    // the one moment where that can be asked and answered, and it costs a
    // compare.
    sched.check_on_stack();
    // Before the switch, so a thread whose deadline has just passed is back
    // on the run queue in time for this tick's choice rather than the next
    // one. `centiseconds` reads the TSC, which costs an instruction and does
    // not depend on this handler having finished.
    sched.wake_sleepers(centiseconds());
    // A real switch. This used to call sched.schedule(), which only chooses
    // the next thread without moving to it — so the comment here claimed
    // "the arch-level switch happens before we return from this IRQ" and
    // nothing of the sort took place.
    sched.preempt();
}

/// A clock that keeps moving with interrupts masked.
///
/// `ticks` does not. It is a count of timer interrupts, and a system call is
/// entered with IF cleared by IA32_FMASK and stays that way, so anything
/// inside one that waits on `ticks` waits forever. That is not a slow read,
/// it is a hung kernel -- and `read(2)`'s idle timeout is exactly such a
/// wait. The counter underneath this one is the TSC, which the CPU advances
/// whatever the interrupt flag says.
///
/// It is calibrated against the PIT rather than assumed, because there is no
/// architectural TSC frequency to assume.
var tsc_per_centi: u64 = 0;
var tsc_base: u64 = 0;

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Measure the TSC against the timer that is already running.
///
/// Called with interrupts enabled and after `init`, because it waits for
/// `ticks` to move. Twenty ticks at 100 Hz is a fifth of a second: long
/// enough that the two reads of a counter incremented by an interrupt are not
/// dominated by where in a tick each one landed.
pub fn calibrate(centi_wanted: u64) void {
    const ticks_per_centi = hz / 100;
    const want_ticks = centi_wanted * @max(ticks_per_centi, 1);
    const start_tick = ticks;
    while (ticks == start_tick) asm volatile ("pause");
    const t0 = rdtsc();
    const from = ticks;
    while (ticks - from < want_ticks) asm volatile ("pause");
    const elapsed_ticks = ticks - from;
    const t1 = rdtsc();
    const elapsed_centi = (elapsed_ticks * 100) / hz;
    if (elapsed_centi == 0) return;
    tsc_per_centi = (t1 - t0) / elapsed_centi;
    tsc_base = t1;
}

/// Hundredths of a second since calibration, or zero if never calibrated.
///
/// Zero is the honest answer for "no clock": `drivers/stdin.zig` reads this
/// twice and subtracts, so a stuck clock means no timeout rather than an
/// immediate one, and a read with no timeout is a read that waits -- which is
/// what a console read should do when the kernel cannot tell the time.
pub fn centiseconds() u64 {
    if (tsc_per_centi == 0) return 0;
    const now = rdtsc();
    if (now <= tsc_base) return 0;
    return (now - tsc_base) / tsc_per_centi;
}

/// Was the TSC measured against the PIT?
pub fn calibrated() bool {
    return tsc_per_centi != 0;
}

/// The counter itself, unscaled.
///
/// For a caller that needs a bound on a wait *without* trusting the scaling
/// above -- which is what a test of `centiseconds` needs, since a test whose
/// escape hatch is the thing under test has no escape hatch.
pub fn raw_tsc() u64 {
    return rdtsc();
}

/// Ticks of the TSC per hundredth of a second, as measured. Zero until
/// `calibrate` has run.
pub fn tsc_rate() u64 {
    return tsc_per_centi;
}

pub fn uptime_ms() u64 { return ticks * (1000 / hz); }
pub fn uptime_seconds() u64 { return ticks / hz; }
