/*
 * posix_spawn.h -- provide posix_spawn / posix_spawnp on bionic API < 28.
 *
 * bionic only exports posix_spawn and friends from API 28, but CPython's
 * configure detects the symbols in the static libc and enables HAVE_POSIX_SPAWN
 * at lower API levels, causing "call to undeclared function" errors.
 *
 * This is a proper implementation via fork(2) + execve(2) in the child process,
 * with full support for file actions and spawn attributes.  The child applies
 * all requested settings before exec; if exec fails it calls _exit(127).
 *
 * The posix_spawnattr_t and posix_spawn_file_actions_t types are defined by
 * the NDK's <spawn.h> (API 24+) as opaque pointers.  We include that header
 * (it exists at every API >= 24) and define the underlying struct bodies.
 *
 * Injected after #include "Python.h" by scripts/make-ndk.sh.
 */
#ifndef NDK_BIONIC_POSIX_SPAWN_H
#define NDK_BIONIC_POSIX_SPAWN_H

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 28) && \
    !defined(__cplusplus)

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/*  Types (opaque pointers, matching the NDK's <spawn.h>)              */
/* ------------------------------------------------------------------ */

#ifndef POSIX_SPAWN_RESETIDS
#define POSIX_SPAWN_RESETIDS      0x0001
#define POSIX_SPAWN_SETPGROUP     0x0002
#define POSIX_SPAWN_SETSIGDEF     0x0004
#define POSIX_SPAWN_SETSIGMASK    0x0008
#define POSIX_SPAWN_SETSCHEDPARAM 0x0010
#define POSIX_SPAWN_SETSCHEDULER  0x0020
#endif

/*
 * Include the NDK's <spawn.h> for its opaque-pointer typedefs:
 *   typedef struct __posix_spawnattr*           posix_spawnattr_t;
 *   typedef struct __posix_spawn_file_actions*  posix_spawn_file_actions_t;
 * Then define the struct bodies ourselves.
 */
#if __has_include(<spawn.h>)
#include <spawn.h>
#else
/* Should not happen at API >= 24, but keep a fallback. */
typedef struct __posix_spawnattr           *posix_spawnattr_t;
typedef struct __posix_spawn_file_actions  *posix_spawn_file_actions_t;
#endif

/* Underlying struct for posix_spawnattr_t. */
struct __posix_spawnattr {
    short       flags;
    pid_t       pgroup;
    sigset_t    sigmask;
    sigset_t    sigdefault;
    struct sched_param schedparam;
    int         schedpolicy;
};

/* File-actions linked-list node. */
typedef struct __ndk_fa_node {
    int                     type;   /* 0 = open, 1 = close, 2 = dup2 */
    int                     fd;
    int                     src_fd; /* for dup2: src fd to dup from   */
    int                     oflag;
    mode_t                  mode;
    char                   *path;   /* for open (heap-allocated)      */
    struct __ndk_fa_node   *next;
} __ndk_fa_node;

/* Underlying struct for posix_spawn_file_actions_t. */
struct __posix_spawn_file_actions {
    __ndk_fa_node *head;
    __ndk_fa_node *tail;
};

/* ------------------------------------------------------------------ */
/*  posix_spawnattr                                                   */
/* ------------------------------------------------------------------ */

/* posix_spawnattr_t is an opaque pointer (struct __posix_spawnattr *).
 * These functions receive posix_spawnattr_t *, so *attr is the handle. */

static inline int posix_spawnattr_init(posix_spawnattr_t *attr) {
    if (attr == NULL) { errno = EINVAL; return -1; }
    *attr = (struct __posix_spawnattr *)calloc(1, sizeof(struct __posix_spawnattr));
    if (*attr == NULL) { errno = ENOMEM; return -1; }
    (*attr)->schedpolicy = SCHED_OTHER;
    return 0;
}

static inline int posix_spawnattr_destroy(posix_spawnattr_t *attr) {
    if (attr != NULL && *attr != NULL) {
        free(*attr);
        *attr = NULL;
    }
    return 0;
}

static inline int posix_spawnattr_setflags(posix_spawnattr_t *attr, short flags) {
    if (attr == NULL || *attr == NULL) { errno = EINVAL; return -1; }
    (*attr)->flags = flags;
    return 0;
}

static inline int posix_spawnattr_setpgroup(posix_spawnattr_t *attr, pid_t pgroup) {
    if (attr == NULL || *attr == NULL) { errno = EINVAL; return -1; }
    (*attr)->pgroup = pgroup;
    return 0;
}

static inline int posix_spawnattr_setsigmask(posix_spawnattr_t *attr,
                                             const sigset_t *sigmask) {
    if (attr == NULL || *attr == NULL || sigmask == NULL) { errno = EINVAL; return -1; }
    (*attr)->sigmask = *sigmask;
    return 0;
}

