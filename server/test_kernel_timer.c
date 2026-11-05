/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Standalone Linux kernel/API experiment. This is not application code.
 * No database, network, credential, or application executable is used.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <gnu/libc-version.h>
#include <limits.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>

#define NS_PER_SECOND INT64_C(1000000000)
#define CHILD_BOUND_NS INT64_C(2800000000)
#define CLEANUP_BOUND_NS INT64_C(2000000000)
#define KERNEL_SIGNAL_BYTES ((_NSIG - 1) / CHAR_BIT)
_Static_assert(KERNEL_SIGNAL_BYTES == sizeof(uint64_t), "Probe requires Linux's 64-signal kernel set");

enum probe { BLOCKED_KILL, DELETED_TIMER, DENIED_CREATE, DENIED_SETTIME, DENIED_DELETE };
enum phase { READY = 1, LIVED_AFTER_DELETE = 2 };
struct observation { int phase, api_errno; int64_t armed_ns; uint64_t mask; };
static struct sigaction inherited_action;
static uint64_t inherited_mask;
static uint64_t blocked_mask;
static int report_fd;
static int64_t previous_alarm_us;

static int64_t now_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
    return (int64_t)now.tv_sec * NS_PER_SECOND + now.tv_nsec;
}

static _Noreturn void child_fail(const char *operation) {
    int saved = errno;
    dprintf(STDERR_FILENO, "kernel-timer probe: child %s failed (errno=%d)\n", operation, saved);
    _exit(90);
}

static uint64_t kernel_mask(void) {
    uint64_t mask = 0;
    if (syscall(SYS_rt_sigprocmask, SIG_SETMASK, NULL, &mask, KERNEL_SIGNAL_BYTES))
        child_fail("read kernel signal mask");
    return mask;
}

static int same_action(const struct sigaction *left, const struct sigaction *right) {
    /* Compare public C API flags; glibc may supply its private signal restorer
     * when restoring an original default disposition through sigaction(). */
    int flags = SA_NOCLDSTOP | SA_NOCLDWAIT | SA_NODEFER | SA_ONSTACK | SA_RESETHAND | SA_RESTART | SA_SIGINFO;
    if (left->sa_handler != right->sa_handler || (left->sa_flags & flags) != (right->sa_flags & flags)) return 0;
    for (int number = 1; number < _NSIG; number++)
        if (sigismember(&left->sa_mask, number) != sigismember(&right->sa_mask, number)) return 0;
    return 1;
}

static void alarm_handler(int number) { (void)number; }

static void checkpoint(void) {
    struct sigaction action;
    struct itimerval alarm;
    if (sigaction(SIGALRM, NULL, &action) || !same_action(&action, &inherited_action))
        child_fail("preserve ALRM action");
    if (kernel_mask() != blocked_mask) child_fail("preserve complete kernel mask");
    if (getitimer(ITIMER_REAL, &alarm)) child_fail("read independent ALRM timer");
    int64_t remaining = (int64_t)alarm.it_value.tv_sec * 1000000 + alarm.it_value.tv_usec;
    if (alarm.it_interval.tv_sec || alarm.it_interval.tv_usec != 250000 ||
        remaining < 27000000 || remaining > previous_alarm_us)
        child_fail("preserve independent active ALRM timer");
    previous_alarm_us = remaining;
}

static void report(int phase, int api_errno, int64_t armed_ns) {
    struct observation value = { .phase = phase, .api_errno = api_errno, .armed_ns = armed_ns,
                                 .mask = kernel_mask() };
    for (int attempt = 0; attempt < 8; attempt++) {
        ssize_t size = write(report_fd, &value, sizeof(value));
        if (size == (ssize_t)sizeof(value)) return;
        if (size < 0 && errno == EINTR) continue;
        child_fail("write bounded observation");
    }
    child_fail("observation interruption bound");
}

static void deny_syscall(int number) {
    /* Test fault injection only. This is not a general sandbox. */
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned int)number, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = { .len = sizeof(instructions) / sizeof(instructions[0]), .filter = instructions };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program)) child_fail("install syscall denial");
}

