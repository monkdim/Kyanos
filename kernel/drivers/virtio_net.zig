//! virtio-net driver — paravirtualised NIC for QEMU/KVM/Xen.
//!
//! virtio is the simplest way to get networking inside a VM, which
//! is where KyanOS development happens. Real Intel NICs (e1000,
//! igc, AX2xx) live in their own drivers and ship in a later phase.

const std = @import("std");
const pci = @import("pci.zig");

pub const VENDOR = 0x1AF4;
pub const DEVICE = 0x1000;

pub fn scan() !void {
    var iter = pci.iterate();
    while (iter.next()) |dev| {
        if (dev.vendor == VENDOR and dev.device == DEVICE) {
            try attach(dev);
        }
    }
}

fn attach(dev: pci.Device) !void {
    _ = dev;
    // TODO: setup virtq, MAC read, IRQ handler, ring buffer
    //       management. Hook into the kernel's network stack
    //       (/dev/net0) once it exists.
}

pub fn send_frame(frame: []const u8) !void {
    _ = frame;
    return error.NotImplemented;
}

pub fn recv_frame(buf: []u8) !usize {
    _ = buf;
    return error.NotImplemented;
}
