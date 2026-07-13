/*
 * libc_compat.h -- aggregate shim for higher-API bionic functions.
 *
 * bionic (Android's libc) only declares/exports certain POSIX/Linux functions
 * from relatively recent API levels (26 for futimes/lutimes, 28 for posix_spawn,
 * 34 for close_range, etc.).  CPython's autoconf-based configure performs link
 * tests that often find those symbols in the static libc regardless of the
 * target API level, which results in HAVE_FOO=1 but no visible prototype.
 *
 * This header pulls in self-gated inline implementations for the missing
 * functions so that compilation succeeds at arbitrary API levels.
 *
 * Included via absolute path after #include "Python.h" by scripts/make-ndk.sh.
 */
#ifndef NDK_BIONIC_LIBC_COMPAT_H
#define NDK_BIONIC_LIBC_COMPAT_H

/* close_range   — syscall-backed, API < 34  (already injected separately) */
/* sem_clockwait — futex-backed,  API < 30  (injected into thread_pthread.h) */

#include "ctermid.h"         /* ctermid,           never in bionic              */
#include "futimes.h"         /* futimes,           API < 26 (via futimens)      */
#include "lutimes.h"         /* lutimes,           API < 26 (via utimensat)     */
#include "fexecve.h"         /* fexecve,           hidden by _POSIX_C_SOURCE    */
#include "posix_spawn.h"     /* posix_spawn/p,     API < 28 (via fork+exec)    */
#include "preadv2.h"         /* preadv2/pwritev2,  API < 24 or hidden by FTM   */
#include "copy_file_range.h" /* copy_file_range,   API < 30 (via syscall)      */
#include "getloadavg.h"      /* getloadavg,        never in bionic              */

#endif /* NDK_BIONIC_LIBC_COMPAT_H */
