//! PS/2 keyboard + mouse driver — 8042 controller.
//!
//! Two devices on the legacy 8042 controller (i8042) hanging off
//! ports 0x60 (data) and 0x64 (status/command). The controller
//! multiplexes keyboard (port 1) and mouse (port 2). USB HID is its
//! own driver and lives in usb_hid.zig (deferred).
//!
//! Events are delivered through ring buffers consumed by the input
//! event bus in stdlib/event_bus.clarity.

const std = @import("std");
const port = @import("../arch/x86_64/port.zig");
const idt = @import("../arch/x86_64/idt.zig");

const PS2_DATA = 0x60;
const PS2_STATUS = 0x64;
const PS2_CMD = 0x64;

const KBD_BUF_SIZE = 256;
const MOUSE_BUF_SIZE = 256;

var kbd_buf: [KBD_BUF_SIZE]u8 = undefined;
var kbd_head: usize = 0;
var kbd_tail: usize = 0;

var mouse_buf: [MOUSE_BUF_SIZE]u8 = undefined;
var mouse_head: usize = 0;
var mouse_tail: usize = 0;

/// Upper bound on any 8042 status poll. Every wait here is bounded: a
/// controller that never clears (or never sets) a status bit must not be
/// able to wedge the boot. Sized generously — the 8042 answers in
/// microseconds, so this only trips on genuinely broken/absent hardware.
const WAIT_SPINS: usize = 100_000;

/// Wait until the input buffer is empty, i.e. it is safe to write a byte.
fn wait_write_ready() bool {
    var spins: usize = 0;
    while (spins < WAIT_SPINS) : (spins += 1) {
        if ((port.in8(PS2_STATUS) & 0x02) == 0) return true;
    }
    return false;
}

/// Wait until the output buffer is full, i.e. a response byte is available.
/// The controller does not answer instantly, so reading PS2_DATA without
/// this first returns stale/garbage data.
fn wait_read_ready() bool {
    var spins: usize = 0;
    while (spins < WAIT_SPINS) : (spins += 1) {
        if ((port.in8(PS2_STATUS) & 0x01) != 0) return true;
    }
    return false;
}

fn write_data(byte: u8) void {
    _ = wait_write_ready();
    port.out8(PS2_DATA, byte);
}

/// Read a response byte, or null if the controller never produced one.
fn read_data() ?u8 {
    if (!wait_read_ready()) return null;
    return port.in8(PS2_DATA);
}

pub fn init() !void {
    // Disable both ports during reconfig.
    cmd(0xAD); // disable port 1
    cmd(0xA7); // disable port 2

    // Drain any bytes the firmware left pending. Bounded: an emulated
    // controller that keeps asserting output-buffer-full would otherwise
    // spin here forever.
    var drained: usize = 0;
    while (drained < 64) : (drained += 1) {
        if ((port.in8(PS2_STATUS) & 0x01) == 0) break;
        _ = port.in8(PS2_DATA);
    }

    // Configure the controller: interrupts on both ports, and scancode
    // translation *on*.
    //
    // Two bits, and the first of them was wrong in a way nothing could see.
    // The mask that cleared the translation bit was 0b1011_1110, which also
    // clears bit 0 -- the first port's interrupt-enable, set on the line
    // above. The keyboard interrupt therefore never fired. Nothing reported
    // anything: the controller was content, `init` returned without error,
    // and the scancodes simply piled up in the output buffer with nobody
    // reading them. Measured, with keys sent through QEMU's monitor: the
    // output-buffer-full bit was set on 16283629 consecutive polls while the
    // ring stayed empty. With bit 0 left alone, the same keys arrive.
    //
    // Translation on, rather than off, because that is what makes the
    // scancodes the same numbers as the Linux keycodes the AArch64 side
    // already has a table for -- see drivers/kbd.zig, which measured both
    // settings.
    cmd(0x20);
    var cfg = read_data() orelse return error.ControllerUnresponsive;
    cfg |= 0b0000_0011; // IRQ1 + IRQ12
    cfg |= 0b0100_0000; // translation: keyboard set 2 in, set 1 out
    cmd(0x60);
    write_data(cfg);

    // Self test.
    cmd(0xAA);
    const self_test = read_data() orelse return error.ControllerUnresponsive;
    if (self_test != 0x55) return error.ControllerSelfTest;

    cmd(0xAE); // enable port 1
    cmd(0xA8); // enable port 2

    idt.set_handler(0x21, kbd_irq);
    idt.set_handler(0x2C, mouse_irq);
}

fn cmd(byte: u8) void {
    _ = wait_write_ready();
    port.out8(PS2_CMD, byte);
}

// Ordinary functions. The vector's stub saves the register file, calls the
// handler and leaves by `iretq` -- see arch/x86_64/trap_entry.zig, which had
// to take that over so a ring boundary could `swapgs`. Each handler still has
// to acknowledge the PIC, or that IRQ line never fires again.
fn kbd_irq(frame: *idt.TrapFrame) callconv(.C) void {
    _ = frame;
    const scancode = port.in8(PS2_DATA);
    const next = (kbd_head + 1) % KBD_BUF_SIZE;
    if (next != kbd_tail) {
        kbd_buf[kbd_head] = scancode;
        kbd_head = next;
    }
    idt.end_of_interrupt(0x21);
}

fn mouse_irq(frame: *idt.TrapFrame) callconv(.C) void {
    _ = frame;
    const byte = port.in8(PS2_DATA);
    const next = (mouse_head + 1) % MOUSE_BUF_SIZE;
    if (next != mouse_tail) {
        mouse_buf[mouse_head] = byte;
        mouse_head = next;
    }
    idt.end_of_interrupt(0x2C);
}

pub fn read_kbd() ?u8 {
    if (kbd_head == kbd_tail) return null;
    const b = kbd_buf[kbd_tail];
    kbd_tail = (kbd_tail + 1) % KBD_BUF_SIZE;
    return b;
}

pub fn read_mouse() ?u8 {
    if (mouse_head == mouse_tail) return null;
    const b = mouse_buf[mouse_tail];
    mouse_tail = (mouse_tail + 1) % MOUSE_BUF_SIZE;
    return b;
}
