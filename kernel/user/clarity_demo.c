#define CLARITY_FREESTANDING 1
#ifndef CLARITY_FREESTANDING
#define _GNU_SOURCE 1
#endif
/* CLARITY_FREESTANDING is defined by `clarity cc --freestanding`, for targets
   with no operating system underneath — KyanOS itself, to begin with. It
   drops the parts of this runtime that are POSIX rather than C: files,
   /proc-backed memory access, process control, dynamic loading and sockets.
   What is left needs a C library of about fifteen functions, which is a
   thing one can write; what it drops needs an operating system that already
   exists, which is the thing being built. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <setjmp.h>
#include <ctype.h>
#ifndef CLARITY_FREESTANDING
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <time.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#endif

/* Fatal-error reporting. Hosted, it goes to stderr, where a diagnostic
   belongs. Freestanding, it goes to printf: a target with no operating system
   has one console, and asking its C library for the whole FILE* machinery —
   stderr, fprintf — to report an error it is about to die from is a large
   thing to require for a small gain. */
static void cl_eprint(const char* prefix, const char* msg){
#ifdef CLARITY_FREESTANDING
  printf("%s%s\n", prefix, msg);
#else
  fprintf(stderr, "%s%s\n", prefix, msg);
#endif
}
static void cl_die(const char* msg){ cl_eprint("", msg); exit(1); }

/* command-line argv, captured in main for the args() builtin */
static int cl_argc = 0;
static char** cl_argv = 0;

/* Conservative stack scanning deliberately reads every word of the C stack,
   including the padding a sanitizer inserts between variables. Exempt the
   scanner from AddressSanitizer's stack instrumentation so those reads aren't
   flagged; heap checks (the ones that would catch a real GC bug) still apply. */
#if defined(__GNUC__) || defined(__clang__)
#define GC_NOSAN __attribute__((no_sanitize_address))
/* main's frame pointer sits above every local in main, so scanning down from
   it to the current stack pointer covers all roots. Taking the address of a
   local would not — the compiler may place that local below other roots. */
#define GC_CAPTURE_STACK_BASE() (gc_stack_base = (char*)__builtin_frame_address(0))
#else
#define GC_NOSAN
#define GC_CAPTURE_STACK_BASE() do { char __b; gc_stack_base = &__b; } while(0)
#endif

typedef enum { T_NULL, T_BOOL, T_INT, T_FLOAT, T_STR, T_LIST, T_MAP, T_OBJECT, T_CLOSURE } Tag;
typedef struct Value Value;
struct Value { Tag t; long i; double f; const char* s; void* o; };
typedef struct { Value* items; long len; long cap; } List;
typedef struct { char** keys; Value* vals; long len; long cap; } Map;
typedef struct { const char* cls; Value fields; } Obj;

/* closures: a function pointer over (arg-array, capture-array) plus the
   captured values (snapshotted by value at creation) */
/* Calling conventions carry the argument count.
   Without it a callee cannot tell `f(1)` from `f(1, 2)`, which is what a rest
   parameter needs to know — and what a fixed parameter needs in order to read
   as null rather than off the end of the array when the caller supplied fewer
   arguments than the function declares. */
typedef Value (*ClFn)(Value*, Value*, long);
typedef struct { ClFn fn; Value* cap; int ncap; } Closure;

/* uniform method calling convention: (self, arg-array) -> Value */
typedef Value (*ClMethod)(Value, Value*, long);
typedef struct { const char* cls; const char* m; ClMethod fn; } ClMethodEntry;
static ClMethodEntry cl_method_table[1024];
static int cl_method_count = 0;

/* mutually-recursive display + deep-equality forward declarations */
static char* cl_to_cstr(Value v);
static char* cl_repr(Value v);
static char* cl_display(Value v);
/* The value a `throw` is carrying. Declared here rather than with the rest
   of the exception machinery because gc_collect scans it as a root, and that
   comes first in the file. */
static Value cl_thrown;
static int cl_equal(Value a, Value b);
static ClMethod cl_find_method(const char* cls, const char* m);
static char* cl_obj_display(Value v);

/* ── conservative mark-sweep garbage collector (opt-in) ──
   Every runtime value carries a small header and is tracked in a global list.
   The whole set is always released at exit (cl_arena_free), so the default
   behaviour is the leak-free arena: allocate, free once at the end. That is
   what ships on by default, and it is safe on every platform.

   Setting the CLARITY_GC environment variable turns on *mid-run* collection:
   when live bytes cross a threshold, cl_alloc flushes callee-saved registers
   to the stack (setjmp), conservatively scans the whole C stack and the
   interiors of reachable objects for words that point into a tracked
   allocation, marks the reachable set, and frees the rest. This reclaims
   memory during the run, but conservative scanning is layout/optimiser
   sensitive (it has shown instability under clang -O2 on arm64), so it stays
   experimental and off until a precise (shadow-stack) collector replaces it.

   Conservative: an integer that happens to look like a live pointer keeps its
   target alive (safe waste), but a real pointer is never missed as long as it
   sits on the stack or inside another live object. Our codegen never hides a
   pointer in a non-pointer or points into the middle of an allocation, and any
   pointer live across a cl_alloc call is spilled to the stack by the ABI, so
   the root set the scan sees is complete. cl_alloc is the single hook a
   precise/generational collector would later replace.

   The mark phase resolves each scanned word through gc_find, which binary-
   searches a payload-address-sorted snapshot of the live set (rebuilt once per
   collection) — so collecting with many simultaneously-live objects is
   O(n log n), not the quadratic a per-word linear walk would cost. */
typedef struct GCObj { struct GCObj* next; size_t size; unsigned char marked; } GCObj;
static GCObj* gc_head = 0;
static size_t gc_live = 0;
static size_t gc_threshold = 1<<20;      /* first collection after ~1 MiB live */
static char* gc_stack_base = 0;          /* set once at main entry */
static int gc_enabled = 0;               /* opt-in: mid-run collection off by default */

/* mark worklist + address index (plain malloc — not GC-tracked) */
static GCObj** gc_work = 0;
static size_t gc_work_len = 0, gc_work_cap = 0;
static GCObj** gc_index = 0;              /* all live objects, sorted by payload address */
static size_t gc_index_len = 0, gc_index_cap = 0;

/* Module-level Clarity bindings are emitted at C file scope so functions can
   see them, which puts them outside the conservative stack scan. The generated
   program hands the collector the table of their addresses at main entry;
   without it a global's object is swept while still reachable. */
static Value** cl_globals = 0;
static size_t cl_globals_n = 0;

static int gc_cmp(const void* a, const void* b){
  char* pa = (char*)(*(GCObj* const*)a + 1);
  char* pb = (char*)(*(GCObj* const*)b + 1);
  return (pa > pb) - (pa < pb);
}
/* snapshot the object list into a payload-address-sorted array so gc_find can
   binary-search instead of walking every object per scanned word */
static void gc_reindex(void){
  gc_index_len = 0;
  for(GCObj* o=gc_head; o; o=o->next){
    if(gc_index_len >= gc_index_cap){
      gc_index_cap = gc_index_cap ? gc_index_cap*2 : 1024;
      gc_index = (GCObj**)realloc(gc_index, sizeof(GCObj*)*gc_index_cap);
    }
    gc_index[gc_index_len++] = o;
  }
  qsort(gc_index, gc_index_len, sizeof(GCObj*), gc_cmp);
}
/* the tracked allocation containing p, or 0 — interior pointers included */
static GCObj* gc_find(void* p){
  char* c = (char*)p;
  size_t lo = 0, hi = gc_index_len;      /* largest payload start <= c */
  while(lo < hi){
    size_t mid = lo + (hi - lo)/2;
    if((char*)(gc_index[mid]+1) <= c) lo = mid + 1; else hi = mid;
  }
  if(lo == 0) return 0;
  GCObj* o = gc_index[lo-1];
  char* s = (char*)(o+1);
  if(c >= s && c < s + o->size) return o;
  return 0;
}
GC_NOSAN static void gc_scan(char* lo, char* hi){
  /* align the low bound so every read of a void* is aligned */
  lo = (char*)(((size_t)lo + sizeof(void*) - 1) & ~((size_t)(sizeof(void*)-1)));
  for(char* p=lo; p + sizeof(void*) <= hi; p += sizeof(void*)){
    GCObj* o = gc_find(*(void**)p);
    if(o && !o->marked){
      o->marked = 1;
      if(gc_work_len >= gc_work_cap){
        gc_work_cap = gc_work_cap ? gc_work_cap*2 : 256;
        gc_work = (GCObj**)realloc(gc_work, sizeof(GCObj*)*gc_work_cap);
      }
      gc_work[gc_work_len++] = o;
    }
  }
}
GC_NOSAN static void gc_collect(void){
  jmp_buf regs; setjmp(regs);                    /* spill callee-saved regs */
  char probe; char* sp = &probe;
  gc_work_len = 0;
  gc_reindex();                                  /* sorted index for O(log n) gc_find */
  char* lo = sp < gc_stack_base ? sp : gc_stack_base;
  char* hi = sp < gc_stack_base ? gc_stack_base : sp;
  gc_scan(lo, hi);                               /* roots: the live C stack */
  gc_scan((char*)&regs, (char*)&regs + sizeof(regs));
  for(size_t gi=0; gi<cl_globals_n; gi++)      /* roots: module-level bindings */
    gc_scan((char*)cl_globals[gi], (char*)cl_globals[gi] + sizeof(Value));
  gc_scan((char*)&cl_thrown, (char*)&cl_thrown + sizeof(Value));  /* roots: value in flight */
  while(gc_work_len){                            /* transitive closure */
    GCObj* o = gc_work[--gc_work_len];
    gc_scan((char*)(o+1), (char*)(o+1) + o->size);
  }
  GCObj** link = &gc_head;                        /* sweep */
  while(*link){
    GCObj* o = *link;
    if(o->marked){ o->marked = 0; link = &o->next; }
    else { *link = o->next; gc_live -= o->size; free(o); }
  }
}
static void* cl_alloc(size_t n){
  n = (n + 15) & ~((size_t)15);                  /* 16-byte align */
  if(gc_enabled && gc_stack_base && gc_live + n > gc_threshold){
    gc_collect();
    if(gc_live > gc_threshold/2) gc_threshold *= 2;   /* grow to amortise */
  }
  GCObj* o = (GCObj*)malloc(sizeof(GCObj) + n);
  o->size = n; o->marked = 0; o->next = gc_head; gc_head = o;
  gc_live += n;
  return (void*)(o + 1);
}
static char* cl_strdup(const char* s){
  size_t n = strlen(s) + 1;
  char* out = (char*)cl_alloc(n);
  memcpy(out, s, n);
  return out;
}
static void cl_arena_free(void){                 /* release everything at exit */
  GCObj* o = gc_head;
  while(o){ GCObj* nx = o->next; free(o); o = nx; }
  gc_head = 0; free(gc_work); gc_work = 0; free(gc_index); gc_index = 0;
}

static Value cl_null(void){ Value v; v.t=T_NULL; v.i=0; v.f=0; v.s=0; v.o=0; return v; }
static Value cl_bool(long b){ Value v=cl_null(); v.t=T_BOOL; v.i=(b!=0); return v; }
static Value cl_int(long i){ Value v=cl_null(); v.t=T_INT; v.i=i; return v; }
static Value cl_float(double f){ Value v=cl_null(); v.t=T_FLOAT; v.f=f; return v; }
static Value cl_str(const char* s){ Value v=cl_null(); v.t=T_STR; v.s=s; return v; }

/* Lists and maps live behind a pointer, so a Value copy shares the backing
   store — push/index-set mutate through it. Backing storage is arena memory,
   reclaimed wholesale at exit; growth allocates a fresh block and copies. */
