// KyanOS aarch64 boot stub — QEMU 'virt' / Apple-Silicon-class AArch64.
//
// The kernel is linked for high virtual addresses (0xFFFF_FF80_0000_0000 +
// physical) and entered at physical ones, so this stub runs in the gap
// between the two: nothing it does may depend on an absolute address being
// mapped, and everything it computes must be turned into a physical address
// by hand. That ends the moment the MMU comes on and it branches high.
//
// In order:
//   1. park secondary CPUs (only the boot CPU proceeds),
//   2. drop from EL2 to EL1 if needed,
//   3. enable FP/SIMD access at EL1 (Zig may emit SIMD; without this,
//      those instructions trap),
//   4. work out the virtual-to-physical offset from the program counter,
//   5. build a translation table that maps the kernel both where it is and
//      where it is linked, and turn the MMU on,
//   6. branch to the high mapping, take a high stack, zero .bss,
//   7. call kernel_main_aarch64.

// ── Translation constants ───────────────────────────────────────────────
//
// Kept as assembler expressions rather than magic numbers so the bit
// positions are checkable against the ARM ARM without arithmetic.

// Level-1 block descriptor bits.
.set DESC_BLOCK,   0b01           // valid + block (not a table pointer)
.set DESC_AF,      (1 << 10)      // access flag; without it every access faults
.set DESC_SH_INNER,(0b11 << 8)    // inner shareable
.set ATTR_DEVICE,  (0 << 2)       // MAIR slot 0: Device-nGnRnE
.set ATTR_NORMAL,  (1 << 2)       // MAIR slot 1: Normal write-back

.set BLOCK_DEVICE, (DESC_AF | ATTR_DEVICE | DESC_BLOCK)
.set BLOCK_NORMAL, (DESC_AF | DESC_SH_INNER | ATTR_NORMAL | DESC_BLOCK)

// MAIR_EL1: slot 0 Device-nGnRnE (0x00), slot 1 Normal write-back
// read/write-allocate (0xFF).
.set MAIR_VALUE,   (0x00 << 0) | (0xFF << 8)

// TCR_EL1. Both halves get a 39-bit VA space with a 4 KiB granule and
// cacheable, inner-shareable table walks. Note TG0 and TG1 encode the
// granule differently (TG0: 0b00 = 4 KiB; TG1: 0b10 = 4 KiB) — a detail
// that silently produces a dead machine if copied across.
.set TCR_T0SZ,  25                // 2^(64-25) = 512 GiB of low half
.set TCR_T1SZ,  (25 << 16)        // and the same at the top
.set TCR_IRGN0, (0b01 << 8)
.set TCR_ORGN0, (0b01 << 10)
.set TCR_SH0,   (0b11 << 12)
.set TCR_TG0,   (0b00 << 14)      // 4 KiB
.set TCR_IRGN1, (0b01 << 24)
.set TCR_ORGN1, (0b01 << 26)
.set TCR_SH1,   (0b11 << 28)
.set TCR_TG1,   (0b10 << 30)      // 4 KiB
.set TCR_IPS,   (0b010 << 32)     // 40-bit intermediate physical addresses
.set TCR_VALUE, (TCR_T0SZ | TCR_IRGN0 | TCR_ORGN0 | TCR_SH0 | TCR_TG0 | TCR_T1SZ | TCR_IRGN1 | TCR_ORGN1 | TCR_SH1 | TCR_TG1 | TCR_IPS)

// SCTLR_EL1: translation, data cache, instruction cache.
.set SCTLR_M,   (1 << 0)
.set SCTLR_C,   (1 << 2)
.set SCTLR_I,   (1 << 12)

