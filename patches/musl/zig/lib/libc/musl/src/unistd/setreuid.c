#include <unistd.h>
#include <stdlib.h>
#include "syscall.h"
#include "libc.h"

int setreuid(uid_t ruid, uid_t euid)
{
	const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return __setxid(SYS_setreuid, ruid, euid, 0);
}
