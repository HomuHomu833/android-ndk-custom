/*
 * futimes.h -- provide futimes() on bionic API levels below 26.
 *
 * bionic only declares futimes() from API 26, but configure detects the symbol
 * in the static libc and enables HAVE_FUTIMES, causing a compilation failure
 * at lower API levels.  Provide a real implementation via futimens(), which is
 * available from API 21 and has identical semantics.
 *
 * Injected after #include "Python.h" by scripts/make-ndk.sh.
 */
#ifndef NDK_BIONIC_FUTIMES_H
#define NDK_BIONIC_FUTIMES_H

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 26) && \
    !defined(__cplusplus)

#include <sys/stat.h>
#include <sys/time.h>

static inline int futimes(int fd, const struct timeval tv[2]) {
    struct timespec ts[2];
    if (tv != NULL) {
        ts[0].tv_sec  = tv[0].tv_sec;
        ts[0].tv_nsec = tv[0].tv_usec * 1000;
        ts[1].tv_sec  = tv[1].tv_sec;
        ts[1].tv_nsec = tv[1].tv_usec * 1000;
        return futimens(fd, ts);
    }
    return futimens(fd, NULL);
}

#endif
#endif /* NDK_BIONIC_FUTIMES_H */
