//! The x86_64 user-memory layer: every address a process hands the kernel
//! goes through here, and the kernel never dereferences one itself.
//!
//! A system call arrives with pointers that mean something only in the
//! calling process's address space, and that the process may be lying
//! about. Until this existed, sys_read, sys_write and sys_open cast the
//! argument to a pointer and used it: a bad one was a page fault in the
//! kernel, which halts the machine, rather than an EFAULT the program gets
//! back. A pointer into the kernel's own half would have been read or
//! written on the program's behalf.
//!
//! aarch64 answers the question with hardware: `at s1e0r` and `at s1e0w`
//! translate an address exactly as EL0 would and say whether it faults.
//! x86_64 has no such instruction, so this walks the page tables the MMU
//! would walk, from the CR3 that is loaded (the calling process's, since a
//! system call runs on its CR3), and applies the same rule the CPU applies:
//! a user access is allowed only if every level on the path is present and
//! user-accessible, and a write only if every level is writable as well.
//! A huge page ends the walk early, the way it ends the CPU's.
//!
//! The copy itself then goes through the direct map of the physical frame,
//! page by page, because two consecutive user pages are two unrelated
//! frames. The kernel therefore touches no user virtual address at all,
//! which is what lets SMAP be switched on: with CR4.SMAP set, a kernel
//! access to a user page through its user address is a fault, so any
//! path that still did that would show up as a crash under `-cpu max`
//! rather than as silent permissiveness.

const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");

/// The first non-user address. Everything at or above it is the kernel's
/// half or non-canonical, and no user pointer may name it.
///
/// Defined in `vmm` and re-exported here. It was a second copy of the same
/// number until `map_page` needed it too, and a limit that two files each
/// state for themselves is a limit that can come to disagree.
pub const USER_TOP: u64 = vmm.USER_TOP;

pub const PAGE_SIZE: u64 = pmm.PAGE_SIZE;
const HHDM_BASE: u64 = 0xFFFF_8000_0000_0000;

fn read_cr3() u64 {
    return asm volatile ("movq %%cr3, %[out]"
        : [out] "=r" (-> u64),
    );
}

fn table_at(phys: u64) *const [512]u64 {
    return @ptrFromInt(HHDM_BASE + (phys & vmm.ADDR_MASK));
}

/// Translate one user address the way the CPU would for a user-mode access,
/// against the currently loaded tables. Returns the physical address, or
/// null if the access would fault: the address is outside the user half,
/// some level of the walk is absent or supervisor-only, or (for a write)
/// some level is read-only.
fn translate(va: u64, for_write: bool) ?u64 {
    if (va >= USER_TOP) return null;
    var need: u64 = vmm.PAGE_PRESENT | vmm.PAGE_USER;
    if (for_write) need |= vmm.PAGE_WRITE;

    const shifts = [_]u6{ 39, 30, 21, 12 };
    var table_phys = read_cr3();
    var level: usize = 0;
    while (level < 4) : (level += 1) {
        const entry = table_at(table_phys)[(va >> shifts[level]) & 0x1FF];
        if (entry & need != need) return null;
        if (level == 3) return (entry & vmm.ADDR_MASK) | (va & (PAGE_SIZE - 1));
        if (level > 0 and (entry & vmm.PAGE_HUGE) != 0) {
            // A 1 GiB (level 1) or 2 MiB (level 2) page: the entry holds the
            // frame, and the rest of the address is the offset into it.
            const size: u64 = if (level == 1) (1 << 30) else (1 << 21);
            return (entry & vmm.ADDR_MASK & ~(size - 1)) | (va & (size - 1));
        }
        table_phys = entry & vmm.ADDR_MASK;
    }
    unreachable;
}

pub fn translate_user_read(va: u64) ?u64 {
    return translate(va, false);
}

pub fn translate_user_write(va: u64) ?u64 {
    return translate(va, true);
}

/// True if every byte of [va, va+len) is readable by the process.
pub fn user_range_readable(va: u64, len: u64) bool {
    return range_ok(va, len, false);
}

/// True if every byte of [va, va+len) is writable by the process.
pub fn user_range_writable(va: u64, len: u64) bool {
    return range_ok(va, len, true);
}

fn range_ok(va: u64, len: u64, for_write: bool) bool {
    if (len == 0) return va < USER_TOP;
    const end = va +| len;
    if (end < va or end > USER_TOP) return false;
    var page = va & ~(PAGE_SIZE - 1);
    while (page < end) : (page += PAGE_SIZE) {
        if (translate(page, for_write) == null) return false;
    }
    return true;
}

/// Copy `dst.len` bytes out of the process at `src`. False if any page of
/// the range is not readable by the process; bytes before that page may
/// already have been copied, and the caller reports the whole call failed.
pub fn copy_from_user(dst: []u8, src: u64) bool {
    var done: usize = 0;
    while (done < dst.len) {
        const va = src +| done;
        const phys = translate(va, false) orelse return false;
        const page_left: usize = @intCast(PAGE_SIZE - (va & (PAGE_SIZE - 1)));
        const n = @min(dst.len - done, page_left);
        const from: [*]const u8 = @ptrFromInt(HHDM_BASE + phys);
        @memcpy(dst[done..][0..n], from[0..n]);
        done += n;
    }
    return true;
}

/// Copy `src` into the process at `dst`. False if any page of the range is
/// not writable by the process. A page the process may read but not write,
/// such as its own text, is refused here: the translation is for writing.
pub fn copy_to_user(dst: u64, src: []const u8) bool {
    var done: usize = 0;
    while (done < src.len) {
        const va = dst +| done;
        const phys = translate(va, true) orelse return false;
        const page_left: usize = @intCast(PAGE_SIZE - (va & (PAGE_SIZE - 1)));
        const n = @min(src.len - done, page_left);
        const to: [*]u8 = @ptrFromInt(HHDM_BASE + phys);
        @memcpy(to[0..n], src[done..][0..n]);
        done += n;
    }
    return true;
}

/// Copy a NUL-terminated string out of the process into `buf`, without the
/// terminator. Null if a page is unreadable before the terminator, or the
/// string does not fit: a path that long is not one this kernel can open,
/// and treating it as EFAULT is the same answer Linux gives for a name it
/// cannot copy.
pub fn copy_user_string(src: u64, buf: []u8) ?[]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const va = src +| len;
        const phys = translate(va, false) orelse return null;
        const page_left: usize = @intCast(PAGE_SIZE - (va & (PAGE_SIZE - 1)));
        const from: [*]const u8 = @ptrFromInt(HHDM_BASE + phys);
        var i: usize = 0;
        while (i < page_left and len < buf.len) : (i += 1) {
            const c = from[i];
            if (c == 0) return buf[0..len];
            buf[len] = c;
            len += 1;
        }
    }
    return null;
}

/// Write one plain value into the process, for the pointer-to-result
/// arguments (wait's status, ioctl's info struct).
pub fn put_user(comptime T: type, dst: u64, value: T) bool {
    const bytes: *const [@sizeOf(T)]u8 = @ptrCast(&value);
    return copy_to_user(dst, bytes);
}