static Value cl_list_new(void){
  List* l=(List*)cl_alloc(sizeof(List));
  l->len=0; l->cap=4; l->items=(Value*)cl_alloc(sizeof(Value)*l->cap);
  Value v=cl_null(); v.t=T_LIST; v.o=l; return v;
}
static Value cl_list_add(Value lv, Value item){
  List* l=(List*)lv.o;
  if(l->len>=l->cap){
    long nc=l->cap*2;
    Value* ni=(Value*)cl_alloc(sizeof(Value)*nc);
    memcpy(ni, l->items, sizeof(Value)*l->len);
    l->items=ni; l->cap=nc;
  }
  l->items[l->len++]=item; return lv;
}
static Value cl_map_new(void){
  Map* m=(Map*)cl_alloc(sizeof(Map));
  m->len=0; m->cap=4; m->keys=(char**)cl_alloc(sizeof(char*)*m->cap); m->vals=(Value*)cl_alloc(sizeof(Value)*m->cap);
  Value v=cl_null(); v.t=T_MAP; v.o=m; return v;
}
static Value cl_map_put(Value mv, char* key, Value val){
  Map* m=(Map*)mv.o;
  for(long j=0;j<m->len;j++){ if(strcmp(m->keys[j],key)==0){ m->vals[j]=val; return mv; } }
  if(m->len>=m->cap){
    long nc=m->cap*2;
    char** nk=(char**)cl_alloc(sizeof(char*)*nc);
    Value* nv=(Value*)cl_alloc(sizeof(Value)*nc);
    memcpy(nk, m->keys, sizeof(char*)*m->len);
    memcpy(nv, m->vals, sizeof(Value)*m->len);
    m->keys=nk; m->vals=nv; m->cap=nc;
  }
  m->keys[m->len]=cl_strdup(key); m->vals[m->len]=val; m->len++; return mv;
}

static int cl_is_num(Value v){ return v.t==T_INT || v.t==T_FLOAT; }
static double cl_num(Value v){ return v.t==T_FLOAT ? v.f : (double)v.i; }

/* grow-and-append into a fresh arena buffer (the accumulator is arena memory,
   reclaimed at exit — no per-call free) */
static char* cl_cat(char* a, const char* b){
  size_t la=strlen(a), lb=strlen(b);
  char* out=(char*)cl_alloc(la+lb+1);
  memcpy(out, a, la); memcpy(out+la, b, lb+1);
  return out;
}

static char* cl_to_cstr(Value v){
  if(v.t==T_LIST || v.t==T_MAP) return cl_repr(v);
  if(v.t==T_OBJECT) return cl_obj_display(v);
  if(v.t==T_CLOSURE){ char* b=(char*)cl_alloc(16); strcpy(b, "<closure>"); return b; }
  char* buf = (char*)cl_alloc(64);
  switch(v.t){
    case T_NULL: strcpy(buf, "null"); return buf;
    case T_BOOL: strcpy(buf, v.i ? "true" : "false"); return buf;
    case T_INT: snprintf(buf, 64, "%ld", v.i); return buf;
    case T_FLOAT:
      if(v.f == (double)(long)v.f && v.f < 1e18 && v.f > -1e18){ snprintf(buf, 64, "%ld", (long)v.f); return buf; }
      /* shortest %g precision that round-trips — matches JS number formatting
         (3.14, not 3.1400000000000001) */
      for(int prec=1; prec<=17; prec++){ snprintf(buf, 64, "%.*g", prec, v.f); if(strtod(buf, 0)==v.f) break; }
      return buf;
    case T_STR: return (char*)v.s;
    default: return buf;
  }
}

/* repr quotes strings and recurses into collections (used inside [] and {}) */
static char* cl_repr(Value v){
  if(v.t==T_STR){
    size_t n=strlen(v.s); char* out=(char*)cl_alloc(n+3);
    out[0]='"'; memcpy(out+1, v.s, n); out[n+1]='"'; out[n+2]=0; return out;
  }
  if(v.t==T_LIST){
    List* l=(List*)v.o; char* out=(char*)cl_alloc(2); strcpy(out, "[");
    for(long j=0;j<l->len;j++){ if(j) out=cl_cat(out, ", "); out=cl_cat(out, cl_repr(l->items[j])); }
    return cl_cat(out, "]");
  }
  if(v.t==T_MAP){
    Map* m=(Map*)v.o; char* out=(char*)cl_alloc(2); strcpy(out, "{");
    for(long j=0;j<m->len;j++){ if(j) out=cl_cat(out, ", "); out=cl_cat(out, m->keys[j]); out=cl_cat(out, ": "); out=cl_cat(out, cl_repr(m->vals[j])); }
    return cl_cat(out, "}");
  }
  return cl_to_cstr(v);
}
/* display leaves top-level strings unquoted but reprs nested collections */
static char* cl_display(Value v){
  if(v.t==T_LIST || v.t==T_MAP) return cl_repr(v);
  if(v.t==T_OBJECT) return cl_obj_display(v);
  return cl_to_cstr(v);
}

static Value cl_concat(Value a, Value b){
  char* sa = cl_to_cstr(a); char* sb = cl_to_cstr(b);
  char* out = (char*)cl_alloc(strlen(sa)+strlen(sb)+1);
  strcpy(out, sa); strcat(out, sb);
  return cl_str(out);
}

static Value cl_add(Value a, Value b){
  if(a.t==T_STR || b.t==T_STR) return cl_concat(a, b);
  if(a.t==T_FLOAT || b.t==T_FLOAT) return cl_float(cl_num(a)+cl_num(b));
  return cl_int(a.i+b.i);
}
static Value cl_sub(Value a, Value b){
  if(a.t==T_FLOAT || b.t==T_FLOAT) return cl_float(cl_num(a)-cl_num(b));
  return cl_int(a.i-b.i);
}
static Value cl_mul(Value a, Value b){
  if(a.t==T_FLOAT || b.t==T_FLOAT) return cl_float(cl_num(a)*cl_num(b));
  return cl_int(a.i*b.i);
}
static Value cl_div(Value a, Value b){
  double d = cl_num(b);
  if(d == 0.0) return cl_int(0);
  return cl_float(cl_num(a)/d);
}
static Value cl_mod(Value a, Value b){
  if(b.i == 0) return cl_int(0);
  if(a.t==T_FLOAT || b.t==T_FLOAT) return cl_float(fmod(cl_num(a), cl_num(b)));
  return cl_int(a.i % b.i);
}
static Value cl_pow(Value a, Value b){
  if(a.t==T_INT && b.t==T_INT && b.i>=0){
    long r=1, base=a.i, e=b.i; while(e-->0) r*=base; return cl_int(r);
  }
  return cl_float(pow(cl_num(a), cl_num(b)));
}
/* Bitwise ops match the interpreter's JS semantics: operands are truncated to
   signed 32-bit, shift counts masked to 5 bits, results are signed 32-bit.
   (`int` is 32-bit on every platform we target.) 64-bit/unsigned bitwise is a
   tracked follow-up — it needs the numeric tower to grow past JS doubles. */
static Value cl_band(Value a, Value b){ return cl_int((long)((int)a.i & (int)b.i)); }
static Value cl_bor(Value a, Value b){ return cl_int((long)((int)a.i | (int)b.i)); }
static Value cl_bxor(Value a, Value b){ return cl_int((long)((int)a.i ^ (int)b.i)); }
static Value cl_shl(Value a, Value b){ return cl_int((long)((int)a.i << ((int)b.i & 31))); }
static Value cl_shr(Value a, Value b){ return cl_int((long)((int)a.i >> ((int)b.i & 31))); }
static Value cl_neg(Value a){
  if(a.t==T_FLOAT) return cl_float(-a.f);
  return cl_int(-a.i);
}

static int cl_truthy(Value v){
  switch(v.t){
    case T_NULL: return 0;
    case T_BOOL: case T_INT: return v.i!=0;
    case T_FLOAT: return v.f!=0.0;
    case T_STR: return v.s && v.s[0];
    case T_LIST: return ((List*)v.o)->len!=0;
    case T_MAP: return ((Map*)v.o)->len!=0;
    case T_OBJECT: return 1;
    case T_CLOSURE: return 1;
  }
  return 0;
}
static Value cl_not(Value a){ return cl_bool(!cl_truthy(a)); }

/* Lists and maps compare by contents, as both other engines do: a list
   element-wise and in order, a map by key regardless of insertion order. An
   instance compares by identity — C(1) == C(1) is false everywhere — and so
   does a closure, which is why neither falls through to the `i` comparison
   below: `i` is 0 in every pointer-backed Value, so that fallthrough made
   any two closures equal. */
static int cl_equal(Value a, Value b){
  if(a.t==T_STR && b.t==T_STR) return strcmp(a.s, b.s)==0;
  if(cl_is_num(a) && cl_is_num(b)) return cl_num(a)==cl_num(b);
  if(a.t != b.t) return 0;
  if(a.t==T_LIST){
    List* x=(List*)a.o; List* y=(List*)b.o;
    if(x==y) return 1;
    if(x->len != y->len) return 0;
    for(long i=0;i<x->len;i++) if(!cl_equal(x->items[i], y->items[i])) return 0;
    return 1;
  }
  if(a.t==T_MAP){
    Map* x=(Map*)a.o; Map* y=(Map*)b.o;
    if(x==y) return 1;
    if(x->len != y->len) return 0;
    for(long i=0;i<x->len;i++){
      int found=0;
      for(long j=0;j<y->len;j++){
        if(strcmp(x->keys[i], y->keys[j])==0){
          if(!cl_equal(x->vals[i], y->vals[j])) return 0;
          found=1; break;
        }
      }
      if(!found) return 0;
    }
    return 1;
  }
  if(a.t==T_OBJECT || a.t==T_CLOSURE) return a.o==b.o;
  return a.i==b.i;
}
static Value cl_eq(Value a, Value b){ return cl_bool(cl_equal(a,b)); }
static Value cl_neq(Value a, Value b){ return cl_bool(!cl_equal(a,b)); }
static Value cl_lt(Value a, Value b){
  if(a.t==T_STR && b.t==T_STR) return cl_bool(strcmp(a.s,b.s)<0);
  return cl_bool(cl_num(a)<cl_num(b));
}
static Value cl_gt(Value a, Value b){
  if(a.t==T_STR && b.t==T_STR) return cl_bool(strcmp(a.s,b.s)>0);
  return cl_bool(cl_num(a)>cl_num(b));
}
static Value cl_lte(Value a, Value b){
  if(a.t==T_STR && b.t==T_STR) return cl_bool(strcmp(a.s,b.s)<=0);
  return cl_bool(cl_num(a)<=cl_num(b));
}
static Value cl_gte(Value a, Value b){
  if(a.t==T_STR && b.t==T_STR) return cl_bool(strcmp(a.s,b.s)>=0);
  return cl_bool(cl_num(a)>=cl_num(b));
}