static inline int posix_spawnattr_setsigdefault(posix_spawnattr_t *attr,
                                                const sigset_t *sigdefault) {
    if (attr == NULL || *attr == NULL || sigdefault == NULL) { errno = EINVAL; return -1; }
    (*attr)->sigdefault = *sigdefault;
    return 0;
}

static inline int posix_spawnattr_setschedparam(posix_spawnattr_t *attr,
                                                const struct sched_param *schedparam) {
    if (attr == NULL || *attr == NULL || schedparam == NULL) { errno = EINVAL; return -1; }
    (*attr)->schedparam = *schedparam;
    return 0;
}

static inline int posix_spawnattr_setschedpolicy(posix_spawnattr_t *attr, int policy) {
    if (attr == NULL || *attr == NULL) { errno = EINVAL; return -1; }
    (*attr)->schedpolicy = policy;
    return 0;
}

/* ------------------------------------------------------------------ */
/*  internal helpers                                                    */
/* ------------------------------------------------------------------ */

/* Local strdup to avoid dependency on feature-test macros. */
static inline char *__ndk_strdup(const char *s) {
    size_t len = strlen(s) + 1;
    char *copy = (char *)malloc(len);
    if (copy != NULL)
        (void)memcpy(copy, s, len);
    return copy;
}

/* ------------------------------------------------------------------ */
/*  posix_spawn_file_actions                                           */
/* ------------------------------------------------------------------ */

/* posix_spawn_file_actions_t is an opaque pointer too. */

static inline int posix_spawn_file_actions_init(posix_spawn_file_actions_t *fa) {
    if (fa == NULL) { errno = EINVAL; return -1; }
    *fa = (struct __posix_spawn_file_actions *)calloc(1, sizeof(struct __posix_spawn_file_actions));
    if (*fa == NULL) { errno = ENOMEM; return -1; }
    return 0;
}

static inline int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *fa) {
    if (fa == NULL || *fa == NULL) { errno = EINVAL; return -1; }
    __ndk_fa_node *cur = (*fa)->head;
    while (cur != NULL) {
        __ndk_fa_node *next = cur->next;
        free(cur->path);
        free(cur);
        cur = next;
    }
    free(*fa);
    *fa = NULL;
    return 0;
}

static inline int posix_spawn_file_actions_addopen(
    posix_spawn_file_actions_t *fa, int fd, const char *path,
    int oflag, mode_t mode) {
    if (fa == NULL || *fa == NULL || path == NULL || fd < 0) { errno = EINVAL; return -1; }
    __ndk_fa_node *node = (__ndk_fa_node *)malloc(sizeof(__ndk_fa_node));
    if (node == NULL) return -1;
    node->path = __ndk_strdup(path);
    if (node->path == NULL) { free(node); return -1; }
    node->type  = 0;
    node->fd    = fd;
    node->oflag = oflag;
    node->mode  = mode;
    node->src_fd = -1;
    node->next  = NULL;
    if ((*fa)->tail == NULL) {
        (*fa)->head = (*fa)->tail = node;
    } else {
        (*fa)->tail->next = node;
        (*fa)->tail = node;
    }
    return 0;
}

static inline int posix_spawn_file_actions_addclose(
    posix_spawn_file_actions_t *fa, int fd) {
    if (fa == NULL || *fa == NULL || fd < 0) { errno = EINVAL; return -1; }
    __ndk_fa_node *node = (__ndk_fa_node *)malloc(sizeof(__ndk_fa_node));
    if (node == NULL) return -1;
    node->type  = 1;
    node->fd    = fd;
    node->path  = NULL;
    node->src_fd = -1;
    node->next  = NULL;
    if ((*fa)->tail == NULL) {
        (*fa)->head = (*fa)->tail = node;
    } else {
        (*fa)->tail->next = node;
        (*fa)->tail = node;
    }
    return 0;
}

