#include <sys/fsuid.h>
#include <stdlib.h>
#include "syscall.h"

int setfsuid(uid_t uid)
{
    const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return syscall(SYS_setfsuid, uid);
}