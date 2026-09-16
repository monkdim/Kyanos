/* KyanOS aarch64 kernel link script.
 *
 * The kernel is *linked* for the top of the address space and *loaded* at
 * the bottom of it. QEMU's `virt` machine places RAM at 0x4000_0000 and the
 * ARM64 boot protocol loads a kernel 512 KiB above the base of RAM, so the
 * physical addresses are fixed by the machine; the virtual ones are ours to
 * choose, and they are chosen high.
 *
 * Why high: TTBR0_EL1 translates the bottom of the address space and
 * TTBR1_EL1 the top, and the hardware switches only TTBR0 per process. A
 * kernel living in TTBR1 stays mapped across every address-space switch,
 * which is what makes per-process address spaces possible at all — and it
 * leaves the whole of the low half free for userland. It mirrors what the
 * x86_64 side already does at 0xFFFF_8000_0000_0000.
 *
 * 0xFFFF_FF80_0000_0000 is the first address TTBR1 covers with a 39-bit VA
 * space (T1SZ = 25), so a kernel virtual address is exactly its physical
 * address plus this base — a direct map, with no per-section arithmetic.
 *
 * Every output section therefore carries an explicit AT(): its load address
 * is its virtual address minus the base. `objcopy -O binary` follows load
 * addresses, so the flat image is laid out for where the bootloader puts it,
 * while every symbol in it resolves to where the MMU will make it appear.
 */

KERNEL_VA_BASE = 0xFFFFFF8000000000;
KERNEL_PA_BASE = 0x40080000;

ENTRY(_start)

SECTIONS {
    . = KERNEL_VA_BASE + KERNEL_PA_BASE;

    .text : AT(ADDR(.text) - KERNEL_VA_BASE) ALIGN(8) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : AT(ADDR(.rodata) - KERNEL_VA_BASE) ALIGN(8) {
        *(.rodata .rodata.*)
    }

    .data : AT(ADDR(.data) - KERNEL_VA_BASE) ALIGN(8) {
        *(.data .data.*)
    }

    . = ALIGN(16);
    __bss_start = .;
    .bss : AT(ADDR(.bss) - KERNEL_VA_BASE) ALIGN(16) {
        *(COMMON)
        *(.bss .bss.*)
    }
    . = ALIGN(16);
    __bss_end = .;

    /* The translation tables sit deliberately *outside* [__bss_start,
     * __bss_end]. The boot stub fills them in before it turns the MMU on and
     * zeroes .bss afterwards, running on the very map it just built; a table
     * inside .bss would be erased by the code executing out of it. */
    . = ALIGN(4096);
    .pagetables (NOLOAD) : AT(ADDR(.pagetables) - KERNEL_VA_BASE) ALIGN(4096) {
        *(.pagetables)
    }

    /* 64 KiB boot stack, grows down from __stack_top. */
    . = ALIGN(16);
    . += 0x10000;
    __stack_top = .;

    /DISCARD/ : {
        *(.eh_frame)
        *(.note.*)
        *(.comment)
    }

    /* What the ARM64 Image header advertises as image_size: everything a
     * bootloader must reserve, .bss, the tables and the boot stack included.
     * Getting this short would let the bootloader place something — the
     * device tree, an initrd — inside memory the kernel is about to zero. */
    __image_size = __stack_top - (KERNEL_VA_BASE + KERNEL_PA_BASE);
}