/* ── collections: length, indexing, iteration ── */
static long cl_length(Value v){
  if(v.t==T_LIST) return ((List*)v.o)->len;
  if(v.t==T_MAP) return ((Map*)v.o)->len;
  if(v.t==T_STR) return (long)strlen(v.s);
  return 0;
}
static Value cl_index(Value c, Value k){
  if(c.t==T_LIST){ List* l=(List*)c.o; long idx=k.i; if(idx<0) idx+=l->len; if(idx<0||idx>=l->len) return cl_null(); return l->items[idx]; }
  if(c.t==T_MAP){ Map* m=(Map*)c.o; char* ks=cl_to_cstr(k); for(long j=0;j<m->len;j++) if(strcmp(m->keys[j],ks)==0) return m->vals[j]; return cl_null(); }
  if(c.t==T_STR){ long n=(long)strlen(c.s); long idx=k.i; if(idx<0) idx+=n; if(idx<0||idx>=n) return cl_null(); char* ch=(char*)cl_alloc(2); ch[0]=c.s[idx]; ch[1]=0; return cl_str(ch); }
  /* An instance reads like the map of its fields — what makes keys(obj)
     useful, since `for k in keys(p) { p[k] }` is the loop anyone writes next.
     A missing field is null, the same answer a map gives. */
  if(c.t==T_OBJECT){ Obj* o=(Obj*)c.o; return cl_index(o->fields, k); }
  return cl_null();
}
static void cl_index_set(Value c, Value k, Value val){
  if(c.t==T_LIST){ List* l=(List*)c.o; long idx=k.i; if(idx<0) idx+=l->len; if(idx>=0&&idx<l->len) l->items[idx]=val; }
  else if(c.t==T_MAP){ char* ks=cl_to_cstr(k); cl_map_put(c, ks, val); }
  else if(c.t==T_OBJECT){ Obj* o=(Obj*)c.o; char* ks=cl_to_cstr(k); cl_map_put(o->fields, ks, val); }
}
/* materialise the thing a for-loop walks: lists as-is, map keys, string chars */
static Value cl_iter(Value v){
  if(v.t==T_LIST) return v;
  if(v.t==T_MAP){ Map* m=(Map*)v.o; Value out=cl_list_new(); for(long j=0;j<m->len;j++) cl_list_add(out, cl_str(m->keys[j])); return out; }
  if(v.t==T_STR){ Value out=cl_list_new(); long n=(long)strlen(v.s); for(long j=0;j<n;j++){ char* ch=(char*)cl_alloc(2); ch[0]=v.s[j]; ch[1]=0; cl_list_add(out, cl_str(ch)); } return out; }
  return cl_list_new();
}

/* ── builtins reachable from native code ── */
static Value cl_range2(Value a, Value b){ Value out=cl_list_new(); for(long j=a.i;j<b.i;j++) cl_list_add(out, cl_int(j)); return out; }
/* An object's field map, or the value unchanged for anything else.
   keys/values/entries/has accept an instance and answer with its fields, the
   same as the interpreter and the transpiled backend do — an object is a map
   with a class name attached, and asking it what it holds should say. */
static Value cl_fields_of(Value v){ if(v.t==T_OBJECT){ Obj* o=(Obj*)v.o; return o->fields; } return v; }
static Value cl_keys(Value vv){ Value v=cl_fields_of(vv); Value out=cl_list_new(); if(v.t==T_MAP){ Map* m=(Map*)v.o; for(long j=0;j<m->len;j++) cl_list_add(out, cl_str(m->keys[j])); } return out; }
static Value cl_has(Value vv, Value k){ Value v=cl_fields_of(vv); if(v.t==T_MAP){ Map* m=(Map*)v.o; char* ks=cl_to_cstr(k); for(long j=0;j<m->len;j++) if(strcmp(m->keys[j],ks)==0) return cl_bool(1); } return cl_bool(0); }
static Value cl_contains(Value a, Value b){
  if(a.t==T_STR){ char* ns=cl_to_cstr(b); return cl_bool(strstr((char*)a.s, ns)!=0); }
  if(a.t==T_LIST){ List* l=(List*)a.o; for(long j=0;j<l->len;j++) if(cl_equal(l->items[j], b)) return cl_bool(1); return cl_bool(0); }
  return cl_bool(0);
}

/* ── objects: instances, fields, method dispatch ── */
static Value cl_object_new(const char* cls){
  Obj* o=(Obj*)cl_alloc(sizeof(Obj));
  o->cls=cls; o->fields=cl_map_new();
  Value v=cl_null(); v.t=T_OBJECT; v.o=o; return v;
}
static Value cl_get_field(Value obj, const char* name){
  Map* m=0;
  if(obj.t==T_OBJECT) m=(Map*)((Obj*)obj.o)->fields.o;   /* instance field map */
  else if(obj.t==T_MAP) m=(Map*)obj.o;                    /* map.key sugar for map["key"] */
  else return cl_null();
  for(long j=0;j<m->len;j++) if(strcmp(m->keys[j],name)==0) return m->vals[j];
  return cl_null();
}
static Value cl_set_field(Value obj, const char* name, Value val){
  if(obj.t==T_OBJECT){ Obj* o=(Obj*)obj.o; cl_map_put(o->fields, (char*)name, val); }
  return val;
}
static void cl_register(const char* cls, const char* m, ClMethod fn){
  if(cl_method_count >= 1024){ cl_die("clarity: method table overflow (>1024 methods)"); }
  cl_method_table[cl_method_count].cls=cls;
  cl_method_table[cl_method_count].m=m;
  cl_method_table[cl_method_count].fn=fn;
  cl_method_count++;
}
static ClMethod cl_find_method(const char* cls, const char* m){
  for(int i=0;i<cl_method_count;i++)
    if(strcmp(cl_method_table[i].cls,cls)==0 && strcmp(cl_method_table[i].m,m)==0)
      return cl_method_table[i].fn;
  return 0;
}
/* obj.method(args): resolve on the instance's class, call with the arg array */
static Value cl_dispatch(Value self, const char* m, Value* a, long n){
  const char* cls = (self.t==T_OBJECT) ? ((Obj*)self.o)->cls : "";
  ClMethod fn = cl_find_method(cls, m);
  if(fn) return fn(self, a, n);
  return cl_null();
}
/* instances print via a to_string method if defined, else <Cls instance> */
static char* cl_obj_default_display(Obj* o){
  char* out=(char*)cl_alloc(strlen(o->cls)+16);
  sprintf(out, "<%s instance>", o->cls);
  return out;
}
static char* cl_obj_to_string(Value v);   /* with the exception machinery below */
static char* cl_obj_display(Value v){
  Obj* o=(Obj*)v.o;
  if(cl_find_method(o->cls, "to_string")) return cl_obj_to_string(v);
  return cl_obj_default_display(o);
}

/* ── closures ── */
static Value cl_closure_new(ClFn fn, Value* cap, int ncap){
  Closure* c=(Closure*)cl_alloc(sizeof(Closure));
  c->fn=fn; c->ncap=ncap;
  c->cap=(Value*)cl_alloc(sizeof(Value)*(ncap>0?ncap:1));
  for(int i=0;i<ncap;i++) c->cap[i]=cap[i];
  Value v=cl_null(); v.t=T_CLOSURE; v.o=c; return v;
}
static Value cl_call(Value f, Value* args, long n){
  if(f.t==T_CLOSURE){ Closure* c=(Closure*)f.o; return c->fn(args, c->cap, n); }
  return cl_null();
}

/* The i-th argument, or null past the end.
   Clarity lets a call supply fewer arguments than the function declares, and
   the missing ones are null. Reading a[i] directly was fine only while every
   call site happened to supply them all: a method with parameters called with
   none was handed a null array and dereferenced it. */
static Value cl_arg(Value* a, long n, long i){ return (i < n) ? a[i] : cl_null(); }

/* The arguments from `i` onwards, as a list — a rest parameter's value. */
static Value cl_rest(Value* a, long n, long i){
  Value out = cl_list_new();
  for(long j=i;j<n;j++) cl_list_add(out, a[j]);
  return out;
}

/* higher-order builtins that drive a closure over a collection.
   NB: array initializers keep a space after the opening brace; an open
   brace followed directly by a letter reads as Clarity string interpolation
   while this prelude is still a source literal. */
static Value cl_hof_map(Value lst, Value fn){
  Value out=cl_list_new(); Value it=cl_iter(lst); long n=cl_length(it);
  for(long i=0;i<n;i++){ Value a[1]={ cl_index(it, cl_int(i)) }; cl_list_add(out, cl_call(fn, a, 1)); }
  return out;
}
static Value cl_hof_filter(Value lst, Value fn){
  Value out=cl_list_new(); Value it=cl_iter(lst); long n=cl_length(it);
  for(long i=0;i<n;i++){ Value e=cl_index(it, cl_int(i)); Value a[1]={ e }; if(cl_truthy(cl_call(fn, a, 1))) cl_list_add(out, e); }
  return out;
}
static Value cl_hof_reduce(Value lst, Value fn, Value init){
  Value acc=init; Value it=cl_iter(lst); long n=cl_length(it);
  for(long i=0;i<n;i++){ Value a[2]={ acc, cl_index(it, cl_int(i)) }; acc=cl_call(fn, a, 2); }
  return acc;
}
/* ── encoding, hashing, environment ── */
static const char CL_B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static Value cl_encode64(Value v){
  const unsigned char* in = (const unsigned char*)v.s;
  size_t n = strlen((const char*)in);
  size_t outlen = 4 * ((n + 2) / 3);
  char* o = (char*)cl_alloc(outlen + 1);
  size_t i = 0, j = 0;
  while(i + 2 < n){
    unsigned long t = ((unsigned long)in[i]<<16) | ((unsigned long)in[i+1]<<8) | in[i+2];
    o[j++]=CL_B64[(t>>18)&63]; o[j++]=CL_B64[(t>>12)&63];
    o[j++]=CL_B64[(t>>6)&63];  o[j++]=CL_B64[t&63];
    i += 3;
  }
  if(i < n){                       /* 1 or 2 bytes left; pad to a quantum */
    unsigned long t = (unsigned long)in[i] << 16;
    int two = (i + 1 < n);
    if(two) t |= (unsigned long)in[i+1] << 8;
    o[j++]=CL_B64[(t>>18)&63]; o[j++]=CL_B64[(t>>12)&63];
    o[j++]= two ? CL_B64[(t>>6)&63] : '=';
    o[j++]='=';
  }
  o[j]=0;
  return cl_str(o);
}

static int cl_b64_val(char c){
  if(c>='A'&&c<='Z') return c-'A';
  if(c>='a'&&c<='z') return c-'a'+26;
  if(c>='0'&&c<='9') return c-'0'+52;
  if(c=='+') return 62;
  if(c=='/') return 63;
  return -1;                       /* '=' and anything else */
}

static Value cl_decode64(Value v){
  const char* in = v.s; size_t n = strlen(in);
  char* o = (char*)cl_alloc(n + 1);
  size_t j = 0; int quad[4]; int q = 0;
  for(size_t i=0;i<n;i++){
    int d = cl_b64_val(in[i]);
    if(d < 0) continue;            /* skip padding and whitespace */
    quad[q++] = d;
    if(q == 4){
      o[j++] = (char)((quad[0]<<2) | (quad[1]>>4));
      o[j++] = (char)(((quad[1]&15)<<4) | (quad[2]>>2));
      o[j++] = (char)(((quad[2]&3)<<6) | quad[3]);
      q = 0;
    }
  }
  if(q == 3){                      /* two bytes encoded */
    o[j++] = (char)((quad[0]<<2) | (quad[1]>>4));
    o[j++] = (char)(((quad[1]&15)<<4) | (quad[2]>>2));
  } else if(q == 2){               /* one byte encoded */
    o[j++] = (char)((quad[0]<<2) | (quad[1]>>4));
  }
  o[j]=0;
  return cl_str(o);
}

/* SHA-256, FIPS 180-4. The interpreter's hash() is node's createHash('sha256')
   and returns lowercase hex, so this has to agree with it byte for byte. */
static unsigned long cl_rotr(unsigned long x, int n){ return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFFul; }

