//! The interrupt controller on QEMU's `virt` machine — GICv2 or GICv3.
//!
//! The exception vectors have been installed since the ARM kernel first
//! booted, and until the timer arrived nothing could ever reach them: no
//! interrupt source existed, so every one of the sixteen entries reported and
//! halted. This is the half of giving them something real to do that decides
//! *which* interrupt fired and says it has been handled.
//!
//! **Why both versions.** Apple Silicon has no GIC at all — the real
//! controller is Apple's AIC — so a Mac running this under QEMU gets an
//! emulated one, and under HVF acceleration QEMU emulates only a GICv3:
//! `-accel hvf` with a GICv2 answers `HVF does not support GICv2 emulation`
//! and refuses to start. Speaking only GICv2 therefore meant the kernel could
//! never run accelerated on the hardware it is aimed at. The emulated
//! cortex-a72 path still builds a GICv2, and still has to work, so the version
//! is read from the device tree and both drivers stay.
//!
//! **GICv2.** Two register blocks. The *distributor* decides which interrupts
//! exist and where they go; the *CPU interface* is what this core reads to
//! find out which one fired and to say it has finished.
//!
//! **GICv3.** The distributor is still there, but the CPU interface is gone
//! from memory: ICC_PMR_EL1, ICC_IAR1_EL1 and ICC_EOIR1_EL1 are system
//! registers, reached with MSR/MRS, and EL2 has to have set ICC_SRE_EL2.Enable
//! before EL1 may touch them — `boot.S` does that, guarded on
//! ID_AA64PFR0_EL1.GIC. In its place is a *redistributor* per core, and the
//! interrupts that are private to a core — SGIs and PPIs, which is where the
//! timer lives — are enabled there rather than in the distributor. Enabling
//! the timer in the distributor on a GICv3 is accepted and does nothing, so
//! that mistake is a kernel that boots and never ticks.
//!
//! A private peripheral interrupt (PPI) is per-core and needs no routing; a
//! shared one (SPI) does, and gets it. What is deliberately *not* set on
//! either version is the configuration register that says whether an interrupt
//! is edge- or level-triggered: the reset configuration is left alone, and the
//! keyboard test is what says whether events keep arriving past the first one.
//! Writing a guess there would make that test pass or fail for a reason
//! nothing had checked.

const vm = @import("vm.zig");
const fdt = @import("../../boot/fdt.zig");

/// Which controller this machine has. `unknown` until `detect` has run, which
/// is deliberate: every entry point below is a no-op until then, so a caller
/// that reaches the GIC before the device tree has been read does nothing
/// rather than writing to whichever addresses happened to be compiled in.
pub const Version = enum { unknown, v2, v3 };

var version: Version = .unknown;

/// Distributor base, virtual. The same block on both versions, and at the same
/// address on this machine, but it is read from the tree rather than assumed.
var dist: u64 = 0;

/// GICv2's CPU interface, virtual. Unused on v3, which has no such block.
var cpu_if: u64 = 0;

/// GICv3's redistributor region, virtual: the first core's RD_base. Each core
/// gets two 64 KiB frames, RD_base then SGI_base, so core 0's SGI frame — the
/// one that enables PPIs — is 64 KiB above this.
var redist: u64 = 0;

/// Returned by `acknowledge` when the interrupt was spurious. Both versions
/// use 1023 for this, and it must not be passed to `end`.
pub const SPURIOUS: u32 = 1023;

/// One redistributor's second frame, where a core's own SGIs and PPIs live.
const GICR_SGI_OFFSET: u64 = 0x10000;

fn mmio_write32(addr: u64, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(addr);
    p.* = value;
}

fn mmio_read32(addr: u64) u32 {
    const p: *volatile u32 = @ptrFromInt(addr);
    return p.*;
}

fn mmio_write64(addr: u64, value: u64) void {
    const p: *volatile u64 = @ptrFromInt(addr);
    p.* = value;
}

/// Work out which controller is present and where its blocks are.
///
/// Must run before `init`. Called with the device tree the boot path parsed;
/// with none, or with a node this does not recognise, the version stays
/// `unknown` and the kernel runs without interrupts rather than writing to a
/// guess — `describe_machine` reports that, and a machine that reaches this
/// state has bigger problems than the timer.
pub fn detect(tree: ?fdt.Fdt) void {
    const t = tree orelse return;

    // `compatible` is a list of NUL-separated strings, most specific first.
    // QEMU's `virt` says `arm,gic-v3` for a GICv3 and `arm,cortex-a15-gic`
    // for a GICv2 — the latter being the name of the first CPU that shipped
    // the design rather than anything about an A15.
    const compat = fdt.node_prop_prefix(&t, "intc", "compatible") orelse return;

    var regs: [4]fdt.Region = undefined;
    const n = fdt.node_regs(&t, "intc", &regs);
    if (n < 2) return;

    if (contains_str(compat, "arm,gic-v3")) {
        version = .v3;
        dist = regs[0].base + vm.KERNEL_VA_BASE;
        redist = regs[1].base + vm.KERNEL_VA_BASE;
    } else {
        version = .v2;
        dist = regs[0].base + vm.KERNEL_VA_BASE;
        cpu_if = regs[1].base + vm.KERNEL_VA_BASE;
    }
}

