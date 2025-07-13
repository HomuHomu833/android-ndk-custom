#include <sys/fsuid.h>
#include <stdlib.h>
#include "syscall.h"

int setfsgid(gid_t gid)
{
    const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return syscall(SYS_setfsgid, gid);
}