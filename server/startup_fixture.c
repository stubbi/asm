/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Test-only preload library. Never link this file into the runtime.
 * Faults and observations apply only to an owned child executable.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <netdb.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static const char *mode;
static int log_fd = -1;
static struct sigaction initial_action;
static sigset_t initial_mask;
static struct itimerval initial_timer;
static struct gaicb *owned_request;
static const struct addrinfo *owned_hints;
static const char *owned_name;
static struct addrinfo first, second;
static struct sockaddr_in first_address, second_address;
static int synthetic, completed, observed_connection;
static timer_t hard_timer;
static int hard_created, hard_armed, hard_deleted, start_clock_valid;
static struct timespec start_clock;
static pthread_mutex_t worker_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t worker_condition = PTHREAD_COND_INITIALIZER;
static int worker_ready;

static int is_mode(const char *name) { return mode && strcmp(mode, name) == 0; }

static void event(const char *line) {
    if (log_fd >= 0) {
        size_t size = strlen(line);
        /* Logging failures must fail the Python observation, not change DNS. */
        (void)write(log_fd, line, size);
        (void)write(log_fd, "\n", 1);
    }
}

static void inherited_alarm(int number) { (void)number; }
static void interruption(int number) { (void)number; }

static void *blocked_worker(void *unused) {
    (void)unused;
    /* The creating thread blocks signals before pthread_create. This worker
     * therefore cannot consume the process-directed watchdog signal. */
    sigset_t mask;
    if (pthread_sigmask(SIG_SETMASK, NULL, &mask) || sigismember(&mask, SIGALRM) != 1)
        _exit(99);
    if (pthread_mutex_lock(&worker_mutex)) _exit(99);
    event("blocked-worker-ready");
    worker_ready = 1;
    if (pthread_cond_signal(&worker_condition)) _exit(99);
    for (;;) {
        if (pthread_cond_wait(&worker_condition, &worker_mutex)) _exit(99);
    }
    return NULL;
}

static void start_blocked_worker(void) {
    sigset_t blocked, saved;
    sigfillset(&blocked);
    pthread_t worker;
    if (pthread_sigmask(SIG_SETMASK, &blocked, &saved) ||
        pthread_create(&worker, NULL, blocked_worker, NULL) ||
        pthread_sigmask(SIG_SETMASK, &saved, NULL) || pthread_detach(worker) ||
        pthread_mutex_lock(&worker_mutex)) {
        event("blocked-worker-setup-failed");
        _exit(99);
    }
    while (!worker_ready) {
        if (pthread_cond_wait(&worker_condition, &worker_mutex)) _exit(99);
    }
    if (pthread_mutex_unlock(&worker_mutex)) _exit(99);
}

static void install_denial(int number, int error) {
    /* A fault injector, not a sandbox. The child cannot change architecture. */
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned int)number, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        /* Keep stderr usable when file writes return EINTR. */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 2, number == SYS_write ? 1 : 0, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (unsigned int)error),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = { .len = sizeof(instructions) / sizeof(instructions[0]),
                                  .filter = instructions };
    event("seccomp-installing");
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program)) {
        event("seccomp-setup-failed");
        _exit(99);
    }
    event("seccomp-installed");
}