.section .text.boot
.global _start
.type _start, %function
_start:
    // ── ARM64 Linux Image header ────────────────────────────────────────
    //
    // 64 bytes, laid out by Documentation/arch/arm64/booting.rst. Its
    // presence is what makes a bootloader treat this as a kernel rather than
    // as an opaque blob to jump into — and following that protocol is the
    // only way to be handed a device tree, because the bootloader puts its
    // address in x0 as part of it.
    //
    // QEMU loading an ELF does neither: it jumps straight to the ELF entry
    // point and loads no device tree at all, even when given `-dtb`. That was
    // measured, not assumed — a scan of the whole of RAM found no tree.
    //
    // This is not a QEMU workaround. m1n1, the bootloader onto Apple Silicon,
    // boots exactly this format and hands over a device tree the same way, as
    // do U-Boot and EDK2. The ELF is still built, for symbols and debugging;
    // the image booted is the flat binary with this header on the front.
    b       .Lheader_end            // code0: a real instruction, as required
    .long   0                       // code1
    .quad   0x80000                 // text_offset: load 512 KiB above RAM base
    .quad   __image_size            // image_size: memory to reserve, .bss included
    .quad   0                       // flags: 4 KiB pages, no constraints
    .quad   0                       // res2
    .quad   0                       // res3
    .quad   0                       // res4
    .ascii  "ARM\x64"               // magic
    .long   0                       // res5
.Lheader_end:

    // Only the boot CPU (Aff0 == 0) continues; others wait forever.
    mrs     x1, mpidr_el1
    and     x1, x1, #0xFF
    cbz     x1, .Lprimary
.Lpark:
    wfe
    b       .Lpark

.Lprimary:
    // If we entered at EL2, configure EL1 as AArch64 and eret down to it.
    mrs     x1, CurrentEL
    lsr     x1, x1, #2
    cmp     x1, #2
    b.ne    .Lat_el1

    movz    x1, #0x8000, lsl #16        // HCR_EL2.RW (bit 31): EL1 is AArch64
    msr     hcr_el2, x1
    mov     x1, #0x3c5                  // DAIF masked, M[3:0]=0b0101 (EL1h)
    msr     spsr_el2, x1
    adr     x1, .Lat_el1                // PC-relative: still a physical address
    msr     elr_el2, x1
    eret

.Lat_el1:
    // Allow FP/SIMD at EL1 (CPACR_EL1.FPEN = 0b11).
    mrs     x1, cpacr_el1
    orr     x1, x1, #(3 << 20)
    msr     cpacr_el1, x1
    isb

    // Privileged Access Never, where the CPU has it.
    //
    // Clearing SCTLR_EL1.SPAN makes PSTATE.PAN set on every exception entry
    // to EL1, so any access the kernel makes to memory a process can also
    // reach faults. That is a rule this kernel already follows — a user
    // pointer is translated through the process's page tables and read
    // through the kernel's own direct map, never dereferenced — and this is
    // what makes it enforced rather than merely intended. A missed conversion
    // becomes a fault at the point of the mistake instead of code that works
    // here and not on hardware.
    //
    // ARMv8.1 and later. Asked for rather than assumed: ID_AA64MMFR1_EL1.PAN
    // is zero on a core without it (QEMU's cortex-a72, among others), and
    // clearing a bit that does not exist would be a silent no-op that reads
    // like it worked.
    mrs     x1, id_aa64mmfr1_el1
    ubfx    x1, x1, #20, #4         // ID_AA64MMFR1_EL1.PAN
    cbz     x1, .Lno_pan
    mrs     x2, sctlr_el1
    bic     x2, x2, #(1 << 23)      // SPAN = 0
    msr     sctlr_el1, x2
    isb
.Lno_pan:

    // ── Where are we, and where do we think we are? ─────────────────────
    //
    // `adrp` is PC-relative, so with the MMU off it yields the address the
    // kernel was actually loaded at. `ldr =` pulls the link-time address out
    // of a literal pool. The difference between them is the offset every
    // absolute symbol in this stub has to be corrected by until translation
    // is live. x28 holds it, and nothing below may clobber it. x0 holds the
    // device tree pointer the bootloader passed and is equally untouchable.
    adrp    x28, _start
    add     x28, x28, #:lo12:_start     // physical address of _start
    ldr     x27, =_start                // virtual address of _start
    sub     x28, x27, x28               // x28 = virtual - physical

    // A physical stack, so the window before translation is not a special
    // case where a call would corrupt memory.
    ldr     x1, =__stack_top
    sub     x1, x1, x28
    mov     sp, x1

    // ── The translation table ───────────────────────────────────────────
    //
    // One level-1 table with 512 entries of 1 GiB serves *both* halves of
    // the address space. That is not a shortcut: a kernel virtual address is
    // its physical address plus 0xFFFF_FF80_0000_0000, and that base is
    // exactly the start of the TTBR1 range, so a physical address lands on
    // the same level-1 index whichever register translates it. The same
    // table therefore describes the identity map the next instruction fetch
    // needs and the high map everything afterwards uses.
    ldr     x1, =aarch64_l1_table
    sub     x1, x1, x28                 // physical address of the table

    // Zero it. It lives outside .bss (which is still full of whatever the
    // bootloader left) and nothing has cleared it.
    mov     x2, x1
    mov     x3, #512
