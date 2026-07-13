/*
 * lutimes.h -- provide lutimes() on bionic API levels below 26.
 *
 * bionic only declares lutimes() from API 26, but configure detects the symbol
 * in the static libc and enables HAVE_LUTIMES.  Provide a real implementation
 * via utimensat() with AT_SYMLINK_NOFOLLOW, available from API 21.
 *
 * Injected after #include "Python.h" by scripts/make-ndk.sh.
 */
#ifndef NDK_BIONIC_LUTIMES_H
#define NDK_BIONIC_LUTIMES_H

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 26) && \
    !defined(__cplusplus)

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>

static inline int lutimes(const char *path, const struct timeval tv[2]) {
    struct timespec ts[2];
    if (tv != NULL) {
        ts[0].tv_sec  = tv[0].tv_sec;
        ts[0].tv_nsec = tv[0].tv_usec * 1000;
        ts[1].tv_sec  = tv[1].tv_sec;
        ts[1].tv_nsec = tv[1].tv_usec * 1000;
        return utimensat(AT_FDCWD, path, ts, AT_SYMLINK_NOFOLLOW);
    }
    return utimensat(AT_FDCWD, path, NULL, AT_SYMLINK_NOFOLLOW);
}

#endif
#endif /* NDK_BIONIC_LUTIMES_H */
