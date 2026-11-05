/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Build-time assertions only. This file is not linked into the server. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/openat2.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/vfs.h>
#include <time.h>
#include <libpq-fe.h>
#include <pg_config.h>
#include <microhttpd.h>
#if !defined(__GLIBC__) || !__GLIBC_PREREQ(2, 34)
#error "Startup resolution requires reviewed glibc 2.34 or later"
#endif
#if !defined(__linux__) || defined(__ILP32__)
#error "This runtime requires a supported Linux 64-bit LP64 ABI"
#elif defined(__x86_64__)
_Static_assert(sizeof(struct stat) <= 160 && offsetof(struct stat, st_mode) == 24 && offsetof(struct stat, st_uid) == 28, "x86-64 stat ABI changed");
_Static_assert(SYS_read == 0 && SYS_open == 2 && SYS_close == 3 && SYS_fstat == 5 && SYS_getuid == 102, "x86-64 syscall numbers changed");
_Static_assert((O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) == 0xa0800, "x86-64 open flags changed");
_Static_assert(offsetof(struct stat, st_nlink) == 16 && sizeof(((struct stat *)0)->st_nlink) == 8 && offsetof(struct stat, st_gid) == 32, "x86-64 preparer stat ABI changed");
_Static_assert(SYS_write == 1 && SYS_fsync == 74 && SYS_fchmod == 91 && SYS_fstatfs == 138 && SYS_exit_group == 231, "x86-64 startup syscall numbers changed");
_Static_assert(SYS_getgid == 104 && SYS_geteuid == 107 && SYS_getegid == 108 && SYS_openat == 257 && SYS_mkdirat == 258 && SYS_unlinkat == 263 && SYS_renameat2 == 316 && SYS_getrandom == 318, "x86-64 preparer syscall numbers changed");
_Static_assert(O_DIRECTORY == 0x10000 && O_NOFOLLOW == 0x20000, "x86-64 preparer flags changed");
#elif defined(__aarch64__)
_Static_assert(sizeof(struct stat) <= 160 && offsetof(struct stat, st_mode) == 16 && offsetof(struct stat, st_uid) == 24, "AArch64 stat ABI changed");
_Static_assert(SYS_read == 63 && SYS_openat == 56 && SYS_close == 57 && SYS_fstat == 80 && SYS_getuid == 174, "AArch64 syscall numbers changed");
_Static_assert((O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) == 0x88800, "AArch64 open flags changed");
_Static_assert(O_DIRECTORY == 0x4000 && O_NOFOLLOW == 0x8000, "AArch64 preparer flags changed");
#elif defined(__riscv) && __riscv_xlen == 64
#if !defined(__riscv_float_abi_double) || !defined(__riscv_flen) || __riscv_flen != 64 || !defined(__riscv_mul) || !defined(__riscv_div) || !defined(__riscv_atomic) || !defined(__riscv_compressed)
#error "The RISC-V server requires RV64GC and the LP64D calling convention"
#endif
_Static_assert(sizeof(struct stat) <= 160 && offsetof(struct stat, st_mode) == 16 && offsetof(struct stat, st_uid) == 24, "RISC-V stat ABI changed");
_Static_assert(SYS_read == 63 && SYS_openat == 56 && SYS_close == 57 && SYS_fstat == 80 && SYS_getuid == 174, "RISC-V syscall numbers changed");
_Static_assert((O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) == 0xa0800, "RISC-V open flags changed");
_Static_assert(O_DIRECTORY == 0x10000 && O_NOFOLLOW == 0x20000, "RISC-V preparer flags changed");
#else
#error "This runtime supports x86-64, AArch64, or RV64GC/LP64D Linux"
#endif
#if defined(__aarch64__) || defined(__riscv)
_Static_assert(offsetof(struct stat, st_nlink) == 20 && sizeof(((struct stat *)0)->st_nlink) == 4 && offsetof(struct stat, st_gid) == 28, "generic preparer stat ABI changed");
_Static_assert(SYS_write == 64 && SYS_fsync == 82 && SYS_fchmod == 52 && SYS_fstatfs == 44 && SYS_exit_group == 94, "generic startup syscall numbers changed");
_Static_assert(SYS_getgid == 176 && SYS_geteuid == 175 && SYS_getegid == 177 && SYS_mkdirat == 34 && SYS_unlinkat == 35 && SYS_renameat2 == 276 && SYS_getrandom == 278, "generic preparer syscall numbers changed");
#endif
/* Startup interfaces reviewed against glibc 2.34/2.41 and Linux v6.12,
 * on 2026-11-05. This executable checks the actual target's headers. */
