// Kernel thread context switching on AArch64.
//
// The saved set is what AAPCS64 requires a function to preserve — x19-x28,
// the frame pointer x29, the link register x30, SP, and the low 64 bits of
// v8-v15 — plus the address space. Everything else is caller-saved, which is
// to say the compiler has already spilled anything it still needs across the
// call to this function.
//
// Where the counterpart on x86_64 has to save an entire 512-byte FXSAVE area,
// here it is eight registers: the AArch64 ABI makes only d8-d15 callee-saved,
// and only their bottom halves. That is not a shortcut — a thread's q8-q15
// upper halves and its q0-q7 are dead across a call by the ABI, so there is
// nothing in them to preserve.
//
// Offsets are shared with context.zig, which asserts every one of them at
// compile time. A silent disagreement here would restore a stack pointer from
// a floating-point register.

.set CTX_SP,     0
.set CTX_X19,    8
.set CTX_X21,   24
.set CTX_X23,   40
.set CTX_X25,   56
.set CTX_X27,   72
.set CTX_X29,   88
.set CTX_D8,   104
.set CTX_D10,  120
.set CTX_D12,  136
.set CTX_D14,  152
.set CTX_TTBR0, 168
.set CTX_TPIDR, 176
.set CTX_SPEL0, 184

.section .text

// void clarity_switch_to(Context *prev, Context *next)
//
// Returns, from `next`'s point of view, at whatever point `next` last called
// this function — or, for a thread that has never run, at the trampoline
// below.
.global clarity_switch_to
.type clarity_switch_to, %function
clarity_switch_to:
    // Mask interrupts for the switch, and put the *outgoing* thread's
    // interrupt state on its own stack rather than in the context. That way
    // it travels with the thread: a thread resumed later gets back the DAIF
    // it had, and does not inherit whatever the CPU happened to be doing when
    // it was picked. A switch that arrives from inside an interrupt handler
    // has I set, and a thread that inherited that could never be preempted
    // again.
    mrs     x9, daif
    msr     daifset, #3
    sub     sp, sp, #16
    str     x9, [sp]

    mov     x9, sp
    str     x9, [x0, #CTX_SP]
    stp     x19, x20, [x0, #CTX_X19]
    stp     x21, x22, [x0, #CTX_X21]
    stp     x23, x24, [x0, #CTX_X23]
    stp     x25, x26, [x0, #CTX_X25]
    stp     x27, x28, [x0, #CTX_X27]
    stp     x29, x30, [x0, #CTX_X29]
    stp     d8,  d9,  [x0, #CTX_D8]
    stp     d10, d11, [x0, #CTX_D10]
    stp     d12, d13, [x0, #CTX_D12]
    stp     d14, d15, [x0, #CTX_D14]

    // Where this thread goes back to when the process it is running stops
    // being the kernel's problem — see context.zig. Saved and restored with
    // the rest rather than left alone, because a thread that came back with
    // another thread's save area would unwind onto another thread's stack.
    mrs     x11, tpidr_el1
    str     x11, [x0, #CTX_TPIDR]

    // The stack the process on this thread runs on. One register for the
    // whole core, and nothing else saves it — so without this a thread
    // preempted at EL0 comes back holding whichever process entered EL0 most
    // recently. See context.zig for why that hid for as long as it did.
    mrs     x11, sp_el0
    str     x11, [x0, #CTX_SPEL0]

    ldp     x19, x20, [x1, #CTX_X19]
    ldp     x21, x22, [x1, #CTX_X21]
    ldp     x23, x24, [x1, #CTX_X23]
    ldp     x25, x26, [x1, #CTX_X25]
    ldp     x27, x28, [x1, #CTX_X27]
    ldp     x29, x30, [x1, #CTX_X29]
    ldp     d8,  d9,  [x1, #CTX_D8]
    ldp     d10, d11, [x1, #CTX_D10]
    ldp     d12, d13, [x1, #CTX_D12]
    ldp     d14, d15, [x1, #CTX_D14]

    ldr     x11, [x1, #CTX_TPIDR]
    msr     tpidr_el1, x11
    ldr     x11, [x1, #CTX_SPEL0]
    msr     sp_el0, x11

    ldr     x9,  [x1, #CTX_TTBR0]
    ldr     x10, [x1, #CTX_SP]
    mov     sp, x10

    // The address space, after SP has moved and before anything is read back
    // off the new stack. Zero means "leave TTBR0 alone", which is what a
    // kernel thread that was never given a process wants — and what keeps
    // this from clobbering the low half with nothing while the kernel is
    // running with it deliberately switched off.
    //
    // Safe to do here and nowhere else: the kernel is in TTBR1, so changing
    // TTBR0 cannot pull the ground out from under this code, which is exactly
    // what the same operation risks on x86 where one register holds both.
    cbz     x9, 1f
    msr     ttbr0_el1, x9
    isb
1:
    ldr     x9, [sp]
    add     sp, sp, #16
    msr     daif, x9
    ret

// Where a brand-new kernel thread starts.
//
// init_kernel_thread puts the entry point in x19 and its argument in x20 and
// points x30 here, so the first `ret` out of clarity_switch_to lands on these
// two instructions. Doing it with a trampoline rather than by pointing x30
// straight at the entry keeps the argument in a register the ABI actually
// passes it in, instead of relying on the entry's first instruction to move
// it out of a callee-saved one.
.global clarity_thread_trampoline
.type clarity_thread_trampoline, %function
clarity_thread_trampoline:
    mov     x0, x20
    br      x19
