//! Interrupt Descriptor Table — IRQ + exception dispatch.
//!
//! Every one of the 256 gates is populated. An unpopulated gate is not
//! "unused": the CPU treats a not-present gate as a #GP, and with no #GP
//! handler that escalates to a double fault and then a triple fault, which
//! resets the machine without printing anything. That failure mode makes
//! every kernel bug look identical from the serial log, so the CPU
//! exception vectors report a register dump before halting, and the
//! remaining vectors get a benign handler that acknowledges the PIC.

const std = @import("std");
const console = @import("console.zig");
const port = @import("port.zig");
const trap_entry = @import("trap_entry.zig");
const arch_syscall = @import("syscall.zig");
const sched = @import("../../sched/scheduler.zig");

const Entry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

/// What a handler is given: every general register, the vector, the error
/// code, and the five words the CPU pushed. See trap_entry.zig for why the
/// entry path is written out rather than left to `callconv(.Interrupt)`.
pub const TrapFrame = trap_entry.TrapFrame;

var idt: [256]Entry align(8) = undefined;
var idtr: packed struct { limit: u16, base: u64 } = undefined;

const EXCEPTION_NAMES = [_][]const u8{
    "divide error",
    "debug",
    "non-maskable interrupt",
    "breakpoint",
    "overflow",
    "BOUND range exceeded",
    "invalid opcode",
    "device not available",
    "double fault",
    "coprocessor segment overrun",
    "invalid TSS",
    "segment not present",
    "stack-segment fault",
    "general protection fault",
    "page fault",
    "reserved",
    "x87 floating-point exception",
    "alignment check",
    "machine check",
    "SIMD floating-point exception",
    "virtualization exception",
    "control protection exception",
};

