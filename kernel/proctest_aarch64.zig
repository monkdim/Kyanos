//! The process table, exercised by the boot.
//!
//! Most of what is checked here is a data structure, and a data structure is
//! usually better tested on the host than inside a kernel. There is a
//! specific reason it is tested here instead: the x86_64 side's process
//! table once kept its `std.mem.Allocator` at the .bss value a global gets —
//! a null vtable pointer — because the call that was supposed to hand it the
//! heap was never made. The first spawn loaded a function pointer from
//! physical page 0 and jumped into the real-mode interrupt vector table. A
//! host test of the same code would have passed, because on the host the
//! allocator is real. What is under test is therefore not only the logic but
//! that this table, on this boot, over this heap, works — which only a boot
//! can say.
//!
//! The ASID checks are the other half, and they are not a data-structure
//! question at all. TCR_EL1.AS is clear in boot.S, so an ASID is eight bits
//! and there are 256 of them. A counter is correct for 255 processes and
//! then hands the 256th a number that is still live.

const console = @import("arch/aarch64/console.zig");
const sched = @import("sched/sched_aarch64.zig");
const paging = @import("arch/aarch64/paging.zig");

var failures: usize = 0;

fn check(ok: bool, what: []const u8) void {
    if (ok) return;
    failures += 1;
    console.print("  [FAIL] process table: ");
    console.println(what);
}

fn check_eq(got: i64, want: i64, what: []const u8) void {
    if (got == want) return;
    failures += 1;
    console.print("  [FAIL] process table: ");
    console.print(what);
    console.print(" — got ");
    console.print_dec(@bitCast(got));
    console.print(", wanted ");
    console.print_dec(@bitCast(want));
    console.println("");
}

/// An address space that owns nothing. `register_process` copies it, and
/// none of the checks below enter a process, so no page tables are needed —
/// what is under test is the bookkeeping, not the MMU, which the address
/// space selftest already covers.
fn no_space() paging.AddressSpace {
    return .{ .root_phys = 0, .asid = 0 };
}

