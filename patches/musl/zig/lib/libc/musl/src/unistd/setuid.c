#include <unistd.h>
#include <stdlib.h>
#include "syscall.h"
#include "libc.h"

int setuid(uid_t uid)
{
	const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return __setxid(SYS_setuid, uid, 0, 0);
}