static void child_probe(enum probe probe, int descriptor) {
    report_fd = descriptor;
    struct rlimit no_core = {0, 0}, cpu = {3, 3};
    if (setrlimit(RLIMIT_CORE, &no_core) || setrlimit(RLIMIT_CPU, &cpu)) child_fail("resource limits");
    struct sigaction action;
    struct itimerval alarm;
    if (getuid() == 0 || getgid() == 0 || getuid() != geteuid() || getgid() != getegid())
        child_fail("nonroot identity");
    if (sigaction(SIGALRM, NULL, &action) || !same_action(&action, &inherited_action) ||
        kernel_mask() != inherited_mask) child_fail("fork-inherited ALRM action and mask");
    /* Linux does not inherit interval timers across fork. Observe that fact
     * separately, then supply a pre-existing active ALRM timer for API checks. */
    if (getitimer(ITIMER_REAL, &alarm) || alarm.it_value.tv_sec || alarm.it_value.tv_usec ||
        alarm.it_interval.tv_sec || alarm.it_interval.tv_usec) child_fail("fork timer state");
    uint64_t all = UINT64_MAX;
    if (syscall(SYS_rt_sigprocmask, SIG_SETMASK, &all, NULL, KERNEL_SIGNAL_BYTES))
        child_fail("block all kernel maskable signals");
    blocked_mask = UINT64_MAX & ~(UINT64_C(1) << (SIGKILL - 1)) & ~(UINT64_C(1) << (SIGSTOP - 1));
    if (kernel_mask() != blocked_mask) child_fail("verify all maskable signals blocked");
    alarm = (struct itimerval){ .it_value = { .tv_sec = 30 }, .it_interval = { .tv_usec = 250000 } };
    if (setitimer(ITIMER_REAL, &alarm, NULL)) child_fail("set independent ALRM timer");
    previous_alarm_us = 30000000;
    checkpoint();

    struct sigevent event = { .sigev_notify = SIGEV_SIGNAL, .sigev_signo = SIGKILL };
    event.sigev_value.sival_int = 7;
    timer_t timer;
    if (probe == DENIED_CREATE) deny_syscall(SYS_timer_create);
    errno = 0;
    int result = timer_create(CLOCK_MONOTONIC, &event, &timer);
    int observed_errno = errno;
    if (probe == DENIED_CREATE) {
        if (result != -1 || observed_errno != EPERM) child_fail("observe denied timer_create");
        checkpoint();
        report(READY, observed_errno, 0);
        _exit(0);
    }
    if (result) child_fail("timer_create SIGKILL");
    checkpoint();
    int64_t armed_ns = now_ns();
    if (armed_ns < 0) child_fail("read absolute deadline");
    int64_t expiration = armed_ns + 2 * NS_PER_SECOND;
    struct itimerspec deadline = { .it_value = {
        .tv_sec = expiration / NS_PER_SECOND, .tv_nsec = expiration % NS_PER_SECOND } };
    if (probe == DENIED_SETTIME) deny_syscall(SYS_timer_settime);
    errno = 0;
    result = timer_settime(timer, TIMER_ABSTIME, &deadline, NULL);
    observed_errno = errno;
    if (probe == DENIED_SETTIME) {
        if (result != -1 || observed_errno != EPERM) child_fail("observe denied timer_settime");
        if (timer_delete(timer)) child_fail("delete unarmed timer");
        checkpoint();
        report(READY, observed_errno, 0);
        _exit(0);
    }
    if (result) child_fail("arm absolute timer");
    checkpoint();
    if (probe == DELETED_TIMER || probe == DENIED_DELETE) {
        if (probe == DENIED_DELETE) deny_syscall(SYS_timer_delete);
        errno = 0;
        result = timer_delete(timer);
        observed_errno = errno;
        if (probe == DELETED_TIMER && result) child_fail("delete armed timer");
        if (probe == DENIED_DELETE && (result != -1 || observed_errno != EPERM))
            child_fail("observe denied timer_delete");
        checkpoint();
    } else observed_errno = 0;
    report(READY, observed_errno, armed_ns);
    if (probe == DELETED_TIMER) {
        int64_t wake = expiration + 200000000;
        struct timespec until = { .tv_sec = wake / NS_PER_SECOND, .tv_nsec = wake % NS_PER_SECOND };
        int sleep_result = 0;
        for (int attempt = 0; attempt < 8; attempt++) {
            sleep_result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &until, NULL);
            if (sleep_result != EINTR) break;
        }
        if (sleep_result) child_fail("wait beyond deleted timer expiration");
        checkpoint();
        report(LIVED_AFTER_DELETE, 0, armed_ns);
        _exit(0);
    }
    for (;;) pause();
}

