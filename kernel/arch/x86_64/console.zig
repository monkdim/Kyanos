//! Early console — VGA text mode at 0xB8000 + serial COM1 fallback.
//!
//! Used during boot before the framebuffer driver is up. Once the
//! desktop is running, console.println goes to the kernel log
//! reachable via dmesg(8).

const std = @import("std");
const port = @import("port.zig");
const idt = @import("idt.zig");

const VGA_BUF: [*]volatile u16 = @ptrFromInt(0xFFFF_8000_000B_8000);
const VGA_W = 80;
const VGA_H = 25;
const COM1 = 0x3F8;

var cursor_x: u8 = 0;
var cursor_y: u8 = 0;
var attr: u8 = 0x07; // light grey on black

pub fn init() void {
    cursor_x = 0;
    cursor_y = 0;
    // Initialise COM1 at 38400 8N1.
    port.out8(COM1 + 1, 0x00);
    port.out8(COM1 + 3, 0x80);
    port.out8(COM1 + 0, 0x03);
    port.out8(COM1 + 1, 0x00);
    port.out8(COM1 + 3, 0x03);
    port.out8(COM1 + 2, 0xC7);
    port.out8(COM1 + 4, 0x0B);
    // And put back the receive interrupt, if it was ever turned on.
    //
    // This function is called *twice*: once as the first thing the kernel
    // does, and again from `drivers/init.zig`, whose own comment says
    // "Console first -- every other driver wants to print errors". The
    // second call re-runs the whole sequence above, including the two writes
    // of zero to the IER -- so anything enabled in between is silently
    // switched off. That cost this file its receive interrupt, and the only
    // symptom was a counter reading zero.
    //
    // Re-applying here rather than moving the caller: a third call would
    // break it again, and a console that reinitialises itself should come
    // back in the state it was in rather than the state it shipped in.
    if (rx_interrupt_on) port.out8(COM1 + 1, 0x01);
}

// ── output atomicity ────────────────────────────────────
//
// The timer preempts a thread between any two instructions, so two threads
// printing at once would interleave *inside* a line — one thread's bytes
// landing in the middle of another's word. On a single CPU, holding off
// interrupts for the length of a call is exactly a console lock: nothing else
// can run, so nothing else can print.
//
// It saves and restores rather than ending with a bare `sti`, because print
// is also called from the exception reporter and from other paths where
// interrupts are already off and must stay off.
//
// The cost is real on real hardware: serial_out busy-waits on the UART, so a
// 40-character line at 38400 baud holds interrupts off for about 10 ms — a
// whole timer tick. Under QEMU the port write returns immediately, which is
// what the gate measures. A buffered console that hands bytes to an
// interrupt-driven writer is the fix, and is not this change.
fn lock() u64 {
    const flags = asm volatile ("pushfq; popq %[out]"
        : [out] "=r" (-> u64),
        :
        : "memory"
    );
    asm volatile ("cli" ::: "memory");
    return flags;
}

fn unlock(flags: u64) void {
    if ((flags & 0x200) != 0) asm volatile ("sti" ::: "memory");
}

pub fn print(s: []const u8) void {
    const flags = lock();
    defer unlock(flags);
    for (s) |c| putchar(c);
}

pub fn println(s: []const u8) void {
    const flags = lock();
    defer unlock(flags);
    for (s) |c| putchar(c);
    putchar('\n');
}

// VGA mirroring is opt-in. The VGA buffer is addressed through the HHDM
// (0xFFFF_8000_..), so a write faults on any path where that mapping isn't
// live — and if it faults inside panic() it storms the log with the panic
// prefix forever. Serial (pure port I/O) never faults, so the early console
// stays serial-only until a driver explicitly turns VGA on.
var vga_enabled: bool = false;

// ── COM1 receive ────────────────────────────────────────────────────────
//
// The keyboard has had an interrupt since its driver landed and the serial
// line did not, and the reason written here was this:
//
//     Polled rather than interrupt-driven, which is what read(2) needs: it
//     is entered with IF clear and an interrupt-filled ring would never fill
//     while it waited.
//
// That stopped being true when `syscall_entry` began setting IF once the
// frame is built, and it is not an argument either way now: the console
// wait was measured taking the `hlt` branch of a test of RFLAGS.IF, which
// only a caller with interrupts *on* can do. So the line can have its
// interrupt, and needs one -- a reader that sleeps until input arrives has
// nothing to wake it on this line otherwise.

const SERIAL_VECTOR: u8 = 0x24; // IRQ4, the PIC's base of 0x20 plus four
const SERIAL_RING = 256;

