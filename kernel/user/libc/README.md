# A C library for freestanding Clarity programs

`clarity cc --freestanding` compiles a Clarity program to C that needs a C
library and no operating system. This is that C library: 1,695 lines of C and
assembly with the comments counted, enough that a compiled Clarity program
using classes, closures, exceptions, maps, sorting, string handling and
floating point runs with nothing underneath it but three kernel calls.

Those three are all of it — `write`, `brk`, `exit`. Their numbers live in
`src/sys.h` and nowhere else, which is what lets the same library be built for
KyanOS or for a Linux host. The Linux build is not a mock-up for testing:
it is the same source, the same objects, running under a different set of
syscall numbers, so what the tests exercise is what ships.

It builds for **x86-64 and AArch64**. Almost all of it is portable C that
never learns which; the parts that cannot be are three files and one function,
each with the two versions side by side and a `#error` for any third
architecture:

| | what differs |
|---|---|
| `src/sys.c` | `syscall` with the number in `%rax`, or `svc #0` with it in `x8` |
| `src/start.S` | which register argc arrives in, and the stack alignment rule |
| `src/setjmp.S` | which registers are callee-saved — AArch64 adds `d8`-`d15`, which the x86-64 ABI has no equivalent of |
| `sqrt` in `src/math.c` | `sqrtsd` or `fsqrt` |

A compiled Clarity program produces byte-identical output on both, floating
point included — checked by diffing the two boot logs, not by reading them:

```
$ diff <(sed -n '/^tally 55/,/^clarity-demo/p' x86.log) \
       <(sed -n '/^tally 55/,/^clarity-demo/p' arm.log)
$
```

## What is here

| | |
|---|---|
| `include/` | the six headers `clarity cc --freestanding` includes |
| `src/string.c` `src/ctype.c` | `str*`, `mem*`, the character classes |
| `src/malloc.c` | first-fit allocator over the program break, with coalescing |
| `src/printf.c` | `printf` / `snprintf` / `sprintf`, straight to fd 1 |
| `src/dtoa.c` `src/strtod.c` `src/bignum.c` | exact decimal ↔ binary conversion |
| `src/math.c` | the libm entries the Clarity builtins reach for |
| `src/qsort.c` | median-of-three quicksort with an insertion cutoff |
| `src/stdlib.c` | `exit`, `abort`, `getenv`, `strtol`, `rand` |
| `src/setjmp.S` | `setjmp` / `longjmp` — what Clarity's `try` compiles to |
| `src/start.S` | `_start`, the entry the kernel's ELF loader jumps to |
| `src/sys.c` | the three system calls, on either architecture |
| `link.sh` | the one place the build flags are written down |

There is no `FILE`, no `stderr`, no `fopen`, no locale, and no `errno`. The
freestanding profile does not emit anything that needs them, and a test with
`-nostdinc` fails if that ever stops being true.

## Accuracy, measured rather than asserted

Everything here is compiled twice from one source — once against the host's C
library, once against this one — and the two outputs compared. For most of it
the requirement is that they are byte-identical, because the behaviour is
specified rather than approximated:

- `str*`, `mem*`, the character classes
- `printf`'s integer, string, character and pointer conversions, with widths,
  precisions, flags and the `l` length modifier
- `strtol`, including the bases, the overflow clamp and the end pointer
- `qsort`, `setjmp`/`longjmp`, `malloc`/`free`/`realloc`/`calloc`
- **`printf("%g")` and `strtod`** — 8,090 comparisons, including 8,000 random
  bit patterns, the subnormal and overflow edges, and for every value the
  shortest precision that reads back identically. Zero differences. This one
  matters more than the rest: the Clarity runtime prints a float by asking for
  increasing precision until `strtod` maps the text back to the same double,
  so if either direction were approximate, floats would print wrongly or the
  loop would never settle. Both are done on exact integers (`src/bignum.c`),
  never on floating-point powers of ten.

The transcendentals are series approximations and are *not* claimed to match.
What is claimed is a bound, and these are the measured worst cases against
glibc over 24,000 samples (`test/math_probe.c`, compared by `test/ulp_cmp.c`,
asserted in `stdlib/test_libc.clarity`):

| | worst | exactly equal |
|---|---|---|
| `sin`, `cos`, `exp`, `log` (\|x\| ≤ 10) | 1–2 ulp | 74–90% |
| `tan` | 2 ulp | 57% |
| `pow` | 6 ulp | 48% |
| `log` (up to 1e6) | 1 ulp | 99% |
| `sin` (up to 1e6) | 5063 ulp | 10% |

`fabs`, `floor`, `ceil`, `round`, `trunc`, `fmod` and `sqrt` are exact, not
approximate — they are bit manipulation, a Sterbenz-exact subtraction loop,
and the hardware instruction respectively. The instruction differs by machine
(`sqrtsd`, `fsqrt`) and the guarantee does not: IEEE 754 requires a correctly
rounded square root, so both give the same bits.

That last row is the honest one. Past about 1e5 the limit is not the series
but reducing the argument modulo π/2 in double arithmetic, which holds the
*absolute* error near 1e-15 and therefore lets the relative error grow without
bound wherever sine is near a zero. Fixing it means Payne–Hanek reduction —
carrying a few hundred bits of 2/π — not a longer polynomial. It is the one
known gap, it is bounded and understood, and no Clarity builtin currently
computes a sine of a large angle.

## Building a program against it

```sh
clarity cc program.clarity --freestanding          # emits program.c
kernel/user/libc/link.sh program.c program         # links it
```

Add `-DCLARITY_LIBC_LINUX` to run the result on a Linux host; without it the
syscall numbers are KyanOS's, from `kernel/syscall/dispatch.zig`.

## Running the tests

They are part of the ordinary suite:

```sh
clarity test stdlib/test_libc.clarity
```

Skipped anywhere the library does not apply — the host test builds for the
host's own architecture with Linux syscall numbers, and it needs clang for the
`stddef.h` and `stdarg.h` that belong to the compiler rather than to a C
library. The AArch64 build is exercised by the OS boot gate rather than here:
`kernel/build.zig` compiles this library for aarch64 and the kernel runs the
result, so a break in the AArch64 half fails that gate.

## What it is not

Not a general-purpose C library. Every function here exists because
`clarity cc --freestanding` emits a call to it; there is no `printf("%e")`, no
wide characters, no threads, no `errno`, and `malloc` never returns memory to
the kernel because `brk` cannot shrink usefully under a kernel that maps
eagerly. Adding to it is a matter of adding the function and a comparison in
`test/`, not of restructuring anything.
