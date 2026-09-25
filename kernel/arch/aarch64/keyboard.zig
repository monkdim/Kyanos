//! Key events into characters, on the AArch64 side.
//!
//! virtio-input reports Linux input event codes, and `drivers/keymap.zig`
//! turns those into characters. The table used to live here; it moved when
//! the x86 side got a keyboard, because the two want exactly the same one --
//! which is what the comment here said should happen.
//!
//! What stays is the part that is about *this* device: an event stream with a
//! type, a code and a value, where a release is a value of zero and shift is
//! the one key whose release matters.

const input = @import("virtio_input.zig");
const keymap = @import("../../drivers/keymap.zig");

var shift_held: bool = false;

/// How many key presses have been seen, whether or not they typed anything.
/// Counted so a keyboard that is delivering events for keys with no character
/// can be told from one that is delivering nothing at all.
pub var presses: u64 = 0;

/// The next character typed, or null if nothing is waiting.
///
/// Key *releases* are consumed and produce nothing, except for shift, whose
/// release is the only reason this function has any state at all.
pub fn poll() ?u8 {
    while (input.poll()) |ev| {
        if (ev.type != input.EV_KEY) continue;

        // value 1 is a press, 2 a repeat, 0 a release.
        const down = ev.value != 0;
        if (ev.code == keymap.KEY_LEFTSHIFT or ev.code == keymap.KEY_RIGHTSHIFT) {
            shift_held = down;
            continue;
        }
        if (!down) continue;
        presses += 1;

        if (ev.code >= keymap.MAP.len) continue;
        const c = keymap.MAP[ev.code][if (shift_held) 1 else 0];
        if (c != 0) return c;
    }
    return null;
}