/// Whether `haystack`, a NUL-separated property value, holds `needle` as one
/// of its entries. A prefix test would accept `arm,gic-v3-its`, which is the
/// ITS child rather than the controller.
fn contains_str(haystack: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i < haystack.len) {
        var j = i;
        while (j < haystack.len and haystack[j] != 0) j += 1;
        const entry = haystack[i..j];
        if (entry.len == needle.len) {
            var k: usize = 0;
            var same = true;
            while (k < entry.len) : (k += 1) {
                if (entry[k] != needle[k]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        i = j + 1;
    }
    return false;
}

/// Which controller `detect` found, for the boot report.
pub fn detected() Version {
    return version;
}

// ── GICv2 ────────────────────────────────────────────────────────────────
// Offsets from the two block bases.

const GICD_CTLR: u64 = 0x000;
const GICD_ISENABLER: u64 = 0x100; // one bit per INTID
const GICD_IPRIORITYR: u64 = 0x400; // one byte per INTID
const GICD_ITARGETSR: u64 = 0x800; // one byte per INTID: which cores (v2 only)
const GICD_IGROUPR: u64 = 0x080; // one bit per INTID: group 0 or 1 (v3)
const GICD_IROUTER: u64 = 0x6000; // eight bytes per INTID: affinity (v3)

const GICC_PMR: u64 = 0x004; // priority mask
const GICC_IAR: u64 = 0x00C; // acknowledge: read the pending INTID
const GICC_EOIR: u64 = 0x010; // end of interrupt
const GICC_CTLR: u64 = 0x000;

// ── GICv3 redistributor ──────────────────────────────────────────────────
// RD_base holds the wake-up protocol; SGI_base, 64 KiB above it, holds the
// per-core interrupt configuration.

const GICR_WAKER: u64 = 0x0014;
const GICR_WAKER_PROCESSOR_SLEEP: u32 = 1 << 1;
const GICR_WAKER_CHILDREN_ASLEEP: u32 = 1 << 2;

const GICR_IGROUPR0: u64 = 0x0080;
const GICR_ISENABLER0: u64 = 0x0100;
const GICR_IPRIORITYR: u64 = 0x0400;

// ── GICv3 CPU interface: system registers ────────────────────────────────
//
// Zig has no named form for these, so they are reached by their encoding.
// S3_0_C12_C12_x is the ICC_*_EL1 block.

fn write_icc_pmr(v: u64) void {
    asm volatile ("msr S3_0_C4_C6_0, %[v]"
        :
        : [v] "r" (v),
    );
}

fn write_icc_igrpen1(v: u64) void {
    asm volatile ("msr S3_0_C12_C12_7, %[v]"
        :
        : [v] "r" (v),
    );
}

fn write_icc_sre(v: u64) void {
    asm volatile ("msr S3_0_C12_C12_5, %[v]"
        :
        : [v] "r" (v),
    );
}

fn read_icc_sre() u64 {
    return asm volatile ("mrs %[out], S3_0_C12_C12_5"
        : [out] "=r" (-> u64),
    );
}

fn read_icc_iar1() u64 {
    return asm volatile ("mrs %[out], S3_0_C12_C12_0"
        : [out] "=r" (-> u64),
    );
}

fn write_icc_eoir1(v: u64) void {
    asm volatile ("msr S3_0_C12_C12_1, %[v]"
        :
        : [v] "r" (v),
    );
}

fn isb() void {
    asm volatile ("isb" ::: "memory");
}

/// Bring the controller up and enable one interrupt.
///
/// The priority mask matters more than it looks: it starts at 0, which masks
/// *everything*, so a GIC that is otherwise configured correctly delivers
/// nothing at all. 0xF0 lets every priority through.
pub fn init(intid: u32) void {
    switch (version) {
        .unknown => return,
        .v2 => {
            // Distributor off while it is configured, then on.
            mmio_write32(dist + GICD_CTLR, 0);
            configure(intid);
            mmio_write32(dist + GICD_CTLR, 1);

            mmio_write32(cpu_if + GICC_PMR, 0xF0);
            mmio_write32(cpu_if + GICC_CTLR, 1);
        },
        .v3 => {
            // The system register interface first: everything else on this
            // core's side is a system register, and they read as zero and
            // ignore writes until SRE is set.
            write_icc_sre(read_icc_sre() | 1);
            isb();

            // Wake this core's redistributor. It comes out of reset asleep,
            // and a sleeping redistributor forwards nothing — the one failure
            // that looks exactly like a timer that was never programmed.
            var waker = mmio_read32(redist + GICR_WAKER);
            waker &= ~GICR_WAKER_PROCESSOR_SLEEP;
            mmio_write32(redist + GICR_WAKER, waker);
            // Bounded, because a machine that never clears this is a machine
            // this kernel cannot use, and spinning forever says less than
            // carrying on and failing at the first interrupt.
            var spins: u32 = 0;
            while (spins < 1_000_000) : (spins += 1) {
                if (mmio_read32(redist + GICR_WAKER) & GICR_WAKER_CHILDREN_ASLEEP == 0) break;
            }

            // Affinity routing, then the group enables. ARE has to be set
            // before GICD_IROUTER means anything, and writing it at the same
            // time as an enable is not guaranteed to be seen in that order.
            mmio_write32(dist + GICD_CTLR, 1 << 4); // ARE
            mmio_write32(dist + GICD_CTLR, (1 << 4) | (1 << 1) | 1); // + Grp1, Grp0

            configure(intid);

            write_icc_pmr(0xF0);
            write_icc_igrpen1(1);
            isb();
        },
    }
}

/// Let one more interrupt through, after `init` has run.
///
/// Separate from `init` rather than a second call to it, because init turns
/// the distributor off and on again: doing that to add a second source would
/// briefly stop delivering the first, and a timer that misses a tick during
/// device probing is a hang waiting to happen.
pub fn enable(intid: u32) void {
    if (version == .unknown) return;
    configure(intid);
}

/// Everything that is per-interrupt rather than per-controller.
fn configure(intid: u32) void {
    const id: u64 = intid;

    // Under 32 is private to a core: an SGI or a PPI. On a GICv2 those live
    // in the distributor like everything else; on a GICv3 they live in this
    // core's redistributor, and the distributor's copy of those bits is
    // reserved. The timer is INTID 30, so this branch is the one that decides
    // whether the clock ticks.
    if (version == .v3 and intid < 32) {
        const sgi = redist + GICR_SGI_OFFSET;

        // Group 1. A GICv3 delivers a Group 0 interrupt as an FIQ, which this
        // kernel's vectors do not take, so an interrupt left in group 0 is one
        // that fires into nothing.
        const grp = mmio_read32(sgi + GICR_IGROUPR0);
        mmio_write32(sgi + GICR_IGROUPR0, grp | (@as(u32, 1) << @intCast(intid)));

        const prio: *volatile u8 = @ptrFromInt(sgi + GICR_IPRIORITYR + id);
        prio.* = 0x00;

        mmio_write32(sgi + GICR_ISENABLER0, @as(u32, 1) << @intCast(intid));
        return;
    }

    // Priority 0 (highest). One byte per INTID.
    const prio: *volatile u8 = @ptrFromInt(dist + GICD_IPRIORITYR + id);
    prio.* = 0x00;

    if (version == .v3) {
        // Group 1, for the same reason as above.
        const off = GICD_IGROUPR + (id / 32) * 4;
        const grp = mmio_read32(dist + off);
        mmio_write32(dist + off, grp | (@as(u32, 1) << @intCast(intid % 32)));
    }

    // Routing. SGIs and PPIs (0..31) are per-core and ignore this — writes to
    // those entries are architecturally reserved, so they are not made. An SPI
    // is routed by the distributor, and on a GIC with more than one CPU
    // interface it reaches nobody until this says which.
    //
    // Nothing on this machine proves that. It was tested on GICv2 by removing
    // the write and running the keyboard gate, which passed: QEMU's `virt`
    // with one vCPU builds a uniprocessor GIC where the register is RAZ/WI and
    // the only CPU interface gets the interrupt either way. So it is written
    // because the architecture requires it of a multi-core GIC and this kernel
    // will meet one, not because anything here noticed — and it is said
    // plainly rather than left to look verified.
    if (intid >= 32) {
        if (version == .v3) {
            // Affinity 0.0.0.0 — core 0, the only one running. The alternative
            // is bit 31, "any participating PE", which would be a choice about
            // scheduling that this kernel is not yet in a position to make.
            mmio_write64(dist + GICD_IROUTER + id * 8, 0);
        } else {
            const target: *volatile u8 = @ptrFromInt(dist + GICD_ITARGETSR + id);
            target.* = 0x01; // CPU interface 0, the only core that is running
        }
    }

    // Enable it: one bit per INTID, 32 to a register.
    //
    // GICD_ISENABLER is write-1-to-set: the bits written as zero are left
    // alone, so this adds an interrupt rather than replacing the set. A
    // read-modify-write would be wrong as well as unnecessary — it would
    // re-write bits the hardware may have changed underneath.
    const reg = dist + GICD_ISENABLER + (id / 32) * 4;
    mmio_write32(reg, @as(u32, 1) << @intCast(intid % 32));
}

/// Which interrupt fired. Every acknowledge must be paired with `end`, or the
/// CPU interface keeps that priority active and delivers nothing further.
pub fn acknowledge() u32 {
    return switch (version) {
        .unknown => SPURIOUS,
        .v2 => mmio_read32(cpu_if + GICC_IAR) & 0x3FF,
        // A GICv3 INTID is 24 bits, not 10: masking to 0x3FF here would turn
        // the spurious 1023 into itself but fold a real LPI into nonsense.
        .v3 => @intCast(read_icc_iar1() & 0xFF_FFFF),
    };
}

pub fn end(intid: u32) void {
    switch (version) {
        .unknown => {},
        .v2 => mmio_write32(cpu_if + GICC_EOIR, intid),
        .v3 => write_icc_eoir1(intid),
    }
}
