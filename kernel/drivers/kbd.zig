//! Scancodes into characters, on the x86_64 side.
//!
//! `drivers/ps2.zig` hands back bytes from the 8042; this turns them into
//! what a person typed, through the same table the AArch64 keyboard uses
//! (`drivers/keymap.zig`).
//!
//! **Set 1, because the controller is asked for set 1.** The 8042's
//! configuration byte has a translation bit that converts the keyboard's own
//! set 2 into set 1, and ps2.zig sets it: with it clear the same four keys
//! arrive as 0x1C/0xF0 0x1C, 0x32, 0x21, 0x5A, and with it set they arrive as
//! 0x1E/0x9E, 0x30, 0x2E, 0x1C -- which are the Linux keycodes the shared
//! table is indexed by. Both measured.
//!
//! A make code is the keycode; a break code is the same byte with the top bit
//! set. 0xE0 introduces an extended key, and the byte after it is dropped:
//! the table has no extended keys, so decoding one would mean indexing it
//! with a number that means something else.

const ps2 = @import("ps2.zig");
const keymap = @import("keymap.zig");

var shift_held: bool = false;
var extended: bool = false;

/// How many key presses have been seen, whether or not they typed anything.
/// Counted so a keyboard delivering events for keys with no character can be
/// told from one delivering nothing at all.
pub var presses: u64 = 0;

/// The next character typed, or null if nothing is waiting.
pub fn poll() ?u8 {
    while (ps2.read_kbd()) |byte| {
        if (byte == 0xE0) {
            extended = true;
            continue;
        }
        if (extended) {
            // The second byte of an extended key, whichever it is.
            extended = false;
            continue;
        }

        const down = (byte & 0x80) == 0;
        const code: u16 = byte & 0x7F;

        if (code == keymap.KEY_LEFTSHIFT or code == keymap.KEY_RIGHTSHIFT) {
            shift_held = down;
            continue;
        }
        if (!down) continue;
        presses += 1;

        if (code >= keymap.MAP.len) continue;
        const c = keymap.MAP[code][if (shift_held) 1 else 0];
        if (c != 0) return c;
    }
    return null;
}
