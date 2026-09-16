/* Program entry for a freestanding Clarity binary.
 *
 * The kernel enters here with the stack laid out the way a Unix loader lays
 * it out — argc at the top, then argv[0..argc-1], then a NULL — because that
 * is what KyanOS's ELF loader builds and what a Linux kernel builds, and
 * matching it means the same object runs under both. That equivalence is what
 * lets this library be tested on a Linux host rather than only in a VM.
 *
 * Two architectures, one contract. The stack layout, the call to main and the
 * call to exit are identical; only the register names and the alignment rule
 * differ, and both of those are properties of the ABI rather than of this
 * program.
 */

#if defined(__x86_64__)

/* The ABI asks for a 16-byte aligned stack at the point of a call. At entry
 * rsp points at argc and is itself 16-aligned, so after the argument setup
 * below it is aligned again for the call to main. */
        .text
        .globl  _start
        .type   _start, @function
_start:
        xorq    %rbp, %rbp             /* outermost frame: no caller to unwind to */
        movq    (%rsp), %rdi           /* argc */
        leaq    8(%rsp), %rsi          /* argv */
        andq    $-16, %rsp             /* realign after the implicit entry layout */
        call    main
        movl    %eax, %edi
        call    exit
        /* exit does not return; if it somehow did, stop here rather than
           executing whatever bytes follow. */
1:      pause
        jmp     1b
        .size   _start, .-_start

        .section .note.GNU-stack,"",@progbits

#elif defined(__aarch64__)

/* AArch64 keeps the stack 16-byte aligned at *all* times, not merely at a
 * call, so there is nothing to realign — but the `and` is still here, because
 * an entry stack that arrived misaligned would otherwise fault somewhere
 * inside main rather than here. It goes through x9 because AND with an
 * immediate cannot name SP: register 31 in that encoding is the zero
 * register, so `and sp, sp, #-16` assembles to something that discards the
 * result.
 *
 * x29 and x30 are zeroed to end the frame chain: this is the outermost frame
 * and there is no caller to unwind to. */
        .text
        .globl  _start
        .type   _start, %function
_start:
        mov     x29, xzr
        mov     x30, xzr
        ldr     x0, [sp]               /* argc */
        add     x1, sp, #8             /* argv */
        mov     x9, sp
        and     x9, x9, #-16
        mov     sp, x9
        bl      main
        /* main's return value is already in w0, which is exit's argument. */
        bl      exit
1:      yield
        b       1b
        .size   _start, .-_start

        .section .note.GNU-stack,"",%progbits

#else
#error "no program entry for this architecture"
#endif
