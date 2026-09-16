/* The three kernel calls this C library is built on.
 *
 * A C library is mostly pure code — string handling, formatting, arithmetic —
 * sitting on a very small number of things only the kernel can do. For a
 * Clarity program under the freestanding profile there are exactly three:
 * write bytes to the console, move the program break, and stop.
 *
 * The numbers differ between KyanOS and Linux, so they live here and
 * nowhere else. The Linux set exists so the same library can be built and run
 * on a Linux host, which is what the test does: the code under test is then
 * the code that ships, not a stand-in for it.
 */
#ifndef _CLARITY_SYS_H
#define _CLARITY_SYS_H
#include <stddef.h>

#ifdef CLARITY_LIBC_LINUX
#define CL_SYS_WRITE 1
#define CL_SYS_BRK   12
#define CL_SYS_EXIT  60
#else
/* Must match kernel/syscall/dispatch.zig's Nr. */
#define CL_SYS_WRITE 1
#define CL_SYS_BRK   9
#define CL_SYS_EXIT  12
#endif

long  cl_sys_write(int fd, const void* buf, unsigned long len);
void* cl_sys_brk(void* addr);
void  cl_sys_exit(int code) __attribute__((noreturn));

#endif