static Value cl_sha256_hex(Value v){
  static const unsigned long K[64] = {
    0x428a2f98ul,0x71374491ul,0xb5c0fbcful,0xe9b5dba5ul,0x3956c25bul,0x59f111f1ul,0x923f82a4ul,0xab1c5ed5ul,
    0xd807aa98ul,0x12835b01ul,0x243185beul,0x550c7dc3ul,0x72be5d74ul,0x80deb1feul,0x9bdc06a7ul,0xc19bf174ul,
    0xe49b69c1ul,0xefbe4786ul,0x0fc19dc6ul,0x240ca1ccul,0x2de92c6ful,0x4a7484aaul,0x5cb0a9dcul,0x76f988daul,
    0x983e5152ul,0xa831c66dul,0xb00327c8ul,0xbf597fc7ul,0xc6e00bf3ul,0xd5a79147ul,0x06ca6351ul,0x14292967ul,
    0x27b70a85ul,0x2e1b2138ul,0x4d2c6dfcul,0x53380d13ul,0x650a7354ul,0x766a0abbul,0x81c2c92eul,0x92722c85ul,
    0xa2bfe8a1ul,0xa81a664bul,0xc24b8b70ul,0xc76c51a3ul,0xd192e819ul,0xd6990624ul,0xf40e3585ul,0x106aa070ul,
    0x19a4c116ul,0x1e376c08ul,0x2748774cul,0x34b0bcb5ul,0x391c0cb3ul,0x4ed8aa4aul,0x5b9cca4ful,0x682e6ff3ul,
    0x748f82eeul,0x78a5636ful,0x84c87814ul,0x8cc70208ul,0x90befffaul,0xa4506cebul,0xbef9a3f7ul,0xc67178f2ul };
  unsigned long h[8] = {0x6a09e667ul,0xbb67ae85ul,0x3c6ef372ul,0xa54ff53aul,
                        0x510e527ful,0x9b05688cul,0x1f83d9abul,0x5be0cd19ul};
  const unsigned char* msg = (const unsigned char*)v.s;
  size_t len = strlen((const char*)msg);
  size_t total = ((len + 9 + 63) / 64) * 64;
  unsigned char* buf = (unsigned char*)cl_alloc(total);
  memset(buf, 0, total);
  memcpy(buf, msg, len);
  buf[len] = 0x80;
  unsigned long long bits = (unsigned long long)len * 8ull;
  for(int i=0;i<8;i++) buf[total-1-i] = (unsigned char)((bits >> (8*i)) & 0xFF);

  for(size_t off=0; off<total; off+=64){
    unsigned long w[64];
    for(int i=0;i<16;i++){
      const unsigned char* p = buf + off + i*4;
      w[i] = ((unsigned long)p[0]<<24)|((unsigned long)p[1]<<16)|((unsigned long)p[2]<<8)|p[3];
    }
    for(int i=16;i<64;i++){
      unsigned long s0 = cl_rotr(w[i-15],7) ^ cl_rotr(w[i-15],18) ^ (w[i-15] >> 3);
      unsigned long s1 = cl_rotr(w[i-2],17) ^ cl_rotr(w[i-2],19) ^ (w[i-2] >> 10);
      w[i] = (w[i-16] + s0 + w[i-7] + s1) & 0xFFFFFFFFul;
    }
    unsigned long a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
    for(int i=0;i<64;i++){
      unsigned long S1 = cl_rotr(e,6) ^ cl_rotr(e,11) ^ cl_rotr(e,25);
      unsigned long ch = (e & f) ^ ((~e & 0xFFFFFFFFul) & g);
      unsigned long t1 = (hh + S1 + ch + K[i] + w[i]) & 0xFFFFFFFFul;
      unsigned long S0 = cl_rotr(a,2) ^ cl_rotr(a,13) ^ cl_rotr(a,22);
      unsigned long mj = (a & b) ^ (a & c) ^ (b & c);
      unsigned long t2 = (S0 + mj) & 0xFFFFFFFFul;
      hh=g; g=f; f=e; e=(d+t1)&0xFFFFFFFFul; d=c; c=b; b=a; a=(t1+t2)&0xFFFFFFFFul;
    }
    h[0]=(h[0]+a)&0xFFFFFFFFul; h[1]=(h[1]+b)&0xFFFFFFFFul;
    h[2]=(h[2]+c)&0xFFFFFFFFul; h[3]=(h[3]+d)&0xFFFFFFFFul;
    h[4]=(h[4]+e)&0xFFFFFFFFul; h[5]=(h[5]+f)&0xFFFFFFFFul;
    h[6]=(h[6]+g)&0xFFFFFFFFul; h[7]=(h[7]+hh)&0xFFFFFFFFul;
  }
  char* o = (char*)cl_alloc(65);
  for(int i=0;i<8;i++) sprintf(o + i*8, "%08lx", h[i]);
  o[64]=0;
  return cl_str(o);
}

static Value cl_cwd(void){
#ifdef CLARITY_FREESTANDING
  /* No working directory without a filesystem. The empty string is what the
     hosted path also returns when getcwd fails, so callers already handle it. */
  return cl_str("");
#else
  char* o = (char*)cl_alloc(4096);
  if(!getcwd(o, 4096)) { o[0]=0; }
  return cl_str(o);
#endif
}

/* Seeded once, lazily: a compiled tool that returns the same "random" numbers
   on every run would be a surprising thing to ship. */
static int cl_rand_ready = 0;
static double cl_rand_unit(void){
  if(!cl_rand_ready){
#ifdef CLARITY_FREESTANDING
    /* No clock and no pid to mix in yet. Stated rather than hidden: on a
       freestanding target the sequence is the same on every run until the
       host gains a time source to seed from. */
    srand(1);
#else
    srand((unsigned)time(0) ^ (unsigned)getpid());
#endif
    cl_rand_ready = 1;
  }
  return (double)rand() / ((double)RAND_MAX + 1.0);
}
static Value cl_random0(void){ return cl_float(cl_rand_unit()); }
static Value cl_random1(Value n){ return cl_int((long)(cl_rand_unit() * cl_num(n))); }
static Value cl_random2(Value a, Value b){
  double lo = cl_num(a), hi = cl_num(b);
  return cl_int((long)(cl_rand_unit() * (hi - lo)) + (long)lo);
}

/* ── exceptions ──
 *
 * A stack of setjmp handlers, innermost first, and one slot for the value in
 * flight. `throw` records the value and longjmps to the nearest handler; with
 * no handler it reports and exits, because a compiled program silently
 * ignoring an uncaught throw would be worse than one that stops.
 *
 * cl_thrown is a GC root — it is often the only reference to the value while
 * the stack that held it is being unwound.
 *
 * Note on setjmp and local variables: C leaves a non-volatile local of the
 * function containing the setjmp indeterminate if it is modified inside the
 * try. The emitter therefore gives `let`/`mut` locals of any function
 * containing a try `volatile` storage. A parameter reassigned inside a try is
 * the one case still relying on the compiler's returns_twice handling rather
 * than on the standard; clang and gcc both spill across setjmp, but it is a
 * gap and is recorded as one.
 */
typedef struct ClHandler { jmp_buf buf; struct ClHandler* prev; } ClHandler;
static ClHandler* cl_handlers = 0;

static void cl_throw(Value v){
  cl_thrown = v;
  if(!cl_handlers){
    cl_eprint("clarity: uncaught throw: ", cl_display(v));
    exit(1);
  }
  longjmp(cl_handlers->buf, 1);
}

/* A to_string() that throws falls back to the default rendering, which is
 * what the interpreter and the VM do: showing a value must not be able to
 * end the program. It needs a handler, so it lives below cl_throw and
 * cl_obj_display reaches it through the forward declaration above. */
static char* cl_obj_to_string(Value v){
  Obj* o=(Obj*)v.o;
  ClMethod ts = cl_find_method(o->cls, "to_string");
  ClHandler h; h.prev = cl_handlers; cl_handlers = &h;
  if(setjmp(h.buf) == 0){
    char* out = cl_display(ts(v, 0, 0));
    cl_handlers = h.prev;
    return out;
  }
  cl_handlers = h.prev;
  return cl_obj_default_display(o);
}

static Value cl_hof_each(Value lst, Value fn){
  Value it=cl_iter(lst); long n=cl_length(it);
  for(long i=0;i<n;i++){ Value a[1]={ cl_index(it, cl_int(i)) }; cl_call(fn, a, 1); }
  return cl_null();
}
static Value cl_hof_find(Value lst, Value fn){
  Value it=cl_iter(lst); long n=cl_length(it);
  for(long i=0;i<n;i++){ Value e=cl_index(it, cl_int(i)); Value a[1]={ e }; if(cl_truthy(cl_call(fn, a, 1))) return e; }
  return cl_null();   /* JS find returns undefined; the interpreter maps that to null */
}
static Value cl_hof_every(Value lst, Value fn){
  Value it=cl_iter(lst); long n=cl_length(it);
  for(long i=0;i<n;i++){ Value a[1]={ cl_index(it, cl_int(i)) }; if(!cl_truthy(cl_call(fn, a, 1))) return cl_bool(0); }
  return cl_bool(1);
}
static Value cl_hof_some(Value lst, Value fn){
  Value it=cl_iter(lst); long n=cl_length(it);
  for(long i=0;i<n;i++){ Value a[1]={ cl_index(it, cl_int(i)) }; if(cl_truthy(cl_call(fn, a, 1))) return cl_bool(1); }
  return cl_bool(0);
}

/* ── app stdlib: list ops ── */
static Value cl_pop(Value lv){
  if(lv.t!=T_LIST) return cl_null();
  List* l=(List*)lv.o; if(l->len==0) return cl_null();
  l->len--; return l->items[l->len];
}
/* JS sorts with (a,b) => a < b ? -1 : a > b ? 1 : 0, over a copy. */
static int cl_sort_cmp(Value a, Value b){
  if(cl_truthy(cl_lt(a,b))) return -1;
  if(cl_truthy(cl_lt(b,a))) return 1;
  return 0;
}
/* Bottom-up merge sort: Array.prototype.sort is required to be stable, and an
   unstable sort would disagree with the interpreter on equal-comparing
   elements — exactly the kind of difference that shows up much later. */