_Static_assert(offsetof(struct stat, st_size) == 48 && sizeof(((struct stat *)0)->st_size) == 8, "preparer file size ABI changed");
_Static_assert(sizeof(struct statfs) <= 120 && offsetof(struct statfs, f_flags) == 80 && ST_RDONLY == 1, "preparer mount ABI changed");
_Static_assert(GRND_NONBLOCK == 1, "preparer random flag changed");
_Static_assert(SYS_openat2 == 437 && sizeof(struct open_how) == 24 && offsetof(struct open_how, flags) == 0 && offsetof(struct open_how, mode) == 8 && offsetof(struct open_how, resolve) == 16, "openat2 ABI changed");
_Static_assert((RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_XDEV) == 11 && RENAME_NOREPLACE == 1 && AT_FDCWD == -100, "preparer path policy constants changed");
_Static_assert(O_NONBLOCK == 0x800 && O_CLOEXEC == 0x80000 && O_CREAT == 64 && O_EXCL == 128 && O_WRONLY == 1, "preparer common open flags changed");
_Static_assert(sizeof(struct gaicb) == 56 && offsetof(struct gaicb, ar_name) == 0 && offsetof(struct gaicb, ar_service) == 8 && offsetof(struct gaicb, ar_request) == 16 && offsetof(struct gaicb, ar_result) == 24, "gaicb ABI changed");
_Static_assert(sizeof(struct addrinfo) == 48 && offsetof(struct addrinfo, ai_flags) == 0 && offsetof(struct addrinfo, ai_family) == 4 && offsetof(struct addrinfo, ai_socktype) == 8 && offsetof(struct addrinfo, ai_protocol) == 12 && offsetof(struct addrinfo, ai_addrlen) == 16 && sizeof(((struct addrinfo *)0)->ai_addrlen) == 4 && offsetof(struct addrinfo, ai_addr) == 24, "addrinfo ABI changed");
_Static_assert(sizeof(struct sigevent) == 64 && offsetof(struct sigevent, sigev_notify) == 12 && SIGEV_NONE == 1 && GAI_NOWAIT == 1, "async resolver notification ABI changed");
_Static_assert(EAI_INPROGRESS == -100 && EAI_ALLDONE == -103 && EAI_INTR == -104 && EAI_AGAIN == -3 && SOCK_STREAM == 1 && IPPROTO_TCP == 6, "resolver constants changed");
_Static_assert(sizeof(sigset_t) == 128, "libc signal-set capacity changed");
_Static_assert(SIGALRM == 14 && SIGPIPE == 13 && SIG_BLOCK == 0 && SIG_SETMASK == 2 && ITIMER_REAL == 0, "watchdog signal constants changed");
_Static_assert(sizeof(timer_t) == 8 && sizeof(struct itimerspec) == 32 && offsetof(struct itimerspec, it_interval) == 0 && offsetof(struct itimerspec, it_value) == 16 && offsetof(struct sigevent, sigev_signo) == 8 && SIGEV_SIGNAL == 0 && SIGKILL == 9 && TIMER_ABSTIME == 1, "kernel timer libc ABI changed");
_Static_assert(sizeof(struct timeval) == 16 && offsetof(struct timeval, tv_usec) == 8 && sizeof(struct itimerval) == 32 && offsetof(struct itimerval, it_interval) == 0 && offsetof(struct itimerval, it_value) == 16, "interval timer ABI changed");
_Static_assert(offsetof(struct sockaddr_in, sin_family) == 0 && offsetof(struct sockaddr_in, sin_addr) == 4, "resolver IPv4 ABI changed");
/* Linux v6.17 UAPI values reviewed on 2026-11-05. The arm64 fcntl header
 * overrides O_NOFOLLOW; RISC-V uses the asm-generic flags. Actual installed
 * libc, libpq, and libmicrohttpd headers must satisfy these assertions. */
_Static_assert(sizeof(void *) == 8 && sizeof(long) == 8 && sizeof(size_t) == 8, "The runtime requires the LP64 data model");
_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "The runtime requires little-endian data");
_Static_assert(sizeof(struct timespec) == 16 && offsetof(struct timespec, tv_nsec) == 8, "timespec ABI changed");
_Static_assert(sizeof(struct pollfd) == 8 && offsetof(struct pollfd, events) == 4 && offsetof(struct pollfd, revents) == 6, "poll ABI changed");
_Static_assert(sizeof(struct sockaddr_in) == 16 && AF_INET == 2, "IPv4 ABI changed");
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
