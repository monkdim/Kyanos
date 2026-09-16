#include <stdio.h>
#include <string.h>
#include "dtoa.h"
#include "sys.h"

/* printf, snprintf, sprintf.
 *
 * One formatter, one output sink. The sink is a struct rather than a FILE*
 * because there is only ever one destination that is not a caller's buffer —
 * file descriptor 1 — and a buffered FILE layer would add flushing semantics
 * to a program whose only other syscalls are brk and exit.
 *
 * Conversions implemented are the ones `clarity cc --freestanding` emits —
 * %ld, %s, %g, %.*g, %08lx — plus the neighbours that cost nothing once those
 * exist (%d, %u, %x, %c, %p, %%, and the l/ll length modifiers). A conversion
 * this does not know is copied through literally, which makes a gap visible
 * in the output rather than silently dropping the argument.
 */

typedef struct {
    char*  buf;      /* NULL means write straight to fd 1 */
    size_t cap;      /* bytes available in buf, including the terminator */
    size_t len;      /* bytes the caller would have needed, terminator aside */
    char   fd_buf[256];
    size_t fd_len;
} Sink;

/* Write all of it, however many calls that takes.
 *
 * write(2) may accept less than it is offered and say so, and KyanOS's
 * does: a single call is capped at 256 bytes. This buffer is also 256 bytes,
 * so today the cap is never reached — which means the loop below has never
 * gone round twice, and also that this code was correct only because two
 * unrelated constants happened to be equal. Grow fd_buf, or shrink the
 * kernel's cap, and without this loop every long line would be silently
 * truncated. */
static void sink_flush(Sink* s) {
    if (s->buf || !s->fd_len) return;
    unsigned long done = 0;
    while (done < s->fd_len) {
        long n = cl_sys_write(1, s->fd_buf + done, s->fd_len - done);
        if (n <= 0) break;   /* nowhere left to write; dropping is all that is left */
        done += (unsigned long)n;
    }
    s->fd_len = 0;
}

static void sink_putc(Sink* s, char c) {
    if (s->buf) {
        /* ISO C: snprintf returns the length it *would* have produced, so the
         * count keeps rising after the buffer is full. */
        if (s->cap > 0 && s->len + 1 < s->cap) s->buf[s->len] = c;
    } else {
        s->fd_buf[s->fd_len++] = c;
        if (s->fd_len == sizeof(s->fd_buf)) sink_flush(s);
    }
    s->len++;
}

static void sink_puts(Sink* s, const char* p, size_t n) { for (size_t i = 0; i < n; i++) sink_putc(s, p[i]); }

static void pad(Sink* s, char c, int n) { for (int i = 0; i < n; i++) sink_putc(s, c); }

