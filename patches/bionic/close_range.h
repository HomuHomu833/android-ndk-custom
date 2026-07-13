/*
 * close_range.h — provide close_range() on bionic API levels below 34.
 *
 * bionic only declares/exports close_range() from API 34, but CPython's configure
 * enables HAVE_CLOSE_RANGE (the NDK libc stub exports the symbol regardless of
 * API; only the header is API-gated), so callers such as Python/fileutils.c and
 * Modules/_posixsubprocess.c fail to compile below 34 with "call to undeclared
 * function 'close_range'". This is a real implementation, not a fallback: the
 * close_range(2) syscall (Linux 5.9+), which is what bionic 34+ wraps and is
 * strictly better than CPython's close()-loop path. On a pre-5.9 device kernel
 * the syscall returns -1/ENOSYS and CPython's callers fall back on their own.
 *
 * Injected after each caller's #include "Python.h" by scripts/make-ndk.sh, so it
 * lands after Python.h has set its feature macros. Self-gated to C on bionic<34.
 */
#ifndef NDK_BIONIC_CLOSE_RANGE_H
#define NDK_BIONIC_CLOSE_RANGE_H

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 34) && \
    !defined(__cplusplus)

#include <sys/syscall.h>
#include <unistd.h>

#ifndef __NR_close_range
#define __NR_close_range 436 /* Linux 5.9+, arch-independent */
#endif

static inline int close_range(unsigned int first, unsigned int last, int flags) {
	return (int)syscall(__NR_close_range, first, last, flags);
}

#endif
#endif /* NDK_BIONIC_CLOSE_RANGE_H */
