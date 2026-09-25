//! KyanOS kernel build script (Zig 0.13+).
//!
//! Produces a freestanding x86_64 ELF kernel that the bootloader can
//! load. Uses our custom linker script (boot/linker.ld) and the
//! bootstrap assembly in boot/start.S.
//!
//!     zig build              # build kernel/ at zig-out/bin/clarity-kernel
//!     zig build run          # build + boot under QEMU (requires qemu-system-x86_64)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = std.Target.x86.featureSet(&.{
            .mmx, .sse, .sse2, .avx, .avx2,
        }),
        .cpu_features_add = std.Target.x86.featureSet(&.{
            .soft_float,
        }),
    });
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "clarity-kernel",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
    });
    // No red zone. On x86-64 SysV a leaf function may use the 128 bytes
    // below %rsp without adjusting it — but an interrupt taken at the same
    // privilege level pushes its frame at %rsp, straight through that area.
    // It cost nothing while no interrupt ever arrived; with the timer running
    // it is silent corruption of whichever leaf function was unlucky.
    kernel.root_module.red_zone = false;

    kernel.setLinkerScript(b.path("boot/linker.ld"));
    kernel.addAssemblyFile(b.path("boot/start.S"));
    kernel.addAssemblyFile(b.path("arch/x86_64/context.S"));
    kernel.entry = .{ .symbol_name = "_start" };

    // ── the first user program ──────────────────────────
    //
    // Built as its own freestanding executable and embedded in the kernel
    // image, rather than assembled byte by byte inside the kernel as it was
    // before. A linker's output is what the loader will actually meet:
    // several PT_LOADs with different permissions, and a .bss whose p_memsz
    // exceeds its p_filesz. None of that was exercised by one hand-made
    // segment.
    //
    // It rides in the kernel image because the physical memory allocator
    // already reserves that; a GRUB module would land somewhere pmm is free
    // to hand out, which is a separate problem to solve properly.
    //
    // Unlike the kernel, this target keeps SSE and does not use soft_float.
    // The kernel gives them up on purpose — an interrupt handler that never
    // touches a vector register can never be the thing that clobbers one —
    // but userspace is where floating point actually happens: a compiled
    // Clarity program is C, and C on x86-64 passes and returns every double
    // in xmm0. The kernel enables SSE for ring 3 (arch/x86_64/fpu.zig) and
    // carries the state across a context switch (arch/x86_64/context.S), so
    // there is nothing left for this target to work around.
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const init_prog = b.addExecutable(.{
        .name = "clarity-init",
        .root_source_file = b.path("user/init.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    init_prog.setLinkerScript(b.path("user/user.ld"));
    init_prog.entry = .{ .symbol_name = "_start" };
    init_prog.pie = false;

    // Hands the built ELF to the kernel as an embeddable file. getEmittedBin
    // also makes the kernel depend on it, so it is built first.
    kernel.root_module.addAnonymousImport("init_elf", .{
        .root_source_file = init_prog.getEmittedBin(),
    });

    // /bin/clarity-hello: the smallest program that can be asked for by name,
    // and /bin/clarity-forkexec, which asks for it from a forked child.
    const hello_prog = b.addExecutable(.{
        .name = "clarity-hello",
        .root_source_file = b.path("user/hello.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    hello_prog.setLinkerScript(b.path("user/user.ld"));
    hello_prog.entry = .{ .symbol_name = "_start" };
    hello_prog.pie = false;
    kernel.root_module.addAnonymousImport("hello_elf", .{
        .root_source_file = hello_prog.getEmittedBin(),
    });

    const forkexec_prog = b.addExecutable(.{
        .name = "clarity-forkexec",
        .root_source_file = b.path("user/forkexec.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    forkexec_prog.setLinkerScript(b.path("user/user.ld"));
    forkexec_prog.entry = .{ .symbol_name = "_start" };
    forkexec_prog.pie = false;
    kernel.root_module.addAnonymousImport("forkexec_elf", .{
        .root_source_file = forkexec_prog.getEmittedBin(),
    });

    // /bin/clarity-waitprobe: does wait(2) wait? Its parent asks before the
    // child has run, so a wait that only looks for an already-finished child
    // has nothing to find.
    const wait_prog = b.addExecutable(.{
        .name = "clarity-waitprobe",
        .root_source_file = b.path("user/waitprobe.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    wait_prog.setLinkerScript(b.path("user/user.ld"));
    wait_prog.entry = .{ .symbol_name = "_start" };
    wait_prog.pie = false;
    kernel.root_module.addAnonymousImport("waitprobe_elf", .{
        .root_source_file = wait_prog.getEmittedBin(),
    });

    // /bin/clarity-readprobe: can a program read what was typed? Descriptor
    // zero went to the filesystem and answered EBADF until now.
    const read_prog = b.addExecutable(.{
        .name = "clarity-readprobe",
        .root_source_file = b.path("user/readprobe.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    read_prog.setLinkerScript(b.path("user/user.ld"));
    read_prog.entry = .{ .symbol_name = "_start" };
    read_prog.pie = false;
    kernel.root_module.addAnonymousImport("readprobe_elf", .{
        .root_source_file = read_prog.getEmittedBin(),
    });

    // /bin/clarity-forkprobe: the first program to call fork(2).
    const fork_prog = b.addExecutable(.{
        .name = "clarity-forkprobe",
        .root_source_file = b.path("user/forkprobe.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    fork_prog.setLinkerScript(b.path("user/user.ld"));
    fork_prog.entry = .{ .symbol_name = "_start" };
    fork_prog.pie = false;
    kernel.root_module.addAnonymousImport("forkprobe_elf", .{
        .root_source_file = fork_prog.getEmittedBin(),
    });

    // /bin/clarity-regprobe: a program that reads the registers it was
    // started with, before anything else can write to them.
    const reg_prog = b.addExecutable(.{
        .name = "clarity-regprobe",
        .root_source_file = b.path("user/regprobe.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    reg_prog.setLinkerScript(b.path("user/user.ld"));
    reg_prog.entry = .{ .symbol_name = "_start" };
    reg_prog.pie = false;
    kernel.root_module.addAnonymousImport("regprobe_elf", .{
        .root_source_file = reg_prog.getEmittedBin(),
    });

    // ── /bin/clarity-demo: a Clarity program ────────────
    //
    // The C is generated by `clarity cc --freestanding` and checked in as
    // user/clarity_demo.c, because this build has to work with only Zig
    // installed — the OS-boot job has no bun and no Clarity compiler, and
    // making it fetch one to build a kernel would tie booting the OS to a
    // network. stdlib/test_libc.clarity regenerates the file and fails if it
    // has drifted, which is the check that keeps the artifact honest and runs
    // where the compiler does exist.
    //
    // Linked against kernel/user/libc, which is the whole point: the program
    // reaches nothing but write, brk and exit.
    const c_flags = [_][]const u8{
        "-ffreestanding",
        // Without this the compiler is free to turn printf("...\n") into
        // puts, and printf is one of the things under test.
        "-fno-builtin",
        "-O2",
        "-w",
    };
    const demo_prog = b.addExecutable(.{
        .name = "clarity-demo",
        .root_source_file = null,
        .target = user_target,
        .optimize = .ReleaseSmall,
    });
    demo_prog.addIncludePath(b.path("user/libc/include"));
    demo_prog.addCSourceFile(.{ .file = b.path("user/clarity_demo.c"), .flags = &c_flags });
    demo_prog.addCSourceFiles(.{
        .root = b.path("user/libc/src"),
        .files = &.{
            "bignum.c", "ctype.c",  "dtoa.c",   "malloc.c", "math.c",
            "printf.c", "qsort.c",  "stdlib.c", "string.c", "strtod.c",
            "sys.c",
        },
        .flags = &c_flags,
    });
    demo_prog.addAssemblyFile(b.path("user/libc/src/setjmp.S"));
    demo_prog.addAssemblyFile(b.path("user/libc/src/start.S"));
    demo_prog.setLinkerScript(b.path("user/user.ld"));
    demo_prog.entry = .{ .symbol_name = "_start" };
    demo_prog.pie = false;

    kernel.root_module.addAnonymousImport("demo_elf", .{
        .root_source_file = demo_prog.getEmittedBin(),
    });

    b.installArtifact(kernel);

    // `zig build run` — boot the kernel under QEMU.
    //
    // Through a script rather than a direct QEMU invocation, because QEMU
    // cannot boot this image with `-kernel`: it is multiboot2, and `-kernel`
    // on x86 wants a bzImage or an ELF with a PVH note. It used to try
    // anyway, and every `zig build run` ended in
    //
    //   Error loading uncompressed kernel without PVH ELF Note
    //
    // with nothing on the serial line. The script builds the same GRUB rescue
    // ISO the boot gate builds, so `zig build run` and CI boot the same way.
    const qemu = b.addSystemCommand(&.{"sh"});
    qemu.addFileArg(b.path("tools/run_x86.sh"));
    qemu.addArtifactArg(kernel);

    const run_step = b.step("run", "Boot the x86-64 kernel under QEMU (builds a GRUB ISO)");
    run_step.dependOn(&qemu.step);

    // ── AArch64 (Apple-Silicon-class) kernel ──────────────
    //
    // Built under its own step (`zig build aarch64`) rather than the
    // default install, so the x86_64 build and its boot gate are wholly
    // unaffected. QEMU's `virt` machine is the CI target.
    const aarch64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const kernel_arm = b.addExecutable(.{
        .name = "clarity-kernel-aarch64",
        .root_source_file = b.path("main_aarch64.zig"),
        .target = aarch64_target,
        .optimize = optimize,
    });
    kernel_arm.setLinkerScript(b.path("boot/linker_aarch64.ld"));
    kernel_arm.addAssemblyFile(b.path("arch/aarch64/boot.S"));
    kernel_arm.addAssemblyFile(b.path("arch/aarch64/vectors.S"));
    kernel_arm.addAssemblyFile(b.path("arch/aarch64/user.S"));
    kernel_arm.addAssemblyFile(b.path("arch/aarch64/context.S"));

    // /bin/clarity-init for aarch64: a real program, built by a compiler and
    // laid out by a linker, embedded in the kernel image for the loader to
    // find. Same link script as the x86_64 one — it only names addresses and
    // alignments, both of which apply here.
    const user_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const init_prog_arm = b.addExecutable(.{
        .name = "clarity-init-aarch64",
        .root_source_file = b.path("user/init_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    init_prog_arm.setLinkerScript(b.path("user/user.ld"));
    init_prog_arm.entry = .{ .symbol_name = "_start" };
    init_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("init_elf_aarch64", .{
        .root_source_file = init_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-sh for aarch64: a shell. Same shape as the program above —
    // a compiler and a linker produce it, and the kernel embeds the result —
    // but it is the first one that reads.
    const sh_prog_arm = b.addExecutable(.{
        .name = "clarity-sh-aarch64",
        .root_source_file = b.path("user/sh_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    sh_prog_arm.setLinkerScript(b.path("user/user.ld"));
    sh_prog_arm.entry = .{ .symbol_name = "_start" };
    sh_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("sh_elf_aarch64", .{
        .root_source_file = sh_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-exec for aarch64: a program that asks to be replaced.
    //
    // Small on purpose. It is the only way the *plain* boot — no keyboard,
    // nothing to type with — can show exec working end to end: a gate that
    // went through the shell would run only in the headless serial job.
    const exec_prog_arm = b.addExecutable(.{
        .name = "clarity-exec-aarch64",
        .root_source_file = b.path("user/exectest_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    exec_prog_arm.setLinkerScript(b.path("user/user.ld"));
    exec_prog_arm.entry = .{ .symbol_name = "_start" };
    exec_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("exec_elf_aarch64", .{
        .root_source_file = exec_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-regprobe for aarch64: a program that reads the registers
    // it was started with, before anything else can write to them.
    const reg_prog_arm = b.addExecutable(.{
        .name = "clarity-regprobe-aarch64",
        .root_source_file = b.path("user/regprobe_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    reg_prog_arm.setLinkerScript(b.path("user/user.ld"));
    reg_prog_arm.entry = .{ .symbol_name = "_start" };
    reg_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("regprobe_elf_aarch64", .{
        .root_source_file = reg_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-fpprobe for aarch64: does a program get its
    // floating-point registers back? Runs alone, so it asks about the system
    // call path with nothing else able to be the explanation.
    const fp_prog_arm = b.addExecutable(.{
        .name = "clarity-fpprobe-aarch64",
        .root_source_file = b.path("user/fpprobe_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    fp_prog_arm.setLinkerScript(b.path("user/user.ld"));
    fp_prog_arm.entry = .{ .symbol_name = "_start" };
    fp_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("fpprobe_elf_aarch64", .{
        .root_source_file = fp_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-forkprobe for aarch64: does fork(2) make a second
    // process? Both halves check that they came back with the registers they
    // had, which is the part that is new on this architecture — a child
    // resumes, it does not start.
    const fork_prog_arm = b.addExecutable(.{
        .name = "clarity-forkprobe-aarch64",
        .root_source_file = b.path("user/forkprobe_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    fork_prog_arm.setLinkerScript(b.path("user/user.ld"));
    fork_prog_arm.entry = .{ .symbol_name = "_start" };
    fork_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("forkprobe_elf_aarch64", .{
        .root_source_file = fork_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-waitprobe for aarch64: does wait(2) actually wait? Its
    // parent asks before the child has run, so a wait that only looks for an
    // already-finished child has nothing to find.
    const wait_prog_arm = b.addExecutable(.{
        .name = "clarity-waitprobe-aarch64",
        .root_source_file = b.path("user/waitprobe_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    wait_prog_arm.setLinkerScript(b.path("user/user.ld"));
    wait_prog_arm.entry = .{ .symbol_name = "_start" };
    wait_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("waitprobe_elf_aarch64", .{
        .root_source_file = wait_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-hello for aarch64: the smallest program that can be asked
    // for by name. Installed in /bin, because a forked child reaches it the
    // way any program does — through the filesystem, by path.
    const hello_prog_arm = b.addExecutable(.{
        .name = "clarity-hello-aarch64",
        .root_source_file = b.path("user/hello_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    hello_prog_arm.setLinkerScript(b.path("user/user.ld"));
    hello_prog_arm.entry = .{ .symbol_name = "_start" };
    hello_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("hello_elf_aarch64", .{
        .root_source_file = hello_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-forkexec for aarch64: fork, exec in the child, wait, and
    // still be there afterwards.
    const forkexec_prog_arm = b.addExecutable(.{
        .name = "clarity-forkexec-aarch64",
        .root_source_file = b.path("user/forkexec_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    forkexec_prog_arm.setLinkerScript(b.path("user/user.ld"));
    forkexec_prog_arm.entry = .{ .symbol_name = "_start" };
    forkexec_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("forkexec_elf_aarch64", .{
        .root_source_file = forkexec_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-spin for aarch64: a program that spends time at EL0.
    //
    // Two copies of it run at once, one per kernel thread, which is the whole
    // of what "a program can be preempted" means here. Built once and loaded
    // twice; the copies tell themselves apart by the number the kernel hands
    // them in x0.
    const spin_prog_arm = b.addExecutable(.{
        .name = "clarity-spin-aarch64",
        .root_source_file = b.path("user/spin_aarch64.zig"),
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    spin_prog_arm.setLinkerScript(b.path("user/user.ld"));
    spin_prog_arm.entry = .{ .symbol_name = "_start" };
    spin_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("spin_elf_aarch64", .{
        .root_source_file = spin_prog_arm.getEmittedBin(),
    });

    // /bin/clarity-demo for aarch64: the same generated C as the x86_64 one,
    // linked against the same C library. Nothing in user/clarity_demo.c knows
    // which machine it is for — `clarity cc --freestanding` emits portable C
    // — and the library's three architecture-specific pieces (the system call
    // stubs, the entry point, setjmp) now have an AArch64 half.
    //
    // Which is the point of building it here rather than porting a smaller
    // program: if this runs, a Clarity program runs on Apple-Silicon-class
    // hardware, through the same path it takes on x86_64.
    const demo_prog_arm = b.addExecutable(.{
        .name = "clarity-demo-aarch64",
        .root_source_file = null,
        .target = user_arm_target,
        .optimize = .ReleaseSmall,
    });
    demo_prog_arm.addIncludePath(b.path("user/libc/include"));
    demo_prog_arm.addCSourceFile(.{ .file = b.path("user/clarity_demo.c"), .flags = &c_flags });
    demo_prog_arm.addCSourceFiles(.{
        .root = b.path("user/libc/src"),
        .files = &.{
            "bignum.c", "ctype.c",  "dtoa.c",   "malloc.c", "math.c",
            "printf.c", "qsort.c",  "stdlib.c", "string.c", "strtod.c",
            "sys.c",
        },
        .flags = &c_flags,
    });
    demo_prog_arm.addAssemblyFile(b.path("user/libc/src/setjmp.S"));
    demo_prog_arm.addAssemblyFile(b.path("user/libc/src/start.S"));
    demo_prog_arm.setLinkerScript(b.path("user/user.ld"));
    demo_prog_arm.entry = .{ .symbol_name = "_start" };
    demo_prog_arm.pie = false;
    kernel_arm.root_module.addAnonymousImport("demo_elf_aarch64", .{
        .root_source_file = demo_prog_arm.getEmittedBin(),
    });
    kernel_arm.entry = .{ .symbol_name = "_start" };

    // The bootable artefact is the flat binary, not the ELF.
    //
    // A bootloader following the ARM64 Linux boot protocol reads the header
    // at offset 0 of a raw image; handed an ELF instead, QEMU jumps to the
    // entry point and loads no device tree, so the kernel has no way to learn
    // what machine it is on. The ELF is still installed alongside it, because
    // it carries the symbols a debugger and a disassembler need.
    const kernel_arm_bin = b.addObjCopy(kernel_arm.getEmittedBin(), .{ .format = .bin });
    const install_arm_bin = b.addInstallBinFile(
        kernel_arm_bin.getOutput(),
        "clarity-kernel-aarch64.img",
    );

    // `zig build check` — compile the modules no kernel imports.
    //
    // Zig never parses a file nothing reaches, so a module outside every
    // build is not "written and compiling": it is written and unread. That
    // was measured, not supposed — a line of deliberate nonsense appended to
    // drivers/tty.zig, fs/devfs.zig, fs/procfs.zig or boot/uefi.zig used to
    // produce zero errors from `zig build` and `zig build aarch64` alike.
    //
    // checkonly.zig imports them, so they are at least valid Zig against the
    // code they refer to. Its first run found boot/uefi.zig discarding a
    // parameter it goes on to use.
    //
    // An object file rather than an executable: none of these has an entry
    // point, and none is meant to be linked into anything yet.
    const checkonly = b.addObject(.{
        .name = "clarity-checkonly",
        .root_source_file = b.path("checkonly.zig"),
        .target = target,
        .optimize = optimize,
    });
    const check_step = b.step("check", "Compile the modules no kernel imports");
    check_step.dependOn(&checkonly.step);

    const aarch64_step = b.step("aarch64", "Build the AArch64 kernel");
    aarch64_step.dependOn(&b.addInstallArtifact(kernel_arm, .{}).step);
    aarch64_step.dependOn(&install_arm_bin.step);

    // `zig build run-aarch64`. This one QEMU really can boot with `-kernel`:
    // the image carries an ARM64 Linux Image header, which is the format
    // `-kernel` expects on this architecture — and following that protocol is
    // also what gets the kernel handed a device tree.
    const qemu_arm = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",         "virt",
        "-cpu",       "cortex-a72",
        "-m",         "512",
        "-device",    "ramfb",
        "-serial",    "stdio",
        "-no-reboot",
        "-kernel",
    });
    qemu_arm.addFileArg(kernel_arm_bin.getOutput());
    qemu_arm.step.dependOn(aarch64_step);

    const run_arm_step = b.step("run-aarch64", "Boot the AArch64 kernel under QEMU");
    run_arm_step.dependOn(&qemu_arm.step);
}
