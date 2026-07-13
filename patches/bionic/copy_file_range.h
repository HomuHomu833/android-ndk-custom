/*
 * copy_file_range.h -- provide copy_file_range() on older bionic API levels.
 *
 * bionic exports copy_file_range only from API 30, but configure detects the
 * symbol in the static libc and enables HAVE_COPY_FILE_RANGE at lower API
 * levels.  Provide a real implementation via the copy_file_range(2) Linux
 * syscall (Linux 4.5+, which covers every Android kernel for API 21+).
 *
 * Injected after #include "Python.h" by scripts/make-ndk.sh.
 */
#ifndef NDK_BIONIC_COPY_FILE_RANGE_H
#define NDK_BIONIC_COPY_FILE_RANGE_H

#if defined(__ANDROID__) && !defined(__cplusplus)

#include <errno.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef __NR_copy_file_range
#if defined(__aarch64__)
#define __NR_copy_file_range 285
#elif defined(__ARM_EABI__) || defined(__arm__)
#define __NR_copy_file_range 391
#elif defined(__i386__)
#define __NR_copy_file_range 377
#elif defined(__x86_64__)
#define __NR_copy_file_range 326
#elif defined(__riscv)
#define __NR_copy_file_range 210
#else
#error "unrecognized architecture for __NR_copy_file_range"
#endif
#endif

static inline ssize_t copy_file_range(int fd_in, off64_t *off_in,
                                       int fd_out, off64_t *off_out,
                                       size_t len, unsigned int flags) {
    return (ssize_t)syscall(__NR_copy_file_range, fd_in, off_in,
                            fd_out, off_out, len, flags);
}

#endif
#endif /* NDK_BIONIC_COPY_FILE_RANGE_H */