__attribute__((constructor)) static void initialize(void) {
    mode = getenv("ASM_STARTUP_MODE");
    const char *path = getenv("ASM_STARTUP_LOG");
    if (path) {
        log_fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (log_fd < 0) _exit(99);
    }
    if (!mode) return;
    if (is_mode("deny-timer-create")) install_denial(SYS_timer_create, EPERM);
    if (is_mode("deny-timer-settime")) install_denial(SYS_timer_settime, EPERM);
    if (is_mode("deny-timer-delete")) install_denial(SYS_timer_delete, EPERM);
    if (is_mode("deny-openat2")) { install_denial(SYS_openat2, EPERM); return; }
    if (is_mode("unsupported-openat2")) { install_denial(SYS_openat2, ENOSYS); return; }
    if (is_mode("interrupt-read")) { install_denial(SYS_read, EINTR); return; }
    if (is_mode("interrupt-write")) { install_denial(SYS_write, EINTR); return; }
    if (is_mode("interrupt-fsync")) { install_denial(SYS_fsync, EINTR); return; }
    if (is_mode("interrupt-rename")) { install_denial(SYS_renameat2, EINTR); return; }
    struct sigaction action = { .sa_handler = inherited_alarm, .sa_flags = SA_RESTART };
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGUSR2);
    if (sigaction(SIGALRM, &action, NULL)) _exit(99);
    sigset_t mask;
    if (sigprocmask(SIG_SETMASK, NULL, &mask)) _exit(99);
    sigaddset(&mask, SIGUSR2);
    if (is_mode("blocked-alarm")) sigaddset(&mask, SIGALRM);
    else sigdelset(&mask, SIGALRM);
    if (sigprocmask(SIG_SETMASK, &mask, NULL)) _exit(99);
    struct itimerval timer = {0};
    if (is_mode("active-timer")) timer.it_value.tv_sec = 30;
    if (is_mode("expired-periodic")) {
        action.sa_handler = SIG_IGN;
        if (sigaction(SIGALRM, &action, NULL)) _exit(99);
        timer.it_value.tv_usec = timer.it_interval.tv_usec = 20000;
    }
    if (setitimer(ITIMER_REAL, &timer, NULL)) _exit(99);
    if (is_mode("expired-periodic")) {
        struct timespec delay = { .tv_nsec = 100000000 };
        while (nanosleep(&delay, &delay) && errno == EINTR) {}
    }
    if (sigaction(SIGALRM, NULL, &initial_action) ||
        sigprocmask(SIG_SETMASK, NULL, &initial_mask) ||
        getitimer(ITIMER_REAL, &initial_timer)) _exit(99);
    if (is_mode("expired-periodic")) {
        if (initial_timer.it_value.tv_sec || initial_timer.it_value.tv_usec ||
            !initial_timer.it_interval.tv_usec) {
            event("expired-periodic-unavailable");
            _exit(99);
        }
        event("expired-periodic-ready");
    }
    action.sa_handler = interruption;
    action.sa_flags = 0;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGUSR1, &action, NULL)) _exit(99);
    event("initialized");
    if (is_mode("submit-stall-worker") || is_mode("submit-stall-masked")) start_blocked_worker();
}

static int initial_signal_state_matches(void) {
    struct sigaction action;
    struct itimerval timer;
    sigset_t mask;
    if (sigaction(SIGALRM, NULL, &action) || getitimer(ITIMER_REAL, &timer) ||
        sigprocmask(SIG_SETMASK, NULL, &mask)) return 0;
    if (action.sa_handler != initial_action.sa_handler || action.sa_flags != initial_action.sa_flags ||
        timer.it_value.tv_sec != initial_timer.it_value.tv_sec ||
        timer.it_value.tv_usec != initial_timer.it_value.tv_usec ||
        timer.it_interval.tv_sec != initial_timer.it_interval.tv_sec ||
        timer.it_interval.tv_usec != initial_timer.it_interval.tv_usec) return 0;
    for (int number = 1; number < NSIG; number++) {
        if (sigismember(&mask, number) != sigismember(&initial_mask, number) ||
            sigismember(&action.sa_mask, number) != sigismember(&initial_action.sa_mask, number)) return 0;
    }
    return 1;
}

static void watchdog_observation(void) {
    int empty_alarm = !initial_timer.it_value.tv_sec && !initial_timer.it_value.tv_usec &&
                      !initial_timer.it_interval.tv_sec && !initial_timer.it_interval.tv_usec;
    int valid = hard_created && hard_armed && !hard_deleted && empty_alarm && initial_signal_state_matches();
    event(valid ? "watchdog-ready" : "watchdog-invalid");
}

