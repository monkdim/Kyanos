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

// Interrupt calling convention: the CPU pushes an interrupt frame and the
// handler must leave via `iretq`, which callconv(.C) would not do.
fn timer_irq(frame: *idt.InterruptFrame) callconv(.Interrupt) void {
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
    // A real switch. This used to call sched.schedule(), which only chooses
    // the next thread without moving to it — so the comment here claimed
    // "the arch-level switch happens before we return from this IRQ" and
    // nothing of the sort took place.
    sched.preempt();
}

pub fn uptime_ms() u64 { return ticks * (1000 / hz); }
pub fn uptime_seconds() u64 { return ticks / hz; }
