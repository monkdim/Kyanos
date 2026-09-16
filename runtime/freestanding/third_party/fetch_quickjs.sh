#!/usr/bin/env bash
# Fetch QuickJS sources for the freestanding KyanOS runtime.
#
# We pin to the upstream Bellard QuickJS-NG fork because it ships a
# clean separation between the JS engine + libc shims, which makes
# the freestanding port straightforward (no host malloc, no host
# stdio).
#
# Usage: ./fetch_quickjs.sh [version]
#
# After running this script, runtime/freestanding/third_party/quickjs/
# will contain quickjs.{c,h}, quickjs-libc.{c,h}, libregexp.{c,h},
# libunicode.{c,h}, cutils.{c,h}, libbf.{c,h}, list.h, and the
# generated quickjs-atom.h / quickjs-opcode.h.

set -euo pipefail

VERSION="${1:-0.5.0}"
VENDOR_DIR="$(cd "$(dirname "$0")" && pwd)/quickjs"
TARBALL_URL="https://github.com/quickjs-ng/quickjs/archive/refs/tags/v${VERSION}.tar.gz"

if [ -f "${VENDOR_DIR}/quickjs.h" ]; then
    echo "QuickJS already vendored at ${VENDOR_DIR}; remove it first to refetch."
    exit 0
fi

echo "Fetching QuickJS-NG ${VERSION} into ${VENDOR_DIR}..."
mkdir -p "${VENDOR_DIR}"
tmp=$(mktemp -d)
trap "rm -rf ${tmp}" EXIT

curl -fsSL "${TARBALL_URL}" -o "${tmp}/quickjs.tar.gz"
tar xzf "${tmp}/quickjs.tar.gz" -C "${tmp}"
src="${tmp}/quickjs-${VERSION}"

# Sources we actually link into the freestanding build.
sources=(
    quickjs.c quickjs.h
    quickjs-libc.c quickjs-libc.h
    libregexp.c libregexp.h libregexp-opcode.h
    libunicode.c libunicode.h libunicode-table.h
    cutils.c cutils.h
    libbf.c libbf.h
    list.h
    quickjs-atom.h
    quickjs-opcode.h
    LICENSE
    VERSION
)
for f in "${sources[@]}"; do
    if [ ! -e "${src}/${f}" ]; then
        echo "  warning: ${f} not present in upstream tarball; skipping" >&2
        continue
    fi
    cp -p "${src}/${f}" "${VENDOR_DIR}/${f}"
done

echo "Done. ${VENDOR_DIR} now contains the QuickJS ${VERSION} sources."
echo "Build with: cd runtime/freestanding && zig build"