static Value cl_sort(Value lv){
  Value out=cl_list_new();
  if(lv.t!=T_LIST) return out;
  List* src=(List*)lv.o; long n=src->len;
  for(long i=0;i<n;i++) cl_list_add(out, src->items[i]);
  if(n<2) return out;
  List* a=(List*)out.o;
  Value* buf=(Value*)cl_alloc((size_t)n*sizeof(Value));
  for(long width=1; width<n; width*=2){
    for(long lo=0; lo<n; lo+=2*width){
      long mid=lo+width; if(mid>n) mid=n;
      long hi=lo+2*width; if(hi>n) hi=n;
      long i=lo, j=mid, k=lo;
      while(i<mid && j<hi) buf[k++] = (cl_sort_cmp(a->items[j], a->items[i])<0) ? a->items[j++] : a->items[i++];
      while(i<mid) buf[k++]=a->items[i++];
      while(j<hi)  buf[k++]=a->items[j++];
      for(long t=lo;t<hi;t++) a->items[t]=buf[t];
    }
  }
  return out;
}
static Value cl_reverse(Value v){
  if(v.t==T_STR){ size_t n=strlen(v.s); char* o=(char*)cl_alloc(n+1); for(size_t i=0;i<n;i++) o[i]=v.s[n-1-i]; o[n]=0; return cl_str(o); }
  Value out=cl_list_new();
  if(v.t!=T_LIST) return out;
  List* l=(List*)v.o; for(long i=l->len-1;i>=0;i--) cl_list_add(out, l->items[i]);
  return out;
}
/* new Set(...) keeps first occurrences, in order. */
static Value cl_unique(Value lv){
  Value out=cl_list_new();
  if(lv.t!=T_LIST) return out;
  List* l=(List*)lv.o;
  for(long i=0;i<l->len;i++){
    List* o=(List*)out.o; int seen=0;
    for(long j=0;j<o->len;j++) if(cl_equal(o->items[j], l->items[i])){ seen=1; break; }
    if(!seen) cl_list_add(out, l->items[i]);
  }
  return out;
}
/* Array.prototype.flat() with no argument: one level only. */
static Value cl_flat(Value lv){
  Value out=cl_list_new();
  if(lv.t!=T_LIST) return out;
  List* l=(List*)lv.o;
  for(long i=0;i<l->len;i++){
    Value e=l->items[i];
    if(e.t==T_LIST){ List* inner=(List*)e.o; for(long j=0;j<inner->len;j++) cl_list_add(out, inner->items[j]); }
    else cl_list_add(out, e);
  }
  return out;
}
static Value cl_zip(Value* ls, long count){
  Value out=cl_list_new();
  if(count<=0) return out;
  long min=cl_length(ls[0]);
  for(long i=1;i<count;i++){ long n=cl_length(ls[i]); if(n<min) min=n; }
  for(long i=0;i<min;i++){
    Value row=cl_list_new();
    for(long j=0;j<count;j++) cl_list_add(row, cl_index(ls[j], cl_int(i)));
    cl_list_add(out, row);
  }
  return out;
}
static Value cl_values(Value vv){
  Value v=cl_fields_of(vv);
  Value out=cl_list_new();
  if(v.t==T_MAP){ Map* m=(Map*)v.o; for(long j=0;j<m->len;j++) cl_list_add(out, m->vals[j]); }
  return out;
}
static Value cl_entries(Value vv){
  Value v=cl_fields_of(vv);
  Value out=cl_list_new();
  if(v.t==T_MAP){
    Map* m=(Map*)v.o;
    for(long j=0;j<m->len;j++){
      Value pair=cl_list_new();
      cl_list_add(pair, cl_str(m->keys[j]));
      cl_list_add(pair, m->vals[j]);
      cl_list_add(out, pair);
    }
  }
  return out;
}
/* Object.assign({}, ...): later sources win. */
static Value cl_merge(Value* ms, long count){
  Value out=cl_map_new();
  for(long i=0;i<count;i++){
    if(ms[i].t!=T_MAP) continue;
    Map* m=(Map*)ms[i].o;
    for(long j=0;j<m->len;j++) cl_map_put(out, m->keys[j], m->vals[j]);
  }
  return out;
}
/* print(...) is show(...) with the arguments joined by a space, which is what
   the interpreter does for both. */
static Value cl_print(Value* vs, long n){
  char* out=(char*)cl_alloc(1); out[0]=0;
  for(long i=0;i<n;i++){ if(i) out=cl_cat(out, " "); out=cl_cat(out, cl_display(vs[i])); }
  printf("%s\n", out);
  return cl_null();
}

/* ── app stdlib: string ops ── (arena-allocated results) */
static Value cl_upper(Value v){ const char* s=v.s; size_t n=strlen(s); char* o=(char*)cl_alloc(n+1); for(size_t i=0;i<n;i++) o[i]=(char)toupper((unsigned char)s[i]); o[n]=0; return cl_str(o); }
static Value cl_lower(Value v){ const char* s=v.s; size_t n=strlen(s); char* o=(char*)cl_alloc(n+1); for(size_t i=0;i<n;i++) o[i]=(char)tolower((unsigned char)s[i]); o[n]=0; return cl_str(o); }
static Value cl_trim(Value v){ const char* s=v.s; while(*s && isspace((unsigned char)*s)) s++; size_t n=strlen(s); while(n>0 && isspace((unsigned char)s[n-1])) n--; char* o=(char*)cl_alloc(n+1); memcpy(o, s, n); o[n]=0; return cl_str(o); }
static Value cl_str_split(Value v, Value sepv){
  const char* s=v.s; const char* sep=sepv.s; size_t sl=strlen(sep); Value out=cl_list_new();
  if(sl==0){ size_t n=strlen(s); for(size_t i=0;i<n;i++){ char* c=(char*)cl_alloc(2); c[0]=s[i]; c[1]=0; cl_list_add(out, cl_str(c)); } return out; }
  const char* p=s; const char* q;
  while((q=strstr(p, sep))){ size_t len=(size_t)(q-p); char* seg=(char*)cl_alloc(len+1); memcpy(seg, p, len); seg[len]=0; cl_list_add(out, cl_str(seg)); p=q+sl; }
  cl_list_add(out, cl_str(cl_strdup(p))); return out;
}
static Value cl_str_join(Value lv, Value sepv){
  List* l=(List*)lv.o; const char* sep=sepv.s; char* out=(char*)cl_alloc(1); out[0]=0;
  for(long j=0;j<l->len;j++){ if(j) out=cl_cat(out, sep); out=cl_cat(out, cl_display(l->items[j])); }
  return cl_str(out);
}
static Value cl_replace(Value sv, Value ov, Value nv){
  const char* s=sv.s; const char* o=ov.s; const char* n=nv.s; size_t ol=strlen(o);
  if(ol==0) return sv;
  char* out=(char*)cl_alloc(1); out[0]=0; const char* p=s; const char* q;
  while((q=strstr(p, o))){ size_t len=(size_t)(q-p); char* seg=(char*)cl_alloc(len+1); memcpy(seg, p, len); seg[len]=0; out=cl_cat(out, seg); out=cl_cat(out, n); p=q+ol; }
  out=cl_cat(out, p); return cl_str(out);
}
static Value cl_starts(Value sv, Value pv){ const char* s=sv.s; const char* p=pv.s; return cl_bool(strncmp(s, p, strlen(p))==0); }
static Value cl_ends(Value sv, Value pv){ const char* s=sv.s; const char* p=pv.s; size_t sl=strlen(s), pl=strlen(p); return cl_bool(pl<=sl && strcmp(s+sl-pl, p)==0); }
/* JS String.prototype.substring semantics (matches the interpreter): clamp to
   [0,len], swap if start>end. */
static Value cl_substr(Value sv, long i, long j){ const char* s=sv.s; long n=(long)strlen(s); if(i<0) i=0; if(j<0) j=0; if(i>n) i=n; if(j>n) j=n; if(i>j){ long t=i; i=j; j=t; } long len=j-i; char* o=(char*)cl_alloc(len+1); memcpy(o, s+i, (size_t)len); o[len]=0; return cl_str(o); }
static Value cl_char_at(Value sv, long i){ const char* s=sv.s; long n=(long)strlen(s); if(i<0) i+=n; if(i<0||i>=n) return cl_str(""); char* o=(char*)cl_alloc(2); o[0]=s[i]; o[1]=0; return cl_str(o); }
static Value cl_char_code(Value sv){ const char* s=sv.s; return cl_int(s[0] ? (unsigned char)s[0] : 0); }
static Value cl_from_char_code(Value n){ char* o=(char*)cl_alloc(2); o[0]=(char)n.i; o[1]=0; return cl_str(o); }
static Value cl_index_of(Value sv, Value subv){ const char* s=sv.s; const char* q=strstr(s, subv.s); return cl_int(q ? (long)(q-s) : -1); }
static Value cl_pad_left(Value sv, long w){ const char* s=sv.s; long n=(long)strlen(s); if(n>=w) return sv; char* o=(char*)cl_alloc(w+1); long pad=w-n; for(long i=0;i<pad;i++) o[i]=' '; memcpy(o+pad, s, (size_t)n); o[w]=0; return cl_str(o); }
static Value cl_pad_right(Value sv, long w){ const char* s=sv.s; long n=(long)strlen(s); if(n>=w) return sv; char* o=(char*)cl_alloc(w+1); memcpy(o, s, (size_t)n); for(long i=n;i<w;i++) o[i]=' '; o[w]=0; return cl_str(o); }
static Value cl_chars(Value sv){ const char* s=sv.s; size_t n=strlen(s); Value out=cl_list_new(); for(size_t i=0;i<n;i++){ char* c=(char*)cl_alloc(2); c[0]=s[i]; c[1]=0; cl_list_add(out, cl_str(c)); } return out; }
static Value cl_str_repeat(Value sv, long k){ const char* s=sv.s; size_t n=strlen(s); char* o=(char*)cl_alloc(n*(k>0?k:0)+1); o[0]=0; for(long i=0;i<k;i++) memcpy(o+i*n, s, n); o[n*(k>0?k:0)]=0; return cl_str(o); }
static Value cl_is_digit(Value v){ const char* s=v.s; if(!s[0]) return cl_bool(0); for(size_t i=0;s[i];i++) if(!isdigit((unsigned char)s[i])) return cl_bool(0); return cl_bool(1); }
static Value cl_is_alpha(Value v){ const char* s=v.s; if(!s[0]) return cl_bool(0); for(size_t i=0;s[i];i++) if(!isalpha((unsigned char)s[i])) return cl_bool(0); return cl_bool(1); }
static Value cl_is_alnum(Value v){ const char* s=v.s; if(!s[0]) return cl_bool(0); for(size_t i=0;s[i];i++) if(!isalnum((unsigned char)s[i])) return cl_bool(0); return cl_bool(1); }
static Value cl_is_space(Value v){ const char* s=v.s; if(!s[0]) return cl_bool(0); for(size_t i=0;s[i];i++) if(!isspace((unsigned char)s[i])) return cl_bool(0); return cl_bool(1); }

/* ── app stdlib: string/number conversion ── */
static Value cl_conv_int(Value v){ if(v.t==T_STR) return cl_int(strtol(v.s, 0, 10)); if(v.t==T_FLOAT) return cl_int((long)v.f); if(v.t==T_BOOL) return cl_int(v.i); return cl_int(v.i); }
static Value cl_conv_float(Value v){ if(v.t==T_STR) return cl_float(strtod(v.s, 0)); return cl_float(cl_num(v)); }

#ifndef CLARITY_FREESTANDING
/* Excluded by the freestanding profile — file I/O: fopen/fread/fwrite/access. A freestanding target has no
   filesystem to open. */
/* ── app stdlib: file I/O ── */
static Value cl_read_file(Value pv){
  FILE* f=fopen(pv.s, "rb"); if(!f) return cl_null();
  /* Read in a growing loop rather than trusting ftell: virtual files under
     /proc (and pipes/FIFOs) report size 0, so a size-then-read would come back
     empty. This reads to real EOF, so read()/lines() work on /proc/<pid>/maps. */
  size_t cap=4096, len=0; char* buf=(char*)cl_alloc(cap); size_t n;
  while((n=fread(buf+len, 1, cap-len, f))>0){
    len+=n;
    if(len==cap){ size_t ncap=cap*2; char* nb=(char*)cl_alloc(ncap); memcpy(nb, buf, len); buf=nb; cap=ncap; }
  }
  fclose(f); buf[len]=0; return cl_str(buf);
}
static Value cl_write_file(Value pv, Value cv){ FILE* f=fopen(pv.s, "wb"); if(!f) return cl_bool(0); char* s=cl_to_cstr(cv); fwrite(s, 1, strlen(s), f); fclose(f); return cl_bool(1); }
static Value cl_append_file(Value pv, Value cv){ FILE* f=fopen(pv.s, "ab"); if(!f) return cl_bool(0); char* s=cl_to_cstr(cv); fwrite(s, 1, strlen(s), f); fclose(f); return cl_bool(1); }
static Value cl_exists(Value pv){ return cl_bool(access(pv.s, F_OK)==0); }
static Value cl_lines(Value pv){ Value c=cl_read_file(pv); if(c.t==T_NULL) return cl_list_new(); Value nl=cl_str("\n"); return cl_str_split(c, nl); }
/* read_bytes(path): raw file bytes as a list of ints (0..255), matching the
   interpreter's Array.from(readFileSync) for the common (file-exists) case. A
   missing file returns an empty list here rather than aborting — the native
   binary has no exception model to mirror the interpreter's ENOENT throw, and
   graceful [] is the friendlier behaviour for a compiled tool. */
