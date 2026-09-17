/* Prints a deterministic sweep of float conversions.
 *
 * Compiled twice from this one source: once against the host's C library and
 * once against the one in ../src. If the two outputs differ, this library's
 * printf or strtod is wrong — and "wrong" is not a matter of taste here,
 * because the Clarity runtime's shortest-round-trip loop reads its own
 * printf's output back through its own strtod and compares bit patterns.
 *
 * The generator is written out longhand rather than using rand() so that both
 * builds walk exactly the same values regardless of whose rand() they get.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef union { double d; unsigned long u; } Bits;

static unsigned long rng = 88172645463325252UL;
static unsigned long next_rand(void) {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return rng;
}

static void emit(double x) {
    char b17[64], b1[64], shortest[64];
    snprintf(b17, sizeof(b17), "%.17g", x);
    snprintf(b1, sizeof(b1), "%.1g", x);

    /* The fewest %g digits that read back identically. */
    int prec = 17;
    for (int p = 1; p <= 17; p++) {
        char t[64];
        snprintf(t, sizeof(t), "%.*g", p, x);
        if (strtod(t, 0) == x) { prec = p; break; }
    }
    snprintf(shortest, sizeof(shortest), "%.*g", prec, x);

    /* And the same in scientific notation, which is the loop the runtime
     * actually runs: cl_num_text takes the shortest round-tripping %e form
     * because that hands it the digits and the decimal exponent together,
     * and then places the decimal point itself. %e did not exist in this
     * library until that loop needed it, and a compiled Clarity program
     * printed the format string where a number should have been. */
    char e17[64], e0[64], eshort[64];
    snprintf(e17, sizeof(e17), "%.17e", x);
    snprintf(e0, sizeof(e0), "%.0e", x);
    int eprec = 17;
    for (int p = 0; p <= 17; p++) {
        char t[64];
        snprintf(t, sizeof(t), "%.*e", p, x);
        if (strtod(t, 0) == x) { eprec = p; break; }
    }
    snprintf(eshort, sizeof(eshort), "%.*e", eprec, x);

    Bits back; back.d = strtod(b17, 0);
    Bits eback; eback.d = strtod(e17, 0);
    Bits orig; orig.d = x;
    printf("%s|%s|%s|%d|%s|%s|%s|%s|%d|%s\n", b17, b1, shortest, prec,
           back.u == orig.u ? "rt" : "BROKEN",
           e17, e0, eshort, eprec,
           eback.u == orig.u ? "ert" : "EBROKEN");
}

int main(void) {
    /* Values whose formatting is decided by a rule rather than by luck. */
    static const double fixed[] = {
        0.0, 1.0, -1.0, 0.5, 0.1, 0.2, 0.3, 1.0/3.0, 2.0/3.0,
        1e-5, 1e-4, 9.999e-5, 1e15, 1e16, 1e17, 123456789.0,
        1e300, 1e-300, 4.9406564584124654e-324, 2.2250738585072014e-308,
        1.7976931348623157e308, 3.141592653589793, 2.718281828459045,
        1024.0, 1e6, 999999.0, 1000000.5, 0.0001220703125,
        1234567890123456789.0, 5e-324, 1.5e-323,
    };
    for (unsigned i = 0; i < sizeof(fixed)/sizeof(fixed[0]); i++) { emit(fixed[i]); emit(-fixed[i]); }

    /* Random bit patterns, rejecting NaN and infinity — %g's spelling of
     * those is not something the Clarity runtime ever produces. */
    for (int i = 0; i < 4000; i++) {
        Bits b;
        b.u = next_rand();
        if (((b.u >> 52) & 0x7FF) == 0x7FF) continue;
        emit(b.d);
    }

    /* Random values in ordinary ranges, where most real output lives. */
    for (int i = 0; i < 4000; i++) {
        double m = (double)(next_rand() >> 11) / 9007199254740992.0;   /* [0,1) */
        int e = (int)(next_rand() % 60) - 30;
        double v = m;
        for (int k = 0; k < (e < 0 ? -e : e); k++) v = (e < 0) ? v / 10.0 : v * 10.0;
        emit(v);
    }

    /* strtod on strings that were not produced by printf: many digits, odd
     * exponents, and the forms the parser has to reject or clamp. */
    static const char* strs[] = {
        "0", "-0", "1", "1.", ".5", "0.1", "3.14159265358979311599796346854",
        "1e308", "1e309", "1e-308", "1e-323", "1e-324", "1e-400",
        "2.2250738585072011e-308", "9007199254740993", "9007199254740992",
        "0.500000000000000000000000000001", "0.4999999999999999999999999",
        "123456789012345678901234567890", "  12.5xyz", "+7e2", "-7e-2",
        "1.7976931348623158e308", "0.0000000000000000000000001",
        "1e", "e5", ".", "-.", "5e+", "1.5e2abc",
    };
    for (unsigned i = 0; i < sizeof(strs)/sizeof(strs[0]); i++) {
        char* end = 0;
        Bits b; b.d = strtod(strs[i], &end);
        printf("S[%s] -> %016lx rest=[%s]\n", strs[i], b.u, end ? end : "(null)");
    }
    return 0;
}
