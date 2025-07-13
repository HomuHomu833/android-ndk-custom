#include <unistd.h>
#include <stdlib.h>
#include "syscall.h"
#include "libc.h"

int seteuid(uid_t euid)
{
    const char *is_android = getenv("ANDROID_DATA");
	if (is_android)
		return 0;
	return __setxid(SYS_setresuid, -1, euid, -1);
}