static Value cl_read_bytes(Value pv){
  FILE* f=fopen(pv.s, "rb"); Value out=cl_list_new(); if(!f) return out;
  unsigned char buf[4096]; size_t n;
  while((n=fread(buf, 1, sizeof(buf), f))>0){ for(size_t i=0;i<n;i++) cl_list_add(out, cl_int((long)buf[i])); }
  fclose(f); return out;
}
/* write_bytes(path, list): each list element is coerced to a byte (& 0xFF).
   Returns true on success (matches the interpreter). */
static Value cl_write_bytes(Value pv, Value lv){
  FILE* f=fopen(pv.s, "wb"); if(!f) return cl_bool(0);
  if(lv.t==T_LIST){ List* l=(List*)lv.o; for(long j=0;j<l->len;j++){ unsigned char c=(unsigned char)(l->items[j].i & 0xFF); fwrite(&c, 1, 1, f); } }
  fclose(f); return cl_bool(1);
}
#endif /* !CLARITY_FREESTANDING */
/* type(v): the same names the interpreter reports, including the class name
   for an instance — code that branches on type() has to agree across the two
   backends or the same program means different things compiled. */
static Value cl_type_of(Value v){
  if(v.t==T_NULL) return cl_str("null");
  if(v.t==T_BOOL) return cl_str("bool");
  if(v.t==T_INT) return cl_str("int");
  if(v.t==T_FLOAT) return cl_str("float");
  if(v.t==T_STR) return cl_str("string");
  if(v.t==T_LIST) return cl_str("list");
  if(v.t==T_MAP) return cl_str("map");
  if(v.t==T_CLOSURE) return cl_str("function");
  if(v.t==T_OBJECT) return cl_str(((Obj*)v.o)->cls);
  return cl_str("null");
}

#ifndef CLARITY_FREESTANDING
/* Excluded by the freestanding profile — TCP sockets, and the /proc-backed memory access below them: both are
   the operating system, not the C language. */
/* ── TCP sockets ──
   Blocking IPv4 TCP, thin enough to read in one sitting and enough to build an
   HTTP client and server on top of. Every call reports failure as -1 (or an
   empty list) rather than aborting, the same way the file builtins behave in a
   compiled tool: a native binary that dies on a refused connection is much
   less useful than one that can say so.

   Received data is a list of ints 0..255, not a string. A Value string is a
   NUL-terminated char*, so a response carrying a zero byte — any binary body,
   any TLS record — would be silently truncated. Sending accepts either, since
   a request is usually built as text. */
/* Writing to a socket the peer has closed raises SIGPIPE, whose default
   action is to kill the process — the exact "dies instead of reporting it"
   behaviour the rest of this API avoids. Ignoring it makes send() return
   EPIPE instead, which the caller sees as -1. Done once, lazily, so a program
   that never opens a socket is unaffected. */
static void cl_sock_init(void){
  static int done = 0;
  if(!done){ signal(SIGPIPE, SIG_IGN); done = 1; }
}

static Value cl_tcp_listen(Value portv){
  cl_sock_init();
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if(fd < 0) return cl_int(-1);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in a;
  memset(&a, 0, sizeof(a));
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  a.sin_port = htons((unsigned short)portv.i);
  if(bind(fd, (struct sockaddr*)&a, sizeof(a)) < 0){ close(fd); return cl_int(-1); }
  if(listen(fd, 16) < 0){ close(fd); return cl_int(-1); }
  return cl_int(fd);
}

/* The port a listening socket actually got. Passing 0 to tcp_listen asks the
   kernel to pick a free one, which is how a test binds without racing whatever
   else is on the machine. */
static Value cl_tcp_port(Value fdv){
  struct sockaddr_in a;
  socklen_t len = sizeof(a);
  if(getsockname((int)fdv.i, (struct sockaddr*)&a, &len) < 0) return cl_int(-1);
  return cl_int((long)ntohs(a.sin_port));
}

static Value cl_tcp_accept(Value fdv){
  int c = accept((int)fdv.i, 0, 0);
  return cl_int(c < 0 ? -1 : c);
}

static Value cl_tcp_connect(Value hostv, Value portv){
  cl_sock_init();
  char port[16];
  snprintf(port, sizeof(port), "%ld", portv.i);
  struct addrinfo hints, *res = 0;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  if(getaddrinfo(hostv.s, port, &hints, &res) != 0 || !res) return cl_int(-1);
  int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if(fd < 0){ freeaddrinfo(res); return cl_int(-1); }
  if(connect(fd, res->ai_addr, res->ai_addrlen) < 0){ close(fd); freeaddrinfo(res); return cl_int(-1); }
  freeaddrinfo(res);
  return cl_int(fd);
}

/* Send a string or a list of byte values. Loops until the whole buffer is
   gone: a single send() is free to accept only part of it, and treating a
   short write as success is the classic way to lose the tail of a request. */
static Value cl_tcp_send(Value fdv, Value data){
  const unsigned char* buf = 0;
  unsigned char* tmp = 0;
  size_t n = 0;
  if(data.t == T_STR){ buf = (const unsigned char*)data.s; n = strlen(data.s); }
  else if(data.t == T_LIST){
    List* l = (List*)data.o;
    n = (size_t)l->len;
    tmp = (unsigned char*)cl_alloc(n ? n : 1);
    for(long j=0;j<l->len;j++) tmp[j] = (unsigned char)(l->items[j].i & 0xFF);
    buf = tmp;
  } else return cl_int(-1);
  size_t sent = 0;
  while(sent < n){
    ssize_t k = send((int)fdv.i, buf + sent, n - sent, 0);
    if(k <= 0){ if(errno == EINTR) continue; return cl_int(sent ? (long)sent : -1); }
    sent += (size_t)k;
  }
  return cl_int((long)sent);
}

/* Up to `max` bytes, as they arrive — one recv, not a fill loop, because the
   caller is the only one who knows where a message ends. An empty list means
   the peer closed or the read failed. */
static Value cl_tcp_recv(Value fdv, Value maxv){
  Value out = cl_list_new();
  long max = maxv.i;
  if(max <= 0) return out;
  unsigned char* buf = (unsigned char*)cl_alloc((size_t)max);
  ssize_t k;
  do { k = recv((int)fdv.i, buf, (size_t)max, 0); } while(k < 0 && errno == EINTR);
  if(k <= 0) return out;
  for(ssize_t i=0;i<k;i++) cl_list_add(out, cl_int((long)buf[i]));
  return out;
}

static Value cl_tcp_close(Value fdv){
  if(fdv.i >= 0) close((int)fdv.i);
  return cl_null();
}

/* read_mem(pid, addr, len): read `len` bytes of another process's virtual
   memory at address `addr`, as a list of ints 0..255 (like read_bytes). pid<=0
   means this process (/proc/self/mem). Linux only — on macOS/anywhere without
   /proc, or on an unreadable region / permission failure, it returns the bytes
   it managed to read (empty on total failure) rather than aborting: the same
   friendly behaviour read_bytes gives a compiled tool. Addresses come in as a
   number (int or double); doubles are exact through 2^53, covering the 48-bit
   userspace address space. */
static Value cl_read_mem(Value pidv, Value addrv, Value lenv){
  Value out=cl_list_new();
  long pid=(long)cl_num(pidv);
  unsigned long long addr=(unsigned long long)cl_num(addrv);
  long len=(long)cl_num(lenv); if(len<=0) return out;
  char path[64];
  if(pid>0) snprintf(path, sizeof(path), "/proc/%ld/mem", pid);
  else snprintf(path, sizeof(path), "/proc/self/mem");
  int fd=open(path, O_RDONLY); if(fd<0) return out;
  unsigned char* buf=(unsigned char*)cl_alloc((size_t)len);
  ssize_t n=pread(fd, buf, (size_t)len, (off_t)addr);
  close(fd);
  if(n>0){ for(ssize_t i=0;i<n;i++) cl_list_add(out, cl_int((long)buf[i])); }
  return out;
}
/* write_mem(pid, addr, bytes): write a list of bytes (each & 0xFF) into another
   process's memory at `addr` via /proc/<pid>/mem (pid<=0 = self). Returns the
   number of bytes written (0 on any failure — no /proc, unwritable page, no
   ptrace permission). The target page must be writable; writing self needs no
   special privilege, writing another process needs ptrace permission. */
static Value cl_write_mem(Value pidv, Value addrv, Value lv){
  if(lv.t!=T_LIST) return cl_int(0);
  List* l=(List*)lv.o; long n=l->len; if(n<=0) return cl_int(0);
  long pid=(long)cl_num(pidv);
  unsigned long long addr=(unsigned long long)cl_num(addrv);
  unsigned char* buf=(unsigned char*)cl_alloc((size_t)n);
  for(long i=0;i<n;i++) buf[i]=(unsigned char)(((long)cl_num(l->items[i])) & 0xFF);
  char path[64];
  if(pid>0) snprintf(path, sizeof(path), "/proc/%ld/mem", pid);
  else snprintf(path, sizeof(path), "/proc/self/mem");
  int fd=open(path, O_RDWR); if(fd<0) return cl_int(0);
  ssize_t w=pwrite(fd, buf, (size_t)n, (off_t)addr);
  close(fd);
  if(w<0) return cl_int(0);
  return cl_int((long)w);
}
#endif /* !CLARITY_FREESTANDING */

/* ── app stdlib: process/env ── */
static Value cl_env(Value kv, Value dv){ const char* v=getenv(kv.s); if(v) return cl_str(cl_strdup(v)); return dv; }
static Value cl_args(void){ Value out=cl_list_new(); for(int i=1;i<cl_argc;i++) cl_list_add(out, cl_str(cl_argv[i])); return out; }
#ifndef CLARITY_FREESTANDING
/* Excluded by the freestanding profile — process control and the clock: popen/fork/execl/waitpid/nanosleep/
   clock_gettime. */

/* ── app stdlib: exec / process ── */
/* exec(cmd): run via the shell, return stdout with one trailing newline
   stripped (matches the interpreter). */
static Value cl_exec(Value cmdv){
  FILE* p=popen(cmdv.s, "r"); if(!p) return cl_str("");
  char* out=(char*)cl_alloc(1); out[0]=0; char buf[4096]; size_t n;
  while((n=fread(buf, 1, sizeof(buf)-1, p))>0){ buf[n]=0; out=cl_cat(out, buf); }
  pclose(p);
  size_t L=strlen(out); if(L>0 && out[L-1]=='\n') out[L-1]=0;
  return cl_str(out);
}
/* exec_full(cmd): fork + two pipes, capture stdout/stderr separately and the
   exit code, return { stdout, stderr, exit_code }. */
