#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <string.h>
#include <stdlib.h>
#include "syscall.h"

#define MAXTRIES 100

char *tmpnam(char *buf)
{
	static char internal[L_tmpnam];
	const char *tmpdir = getenv("TMPDIR");
	if (!tmpdir || !*tmpdir) tmpdir = "/tmp";
	char s[256];
	int try;
	int r;
	for (try = 0; try < MAXTRIES; try++) {
		snprintf(s, sizeof s, "%s/tmpnam_XXXXXX", tmpdir);
		__randname(s + strlen(tmpdir) + 8);
#ifdef SYS_readlink
		r = __syscall(SYS_readlink, s, (char[1]){0}, 1);
#else
		r = __syscall(SYS_readlinkat, AT_FDCWD, s, (char[1]){0}, 1);
#endif
		if (r == -ENOENT) {
			char *dst = buf ? buf : internal;
			snprintf(dst, L_tmpnam, "%s", s);
			return dst;
		}
	}
	return 0;
}
