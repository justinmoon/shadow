#define _GNU_SOURCE

#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static int (*real_open_fn)(const char *pathname, int flags, ...) = NULL;
static int (*real_open64_fn)(const char *pathname, int flags, ...) = NULL;
static int (*real_openat_fn)(int dirfd, const char *pathname, int flags, ...) = NULL;
static int (*real_openat64_fn)(int dirfd, const char *pathname, int flags, ...) = NULL;
static int (*real_close_fn)(int fd) = NULL;
static int (*real_ioctl_fn)(int fd, unsigned long request, ...) = NULL;
static __thread int in_hook = 0;

enum tracked_fd_kind {
    TRACKED_FD_NONE = 0,
    TRACKED_FD_KGSL = 1,
    TRACKED_FD_DRI = 2,
};

static enum tracked_fd_kind tracked_fds[4096];

static bool env_enabled(const char *name) {
    const char *value = getenv(name);
    if (value == NULL || value[0] == '\0') {
        return false;
    }

    return strcmp(value, "0") != 0 &&
           strcmp(value, "false") != 0 &&
           strcmp(value, "off") != 0;
}

static bool should_log_path(const char *pathname) {
    if (pathname == NULL) {
        return false;
    }

    return strstr(pathname, "/dev/kgsl") != NULL ||
           strstr(pathname, "/dev/dri") != NULL ||
           strstr(pathname, "dma_heap") != NULL ||
           strstr(pathname, "/dev/ion") != NULL;
}

static enum tracked_fd_kind classify_path(const char *pathname) {
    if (pathname == NULL) {
        return TRACKED_FD_NONE;
    }
    if (strstr(pathname, "/dev/kgsl") != NULL) {
        return TRACKED_FD_KGSL;
    }
    if (strstr(pathname, "/dev/dri") != NULL) {
        return TRACKED_FD_DRI;
    }
    return TRACKED_FD_NONE;
}

static int deny_errno_value(void) {
    const char *value = getenv("SHADOW_OPENLOG_DENY_ERRNO");
    if (value == NULL || value[0] == '\0') {
        return ENOENT;
    }

    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed <= 0 || parsed > 4096) {
        return ENOENT;
    }
    return (int)parsed;
}

static bool should_deny_path(const char *pathname) {
    if (pathname == NULL) {
        return false;
    }

    if (strstr(pathname, "/dev/dri") != NULL && env_enabled("SHADOW_OPENLOG_DENY_DRI")) {
        return true;
    }
    if (strstr(pathname, "/dev/kgsl") != NULL && env_enabled("SHADOW_OPENLOG_DENY_KGSL")) {
        return true;
    }
    return false;
}

static void write_log_line(const char *kind, const char *pathname, int flags) {
    if (!should_log_path(pathname)) {
        return;
    }

    char buffer[512];
    int len = snprintf(
        buffer,
        sizeof(buffer),
        "[shadow-openlog] %s path=%s flags=0x%x\n",
        kind,
        pathname,
        flags);
    if (len <= 0) {
        return;
    }
    if ((size_t)len > sizeof(buffer)) {
        len = (int)sizeof(buffer);
    }
    syscall(SYS_write, STDERR_FILENO, buffer, (size_t)len);
}

static void write_deny_log_line(const char *kind, const char *pathname, int flags, int err) {
    if (!should_log_path(pathname)) {
        return;
    }

    char buffer[512];
    int len = snprintf(
        buffer,
        sizeof(buffer),
        "[shadow-openlog] %s path=%s flags=0x%x errno=%d\n",
        kind,
        pathname,
        flags,
        err);
    if (len <= 0) {
        return;
    }
    if ((size_t)len > sizeof(buffer)) {
        len = (int)sizeof(buffer);
    }
    syscall(SYS_write, STDERR_FILENO, buffer, (size_t)len);
}

static void ensure_real_symbols(void) {
    if (real_open_fn == NULL) {
        real_open_fn = dlsym(RTLD_NEXT, "open");
    }
    if (real_open64_fn == NULL) {
        real_open64_fn = dlsym(RTLD_NEXT, "open64");
    }
    if (real_openat_fn == NULL) {
        real_openat_fn = dlsym(RTLD_NEXT, "openat");
    }
    if (real_openat64_fn == NULL) {
        real_openat64_fn = dlsym(RTLD_NEXT, "openat64");
    }
    if (real_close_fn == NULL) {
        real_close_fn = dlsym(RTLD_NEXT, "close");
    }
    if (real_ioctl_fn == NULL) {
        real_ioctl_fn = dlsym(RTLD_NEXT, "ioctl");
    }
}

static void track_fd(int fd, const char *pathname) {
    if (fd < 0 || fd >= (int)(sizeof(tracked_fds) / sizeof(tracked_fds[0]))) {
        return;
    }
    tracked_fds[fd] = classify_path(pathname);
}