fn read_cr2() u64 {
    return asm volatile ("mov %%cr2, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

fn halt() noreturn {
    while (true) asm volatile ("cli; hlt");
}

/// What `sched.exit` is given for a process the kernel ended rather than one
/// that ended itself. Negative because an exit status a program can pass to
/// `exit(2)` is a byte, so nothing a program can say collides with it.
const KILLED: i32 = -1;

fn report(vec: usize, err: ?u64, frame: *const TrapFrame) void {
    console.print("\n\nCPU EXCEPTION ");
    console.print_dec(vec);
    if (vec < EXCEPTION_NAMES.len) {
        console.print(" (");
        console.print(EXCEPTION_NAMES[vec]);
        console.print(")");
    }
    if (err) |e| {
        console.print(" error_code=");
        console.print_hex(e);
    }
    console.print("\n  rip=");
    console.print_hex(frame.rip);
    console.print(" cs=");
    console.print_hex(frame.cs);
    console.print(" rflags=");
    console.print_hex(frame.rflags);
    console.print("\n  rsp=");
    console.print_hex(frame.rsp);
    console.print(" ss=");
    console.print_hex(frame.ss);
    if (vec == 14) {
        // #PF: CR2 holds the faulting linear address.
        console.print(" cr2=");
        console.print_hex(read_cr2());
    }
    console.println("");
}

/// A program faulted. End the program.
///
/// Reached only from ring 3, and it does exactly what `exit(2)` does, for the
/// reason that the two situations are the same one: a fault from ring 3
/// arrives on the faulting thread's own kernel stack — `yield` writes
/// `next.kernel_stack_top` into the TSS on every switch — so `sched.exit` is
/// running where it always runs. It marks the thread a zombie, gives the
/// process's memory back, records the exit against the parent and switches
/// away without returning; the trap frame is abandoned along with the stack,
/// which is freed later by whoever next reaches `yield`.
///
/// Interrupts are masked here and stay masked, and that is not a hazard:
/// every gate is an interrupt gate (`0x8E`), so the counter below cannot be
/// raced by a tick, and `switch_to` does `pushfq; cli` in and `popfq` out, so
/// the thread this switches to comes back with its own interrupt state rather
/// than the fault's.
fn kill_current() noreturn {
    if (sched.current_thread()) |t| {
        console.print("  [killed] ");
        console.print(t.name);
        console.print(" (pid ");
        console.print_dec(if (t.pid > 0) @intCast(t.pid) else 0);
        console.println(") — it faulted, so the kernel ended it");
        sched.user_faults += 1;
        sched.exit(KILLED);
    }
    // Nothing to end. Every path into ring 3 goes through a scheduler thread,
    // so this is unreachable rather than merely unlikely — and if it is ever
    // reached, there is no process to blame and no successor to switch to.
    console.println("  [halt] a fault in ring 3 with no thread to end");
    halt();
}

/// A handler installed against a vector. Plain C convention now: the stub
/// owns the `iretq`, so a handler is an ordinary call and may return.
pub const Handler = *const fn (*TrapFrame) callconv(.C) void;

var handlers: [256]?Handler = [_]?Handler{null} ** 256;

/// Where every vector arrives. An exception reports, and then ends either the
/// machine or the program depending on the ring it came from; everything else
/// goes to whatever driver claimed the vector, or acknowledges the PIC and
/// resumes -- a spurious or unclaimed IRQ must not be able to take the
/// machine down, and neither must a program.
fn dispatch(frame: *TrapFrame) callconv(.C) void {
    const vec = frame.vector;
    check_gs(frame);
    if (vec < 32) {
        const err: ?u64 = if (has_error_code(vec)) frame.error_code else null;
        report(vec, err, frame);
        // Whose bug it was decides what happens next, and until now the
        // answer to both was to stop the machine. A fault in ring 0 is a
        // kernel bug and halting is right: there is no smaller thing to end,
        // and carrying on would run the rest of the boot on top of whatever
        // went wrong. A fault in ring 3 is a *program's* bug, and an
        // operating system that stops for one is not one — so the program
        // ends and nothing else does.
        if ((frame.cs & 3) == 3) kill_current();
        halt();
    }
    if (vec < handlers.len) {
        if (handlers[vec]) |h| {
            h(frame);
            return;
        }
    }
    end_of_interrupt(0xFF);
}

/// Was the per-CPU block reachable through %gs when this trap arrived?
///
/// It has to be, in ring 0, whichever ring the trap came from -- and the only
/// thing that makes it true for a trap from ring 3 is the `swapgs` in the
/// stub. Ring 3 runs with a GS base of the kernel's choosing that is *not*
/// the per-CPU block (arch/x86_64/syscall.zig's `user_gs`), so a missing
/// `swapgs` shows up as a wrong magic here rather than as a fault somewhere
/// later with nothing to connect it to.
fn check_gs(frame: *const TrapFrame) void {
    // Not before the bases exist -- see `gs_ready`, which is where the one
    // interrupt that arrives in that window is written down.
    if (!arch_syscall.gs_ready) return;
    if ((frame.cs & 3) != 0) arch_syscall.entries_from_ring3 += 1;
    arch_syscall.entries_total += 1;
    if (!arch_syscall.gs_is_kernel()) arch_syscall.gs_wrong += 1;
}

/// The runtime twin of trap_entry's comptime list, for reporting only: the
/// frame always carries an `error_code` word, and this says whether the CPU
/// put it there or the stub did.
fn has_error_code(vec: u64) bool {
    return vec == 8 or (vec >= 10 and vec <= 14) or vec == 17 or vec == 21 or vec == 29 or vec == 30;
}

/// Signal end-of-interrupt to the PIC(s). Vectors 0x28+ live on the slave.
pub fn end_of_interrupt(vector: u8) void {
    if (vector >= 0x28) port.out8(0xA0, 0x20);
    port.out8(0x20, 0x20);
}

pub fn init() void {
    @memset(std.mem.asBytes(&idt), 0);
    remap_pic();

    trap_entry.dispatch = dispatch;
    // Every gate points at its own stub. They differ only in the vector they
    // name and whether they push a zero where the CPU pushed nothing.
    inline for (0..256) |vec| {
        set_gate(@intCast(vec), trap_entry.stub_address(vec));
    }

    idtr.limit = @sizeOf(@TypeOf(idt)) - 1;
    idtr.base = @intFromPtr(&idt);
    asm volatile ("lidt %[idtr]; sti"
        :
        : [idtr] "*p" (&idtr),
    );
}

fn set_gate(vector: u8, addr: u64) void {
    idt[vector] = .{
        .offset_low = @truncate(addr),
        .selector = 0x08,
        .ist = 0,
        .type_attr = 0x8E, // present, ring 0, 64-bit interrupt gate
        .offset_mid = @truncate(addr >> 16),
        .offset_high = @truncate(addr >> 32),
        .reserved = 0,
    };
}

/// Install a device IRQ handler.
///
/// It used to be the gate itself, which is why it had to carry the interrupt
/// calling convention. The gate is the stub now and the handler is called
/// from it, so this is an ordinary function that returns and the stub does
/// the `iretq`.
pub fn set_handler(vector: u8, handler: Handler) void {
    handlers[vector] = handler;
}

fn remap_pic() void {
    // Remap the legacy 8259 PIC vectors to 0x20..0x2F so they don't
    // collide with CPU exceptions in the 0x00..0x1F range.
    port.out8(0x20, 0x11); port.out8(0xA0, 0x11);
    port.out8(0x21, 0x20); port.out8(0xA1, 0x28);
    port.out8(0x21, 0x04); port.out8(0xA1, 0x02);
    port.out8(0x21, 0x01); port.out8(0xA1, 0x01);
    port.out8(0x21, 0x00); port.out8(0xA1, 0x00);
}
