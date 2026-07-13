/*
 * ctermid.h -- provide ctermid() on bionic (which never implemented it).
 *
 * ctermid(3) is a POSIX function that returns the pathname of the controlling
 * terminal for the current process.  On Android /dev/tty is the standard
 * controlling-terminal device, so this implementation returns "/dev/tty".
 *
 * Injected after each caller's #include "Python.h" by scripts/make-ndk.sh.
 * Self-gated to C on bionic (ignore C++ where libc++ might provide its own).
 */
#ifndef NDK_BIONIC_CTERMID_H
#define NDK_BIONIC_CTERMID_H

#if defined(__ANDROID__) && defined(__ANDROID_API__) && !defined(__cplusplus)

#include <string.h>

#ifndef L_ctermid
#define L_ctermid 1024
#endif

static inline char *ctermid(char *buf) {
    static char ndk_ctermid_buf[L_ctermid];
    if (buf == NULL)
        buf = ndk_ctermid_buf;
    (void)memcpy(buf, "/dev/tty", 9);
    return buf;
}

#endif
#endif /* NDK_BIONIC_CTERMID_H */
