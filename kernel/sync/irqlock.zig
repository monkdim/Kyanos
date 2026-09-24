//! The lock that protects data a thread and an interrupt handler share.
//!
//! On one core, masking interrupts *is* the lock. Nothing else is running:
//! the only way another piece of code can touch the data between this
//! thread's read and its write is if an interrupt takes the CPU away, and a
//! masked interrupt cannot. That makes this whole file two instructions on
//! each architecture, and it makes the guarantee exactly as strong as the
//! assumption underneath it.
//!
//! **It does not survive a second core.** On two cores the other core is not
//! interrupted by anything this one does, and it walks straight into the same
//! critical section. Every use of this guard therefore has to become a real
//! spinlock — this same mask *plus* an atomic test-and-set on a lock word —
//! when the kernel brings up a second CPU. Saying so here is the point:
//! what makes this correct is that there is one core, and that is a fact
//! about today rather than a property of the design.
//!
//! Nesting is safe, and is relied on: `pmm.alloc_pages(1)` calls
//! `alloc_page`, so the guard is taken twice. The inner `acquire` saves an
//! already-masked state and its `release` puts that back — still masked — and
//! only the outermost release restores the caller's own interrupt state.
//! That is what makes this composable in a way a bare `cli`/`sti` pair is
//! not: `sti` at the end of an inner function would unmask inside the outer
//! critical section, which is the classic way this goes wrong.

const builtin = @import("builtin");

/// Held while the critical section runs. Release it with `defer`.
pub const Guard = struct {
    /// The caller's interrupt state, as the CPU represents it: x86_64's
    /// RFLAGS and AArch64's DAIF. Opaque on purpose — nothing outside this
    /// file should read or construct one.
    saved: usize,

    pub fn release(self: Guard) void {
        restore(self.saved);
    }
};

/// Mask interrupts and remember whether they were masked already.
pub fn acquire() Guard {
    return .{ .saved = save_and_mask() };
}

fn save_and_mask() usize {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // RFLAGS.IF is bit 9, but nothing here needs to know that: the
            // whole register is saved and put back, so the restore is exact
            // rather than a reconstruction.
            const flags = asm volatile ("pushfq; popq %[out]"
                : [out] "=r" (-> usize),
                :
                : "memory"
            );
            asm volatile ("cli" ::: "memory");
            return flags;
        },
        .aarch64 => {
            const daif = asm volatile ("mrs %[out], daif"
                : [out] "=r" (-> usize),
            );
            // Bit 1 of the DAIF *set* register is I, the IRQ mask. `daifset`
            // only sets, so this cannot clear D, A or F on the way past.
            asm volatile ("msr daifset, #2" ::: "memory");
            return daif;
        },
        else => @compileError("irqlock: no interrupt mask for this architecture"),
    }
}

fn restore(saved: usize) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("pushq %[f]; popfq"
            :
            : [f] "r" (saved),
            : "memory", "cc"
        ),
        .aarch64 => asm volatile ("msr daif, %[v]"
            :
            : [v] "r" (saved),
            : "memory"
        ),
        else => @compileError("irqlock: no interrupt mask for this architecture"),
    }
}
