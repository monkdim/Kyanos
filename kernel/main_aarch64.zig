//! KyanOS aarch64 kernel entry.
//!
//! First milestone of the Apple-Silicon-class AArch64 port: come up at
//! EL1 on QEMU's `virt` machine, bring the PL011 console online, and
//! report a verifiable boot marker over serial.
//!
//! The x86_64 kernel (main.zig) owns the mature path — memory manager,
//! scheduler, syscalls, VFS, drivers. Those subsystems are largely
//! architecture-neutral Zig, but they reach into x86-only pieces today
//! (port I/O, GDT/IDT, 4-level x86 paging), so they are brought across
//! one phase at a time rather than in one risky move. This entry point
//! grows as each is made architecture-clean.

const std = @import("std");
const console = @import("arch/aarch64/console.zig");
const timer = @import("arch/aarch64/timer.zig");
const gic = @import("arch/aarch64/gic.zig");
const mmu = @import("arch/aarch64/mmu.zig");
const ramfb = @import("arch/aarch64/ramfb.zig");
const fwcfg = @import("arch/aarch64/fwcfg.zig");
const fdt = @import("boot/fdt.zig");
const cmdline = @import("boot/cmdline.zig");
const virtio_mmio = @import("arch/aarch64/virtio_mmio.zig");
const virtio_input = @import("arch/aarch64/virtio_input.zig");
const keyboard = @import("arch/aarch64/keyboard.zig");
const line = @import("drivers/line.zig");
const stdin = @import("drivers/stdin.zig");
const vfs = @import("fs/vfs.zig");
const tmpfs = @import("fs/tmpfs.zig");
const fstest = @import("fstest.zig");
const pmm = @import("mm/pmm.zig");
const vm = @import("arch/aarch64/vm.zig");
const paging = @import("arch/aarch64/paging.zig");
const trap = @import("arch/aarch64/trap.zig");
const threadtest = @import("threadtest_aarch64.zig");
const sched = @import("sched/sched_aarch64.zig");
const schedtest = @import("schedtest_aarch64.zig");
const proctest = @import("proctest_aarch64.zig");
const heap = @import("mm/heap.zig");
const loader = @import("loader/load_aarch64.zig");
const fb = @import("graphics/fb.zig");
const text = @import("graphics/console.zig");

/// Entry point called by the boot stub (arch/aarch64/boot.S) once the CPU
/// is at EL1 with a stack and a zeroed .bss. `dtb_phys` is the device tree
/// pointer QEMU leaves in x0; recorded now, consumed by the memory phase.
export fn kernel_main_aarch64(dtb_phys: u64) callconv(.C) noreturn {
    console.init();
    console.println("KyanOS aarch64 micro-kernel starting...");
    console.println("  [ok] EL1 + PL011 UART");

    install_vectors();
    console.println("  [ok] exception vectors (VBAR_EL1)");

    // Translation was turned on by the boot stub, before this function could
    // run at all: the kernel is linked for the high half, so there is no
    // address at which this code could execute untranslated. Reaching this
    // line at a high program counter is the evidence that the table the stub
    // built, the device attributes covering the UART, and the branch into the
    // high mapping are all correct.
    mmu.report();

    // Stop translating the low half. Everything below this line — the device
    // tree, fw_cfg, the framebuffer, every page the allocator returns — is
    // reached through the kernel's direct map, and dropping the identity map
    // here rather than at the end of boot is what makes that a claim the
    // machine checks instead of one this file asserts. A single missed
    // conversion is now a translation fault at the point of the mistake.
    //
    // It is also the point of the exercise: TTBR0 is the register the
    // hardware switches per process, and it is now free for userland.
    mmu.drop_identity();
    address_space_selftest();

    // What kind of machine is this? On x86 the firmware answers with a
    // multiboot2 block; here the answer is a device tree, whose address the
    // bootloader left in x0 — a physical one, which is now a number this
    // kernel cannot dereference until it says where that memory appears.
    const tree = describe_machine(dtb_phys);

    // And what was it told to do? Everything above this line the kernel
    // worked out for itself; this is the one thing it can only be handed.
    cmdline.init(tree);
    report_command_line();

    // Which interrupt controller this machine has, before anything programs
    // one. Read from the tree rather than assumed: the emulated cortex-a72
    // path gets a GICv2, and a Mac running this accelerated gets a GICv3
    // because HVF emulates nothing else.
    gic.detect(tree);
    report_interrupt_controller();

    timer.init(100);
    console.print("  [ok] generic timer armed at 100 Hz, cntfrq=");
    console.print_dec(timer.frequency());
    console.println("");

    timer_selftest();

    // Physical memory. Nothing on this architecture could allocate a page
    // before this: the kernel had no idea where RAM was.
    memory_selftest(tree, dtb_phys);

    // A kernel heap, over the page allocator. Nothing on this architecture
    // needed one until something had to parse an ELF.
    heap.init();

    // A process table, over that heap. Nothing on this architecture had one:
    // a program was loaded, entered and released, and the ASID it ran under
    // was a literal at the call site. From here a program is a process with
    // a PID, a parent and an ASID that was allocated rather than chosen.
    sched.init_processes();

    // A filesystem. The first subsystem to arrive here already written:
    // fs/vfs.zig and fs/tmpfs.zig import std, the heap, and each other, and
    // needed no change at all to run on this machine. The selftest below is
    // the same file the x86_64 kernel runs, which is why it is worth saying
    // — a port that shares its code and a port that has a second copy of it
    // look identical from a boot log.
    filesystem_selftest();

    // A process's address space — built, installed, questioned, and taken
    // apart again. Nothing runs in it yet; that it can exist at all is what
    // moving the kernel out of TTBR0 was for.
    process_space_selftest();

    // And now something runs inside one. This is the line the whole aarch64
    // port has been walking towards: code executing at EL0, in its own
    // address space, trapping into the kernel and being answered.
    userland_selftest();

    // More than one thread. Cooperatively first, then with the timer taking
    // the CPU away from a thread that never offers it.
    threadtest.run();

    // And then a scheduler over the top of that primitive: run queues,
    // priorities, threads that finish and are reclaimed. Everything above
    // switches between two contexts that the test itself names; from here
    // on, which thread runs next is a decision the kernel makes.
    schedtest.run();

    // And the other half of "what is running": a process table. The
    // scheduler above says which thread has the CPU; this says whose it is.
    proctest.run();

    // A screen, and then a console on it.
    //
    // Before this everything the kernel said went out a serial line. From the
    // next line on it also appears on the display — which is why this happens
    // here and not at the end: a boot log that is only shown after the boot
    // has finished is a screenshot, not a console.
    screen_selftest();
    open_screen_console();

    // A keyboard. Nothing on this architecture could read one: QEMU's `virt`
    // has no PS/2 controller, which is also true of the hardware this is
    // aimed at, so the way in is the virtio bus rather than a port.
    input_selftest(tree);

    // And finally a program that was compiled and linked rather than
    // assembled into this image.
    init_program();

    // And then a Clarity program, through the same path.
    demo_program();

    // And last, a shell — the first program on this machine that is told what
    // to do rather than deciding for itself. It runs after everything else
    // because it is the thing a person would still be sitting in front of;
    // the boot has nothing left to say by then.
    shell_program();

    // How the keyboard was actually serviced, once nothing else is going to
    // touch it. Printed here rather than after the input selftest because
    // most of the typing happens after that — at the init program's prompt
    // and at the shell — and a count taken before it would say nothing about
    // the case this is here for.
    keyboard_report();

    // Every program the boot ran was a process, and every one of them has
    // ended. What should be left is init and nothing else, with no ASID
    // outstanding — which is the check that makes those PIDs mean something
    // rather than decorate a log line. A program that exits without giving
    // its ASID back is invisible until the 256th one is refused; here it is
    // one line.
    proctest.check_drained();

    console.println("KyanOS aarch64: EL1 boot ok");

    hang();
}

// The EL0 probe, assembled in arch/aarch64/user.S and living in .rodata: from
// the kernel's side it is data to be copied into a process's page, not code to
// be run here.
extern const __user_probe_start: u8;
extern const __user_probe_end: u8;
extern const __user_fault_start: u8;
extern const __user_fault_end: u8;

/// Where the probe's pages go in its own address space. These numbers are
/// also written into the probe itself — it loads from USER_DATA and stores to
/// USER_TEXT by absolute address — so the two have to agree, and there is no
/// mechanism yet (no ELF loader on this architecture) that would let them
/// agree by construction.
const USER_TEXT: u64 = 0x0040_0000;
const USER_DATA: u64 = 0x1000_0000;
const USER_STACK_TOP: u64 = 0x2000_0000;

/// The value the kernel leaves in the process's data page. The program reads
/// it, adds one, writes it back, and exits with it — so one number has to
/// survive a read from the process's own memory, a preemption, a write, and
/// the exit status, and the kernel checks it at both ends.
const SEED: u64 = 41;

/// How long the probe's greeting is. Written here and in user.S, because
/// there is nothing yet that could let one derive it from the other — an ELF
/// loader would, and does not exist on this architecture.
const MESSAGE_LEN: u64 = 26;

/// Run a program at EL0.
///
/// Everything before this has been the kernel talking about itself. This is
/// the first code on this architecture that runs *without* the privilege to
/// do what it likes, in an address space that is not the kernel's, and gets
/// back into the kernel only through the door the kernel opened.
///
/// The probe is entered twice, deliberately. The first run ends with a system
/// call, which is the path a program takes; the second ends with a fault,
/// which is the path a program takes when it is wrong. A kernel that can only
/// do the first has no way to survive the second, and re-entering EL0 after a
/// fault is what shows the kernel really got the CPU back rather than
/// stumbling on.
fn userland_selftest() void {
    if (pmm.stats().total_pages == 0) {
        console.println("  [--] no physical memory; EL0 not exercised");
        return;
    }

    var space = paging.create(2) orelse {
        console.println("  [FAIL] EL0: no root table");
        return;
    };

    const text_phys = pmm.alloc_page() orelse {
        console.println("  [FAIL] EL0: no page for text");
        return;
    };
    const data_phys = pmm.alloc_page() orelse {
        console.println("  [FAIL] EL0: no page for data");
        return;
    };
    const stack_phys = pmm.alloc_page() orelse {
        console.println("  [FAIL] EL0: no page for a stack");
        return;
    };

    // Copy the probe into the process's text page, through the direct map —
    // never through the user mapping, which PSTATE.PAN may refuse.
    const blob_start = @intFromPtr(&__user_probe_start);
    const blob_len = @intFromPtr(&__user_fault_end) - blob_start;
    const fault_offset = @intFromPtr(&__user_fault_start) - blob_start;
    const src: [*]const u8 = @ptrCast(&__user_probe_start);
    const dst: [*]u8 = vm.ptr_to_phys([*]u8, text_phys);
    var i: usize = 0;
    while (i < blob_len) : (i += 1) dst[i] = src[i];

    // Those were stores, and EL0 is about to fetch instructions from them.
    // The two go through different caches.
    mmu.sync_instructions(@intFromPtr(dst), blob_len);

    const seed_cell = vm.ptr_to_phys(*volatile u64, data_phys);
    seed_cell.* = SEED;

    paging.map_page(&space, USER_TEXT, text_phys, paging.MAP_USER | paging.MAP_EXEC) catch {
        console.println("  [FAIL] EL0: could not map text");
        return;
    };
    paging.map_page(&space, USER_DATA, data_phys, paging.MAP_USER | paging.MAP_WRITE) catch {
        console.println("  [FAIL] EL0: could not map data");
        return;
    };
    paging.map_page(&space, USER_STACK_TOP - pmm.PAGE_SIZE, stack_phys, paging.MAP_USER | paging.MAP_WRITE) catch {
        console.println("  [FAIL] EL0: could not map a stack");
        return;
    };

    paging.activate(&space);

    // ── Run one: a program that works ───────────────────────────────────
    console.println("  -- below this line, EL0 is speaking through write(2) --");
    trap.reset();
    const exit_a = trap.enter_user(USER_TEXT, USER_STACK_TOP);
    const answer = trap.exit_status;
    const written = trap.bytes_written;
    const calls = trap.calls;
    // What EL0 stored, read back through the kernel's own map: proof the
    // write landed in the physical page rather than somewhere that merely
    // looked right from EL0.
    const written_back = seed_cell.*;
    const preempted = trap.ticks_leaving - trap.ticks_entering;

    // ── Run two: a program that is wrong ────────────────────────────────
    // It stores to its own text page, which is mapped read-only for EL0.
    trap.reset();
    const exit_b = trap.enter_user(USER_TEXT + fault_offset, USER_STACK_TOP);
    const fault = trap.last_fault;
    // 0xDEAD is what the probe exits with if its illegal store was allowed.
    const store_allowed = trap.exit_status;

    paging.deactivate();

    // Is the kernel still a working kernel?
    //
    // Taking an exception from EL0 masks interrupts, and the way back out of
    // one is `ret`, not `eret` — so unless something puts DAIF back, the
    // kernel returns from a process with its timer switched off and no sign
    // of it until the next thing that needs to be scheduled. Bounded in spins
    // rather than in time, for the same reason the boot timer test is: a
    // deadline in ticks would wait forever for exactly the thing whose
    // absence it is checking.
    const ticks_before = timer.ticks();
    var spins: u64 = 0;
    while (timer.ticks() == ticks_before and spins < 100_000_000) : (spins += 1) {
        asm volatile ("nop");
    }
    const still_ticking = timer.ticks() > ticks_before;

    const ran_ok = exit_a == trap.EXIT_DONE and
        calls == 2 and
        written == MESSAGE_LEN and
        answer == SEED + 1 and
        written_back == SEED + 1 and
        preempted > 0;

    const caught_ok = exit_b == trap.EXIT_FAULT and
        fault != null and
        fault.?.ec == trap.EC_DATA_ABORT and
        fault.?.far == USER_TEXT and
        fault.?.elr >= USER_TEXT and fault.?.elr < USER_TEXT + pmm.PAGE_SIZE;

    if (ran_ok and caught_ok and still_ticking) {
        console.print("  [ok] EL0: a program wrote ");
        console.print_dec(written);
        console.print(" bytes through write(2), read ");
        console.print_dec(SEED);
        console.print(" from its own memory, and exited with ");
        console.print_dec(answer);
        console.println(" — which the kernel found in the page it had left it");
        console.print("  [ok] EL0: the timer interrupted it ");
        console.print_dec(preempted);
        console.println(" times while it ran, and it carried on afterwards");
        console.print("  [ok] EL0: and when it wrote to its read-only text at ");
        console.print_hex(USER_TEXT);
        console.println(", the kernel took the CPU back — and still had its own timer");
    } else {
        console.print("  [FAIL] EL0: exit_a=");
        console.print_dec(exit_a);
        console.print(" calls=");
        console.print_dec(calls);
        console.print(" written=");
        console.print_dec(written);
        console.print(" answer=");
        console.print_dec(answer);
        console.print(" written_back=");
        console.print_dec(written_back);
        console.print(" ticks_while_running=");
        console.print_dec(preempted);
        console.print(" exit_b=");
        console.print_dec(exit_b);
        console.print(" fault_probe_exit=");
        console.print_hex(store_allowed);
        console.print(" still_ticking=");
        console.print_dec(@intFromBool(still_ticking));
        console.println("");
        if (fault) |f| trap.report_fault(f) else console.println("    no fault recorded");
    }

    paging.unmap_page(&space, USER_TEXT);
    paging.unmap_page(&space, USER_DATA);
    paging.unmap_page(&space, USER_STACK_TOP - pmm.PAGE_SIZE);
    pmm.free_page(text_phys);
    pmm.free_page(data_phys);
    pmm.free_page(stack_phys);
    paging.destroy(&space);
}