static void make_result(void) {
    first_address.sin_family = second_address.sin_family = AF_INET;
    inet_pton(AF_INET, "127.0.0.1", &first_address.sin_addr);
    inet_pton(AF_INET, "127.0.0.2", &second_address.sin_addr);
    first.ai_family = second.ai_family = AF_INET;
    first.ai_socktype = second.ai_socktype = SOCK_STREAM;
    first.ai_protocol = second.ai_protocol = IPPROTO_TCP;
    first.ai_addrlen = second.ai_addrlen = sizeof(first_address);
    first.ai_addr = (struct sockaddr *)&first_address;
    second.ai_addr = (struct sockaddr *)&second_address;
    first.ai_next = &second;
    if (is_mode("bad-family")) first.ai_family = AF_INET6;
    if (is_mode("bad-socktype")) first.ai_socktype = SOCK_DGRAM;
    if (is_mode("bad-protocol")) first.ai_protocol = IPPROTO_UDP;
    if (is_mode("bad-length")) first.ai_addrlen = sizeof(first_address) - 1;
    if (is_mode("null-address")) first.ai_addr = NULL;
    if (is_mode("bad-address-family")) first_address.sin_family = AF_INET6;
    owned_request->ar_result = is_mode("null-result") ? NULL : &first;
}

int getaddrinfo_a(int how, struct gaicb *list[], int count, struct sigevent *notification) {
    event("lookup");
    watchdog_observation();
    if (how != GAI_NOWAIT || count != 1 || !list || !list[0] || !list[0]->ar_name ||
        strcmp(list[0]->ar_name, "localhost") || !list[0]->ar_request || !notification ||
        notification->sigev_notify != SIGEV_NONE ||
        list[0]->ar_request->ai_family != AF_INET ||
        list[0]->ar_request->ai_socktype != SOCK_STREAM ||
        list[0]->ar_request->ai_protocol != IPPROTO_TCP) {
        event("bad-profile");
        return EAI_FAIL;
    }
    event("profile-valid");
    owned_request = list[0];
    owned_name = owned_request->ar_name;
    owned_hints = owned_request->ar_request;
    if (is_mode("submit-stall-masked")) {
        _Static_assert(sizeof(unsigned long) == 8 && NSIG == 65, "Review the kernel signal-set profile");
        unsigned long all = ~0UL, actual = 0;
        unsigned long expected = all & ~(1UL << (SIGKILL - 1)) & ~(1UL << (SIGSTOP - 1));
        if (syscall(SYS_rt_sigprocmask, SIG_SETMASK, &all, NULL, sizeof(all)) ||
            syscall(SYS_rt_sigprocmask, SIG_SETMASK, NULL, &actual, sizeof(actual)) || actual != expected)
            _exit(99);
        event("masked-submit-ready");
        for (;;) pause();
    }
    if (is_mode("submit-stall") || is_mode("submit-stall-worker")) for (;;) pause();
    if (is_mode("submit-fail")) { errno = EIO; return EAI_SYSTEM; }
    synthetic = !is_mode("real");
    if (!synthetic) {
        int (*next)(int, struct gaicb *[], int, struct sigevent *) = dlsym(RTLD_NEXT, "getaddrinfo_a");
        if (!next) _exit(99);
        return next(how, list, count, notification);
    }
    make_result();
    return 0;
}

int gai_error(struct gaicb *request) {
    event("gai-error");
    if (request != owned_request || request->ar_name != owned_name ||
        strcmp(owned_name, "localhost") || request->ar_request != owned_hints ||
        owned_hints->ai_family != AF_INET || owned_hints->ai_socktype != SOCK_STREAM ||
        owned_hints->ai_protocol != IPPROTO_TCP) {
        event("storage-invalid");
        return EAI_FAIL;
    }
    if (!synthetic) {
        int (*next)(struct gaicb *) = dlsym(RTLD_NEXT, "gai_error");
        if (!next) _exit(99);
        int result = next(request);
        if (result != EAI_INPROGRESS) completed = 1;
        return result;
    }
    if (is_mode("wait-stall") || is_mode("interrupt")) return EAI_INPROGRESS;
    completed = 1;
    if (is_mode("lookup-fail")) return EAI_NONAME;
    if (is_mode("pending-alarm")) {
        sigset_t mask;
        sigemptyset(&mask);
        sigaddset(&mask, SIGALRM);
        sigprocmask(SIG_BLOCK, &mask, NULL);
        raise(SIGALRM);
    }
    return 0;
}

