// KyanOS boot stub — multiboot2 entry, switch to long mode, jump to
// the higher-half kernel_main(boot_info).
//
// multiboot2 hands us control in 32-bit protected mode with the kernel
// loaded at its physical LMA (1 MiB). This stub lives in the identity
// low-half `.boot` region so its 32-bit code can address its own symbols
// with 32-bit relocations. It:
//   1. saves the multiboot info pointer (%ebx),
//   2. builds page tables mapping three windows onto physical 0..1 GiB:
//        - identity          0x0000000000000000  (needed during the switch)
//        - HHDM              0xFFFF800000000000  (used by the VMM)
//        - kernel higher half 0xFFFFFFFF80000000 (where the kernel links)
//   3. enables PAE + long mode (+ NX) and paging,
//   4. far-jumps to a low 64-bit trampoline, then jumps to the
//      higher-half entry which calls kernel_main(boot_info).

.set PML4_ID,   0            // identity 0x0
.set PML4_HHDM, 256          // 0xFFFF800000000000 >> 39 & 0x1FF
.set PML4_KERN, 511          // 0xFFFFFFFF80000000 >> 39 & 0x1FF
.set PDPT_KERN, 510          // 0xFFFFFFFF80000000 >> 30 & 0x1FF

.section .multiboot2, "a"
.align 8
.long 0xE85250D6                                    // magic
.long 0                                              // arch (i386)
.long header_end - header_start                      // header length
.long -(0xE85250D6 + (header_end - header_start))    // checksum
header_start:
    // Information request tag — ask for memory map + framebuffer.
    .word 1                                  // tag_type
    .word 0                                  // flags
    .long 8 + 4 * 2                          // size
    .long 6                                  // mmap
    .long 8                                  // framebuffer
    .long 0                                  // pad
    // End tag
    .word 0
    .word 0
    .long 8
header_end:

// ── Boot page tables + stack (low, identity) ──
// Kept as zero-filled loaded data (not NOBITS) so the multiboot loader
// reserves the physical range and won't place its info blob over it. The
// stub also re-zeroes the tables it uses, so correctness never depends on
// the loader pre-zeroing them.
.section .boot.bss, "aw"
.align 4096
boot_pml4:     .skip 4096
boot_pdpt_id:  .skip 4096     // identity + HHDM both use entry[0] → boot_pd
boot_pdpt_hh:  .skip 4096     // kernel higher half uses entry[510] → boot_pd
boot_pd:       .skip 4096     // 512 × 2 MiB = 1 GiB
.align 16
stack_bottom:  .skip 16384    // 16 KiB initial stack
stack_top:

// ── 32-bit boot stub (low) ──
.section .boot.text, "ax"
.code32
.global _start
.type _start, @function
_start:
    mov   $stack_top, %esp
    // %ebx holds the multiboot2 info pointer; preserve it untouched all
    // the way to the 64-bit entry (nothing below clobbers %ebx).

    // Zero the four table pages (pml4, pdpt_id, pdpt_hh, pd).
    mov   $boot_pml4, %edi
    mov   $(4096 * 4 / 4), %ecx
    xor   %eax, %eax
    rep   stosl

    // boot_pd: identity-map the first 1 GiB with 2 MiB pages.
    mov   $boot_pd, %edi
    xor   %ecx, %ecx
1:  mov   %ecx, %eax
    shl   $21, %eax             // index * 2 MiB
    or    $0x83, %eax           // present + writable + 2 MiB page
    mov   %eax, (%edi, %ecx, 8) // high dword already zeroed above
    inc   %ecx
    cmp   $512, %ecx
    jl    1b

    // boot_pdpt_id[0] = boot_pd | present|writable
    mov   $boot_pd, %eax
    or    $0x3, %eax
    mov   $boot_pdpt_id, %edi
    mov   %eax, (%edi)

    // boot_pdpt_hh[510] = boot_pd | present|writable
    mov   $boot_pdpt_hh, %edi
    mov   %eax, PDPT_KERN*8(%edi)

    // boot_pml4 entries: identity[0], HHDM[256] → pdpt_id; kernel[511] → pdpt_hh
    mov   $boot_pml4, %edi
    mov   $boot_pdpt_id, %eax
    or    $0x3, %eax
    mov   %eax, PML4_ID*8(%edi)
    mov   %eax, PML4_HHDM*8(%edi)
    mov   $boot_pdpt_hh, %eax
    or    $0x3, %eax
    mov   %eax, PML4_KERN*8(%edi)

    // CR3 = PML4
    mov   $boot_pml4, %eax
    mov   %eax, %cr3

    // Enable PAE (CR4.PAE)
    mov   %cr4, %eax
    or    $(1 << 5), %eax
    mov   %eax, %cr4

    // EFER: enable Long Mode (LME) and No-Execute (NXE); the VMM sets the
    // NX bit (63) in PTEs, which faults unless NXE is on.
    mov   $0xC0000080, %ecx
    rdmsr
    or    $(1 << 8), %eax       // LME
    or    $(1 << 11), %eax      // NXE
    wrmsr

    // Enable paging (CR0.PG); PE is already set by the loader.
    mov   %cr0, %eax
    or    $(1 << 31), %eax
    mov   %eax, %cr0

    // Load the 64-bit GDT (low) and far-jump to the low 64-bit trampoline.
    lgdt  boot_gdt64_pointer
    ljmp  $0x08, $long_low

.code64
long_low:
    mov   $0x10, %ax
    mov   %ax, %ds
    mov   %ax, %es
    mov   %ax, %fs
    mov   %ax, %gs
    mov   %ax, %ss
    mov   $stack_top, %esp      // re-set rsp cleanly (zero-extends)
    // Hop to the higher-half kernel entry via an absolute 64-bit target.
    movabs $long_high, %rax
    jmp   *%rax

// ── 64-bit GDT (low, so lgdt can reach it in 32-bit mode) ──
.section .boot.rodata, "a"
.align 8
boot_gdt64:
    .quad 0x0000000000000000    // null
    .quad 0x00AF9A000000FFFF    // 64-bit code
    .quad 0x00AF92000000FFFF    // 64-bit data
boot_gdt64_end:
boot_gdt64_pointer:
    .word boot_gdt64_end - boot_gdt64 - 1
    .quad boot_gdt64

// ── Higher-half kernel entry ──
.section .text
.code64
.global long_high
.type long_high, @function
long_high:
    mov   %ebx, %edi           // multiboot info pointer → first arg (zero-extended)
    call  kernel_main
.halt:
    cli
    hlt
    jmp   .halt
