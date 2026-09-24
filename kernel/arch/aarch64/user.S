// Entering and leaving EL0 on AArch64.
//
// Two halves of one journey. `aarch64_enter_user` saves the kernel's
// callee-saved state, points ELR_EL1 and SP_EL0 at the process, and erets
// down. `aarch64_leave_user` is called from inside an exception handler and
// puts the kernel back exactly where `enter_user` left it — so from the
// caller's point of view `enter_user` simply returned, with whatever value
// the handler passed.
//
// That is a context switch with the general registers left out, and it is
// deliberately the smaller thing: nothing here resumes a *different* thread,
// only the one that went down. Which thread runs next is the scheduler's
// decision, and it is taken in the vector entry's handler, on the kernel
// stack this file's caller is standing on.
//
// Where the kernel's state waits while EL0 runs — `struct UserSave` in
// trap.zig, which asserts this layout:
//
//    0..95   x19-x30, the callee-saved set AAPCS64 requires a function to
//            preserve — exactly what `enter_user`'s caller is entitled to
//            still have when it returns
//   96       SP
//  104       DAIF
//
// DAIF is in there because taking an exception from EL0 sets PSTATE.I: the
// handler runs with interrupts masked, and `leave_user` returns with `ret`
// rather than `eret`, so nothing would ever unmask them again. A kernel that
// lost its timer the first time a process exited would look completely
// healthy right up until it needed to schedule something.
//
// The caller supplies the area, and TPIDR_EL1 says which one is the current
// thread's. It used to be one static block, with a comment saying "so
// `enter_user` does not nest. Nothing needs it to". Something does now: two
// threads each running a program are each inside `enter_user`, and a single
// block would mean whichever entered second wrote over the first's way home
// — so the first program to exit would unwind onto the other thread's stack.
// `clarity_switch_to` carries TPIDR_EL1 from thread to thread, which is what
// makes "the current thread's" true after a preemption as well as before it.

.section .text


