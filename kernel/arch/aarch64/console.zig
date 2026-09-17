//! AArch64 early console — PL011 UART.
//!
//! QEMU's `virt` machine maps PL011 UART0 at 0x0900_0000 and wires it to
//! `-serial`. The firmware/QEMU leaves it in a usable state, so we only
//! need to respect the transmit-FIFO-full flag before writing a byte.
//!
//! Mirrors the x86_64 console API (init/print/println) so the shared
//! kernel code can print identically on both architectures.

const vm = @import("vm.zig");
const gic = @import("gic.zig");
const text = @import("../../graphics/console.zig");

/// Where else everything printed should go.
///
/// Null until there is a screen, which cannot be before the device tree has
/// been read — and by then the console has already said several things. Those
/// early lines exist only on the serial line, which is correct: they are about
/// finding the machine, and one of the things being found is the display.
///
/// Opt-in and set once, so the ordinary path stays a single MMIO write. The
/// x86_64 side mirrors to VGA the same way and for the same reason.
var mirror: ?*text.Console = null;

pub fn set_mirror(c: *text.Console) void {
    mirror = c;
}

/// The PL011's physical address on QEMU's `virt`, seen through the kernel's
/// direct map. It has to be a constant rather than something read from the
/// device tree, because the console has to work before anything can be
/// printed about the tree — including the fact that there is not one.
///
/// The `+ KERNEL_VA_BASE` is what changed when the kernel moved to the high
/// half: the physical address is still 0x0900_0000, and after the boot stub
/// drops the identity map that address is no longer one this kernel can
/// dereference.
const UART0_PHYS: usize = 0x0900_0000;
const UART0_BASE: usize = UART0_PHYS + vm.KERNEL_VA_BASE;
const UARTDR: usize = 0x00; // data register
const UARTFR: usize = 0x18; // flag register
const UARTIFLS: usize = 0x34; // FIFO level select
const UARTIMSC: usize = 0x38; // interrupt mask set/clear
const UARTMIS: usize = 0x40; // masked interrupt status
const UARTICR: usize = 0x44; // interrupt clear
const FR_RXFE: u32 = 1 << 4; // receive FIFO empty
const FR_TXFF: u32 = 1 << 5; // transmit FIFO full

/// Receive, and receive-timeout. Both are needed and the second is the one
/// that is easy to leave out: RX fires when the FIFO reaches its trigger
/// level, so a person typing one character and waiting would sit below the
/// level forever. RT fires when the FIFO is non-empty and the line has been
/// idle for thirty-two bit periods, which is that case exactly.
const INT_RX: u32 = 1 << 4;
const INT_RT: u32 = 1 << 6;

inline fn mmio_write(offset: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(UART0_BASE + offset)).* = value;
}

inline fn mmio_read(offset: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(UART0_BASE + offset)).*;
}

pub fn init() void {
    // QEMU's PL011 comes up transmit-ready; nothing to program for output.
    // Real hardware bring-up (baud divisors, line control, FIFO enable)
    // lands with the aarch64 driver phase.
}

/// One byte from the serial line, or null.
///
/// This port was write-only until now, and that was not a small gap. The only
/// way to type into this machine was the graphical window — which means
/// finding it, clicking it, and letting it capture the pointer before a text
/// prompt would listen. On a Mac that turned out to be the difference between
/// an operating system somebody could use and one they could only watch.
///
/// A serial console needs no window, no display backend and no focus. It is
/// how every other kernel is driven headlessly, and with `-serial stdio` it
/// means typing into the same terminal that started QEMU.
///
/// Interrupt-driven, with the FIFO drained here as well.
///
/// This was polled, and the argument for leaving it that way was that the
/// UART holds sixteen bytes in its own FIFO and a person types slower than
/// that. The architectural answer is that nothing empties the FIFO while the
/// kernel is doing something else, so a burst arriving then has only those
/// sixteen bytes to sit in — the same asymmetry the keyboard's interrupt
/// closed.
///
/// **Under QEMU that does not happen, and it was tried.** Sixty-five bytes in
/// one write, spanning six shell commands with a command executing between
/// each, arrived complete on a build with this interrupt not routed at all;
/// so did a forty-three byte line typed in one go at the kernel's own prompt.
/// QEMU's chardev backend does not hand the model more than the guest has
/// taken, so the emulated FIFO does not overrun however fast the writer goes.
/// What this buys on hardware without that courtesy is therefore an argument
/// from the device, not a measurement — said plainly rather than left to look
/// like a bug that was fixed.
///
/// The drain happens in both places on purpose — here and in the handler. The
/// handler is what empties the FIFO without waiting to be asked; draining here
/// as well is what keeps this working on a machine whose interrupt never
/// arrives, which is the same reasoning the virtio-input driver's ring is
/// written with. Interrupts are masked across it because the handler is the
/// other producer, and two of them sharing `head` would each overwrite what
/// the other had just written.
pub fn poll_in() ?u8 {
    const daif = mask_irqs();
    drain_fifo();
    restore_irqs(daif);

    const t = rx_tail;
    if (t == rx_head) return null;
    const c = rx[t % RX_RING];
    rx_tail = t +% 1;
    return c;
}

/// Everything the FIFO is holding, into the ring.
///
/// Called with interrupts masked, from the handler or from `poll_in`.
fn drain_fifo() void {
    while (mmio_read(UARTFR) & FR_RXFE == 0) {
        const c: u8 = @truncate(mmio_read(UARTDR) & 0xFF);
        if (rx_head -% rx_tail >= RX_RING) {
            // The reader is further behind than the ring is deep. Dropping
            // the new byte rather than the oldest keeps what was typed first,
            // which is what a line editor needs; and it is counted, so a boot
            // that lost input says so instead of looking like one where less
            // was typed.
            rx_dropped +%= 1;
            return;
        }
        rx[rx_head % RX_RING] = c;
        rx_head +%= 1;
    }
}

/// Deeper than the FIFO by a wide margin, because the FIFO is what this is
/// for: sixteen bytes is what the hardware holds between one service and the
/// next, and the ring is what holds them while nothing is reading.
const RX_RING: u32 = 256;
var rx: [RX_RING]u8 = undefined;
var rx_head: u32 = 0;
var rx_tail: u32 = 0;
var rx_dropped: u64 = 0;
var rx_intid: ?u32 = null;
var rx_interrupts: u64 = 0;

/// Ask the GIC to deliver this port's receive interrupt.
///
/// Called after the device tree has been read, with the INTID from it — the
/// same shape as the keyboard's `route`, and for the same reason: the console
/// is brought up before anything has parsed a tree, so it cannot learn its
/// own interrupt at `init` time.
pub fn route(id: u32) void {
    // Trigger at one eighth — two bytes of sixteen. Low on purpose: the
    // point of the interrupt is to empty the FIFO long before it fills, and
    // a high trigger level trades the latency this exists to remove for
    // fewer interrupts nobody was counting.
    mmio_write(UARTIFLS, 0);
    mmio_write(UARTICR, INT_RX | INT_RT);
    mmio_write(UARTIMSC, mmio_read(UARTIMSC) | INT_RX | INT_RT);
    gic.enable(id);
    rx_intid = id;
}

/// Service the port's interrupt. Returns false if it was not ours.
///
/// Cleared before the FIFO is drained rather than after. Either order empties
/// it; this one cannot lose a byte, because one arriving in the window
/// between the two is still in the FIFO for this pass to read, and would
/// raise the interrupt again if it were not.
pub fn handle_irq(which: u32) bool {
    const mine = rx_intid orelse return false;
    if (which != mine) return false;
    rx_interrupts +%= 1;
    mmio_write(UARTICR, INT_RX | INT_RT);
    drain_fifo();
    return true;
}

/// Whether the receive interrupt was wired, and what it has done — for the
/// boot report. A port that is being polled and one whose interrupt never
/// fires look the same from the outside, which is the asymmetry this closes.
pub fn rx_routed() ?u32 {
    return rx_intid;
}
pub fn rx_serviced() u64 {
    return rx_interrupts;
}
pub fn rx_lost() u64 {
    return rx_dropped;
}

fn mask_irqs() u64 {
    const daif = asm volatile ("mrs %[out], daif"
        : [out] "=r" (-> u64),
    );
    asm volatile ("msr daifset, #2" ::: "memory");
    return daif;
}

fn restore_irqs(daif: u64) void {
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (daif),
        : "memory"
    );
}

pub fn print(s: []const u8) void {
    for (s) |c| putchar(c);
}

pub fn println(s: []const u8) void {
    print(s);
    putchar('\n');
}

/// Print an unsigned value as 0x-prefixed hex. Dependency-free (no std.fmt,
/// no allocator) so it is safe from the earliest boot paths and from
/// exception handlers.
pub fn print_hex(v: u64) void {
    const digits = "0123456789abcdef";
    print("0x");
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

/// One byte to the console, control characters included.
///
/// `print` exists for messages; this exists for echoing what someone typed,
/// where the bytes go out one at a time and several of them are not
/// printable. Same path, so an echoed character reaches the screen exactly
/// as a printed one does.
pub fn putc(c: u8) void {
    putchar(c);
}

fn putchar(c: u8) void {
    while ((mmio_read(UARTFR) & FR_TXFF) != 0) {}
    mmio_write(UARTDR, c);
    if (mirror) |m| m.put(c);
}
