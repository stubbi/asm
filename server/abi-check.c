/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Build-time assertions only. This file is not linked into the server. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <libpq-fe.h>
#include <pg_config.h>
#include <microhttpd.h>
#if !defined(__linux__) || !defined(__x86_64__) || defined(__ILP32__)
#error "This runtime requires the Linux x86-64 LP64 ABI"
#endif
_Static_assert(sizeof(void *) == 8, "The runtime requires the x86-64 ABI");
_Static_assert(sizeof(struct timespec) == 16 && offsetof(struct timespec, tv_nsec) == 8, "timespec ABI changed");
_Static_assert(sizeof(struct pollfd) == 8 && offsetof(struct pollfd, events) == 4 && offsetof(struct pollfd, revents) == 6, "poll ABI changed");
_Static_assert(sizeof(struct sockaddr_in) == 16 && AF_INET == 2, "IPv4 ABI changed");
_Static_assert(sizeof(struct stat) <= 160 && offsetof(struct stat, st_mode) == 24 && offsetof(struct stat, st_uid) == 28, "stat ABI changed");
_Static_assert(SYS_read == 0 && SYS_open == 2 && SYS_close == 3 && SYS_fstat == 5 && SYS_getuid == 102, "Linux syscall numbers changed");
_Static_assert((O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) == 0xa0800, "open flags changed");
_Static_assert(POLLIN == 1 && POLLOUT == 4 && (POLLERR | POLLHUP | POLLNVAL) == 56 && CLOCK_MONOTONIC == 1, "poll or clock constants changed");
_Static_assert(PGRES_POLLING_READING == 1 && PGRES_POLLING_WRITING == 2 && PGRES_POLLING_OK == 3 && PGRES_TUPLES_OK == 2, "libpq enums changed");
_Static_assert(PG_VERSION_NUM == 160015, "Review another PostgreSQL header version before testing");
_Static_assert(sizeof(struct MHD_OptionItem) == 24, "MHD option layout changed");
_Static_assert(offsetof(struct MHD_OptionItem, value) == 8, "MHD value offset changed");
_Static_assert(offsetof(struct MHD_OptionItem, ptr_value) == 16, "MHD pointer offset changed");
_Static_assert(MHD_VERSION == 0x01000300, "Review another MHD version before testing");
_Static_assert(MHD_USE_THREAD_PER_CONNECTION == 4 && MHD_USE_INTERNAL_POLLING_THREAD == 8, "MHD flags changed");
_Static_assert(MHD_USE_ITC == 1024, "MHD inter-thread wake flag changed");
_Static_assert(MHD_OPTION_ARRAY == 15 && MHD_OPTION_SOCK_ADDR_LEN == 40, "MHD options changed");
_Static_assert(MHD_OPTION_CONNECTION_MEMORY_LIMIT == 1 && MHD_OPTION_CONNECTION_LIMIT == 2, "MHD bounds changed");
_Static_assert(MHD_OPTION_CONNECTION_TIMEOUT == 3 && MHD_OPTION_URI_LOG_CALLBACK == 7, "MHD callbacks changed");
_Static_assert(MHD_OPTION_THREAD_STACK_SIZE == 19 && MHD_OPTION_STRICT_FOR_CLIENT == 29, "MHD limits changed");
_Static_assert(MHD_HEADER_KIND == 1 && MHD_GET_ARGUMENT_KIND == 8 && MHD_RESPMEM_MUST_COPY == 2, "MHD value constants changed");
_Static_assert(sizeof(PQconninfoOption) == 56 && offsetof(PQconninfoOption, val) == 24, "libpq option ABI changed");
int main(void)
{
    if (strcmp(MHD_get_version(), "1.0.3") != 0 || PQlibVersion() != 160015) {
        fputs("Use the reviewed libmicrohttpd 1.0.3 and libpq 16.15 runtime libraries.\n", stderr);
        return 1;
    }
    return 0;
}
