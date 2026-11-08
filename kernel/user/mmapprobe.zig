//! /bin/clarity-mmapprobe — asks the kernel to map the framebuffer somewhere
//! it should not, and then somewhere it should.
//!
//! `mmap` is the only system call in this kernel that takes an address from
//! userspace and installs a page-table entry for it. Every other user pointer
//! is *read through* `uaccess`, which refuses anything at or above
//! `USER_TOP`; this one is *written to* the tables, and nothing on the boot
//! has ever called it. The reachability gate says so: mmap is on its list of
//! calls that nothing but the probe pokes, and that list has a perfect record
//! -- fork, wait, exec and nanosleep were all on it, and all four were broken.
//!
//! The zero-argument poke the reachability probe makes is not a test of this
//! path: its fd is 0, which is not the framebuffer's fd, so it is refused
//! before any address is looked at. This program is the first thing to get
//! past that check.
//!
//! Ten questions, one bit of the exit status each, so the kernel-side gate
//! can say which one failed rather than just that something did. Every answer
//! is set only after the call returns, so a question that takes the machine
//! down leaves its bit clear.
//!
//! The addresses are not arbitrary:
//!
//!   AT_TOP      `USER_TOP` exactly: the first address that is not
//!               userspace. Bits 47..39 of it are 256, so the walk starts at
//!               PML4[256] -- the first entry `share_kernel_half` copies out
//!               of the kernel's own table. The address is not canonical, so
//!               nothing could ever read it, but `map_page` does not walk
//!               addresses, it walks index arithmetic, and the indices land
//!               in the kernel's tables all the same. It is first because it
//!               is the case that demonstrates the damage without stopping
//!               the boot.
//!   KERNEL_VA   the base of the kernel's half, bit 63 set. Same tables, and
//!               on the way back out the dispatcher converts the address to
//!               a signed return value, which a value this large does not
//!               fit.
//!   MISALIGNED  a valid user address plus one byte. The mapping loop adds
//!               0x1000 per page without rounding, so an unaligned request
//!               walks to a different leaf for every page.
//!   WRAPS       high enough that the end of the request, computed as
//!               `addr + pages * 0x1000`, wraps round past zero. A length
//!               check that compares the end against a limit without
//!               checking the addition reads such a request as tiny.
//!   LAST_LEGAL  the highest placement that fits entirely under `USER_TOP`,
//!               derived from the framebuffer's real size. This one has to
//!               be *granted*: a bounds check written one page out rejects
//!               it, and a gate that only ever asks for refusals would call
//!               that a pass.
//!   VALID       clear of the program image, of the heap `brk` can reach
//!               (brk_start + 256 MiB), and of the stack.

const NR_WRITE: u64 = 1;
const NR_EXIT: u64 = 12;
const NR_MMAP: u64 = 7;
const NR_IOCTL: u64 = 40;

const FB_FD: u64 = @bitCast(@as(i64, -2));
const IOCTL_FB_GET_INFO: u64 = 0x4600;

/// The first address that is not userspace. Must match `uaccess.USER_TOP`.
const USER_TOP: u64 = 0x0000_8000_0000_0000;

const AT_TOP: u64 = USER_TOP;
const WRAPS: u64 = 0xFFFF_FFFF_FFFF_F000;
const KERNEL_VA: u64 = 0xFFFF_8000_0000_0000;
const VALID: u64 = 0x6000_0000;

const ALL_PASSED: u64 = 0x3FF;

const FbInfo = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
    fb_type: u8,
    pad: u16,
};

fn syscall6(nr: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
          [a3] "{r10}" (a3),
          [a4] "{r8}" (a4),
          [a5] "{r9}" (a5),
        : "rcx", "r11", "memory"
    );
}

fn syscall3(nr: u64, a0: u64, a1: u64, a2: u64) i64 {
    return syscall6(nr, a0, a1, a2, 0, 0, 0);
}

/// mmap(addr, length, prot, flags, fd, offset).
fn mmap(addr: u64, fd: u64) i64 {
    return syscall6(NR_MMAP, addr, 0, 0, 0, fd, 0);
}

fn write(buf: []const u8) void {
    var done: usize = 0;
    while (done < buf.len) {
        const n = syscall3(NR_WRITE, 1, @intFromPtr(buf.ptr) + done, buf.len - done);
        if (n <= 0) return;
        done += @intCast(n);
    }
}

fn say(what: []const u8, got: i64) void {
    write("  mmapprobe: ");
    write(what);
    write(" -> ");
    if (got < 0) {
        write("-");
        print_dec(@intCast(-got));
    } else {
        write("0x");
        print_hex(@bitCast(got));
    }
    write("\n");
}

fn print_dec(v: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n = v;
    if (n == 0) {
        write("0");
        return;
    }
    while (n != 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    write(buf[i..]);
}

fn print_hex(v: u64) void {
    const digits = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    var started = false;
    var shift: u6 = 60;
    while (true) {
        const nib: u8 = @intCast((v >> shift) & 0xF);
        if (nib != 0 or started or shift == 0) {
            started = true;
            buf[i] = digits[nib];
            i += 1;
        }
        if (shift == 0) break;
        shift -= 4;
    }
    write(buf[0..i]);
}

/// `_start` is entered with a 16-byte-aligned %rsp, because that is what the
/// System V ABI says a process entry point gets. A Zig `callconv(.C)`
/// function is compiled on the opposite assumption -- that it was reached by
/// `call`, so %rsp is 8 past an alignment boundary -- and lays out its frame
/// from there. With the two disagreeing, every 16-byte-aligned SSE store in
/// the prologue is off by eight: the first `movaps` into the frame raises
/// #GP. Measured, not reasoned about: this program's first version faulted at
/// its fourth instruction, `movaps %xmm0,(%rdx)`, before it reached a single
/// system call.
///
/// So the entry point is naked and reaches the body through `call`, which
/// pushes the eight bytes the body's own layout assumes are there.
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ callq %[body:P]
        \\ ud2
        :
        : [body] "X" (&body),
    );
}

