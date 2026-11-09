//! What does the loader do with an executable that is lying to it?
//!
//! `elf.parse` and `loader.load_into_new_space` read a file and, on the
//! strength of what it says, allocate physical frames and install
//! user-reachable page-table entries. Every field they act on is a `u64` or
//! `u32` taken straight out of the image: `e_phoff`, `e_phnum`, `p_offset`,
//! `p_filesz`, `p_memsz`, `p_vaddr`, `e_entry`. Nothing clamps them, and the
//! bounds checks that exist are written as additions on them -- so a field
//! chosen to make a sum wrap passes a check that was meant to stop it.
//!
//! Who gets to pick those bytes matters. Today every image is `@embedFile`d
//! into the kernel, so the answer is "whoever built the kernel", and none of
//! this is reachable. But `sched.spawn_user` takes a path, reads it out of
//! the VFS, and hands the bytes to `elf.parse` -- so the moment a program can
//! write a file and ask for it to be run, every field above is attacker-
//! controlled. That is one `exec` away, and the checking has to exist before
//! the path does, not after.
//!
//! So this gate builds images by hand, in memory, and asks for each one. It
//! runs in the kernel rather than from ring 3 because the parser *is* kernel
//! code reached from kernel code: a user program could only offer a path, and
//! there is no syscall yet that would take one. What it must not do is assert
//! on return codes alone, because a refusal that has already allocated frames
//! and left them mapped is not a refusal. The physical allocator's free count
//! before and after each rejected image is the real check: a loader that
//! bailed out part-way and lost what it had taken shows up there and nowhere
//! else.
//!
//! A case that stops the machine prints nothing, which is the point of saying
//! each one before asking: the last line in the log names the image the
//! kernel died on.

