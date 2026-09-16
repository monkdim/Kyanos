/* KyanOS kernel link script.
 *
 * The kernel proper is linked at the higher half (KERNEL_VMA =
 * 0xFFFF_FFFF_8000_0000) but physically loaded low (LMA = 1 MiB). A
 * separate low-half `.boot` region holds the 32-bit boot stub and its
 * page tables/stack: that code runs before paging maps the higher half,
 * so it must be reachable with 32-bit relocations — hence it stays at an
 * identity (VMA == LMA) low address. The stub builds page tables that map
 * the identity low 1 GiB, the higher-half kernel window, and the HHDM
 * (0xFFFF_8000_0000_0000, used by the VMM), then far-jumps into the
 * higher-half kernel entry.
 */

ENTRY(_start)

KERNEL_VMA = 0xFFFFFFFF80000000;
KERNEL_LMA = 0x100000;

SECTIONS {
    . = KERNEL_LMA;

    /* Low-half boot code + data (identity: VMA == LMA). The multiboot2
       header must land in the first 32 KiB so the loader can find it. The
       boot page tables + stack are zero-filled loaded data (kept in a
       PT_LOAD segment) so the loader reserves their physical range. */
    .boot : ALIGN(8) {
        KEEP(*(.multiboot2))
        *(.boot.text)
        *(.boot.rodata)
        . = ALIGN(4096);
        *(.boot.bss)
    }

    /* The kernel proper: linked high, loaded low via AT(). */
    . += KERNEL_VMA;

    .text : AT(ADDR(.text) - KERNEL_VMA) ALIGN(4K) {
        *(.text .text.*)
    }

    .rodata : AT(ADDR(.rodata) - KERNEL_VMA) ALIGN(4K) {
        *(.rodata .rodata.*)
    }

    .data : AT(ADDR(.data) - KERNEL_VMA) ALIGN(4K) {
        *(.data .data.*)
    }

    .bss : AT(ADDR(.bss) - KERNEL_VMA) ALIGN(4K) {
        *(COMMON)
        *(.bss .bss.*)
    }

    /* Physical end of the loaded kernel image (LMA). pmm reserves
       [0, __kernel_phys_end) so it never hands out pages occupied by the
       kernel, its boot page tables, or its stack. */
    __kernel_phys_end = . - KERNEL_VMA;

    /DISCARD/ : {
        *(.eh_frame)
        *(.note.*)
        *(.comment)
    }
}