/// Whether the receive interrupt has been turned on, so `init` can put it
/// back when it is called a second time. See the note at the end of `init`.
var rx_interrupt_on: bool = false;

var rx: [SERIAL_RING]u8 = undefined;
var rx_head: usize = 0;
var rx_tail: usize = 0;

/// How many bytes arrived by interrupt, and how many were dropped because
/// nobody had read the ring yet. Both, because "the interrupt works" and
/// "the ring is big enough" are different claims.
pub var rx_interrupts: u64 = 0;
pub var rx_dropped: u64 = 0;

fn rx_push(c: u8) void {
    const next = (rx_head + 1) % SERIAL_RING;
    if (next == rx_tail) {
        rx_dropped += 1;
        return;
    }
    rx[rx_head] = c;
    rx_head = next;
}

fn serial_irq(frame: *idt.TrapFrame) callconv(.C) void {
    _ = frame;
    // Drain, rather than take one byte: the UART raises one interrupt for a
    // FIFO that may hold several, and a handler that took one byte per
    // interrupt would fall behind exactly when it matters.
    while ((port.in8(COM1 + 5) & 0x01) != 0) {
        rx_push(port.in8(COM1));
        rx_interrupts += 1;
    }
    idt.end_of_interrupt(SERIAL_VECTOR);
}

/// Let COM1 raise an interrupt when a byte arrives.
///
/// Separate from `init`, which runs before there is an IDT to put a handler
/// in: the console is the first thing the kernel brings up precisely so that
/// everything after it can report its own failures.
pub fn enable_receive_interrupt() void {
    idt.set_handler(SERIAL_VECTOR, serial_irq);
    rx_interrupt_on = true;
    // IER bit 0: received-data-available. Only that one -- the others report
    // transmitter and modem state, which nothing here reads, and an
    // interrupt nobody handles is a line that never fires again.
    port.out8(COM1 + 1, 0x01);
}

/// One byte from COM1, or null if nothing has arrived.
///
/// The ring first and the port second, and both rather than either. The ring
/// is where the interrupt puts bytes; the port is where they sit on a machine
/// whose interrupt never arrives, and this is the same belt-and-braces the
/// PL011 driver has on the other architecture. Reading the port when the ring
/// is empty cannot steal a byte from the handler: the handler runs with
/// interrupts masked and drains the FIFO completely, so either it has taken
/// the byte and the ring is not empty, or it has not run and the byte is
/// still in the port.
pub fn serial_poll() ?u8 {
    if (rx_tail != rx_head) {
        const c = rx[rx_tail];
        rx_tail = (rx_tail + 1) % SERIAL_RING;
        return c;
    }
    if ((port.in8(COM1 + 5) & 0x01) == 0) return null;
    return port.in8(COM1);
}

/// Echo a byte back the way it came, for the line editor.
pub fn echo(c: u8) void {
    const flags = lock();
    defer unlock(flags);
    putchar(c);
}

pub fn enable_vga() void {
    vga_enabled = true;
}

fn putchar(c: u8) void {
    serial_out(c);
    if (!vga_enabled) return;
    if (c == '\n') {
        cursor_x = 0;
        cursor_y += 1;
    } else {
        VGA_BUF[cursor_y * VGA_W + cursor_x] = (@as(u16, attr) << 8) | c;
        cursor_x += 1;
        if (cursor_x >= VGA_W) {
            cursor_x = 0;
            cursor_y += 1;
        }
    }
    if (cursor_y >= VGA_H) cursor_y = VGA_H - 1; // TODO: scroll
}

/// Print an unsigned value as 0x-prefixed hex. Kept dependency-free (no
/// std.fmt, no allocator) so it is safe to call from the earliest boot
/// paths and from panic handlers.
pub fn print_hex(v: u64) void {
    const flags = lock();
    defer unlock(flags);
    const digits = "0123456789abcdef";
    putchar('0');
    putchar('x');
    var i: u6 = 60;
    var started = false;
    while (true) : (i -= 4) {
        const nib: u8 = @intCast((v >> i) & 0xF);
        if (nib != 0 or started or i == 0) {
            started = true;
            putchar(digits[nib]);
        }
        if (i == 0) break;
    }
}

/// Print an unsigned value in decimal.
pub fn print_dec(v: u64) void {
    const flags = lock();
    defer unlock(flags);
    if (v == 0) {
        putchar('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var n = v;
    var i: usize = 0;
    while (n > 0) : (n /= 10) {
        buf[i] = @intCast('0' + (n % 10));
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        putchar(buf[i]);
    }
}

fn serial_out(c: u8) void {
    while ((port.in8(COM1 + 5) & 0x20) == 0) {}
    port.out8(COM1, c);
}