/// Build a process's low half, install it, and ask the hardware what it did.
///
/// Every claim here is answered by the MMU rather than by reading back a
/// descriptor this code just wrote: `at s1e0r` and `at s1e0w` run real
/// stage-1 translations with EL0 permissions. Reading the table back would
/// only prove the store landed, which was never in doubt.
///
/// The data page is filled through the *direct map* and never through the
/// user address, which is not fastidiousness: PSTATE.PAN makes an EL1 access
/// to EL0-accessible memory fault on any core that implements it, so a kernel
/// that populated a process's memory through the process's own addresses
/// would work on some machines and not others.
fn process_space_selftest() void {
    if (pmm.stats().total_pages == 0) {
        console.println("  [--] no physical memory; process address space not exercised");
        return;
    }

    const before = pmm.stats();

    var space = paging.create(1) orelse {
        console.println("  [FAIL] address space: could not allocate a root table");
        return;
    };

    const backing = pmm.alloc_page() orelse {
        console.println("  [FAIL] address space: no page to back the mapping");
        return;
    };
    const MAGIC: u64 = 0xA11C_1747_0000_0001;
    const cell = vm.ptr_to_phys(*volatile u64, backing);
    cell.* = MAGIC;

    // Somewhere a process would plausibly be, and far from anything the
    // kernel uses — the point of a separate address space is that this
    // number means nothing in the kernel's own.
    const UVA: u64 = 0x0000_0000_1000_0000;

    paging.map_page(&space, UVA, backing, paging.MAP_USER | paging.MAP_WRITE) catch |e| {
        console.print("  [FAIL] address space: map_page said ");
        console.println(@errorName(e));
        return;
    };

    // Building a space is not entering it. Until `activate`, the address is
    // still nothing at all — if this translated, the mapping would be leaking
    // into whatever address space happens to be current.
    const before_activate = mmu.translate_user_read(UVA);

    // A second page, mapped read-only and executable — a process's text.
    // Presence is the easy half of a page table; permissions are the half
    // that decides whether a process can write over its own code, and the
    // only way to see the difference is to ask for a write translation and
    // be refused.
    const text_backing = pmm.alloc_page() orelse {
        console.println("  [FAIL] address space: no page to back the text mapping");
        return;
    };
    const TEXT_UVA: u64 = 0x0000_0000_0040_0000;
    paging.map_page(&space, TEXT_UVA, text_backing, paging.MAP_USER | paging.MAP_EXEC) catch |e| {
        console.print("  [FAIL] address space: text map_page said ");
        console.println(@errorName(e));
        return;
    };

    paging.activate(&space);
    const user_r = mmu.translate_user_read(UVA);
    const user_w = mmu.translate_user_write(UVA);
    const text_r = mmu.translate_user_read(TEXT_UVA);
    const text_w = mmu.translate_user_write(TEXT_UVA);

    // The kernel has to survive the switch. It is in TTBR1 and the process is
    // in TTBR0, so it should — but "should" is what the UART is for.
    const kernel_survived = mmu.translate(vm.phys_to_virt(0x0900_0000));

    // What the tables say, walked without the MMU. Answers for a space that
    // is not installed, which is how a process's memory gets inspected.
    const table_says = paging.lookup(&space, UVA);

    paging.unmap_page(&space, UVA);
    paging.unmap_page(&space, TEXT_UVA);
    const after_unmap = mmu.translate_user_read(UVA);

    paging.deactivate();
    const after_deactivate = mmu.translate_user_read(UVA);

    // The data is still there. If a page table had been allocated on top of
    // it — the mistake that makes a process corrupt its own memory — this is
    // where it shows.
    const held = cell.* == MAGIC;

    pmm.free_page(backing);
    pmm.free_page(text_backing);
    paging.destroy(&space);
    const after = pmm.stats();

    const ok = before_activate == null and
        user_r != null and user_r.? == backing and
        user_w != null and user_w.? == backing and
        text_r != null and text_r.? == text_backing and
        text_w == null and
        table_says != null and table_says.? == backing and
        kernel_survived != null and kernel_survived.? == 0x0900_0000 and
        after_unmap == null and
        after_deactivate == null and
        held and
        after.free_pages == before.free_pages;

    if (ok) {
        console.print("  [ok] process address space: ");
        console.print_hex(UVA);
        console.print(" -> ");
        console.print_hex(backing);
        console.print(" for EL0 read and write, ");
        console.print_hex(TEXT_UVA);
        console.print(" read-only (a write there faults), kernel unaffected, ");
        console.println("unmapped and torn down with every page returned");
    } else {
        console.print("  [FAIL] process address space: pre=");
        console.print_hex(before_activate orelse 0);
        console.print(" r=");
        console.print_hex(user_r orelse 0);
        console.print(" w=");
        console.print_hex(user_w orelse 0);
        console.print(" text_r=");
        console.print_hex(text_r orelse 0);
        console.print(" text_w=");
        console.print_hex(text_w orelse 0);
        console.print(" table=");
        console.print_hex(table_says orelse 0);
        console.print(" kernel=");
        console.print_hex(kernel_survived orelse 0);
        console.print(" unmapped=");
        console.print_hex(after_unmap orelse 0);
        console.print(" off=");
        console.print_hex(after_deactivate orelse 0);
        console.print(" held=");
        console.print_dec(@intFromBool(held));
        console.print(" pages ");
        console.print_dec(before.free_pages);
        console.print("->");
        console.print_dec(after.free_pages);
        console.println("");
    }
}

/// The aarch64 /bin/clarity-init, embedded by build.zig. A real ELF, from a
/// compiler and a linker.
const INIT_ELF = @embedFile("init_elf_aarch64");

/// /bin/clarity-demo: a Clarity program, compiled to C by
/// `clarity cc --freestanding` and linked against kernel/user/libc. The same
/// generated C the x86_64 side runs — nothing in it knows which machine it is
/// for.
const DEMO_ELF = @embedFile("demo_elf_aarch64");
const SH_ELF = @embedFile("sh_elf_aarch64");

/// Load that ELF into a fresh address space and run it.
///
/// Everything the probe above proves, this proves again without the kernel
/// having chosen any of it. The probe's layout was the kernel's: one page of
/// code at an address main_aarch64.zig picked, with the same file writing
/// both ends of the agreement. Here a linker decided there would be three
/// segments, which permissions each has, and that the last one's memory size
/// exceeds its file size — and the loader had to be right about all of it
/// without being told.
fn init_program() void {
    if (pmm.stats().total_pages == 0) {
        console.println("  [--] no physical memory; /bin/clarity-init not loaded");
        return;
    }

    console.print("  init: ");
    console.print_dec(INIT_ELF.len);
    console.println(" bytes of ELF, embedded in the kernel image");

    // Twice, in two different address spaces.
    //
    // Once would leave two things unproven. The page accounting cannot
    // balance across a first load, because parsing the ELF is the first thing
    // on this architecture ever to use the kernel heap and the slab keeps the
    // page it took — a real allocation that is not a leak. Measuring across
    // the *second* load separates the two: the heap is warm, so anything
    // missing at the end is the loader's.
    //
    // And a loader that works once is not a loader. The second run gets its
    // own address space with its own ASID, over frames the first one just
    // returned, which is what every load after the first will be.
    const first = run_init(true);
    const before = pmm.stats();
    const second = run_init(false);
    const after = pmm.stats();

    const balanced = after.free_pages == before.free_pages;

    if (first.ok and second.ok and balanced) {
        console.print("  [ok] init: a compiled, linked ELF ran at EL0 twice, printed ");
        console.print_dec(first.wrote);
        console.print(" bytes, exited ");
        console.print_dec(first.code);
        console.println(" each time, and every page came back");
    } else {
        console.print("  [FAIL] init: first(ok=");
        console.print_dec(@intFromBool(first.ok));
        console.print(" status=");
        console.print_dec(first.status);
        console.print(" code=");
        console.print_dec(first.code);
        console.print(" wrote=");
        console.print_dec(first.wrote);
        console.print(") second(ok=");
        console.print_dec(@intFromBool(second.ok));
        console.print(" status=");
        console.print_dec(second.status);
        console.print(" code=");
        console.print_dec(second.code);
        console.print(") pages ");
        console.print_dec(before.free_pages);
        console.print("->");
        console.print_dec(after.free_pages);
        console.println("");
        if (trap.last_fault) |f| trap.report_fault(f);
    }
}