/* Unsigned integer in base 10 or 16 into a caller buffer, returning length. */
static int utoa(unsigned long v, unsigned base, int upper, char* out) {
    char tmp[24];
    int n = 0;
    do {
        unsigned d = (unsigned)(v % base);
        tmp[n++] = (char)(d < 10 ? '0' + d : (upper ? 'A' : 'a') + (d - 10));
        v /= base;
    } while (v);
    for (int i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
    return n;
}

/* %g, per ISO C: `prec` significant digits (0 means 1), scientific notation
 * when the exponent is below -4 or at least prec, and trailing zeros removed
 * unless '#' was given — which the Clarity runtime never gives, so it is not
 * implemented. */
static void fmt_g(Sink* s, double x, int prec, int alt) {
    union { double d; unsigned long u; } b;
    b.d = x;
    int neg = (int)(b.u >> 63);
    unsigned long expfield = (b.u >> 52) & 0x7FF;
    unsigned long frac = b.u & 0x000FFFFFFFFFFFFFUL;

    if (expfield == 0x7FF) {
        if (frac) { sink_puts(s, "nan", 3); return; }
        if (neg) sink_putc(s, '-');
        sink_puts(s, "inf", 3);
        return;
    }
    if (neg) sink_putc(s, '-');
    if (prec == 0) prec = 1;
    if (prec > CL_DTOA_MAX_DIGITS) prec = CL_DTOA_MAX_DIGITS;

    if (expfield == 0 && frac == 0) {   /* +-0 */
        sink_putc(s, '0');
        return;
    }

    char digits[CL_DTOA_MAX_DIGITS + 1];
    int decexp = 0;
    cl_dtoa(x, prec, digits, &decexp);

    int ndig = prec;
    if (!alt) { while (ndig > 1 && digits[ndig - 1] == '0') ndig--; }

    if (decexp < -4 || decexp >= prec) {
        /* d.dddde+XX */
        sink_putc(s, digits[0]);
        if (ndig > 1) { sink_putc(s, '.'); sink_puts(s, digits + 1, (size_t)(ndig - 1)); }
        sink_putc(s, 'e');
        int ev = decexp;
        sink_putc(s, ev < 0 ? '-' : '+');
        if (ev < 0) ev = -ev;
        char eb[8];
        int en = utoa((unsigned long)ev, 10, 0, eb);
        /* At least two exponent digits, which is what every other printf
         * does and what code that diffs output against a hosted run expects. */
        if (en < 2) sink_putc(s, '0');
        sink_puts(s, eb, (size_t)en);
    } else if (decexp >= 0) {
        for (int i = 0; i <= decexp; i++) sink_putc(s, i < ndig ? digits[i] : '0');
        if (ndig > decexp + 1) { sink_putc(s, '.'); sink_puts(s, digits + decexp + 1, (size_t)(ndig - decexp - 1)); }
    } else {
        sink_putc(s, '0');
        sink_putc(s, '.');
        for (int i = 0; i < -decexp - 1; i++) sink_putc(s, '0');
        sink_puts(s, digits, (size_t)ndig);
    }
}

static void format(Sink* s, const char* fmt, va_list ap) {
    for (const char* p = fmt; *p; p++) {
        if (*p != '%') { sink_putc(s, *p); continue; }
        const char* start = p;
        p++;

        int zero = 0, left = 0, plus = 0, space = 0, alt = 0;
        for (;; p++) {
            if (*p == '0') zero = 1;
            else if (*p == '-') left = 1;
            else if (*p == '+') plus = 1;
            else if (*p == ' ') space = 1;
            else if (*p == '#') alt = 1;
            else break;
        }

        int width = 0;
        if (*p == '*') { width = va_arg(ap, int); if (width < 0) { left = 1; width = -width; } p++; }
        else while (*p >= '0' && *p <= '9') width = width * 10 + (*p++ - '0');

        int prec = -1;
        if (*p == '.') {
            p++;
            if (*p == '*') { prec = va_arg(ap, int); p++; }
            else { prec = 0; while (*p >= '0' && *p <= '9') prec = prec * 10 + (*p++ - '0'); }
        }

        int lng = 0;
        while (*p == 'l') { lng++; p++; }
        if (*p == 'z' || *p == 'j') { lng = 1; p++; }

        char body[CL_DTOA_MAX_DIGITS + 32];
        int  blen = 0;
        char sign = 0;

        switch (*p) {
        case 'd': case 'i': {
            long v = lng ? va_arg(ap, long) : (long)va_arg(ap, int);
            unsigned long mag;
            if (v < 0) { sign = '-'; mag = (unsigned long)(-(v + 1)) + 1UL; }   /* LONG_MIN safe */
            else { mag = (unsigned long)v; if (plus) sign = '+'; else if (space) sign = ' '; }
            blen = utoa(mag, 10, 0, body);
            break;
        }
        case 'u': {
            unsigned long v = lng ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int);
            blen = utoa(v, 10, 0, body);
            break;
        }
        case 'x': case 'X': {
            unsigned long v = lng ? va_arg(ap, unsigned long) : (unsigned long)va_arg(ap, unsigned int);
            /* '#' prefixes a nonzero value with 0x, and only a nonzero one —
             * ISO C is explicit that 0 is printed without the prefix. */
            if (alt && v) { body[0] = '0'; body[1] = (*p == 'X') ? 'X' : 'x'; blen = 2; }
            blen += utoa(v, 16, *p == 'X', body + blen);
            break;
        }
        case 'p': {
            unsigned long v = (unsigned long)va_arg(ap, void*);
            body[0] = '0'; body[1] = 'x';
            blen = 2 + utoa(v, 16, 0, body + 2);
            break;
        }
        case 'c': {
            body[0] = (char)va_arg(ap, int);
            blen = 1;
            break;
        }
        case 's': {
            const char* v = va_arg(ap, const char*);
            if (!v) v = "(null)";
            size_t n = strlen(v);
            if (prec >= 0 && (size_t)prec < n) n = (size_t)prec;
            int padn = width - (int)n;
            if (!left) pad(s, ' ', padn);
            sink_puts(s, v, n);
            if (left) pad(s, ' ', padn);
            continue;
        }
        case 'g': case 'G': {
            double v = va_arg(ap, double);
            /* Width and zero padding are not applied to %g: the Clarity
             * runtime never asks for them, and silently ignoring them is
             * better than half-implementing padding around a sign. */
            fmt_g(s, v, prec < 0 ? 6 : prec, alt);
            continue;
        }
        case '%':
            sink_putc(s, '%');
            continue;
        default:
            /* Unknown conversion: emit it verbatim so it shows up. */
            sink_puts(s, start, (size_t)(p - start + 1));
            continue;
        }

        /* Integer-family tail: precision is a minimum digit count, width is a
         * minimum field width, and zero padding goes after the sign. */
        int zeros = (prec > blen) ? prec - blen : 0;
        int total = blen + zeros + (sign ? 1 : 0);
        if (!left && !zero) pad(s, ' ', width - total);
        if (sign) sink_putc(s, sign);
        if (!left && zero && prec < 0) pad(s, '0', width - total);
        pad(s, '0', zeros);
        sink_puts(s, body, (size_t)blen);
        if (left) pad(s, ' ', width - total);
    }
}

int vsnprintf(char* buf, size_t size, const char* fmt, va_list ap) {
    Sink s;
    s.buf = buf; s.cap = size; s.len = 0; s.fd_len = 0;
    format(&s, fmt, ap);
    if (buf && size > 0) buf[(s.len < size) ? s.len : size - 1] = 0;
    return (int)s.len;
}

int snprintf(char* buf, size_t size, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return n;
}

int sprintf(char* buf, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    /* No bound to honour, so give the sink one it cannot reach. */
    int n = vsnprintf(buf, (size_t)-1, fmt, ap);
    va_end(ap);
    return n;
}

int printf(const char* fmt, ...) {
    Sink s;
    s.buf = 0; s.cap = 0; s.len = 0; s.fd_len = 0;
    va_list ap;
    va_start(ap, fmt);
    format(&s, fmt, ap);
    va_end(ap);
    sink_flush(&s);
    return (int)s.len;
}
