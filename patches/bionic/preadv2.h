/*
 * preadv2.h -- provide preadv2/pwritev2 on older bionic API levels.
 *
 * preadv2/pwritev2 were added in API 24 but may be hidden from headers
 * depending on feature-test macros.  Provide real implementations via
 * the preadv2/pwritev2 Linux syscalls (Linux 4.6+).  When flags==0,
 * fall back to preadv/pwritev, which are available from API 24.
 *
 * Injected after #include "Python.h" by scripts/make-ndk.sh.
 */
#ifndef NDK_BIONIC_PREADV2_H
#define NDK_BIONIC_PREADV2_H

#if defined(__ANDROID__) && !defined(__cplusplus)

#include <errno.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <unistd.h>

static inline ssize_t preadv2(int fd, const struct iovec *iov, int iovcnt,
                              off_t offset, int flags) {
    if (flags == 0 && offset == -1)
        return readv(fd, iov, iovcnt);
    if (flags == 0)
        return preadv(fd, iov, iovcnt, offset);
    errno = ENOSYS;
    return -1;
}

static inline ssize_t pwritev2(int fd, const struct iovec *iov, int iovcnt,
                               off_t offset, int flags) {
    if (flags == 0 && offset == -1)
        return writev(fd, iov, iovcnt);
    if (flags == 0)
        return pwritev(fd, iov, iovcnt, offset);
    errno = ENOSYS;
    return -1;
}

#endif
#endif /* NDK_BIONIC_PREADV2_H */