/// Run the compiled Clarity program.
///
/// Everything under it is what makes this the interesting one: a Clarity
/// source file, through `clarity cc --freestanding` to C, through clang to
/// aarch64, linked against a C library whose printf, malloc, qsort, strtod
/// and floating-point code are the same source the x86_64 side runs — and
/// whose three architecture-specific pieces, the system call stubs, the entry
/// point and setjmp, now have an AArch64 half.
/// Run the shell.
///
/// Nothing here is different from loading any other program — same loader,
/// same address space, same four system calls. What is different is that it
/// does not finish on its own: it reads until its input ends, which on a
/// machine with nobody at the keyboard is a few seconds and then a clean
/// exit. That is what a shell does when its input closes, and it is also
/// what keeps a boot nobody is watching from stopping here forever.
///
/// Its own output is the evidence. The kernel checks only that it started,
/// ended by choice, and wrote something; what it *said* is between it and
/// whoever typed, and tools/key_check.py is what reads that back.
fn shell_program() void {
    if (pmm.stats().total_pages == 0) return;
    if (!stdin.present()) {
        console.println("  [--] shell: nothing to read from, so nothing could be typed at it");
        return;
    }

    console.print("  shell: ");
    console.print_dec(SH_ELF.len);
    console.println(" bytes; it ends when the input does");

    const sh_asid = claim_asid("shell") orelse return;
    var proc = loader.load(SH_ELF, sh_asid, heap.allocator()) catch |e| {
        console.print("  [FAIL] shell: could not load: ");
        console.println(@errorName(e));
        sched.free_asid(sh_asid);
        return;
    };
    const sh_proc = begin_process("shell", proc.space, proc.brk_start);

    paging.activate(&proc.space);
    trap.reset();
    trap.set_heap(&proc.space, proc.brk_start);
    const status = trap.enter_user(proc.entry, proc.user_sp);
    const code = trap.exit_status;
    const wrote = trap.bytes_written;
    const heap_end = trap.heap_end();
    trap.clear_heap();
    paging.deactivate();
    loader.release(&proc, heap_end);
    if (sh_proc) |sp| sched.exit_process(sp, @intCast(code)) else sched.free_asid(sh_asid);

    if (status == trap.EXIT_DONE and wrote > 0) {
        console.print("  [ok] shell: ran at EL0, read its own input, wrote ");
        console.print_dec(wrote);
        console.print(" bytes and exited ");
        console.print_dec(code);
        console.println("");
    } else {
        console.print("  [FAIL] shell: status=");
        console.print_dec(status);
        console.print(" code=");
        console.print_dec(code);
        console.print(" wrote=");
        console.print_dec(wrote);
        console.println("");
        if (trap.last_fault) |f| trap.report_fault(f);
    }
}

///
/// It checks itself and says so. The kernel checks that it said so by its
/// exit status, and CI checks the line where it reports the doubles it
/// computed, because that is the part that would still print something
/// plausible if the floating-point path were subtly wrong.
fn demo_program() void {
    if (pmm.stats().total_pages == 0) return;

    console.print("  demo: ");
    console.print_dec(DEMO_ELF.len);
    console.println(" bytes of Clarity, compiled to C and then to this machine");

    const demo_asid = claim_asid("demo") orelse return;
    var proc = loader.load(DEMO_ELF, demo_asid, heap.allocator()) catch |e| {
        console.print("  [FAIL] demo: could not load: ");
        console.println(@errorName(e));
        sched.free_asid(demo_asid);
        return;
    };
    const demo_proc = begin_process("demo", proc.space, proc.brk_start);

    paging.activate(&proc.space);
    trap.reset();
    trap.set_heap(&proc.space, proc.brk_start);
    const status = trap.enter_user(proc.entry, proc.user_sp);
    const code = trap.exit_status;
    const wrote = trap.bytes_written;
    const heap_used = trap.heap_end() - proc.brk_start;
    const heap_end = trap.heap_end();
    trap.clear_heap();
    paging.deactivate();
    loader.release(&proc, heap_end);
    if (demo_proc) |dp| sched.exit_process(dp, @intCast(code)) else sched.free_asid(demo_asid);

    if (status == trap.EXIT_DONE and code == 0 and wrote > 0) {
        console.print("  [ok] demo: a Clarity program ran on aarch64, printed ");
        console.print_dec(wrote);
        console.print(" bytes and used ");
        console.print_dec(heap_used >> 10);
        console.println(" KiB of heap");
    } else {
        console.print("  [FAIL] demo: status=");
        console.print_dec(status);
        console.print(" code=");
        console.print_dec(code);
        console.print(" wrote=");
        console.print_dec(wrote);
        console.println("");
        if (trap.last_fault) |f| trap.report_fault(f);
    }
}

/// Claim an ASID for a program about to be loaded, and say so if there is
/// none left.
///
/// Every program on this machine used to be loaded under a number written at
/// the call site — 3 and 4 for the two init runs, 5 for the demo, 7 for the
/// shell. They did not collide, but nothing made them not collide: the
/// numbers were chosen by whoever added the line, and two programs alive at
/// once under one ASID each see the other's cached translations.
fn claim_asid(what: []const u8) ?u16 {
    return sched.alloc_asid() orelse {
        console.print("  [FAIL] ");
        console.print(what);
        console.println(": no ASID left — the pool is 255 deep");
        return null;
    };
}

/// Register a loaded image as a process whose parent is init, and print what
/// it was given. Returns null having said so if the table refused.
fn begin_process(name: []const u8, space: paging.AddressSpace, brk_start: u64) ?*sched.Process {
    const p = sched.register_process(name, space, 1, brk_start) orelse {
        console.print("  [FAIL] ");
        console.print(name);
        console.println(": the process table refused it");
        return null;
    };
    console.print("  ");
    console.print(name);
    console.print(": pid ");
    console.print_dec(@intCast(p.pid));
    console.print(", asid ");
    console.print_dec(space.asid);
    console.println("");
    return p;
}

const InitRun = struct {
    ok: bool = false,
    status: u64 = 0,
    code: u64 = 0,
    wrote: u64 = 0,
};

/// One load, run and teardown. `announce` prints where the linker put things,
/// which is worth seeing once and not twice.
fn run_init(announce: bool) InitRun {
    const asid = claim_asid("init") orelse return .{};
    var proc = loader.load(INIT_ELF, asid, heap.allocator()) catch |e| {
        console.print("  [FAIL] init: could not load the ELF: ");
        console.println(@errorName(e));
        sched.free_asid(asid);
        return .{};
    };
    const ip = begin_process("init", proc.space, proc.brk_start);

    if (announce) {
        console.print("  init: entry ");
        console.print_hex(proc.entry);
        console.print(", stack ");
        console.print_hex(proc.user_sp);
        console.print(", ");
        console.print_dec(proc.range_count);
        console.print(" mapped ranges, heap from ");
        console.print_hex(proc.brk_start);
        console.println("");
    }

    paging.activate(&proc.space);
    trap.reset();
    trap.set_heap(&proc.space, proc.brk_start);
    const status = trap.enter_user(proc.entry, proc.user_sp);
    const wrote = trap.bytes_written;
    const code = trap.exit_status;
    const heap_end = trap.heap_end();
    trap.clear_heap();
    paging.deactivate();
    loader.release(&proc, heap_end);
    if (ip) |p| sched.exit_process(p, @intCast(code)) else sched.free_asid(asid);

    // 42 is what init_aarch64.zig exits with, and it only reaches that line
    // after its own .bss, .data and floating-point checks. Those print their
    // own verdicts above, so a failure here says which step it was.
    return .{
        .ok = status == trap.EXIT_DONE and code == 42 and wrote > 0,
        .status = status,
        .code = code,
        .wrote = wrote,
    };
}