int gai_suspend(const struct gaicb *const list[], int count, const struct timespec *timeout) {
    event("wait");
    if (count != 1 || !list || list[0] != owned_request || !timeout || timeout->tv_sec < 0 ||
        timeout->tv_sec > 2 || timeout->tv_nsec < 0 || timeout->tv_nsec >= 1000000000L) {
        event("bad-wait");
        return EAI_SYSTEM;
    }
    char remaining[64];
    snprintf(remaining, sizeof(remaining), "wait-ms=%lld",
             (long long)timeout->tv_sec * 1000 + timeout->tv_nsec / 1000000);
    event(remaining);
    if (is_mode("wait-stall")) for (;;) pause();
    if (is_mode("interrupt")) {
        struct timespec delay = { .tv_nsec = 10000000 };
        nanosleep(&delay, NULL);
        raise(SIGUSR1);
        return EAI_INTR;
    }
    int (*next)(const struct gaicb *const [], int, const struct timespec *) = dlsym(RTLD_NEXT, "gai_suspend");
    if (!next) _exit(99);
    return next(list, count, timeout);
}

int gai_cancel(struct gaicb *request) {
    (void)request;
    event("cancel-forbidden");
    return EAI_NOTCANCELED;
}

void freeaddrinfo(struct addrinfo *result) {
    if (owned_request && result == owned_request->ar_result) {
        event(completed ? "freed-completed-result" : "freed-live-result");
        if (synthetic) return;
    }
    void (*next)(struct addrinfo *) = dlsym(RTLD_NEXT, "freeaddrinfo");
    if (!next) _exit(99);
    next(result);
}

/* Record the last pre-timer monotonic sample to check the exact configured
 * two-second absolute deadline, without treating scheduling time as proof. */
int clock_gettime(clockid_t clock, struct timespec *value) {
    int (*next)(clockid_t, struct timespec *) = dlsym(RTLD_NEXT, "clock_gettime");
    if (!next) _exit(99);
    int result = next(clock, value);
    if (!result && clock == CLOCK_MONOTONIC && !hard_created) {
        start_clock = *value;
        start_clock_valid = 1;
    }
    return result;
}

/* Observe the libc timer interface. The kernel still owns every timer. */
static void timer_failure(const char *operation, int error) {
    char line[96];
    snprintf(line, sizeof(line), "hard-timer-%s-failed-errno=%d", operation, error);
    event(line);
}

int timer_create(clockid_t clock, struct sigevent *notification, timer_t *identifier) {
    int entry_errno = errno;
    int (*next)(clockid_t, struct sigevent *, timer_t *) = dlsym(RTLD_NEXT, "timer_create");
    if (!next) _exit(99);
    event("hard-timer-create-attempt");
    errno = entry_errno;
    int result = next(clock, notification, identifier);
    int result_errno = errno;
    if (!result) {
        if (hard_created || clock != CLOCK_MONOTONIC || !notification || !identifier ||
            notification->sigev_notify != SIGEV_SIGNAL || notification->sigev_signo != SIGKILL)
            event("hard-timer-invalid");
        hard_timer = *identifier;
        hard_created = 1;
        event("hard-timer-created");
    } else timer_failure("create", result_errno);
    errno = result_errno;
    return result;
}

