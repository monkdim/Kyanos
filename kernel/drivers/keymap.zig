//! Which key types which character.
//!
//! One table for both architectures, which is what the AArch64 keyboard file
//! asked for when it was the only one that had it: "This is not a second copy
//! of something on the x86 side... when it does, this is what it should share
//! rather than the other way round."
//!
//! Indexed by the Linux input keycode, which over the main block is the AT
//! set-1 scancode unchanged -- KEY_ESC is 1, KEY_A is 30, space is 57. That
//! is why the same table serves virtio-input, which reports Linux codes, and
//! an 8042 with translation on, which reports set 1. **Measured, not assumed:
//! with the translation bit set, QEMU's controller answers `a` with 0x1E make
//! and 0x9E break, `b` with 0x30, `c` with 0x2E and Enter with 0x1C -- 30, 48,
//! 46 and 28, which are the four keycodes.**
//!
//! The table is written out rather than computed because there is no rule to
//! compute: the layout is a historical artefact of a keyboard from 1984.
//!
//! Only the main block. Function keys, the numeric keypad, the arrows and the
//! modifiers beyond shift are absent because nothing reads them yet, and a
//! table full of entries no test has ever produced is a table full of
//! guesses.

pub const KEY_LEFTSHIFT: u16 = 42;
pub const KEY_RIGHTSHIFT: u16 = 54;

/// Linux keycode → the character it types, unshifted and shifted. Index is
/// the keycode; a zero means "this key types nothing".
pub const MAP = blk: {
    var m: [58][2]u8 = [_][2]u8{.{ 0, 0 }} ** 58;
    const rows = .{
        .{ 1, "\x1B\x1B" }, // escape
        .{ 2, "1!" },   .{ 3, "2@" },   .{ 4, "3#" },   .{ 5, "4$" },
        .{ 6, "5%" },   .{ 7, "6^" },   .{ 8, "7&" },   .{ 9, "8*" },
        .{ 10, "9(" },  .{ 11, "0)" },  .{ 12, "-_" },  .{ 13, "=+" },
        .{ 14, "\x08\x08" }, // backspace
        .{ 15, "\t\t" },
        .{ 16, "qQ" },  .{ 17, "wW" },  .{ 18, "eE" },  .{ 19, "rR" },
        .{ 20, "tT" },  .{ 21, "yY" },  .{ 22, "uU" },  .{ 23, "iI" },
        .{ 24, "oO" },  .{ 25, "pP" },  .{ 26, "[{" },  .{ 27, "]}" },
        .{ 28, "\n\n" }, // enter
        .{ 30, "aA" },  .{ 31, "sS" },  .{ 32, "dD" },  .{ 33, "fF" },
        .{ 34, "gG" },  .{ 35, "hH" },  .{ 36, "jJ" },  .{ 37, "kK" },
        .{ 38, "lL" },  .{ 39, ";:" },  .{ 40, "'\"" }, .{ 41, "`~" },
        .{ 43, "\\|" },
        .{ 44, "zZ" },  .{ 45, "xX" },  .{ 46, "cC" },  .{ 47, "vV" },
        .{ 48, "bB" },  .{ 49, "nN" },  .{ 50, "mM" },  .{ 51, ",<" },
        .{ 52, ".>" },  .{ 53, "/?" },  .{ 57, "  " },
    };
    for (rows) |r| {
        m[r[0]] = .{ r[1][0], r[1][1] };
    }
    break :blk m;
};
