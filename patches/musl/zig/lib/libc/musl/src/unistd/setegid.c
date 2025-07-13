#include <unistd.h>
#include <stdlib.h>
#include "libc.h"
#include "syscall.h"

int setegid(gid_t egid)
{
    const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return __setxid(SYS_setresgid, -1, egid, -1);
}