/// Ask the translation hardware what the address space actually looks like.
///
/// Setting TCR_EL1.EPD0 and reading it back proves only that the write
/// landed. `at s1e1w` runs a real stage-1 translation and reports what came
/// out, so the three claims below are answered by the MMU rather than by this
/// file: the low half no longer translates, the high half does, and it maps
/// where the linker script says it maps.
///
/// The UART is the address to ask about, because it is the one this kernel is
/// printing through — if its high mapping were wrong there would be no
/// message, and if its low mapping still worked the whole exercise would be
/// pointless.
fn address_space_selftest() void {
    const uart_phys: u64 = 0x0900_0000;
    const low = mmu.translate(uart_phys);
    const high = mmu.translate(vm.phys_to_virt(uart_phys));

    if (low == null and high != null and high.? == uart_phys) {
        console.print("  [ok] identity map dropped: ");
        console.print_hex(uart_phys);
        console.print(" no longer translates, ");
        console.print_hex(vm.phys_to_virt(uart_phys));
        console.print(" -> ");
        console.print_hex(high.?);
        console.println("; TTBR0 is free for userland");
    } else {
        console.print("  [FAIL] address space: low=");
        console.print_hex(low orelse 0);
        console.print(" high=");
        console.print_hex(high orelse 0);
        console.print(" tcr.EPD0=");
        console.print_dec(if (mmu.identity_dropped()) 1 else 0);
        console.println("");
    }
}

/// The vector table lives in vectors.S, 2 KiB-aligned as VBAR_EL1 requires.
extern const aarch64_vectors: u8;

const SCREEN_W: u32 = 1024;
const SCREEN_H: u32 = 768;

/// Where the four colour patches sit. Named here so the pattern that draws
/// them and the check that reads them back cannot drift apart, and so the CI
/// step that inspects a screenshot has coordinates to name.
const PATCH: u32 = 120;
const PATCH_Y: u32 = 240;
const PATCH_X = [_]u32{ 112, 288, 464, 640 };
const PATCH_COLOUR = [_]u32{ fb.RED, fb.GREEN, fb.BLUE, fb.WHITE };

/// One past the last byte of usable RAM, once the device tree has been read.
/// Zero means it is not known yet, in which case nothing may assume a fixed
/// address is real memory.
var ram_end: u64 = 0;

/// Bring up the display and prove something is really on it.
///
/// Reading the pixels back is the part that matters. Writing to memory proves
/// only that the memory is writable — the question is whether that memory is
/// the screen, and whether the machine agreed to scan it out. The read-back
/// answers the first half; the screenshot CI takes answers the second, and
/// neither is redundant.
fn screen_selftest() void {
    // The framebuffer sits at a fixed address chosen before this kernel could
    // ask how much RAM the machine has. Now it can — and on a machine small
    // enough that the address is past the end of memory, configuring ramfb
    // would point the display at nothing and the writes below would go
    // nowhere. Refusing is a message; carrying on is a picture of noise.
    const fb_bytes: u64 = @as(u64, SCREEN_W) * SCREEN_H * 4;
    if (ram_end != 0 and ramfb.FB_PHYS + fb_bytes > ram_end) {
        console.print("  [--] framebuffer wants ");
        console.print_hex(ramfb.FB_PHYS);
        console.print("..");
        console.print_hex(ramfb.FB_PHYS + fb_bytes);
        console.print(" but RAM ends at ");
        console.print_hex(ram_end);
        console.println("; running headless");
        return;
    }

    const surf_info = ramfb.init(SCREEN_W, SCREEN_H) orelse {
        // Not a failure of this code: it means QEMU was started without
        // `-device ramfb`, and the kernel carries on headless as before.
        console.println("  [--] no ramfb on this machine; running headless");
        return;
    };

    const s = fb.Surface{
        .base = surf_info.base,
        .width = surf_info.width,
        .height = surf_info.height,
        .stride = surf_info.stride,
    };

    s.clear(fb.SLATE);
    s.frame(0, 0, SCREEN_W, SCREEN_H, 8, fb.SIGNAL);
    for (PATCH_X, PATCH_COLOUR) |x, colour| {
        s.fill(x, PATCH_Y, PATCH, PATCH, colour);
    }

    // Read back the centre of each patch, plus one pixel of the border and
    // one of the background, so a surface that came up entirely one colour
    // fails rather than passes.
    var ok = true;
    for (PATCH_X, PATCH_COLOUR) |x, colour| {
        if (s.get(x + PATCH / 2, PATCH_Y + PATCH / 2) != colour) ok = false;
    }
    if (s.get(4, 4) != fb.SIGNAL) ok = false;
    if (s.get(SCREEN_W / 2, SCREEN_H - 64) != fb.SLATE) ok = false;

    if (ok) {
        live_surface = s;
        console.print("  [ok] framebuffer: ");
        console.print_dec(SCREEN_W);
        console.print("x");
        console.print_dec(SCREEN_H);
        console.print(" at ");
        console.print_hex(surf_info.base);
        console.println(", pattern reads back correct");
    } else {
        console.println("  [FAIL] framebuffer: wrote a pattern, read back something else");
    }
}

/// Mount a root filesystem and prove a path resolves.
///
/// Needs the heap, so it runs after heap.init(). Everything it exercises —
/// resolution, create, write, read back, directory listing — is code the
/// x86_64 kernel has been running since long before this architecture could
/// allocate a page, and none of it needed changing.
fn filesystem_selftest() void {
    vfs.init();
    tmpfs.mount_root() catch |e| {
        console.print("  [FAIL] vfs: could not mount a root: ");
        console.println(@errorName(e));
        return;
    };
    fstest.run() catch |e| {
        console.print("  [FAIL] vfs: ");
        console.println(@errorName(e));
        return;
    };
}

/// The next character from anything that can produce one.
///
/// Two sources now: the keyboard, and the serial line. The keyboard is asked
/// first, and not arbitrarily — it is the one with a queue that fills. The
/// UART holds its own bytes in a sixteen-deep FIFO and a person types slower
/// than that, so a byte waiting there will still be waiting next time.
///
/// Either may be absent and neither says so: `keyboard.poll` answers null on
/// a machine with no keyboard, and a serial port with nothing typed at it is
/// indistinguishable from one nobody is connected to. That is the point —
/// whoever is reading does not care which of them a character came from.
fn poll_input() ?u8 {
    if (keyboard.poll()) |c| return c;
    return console.poll_in();
}

/// Bring up what can be typed on, and read a few lines of it.
///
/// The keyboard's bus slots come from the device tree — thirty-two of them on
/// `virt`, identical, with whatever is in each discoverable only by reading
/// its registers. Hardcoding 0x0a000000 and a stride of 0x200 would work on
/// this machine and nowhere else.
///
/// The serial line needs no finding: the console has been writing to it since
/// the first line of the boot, and reading from it is the same registers in
/// the other direction. It is also the reason none of the keyboard failures
/// below return early any more. They used to, and the effect was that a
/// machine with no keyboard had no input at all — which on a Mac, where the
/// graphical window is awkward to type into and the terminal is not, meant an
/// operating system that could be watched and not used.
///
/// Reading is checked two ways, because there are two paths: tools/key_check.py
/// sends keys through QEMU's monitor to the virtio keyboard, and
/// tools/serial_check.py types down the serial socket. Either alone would
/// leave the other able to break silently.
fn input_selftest(tree: ?fdt.Fdt) void {
    serial_setup(tree);
    keyboard_setup(tree);
    read_some_lines();
}