fn body() callconv(.C) noreturn {
    var passed: u64 = 0;

    // Geometry first: the size decides where the overflow case has to start,
    // and a size the program invented would test the wrong boundary.
    // Left `undefined` rather than zeroed: the ioctl fills it, and nothing
    // below reads it unless that call returned 0. A zeroing initialiser is
    // also how the SSE store above got in.
    var fb: FbInfo = undefined;
    const geom = syscall3(NR_IOCTL, FB_FD, IOCTL_FB_GET_INFO, @intFromPtr(&fb));
    say("ioctl(FB_GET_INFO)", geom);
    if (geom != 0) {
        write("  mmapprobe: no framebuffer geometry, so the rest would test nothing\n");
        _ = syscall3(NR_EXIT, 0, 0, 0);
        unreachable;
    }
    write("  mmapprobe: framebuffer is ");
    print_dec(fb.width);
    write("x");
    print_dec(fb.height);
    write(", pitch ");
    print_dec(fb.pitch);
    write(", bpp ");
    print_dec(fb.bpp);
    write(", type ");
    print_dec(fb.fb_type);
    write("\n");

    const size: u64 = @as(u64, fb.pitch) * fb.height;
    const pages: u64 = (size + 0xFFF) / 0x1000;
    if (pages == 0) {
        write("  mmapprobe: framebuffer has no pages\n");
        _ = syscall3(NR_EXIT, 0, 0, 0);
        unreachable;
    }

    // 1. The first address that is not userspace. Walks into PML4[256],
    //    which is the kernel's. Asked first because it is the one that
    //    corrupts the shared tables without also stopping the boot, so the
    //    gate's table check downstream has something to find.
    const r_top = mmap(AT_TOP, FB_FD);
    say("mmap at the first non-user address", r_top);
    if (r_top < 0) passed |= 1 << 0;

    // 2. The kernel half proper.
    const r_kernel = mmap(KERNEL_VA, FB_FD);
    say("mmap at the kernel half", r_kernel);
    if (r_kernel < 0) passed |= 1 << 1;

    // 3. One byte past a page boundary.
    const r_align = mmap(VALID + 1, FB_FD);
    say("mmap at an unaligned address", r_align);
    if (r_align < 0) passed |= 1 << 2;

    // 4. An address whose end wraps past zero.
    const r_wrap = mmap(WRAPS, FB_FD);
    say("mmap at an address whose end wraps", r_wrap);
    if (r_wrap < 0) passed |= 1 << 3;

    // 5. An fd that does not fit in the i32 the dispatcher converts it to.
    //    The bit still being clear afterwards is the whole point: if the
    //    conversion traps, this program never reaches the next line.
    const r_wide = mmap(VALID, 0xFFFF_FFFF_0000_0000);
    say("mmap with an fd wider than i32", r_wide);
    if (r_wide < 0) passed |= 1 << 4;

    // 6. A plain fd, which is not the framebuffer's.
    const r_fd0 = mmap(VALID, 0);
    say("mmap with fd 0", r_fd0);
    if (r_fd0 < 0) passed |= 1 << 5;

    // 7. The highest placement that still fits. Must be granted.
    const last_legal = USER_TOP - pages * 0x1000;
    const r_edge = mmap(last_legal, FB_FD);
    say("mmap at the last placement that fits under the top", r_edge);
    if (r_edge >= 0 and @as(u64, @bitCast(r_edge)) == last_legal) passed |= 1 << 6;

    // 8. The request this call exists for.
    const r_ok = mmap(VALID, FB_FD);
    say("mmap at a valid user address", r_ok);
    if (r_ok >= 0 and @as(u64, @bitCast(r_ok)) == VALID) passed |= 1 << 7;

    // And it has to actually be the framebuffer: writable, readable, and
    //    the bytes that come back are the ones that went in. Restored
    //    afterwards so the probe does not leave the screen scribbled on.
    // 9. And it has to actually be the framebuffer.
    if ((passed & (1 << 7)) != 0) {
        const px: [*]volatile u32 = @ptrFromInt(VALID);
        const words = size / 4;
        const probe_at = [_]u64{ 0, words / 2, words - 1 };
        var good = true;
        for (probe_at) |w| {
            const saved = px[w];
            const pattern: u32 = 0xA5A5_5A5A ^ @as(u32, @truncate(w));
            px[w] = pattern;
            if (px[w] != pattern) good = false;
            px[w] = saved;
        }
        if (good) passed |= 1 << 8;
        write("  mmapprobe: wrote and read back three words of the mapping: ");
        write(if (good) "they match\n" else "THEY DO NOT MATCH\n");
    }

    // 10. The same range twice. The second request would rewrite leaf entries
    //    the first one installed and append a second region describing the
    //    same addresses.
    const r_again = mmap(VALID, FB_FD);
    say("mmap over a range already mapped", r_again);
    if (r_again < 0) passed |= 1 << 9;

    write("  mmapprobe: done, ");
    print_dec(@popCount(passed));
    write(" of 10\n");

    _ = syscall3(NR_EXIT, passed, 0, 0);
    unreachable;
}

comptime {
    if (ALL_PASSED != 0x3FF) @compileError("ten questions, ten bits");
}
