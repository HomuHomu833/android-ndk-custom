#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include "syscall.h"
#include "pthread_impl.h"

struct ctx {
	int fd;
	const char *filename;
	int amode;
	int p;
};

static int checker(void *p)
{
	struct ctx *c = p;
	int ret;

	ret = __syscall(SYS_faccessat, c->fd, c->filename, c->amode);
	__syscall(SYS_write, c->p, &ret, sizeof ret);
	return 0;
}

int faccessat(int fd, const char *filename, int amode, int flag)
{
	if (flag & ~AT_EACCESS)
		return __syscall_ret(-EINVAL);

	if (!flag || (getuid() == geteuid() && getgid() == getegid()))
		return syscall(SYS_faccessat, fd, filename, amode);

	char stack[1024];
	sigset_t set;
	pid_t pid;
	int status;
	int ret, p[2];

	if (pipe2(p, O_CLOEXEC)) return __syscall_ret(-EBUSY);
	struct ctx c = { .fd = fd, .filename = filename, .amode = amode, .p = p[1] };

	__block_all_sigs(&set);

	pid = __clone(checker, stack + sizeof stack, 0, &c);
	__syscall(SYS_close, p[1]);

	if (pid < 0 || __syscall(SYS_read, p[0], &ret, sizeof ret) != sizeof(ret))
		ret = -EBUSY;
	__syscall(SYS_close, p[0]);
	__sys_wait4(pid, &status, __WCLONE, 0);

	__restore_sigs(&set);

	return __syscall_ret(ret);
}