/// Give the serial line its interrupt.
///
/// The console has been printing since before the device tree was read — it
/// has to, or a machine with no tree could not say so — so its own address is
/// a constant. Its *interrupt* is not: the INTID is in the tree, and until now
/// nothing read it, so the port was polled and nothing emptied its FIFO while
/// the kernel was busy. See `console.poll_in` for what that is worth in
/// practice, which is less than it sounds under QEMU and was measured.
fn serial_setup(tree: ?fdt.Fdt) void {
    const t = tree orelse {
        console.println("  [--] no device tree; the serial line stays polled");
        return;
    };

    var slots: [2]fdt.Slot = undefined;
    const n = fdt.node_slots(&t, "pl011@", &slots);
    if (n == 0) {
        console.println("  [--] no pl011 in the device tree; the serial line stays polled");
        return;
    }
    const id = slots[0].intid orelse {
        console.println("  [--] pl011 has no usable interrupts property; the serial line stays polled");
        return;
    };

    console.route(id);
    console.print("  [ok] serial: receive interrupt ");
    console.print_dec(id);
    console.println(" routed to this core");
}

fn keyboard_setup(tree: ?fdt.Fdt) void {
    const t = tree orelse {
        console.println("  [--] no device tree; no virtio bus to look on");
        return;
    };

    var slots: [40]fdt.Slot = undefined;
    const n = fdt.node_slots(&t, "virtio_mmio@", &slots);
    if (n == 0) {
        console.println("  [--] no virtio-mmio slots in the device tree");
        return;
    }

    var bases: [40]u64 = undefined;
    for (slots[0..n], 0..) |r, i| bases[i] = r.base;

    if (!virtio_input.init(bases[0..n])) {
        // Usually not a failure of this code at all: it means QEMU was
        // started without `-device virtio-keyboard-device`, and there is no
        // keyboard to find. But "no keyboard" is also what a driver looking
        // at the wrong addresses says, and what one that rejects the
        // transport version the devices actually speak says, so the failure
        // path prints the bus rather than a summary of it. Success does not:
        // a list of every slot on every boot is noise until the day it is
        // the only thing that would explain the silence.
        console.print("  [--] ");
        console.print_dec(n);
        console.println(" virtio slots, none of them a usable keyboard:");
        for (bases[0..n]) |b| {
            const magic: *volatile u32 = @ptrFromInt(vm.phys_to_virt(b));
            const ver: *volatile u32 = @ptrFromInt(vm.phys_to_virt(b) + 4);
            const did: *volatile u32 = @ptrFromInt(vm.phys_to_virt(b) + 8);
            if (magic.* != virtio_mmio.MAGIC or did.* == 0) continue;
            console.print("       slot ");
            console.print_hex(b);
            console.print(": transport version ");
            console.print_dec(ver.*);
            console.print(", device id ");
            console.print_dec(did.*);
            console.println("");
        }
        return;
    }

    console.print("  [ok] keyboard: virtio-input on a bus of ");
    console.print_dec(n);
    console.println(" slots");

    // And its interrupt, so the queue is emptied while something else is
    // running rather than only when a read asks. Which slot answered is the
    // driver's to say; which interrupt that slot raises is the device
    // tree's. A slot whose node has no usable `interrupts` leaves the
    // keyboard polled, which is what it was before and still works — so this
    // is reported rather than treated as a failure to boot.
    if (virtio_input.found_in()) |i| {
        if (slots[i].intid) |id| {
            virtio_input.route(id);
            console.print("  [ok] keyboard: interrupt ");
            console.print_dec(id);
            console.println(" routed to this core");
        } else {
            console.println("  [--] keyboard: no interrupt in the device tree; polled only");
        }
    }

}

/// Open the console for reading, then read what turns up.
fn read_some_lines() void {
    // Everything that reads the console reads it through drivers/stdin.zig,
    // this selftest and read(2) alike. One editor, not one each: two editors
    // polling the same keyboard would each see half of what was typed, and
    // the half each got would depend on which happened to ask first.
    //
    // Unconditional now. It used to happen only where a keyboard had been
    // found, which quietly made the serial line unreadable on exactly the
    // machines that most needed it.
    stdin.init(.{
        .poll = poll_input,
        .echo = console.putc,
        // The physical counter, not the interrupt count: read(2) runs with
        // interrupts masked, where the interrupt count does not move and a
        // timeout built on it never expires.
        .ticks = timer.hundredths,
    });

    // Bounded by the timer rather than by a spin count: how many times a loop
    // goes round in a second depends on the machine, and the window the keys
    // have to arrive in should not. The timer is known to be delivering
    // interrupts by here — timer_selftest ran several screens ago and would
    // have said so if it were not.
    //
    // Nothing may be typed at all, which is why this reports what it saw
    // rather than passing or failing. The checking is tools/key_check.py's
    // job, because only something outside the kernel can make keys happen.
    // The same wait `read(2)` uses, from the same place: this prompt and a
    // program's are the same prompt as far as whoever is sitting there is
    // concerned, and two different timeouts would mean the kernel's own
    // prompt gave up while a program's was still listening.
    const WAIT: u64 = cmdline.idle_ticks();
    const MAX_LINES: usize = 4;

    var buf: [line.MAX_LINE + 1]u8 = undefined;
    var lines: usize = 0;
    var characters: usize = 0;

    console.print("  type at it; ");
    console.print_dec(cmdline.idle());
    console.println(cmdline.idle_unit_plain());

    while (lines < MAX_LINES) {
        console.print("  > ");
        const got = stdin.read(&buf, WAIT);
        if (got == 0) {
            // Nothing typed. End the prompt's line so the next message does
            // not run on from it.
            console.println("");
            break;
        }

        // The newline stdin puts back on is where the line ends, not part of
        // it. Trimming it here rather than in stdin is deliberate: read(2)
        // wants it, and a printed line does not.
        const body = buf[0 .. got - 1];
        lines += 1;
        characters += body.len;

        // Printed on its own line rather than left on screen, because the
        // echo shows what was typed and this shows what the kernel *has* —
        // and the whole point of a line discipline is that those two differ
        // wherever something was corrected.
        console.print("  line ");
        console.print_dec(lines);
        console.print(": \"");
        console.print(body);
        console.println("\"");
    }

    // A line still being typed when the time ran out is reported too. Left
    // out, a test that lost the Enter would look exactly like one that lost
    // the whole line.
    const rest = stdin.partial();
    if (rest.len > 0) {
        console.print("  unfinished: \"");
        console.print(rest);
        console.println("\"");
    }

    console.print("  [ok] console input: ");
    console.print_dec(lines);
    console.print(if (lines == 1) " line, " else " lines, ");
    console.print_dec(characters);
    console.print(if (characters == 1) " character, from " else " characters, from ");
    console.print_dec(keyboard.presses);
    console.print(if (keyboard.presses == 1) " key press (" else " key presses (");
    console.print_dec(stdin.ignored());
    console.print(" ignored, ");
    console.print_dec(stdin.dropped());
    console.println(" dropped)");
}

/// What the machine was told at boot, and whether it was told anything.
///
/// Printed even when there was no command line, and saying which of the two
/// it was. A kernel whose parser silently failed and one that was never given
/// an `-append` would otherwise produce the same boot log, and the first is a
/// bug while the second is Tuesday.
fn report_command_line() void {
    console.print("  [ok] command line: read ");
    console.print_dec(cmdline.idle());
    console.print(cmdline.idle_unit());
    console.println(if (cmdline.was_given()) " (asked for)" else " (default)");
    if (cmdline.ignored() > 0 or cmdline.rejected() > 0) {
        console.print("       ");
        console.print_dec(cmdline.ignored());
        console.print(" options not understood, ");
        console.print_dec(cmdline.rejected());
        console.println(" values refused");
    }
}