static int reap_until(pid_t child, int *status, int64_t deadline) {
    /* Iteration bounds also prevent a clock failure from creating an infinite wait. */
    for (int attempt = 0; attempt < 600; attempt++) {
        pid_t result = waitpid(child, status, WNOHANG);
        if (result == child) return 1;
        if (result < 0 && errno != EINTR) return -1;
        int64_t now = now_ns();
        if (now < 0 || now >= deadline) return 0;
        struct timespec delay = { .tv_nsec = 5000000 };
        nanosleep(&delay, NULL);
    }
    return 0;
}

static int run_probe(enum probe probe, const char *name) {
    int descriptors[2];
    if (pipe2(descriptors, O_CLOEXEC | O_NONBLOCK)) { perror("probe pipe"); return 0; }
    fflush(NULL);
    int64_t started = now_ns();
    pid_t child = started < 0 ? -1 : fork();
    if (child == 0) {
        close(descriptors[0]);
        child_probe(probe, descriptors[1]);
        _exit(91);
    }
    close(descriptors[1]);
    if (child < 0) { perror("probe fork/clock"); close(descriptors[0]); return 0; }
    int status = 0;
    int reaped = reap_until(child, &status, started + CHILD_BOUND_NS);
    int64_t finished = now_ns();
    if (reaped != 1) {
        fprintf(stderr, "FAIL %s: child did not terminate within 2.8 seconds\n", name);
        if (reaped == 0) {
            if (kill(child, SIGKILL) && errno != ESRCH) perror("probe cleanup kill");
            int64_t cleanup = now_ns();
            if (cleanup < 0 || reap_until(child, &status, cleanup + CLEANUP_BOUND_NS) != 1)
                fprintf(stderr, "FAIL %s: bounded SIGKILL cleanup could not reap child\n", name);
        }
        close(descriptors[0]);
        return 0;
    }
    struct observation records[2];
    ssize_t count = 0;
    for (int attempt = 0; attempt < 8 && count < (ssize_t)sizeof(records); attempt++) {
        ssize_t size = read(descriptors[0], (char *)records + count, sizeof(records) - (size_t)count);
        if (size > 0) { count += size; continue; }
        if (size < 0 && errno == EINTR) continue;
        if (size < 0 && errno != EAGAIN) count = -1;
        break;
    }
    close(descriptors[0]);
    int expected_count = probe == DELETED_TIMER ? 2 : 1;
    int expected_errno = probe >= DENIED_CREATE ? EPERM : 0;
    int good = count == (ssize_t)(expected_count * sizeof(records[0]));
    if (good) good = records[0].phase == READY && records[0].api_errno == expected_errno;
    int killed = probe == BLOCKED_KILL || probe == DENIED_DELETE;
    if (killed) {
        good = good && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL;
    } else good = good && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    int64_t elapsed = good && records[0].armed_ns ? finished - records[0].armed_ns : finished - started;
    good = good && finished >= started && finished - started < CHILD_BOUND_NS;
    if (killed) good = good && elapsed >= INT64_C(1500000000);
    if (probe == DELETED_TIMER)
        good = good && records[1].phase == LIVED_AFTER_DELETE && records[1].api_errno == 0 &&
               records[1].armed_ns == records[0].armed_ns && elapsed >= INT64_C(2100000000);
    printf("%s %s elapsed_ms=%.3f status=%d observation_bytes=%zd api_errno=%d mask=0x%016llx\n",
           good ? "PASS" : "FAIL", name, (double)elapsed / 1000000, status, count,
           count >= (ssize_t)sizeof(records[0]) ? records[0].api_errno : -1,
           count >= (ssize_t)sizeof(records[0]) ? (unsigned long long)records[0].mask : 0ULL);
    return good;
}

