#include <unistd.h>
#include <stdlib.h>
#include "syscall.h"
#include "libc.h"

int setgid(gid_t gid)
{
	const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return __setxid(SYS_setgid, gid, 0, 0);
}