/// Where the key events came from, and whether any were lost.
///
/// The distinction that matters is `interrupts`. Reads poll the device queue
/// as well, so a keyboard whose interrupt was never routed still works — it
/// works exactly as badly as it did before the interrupt existed, and the
/// only difference visible from outside is that this number stays at zero.
/// Without it, "the GIC routing is wrong" and "the GIC routing is right"
/// produce the same boot log.
fn keyboard_report() void {
    if (!stdin.present()) return;
    console.print("  [ok] keyboard: ");
    console.print_dec(virtio_input.interrupts);
    console.print(if (virtio_input.interrupts == 1) " interrupt serviced, " else " interrupts serviced, ");
    console.print_dec(virtio_input.overruns);
    console.println(" events overrun");
}

/// The console's screen half, once there is a screen.
///
/// Kept here rather than inside screen_selftest because the two are different
/// claims: that one is about whether the display works, and is checked by
/// reading pixels back and by a screenshot. This is about whether the kernel
/// can write text, and is checked by the same screenshot reading the glyphs.
var screen_console: text.Console = undefined;

fn open_screen_console() void {
    const s = live_surface orelse return;
    screen_console = text.Console.init(s, 2, fb.WHITE, fb.SLATE);
    screen_console.clear();
    console.set_mirror(&screen_console);
    console.print("  [ok] console on screen: ");
    console.print_dec(screen_console.cols);
    console.print("x");
    console.print_dec(screen_console.rows);
    console.println(" characters");

    console_selftest();
}

/// Every printable character, in order. Written out rather than generated so
/// that what the screenshot check compares against is a literal, and so a
/// glyph nothing else prints still gets drawn once.
const PRINTABLE =
    " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`" ++
    "abcdefghijklmnopqrstuvwxyz{|}~";

/// Draw every glyph, and make the screen scroll.
///
/// Both halves are here because neither happens on its own. The boot log uses
/// perhaps forty distinct characters, so a wrong byte in a glyph nothing
/// prints would sit there indefinitely; and it fills thirty-three rows of
/// forty-eight, so the code that moves the picture up had never once run —
/// the same shape of gap as an exception vector nothing reaches, which is
/// where most of this kernel's real bugs have been.
///
/// Deliberately noisy on the serial line. The alternative is a console whose
/// scrolling is untested, and forty lines of boot log is a cheaper price than
/// that.
fn console_selftest() void {
    console.print("  console: ");
    console.println(PRINTABLE);

    // As many lines as it takes, rather than a number chosen once and left
    // to rot. Forty was the first guess and it was wrong — the screen holds
    // forty-eight rows and forty-three were already spoken for, so nothing
    // scrolled and the test passed anyway by asking the wrong question.
    // Asking for three scrolls instead of a line count cannot go stale when
    // the boot log or the screen changes size.
    const before = screen_console.scrolls;
    const WANT_SCROLLS: u64 = 3;
    var i: u32 = 0;
    while (screen_console.scrolls - before < WANT_SCROLLS and i < 500) : (i += 1) {
        console.print("  console: filling the screen, line ");
        console.print_dec(i);
        console.println("");
    }
    const scrolled = screen_console.scrolls - before;

    if (scrolled >= WANT_SCROLLS) {
        console.print("  [ok] console: ");
        console.print_dec(PRINTABLE.len);
        console.print(" glyphs drawn, screen scrolled ");
        console.print_dec(scrolled);
        console.print(" times over ");
        console.print_dec(i);
        console.println(" lines");
    } else {
        console.print("  [FAIL] console: ");
        console.print_dec(i);
        console.print(" lines produced only ");
        console.print_dec(scrolled);
        console.println(" scrolls");
    }
}

/// The surface the display is actually scanning out, or null if there is
/// none. Set by screen_selftest once it has proved the surface works.
var live_surface: ?fb.Surface = null;

/// Prove an interrupt actually arrives.
///
/// The counter is incremented only by the IRQ handler, so reaching WANT is
/// impossible without one really being delivered — the same principle as the
/// x86 preemption test, which two threads could not pass by cooperating.
///
/// Bounded in spins rather than in time, because a deadline measured in timer
/// ticks would wait forever for exactly the thing whose absence it is meant to
/// report. Three ticks rather than one, because the comparator is one-shot: a
/// handler that fires but forgets to re-arm would pass a test that asked for
/// one and fail this.
fn timer_selftest() void {
    const WANT: u64 = 3;
    const SPIN_LIMIT: u64 = 100_000_000;
    var spins: u64 = 0;
    while (timer.ticks() < WANT and spins < SPIN_LIMIT) : (spins += 1) {
        asm volatile ("nop");
    }
    if (timer.ticks() >= WANT) {
        console.print("  [ok] aarch64 timer: interrupts delivered, ticks=");
        console.print_dec(timer.ticks());
        console.println("");
    } else {
        console.print("  [FAIL] aarch64 timer: no interrupt arrived, ticks=");
        console.print_dec(timer.ticks());
        console.println("");
    }
}

/// Called from the IRQ vector entry, which saved the caller-saved integer
/// registers and will `eret` when this returns.
///
/// Condition flags need no saving: `eret` restores PSTATE from SPSR_EL1 —
/// which the vector entry now keeps on the stack rather than in the register,
/// because this handler can switch threads and a single pair of ELR/SPSR
/// registers cannot serve two of them.
///
/// FP and SIMD registers are *not* saved here. That is not the gap it looks
/// like: `switch_to` saves d8-d15, which is the whole of what AAPCS64 makes
/// callee-saved, and everything else in the vector file is dead across a call
/// by the same ABI. It becomes a gap the moment userspace can be preempted
/// with live floating point, which needs the full register file saved into
/// the trap frame.
export fn aarch64_irq() callconv(.C) void {
    // Acknowledged first, then the scheduling decision — switching away with
    // the interrupt still active at the GIC would leave that priority pending
    // on this core and nothing further would ever be delivered.
    //
    // And only on a real tick. A time slice expiring and an interrupt
    // arriving are the same event only on a machine whose only device is the
    // timer, which this one no longer is.
    const which = gic.acknowledge();
    if (which == gic.SPURIOUS) return;

    const tick = timer.handle_irq(which);
    if (!tick) {
        // Not the timer. The keyboard and the serial line are the others,
        // and an interrupt that belongs to nothing is still ended below:
        // leaving it active would keep its priority on this core and stop
        // everything quieter than it, the timer included.
        if (!virtio_input.handle_irq(which)) _ = console.handle_irq(which);
    }

    gic.end(which);

    // A time slice may only end where the kernel can be left. Since system
    // calls run with interrupts on, a tick can now arrive in the middle of
    // one, and switching threads there would suspend a half-finished call on
    // a stack frame nothing comes back to until that thread runs again —
    // with no way yet to say what the call should do when it does.
    if (tick and !trap.in_syscall()) {
        // Two supervisors and then the scheduler. The first two are boot
        // selftests that are inert unless their own test is running, and
        // they are mutually exclusive with each other and with the
        // scheduler: while `threadtest` drives its own pair of contexts the
        // scheduler has no current thread, and while the scheduler is
        // running threads `threadtest` is not.
        threadtest.on_tick();
        schedtest.on_tick();
        sched.tick();
    }
}

fn install_vectors() void {
    asm volatile (
        \\msr vbar_el1, %[table]
        \\isb
        :
        : [table] "r" (@intFromPtr(&aarch64_vectors)),
        : "memory"
    );
}

/// Called from every vector-table entry. `kind` is the entry index (0..15:
/// four groups of sync/IRQ/FIQ/SError), and the syndrome registers say what
/// happened and where. Nothing generates interrupts yet, so anything
/// arriving here is a bug worth reporting rather than silently spinning.
export fn aarch64_exception(kind: u64, esr: u64, elr: u64, far: u64) callconv(.C) noreturn {
    console.print("\n\nAARCH64 EXCEPTION entry=");
    console.print_dec(kind);
    console.print(" esr=");
    console.print_hex(esr);
    console.print(" elr=");
    console.print_hex(elr);
    console.print(" far=");
    console.print_hex(far);
    console.println("");
    hang();
}

