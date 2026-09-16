#!/bin/sh
# Boot the x86-64 kernel under QEMU.
#
# QEMU's `-kernel` cannot load this image. It is multiboot2, and `-kernel` on
# x86 wants a Linux bzImage or an ELF carrying a PVH note; handed the kernel
# directly it says so and stops:
#
#   qemu-system-x86_64: Error loading uncompressed kernel without PVH ELF Note
#
# So it boots the way the boot gate boots it: a GRUB rescue ISO with a
# multiboot2 menu entry. This script builds one into a temporary directory and
# boots it, which is exactly what .github/workflows/os-boot.yml does — if this
# works and CI does not, the difference is not the way it was started.
set -eu

KERNEL="${1:-zig-out/bin/clarity-kernel}"

if [ ! -f "$KERNEL" ]; then
    echo "run_x86.sh: no kernel at $KERNEL — run 'zig build' first" >&2
    exit 1
fi

for tool in grub-mkrescue xorriso qemu-system-x86_64; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "run_x86.sh: $tool is not installed." >&2
        echo "  Debian/Ubuntu: apt install grub-pc-bin grub-common xorriso mtools qemu-system-x86" >&2
        echo "  macOS:         brew install qemu xorriso  (grub-mkrescue needs a cross GRUB)" >&2
        exit 1
    }
done

ISO_DIR=$(mktemp -d)
trap 'rm -rf "$ISO_DIR"' EXIT

mkdir -p "$ISO_DIR/iso/boot/grub"
cp "$KERNEL" "$ISO_DIR/iso/boot/clarity-kernel"
cat > "$ISO_DIR/iso/boot/grub/grub.cfg" <<'CFG'
set timeout=0
set default=0
menuentry "KyanOS" {
    multiboot2 /boot/clarity-kernel
    boot
}
CFG

grub-mkrescue -o "$ISO_DIR/clarity.iso" "$ISO_DIR/iso" >/dev/null 2>&1

exec qemu-system-x86_64 \
    -cpu qemu64,+sse,+sse2 \
    -m 256M \
    -cdrom "$ISO_DIR/clarity.iso" \
    -boot d \
    -serial stdio \
    -display none \
    -no-reboot \
    -no-shutdown
