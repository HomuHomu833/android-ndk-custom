#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>
#include "syscall.h"
#include "libc.h"

int setresgid(gid_t rgid, gid_t egid, gid_t sgid)
{
	const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return __setxid(SYS_setresgid, rgid, egid, sgid);
}