fn hang() noreturn {
    while (true) {
        asm volatile ("wfe");
    }
}

/// Freestanding targets need an explicit panic handler.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    console.print("\n\nKERNEL PANIC (aarch64): ");
    console.println(msg);
    hang();
}

/// End of everything the kernel image occupies, from the linker script — past
/// .bss and past the boot stack.
extern const __stack_top: u8;

/// Read the machine's own description, and point the drivers that need an
/// address at the one it gives.
///
/// Null means no device tree, which is survivable: the drivers keep their
/// QEMU `virt` defaults and the memory phase below reports that it cannot
/// run. It is worth distinguishing from a tree that parsed and said something
/// unexpected, because the two have completely different causes.
/// Say which interrupt controller was found, and stop if there was none.
///
/// A kernel that reaches this line without a controller has no timer and no
/// keyboard: it would boot, print, and then sit still for reasons nothing on
/// the serial line would explain. Saying so is the difference between a bug
/// report and a mystery.
fn report_interrupt_controller() void {
    switch (gic.detected()) {
        .v2 => console.println("  [ok] interrupt controller: GICv2 (memory-mapped CPU interface)"),
        .v3 => console.println("  [ok] interrupt controller: GICv3 (redistributor + system registers)"),
        .unknown => console.println("  [!!] interrupt controller: none found in the device tree — no interrupts will be delivered"),
    }
}

fn describe_machine(dtb_phys: u64) ?fdt.Fdt {
    const tree = fdt.parse(vm.phys_to_virt(dtb_phys)) orelse {
        console.print("  [--] no device tree at ");
        console.print_hex(dtb_phys);
        console.println("; using built-in machine defaults");
        return null;
    };

    console.print("  [ok] device tree at ");
    console.print_hex(dtb_phys);
    console.print(", ");
    console.print_dec(tree.total_size);
    console.print(" bytes, #address-cells=");
    console.print_dec(tree.addr_cells);
    console.print(" #size-cells=");
    console.print_dec(tree.size_cells);
    console.println("");

    // The one hardcoded address this retires. The UART's cannot follow: the
    // console has to work before anything can be printed about the tree, so
    // it is found the only way something can be before there is any output.
    if (fdt.node_reg(&tree, "fw-cfg@")) |reg| {
        fwcfg.set_base(reg.base);
        console.print("  [ok] fw_cfg from the device tree at ");
        console.print_hex(reg.base);
        console.println("");
    }
    return tree;
}

/// Stand up the page allocator, and prove it hands out memory that works.
fn memory_selftest(tree: ?fdt.Fdt, dtb_phys: u64) void {
    const t = tree orelse {
        console.println("  [--] no device tree; physical memory unknown, allocator not started");
        return;
    };

    var regions: [8]fdt.Region = undefined;
    const n = fdt.memory_regions(&t, &regions);
    if (n == 0) {
        console.println("  [FAIL] device tree describes no memory");
        return;
    }

    pmm.begin();
    var total: u64 = 0;
    for (regions[0..n]) |r| {
        pmm.add_available(r.base, r.len);
        total += r.len;
        ram_end = @max(ram_end, r.base + r.len);
        console.print("  ram ");
        console.print_hex(r.base);
        console.print(" + ");
        console.print_dec(r.len >> 20);
        console.println(" MiB");
    }

    // The boot stub could only map the gigabyte it found itself running in,
    // because it ran before anything had read this tree. Now that the extent
    // of RAM is known, the rest of it gets mapped — otherwise the allocator
    // would happily hand out pages above the first gigabyte that this kernel
    // could not touch.
    var mmu_regions: [8]mmu.Region = undefined;
    for (regions[0..n], 0..) |r, i| mmu_regions[i] = .{ .base = r.base, .len = r.len };
    const added = mmu.map_ram(mmu_regions[0..n]);

    // Every gigabyte the allocator is about to hand pages out of has to be
    // reachable, and the way to know is to ask the MMU rather than to trust
    // the loop above. The last byte of each region is the interesting one: it
    // is the address a mapping that stopped one block short would miss, and
    // it is exactly where the allocator ends up on a machine with more RAM
    // than the boot stub could map.
    var reach_ok = true;
    for (regions[0..n]) |r| {
        if (r.len == 0) continue;
        const last = r.base + r.len - 1;
        if (mmu.translate(vm.phys_to_virt(last)) != last) reach_ok = false;
    }
    if (reach_ok) {
        console.print("  [ok] direct map covers all of RAM (");
        console.print_dec(added);
        console.println(" GiB added beyond the boot stub's block)");
    } else {
        console.println("  [FAIL] direct map does not reach the end of RAM");
    }

    // Three things already live in that memory and must never be handed out.
    //
    // The kernel image runs from where it was loaded — and the reservation
    // starts at the base of RAM rather than at the image, because the ARM64
    // boot protocol puts the kernel 512 KiB up and leaves what is underneath
    // to the bootloader. QEMU happens to put nothing there; a different
    // bootloader is entitled to, and half a mebibyte is not worth the risk.
    //
    // The device tree is still being read from, wherever the bootloader chose
    // to put it. And the framebuffer is being scanned out by the display
    // right now, so a page handed out of it would appear on screen.
    // `__stack_top` is a link-time address, which is now a *virtual* one; the
    // allocator deals in physical addresses, so it is converted back. Getting
    // this wrong would reserve a range starting 0xFFFF_FF80... pages in and
    // reserve nothing at all.
    const kernel_end: u64 = vm.virt_to_phys(@intFromPtr(&__stack_top));
    pmm.reserve(regions[0].base, kernel_end - regions[0].base);
    pmm.reserve(dtb_phys, t.total_size);
    pmm.reserve(ramfb.FB_PHYS, @as(u64, SCREEN_W) * SCREEN_H * 4);
    pmm.finish();

    const before = pmm.stats();

    // Allocate, write through it, read it back, free it, and check the page
    // comes back. Allocating alone proves only that a bit was flipped; the
    // question is whether the address returned is memory that works.
    const p1 = pmm.alloc_page() orelse {
        console.println("  [FAIL] pmm: no page available on a machine with RAM");
        return;
    };
    // `p1` is physical, and this kernel has no identity map: dereferencing it
    // directly would fault. Through the direct map it is memory.
    const cell: *volatile u64 = vm.ptr_to_phys(*volatile u64, p1);
    cell.* = 0xC0FFEE_5EED;
    const held = cell.* == 0xC0FFEE_5EED;

    const p2 = pmm.alloc_page() orelse 0;
    const distinct = p2 != 0 and p2 != p1;

    pmm.free_page(p1);
    pmm.free_page(p2);
    const after = pmm.stats();
    const restored = after.free_pages == before.free_pages;

    // A page below the end of the kernel image would mean the reservations
    // did not take — the failure that corrupts the kernel out from under
    // itself later rather than here.
    const outside_kernel = p1 >= kernel_end;

    if (held and distinct and restored and outside_kernel) {
        console.print("  [ok] pmm: ");
        console.print_dec(before.total_bytes >> 20);
        console.print(" MiB managed, ");
        console.print_dec(before.free_pages);
        console.print(" pages free, allocated ");
        console.print_hex(p1);
        console.println(" and it holds");
    } else {
        console.print("  [FAIL] pmm: held=");
        console.print_dec(@intFromBool(held));
        console.print(" distinct=");
        console.print_dec(@intFromBool(distinct));
        console.print(" restored=");
        console.print_dec(@intFromBool(restored));
        console.print(" outside_kernel=");
        console.print_dec(@intFromBool(outside_kernel));
        console.println("");
    }
}