static Value cl_exec_full(Value cmdv){
  int op[2], ep[2]; Value m=cl_map_new();
  if(pipe(op) || pipe(ep)){ cl_map_put(m, "stdout", cl_str("")); cl_map_put(m, "stderr", cl_str("")); cl_map_put(m, "exit_code", cl_int(1)); return m; }
  pid_t pid=fork();
  if(pid==0){ dup2(op[1], 1); dup2(ep[1], 2); close(op[0]); close(op[1]); close(ep[0]); close(ep[1]); execl("/bin/sh", "sh", "-c", cmdv.s, (char*)0); _exit(127); }
  close(op[1]); close(ep[1]);
  char* so=(char*)cl_alloc(1); so[0]=0; char* se=(char*)cl_alloc(1); se[0]=0; char buf[4096]; ssize_t n;
  while((n=read(op[0], buf, sizeof(buf)-1))>0){ buf[n]=0; so=cl_cat(so, buf); }
  while((n=read(ep[0], buf, sizeof(buf)-1))>0){ buf[n]=0; se=cl_cat(se, buf); }
  close(op[0]); close(ep[0]);
  int status=0; waitpid(pid, &status, 0);
  int code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
  cl_map_put(m, "stdout", cl_str(so)); cl_map_put(m, "stderr", cl_str(se)); cl_map_put(m, "exit_code", cl_int(code));
  return m;
}
static Value cl_sleep(Value sv){ double s=cl_num(sv); struct timespec ts; ts.tv_sec=(time_t)s; ts.tv_nsec=(long)((s-(double)ts.tv_sec)*1e9); nanosleep(&ts, 0); return cl_null(); }
static Value cl_time(void){ struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); return cl_float((double)ts.tv_sec + (double)ts.tv_nsec/1e9); }
#endif /* !CLARITY_FREESTANDING */

/* ── app stdlib: math ── */
static Value cl_abs(Value v){ if(v.t==T_FLOAT) return cl_float(fabs(v.f)); return cl_int(v.i<0 ? -v.i : v.i); }
static Value cl_floor(Value v){ return cl_int((long)floor(cl_num(v))); }
static Value cl_ceil(Value v){ return cl_int((long)ceil(cl_num(v))); }
static Value cl_round1(Value v){ return cl_int((long)floor(cl_num(v)+0.5)); }  /* round half up, like Math.round */
static Value cl_round2(Value v, Value d){ double f=pow(10.0, (double)d.i); return cl_float(floor(cl_num(v)*f+0.5)/f); }
static Value cl_sqrt(Value v){ return cl_float(sqrt(cl_num(v))); }
static Value cl_sin(Value v){ return cl_float(sin(cl_num(v))); }
static Value cl_cos(Value v){ return cl_float(cos(cl_num(v))); }
static Value cl_tan(Value v){ return cl_float(tan(cl_num(v))); }
static Value cl_log(Value v){ return cl_float(log(cl_num(v))); }
static Value cl_sum(Value lv){ List* l=(List*)lv.o; int isf=0; for(long j=0;j<l->len;j++) if(l->items[j].t==T_FLOAT) isf=1; if(isf){ double a=0; for(long j=0;j<l->len;j++) a+=cl_num(l->items[j]); return cl_float(a); } long a=0; for(long j=0;j<l->len;j++) a+=l->items[j].i; return cl_int(a); }
static Value cl_min2(Value a, Value b){ return cl_num(a)<=cl_num(b) ? a : b; }
static Value cl_max2(Value a, Value b){ return cl_num(a)>=cl_num(b) ? a : b; }
static Value cl_min_list(Value lv){ List* l=(List*)lv.o; if(l->len==0) return cl_null(); Value m=l->items[0]; for(long j=1;j<l->len;j++) if(cl_num(l->items[j])<cl_num(m)) m=l->items[j]; return m; }
static Value cl_max_list(Value lv){ List* l=(List*)lv.o; if(l->len==0) return cl_null(); Value m=l->items[0]; for(long j=1;j<l->len;j++) if(cl_num(l->items[j])>cl_num(m)) m=l->items[j]; return m; }

/* ── app stdlib: JSON ── */
/* amortized-O(n) string builder over arena memory */
typedef struct { char* buf; size_t len; size_t cap; } SB;
static void sb_init(SB* s){ s->cap=16; s->len=0; s->buf=(char*)cl_alloc(s->cap); s->buf[0]=0; }
static void sb_putc(SB* s, char c){ if(s->len+2>s->cap){ s->cap*=2; char* nb=(char*)cl_alloc(s->cap); memcpy(nb, s->buf, s->len); s->buf=nb; } s->buf[s->len++]=c; s->buf[s->len]=0; }
static void sb_puts(SB* s, const char* t){ while(*t) sb_putc(s, *t++); }

static Value j_value(const char** pp);
static void j_ws(const char** pp){ const char* p=*pp; while(*p==' '||*p=='\t'||*p=='\n'||*p=='\r') p++; *pp=p; }
static Value j_string(const char** pp){
  const char* p=*pp; p++;                          /* opening quote */
  SB s; sb_init(&s);
  while(*p && *p!='"'){
    if(*p=='\\'){
      p++; char c=*p++;
      if(c=='n') sb_putc(&s, '\n'); else if(c=='t') sb_putc(&s, '\t'); else if(c=='r') sb_putc(&s, '\r');
      else if(c=='b') sb_putc(&s, '\b'); else if(c=='f') sb_putc(&s, '\f');
      else if(c=='u'){
        int cp=0; for(int k=0;k<4 && *p;k++){ char h=*p++; cp=cp*16 + (h<='9'?h-'0':(tolower((unsigned char)h)-'a'+10)); }
        if(cp<0x80){ sb_putc(&s, (char)cp); }
        else if(cp<0x800){ sb_putc(&s, (char)(0xC0|(cp>>6))); sb_putc(&s, (char)(0x80|(cp&0x3F))); }
        else { sb_putc(&s, (char)(0xE0|(cp>>12))); sb_putc(&s, (char)(0x80|((cp>>6)&0x3F))); sb_putc(&s, (char)(0x80|(cp&0x3F))); }
      }
      else sb_putc(&s, c);                          /* " \ / and any other */
    } else sb_putc(&s, *p++);
  }
  if(*p=='"') p++;
  *pp=p; return cl_str(s.buf);
}
static Value j_number(const char** pp){
  const char* p=*pp; const char* start=p; int isf=0;
  if(*p=='-') p++;
  while(isdigit((unsigned char)*p)) p++;
  if(*p=='.'){ isf=1; p++; while(isdigit((unsigned char)*p)) p++; }
  if(*p=='e'||*p=='E'){ isf=1; p++; if(*p=='+'||*p=='-') p++; while(isdigit((unsigned char)*p)) p++; }
  char tmp[64]; size_t L=(size_t)(p-start); if(L>63) L=63; memcpy(tmp, start, L); tmp[L]=0;
  *pp=p; return isf ? cl_float(strtod(tmp, 0)) : cl_int(strtol(tmp, 0, 10));
}
static Value j_value(const char** pp){
  j_ws(pp); const char* p=*pp; char c=*p;
  if(c=='"') return j_string(pp);
  if(c=='{'){
    p++; Value m=cl_map_new(); *pp=p; j_ws(pp); p=*pp;
    if(*p=='}'){ *pp=p+1; return m; }
    while(1){
      j_ws(pp); Value k=j_string(pp); j_ws(pp); p=*pp; if(*p==':'){ p++; *pp=p; }
      Value v=j_value(pp); cl_map_put(m, (char*)k.s, v); j_ws(pp); p=*pp;
      if(*p==','){ *pp=p+1; continue; }
      if(*p=='}'){ *pp=p+1; }
      break;
    }
    return m;
  }
  if(c=='['){
    p++; Value a=cl_list_new(); *pp=p; j_ws(pp); p=*pp;
    if(*p==']'){ *pp=p+1; return a; }
    while(1){
      Value v=j_value(pp); cl_list_add(a, v); j_ws(pp); p=*pp;
      if(*p==','){ *pp=p+1; continue; }
      if(*p==']'){ *pp=p+1; }
      break;
    }
    return a;
  }
  if(c=='t'){ *pp=p+4; return cl_bool(1); }
  if(c=='f'){ *pp=p+5; return cl_bool(0); }
  if(c=='n'){ *pp=p+4; return cl_null(); }
  if(c=='-' || isdigit((unsigned char)c)) return j_number(pp);
  return cl_null();
}
static Value cl_json_parse(Value sv){ const char* p=sv.s; return j_value(&p); }

static void j_ser(SB* s, Value v);
static void j_ser_str(SB* s, const char* str){
  sb_putc(s, '"');
  for(const char* p=str; *p; p++){
    char c=*p;
    if(c=='"') sb_puts(s, "\\\"");
    else if(c=='\\') sb_puts(s, "\\\\");
    else if(c=='\n') sb_puts(s, "\\n");
    else if(c=='\t') sb_puts(s, "\\t");
    else if(c=='\r') sb_puts(s, "\\r");
    else sb_putc(s, c);
  }
  sb_putc(s, '"');
}
static void j_ser(SB* s, Value v){
  if(v.t==T_NULL){ sb_puts(s, "null"); return; }
  if(v.t==T_BOOL){ sb_puts(s, v.i ? "true" : "false"); return; }
  if(v.t==T_INT || v.t==T_FLOAT){ sb_puts(s, cl_to_cstr(v)); return; }
  if(v.t==T_STR){ j_ser_str(s, v.s); return; }
  if(v.t==T_LIST){ List* l=(List*)v.o; sb_putc(s, '['); for(long j=0;j<l->len;j++){ if(j) sb_putc(s, ','); j_ser(s, l->items[j]); } sb_putc(s, ']'); return; }
  if(v.t==T_MAP){ Map* m=(Map*)v.o; sb_putc(s, '{'); for(long j=0;j<m->len;j++){ if(j) sb_putc(s, ','); j_ser_str(s, m->keys[j]); sb_putc(s, ':'); j_ser(s, m->vals[j]); } sb_putc(s, '}'); return; }
  sb_puts(s, "null");
}
static Value cl_json_string(Value v){ SB s; sb_init(&s); j_ser(&s, v); return cl_str(s.buf); }

#ifndef CLARITY_FREESTANDING
/* Excluded by the freestanding profile — native FFI: dlopen/dlsym. There is no dynamic loader on a target that
   has no operating system. */
/* ── app stdlib: native FFI (dlopen/dlsym) ── */
/* ffi_open(path): dlopen a shared library so its symbols become resolvable by
   ffi_sym/ffi_call. RTLD_GLOBAL folds them into the global scope that
   RTLD_DEFAULT searches, so after ffi_open("libm.so.6") a plain
   ffi_call("pow", …) works even though the program never referenced libm
   directly (the --as-needed case ffi_sym alone couldn't reach). Returns the
   library handle as an int (0 on failure). */
static Value cl_ffi_open(Value pathv){
  if(pathv.t!=T_STR) return cl_int(0);
  void* h = dlopen(pathv.s, RTLD_NOW | RTLD_GLOBAL);
  return cl_int((long)h);
}
/* Raw native buffers for FFI: pass a pointer to a C function that reads/writes
   through it (an out-param, a struct, a byte region), then marshal the result
   back. Kept off the GC heap (malloc/free) so a library may hold the pointer. */
static Value cl_ffi_buffer(Value nv){ long n=(long)cl_num(nv); if(n<=0) return cl_int(0); void* p=calloc(1,(size_t)n); return cl_int((long)p); }
static Value cl_ffi_read(Value pv, Value nv){ Value out=cl_list_new(); unsigned char* p=(unsigned char*)(long)cl_num(pv); long n=(long)cl_num(nv); if(!p||n<=0) return out; for(long i=0;i<n;i++) cl_list_add(out, cl_int((long)p[i])); return out; }
static Value cl_ffi_write(Value pv, Value lv){ unsigned char* p=(unsigned char*)(long)cl_num(pv); if(!p||lv.t!=T_LIST) return cl_int(0); List* l=(List*)lv.o; for(long i=0;i<l->len;i++) p[i]=(unsigned char)(((long)cl_num(l->items[i]))&0xFF); return cl_int(l->len); }
static Value cl_ffi_free(Value pv){ void* p=(void*)(long)cl_num(pv); if(p) free(p); return cl_null(); }
/* ffi_sym(name): raw address of a symbol in the process (RTLD_DEFAULT covers
   libc/libm and anything linked or dlopen'd), as an int (0 if not found). */