pub fn run() void {
    if (!sched.processes_started()) {
        console.println("  [--] no process table; not exercised");
        return;
    }
    failures = 0;

    const before_asids = sched.asids_in_use();

    // ── identity ────────────────────────────────────────────────────────
    //
    // Distinct PIDs, and an ASID each. A process that shared either with a
    // live one would be indistinguishable from it to `kill`, to `waitpid`,
    // and to the translation hardware.
    const a_asid = sched.alloc_asid() orelse {
        console.println("  [FAIL] process table: no ASID for the first process");
        return;
    };
    const b_asid = sched.alloc_asid() orelse {
        console.println("  [FAIL] process table: no ASID for the second process");
        return;
    };
    check(a_asid != b_asid, "two live processes were given the same ASID");
    check(a_asid != 0 and b_asid != 0, "ASID 0 was handed out — it means 'no process'");

    var space_a = no_space();
    space_a.asid = a_asid;
    var space_b = no_space();
    space_b.asid = b_asid;

    const parent = sched.register_process("[proc-parent]", space_a, 1, 0x1000) orelse {
        console.println("  [FAIL] process table: could not register a process");
        return;
    };
    const child = sched.register_process("[proc-child]", space_b, parent.pid, 0x1000) orelse {
        console.println("  [FAIL] process table: could not register a second process");
        return;
    };

    check(parent.pid != child.pid, "two processes were given the same PID");
    check(parent.pid > 1 and child.pid > 1, "a PID collided with init's");
    check(sched.processes.lookup(parent.pid) == parent, "lookup did not find the parent");
    check(sched.processes.lookup(child.pid) == child, "lookup did not find the child");

    // ── whose child ─────────────────────────────────────────────────────
    var found_child = false;
    for (parent.children.items) |c| {
        if (c == child.pid) found_child = true;
    }
    check(found_child, "the child was not recorded against its parent");
    check_eq(child.parent_pid, parent.pid, "the child does not point at its parent");

    // ── an orphan goes to init ──────────────────────────────────────────
    //
    // The parent exits while the child is still alive. Nothing is left
    // holding the child's exit code otherwise: its parent is gone, and a
    // process whose parent_pid names a dead PID can never be reaped.
    sched.exit_process(parent, 3);
    check_eq(child.parent_pid, 1, "an orphan was not reparented to init");
    check(sched.processes.lookup(parent.pid) == null, "the dead parent is still in the table");

    const init_proc = sched.processes.lookup(1) orelse {
        console.println("  [FAIL] process table: there is no init process");
        return;
    };
    var init_has_orphan = false;
    for (init_proc.children.items) |c| {
        if (c == child.pid) init_has_orphan = true;
    }
    check(init_has_orphan, "init was not told about the orphan it inherited");

    // ── a zombie is reaped exactly once ─────────────────────────────────
    sched.exit_process(child, 9);
    const first = init_proc.reap_pid(child.pid);
    check(first != null, "the orphan's exit was never recorded against init");
    if (first) |z| check_eq(z.exit_code, 9, "the wrong exit code was reaped");
    const second = init_proc.reap_pid(child.pid);
    check(second == null, "the same zombie was reaped twice");

    // ── the ASIDs came back ─────────────────────────────────────────────
    check_eq(@intCast(sched.asids_in_use()), @intCast(before_asids),
        "an exited process kept its ASID");

    // ── and there are only 256 of them ──────────────────────────────────
    //
    // The check a counter passes and an allocator does not. Every ASID but
    // zero is taken, and the next request has to be refused rather than
    // wrapping onto a number that is still live.
    var taken: usize = 0;
    var last: ?u16 = null;
    while (sched.alloc_asid()) |got| {
        taken += 1;
        last = got;
        if (taken > 300) break;
    }
    check_eq(@intCast(taken + before_asids), 255, "the pool is not 255 ASIDs deep");
    check(sched.alloc_asid() == null, "a 256th ASID was handed out over a live one");
    // Give them all back so the rest of the boot can start processes.
    var a: u16 = 1;
    while (a < 256) : (a += 1) sched.free_asid(a);
    check_eq(@intCast(sched.asids_in_use()), @intCast(before_asids),
        "the ASID pool did not come back");

    if (failures == 0) {
        console.print("  [ok] process table: PIDs ");
        console.print_dec(@intCast(parent.pid));
        console.print(" and ");
        console.print_dec(@intCast(child.pid));
        console.print(" with ASIDs ");
        console.print_dec(a_asid);
        console.print(" and ");
        console.print_dec(b_asid);
        console.print(", the orphan went to init, its zombie reaped once, and the pool is ");
        console.print_dec(255);
        console.println(" deep and refuses a 256th");
    }
}

/// Called at the very end of the boot, after every program has run and
/// exited.
///
/// The checks above build processes by hand and take them apart again. This
/// one asks about the real ones: the two init runs, the Clarity demo and the
/// shell each claimed an ASID from the pool and were registered in the
/// table, and if any of them failed to give it back the count says so. That
/// is a leak nothing else would notice until the 256th process was refused.
pub fn check_drained() void {
    if (!sched.processes_started()) return;

    const live = sched.asids_in_use();
    const table_size = sched.processes.map.count();

    // init is PID 1 and holds ASID 0, which is never allocated — so the pool
    // should be empty and the table should hold exactly one entry.
    if (live == 0 and table_size == 1 and sched.processes.lookup(1) != null) {
        console.println("  [ok] processes: every program that ran gave back its PID and its ASID; only init is left");
    } else {
        console.print("  [FAIL] processes: ");
        console.print_dec(live);
        console.print(" ASIDs still out and ");
        console.print_dec(table_size);
        console.println(" processes still in the table — wanted 0 and 1");
    }
}
