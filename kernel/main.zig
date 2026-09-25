//! KyanOS micro-kernel — main entry point.
//!
//! The bootloader hands control here once paging is set up and the
//! machine is in long mode. From here we initialise memory, set up
//! the scheduler, mount the root filesystem, then jump into the
//! Clarity userspace runtime.
//!
//! This is the only non-Clarity code in the OS. Everything above
//! `userspace_start()` runs as Clarity.

const std = @import("std");
const console = @import("arch/x86_64/console.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const paging = @import("arch/x86_64/paging.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const heap = @import("mm/heap.zig");
const sched = @import("sched/scheduler.zig");
const syscall = @import("syscall/dispatch.zig");
const vfs = @import("fs/vfs.zig");
const smap = @import("arch/x86_64/smap.zig");
const tmpfs = @import("fs/tmpfs.zig");
const drivers = @import("drivers/init.zig");
const multiboot = @import("boot/multiboot2.zig");
const initprog = @import("initprog.zig");
const regprobe = @import("regprobe.zig");
const forkprobe = @import("forkprobe.zig");
const waitprobe = @import("waitprobe.zig");
const forkexec = @import("forkexec.zig");
const clarityprog = @import("clarityprog.zig");
const gsprobe = @import("gsprobe.zig");
const stackprobe = @import("stackprobe.zig");
const threadtest = @import("threadtest.zig");
const fstest = @import("fstest.zig");
const preempttest = @import("preempttest.zig");
const timer = @import("arch/x86_64/timer.zig");
const stdin = @import("drivers/stdin.zig");
const kbd = @import("drivers/kbd.zig");
const conread = @import("conread.zig");
const readprobe = @import("readprobe.zig");
const faultprobe = @import("faultprobe.zig");
const shell = @import("shell.zig");
const fpu = @import("arch/x86_64/fpu.zig");
const fputest = @import("fputest.zig");

extern const __kernel_phys_end: u8;

/// Boot info handed up from the loader: memory map, framebuffer, ACPI RSDP.
pub const BootInfo = struct {
    memory_map: []const multiboot.MemoryMapEntry,
    framebuffer: ?multiboot.Framebuffer,
    rsdp: ?u64,
    cmdline: []const u8,
};

/// Entry point invoked by the boot stub. The stub switched to long mode,
/// mapped the identity/HHDM/kernel windows, loaded a flat GDT, and passed
/// the raw multiboot2 info blob pointer (physical, identity-mapped) in the
/// first C argument register.
pub export fn kernel_main(mb_info_phys: u64) callconv(.C) noreturn {
    console.init();
    console.println("KyanOS micro-kernel starting...");

    // 1. CPU structures
    gdt.init();
    idt.init();
    // x87 and SSE, before anything can execute a floating-point instruction.
    // The kernel does not use one — it is built with SSE subtracted and
    // soft_float on — but ring 3 will: a compiled Clarity program is C, and C
    // on x86-64 keeps every double in an xmm register. Without CR4.OSFXSR
    // that program's first division raises #UD.
    fpu.enable();
    console.println("  [ok] GDT + IDT + FPU");
    // SMEP and SMAP, where the CPU has them. Every access to a process's
    // memory goes through mm/uaccess.zig and the direct map, so the kernel
    // never needs to touch a user address; with SMAP on, a path that still
    // did would fault instead of quietly working. The default QEMU CPU has
    // neither, and the log says so rather than claiming a protection the
    // hardware did not provide; the boot gate also runs `-cpu max`, which has
    // both.
    const guard = smap.enable();
    if (guard.smep and guard.smap) {
        console.println("  [ok] smep+smap: ring 0 cannot run or touch user pages by accident");
    } else if (guard.smep) {
        console.println("  [--] smep on; smap not on this CPU");
    } else {
        console.println("  [--] smep+smap: not on this CPU (qemu64 has neither; -cpu max does)");
    }

    // Parse the multiboot2 info blob into a BootInfo. Allocator-free, so
    // the memory map aliases the firmware-supplied table — it must be
    // consumed by pmm before we repurpose low memory.
    const parsed = multiboot.ParsedBootInfo.parse(@ptrFromInt(mb_info_phys), null) catch {
        console.println("PANIC: multiboot2 info parse failed");
        hang();
    };
    const boot_info = BootInfo{
        .memory_map = parsed.memory_map,
        .framebuffer = parsed.framebuffer,
        .rsdp = parsed.rsdp_v2 orelse parsed.rsdp_v1,
        .cmdline = parsed.cmdline,
    };

    // Boot-layout diagnostics. The multiboot info blob is handed to us by
    // the loader, which reserves the kernel's file image but not its .bss;
    // if the blob lands inside .bss, pmm's bitmap memset would shred the
    // memory map we are about to read. Report the geometry so the boot log
    // proves whether they overlap.
    console.print("  mbi=");
    console.print_hex(mb_info_phys);
    console.print(" kernel_end=");
    console.print_hex(@intFromPtr(&__kernel_phys_end));
    console.print(" mmap_entries=");
    console.print_dec(boot_info.memory_map.len);
    console.println("");

    // 2. Memory: physical page allocator over the boot memory map,
    //    then a clean page-table tree owned by the kernel, then a
    //    slab allocator for kernel objects.
    // The map is built explicitly rather than handed over as a multiboot
    // structure, so the allocator itself knows nothing about how this machine
    // describes its memory — the aarch64 side builds the same map from a
    // device tree.
    pmm.begin();
    for (boot_info.memory_map) |entry| {
        if (entry.region_type != @intFromEnum(multiboot.MemoryRegionType.available)) continue;
        pmm.add_available(entry.base_addr, entry.length);
    }
    // The first mebibyte is BIOS and legacy hardware, and the kernel image —
    // code, rodata, data, bss, the boot page tables and the boot stack — runs
    // from where it was loaded. Neither is ours to hand out.
    pmm.reserve(0, 1 << 20);
    pmm.reserve(0, @intFromPtr(&__kernel_phys_end));
    pmm.finish();
    console.println("  .. pmm ok");
    vmm.init();
    console.println("  .. vmm ok");
    heap.init();
    console.println("  [ok] memory: pmm + vmm + heap");

    // 3. Scheduler: idle thread + kernel-thread runqueue.
    sched.init();
    // The PIT, at last actually programmed: timer.init was called from
    // nowhere, so the scheduler had no clock and nothing was ever preempted.
    // It goes here, after the scheduler and before any thread exists, so the
    // first tick can only ever land on the boot path — where preempt() is a
    // no-op — and never on a half-built run queue.
    timer.init(100);
    console.println("  [ok] scheduler + 100 Hz timer");

    // 4. Syscall surface. Wires the SYSCALL/SYSRET MSRs and the
    //    int 0x80 fallback to the dispatch table.
    syscall.init();
    console.println("  [ok] syscalls");

    // 5. VFS + tmpfs as the root filesystem.
    vfs.init();
    tmpfs.mount_root() catch |err| {
        console.print("PANIC: tmpfs mount failed: ");
        console.println(@errorName(err));
        hang();
    };
    console.println("  [ok] vfs + rootfs");

    // 6. Drivers: console, framebuffer, PS/2 keyboard + mouse, storage.
    drivers.init(&boot_info) catch |err| {
        console.print("PANIC: driver init failed: ");
        console.println(@errorName(err));
        hang();
    };
    console.println("  [ok] drivers");

    // The console as something to *read*. Everything that reads it reads it
    // through drivers/stdin.zig -- the line editor there is one editor and
    // not one per caller, because two editors polling the same port would
    // each see half of what was typed.
    //
    // The clock is measured, not the interrupt count: `read(2)` is entered
    // with IF cleared by IA32_FMASK, where `timer.ticks` stands still and a
    // timeout built on it never expires.
    //
    // Two inputs, one editor: `poll_input` below asks the keyboard and then
    // the serial port.
    timer.calibrate(20);
    stdin.init(.{
        .poll = poll_input,
        .echo = console.echo,
        .ticks = timer.centiseconds,
    });
    conread.report_clock();

    console.println("KyanOS ready.");

    // 7. Kernel threads. The context switch had never executed — the call
    //    that would have used it was commented out — so this runs before
    //    anything is built on top of it.
    threadtest.run() catch |err| {
        console.print("PANIC: kernel thread self-test: ");
        console.println(@errorName(err));
        hang();
    };

    // 8. Preemption. The timer had never been started, so nothing had ever
    //    been taken off the CPU against its will.
    preempttest.run() catch |err| {
        console.print("PANIC: preemption self-test: ");
        console.println(@errorName(err));
        hang();
    };

    // 9. The FPU across a context switch. Nothing had ever needed it: the
    //    kernel has no floating point and the first user program did integer
    //    arithmetic, so FXSAVE was absent from the switch and would have
    //    stayed absent until two processes doing arithmetic corrupted each
    //    other in a way nobody could reproduce.
    fputest.run() catch |err| {
        console.print("PANIC: fpu self-test: ");
        console.println(@errorName(err));
        hang();
    };

    // 10. Filesystem. `vfs.resolve` was a stub returning null, so nothing
    //    could open a path and spawn_user could never load an executable.
    fstest.run() catch |err| {
        console.print("PANIC: filesystem self-test: ");
        console.println(@errorName(err));
        hang();
    };

    // 11. The first real process. This supersedes the hand-mapped ring 3
    //    self-test: it enters ring 3 the same way, but from an actual ELF
    //    read out of the filesystem, so it also covers elf.parse, segment
    //    mapping into a fresh address space, and the CR3 switch — none of
    //    which had ever run, because nothing could open a file to reach them.
    //
    //    It returns when the process exits: the thread now has a kernel-side
    //    entry context like any other, so the scheduler dispatches it and
    //    there is somewhere to come back to.
    initprog.run() catch |err| {
        console.print("PANIC: /bin/clarity-init: ");
        console.println(@errorName(err));
        hang();
    };

    // 11a. What that process could see of the kernel at its first
    //    instruction. The answer used to be every general register; this
    //    requires it to be nothing the kernel did not choose.
    regprobe.run();

    // 11b. The first call to fork(2) this kernel has ever served.
    forkprobe.run();

    // And the other half: a parent that sleeps until its child is done. The
    // first system call on this architecture that does not return on the
    // spot.
    waitprobe.run();

    // And the two together: fork, become another program in the child, wait
    // for it, and still be there. Untried on this architecture.
    forkexec.run();

    // 12. The console, read from a program. Descriptor zero was a descriptor
    //    like any other until now: it went to the filesystem, found no inode
    //    and answered EBADF, so nothing a person typed could reach a program.
    readprobe.run();

    // 12a. And a program that does the worst thing it can. Everything above
    //    behaves; this one writes through a null pointer, and what is being
    //    measured is whether anything below it runs at all.
    faultprobe.run();

    // 13. A Clarity program. Everything above this ran code written for the
    //    kernel; this is a Clarity source file compiled to C by
    //    `clarity cc --freestanding`, linked against kernel/user/libc, and
    //    run as a second process — which also means the first one exited and
    //    the kernel carried on, rather than the boot path ending inside it.
    clarityprog.run() catch |err| {
        console.print("PANIC: /bin/clarity-demo: ");
        console.println(@errorName(err));
        hang();
    };

    // 14. And what every one of those crossings had to be true for. Read at
    //    the end because it is a tally of the whole boot, not a test of its
    //    own -- see gsprobe.zig for why it cannot be one.
    // 15. And then a person, if there is one. Everything above is the kernel
    //    asking itself questions; this is the first thing on this
    //    architecture that lets somebody ask it one.
    shell.run();

    gsprobe.run();
    stackprobe.run();

    console.println("KyanOS: userspace complete.");
    hang();
}

fn idle_loop() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

fn hang() noreturn {
    while (true) {
        asm volatile ("cli; hlt");
    }
}

/// The Zig panic handler runs when a programming invariant is
/// violated (slice OOB, integer overflow with checked semantics,
/// `unreachable`, etc). We dump the message, stop scheduling, and
/// halt.
/// The two ways into this machine, in one function because the line editor
/// has one input.
///
/// The keyboard first and the serial port second, in the order a person is
/// more likely to be at -- but each call asks both, so a byte on either never
/// waits for the other to be quiet. A machine with no keyboard attached
/// simply never answers from the first half, which is the headless case and
/// is not a special case here.
fn poll_input() ?u8 {
    if (kbd.poll()) |c| return c;
    return console.serial_poll();
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    console.print("\n\nKERNEL PANIC: ");
    console.println(msg);
    sched.freeze();
    hang();
}
