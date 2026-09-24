// AArch64 exception vector table for EL1.
//
// VBAR_EL1 points at a 2 KiB-aligned table of 16 entries, each exactly
// 128 bytes: four groups (current EL with SP0, current EL with SPx, lower
// EL in AArch64, lower EL in AArch32) times four kinds (synchronous, IRQ,
// FIQ, SError).
//
// Thirteen entries report and halt: a fault reaching one of those is a bug,
// and printing what happened beats spinning silently — the same reasoning
// behind populating all 256 x86 IDT gates.
//
// Three are real:
//
//   entry 5   current EL with SPx, IRQ    — the generic timer
//   entry 8   lower EL AArch64, sync      — every `svc` and every fault
//                                            userspace takes
//   entry 9   lower EL AArch64, IRQ       — the timer, while EL0 is running
//
// Entry 9 exists because EL0 runs with interrupts unmasked. A timer tick
// arriving while a process is on the CPU is not an error, and pointing that
// vector at the reporting path would make any EL0 test pass or fail depending
// on when it happened to start.
//
// The IRQ entries save x0-x18 and x30 themselves: these are not functions the
// compiler knows about, they are entries the CPU jumps to with the
// interrupted code's registers still live, and an AAPCS64 callee is free to
// clobber every caller-saved one. Entry 8 saves rather more, because the
// handler has to *read and change* the interrupted registers: a system call's
// arguments arrive in them and its result goes back through them.

.macro VEC_ENTRY kind
.align 7                        // each vector entry occupies 2^7 = 128 bytes
    mov     x0, #\kind
    mrs     x1, esr_el1         // syndrome: what happened
    mrs     x2, elr_el1         // faulting instruction address
    mrs     x3, far_el1         // faulting virtual address
    b       aarch64_exception
.endm

// An IRQ that is handled rather than reported. x0-x18 are the caller-saved
// set; x30 is the link register, which `bl` is about to overwrite. Pushed in
// pairs because stp/ldp need the stack 16-byte aligned, which SP_EL1 is.
//
// ELR_EL1 and SPSR_EL1 go on the stack too, and that is not symmetry for its
// own sake. They are single registers, one pair for the whole CPU, and the
// handler is allowed to switch threads: the moment it does, another thread
// resumes inside *its* copy of this entry, takes its own interrupts, and
// overwrites them. Whichever thread erets last would return to whatever
// address the most recent exception happened to leave behind.
//
// The x86_64 side gets this free, because `iretq` pops its return frame off
// the stack, so it is per-thread by construction. Here it has to be written
// down.
.macro IRQ_ENTRY
.align 7
    b       aarch64_irq_body
.endm