.Lzero_l1:
    str     xzr, [x2], #8
    subs    x3, x3, #1
    b.ne    .Lzero_l1

    // [0] The first gigabyte, Device-nGnRnE. Every MMIO register this kernel
    //     touches on `virt` is in it: the PL011 UART at 0x0900_0000, the GIC
    //     at 0x0800_0000, fw_cfg at 0x0902_0000.
    mov     x2, #BLOCK_DEVICE
    str     x2, [x1]

    // [k] The gigabyte the kernel is running in, Normal write-back. Which
    //     one that is comes from the program counter rather than a constant,
    //     so a machine that puts its RAM somewhere other than 0x4000_0000
    //     maps the gigabyte it really loaded the kernel into. The rest of
    //     RAM is mapped later, by the code that has read the device tree and
    //     therefore knows how much of it there is.
    adrp    x3, _start
    lsr     x4, x3, #30                 // level-1 index = physical >> 30
    lsl     x3, x4, #30                 // 1 GiB-aligned base of that block
    mov     x5, #BLOCK_NORMAL
    orr     x3, x3, x5
    add     x5, x1, x4, lsl #3
    str     x3, [x5]

    // The table was written with the MMU off, which makes those stores
    // non-cacheable, and the table walker is configured to read it
    // cacheable. Clean the whole table to the point of coherency so the
    // walker cannot be served a stale line. QEMU models no caches and would
    // not notice; hardware would, once and unreproducibly.
    mrs     x5, ctr_el0
    ubfx    x5, x5, #16, #4             // CTR_EL0.DminLine: log2 words per line
    mov     x6, #4
    lsl     x5, x6, x5                  // line size in bytes
    mov     x6, x1
    add     x7, x1, #4096
.Lclean_l1:
    dc      civac, x6
    add     x6, x6, x5
    cmp     x6, x7
    b.lo    .Lclean_l1
    dsb     sy
    isb

    // ── Translation on ──────────────────────────────────────────────────
    ldr     x2, =MAIR_VALUE
    msr     mair_el1, x2
    ldr     x2, =TCR_VALUE
    msr     tcr_el1, x2
    msr     ttbr0_el1, x1               // identity: what the PC needs now
    msr     ttbr1_el1, x1               // high: what everything after needs
    isb

    tlbi    vmalle1
    ic      iallu
    dsb     nsh
    isb

    mrs     x2, sctlr_el1
    orr     x2, x2, #SCTLR_M
    orr     x2, x2, #SCTLR_C
    orr     x2, x2, #SCTLR_I
    msr     sctlr_el1, x2
    isb

    // Translation is live and the identity map is what kept this running.
    // Move to the high mapping through a register: the branch target is an
    // absolute virtual address, which no PC-relative instruction can reach
    // from down here.
    ldr     x1, =.Lhigh
    br      x1

.Lhigh:
    // From this point on, absolute symbols mean what they say.
    ldr     x1, =__stack_top
    mov     sp, x1

    // Zero .bss, now, through the high mapping. Doing it here rather than
    // before the MMU came on means these are cacheable stores to the same
    // addresses the kernel will read them back from, so there is no window
    // in which a stale cache line could survive the zeroing.
    ldr     x1, =__bss_start
    ldr     x2, =__bss_end
.Lbss_loop:
    cmp     x1, x2
    b.hs    .Lbss_done
    str     xzr, [x1], #8
    b       .Lbss_loop
.Lbss_done:

    // x0 still holds the DTB pointer the bootloader passed in — a physical
    // address, which the kernel turns into a virtual one itself.
    bl      kernel_main_aarch64

.Lhalt:
    wfe
    b       .Lhalt

// The level-1 translation table. Declared here rather than in Zig because
// the boot stub fills it in before any Zig runs, and because it must live
// outside .bss — the stub zeroes .bss while executing on this table.
.section .pagetables, "aw", %nobits
.align 12
.global aarch64_l1_table
aarch64_l1_table:
    .space 4096
