/*
 * fexecve.h -- provide fexecve() for bionic when feature-test macros
 * (e.g. _POSIX_C_SOURCE set by CPython) hide the declaration.
 *
 * bionic declares fexecve() from API 21, but under _POSIX_C_SOURCE the
 * declaration may be suppressed (it is a GNU extension, not POSIX base).
 * Implement it via the execveat(2) syscall with AT_EMPTY_PATH, which is
 * available since Linux 3.19 (Android API 21+).
 *
 * Injected after #include "Python.h" by scripts/make-ndk.sh.
 */
#ifndef NDK_BIONIC_FEXECVE_H
#define NDK_BIONIC_FEXECVE_H

#if defined(__ANDROID__) && defined(__ANDROID_API__) && !defined(__cplusplus)

#include <errno.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

#ifndef __NR_execveat
#if defined(__aarch64__)
#define __NR_execveat 358
#elif defined(__ARM_EABI__) || defined(__arm__)
#define __NR_execveat 387
#elif defined(__i386__)
#define __NR_execveat 358
#elif defined(__x86_64__)
#define __NR_execveat 322
#elif defined(__riscv)
#define __NR_execveat 210
#else
#error "unrecognized architecture for __NR_execveat"
#endif
#endif

static inline int fexecve(int fd, char *const argv[], char *const envp[]) {
    int ret = (int)syscall(__NR_execveat, fd, "", argv, envp, AT_EMPTY_PATH);
    if (ret < 0) {
        /* execveat(AT_EMPTY_PATH) on a directory fd or a file opened with
         * O_CLOEXEC / O_PATH returns ENOENT on older kernels.  Fall back to
         * reading the path from /proc/self/fd/<fd>. */
        if (errno == ENOENT) {
            char procpath[64];
            (void)snprintf(procpath, sizeof(procpath), "/proc/self/fd/%d", fd);
            (void)execve(procpath, argv, envp);
        }
        return -1; /* errno set by the syscall or execve */
    }
    /* unreachable on success (execveat does not return) */
    return ret;
}

#endif
#endif /* NDK_BIONIC_FEXECVE_H */