const std = @import("std");
const console = @import("arch/x86_64/console.zig");
const heap = @import("mm/heap.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const elf = @import("loader/elf.zig");
const loader = @import("loader/load.zig");
const uaccess = @import("mm/uaccess.zig");

/// Room for a header, a few program headers and a page of contents.
var image_buf: [8192]u8 align(8) = undefined;

/// An image is described by explicit arguments, not by a struct with
/// defaults.
///
/// That is deliberate and was learned the hard way: a first version of this
/// gate, and a host-side harness built the same way, passed a `Spec` struct
/// whose unmentioned fields were meant to take their declared defaults. Under
/// zig 0.13 the literals came out with `e_phoff` holding 0xFFFFFFFF in every
/// case -- including the ones that never mention it, and including a case
/// with `e_phnum` 0 where the only check that can fail is the one on
/// `e_phoff`. A default-constructed `Spec` read correctly inside the callee
/// at the same moment, so the values were being lost between the literal and
/// the call. Every image therefore claimed a program-header table past the
/// end of the file, every case was refused as `Truncated`, and the gate would
/// have reported ten refusals and called the loader sound.
///
/// Which would have been a test that passes for the wrong reason -- the
/// expensive kind. So nothing here relies on a field it did not write.
fn build(
    e_phoff: u64,
    e_phnum: u16,
    e_entry: u64,
    phdrs: []const elf.ProgramHeader,
    len: usize,
) []const u8 {
    @memset(image_buf[0..], 0);
    var hdr: elf.Header = std.mem.zeroes(elf.Header);
    hdr.e_ident[0] = elf.ELFMAG[0];
    hdr.e_ident[1] = elf.ELFMAG[1];
    hdr.e_ident[2] = elf.ELFMAG[2];
    hdr.e_ident[3] = elf.ELFMAG[3];
    hdr.e_ident[4] = elf.ELFCLASS64;
    hdr.e_ident[5] = elf.ELFDATA2LSB;
    hdr.e_ident[6] = 1; // EV_CURRENT
    hdr.e_type = elf.ET_EXEC;
    hdr.e_machine = elf.EM_NATIVE;
    hdr.e_version = 1;
    hdr.e_entry = e_entry;
    hdr.e_phoff = e_phoff;
    hdr.e_ehsize = @sizeOf(elf.Header);
    hdr.e_phentsize = @sizeOf(elf.ProgramHeader);
    hdr.e_phnum = e_phnum;
    @memcpy(image_buf[0..@sizeOf(elf.Header)], std.mem.asBytes(&hdr));

    // The table goes where the header says, when that is somewhere this
    // buffer has room for. An image that points it off the end is testing
    // exactly that, so it is left alone.
    if (e_phoff < image_buf.len) {
        var off: usize = @intCast(e_phoff);
        for (phdrs) |ph| {
            if (off + @sizeOf(elf.ProgramHeader) > image_buf.len) break;
            var copy = ph;
            @memcpy(image_buf[off..][0..@sizeOf(elf.ProgramHeader)], std.mem.asBytes(&copy));
            off += @sizeOf(elf.ProgramHeader);
        }
    }

    // Said once per image, because a gate whose inputs are wrong reports on
    // something other than its subject -- which is how the version above
    // nearly passed.
    console.print("    (image: phoff=");
    console.print_dec(e_phoff);
    console.print(" phnum=");
    console.print_dec(e_phnum);
    console.print(" bytes=");
    console.print_dec(len);
    console.println(")");
    return image_buf[0..len];
}

/// Where the program headers sit when the image is well-formed.
const PHOFF: u64 = @sizeOf(elf.Header);
/// How big every image in this gate is.
const IMAGE_LEN: usize = 4096;

fn load_phdr(vaddr: u64, offset: u64, filesz: u64, memsz: u64) elf.ProgramHeader {
    return .{
        .p_type = elf.PT_LOAD,
        .p_flags = elf.PF_R | elf.PF_X,
        .p_offset = offset,
        .p_vaddr = vaddr,
        .p_paddr = 0,
        .p_filesz = filesz,
        .p_memsz = memsz,
        .p_align = 0x1000,
    };
}

var failures: u32 = 0;
var cases: u32 = 0;

/// Ask for one image that must be refused, and check that refusing it cost
/// nothing. `what` is said before the attempt, so a case that takes the
/// machine down is named by the last line in the log.
fn must_refuse(what: []const u8, image: []const u8) void {
    cases += 1;
    console.print("  elf: ");
    console.print(what);
    console.println(" ->");

    // Attempted three times, and only the last is measured, for the reason
    // given on `must_accept`: a refusal that gets far enough to append a
    // region grows the kernel heap's slab, and a slab page is never given
    // back. Measuring an early attempt reports that as the loader losing a
    // page -- which is what the first version of this gate did, on a case
    // where the cleanup was already correct.
    _ = attempt(image, true);
    _ = attempt(image, false);
    const free_before = pmm.stats().free_pages;
    _ = attempt(image, false);
    check_balance(what, free_before);
}

/// One parse-and-load of an image that is expected to be refused. Returns
/// true if something accepted it.
fn attempt(image: []const u8, say: bool) bool {
    const exe = elf.parse(image, heap.allocator()) catch |e| {
        if (say) {
            console.print("    parse refused it (");
            console.print(@errorName(e));
            console.println(")");
        }
        return false;
    };
    defer elf.release(heap.allocator(), exe);

    const loaded = loader.load_into_new_space(exe, image, heap.allocator()) catch |e| {
        if (say) {
            console.print("    the load refused it (");
            console.print(@errorName(e));
            console.println(")");
        }
        return false;
    };

    // Nothing refused it. Give back what it took before saying so, or every
    // case after this one measures a leak this one caused.
    if (say) {
        console.println("    ACCEPTED");
        failures += 1;
    }
    release_loaded(loaded);
    return true;
}

fn check_balance(what: []const u8, free_before: usize) void {
    const free_after = pmm.stats().free_pages;
    console.print("    (free pages ");
    console.print_dec(free_before);
    console.print(" -> ");
    console.print_dec(free_after);
    console.println(")");
    if (free_after < free_before) {
        failures += 1;
        console.print("  [FAIL] elf: refusing \"");
        console.print(what);
        console.print("\" lost ");
        console.print_dec(free_before - free_after);
        console.println(" physical pages — the load gave up without giving them back");
    }
}

fn release_loaded(loaded: loader.LoadedProcess) void {
    vmm.free_user_half(loaded.address_space);
    loaded.address_space.regions.deinit(heap.allocator());
    heap.allocator().destroy(loaded.address_space);
}

/// The other direction: an image this loader is supposed to accept.
/// Load and release an image, twice, and measure the second round.
///
/// Twice because the first one cannot be measured. Loading a program appends
/// to the address space's region list, and `heap.allocator()` serves that
/// from a slab which takes a page from `pmm` when it needs one and never
/// gives a slab page back. So the first load of an image with more regions
/// than any before it grows the heap by a page, and the free count ends one
/// lower through no fault of the loader -- which is exactly what the first
/// version of this gate reported about the init program, as a FAIL.
///
/// Two warm-up rounds rather than one, measured. With a single warm-up the
/// gate still reported -1 on two cases, and a third round showed the count
/// flat -- so the slab had grown again on the second. One round is not
/// enough; the count going flat and staying flat is what says the warm-up is
/// over, and that is what was observed rather than assumed.
fn must_accept(what: []const u8, image: []const u8) void {
    cases += 1;
    console.print("  elf: ");
    console.print(what);
    console.println(" ->");

    if (!round_trip(what, image, true)) return;
    if (!round_trip(what, image, false)) return;

    const free_before = pmm.stats().free_pages;
    if (!round_trip(what, image, false)) return;
    const free_after = pmm.stats().free_pages;

    if (free_after != free_before) {
        failures += 1;
        console.print("  [FAIL] elf: loading and releasing \"");
        console.print(what);
        console.print("\" moved the free count by ");
        if (free_after > free_before) {
            console.print("+");
            console.print_dec(free_after - free_before);
        } else {
            console.print("-");
            console.print_dec(free_before - free_after);
        }
        console.println("");
    }
}

/// One load and release. Returns false, having said why, if either refused.
fn round_trip(what: []const u8, image: []const u8, say: bool) bool {
    _ = what;
    const exe = elf.parse(image, heap.allocator()) catch |e| {
        failures += 1;
        console.print("    [FAIL] parse refused it (");
        console.print(@errorName(e));
        console.println(")");
        return false;
    };
    defer elf.release(heap.allocator(), exe);

    const loaded = loader.load_into_new_space(exe, image, heap.allocator()) catch |e| {
        failures += 1;
        console.print("    [FAIL] the load refused it (");
        console.print(@errorName(e));
        console.println(")");
        return false;
    };
    if (say) {
        console.print("    loaded, entry ");
        console.print_hex(loaded.entry_rip);
        console.println("");
    }
    release_loaded(loaded);
    return true;
}

pub fn run() void {
    const HUGE: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    const KERNEL_HALF: u64 = 0xFFFF_8000_0000_0000;
    const GOOD_VADDR: u64 = 0x40100000;

    // 1. A program-header table that starts past the end of the universe.
    //    `phoff + phnum * 56 > bytes.len` is the check; at this value the sum
    //    wraps and passes it, and then the table is read from `phoff`.
    //    Measured on the base revision: "KERNEL PANIC: integer overflow" at
    //    loader/elf.zig:155, and the same panic at the same line from a
    //    host-side build of the parser.
    {
        const ph = [_]elf.ProgramHeader{};
        must_refuse("a program-header table at 0xFFFFFFFFFFFFFFFF", build(HUGE, 1, GOOD_VADDR, &ph, IMAGE_LEN));
    }

    // 2. A segment whose contents start past the end, by the same trick on
    //    `p_offset + p_filesz`.
    {
        const ph = [_]elf.ProgramHeader{load_phdr(GOOD_VADDR, 0xFFFF_FFFF_FFFF_FF00, 0x200, 0x200)};
        must_refuse("a segment whose contents start past the end of the file", build(PHOFF, 1, GOOD_VADDR, &ph, IMAGE_LEN));
    }

    // 3. A segment whose virtual end wraps. `vaddr + memsz` is computed in
    //    three places and rounded up in two of them.
    {
        const ph = [_]elf.ProgramHeader{load_phdr(0xFFFF_FFFF_FFFF_F000, 0, 0x100, 0x2000)};
        must_refuse("a segment whose virtual end wraps past zero", build(PHOFF, 1, GOOD_VADDR, &ph, IMAGE_LEN));
    }

    // 4. A segment asking to be mapped in the kernel's half. No arithmetic
    //    trick -- it simply says where it wants to go.
    {
        const ph = [_]elf.ProgramHeader{load_phdr(KERNEL_HALF, 0, 0x100, 0x1000)};
        // The entry is inside that segment on purpose. With it left at a
        // sensible address the image is refused as EntryNotMapped -- true,
        // but it means the range check never runs and the case proves
        // nothing about it. The first version of this gate did exactly that.
        must_refuse("a segment asking for the kernel's half", build(PHOFF, 1, KERNEL_HALF, &ph, IMAGE_LEN));
    }

    // 5. And one exactly on the line the limit names.
    {
        const ph = [_]elf.ProgramHeader{load_phdr(uaccess.USER_TOP, 0, 0x100, 0x1000)};
        must_refuse("a segment starting at the first non-user address", build(PHOFF, 1, uaccess.USER_TOP, &ph, IMAGE_LEN));
    }

    // 6. An entry point outside the user half. On x86_64 that address is what
    //    `sysretq` is handed, and a non-canonical one faults in ring 0.
    {
        const ph = [_]elf.ProgramHeader{load_phdr(GOOD_VADDR, 0, 0x100, 0x1000)};
        must_refuse("an entry point in the kernel's half", build(PHOFF, 1, KERNEL_HALF + 0x1000, &ph, IMAGE_LEN));
    }

    // 7. An entry point no segment covers. There is nothing to execute there.
    {
        const ph = [_]elf.ProgramHeader{load_phdr(GOOD_VADDR, 0, 0x100, 0x1000)};
        must_refuse("an entry point outside every segment", build(PHOFF, 1, 0x50000000, &ph, IMAGE_LEN));
    }

    // 8. Nothing to load at all.
    {
        const ph = [_]elf.ProgramHeader{};
        must_refuse("an executable with no loadable segments", build(PHOFF, 0, GOOD_VADDR, &ph, IMAGE_LEN));
    }

    // 9. filesz past memsz: the copy would run past the segment holding it.
    //    The parser already refuses this; it is here so that it stays
    //    refused.
    {
        const ph = [_]elf.ProgramHeader{load_phdr(GOOD_VADDR, 0, 0x2000, 0x100)};
        must_refuse("a segment claiming more file than memory", build(PHOFF, 1, GOOD_VADDR, &ph, IMAGE_LEN));
    }

    // 10. Two segments whose page-rounded ranges overlap. This loader maps a
    //     segment page by page onto fresh frames, so the second mapping
    //     replaces the first's frame and discards what was copied into it --
    //     which is why user/user.ld aligns every section to a page and says
    //     so. The layout is not supported, and saying so beats loading it
    //     wrong.
    {
        const ph = [_]elf.ProgramHeader{
            load_phdr(GOOD_VADDR, 0, 0x100, 0x100),
            load_phdr(GOOD_VADDR + 0x800, 0x200, 0x100, 0x100),
        };
        must_refuse("two segments sharing a page", build(PHOFF, 2, GOOD_VADDR, &ph, IMAGE_LEN));
    }

    // And the valid paths, which are half the point. Page-disjoint segments
    // are the layout the linker script produces and the only one this loader
    // can honour; the second has memsz past filesz, which is a real .bss.
    {
        const ph = [_]elf.ProgramHeader{
            load_phdr(GOOD_VADDR, 0x200, 0x100, 0x100),
            load_phdr(GOOD_VADDR + 0x1000, 0x300, 0x100, 0x2000),
        };
        must_accept("two page-disjoint segments, the second with a .bss", build(PHOFF, 2, GOOD_VADDR, &ph, IMAGE_LEN));
    }

    // A segment that does not begin on a page boundary, which a linker is
    // free to emit and the copy handles with an offset into the first frame.
    {
        const ph = [_]elf.ProgramHeader{load_phdr(GOOD_VADDR + 0x40, 0x200, 0x100, 0x100)};
        must_accept("a segment starting mid-page", build(PHOFF, 1, GOOD_VADDR + 0x40, &ph, IMAGE_LEN));
    }

    // And the real thing: the program this boot actually runs, through the
    // same two functions.
    must_accept("the init program this boot loads", @embedFile("init_elf"));

    console.print("  elf: ");
    console.print_dec(cases);
    console.println(" executables offered to the loader");

    if (failures == 0) {
        console.println("  [ok] elf: every malformed executable was refused without losing a page, and every valid one loaded and released cleanly");
    } else {
        console.print("  [FAIL] elf: ");
        console.print_dec(failures);
        console.println(" of the images above were not handled correctly");
    }
}
