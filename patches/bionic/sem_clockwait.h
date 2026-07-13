/*
 * sem_clockwait.h — provide sem_clockwait() on bionic API levels below 30.
 *
 * bionic only declares/exports sem_clockwait() from API 30, but CPython's
 * configure enables HAVE_SEM_CLOCKWAIT and Python/thread_pthread.h calls it
 * unconditionally, so a sub-30 build fails with "call to undeclared function
 * 'sem_clockwait'". This is a genuine implementation, not a fallback: it is a
 * transcription of bionic's own semaphore.cpp — a futex wait over the semaphore
 * counter word — so it gives true CLOCK_MONOTONIC waits identical to API 30+.
 *
 * Force-included (via -include) for the bionic Python build; self-gated so it is
 * inert at API >= 30 (where the libc declaration wins) and on non-Android hosts.
 */
#ifndef NDK_BIONIC_SEM_CLOCKWAIT_H
#define NDK_BIONIC_SEM_CLOCKWAIT_H

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 30)

#include <errno.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#include <linux/futex.h>

/* bionic packs the semaphore in a single 32-bit word: bit 0 is the
 * process-shared flag, bits 1..31 are the signed value. (semaphore.cpp) */
#define NDK_SEMCOUNT_SHARED_MASK 0x00000001u
#define NDK_SEMCOUNT_VALUE_SHIFT 1

static inline int ndk_semcount_to_value(unsigned int sval) {
	return (int)sval >> NDK_SEMCOUNT_VALUE_SHIFT;
}

/* Atomically decrement the value if positive; returns the pre-decrement value
 * (<= 0 means the semaphore was empty and no decrement happened). */
static inline int ndk_sem_dec(atomic_uint *count_ptr) {
	unsigned int old = atomic_load_explicit(count_ptr, memory_order_relaxed);
	unsigned int shared = old & NDK_SEMCOUNT_SHARED_MASK;
	unsigned int newv;
	do {
		if (ndk_semcount_to_value(old) <= 0)
			return ndk_semcount_to_value(old);
		newv = ((old - (1u << NDK_SEMCOUNT_VALUE_SHIFT)) & ~NDK_SEMCOUNT_SHARED_MASK) | shared;
	} while (!atomic_compare_exchange_weak_explicit(
	             count_ptr, &old, newv, memory_order_acquire, memory_order_relaxed));
	return ndk_semcount_to_value(old);
}

static inline int sem_clockwait(sem_t *sem, clockid_t clock,
                                const struct timespec *abs_timeout) {
	if (clock != CLOCK_MONOTONIC && clock != CLOCK_REALTIME) {
		errno = EINVAL;
		return -1;
	}
	if (abs_timeout != NULL &&
	    (abs_timeout->tv_nsec < 0 || abs_timeout->tv_nsec >= 1000000000)) {
		errno = EINVAL;
		return -1;
	}

	/* sem_t's first (and, for the counter, only relevant) word is the count. */
	atomic_uint *count_ptr = (atomic_uint *)sem;

	if (ndk_sem_dec(count_ptr) > 0)
		return 0;

	unsigned int shared =
	    atomic_load_explicit(count_ptr, memory_order_relaxed) & NDK_SEMCOUNT_SHARED_MASK;

	int op = FUTEX_WAIT_BITSET;
	if (shared == 0)
		op |= FUTEX_PRIVATE_FLAG;
	if (clock == CLOCK_REALTIME)
		op |= FUTEX_CLOCK_REALTIME;

	for (;;) {
		if (ndk_sem_dec(count_ptr) > 0)
			return 0;
		/* When the value is 0 the whole word equals the shared bit, so that is
		 * the value we tell the kernel to compare against. abs_timeout is an
		 * absolute deadline on `clock`, matching sem_clockwait(3) semantics. */
		long r = syscall(SYS_futex, (void *)count_ptr, op, (int)shared,
		                 abs_timeout, NULL, FUTEX_BITSET_MATCH_ANY);
		if (r != 0) {
			if (errno == ETIMEDOUT || errno == EINTR)
				return -1; /* errno already set by the syscall */
			/* EAGAIN: the word changed before we slept — just retry. */
		}
	}
}

#endif /* __ANDROID_API__ < 30 */
#endif /* NDK_BIONIC_SEM_CLOCKWAIT_H */