// The body both IRQ entries branch to — entry 5, an interrupt taken in the
// kernel, and entry 9, one taken while a process is running.
//
// It used to be written inline in the 128-byte vector slot, saving x0-x18 and
// x30: the caller-saved set, which is all an AAPCS64 callee may clobber. That
// was right for as long as the only thing an interrupt could interrupt was
// code the ABI's rules applied to.
//
// They do not apply here. An interrupt is not a call. A program halfway
// through a floating-point expression has live values in v0-v7 and v16-v31,
// and the handler is compiled code that is entitled to use every one of them
// — so what the ABI calls dead is exactly what gets destroyed. The same is
// true of kernel code interrupted mid-computation, which is why both entries
// come here rather than only the one from EL0.
//
// So the whole vector file goes on the stack, and FPSR and FPCR with it: they
// are one pair for the core, and FPCR holds the rounding mode whoever was
// interrupted chose.
//
//     0..159   x0-x18, x30
//   160        ELR_EL1
//   168        SPSR_EL1
//   176        FPSR
//   184        FPCR
//   192..703   q0-q31
//
// 704 bytes, a multiple of sixteen, which SP must stay aligned to.
//
// ELR and SPSR are on the stack rather than left in their registers because
// this handler is allowed to switch threads: they are one pair for the whole
// CPU, and whichever thread eret-ed last would otherwise return to whatever
// address the most recent exception left behind. The x86_64 side gets that
// free, because iretq pops its frame; here it has to be written down.
aarch64_irq_body:
    sub     sp, sp, #704
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x30, [sp, #144]
    mrs     x0, elr_el1
    mrs     x1, spsr_el1
    stp     x0, x1, [sp, #160]
    mrs     x0, fpsr
    mrs     x1, fpcr
    stp     x0, x1, [sp, #176]
    stp     q0, q1, [sp, #192]
    stp     q2, q3, [sp, #224]
    stp     q4, q5, [sp, #256]
    stp     q6, q7, [sp, #288]
    stp     q8, q9, [sp, #320]
    stp     q10, q11, [sp, #352]
    stp     q12, q13, [sp, #384]
    stp     q14, q15, [sp, #416]
    stp     q16, q17, [sp, #448]
    stp     q18, q19, [sp, #480]
    stp     q20, q21, [sp, #512]
    stp     q22, q23, [sp, #544]
    stp     q24, q25, [sp, #576]
    stp     q26, q27, [sp, #608]
    stp     q28, q29, [sp, #640]
    stp     q30, q31, [sp, #672]

    bl      aarch64_irq

    ldp     q0, q1, [sp, #192]
    ldp     q2, q3, [sp, #224]
    ldp     q4, q5, [sp, #256]
    ldp     q6, q7, [sp, #288]
    ldp     q8, q9, [sp, #320]
    ldp     q10, q11, [sp, #352]
    ldp     q12, q13, [sp, #384]
    ldp     q14, q15, [sp, #416]
    ldp     q16, q17, [sp, #448]
    ldp     q18, q19, [sp, #480]
    ldp     q20, q21, [sp, #512]
    ldp     q22, q23, [sp, #544]
    ldp     q24, q25, [sp, #576]
    ldp     q26, q27, [sp, #608]
    ldp     q28, q29, [sp, #640]
    ldp     q30, q31, [sp, #672]
    ldp     x0, x1, [sp, #176]
    msr     fpsr, x0
    msr     fpcr, x1
    ldp     x0, x1, [sp, #160]
    msr     elr_el1, x0
    msr     spsr_el1, x1
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldp     x8, x9, [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x30, [sp, #144]
    add     sp, sp, #704
    eret


// The synchronous entry from EL0. Everything a process does that the kernel
// has to deal with arrives here: `svc`, and every fault it takes.
//
// It builds a full trap frame — x0-x30, then ELR_EL1 and SPSR_EL1 — and hands
// its address to Zig. Not to be tidy: the handler has to be able to change
// what it holds. A system call's return value is a write to the saved x0, and
// resuming a process at a different instruction is a write to the saved ELR.
// Restoring ELR and SPSR from the frame rather than leaving them in the
// system registers is what makes that possible, and is also what makes the
// entry re-entrant once a fault handler is allowed to take a fault.
//
// 800 bytes:
//
//     0..247   x0-x30
//   248        ELR_EL1
//   256        SPSR_EL1
//   264        FPSR
//   272        FPCR
//   280        padding, so the vector file lands 16-byte aligned
//   288..799   q0-q31
//
// A multiple of sixteen, which SP must stay aligned to. trap.zig's Frame
// asserts every one of these offsets.
//
// The vector entry itself is a single branch, because the body does not fit:
// a vector slot is exactly 128 bytes and building and unwinding a 31-register
// frame takes more than thirty instructions. The two IRQ entries save half as
// much and do fit, which is the only reason they are written inline.
.macro SYNC_LOWER_ENTRY
.align 7
    b       aarch64_sync_lower_body
.endm

aarch64_sync_lower_body:
    sub     sp, sp, #800
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30, [sp, #240]
    mrs     x9, elr_el1
    mrs     x10, spsr_el1
    stp     x9, x10, [sp, #248]
    // And the vector file. A system call is a call from the program's point
    // of view, but it is not a call the compiler made: the handler is
    // ordinary compiled code and will use v0-v7 to move a struct around
    // without anybody asking it to. Measured, before this existed: a program
    // that put a value in d0, did a write, and looked again did not find it.
    mrs     x9, fpsr
    mrs     x10, fpcr
    stp     x9, x10, [sp, #264]
    stp     q0, q1, [sp, #288]
    stp     q2, q3, [sp, #320]
    stp     q4, q5, [sp, #352]
    stp     q6, q7, [sp, #384]
    stp     q8, q9, [sp, #416]
    stp     q10, q11, [sp, #448]
    stp     q12, q13, [sp, #480]
    stp     q14, q15, [sp, #512]
    stp     q16, q17, [sp, #544]
    stp     q18, q19, [sp, #576]
    stp     q20, q21, [sp, #608]
    stp     q22, q23, [sp, #640]
    stp     q24, q25, [sp, #672]
    stp     q26, q27, [sp, #704]
    stp     q28, q29, [sp, #736]
    stp     q30, q31, [sp, #768]

    mov     x0, sp
    bl      aarch64_sync_lower

    ldp     q0, q1, [sp, #288]
    ldp     q2, q3, [sp, #320]
    ldp     q4, q5, [sp, #352]
    ldp     q6, q7, [sp, #384]
    ldp     q8, q9, [sp, #416]
    ldp     q10, q11, [sp, #448]
    ldp     q12, q13, [sp, #480]
    ldp     q14, q15, [sp, #512]
    ldp     q16, q17, [sp, #544]
    ldp     q18, q19, [sp, #576]
    ldp     q20, q21, [sp, #608]
    ldp     q22, q23, [sp, #640]
    ldp     q24, q25, [sp, #672]
    ldp     q26, q27, [sp, #704]
    ldp     q28, q29, [sp, #736]
    ldp     q30, q31, [sp, #768]
    ldp     x9, x10, [sp, #264]
    msr     fpsr, x9
    msr     fpcr, x10
    ldp     x9, x10, [sp, #248]
    msr     elr_el1, x9
    msr     spsr_el1, x10
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldp     x8, x9, [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30, [sp, #240]
    add     sp, sp, #800
    eret

.section .text
.align 11                       // VBAR_EL1 requires 2^11 = 2048-byte alignment
.global aarch64_vectors
aarch64_vectors:
    // Current EL with SP0
    VEC_ENTRY 0                 // synchronous
    VEC_ENTRY 1                 // IRQ
    VEC_ENTRY 2                 // FIQ
    VEC_ENTRY 3                 // SError
    // Current EL with SPx — the kernel's own IRQs arrive at entry 5.
    VEC_ENTRY 4
    IRQ_ENTRY
    VEC_ENTRY 6
    VEC_ENTRY 7
    // Lower EL, AArch64 — a process. Its system calls and faults arrive at
    // entry 8, and the timer interrupting it at entry 9.
    SYNC_LOWER_ENTRY
    IRQ_ENTRY
    VEC_ENTRY 10
    VEC_ENTRY 11
    // Lower EL, AArch32
    VEC_ENTRY 12
    VEC_ENTRY 13
    VEC_ENTRY 14
    VEC_ENTRY 15
