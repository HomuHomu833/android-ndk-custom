#include <unistd.h>
#include <stdlib.h>
#include "syscall.h"
#include "libc.h"

int setregid(gid_t rgid, gid_t egid)
{
	const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return __setxid(SYS_setregid, rgid, egid, 0);
}
