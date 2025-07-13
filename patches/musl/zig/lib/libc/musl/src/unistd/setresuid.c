#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>
#include "syscall.h"
#include "libc.h"

int setresuid(uid_t ruid, uid_t euid, uid_t suid)
{
	const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return __setxid(SYS_setresuid, ruid, euid, suid);
}
