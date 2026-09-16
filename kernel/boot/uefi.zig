//! UEFI loader stub.
//!
//! When booted via UEFI (rather than legacy multiboot), the firmware
//! drops us in long mode with services already up. We translate the
//! UEFI memory map into the same MemoryMapEntry layout the kernel
//! expects from the multiboot path, exit boot services, then jump
//! to kernel_main with our synthesised BootInfo.
//!
//! The two boot paths converge at kernel_main() so the rest of the
//! kernel never has to care which loader it came from.

const std = @import("std");
const uefi = std.os.uefi;
const multiboot = @import("multiboot2.zig");
const main = @import("../main.zig");

pub fn efi_main(handle: uefi.Handle, system_table: *uefi.tables.SystemTable) uefi.Status {
    const con_out = system_table.con_out.?;
    _ = con_out.outputString(toUcs2("KyanOS UEFI loader\r\n"));

    const bs = system_table.boot_services.?;

    // Allocate the memory map. EFI tells us the size in two stages.
    var mmap_size: usize = 0;
    var map_key: usize = 0;
    var desc_size: usize = 0;
    var desc_version: u32 = 0;
    var mmap_buf: [*]u8 = undefined;

    var status = bs.getMemoryMap(&mmap_size, @ptrCast(mmap_buf), &map_key, &desc_size, &desc_version);
    // First call returns BUFFER_TOO_SMALL with the required size — allocate + retry.
    if (status == .buffer_too_small) {
        mmap_size += 2 * desc_size;
        status = bs.allocatePool(.loader_data, mmap_size, &mmap_buf);
        if (status != .success) return status;
        status = bs.getMemoryMap(&mmap_size, @ptrCast(mmap_buf), &map_key, &desc_size, &desc_version);
    }
    if (status != .success) return status;

    // TODO: build a heap-allocated MemoryMapEntry slice that mirrors
    // the EFI map, then exit boot services and jump to kernel_main.
    // The full implementation lives in a follow-up; this skeleton
    // documents the boot path so the build system can wire it in.

    _ = bs.exitBootServices(handle, map_key);

    // Once boot services are gone we can't print via UEFI any more.
    // The console driver takes over via the framebuffer it claimed.

    var boot_info = main.BootInfo{
        .memory_map = &.{},
        .framebuffer = null,
        .rsdp = null,
        .cmdline = "",
    };
    main.kernel_main(&boot_info);
}

fn toUcs2(comptime ascii: []const u8) [*:0]const u16 {
    comptime var buf: [ascii.len + 1]u16 = undefined;
    comptime {
        for (ascii, 0..) |c, i| buf[i] = c;
        buf[ascii.len] = 0;
    }
    return @ptrCast(&buf);
}