static inline int posix_spawn_file_actions_adddup2(
    posix_spawn_file_actions_t *fa, int fd, int newfd) {
    if (fa == NULL || *fa == NULL || fd < 0 || newfd < 0) { errno = EINVAL; return -1; }
    __ndk_fa_node *node = (__ndk_fa_node *)malloc(sizeof(__ndk_fa_node));
    if (node == NULL) return -1;
    node->type   = 2;
    node->fd     = newfd;  /* destination */
    node->src_fd = fd;     /* source      */
    node->path   = NULL;
    node->next   = NULL;
    if ((*fa)->tail == NULL) {
        (*fa)->head = (*fa)->tail = node;
    } else {
        (*fa)->tail->next = node;
        (*fa)->tail = node;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  child helper: apply file_actions + attrs, then execve              */
/* ------------------------------------------------------------------ */

static inline void __ndk_spawn_child(const char *path,
    const posix_spawn_file_actions_t *fa,
    const posix_spawnattr_t *attrp,
    char *const argv[], char *const envp[]) {

    /* 1. Apply file actions. */
    if (fa != NULL && *fa != NULL) {
        for (const __ndk_fa_node *n = (*fa)->head; n != NULL; n = n->next) {
            switch (n->type) {
            case 0: { /* open */
                int f = open(n->path, n->oflag, n->mode);
                if (f < 0) _exit(127);
                if (f != n->fd) {
                    dup2(f, n->fd);
                    close(f);
                }
                break;
            }
            case 1: /* close */
                close(n->fd);
                break;
            case 2: /* dup2 */
                if (dup2(n->src_fd, n->fd) < 0) _exit(127);
                break;
            }
        }
    }

    /* 2. Apply attributes. */
    if (attrp != NULL && *attrp != NULL) {
        if ((*attrp)->flags & POSIX_SPAWN_RESETIDS) {
            /* Best-effort: bionic may ignore these (no-op on typical
             * Android kernels), but try for correctness. */
            (void)setegid(getgid());
            (void)seteuid(getuid());
        }
        if ((*attrp)->flags & POSIX_SPAWN_SETPGROUP)
            (void)setpgid(0, (*attrp)->pgroup);
        if ((*attrp)->flags & POSIX_SPAWN_SETSIGMASK)
            pthread_sigmask(SIG_SETMASK, &(*attrp)->sigmask, NULL);
        if ((*attrp)->flags & POSIX_SPAWN_SETSIGDEF) {
            struct sigaction sa;
            memset(&sa, 0, sizeof(sa));
            sa.sa_handler = SIG_DFL;
            for (int sig = 1; sig < NSIG; sig++) {
                if (sigismember(&(*attrp)->sigdefault, sig))
                    (void)sigaction(sig, &sa, NULL);
            }
        }
        if ((*attrp)->flags & POSIX_SPAWN_SETSCHEDPARAM)
            (void)sched_setparam(0, &(*attrp)->schedparam);
        if ((*attrp)->flags & POSIX_SPAWN_SETSCHEDULER)
            (void)sched_setscheduler(0, (*attrp)->schedpolicy, &(*attrp)->schedparam);
    }

    /* 3. Execute; _exit(127) on failure. */
    execve(path, argv, envp);
    _exit(127);
}

/* ------------------------------------------------------------------ */
/*  posix_spawn / posix_spawnp                                         */
/* ------------------------------------------------------------------ */

static inline int posix_spawn(pid_t *pid, const char *path,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *attrp,
    char *const argv[], char *const envp[]) {

    pid_t child = fork();
    if (child == -1)
        return errno; /* errno set by fork */

    if (child == 0) {
        __ndk_spawn_child(path, file_actions, attrp, argv, envp);
        /* unreachable */
    }

    if (pid != NULL)
        *pid = child;
    return 0;
}

static inline int posix_spawnp(pid_t *pid, const char *file,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *attrp,
    char *const argv[], char *const envp[]) {

    pid_t child = fork();
    if (child == -1)
        return errno;

    if (child == 0) {
        /* Apply file_actions and attrs first, then exec with PATH search. */
        if (file_actions != NULL && *file_actions != NULL) {
            for (const __ndk_fa_node *n = (*file_actions)->head; n != NULL; n = n->next) {
                switch (n->type) {
                case 0: {
                    int f = open(n->path, n->oflag, n->mode);
                    if (f < 0) _exit(127);
                    if (f != n->fd) { dup2(f, n->fd); close(f); }
                    break;
                }
                case 1: close(n->fd); break;
                case 2: if (dup2(n->src_fd, n->fd) < 0) _exit(127); break;
                }
            }
        }
        if (attrp != NULL && *attrp != NULL) {
            if ((*attrp)->flags & POSIX_SPAWN_RESETIDS) {
                (void)setegid(getgid());
                (void)seteuid(getuid());
            }
            if ((*attrp)->flags & POSIX_SPAWN_SETPGROUP)
                (void)setpgid(0, (*attrp)->pgroup);
            if ((*attrp)->flags & POSIX_SPAWN_SETSIGMASK)
                pthread_sigmask(SIG_SETMASK, &(*attrp)->sigmask, NULL);
            if ((*attrp)->flags & POSIX_SPAWN_SETSIGDEF) {
                struct sigaction sa;
                memset(&sa, 0, sizeof(sa));
                sa.sa_handler = SIG_DFL;
                for (int sig = 1; sig < NSIG; sig++)
                    if (sigismember(&(*attrp)->sigdefault, sig))
                        (void)sigaction(sig, &sa, NULL);
            }
            if ((*attrp)->flags & POSIX_SPAWN_SETSCHEDPARAM)
                (void)sched_setparam(0, &(*attrp)->schedparam);
            if ((*attrp)->flags & POSIX_SPAWN_SETSCHEDULER)
                (void)sched_setscheduler(0, (*attrp)->schedpolicy, &(*attrp)->schedparam);
        }
        execvp(file, argv);
        _exit(127);
    }

    if (pid != NULL)
        *pid = child;
    return 0;
}

#endif /* __ANDROID_API__ < 28 */
#endif /* NDK_BIONIC_POSIX_SPAWN_H */