static Value cl_ffi_sym(Value namev){ return cl_int((long)dlsym(RTLD_DEFAULT, namev.s)); }
/* ffi_call(name, sig, args): resolve `name` and call it through a typed shim.
   `sig` is <ret><args>: l=long/int, d=double, s=cstring, v=void. Returns an int
   (l), float (d), fresh string (s return), or null (void / unknown sig).
   RTLD_DEFAULT resolves any symbol in a *loaded* library. libc is always
   loaded, so its symbols (strlen/abs/toupper/…) always resolve; a symbol from a
   library the program never otherwise references (e.g. libm's pow under the
   linker's default --as-needed) won't be loaded — an explicit ffi_open(path)
   for such libraries is a follow-up. Unknown symbol → null. */
static Value cl_ffi_call(Value namev, Value sigv, Value argsv){
  void* fp = dlsym(RTLD_DEFAULT, namev.s);
  if(!fp) return cl_null();
  const char* sig = sigv.s;
  List* l = (argsv.t==T_LIST) ? (List*)argsv.o : (List*)0;
  long n = l ? l->len : 0;
  int has_float = 0; for(const char* c=sig; *c; c++) if(*c=='d') has_float=1;
  /* Generic word-argument path: any mix of l (long/int), p (pointer/address),
     and s (cstring) args. On the SysV-x86-64 and AArch64 integer-register ABIs
     these all pass as machine words in the same registers, and surplus
     prototype args are harmless, so one 6-word prototype calls any such
     function — that's what pointer-heavy C libraries (Capstone, zlib, …) need.
     Return per the sig's first char: l/p -> int (address for p), s -> fresh
     string, v -> null. Float args keep the dedicated prototypes below (they use
     a different register class). Not for variadic callees. */
  if(!has_float){
    long w[6] = {0,0,0,0,0,0};
    char rc = sig[0] ? sig[0] : 'v';
    int ai = 0;
    for(const char* c = sig[0] ? sig+1 : sig; *c && ai < 6; c++, ai++){
      Value it = (ai < n && l) ? l->items[ai] : cl_null();
      if(*c=='s') w[ai] = (long)(it.t==T_STR ? it.s : "");
      else        w[ai] = (long)(long long)cl_num(it);   /* l or p: value/address */
    }
    long ret = ((long(*)(long,long,long,long,long,long))fp)(w[0],w[1],w[2],w[3],w[4],w[5]);
    if(rc=='v') return cl_null();
    if(rc=='s') return ret ? cl_str(cl_strdup((char*)ret)) : cl_null();
    return cl_int(ret);   /* l or p */
  }
  double d0 = n>0 ? cl_num(l->items[0]) : 0.0, d1 = n>1 ? cl_num(l->items[1]) : 0.0;
  if(!strcmp(sig, "d"))    return cl_float(((double(*)(void))fp)());
  if(!strcmp(sig, "dd"))   return cl_float(((double(*)(double))fp)(d0));
  if(!strcmp(sig, "ddd"))  return cl_float(((double(*)(double,double))fp)(d0, d1));
  return cl_null();
}
#endif /* !CLARITY_FREESTANDING */

static void cl_show(Value v){ char* s=cl_display(v); printf("%s\n", s); }


/* module-level bindings */
Value v_t;
Value v_m;
Value v_parts;
Value v_squares;
Value v_big;
static Value* cl_global_roots[] = {&v_t, &v_m, &v_parts, &v_squares, &v_big};

Value f_risky(Value v_x);
Value f_Tally_init(Value v_this, Value* __a, long __n);
Value f_Tally_add(Value v_this, Value* __a, long __n);
Value cl_ctor_Tally(Value* __a, long __n);
Value __closure_0(Value* __a, Value* __cap, long __n);
Value __closure_1(Value* __a, Value* __cap, long __n);

Value __closure_0(Value* __a, Value* __cap, long __n) {
  (void)__a; (void)__n;
  Value v_v = cl_arg(__a, __n, 0);
  return cl_eq(cl_mod(v_v, cl_int(2)), cl_int(0));
  return cl_null();
}

Value __closure_1(Value* __a, Value* __cap, long __n) {
  (void)__a; (void)__n;
  Value v_v = cl_arg(__a, __n, 0);
  return cl_mul(v_v, v_v);
  return cl_null();
}

Value f_risky(Value v_x) {
  if(cl_truthy(cl_lt(v_x, cl_int(0)))) {
    cl_throw(({ volatile Value __o0 = (cl_str("negative: ")); volatile Value __o1 = (cl_str(cl_to_cstr(v_x))); cl_add(__o0, __o1); }));
  }
  return cl_mul(v_x, cl_int(3));
  return cl_null();
}


Value f_Tally_init(Value v_this, Value* __a, long __n) {
  (void)__a; (void)__n;
  cl_set_field(v_this, "n", cl_int(0));
  return cl_null();
}
Value f_Tally_add(Value v_this, Value* __a, long __n) {
  (void)__a; (void)__n;
  Value v_k = cl_arg(__a, __n, 0);
  cl_set_field(v_this, "n", cl_add(cl_get_field(v_this, "n"), v_k));
  return cl_get_field(v_this, "n");
  return cl_null();
}
Value cl_ctor_Tally(Value* __a, long __n) {
  Value self = cl_object_new("Tally");
  f_Tally_init(self, __a, __n);
  return self;
}

int main(int argc, char** argv) {
  cl_argc = argc; cl_argv = argv;
  GC_CAPTURE_STACK_BASE();
  if(getenv("CLARITY_GC")) gc_enabled = 1;
  cl_globals = cl_global_roots; cl_globals_n = 5;
  cl_register("Tally", "init", &f_Tally_init);
  cl_register("Tally", "add", &f_Tally_add);
  v_t = cl_ctor_Tally(0, 0);
  Value __it1 = cl_iter(cl_range2(cl_int(1), cl_int(11)));
  for(long __i1=0; __i1 < cl_length(__it1); __i1++) {
    Value v_i = cl_index(__it1, cl_int(__i1));
    (void)(cl_dispatch(v_t, "add", (Value[]){v_i}, 1));
  }
  cl_show(({ volatile Value __o2 = (cl_str("tally ")); volatile Value __o3 = (cl_str(cl_to_cstr(cl_get_field(v_t, "n")))); cl_add(__o2, __o3); }));
  { ClHandler __h4; __h4.prev = cl_handlers; cl_handlers = &__h4;
    if(setjmp(__h4.buf) == 0) {
      cl_show(cl_str(cl_to_cstr(f_risky(cl_neg(cl_int(4))))));
      cl_handlers = __h4.prev;
    } else {
      cl_handlers = __h4.prev;
      Value v_e = cl_thrown;
      ClHandler __hc4; __hc4.prev = cl_handlers; cl_handlers = &__hc4;
      if(setjmp(__hc4.buf) == 0) {
        cl_show(({ volatile Value __o5 = (cl_str("caught ")); volatile Value __o6 = (cl_str(cl_to_cstr(v_e))); cl_add(__o5, __o6); }));
        cl_handlers = __hc4.prev;
      } else {
        cl_handlers = __hc4.prev;
        Value __hc4_v = cl_thrown;
        cl_show(cl_str("finally ran"));
        cl_throw(__hc4_v);
      }
    }
    cl_show(cl_str("finally ran"));
  }
  v_m = cl_map_put(cl_map_put(cl_map_put(cl_map_new(), cl_to_cstr(cl_str("pear")), cl_int(2)), cl_to_cstr(cl_str("apple")), cl_int(1)), cl_to_cstr(cl_str("fig")), cl_int(3));
  v_parts = cl_list_new();
  Value __it2 = cl_iter(cl_sort(cl_keys(v_m)));
  for(long __i2=0; __i2 < cl_length(__it2); __i2++) {
    Value v_k = cl_index(__it2, cl_int(__i2));
    (void)(({ volatile Value __o7 = (v_parts); volatile Value __o8 = (({ volatile Value __o9 = (({ volatile Value __o10 = (cl_upper(v_k)); volatile Value __o11 = (cl_str("=")); cl_add(__o10, __o11); })); volatile Value __o12 = (cl_str(cl_to_cstr(cl_index(v_m, v_k)))); cl_add(__o9, __o12); })); cl_list_add(__o7, __o8); }));
  }
  cl_show(cl_str_join(v_parts, cl_str(" ")));
  v_squares = ({ volatile Value __o13 = (cl_hof_filter(cl_list_add(cl_list_add(cl_list_add(cl_list_add(cl_list_add(cl_list_add(cl_list_add(cl_list_add(cl_list_new(), cl_int(1)), cl_int(2)), cl_int(3)), cl_int(4)), cl_int(5)), cl_int(6)), cl_int(7)), cl_int(8)), cl_closure_new(&__closure_0, 0, 0))); volatile Value __o14 = (cl_closure_new(&__closure_1, 0, 0)); cl_hof_map(__o13, __o14); });
  cl_show(({ volatile Value __o15 = (cl_str("evens squared ")); volatile Value __o16 = (cl_str_join(v_squares, cl_str(","))); cl_add(__o15, __o16); }));
  cl_show(({ volatile Value __o17 = (({ volatile Value __o18 = (({ volatile Value __o19 = (({ volatile Value __o20 = (({ volatile Value __o21 = (cl_str("float ")); volatile Value __o22 = (cl_str(cl_to_cstr(cl_div(cl_int(355), cl_int(113))))); cl_add(__o21, __o22); })); volatile Value __o23 = (cl_str(" ")); cl_add(__o20, __o23); })); volatile Value __o24 = (cl_str(cl_to_cstr(cl_sqrt(cl_int(2))))); cl_add(__o19, __o24); })); volatile Value __o25 = (cl_str(" ")); cl_add(__o18, __o25); })); volatile Value __o26 = (cl_str(cl_to_cstr(cl_pow(cl_float(2.5), cl_int(2))))); cl_add(__o17, __o26); }));
  cl_show(({ volatile Value __o27 = (({ volatile Value __o28 = (({ volatile Value __o29 = (({ volatile Value __o30 = (({ volatile Value __o31 = (cl_str("text ")); volatile Value __o32 = (cl_trim(cl_str("  spaced  "))); cl_add(__o31, __o32); })); volatile Value __o33 = (cl_str("|")); cl_add(__o30, __o33); })); volatile Value __o34 = (cl_replace(cl_str("a-b-c"), cl_str("-"), cl_str("+"))); cl_add(__o29, __o34); })); volatile Value __o35 = (cl_str("|")); cl_add(__o28, __o35); })); volatile Value __o36 = (cl_str(cl_to_cstr(cl_index_of(cl_str("clarity"), cl_str("rit"))))); cl_add(__o27, __o36); }));
  v_big = cl_list_new();
  Value __it3 = cl_iter(cl_range2(cl_int(1), cl_int(401)));
  for(long __i3=0; __i3 < cl_length(__it3); __i3++) {
    Value v_i = cl_index(__it3, cl_int(__i3));
    (void)(({ volatile Value __o37 = (v_big); volatile Value __o38 = (cl_str(cl_to_cstr(cl_mul(v_i, v_i)))); cl_list_add(__o37, __o38); }));
  }
  cl_show(({ volatile Value __o39 = (({ volatile Value __o40 = (({ volatile Value __o41 = (cl_str("list ")); volatile Value __o42 = (cl_str(cl_to_cstr(cl_int(cl_length(v_big))))); cl_add(__o41, __o42); })); volatile Value __o43 = (cl_str(" last ")); cl_add(__o40, __o43); })); volatile Value __o44 = (cl_index(v_big, cl_int(399))); cl_add(__o39, __o44); }));
  cl_show(cl_str("clarity-demo: all checks passed"));
  cl_arena_free();
  return 0;
}