int main(void) {
    if (getuid() == 0 || getgid() == 0 || getuid() != geteuid() || getgid() != getegid()) {
        fputs("Run the kernel timer probe with nonzero real UID/GID and matching effective IDs.\n", stderr);
        return 1;
    }
    struct utsname host;
    if (uname(&host)) { perror("uname"); return 1; }
    printf("kernel-timer probe host=%s kernel=%s glibc=%s uid=%lu gid=%lu\n",
           host.machine, host.release, gnu_get_libc_version(), (unsigned long)getuid(), (unsigned long)getgid());
    printf("headers timer_t=%zu sigevent=%zu sigevent.value=%zu sigevent.signo=%zu sigevent.notify=%zu "
           "itimerspec=%zu itimerspec.interval=%zu itimerspec.value=%zu timespec=%zu timespec.sec=%zu "
           "timespec.nsec=%zu sigset_t=%zu kernel_sigset=%d\n", sizeof(timer_t), sizeof(struct sigevent),
           offsetof(struct sigevent, sigev_value), offsetof(struct sigevent, sigev_signo),
           offsetof(struct sigevent, sigev_notify), sizeof(struct itimerspec),
           offsetof(struct itimerspec, it_interval), offsetof(struct itimerspec, it_value), sizeof(struct timespec),
           offsetof(struct timespec, tv_sec), offsetof(struct timespec, tv_nsec), sizeof(sigset_t), KERNEL_SIGNAL_BYTES);
    printf("constants CLOCK_MONOTONIC=%d SIGEV_SIGNAL=%d SIGKILL=%d TIMER_ABSTIME=%d "
           "SYS_timer_create=%ld SYS_timer_settime=%ld SYS_timer_delete=%ld SYS_rt_sigprocmask=%ld\n",
           CLOCK_MONOTONIC, SIGEV_SIGNAL, SIGKILL, TIMER_ABSTIME, (long)SYS_timer_create,
           (long)SYS_timer_settime, (long)SYS_timer_delete, (long)SYS_rt_sigprocmask);
    struct sigaction original_action, action = { .sa_handler = alarm_handler, .sa_flags = SA_RESTART };
    uint64_t original_mask;
    struct itimerval original_timer;
    if (getitimer(ITIMER_REAL, &original_timer) || original_timer.it_value.tv_sec ||
        original_timer.it_value.tv_usec || original_timer.it_interval.tv_sec || original_timer.it_interval.tv_usec) {
        fputs("The probe parent requires an originally empty ALRM timer.\n", stderr);
        return 1;
    }
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGUSR1);
    if (sigaction(SIGALRM, NULL, &original_action) ||
        syscall(SYS_rt_sigprocmask, SIG_SETMASK, NULL, &original_mask, KERNEL_SIGNAL_BYTES)) {
        perror("capture parent signal state"); return 1;
    }
    uint64_t mask = original_mask | (UINT64_C(1) << (SIGUSR2 - 1));
    int setup = sigaction(SIGALRM, &action, NULL) ||
                syscall(SYS_rt_sigprocmask, SIG_SETMASK, &mask, NULL, KERNEL_SIGNAL_BYTES) ||
                sigaction(SIGALRM, NULL, &inherited_action) ||
                syscall(SYS_rt_sigprocmask, SIG_SETMASK, NULL, &inherited_mask, KERNEL_SIGNAL_BYTES);
    int good = !setup;
    int tests = 0;
    if (setup) perror("set probe parent signal state");
    if (good) {
        good &= run_probe(BLOCKED_KILL, "all-kernel-maskable-signals-blocked");
        good &= run_probe(DELETED_TIMER, "deleted-timer-survives-past-deadline");
        good &= run_probe(DENIED_CREATE, "seccomp-denied-timer-create");
        good &= run_probe(DENIED_SETTIME, "seccomp-denied-timer-settime");
        good &= run_probe(DENIED_DELETE, "seccomp-denied-timer-delete-still-kills");
        tests = 5;
    }
    if (sigaction(SIGALRM, &original_action, NULL) ||
        syscall(SYS_rt_sigprocmask, SIG_SETMASK, &original_mask, NULL, KERNEL_SIGNAL_BYTES)) {
        perror("restore probe parent signal state"); good = 0;
    }
    struct itimerval final_timer;
    if (getitimer(ITIMER_REAL, &final_timer) || final_timer.it_value.tv_sec || final_timer.it_value.tv_usec ||
        final_timer.it_interval.tv_sec || final_timer.it_interval.tv_usec) good = 0;
    struct sigaction final_action;
    uint64_t final_mask = 0;
    if (sigaction(SIGALRM, NULL, &final_action) || !same_action(&final_action, &original_action) ||
        syscall(SYS_rt_sigprocmask, SIG_SETMASK, NULL, &final_mask, KERNEL_SIGNAL_BYTES) ||
        final_mask != original_mask) good = 0;
    printf("{\"schema\":1,\"scope\":\"kernel-timer-probe\",\"status\":\"%s\",\"tests\":%d,\"uid\":%lu,\"gid\":%lu}\n",
           good ? "pass" : "fail", tests, (unsigned long)getuid(), (unsigned long)getgid());
    return good ? 0 : 1;
}