static void clear_fd(int fd) {
    if (fd < 0 || fd >= (int)(sizeof(tracked_fds) / sizeof(tracked_fds[0]))) {
        return;
    }
    tracked_fds[fd] = TRACKED_FD_NONE;
}

static void write_ioctl_log_line(int fd, unsigned long request, int result, int err) {
    if (fd < 0 || fd >= (int)(sizeof(tracked_fds) / sizeof(tracked_fds[0]))) {
        return;
    }
    if (tracked_fds[fd] == TRACKED_FD_NONE) {
        return;
    }

    const char *kind =
        tracked_fds[fd] == TRACKED_FD_KGSL ? "kgsl" :
        tracked_fds[fd] == TRACKED_FD_DRI ? "dri" :
        "fd";
    char buffer[512];
    int len = snprintf(
        buffer,
        sizeof(buffer),
        "[shadow-openlog] ioctl kind=%s fd=%d request=0x%lx result=%d errno=%d\n",
        kind,
        fd,
        request,
        result,
        err);
    if (len <= 0) {
        return;
    }
    if ((size_t)len > sizeof(buffer)) {
        len = (int)sizeof(buffer);
    }
    syscall(SYS_write, STDERR_FILENO, buffer, (size_t)len);
}

int open(const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    ensure_real_symbols();

    if (!in_hook) {
        in_hook = 1;
        write_log_line("open", pathname, flags);
        in_hook = 0;
    }

    if (should_deny_path(pathname)) {
        int err = deny_errno_value();
        if (!in_hook) {
            in_hook = 1;
            write_deny_log_line("deny-open", pathname, flags, err);
            in_hook = 0;
        }
        errno = err;
        return -1;
    }

    if (flags & O_CREAT) {
        int fd = real_open_fn(pathname, flags, mode);
        track_fd(fd, pathname);
        return fd;
    }
    int fd = real_open_fn(pathname, flags);
    track_fd(fd, pathname);
    return fd;
}

int open64(const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    ensure_real_symbols();

    if (!in_hook) {
        in_hook = 1;
        write_log_line("open64", pathname, flags);
        in_hook = 0;
    }

    if (should_deny_path(pathname)) {
        int err = deny_errno_value();
        if (!in_hook) {
            in_hook = 1;
            write_deny_log_line("deny-open64", pathname, flags, err);
            in_hook = 0;
        }
        errno = err;
        return -1;
    }

    if (real_open64_fn == NULL) {
        return open(pathname, flags, mode);
    }
    if (flags & O_CREAT) {
        int fd = real_open64_fn(pathname, flags, mode);
        track_fd(fd, pathname);
        return fd;
    }
    int fd = real_open64_fn(pathname, flags);
    track_fd(fd, pathname);
    return fd;
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    ensure_real_symbols();

    if (!in_hook) {
        in_hook = 1;
        write_log_line("openat", pathname, flags);
        in_hook = 0;
    }

    if (should_deny_path(pathname)) {
        int err = deny_errno_value();
        if (!in_hook) {
            in_hook = 1;
            write_deny_log_line("deny-openat", pathname, flags, err);
            in_hook = 0;
        }
        errno = err;
        return -1;
    }

    if (flags & O_CREAT) {
        int fd = real_openat_fn(dirfd, pathname, flags, mode);
        track_fd(fd, pathname);
        return fd;
    }
    int fd = real_openat_fn(dirfd, pathname, flags);
    track_fd(fd, pathname);
    return fd;
}

int openat64(int dirfd, const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    ensure_real_symbols();

    if (!in_hook) {
        in_hook = 1;
        write_log_line("openat64", pathname, flags);
        in_hook = 0;
    }

    if (should_deny_path(pathname)) {
        int err = deny_errno_value();
        if (!in_hook) {
            in_hook = 1;
            write_deny_log_line("deny-openat64", pathname, flags, err);
            in_hook = 0;
        }
        errno = err;
        return -1;
    }

    if (real_openat64_fn == NULL) {
        return openat(dirfd, pathname, flags, mode);
    }
    if (flags & O_CREAT) {
        int fd = real_openat64_fn(dirfd, pathname, flags, mode);
        track_fd(fd, pathname);
        return fd;
    }
    int fd = real_openat64_fn(dirfd, pathname, flags);
    track_fd(fd, pathname);
    return fd;
}

int close(int fd) {
    ensure_real_symbols();
    clear_fd(fd);
    return real_close_fn(fd);
}

int ioctl(int fd, unsigned long request, ...) {
    void *arg = NULL;
    va_list ap;
    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);

    ensure_real_symbols();

    errno = 0;
    int result = real_ioctl_fn(fd, request, arg);
    int err = errno;

    if (!in_hook) {
        in_hook = 1;
        write_ioctl_log_line(fd, request, result, err);
        in_hook = 0;
    }

    errno = err;
    return result;
}