int timer_settime(timer_t identifier, int flags, const struct itimerspec *value, struct itimerspec *old) {
    int entry_errno = errno;
    int (*next)(timer_t, int, const struct itimerspec *, struct itimerspec *) = dlsym(RTLD_NEXT, "timer_settime");
    if (!next) _exit(99);
    event("hard-timer-settime-attempt");
    if (!hard_created || identifier != hard_timer || flags != TIMER_ABSTIME || !value ||
        value->it_interval.tv_sec || value->it_interval.tv_nsec) event("hard-timer-invalid");
    struct timespec now;
    if (!value || clock_gettime(CLOCK_MONOTONIC, &now)) _exit(99);
    long long remaining = (long long)(value->it_value.tv_sec - now.tv_sec) * 1000000000LL +
                          value->it_value.tv_nsec - now.tv_nsec;
    if (remaining <= 0 || remaining > 2000000000LL || !start_clock_valid ||
        value->it_value.tv_sec != start_clock.tv_sec + 2 ||
        value->it_value.tv_nsec != start_clock.tv_nsec) event("hard-timer-invalid");
    errno = entry_errno;
    int result = next(identifier, flags, value, old);
    int result_errno = errno;
    if (!result) {
        hard_armed = 1;
        event("hard-timer-armed");
    } else timer_failure("settime", result_errno);
    errno = result_errno;
    return result;
}

int timer_delete(timer_t identifier) {
    int entry_errno = errno;
    int (*next)(timer_t) = dlsym(RTLD_NEXT, "timer_delete");
    if (!next) _exit(99);
    event("hard-timer-delete-attempt");
    if (!hard_created || !hard_armed || hard_deleted || identifier != hard_timer) event("hard-timer-invalid");
    errno = entry_errno;
    int result = next(identifier);
    int result_errno = errno;
    if (!result) {
        hard_deleted = 1;
        event("hard-timer-deleted");
    } else timer_failure("delete", result_errno);
    errno = result_errno;
    return result;
}

/* libpq is not replaced: observe the state at the actual connection boundary. */
void *PQconnectStartParams(const char *const *keys, const char *const *values, int expand) {
    if (owned_request && !observed_connection) {
        observed_connection = 1;
        struct sigaction action;
        struct itimerval timer;
        sigset_t mask;
        int valid = !sigaction(SIGALRM, NULL, &action) &&
                    !getitimer(ITIMER_REAL, &timer) && !sigprocmask(SIG_SETMASK, NULL, &mask);
        valid = valid && hard_created && hard_armed && hard_deleted &&
            action.sa_handler == initial_action.sa_handler &&
            action.sa_flags == initial_action.sa_flags &&
            timer.it_value.tv_sec == 0 && timer.it_value.tv_usec == 0 &&
            timer.it_interval.tv_sec == initial_timer.it_interval.tv_sec &&
            timer.it_interval.tv_usec == initial_timer.it_interval.tv_usec;
        for (int number = 1; number < NSIG; number++) {
            if (sigismember(&mask, number) != sigismember(&initial_mask, number) ||
                sigismember(&action.sa_mask, number) != sigismember(&initial_action.sa_mask, number)) valid = 0;
        }
        event(valid ? "state-restored" : "state-invalid");
    }
    if (!owned_request && !observed_connection) {
        observed_connection = 1;
        event(initial_signal_state_matches() ? "bypass-state-preserved" : "bypass-state-mutated");
    }
    if (owned_request) {
        const char *url = NULL;
        for (int index = 0; index < 32 && keys[index]; index++)
            if (!strcmp(keys[index], "dbname")) url = values[index];
        const char *address = url ? strstr(url, "&hostaddr=") : NULL;
        int pinned = url && strstr(url, "@localhost:") && address &&
            !strcmp(address, "&hostaddr=127.0.0.1") && !strstr(address + sizeof("&hostaddr=") - 1, "hostaddr=");
        event(pinned ? "pinned-address-valid" : "pinned-address-invalid");
    }
    event("database-connect");
    void *(*next)(const char *const *, const char *const *, int) = dlsym(RTLD_NEXT, "PQconnectStartParams");
    if (!next) _exit(99);
    return next(keys, values, expand);
}
