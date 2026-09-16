#!/bin/sh
# Link a freestanding C program against this C library.
#
#   link.sh <program.c> <output> [extra cc flags...]
#
# One place for the flags, so the test, the documentation and anyone building
# a program by hand are running the same command. What each flag is doing:
#
#   -ffreestanding   no assumptions about a hosted environment
#   -nostdinc        the host's headers are unreachable; only ../include is
#   -nostdlib        no host C library, no host startup files
#   -static          nothing to load a dynamic linker with
#   -fno-builtin     stop the compiler turning printf into puts and so on, so
#                    that what runs is the code in src/ rather than the
#                    compiler's idea of it
#   -I<resource>/include   stddef.h and stdarg.h, which belong to the compiler
#
# CLARITY_LIBC_LINUX picks Linux's syscall numbers so the result runs on a
# Linux host. Without it the numbers are KyanOS's — see src/sys.h.
set -e

if [ $# -lt 2 ]; then
    echo "usage: link.sh <program.c> <output> [cc flags...]" >&2
    exit 2
fi

SRC="$1"; shift
OUT="$1"; shift

DIR=$(cd "$(dirname "$0")" && pwd)
CC=${CC:-clang}
RES=$("$CC" -print-resource-dir 2>/dev/null || true)
if [ -z "$RES" ]; then
    echo "link.sh: $CC has no -print-resource-dir; stddef.h/stdarg.h cannot be found" >&2
    exit 1
fi

exec "$CC" -O2 -w -ffreestanding -nostdinc -nostdlib -static -fno-builtin \
    -I "$DIR/include" -I "$RES/include" \
    "$SRC" "$DIR"/src/*.c "$DIR"/src/*.S \
    -o "$OUT" "$@"
