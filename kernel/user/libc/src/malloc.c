#include <stdlib.h>
#include <string.h>
#include "sys.h"

/* A first-fit allocator over the program break.
 *
 * The Clarity runtime allocates in one of two modes. By default it uses an
 * arena that never frees, so any allocator at all would do. With CLARITY_GC=1
 * the collector sweeps and calls free, and then free has to really return
 * memory or a long-running program grows without bound — which is the whole
 * point of turning the collector on. So this frees, coalesces, and reuses.
 *
 * Blocks are kept in a single address-ordered list, which makes coalescing a
 * comparison against the neighbour's address and nothing more. First fit
 * rather than best fit: best fit needs a full walk on every allocation to
 * find the winner, and its payoff (less fragmentation) is smaller than it
 * sounds for the allocation pattern here, which is dominated by many small
 * short-lived strings and lists of one of a few sizes.
 */

typedef struct Block {
    size_t         size;   /* payload bytes, not counting this header */
    struct Block*  next;   /* next block by address, or NULL */
    size_t         free;   /* 1 if available */
    size_t         _pad;   /* keeps sizeof(Block) a multiple of 16 */
} Block;

/* malloc must return memory aligned for any type. On x86-64 that is 16 bytes
 * (the ABI's requirement for __m128 and long double), and since the header is
 * exactly 32 bytes, a 16-aligned header yields a 16-aligned payload. */
#define ALIGN 16UL
#define HDR   (sizeof(Block))

static Block* heap_head = 0;
static Block* heap_tail = 0;

static size_t align_up(size_t n) { return (n + (ALIGN - 1)) & ~(ALIGN - 1); }

/* Ask the kernel for `bytes` more heap and return a block covering it.
 *
 * The break is grown in chunks rather than by the exact request: brk is a
 * syscall, and one per small allocation would dominate the cost of allocating
 * at all. 64 KiB is large enough that a program doing thousands of small
 * allocations makes a handful of calls, and small enough not to look like a
 * leak to a kernel that maps every page eagerly — which KyanOS's brk does.
 */
#define CHUNK (64UL * 1024UL)

static Block* heap_grow(size_t bytes) {
    size_t want = align_up(bytes + HDR);
    if (want < CHUNK) want = CHUNK;

    char* start = (char*)cl_sys_brk(0);
    if (!start) return 0;
    char* end = (char*)cl_sys_brk(start + want);
    /* brk reports failure by returning the *current* break unchanged, so a
     * result that did not move is the error case — there is no errno here to
     * consult, and none is needed. */
    if (end < start + want) return 0;

    Block* b = (Block*)start;
    b->size = want - HDR;
    b->next = 0;
    b->free = 1;
    b->_pad = 0;

    if (heap_tail) heap_tail->next = b; else heap_head = b;
    heap_tail = b;
    return b;
}

/* Split `b` so it holds exactly `size` bytes, if what is left over is worth
 * tracking. A remainder smaller than a header plus one alignment unit would
 * cost more to record than it could ever hand out. */
static void split(Block* b, size_t size) {
    if (b->size < size + HDR + ALIGN) return;
    Block* rest = (Block*)((char*)b + HDR + size);
    rest->size = b->size - size - HDR;
    rest->next = b->next;
    rest->free = 1;
    rest->_pad = 0;
    b->size = size;
    b->next = rest;
    if (heap_tail == b) heap_tail = rest;
}

void* malloc(size_t n) {
    if (n == 0) n = 1;
    size_t size = align_up(n);

    for (Block* b = heap_head; b; b = b->next) {
        if (b->free && b->size >= size) {
            split(b, size);
            b->free = 0;
            return (char*)b + HDR;
        }
    }

    Block* b = heap_grow(size);
    if (!b) return 0;
    split(b, size);
    b->free = 0;
    return (char*)b + HDR;
}

void free(void* p) {
    if (!p) return;
    Block* b = (Block*)((char*)p - HDR);
    b->free = 1;

    /* Coalesce forward as far as it goes, then find the predecessor and
     * coalesce backward once — which is enough, because the predecessor's own
     * forward pass already absorbed everything after it that was free. */
    while (b->next && b->next->free && (char*)b + HDR + b->size == (char*)b->next) {
        if (heap_tail == b->next) heap_tail = b;
        b->size += HDR + b->next->size;
        b->next = b->next->next;
    }
    Block* prev = 0;
    for (Block* c = heap_head; c && c != b; c = c->next) prev = c;
    if (prev && prev->free && (char*)prev + HDR + prev->size == (char*)b) {
        if (heap_tail == b) heap_tail = prev;
        prev->size += HDR + b->size;
        prev->next = b->next;
    }
}

void* calloc(size_t count, size_t size) {
    size_t total = count * size;
    /* Overflow would hand back a buffer smaller than the caller asked for,
     * and the caller would then write past it. Refusing is the only safe
     * answer, and it is cheap to check. */
    if (size != 0 && total / size != count) return 0;
    void* p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void* realloc(void* p, size_t n) {
    if (!p) return malloc(n);
    if (n == 0) { free(p); return 0; }
    Block* b = (Block*)((char*)p - HDR);
    if (b->size >= align_up(n)) return p;
    void* q = malloc(n);
    if (!q) return 0;
    memcpy(q, p, b->size);
    free(p);
    return q;
}
