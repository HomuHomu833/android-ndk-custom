/*
 * getloadavg.h -- provide getloadavg() on bionic.
 *
 * bionic does not implement getloadavg(3) (Android has no load-average
 * concept).  If configure somehow detects the symbol in the static libc
 * stubs and enables HAVE_GETLOADAVG, supply a stub that returns -1/ENOSYS.
 *
 * Injected after #include "Python.h" by scripts/make-ndk.sh.
 */
#ifndef NDK_BIONIC_GETLOADAVG_H
#define NDK_BIONIC_GETLOADAVG_H

#if defined(__ANDROID__) && !defined(__cplusplus)

#include <errno.h>
#include <stdlib.h>

static inline int getloadavg(double loadavg[], int nelem) {
    (void)loadavg;
    (void)nelem;
    errno = ENOSYS;
    return -1;
}

#endif
#endif /* NDK_BIONIC_GETLOADAVG_H */