// u64 aarch64_enter_user(u64 entry, u64 user_sp, UserSave *save, u64 arg)
//
// Returns the value handed to aarch64_leave_user. Does not return any other
// way: an EL0 program that never traps never comes back.
//
// `save` is 112 bytes the caller owns for as long as the process runs, which
// in practice means a local in the frame this is about to leave behind — the
// frame `leave_user` restores SP to.
//
// `arg` arrives in the program's x0. It is the first thing this kernel has
// ever told a program about itself, and it exists because two copies of one
// image running side by side are otherwise indistinguishable — to each other
// and to anyone reading the boot log. It is not argv: argv is a stack the
// kernel builds and a contract about what is on it, and none of that is here
// yet. It is one number, in the register the ABI already passes a first
// argument in, so the day there is an argv it goes in the same place.
.global aarch64_enter_user
.type aarch64_enter_user, %function
aarch64_enter_user:
    // This thread's way home, where the exception handler can find it
    // whichever thread was running when the process trapped.
    msr     tpidr_el1, x2
    stp     x19, x20, [x2, #0]
    stp     x21, x22, [x2, #16]
    stp     x23, x24, [x2, #32]
    stp     x25, x26, [x2, #48]
    stp     x27, x28, [x2, #64]
    stp     x29, x30, [x2, #80]
    // x5 and x6 rather than x3 and x4: x3 is the argument the program is
    // about to be given, and must still be there at the `eret`.
    mov     x5, sp
    str     x5, [x2, #96]
    mrs     x6, daif
    str     x6, [x2, #104]

    msr     sp_el0, x1              // the process's stack
    msr     elr_el1, x0             // where it starts
    // SPSR_EL1 = 0: M[3:0] = 0b0000 (EL0t, using SP_EL0), M[4] = 0
    // (AArch64), and DAIF all clear — interrupts stay live while EL0 runs,
    // which is why vector entry 9 has to be a real handler rather than a
    // report-and-halt. A timer tick landing in a reporting vector would make
    // this a test that passes or fails depending on when it was started.
    msr     spsr_el1, xzr

    // The argument first, because it is read out of a register the clearing
    // below is about to take away.
    mov     x0, x3

    // And then everything else, because the register file is not the
    // kernel's to leave lying around.
    //
    // What used to be in these at the `eret` was whatever the kernel was
    // last holding: the pointer to this thread's UserSave, addresses the ELF
    // loader had just walked, whatever the heap allocator had in hand. A
    // program's first instruction could read all of it, and none of it cost
    // a fault to obtain. Nothing on this machine did read it — the programs
    // here are written by the same people as the kernel — which is the
    // reason to close it now and not when something arrives that was not.
    //
    // x0 is the exception and the only one: it is what the program is told
    // on purpose. SP_EL0 and ELR_EL1 are already set above, and PSTATE comes
    // from SPSR_EL1, so between them and these the whole of what EL0 can see
    // at its first instruction is now something this file chose.
    mov     x1, xzr
    mov     x2, xzr
    mov     x3, xzr
    mov     x4, xzr
    mov     x5, xzr
    mov     x6, xzr
    mov     x7, xzr
    mov     x8, xzr
    mov     x9, xzr
    mov     x10, xzr
    mov     x11, xzr
    mov     x12, xzr
    mov     x13, xzr
    mov     x14, xzr
    mov     x15, xzr
    mov     x16, xzr
    mov     x17, xzr
    mov     x18, xzr
    mov     x19, xzr
    mov     x20, xzr
    mov     x21, xzr
    mov     x22, xzr
    mov     x23, xzr
    mov     x24, xzr
    mov     x25, xzr
    mov     x26, xzr
    mov     x27, xzr
    mov     x28, xzr
    mov     x29, xzr
    mov     x30, xzr

    // FPSR and FPCR, which are one pair for the whole core and not part of
    // the file the loop below clears.
    //
    // FPCR holds the rounding mode. A program that sets one and exits leaves
    // it set, and every program after it computes different numbers —
    // measured, and not hypothetically: /bin/clarity-fpprobe sets rounding
    // toward minus infinity to check that FPCR survives a system call, and
    // the Clarity demo that ran after it printed the square root of two as
    // 1.414213562373095 instead of 1.4142135623730951. The boot gate asserts
    // that digit precisely because a floating-point path that is subtly
    // wrong still prints something plausible.
    //
    // Zero is the reset state: round to nearest, no exceptions trapped, no
    // flags raised. What a program is entitled to assume it starts with.
    msr     fpcr, xzr
    msr     fpsr, xzr

    // The vector file too, both halves of each register. `clarity_switch_to`
    // saves only the low halves of v8-v15, because that is all AAPCS64 makes
    // callee-saved — so the upper halves and the whole of the rest hold
    // whatever last ran, which for a kernel that computes in floating point
    // is kernel data.
    movi    v0.2d, #0
    movi    v1.2d, #0
    movi    v2.2d, #0
    movi    v3.2d, #0
    movi    v4.2d, #0
    movi    v5.2d, #0
    movi    v6.2d, #0
    movi    v7.2d, #0
    movi    v8.2d, #0
    movi    v9.2d, #0
    movi    v10.2d, #0
    movi    v11.2d, #0
    movi    v12.2d, #0
    movi    v13.2d, #0
    movi    v14.2d, #0
    movi    v15.2d, #0
    movi    v16.2d, #0
    movi    v17.2d, #0
    movi    v18.2d, #0
    movi    v19.2d, #0
    movi    v20.2d, #0
    movi    v21.2d, #0
    movi    v22.2d, #0
    movi    v23.2d, #0
    movi    v24.2d, #0
    movi    v25.2d, #0
    movi    v26.2d, #0
    movi    v27.2d, #0
    movi    v28.2d, #0
    movi    v29.2d, #0
    movi    v30.2d, #0
    movi    v31.2d, #0

    eret

// u64 aarch64_enter_user_frame(const Frame *frame, UserSave *save, u64 user_sp)
//
// The same journey as `aarch64_enter_user`, starting from a place a process
// has already been rather than from an entry point.
//
// `enter_user` starts a program: it picks the entry, zeroes the register
// file, resets the floating-point control and hands over one argument.
// Everything it does is a decision about what a program is entitled to begin
// with. This does the opposite — it takes a `Frame`, the exact register file
// a vector entry recorded when a process trapped, and puts every bit of it
// back, so the process continues from the instruction after its `svc` with
// the registers it had there.
//
// Which is what `fork` needs and could not have before. A child is not a
// program that starts; it is a process that was already running and now
// exists twice. The only thing the kernel changes between the parent's frame
// and the child's is the saved x0 — the value the system call returns — and
// that is a store into the copy in Zig, not anything here.
//
// `user_sp` is separate because SP_EL0 is not in the frame: it is one
// register for the whole core, untouched by an exception from EL0, so the
// caller reads it while the process's own value is still in it and hands it
// over here. A child on a different kernel thread has no other way to get it.
//
// Restores, in order: SP_EL0, ELR, SPSR, FPSR, FPCR, q0-q31, x1-x30, and x0
// last because x0 is the pointer everything else is being read through.
.global aarch64_enter_user_frame
.type aarch64_enter_user_frame, %function
aarch64_enter_user_frame:
    // This thread's way home, exactly as `enter_user` lays it down — the
    // `leave_user` that unwinds through it cannot tell the two apart, and
    // must not have to.
    msr     tpidr_el1, x1
    stp     x19, x20, [x1, #0]
    stp     x21, x22, [x1, #16]
    stp     x23, x24, [x1, #32]
    stp     x25, x26, [x1, #48]
    stp     x27, x28, [x1, #64]
    stp     x29, x30, [x1, #80]
    mov     x3, sp
    str     x3, [x1, #96]
    mrs     x4, daif
    str     x4, [x1, #104]

    msr     sp_el0, x2

    // The system registers the frame carries. SPSR is the process's own
    // PSTATE as the exception recorded it — its condition flags included, so
    // a process forked in the middle of a comparison resumes with the answer
    // it had.
    ldr     x3, [x0, #248]          // ELR: the instruction after the `svc`
    msr     elr_el1, x3
    ldr     x3, [x0, #256]          // SPSR
    msr     spsr_el1, x3
    ldr     x3, [x0, #264]          // FPSR: the exception flags accumulated
    msr     fpsr, x3
    ldr     x3, [x0, #272]          // FPCR: the rounding mode chosen
    msr     fpcr, x3

    // The whole vector file, both halves of every register. Not the eight
    // `clarity_switch_to` keeps: a process is not a function call, and a
    // program interrupted mid-expression has live values everywhere in here.
    add     x3, x0, #288
    ldp     q0, q1, [x3, #0]
    ldp     q2, q3, [x3, #32]
    ldp     q4, q5, [x3, #64]
    ldp     q6, q7, [x3, #96]
    ldp     q8, q9, [x3, #128]
    ldp     q10, q11, [x3, #160]
    ldp     q12, q13, [x3, #192]
    ldp     q14, q15, [x3, #224]
    ldp     q16, q17, [x3, #256]
    ldp     q18, q19, [x3, #288]
    ldp     q20, q21, [x3, #320]
    ldp     q22, q23, [x3, #352]
    ldp     q24, q25, [x3, #384]
    ldp     q26, q27, [x3, #416]
    ldp     q28, q29, [x3, #448]
    ldp     q30, q31, [x3, #480]

    // x0 last: it is the base every load above reads through.
    ldp     x1, x2, [x0, #8]
    ldp     x3, x4, [x0, #24]
    ldp     x5, x6, [x0, #40]
    ldp     x7, x8, [x0, #56]
    ldp     x9, x10, [x0, #72]
    ldp     x11, x12, [x0, #88]
    ldp     x13, x14, [x0, #104]
    ldp     x15, x16, [x0, #120]
    ldp     x17, x18, [x0, #136]
    ldp     x19, x20, [x0, #152]
    ldp     x21, x22, [x0, #168]
    ldp     x23, x24, [x0, #184]
    ldp     x25, x26, [x0, #200]
    ldp     x27, x28, [x0, #216]
    ldp     x29, x30, [x0, #232]
    ldr     x0, [x0, #0]

    eret

// void aarch64_leave_user(u64 return_value) — never returns to its caller.
.global aarch64_leave_user
.type aarch64_leave_user, %function
aarch64_leave_user:
    // The running thread's own save area, not a global one: with two threads
    // in EL0 the difference is which stack this returns onto.
    mrs     x2, tpidr_el1
    ldp     x19, x20, [x2, #0]
    ldp     x21, x22, [x2, #16]
    ldp     x23, x24, [x2, #32]
    ldp     x25, x26, [x2, #48]
    ldp     x27, x28, [x2, #64]
    ldp     x29, x30, [x2, #80]
    ldr     x3, [x2, #96]
    mov     sp, x3
    // Interrupts last, so nothing arrives while SP is in flight.
    ldr     x4, [x2, #104]
    msr     daif, x4
    // Nothing is in EL0 on this thread any more, and nothing may find a
    // stale way home through TPIDR_EL1 — a `leave_user` with no matching
    // `enter_user` would otherwise return onto a frame that has been reused.
    msr     tpidr_el1, xzr
    // x30 now holds enter_user's return address, and x0 the value to return
    // through it. This `ret` returns from a function whose frame was
    // abandoned two exception levels ago.
    ret

// ── The program that runs at EL0 ────────────────────────────────────────
//
// Not linked as code — the kernel copies these bytes into a page it
// allocated and maps that page into a process's address space. It therefore
// lives in .rodata: from the kernel's own point of view it is data, and the
// kernel's mapping of it should not be executable.
//
// Everything here is position-independent except the two addresses it is
// told about, which are the addresses main_aarch64.zig maps the pages at.
// That coupling is the point rather than an accident: it is the process's
// memory layout, and both ends have to agree on it.

.section .rodata.usertest, "a"

.global __user_probe_start
__user_probe_start:
    // 1. Say something. The string is in this page, named by a PC-relative
    //    address — so what reaches the kernel is a *user* virtual address,
    //    meaningful only inside this process's page tables. The kernel
    //    translating it rather than dereferencing it is the whole point.
    mov     x0, #1                  // fd 1
    adr     x1, .Lmsg
    mov     x2, #(.Lmsgend - .Lmsg)
    mov     x8, #1                  // SYS_WRITE
    svc     #0

    // The kernel put the byte count in x0. If it disagrees with what we
    // asked for, say so with an exit status nothing else produces.
    cmp     x0, x2
    b.ne    .Lbad_write

    // 2. Read the kernel's number out of our data page, add one to it.
    movz    x9, #0x1000, lsl #16    // 0x1000_0000 — the data page
    ldr     x19, [x9]
    add     x19, x19, #1

    // 3. Spend long enough at EL0 that the 100 Hz timer is certain to fire
    //    here rather than in the kernel. That is the point of the loop: it
    //    makes the process get interrupted, so vector entry 9 has to save and
    //    restore it correctly and the kernel has to hand the CPU back to
    //    exactly this instruction. Sixty-seven million iterations is a
    //    fraction of a second under TCG — several ticks — and a slower
    //    machine only makes it more certain.
    movz    x11, #0x400, lsl #16
2:  subs    x11, x11, #1
    b.ne    2b

    // 4. Store it where the kernel can read it through its own direct map,
    //    which is how the write is checked: it has to land in the physical
    //    page, not merely appear to from here.
    str     x19, [x9]

    // 5. Exit with it.
    mov     x0, x19
    mov     x8, #12                 // SYS_EXIT
    svc     #0
1:  b       1b                      // the kernel does not come back here

.Lbad_write:
    movz    x0, #0xBAD
    mov     x8, #12
    svc     #0
3:  b       3b

    .balign 4
.Lmsg:
    .ascii  "hello from EL0 on aarch64\n"
.Lmsgend:
    .balign 4
.global __user_probe_end
__user_probe_end:

// A second entry point, entered separately. It writes to its own text page,
// which is mapped read-only for EL0 — so this must trap, and the kernel must
// be the one that says what happened.
.global __user_fault_start
__user_fault_start:
    movz    x12, #0x40, lsl #16     // 0x0040_0000 — this very page
    mov     x0, #1
    str     x0, [x12]               // must fault: read-only at EL0

    // Reaching this instruction means the store was allowed, which is the
    // failure this half of the probe exists to catch. Exiting with a status
    // nothing else produces, rather than spinning, is the difference between
    // a test that reports and a test that hangs — and a hung boot is a much
    // worse way to find out.
    movz    x0, #0xDEAD
    mov     x8, #12                 // SYS_EXIT
    svc     #0
1:  b       1b
.global __user_fault_end
__user_fault_end:
