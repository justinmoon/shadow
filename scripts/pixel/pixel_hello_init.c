#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <strings.h>
#include <string.h>
#include <stdint.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef SHADOW_HELLO_INIT_CONFIG_PATH
#define SHADOW_HELLO_INIT_CONFIG_PATH "/shadow-init.cfg"
#endif

#define SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH "/orange-init"
#define SHADOW_HELLO_INIT_ORANGE_MODE_ENV "SHADOW_DRM_RECT_MODE"
#define SHADOW_HELLO_INIT_ORANGE_HOLD_ENV "SHADOW_DRM_RECT_HOLD_SECS"

#define SHADOW_HELLO_INIT_TAG "shadow-hello-init"
#define SHADOW_HELLO_INIT_DEFAULT_HOLD_SECONDS 30U
#define SHADOW_HELLO_INIT_MAX_HOLD_SECONDS 3600U

static const char kOwnedInitRoleSentinel[] = "shadow-owned-init-role:hello-init";
static const char kOwnedInitImplSentinel[] = "shadow-owned-init-impl:c-static";
static const char kOwnedInitConfigSentinel[] =
    "shadow-owned-init-config:" SHADOW_HELLO_INIT_CONFIG_PATH;
static const char kOwnedInitMountsSentinelPrefix[] =
    "shadow-owned-init-mounts:";
static const char kOwnedInitRunTokenSentinelPrefix[] =
    "shadow-owned-init-run-token:";
static const char kOwnedInitOrangePayloadSentinel[] =
    "shadow-owned-init-payload-path:" SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH;

struct hello_init_config {
    char payload[32];
    unsigned int hold_seconds;
    char reboot_target[32];
    char run_token[64];
    char dev_mount[16];
    bool mount_dev;
    bool mount_proc;
    bool mount_sys;
    bool log_kmsg;
    bool log_pmsg;
};

static int shadow_kmsg_fd = -1;
static int shadow_pmsg_fd = -1;
static uint64_t shadow_boot_start_ms = 0;
static bool shadow_log_stdio = true;
static bool shadow_log_kmsg = false;
static bool shadow_log_pmsg = false;
static char shadow_run_token[64] = "";

static bool fd_is_open(int fd) {
    return fcntl(fd, F_GETFL) != -1 || errno != EBADF;
}

static bool fd_is_dev_null(int fd) {
    struct stat st;

    if (fstat(fd, &st) != 0) {
        return false;
    }

    return S_ISCHR(st.st_mode) &&
           major(st.st_rdev) == 1U &&
           minor(st.st_rdev) == 3U;
}

static bool stdio_is_available(void) {
    return fd_is_open(STDIN_FILENO) &&
           fd_is_open(STDOUT_FILENO) &&
           fd_is_open(STDERR_FILENO);
}

static bool copy_string(char *dest, size_t dest_size, const char *src) {
    size_t src_length;

    if (dest_size == 0) {
        return false;
    }

    if (src == NULL) {
        dest[0] = '\0';
        return true;
    }

    src_length = strlen(src);
    strncpy(dest, src, dest_size - 1);
    dest[dest_size - 1] = '\0';
    return src_length < dest_size;
}

static void init_default_config(struct hello_init_config *config) {
    (void)copy_string(config->payload, sizeof(config->payload), "hello");
    config->hold_seconds = SHADOW_HELLO_INIT_DEFAULT_HOLD_SECONDS;
    (void)copy_string(config->reboot_target, sizeof(config->reboot_target), "bootloader");
    config->run_token[0] = '\0';
    (void)copy_string(config->dev_mount, sizeof(config->dev_mount), "devtmpfs");
    config->mount_dev = true;
    config->mount_proc = true;
    config->mount_sys = true;
    config->log_kmsg = true;
    config->log_pmsg = true;
}

static const char *bool_word(bool value) {
    return value ? "true" : "false";
}

static uint64_t monotonic_millis(void) {
    struct timespec ts;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }

    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static const char *run_token_or_unset(void) {
    return shadow_run_token[0] != '\0' ? shadow_run_token : "unset";
}

static void ensure_kmsg_fd(void) {
    if (shadow_kmsg_fd >= 0) {
        return;
    }

    shadow_kmsg_fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC | O_NOCTTY);
}

static void ensure_pmsg_fd(void) {
    if (shadow_pmsg_fd >= 0) {
        return;
    }

    shadow_pmsg_fd = open("/dev/pmsg0", O_WRONLY | O_CLOEXEC | O_NOCTTY);
}

static void write_fd_all(int fd, const char *message) {
    size_t total = 0;
    size_t remaining = strlen(message);

    while (remaining > 0) {
        ssize_t written = write(fd, message + total, remaining);

        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return;
        }
        if (written == 0) {
            return;
        }

        total += (size_t)written;
        remaining -= (size_t)written;
    }
}

static void log_boot_v(const char *level, const char *fmt, va_list args) {
    char payload[448];
    char plain[512];
    char kmsg_line[512];
    int payload_len;
    int plain_len;
    int kmsg_len;
    va_list copy;

    va_copy(copy, args);
    payload_len = vsnprintf(payload, sizeof(payload), fmt, copy);
    va_end(copy);
    if (payload_len < 0) {
        return;
    }

    plain_len = snprintf(plain, sizeof(plain), "[%s] %s\n", SHADOW_HELLO_INIT_TAG, payload);
    if (plain_len < 0 || (size_t)plain_len >= sizeof(plain)) {
        return;
    }

    kmsg_len = snprintf(kmsg_line, sizeof(kmsg_line), "%s[%s] %s\n", level, SHADOW_HELLO_INIT_TAG, payload);
    if (kmsg_len < 0 || (size_t)kmsg_len >= sizeof(kmsg_line)) {
        return;
    }

    if (shadow_log_stdio) {
        write_fd_all(STDOUT_FILENO, plain);
        write_fd_all(STDERR_FILENO, plain);
    }

    if (shadow_log_kmsg) {
        ensure_kmsg_fd();
        if (shadow_kmsg_fd >= 0) {
            write_fd_all(shadow_kmsg_fd, kmsg_line);
        }
    }

    if (shadow_log_pmsg) {
        ensure_pmsg_fd();
        if (shadow_pmsg_fd >= 0) {
            write_fd_all(shadow_pmsg_fd, plain);
        }
    }
}

static void log_boot(const char *level, const char *fmt, ...) {
    va_list args;

    va_start(args, fmt);
    log_boot_v(level, fmt, args);
    va_end(args);
}

static void log_stage(const char *level, const char *stage, const char *fmt, ...) {
    char detail[320];
    uint64_t elapsed_ms;
    va_list args;

    if (shadow_boot_start_ms == 0) {
        shadow_boot_start_ms = monotonic_millis();
    }
    elapsed_ms = monotonic_millis();
    if (elapsed_ms >= shadow_boot_start_ms) {
        elapsed_ms -= shadow_boot_start_ms;
    } else {
        elapsed_ms = 0;
    }

    detail[0] = '\0';
    if (fmt != NULL && fmt[0] != '\0') {
        va_start(args, fmt);
        (void)vsnprintf(detail, sizeof(detail), fmt, args);
        va_end(args);
    }

    if (detail[0] != '\0') {
        log_boot(level, "trace_ms=%llu stage=%s %s", (unsigned long long)elapsed_ms, stage, detail);
        return;
    }

    log_boot(level, "trace_ms=%llu stage=%s", (unsigned long long)elapsed_ms, stage);
}

static void log_observability_status(void) {
    bool kmsg_available;
    bool pmsg_available;
    bool stdio_available;
    bool stdio_observable;
    const char *stdio_status;

    if (shadow_log_kmsg) {
        ensure_kmsg_fd();
    }
    if (shadow_log_pmsg) {
        ensure_pmsg_fd();
    }
    kmsg_available = !shadow_log_kmsg || shadow_kmsg_fd >= 0;
    pmsg_available = !shadow_log_pmsg || shadow_pmsg_fd >= 0;
    stdio_available = stdio_is_available();
    stdio_observable = stdio_available &&
                       !fd_is_dev_null(STDOUT_FILENO) &&
                       !fd_is_dev_null(STDERR_FILENO);
    if (!stdio_available) {
        stdio_status = "false";
    } else if (!stdio_observable) {
        stdio_status = "dev-null";
    } else {
        stdio_status = "true";
    }

    log_boot(
        "<6>",
        "shadow-owned-init-observability:kmsg=%s,pmsg=%s,stdio=%s,run_token=%s",
        shadow_log_kmsg ? bool_word(kmsg_available) : "disabled",
        shadow_log_pmsg ? bool_word(pmsg_available) : "disabled",
        stdio_status,
        run_token_or_unset()
    );
    if (!kmsg_available || !pmsg_available || !stdio_observable) {
        log_stage(
            "<4>",
            "observability-degraded",
            "kmsg=%s pmsg=%s stdio=%s run_token=%s",
            bool_word(kmsg_available),
            bool_word(pmsg_available),
            stdio_status,
            run_token_or_unset()
        );
    }
}

static int ensure_directory(const char *path, mode_t mode) {
    struct stat st;

    if (mkdir(path, mode) == 0) {
        return 0;
    }
    if (errno == EEXIST && stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
        return 0;
    }

    log_boot("<3>", "mkdir(%s) failed: errno=%d", path, errno);
    return -1;
}

static int ensure_char_device(
    const char *path,
    mode_t mode,
    unsigned int major_num,
    unsigned int minor_num
) {
    struct stat st;
    dev_t expected_device;
    mode_t old_umask;

    expected_device = makedev(major_num, minor_num);

    if (lstat(path, &st) == 0) {
        if (S_ISCHR(st.st_mode) && st.st_rdev == expected_device) {
            return 0;
        }

        log_boot(
            "<3>",
            "device path %s exists with unexpected mode=%o rdev=%llu:%llu",
            path,
            st.st_mode,
            (unsigned long long)major(st.st_rdev),
            (unsigned long long)minor(st.st_rdev)
        );
        return -1;
    }
    if (errno != ENOENT) {
        log_boot("<3>", "lstat(%s) failed: errno=%d", path, errno);
        return -1;
    }

    old_umask = umask(0);
    if (mknod(path, S_IFCHR | mode, expected_device) != 0 && errno != EEXIST) {
        int saved_errno = errno;

        (void)umask(old_umask);
        log_boot(
            "<3>",
            "mknod(%s major=%u minor=%u) failed: errno=%d",
            path,
            major_num,
            minor_num,
            saved_errno
        );
        return -1;
    }
    (void)umask(old_umask);

    if (lstat(path, &st) != 0) {
        log_boot("<3>", "post-mknod lstat(%s) failed: errno=%d", path, errno);
        return -1;
    }
    if (!S_ISCHR(st.st_mode) || st.st_rdev != expected_device) {
        log_boot(
            "<3>",
            "device path %s did not resolve to expected char device %u:%u",
            path,
            major_num,
            minor_num
        );
        return -1;
    }

    return 0;
}

static int ensure_symlink_target(const char *path, const char *target) {
    struct stat st;
    char actual_target[64];
    ssize_t actual_length;

    if (lstat(path, &st) == 0) {
        if (!S_ISLNK(st.st_mode)) {
            log_boot("<3>", "path %s exists and is not a symlink", path);
            return -1;
        }

        actual_length = readlink(path, actual_target, sizeof(actual_target) - 1);
        if (actual_length < 0) {
            log_boot("<3>", "readlink(%s) failed: errno=%d", path, errno);
            return -1;
        }
        actual_target[actual_length] = '\0';
        if (strcmp(actual_target, target) == 0) {
            return 0;
        }

        log_boot(
            "<3>",
            "symlink %s points to %s, expected %s",
            path,
            actual_target,
            target
        );
        return -1;
    }
    if (errno != ENOENT) {
        log_boot("<3>", "lstat(%s) failed: errno=%d", path, errno);
        return -1;
    }

    if (symlink(target, path) != 0 && errno != EEXIST) {
        log_boot("<3>", "symlink(%s -> %s) failed: errno=%d", path, target, errno);
        return -1;
    }

    return 0;
}

static void ensure_stdio_fds(void) {
    int null_fd;

    if (stdio_is_available()) {
        return;
    }

    null_fd = open("/dev/null", O_RDWR | O_CLOEXEC | O_NOCTTY);
    if (null_fd < 0) {
        return;
    }

    if (!fd_is_open(STDIN_FILENO)) {
        (void)dup2(null_fd, STDIN_FILENO);
    }
    if (!fd_is_open(STDOUT_FILENO)) {
        (void)dup2(null_fd, STDOUT_FILENO);
    }
    if (!fd_is_open(STDERR_FILENO)) {
        (void)dup2(null_fd, STDERR_FILENO);
    }

    if (null_fd > STDERR_FILENO) {
        close(null_fd);
    }
}

static int bootstrap_tmpfs_dev_runtime(const struct hello_init_config *config) {
    if (!config->mount_dev || strcmp(config->dev_mount, "tmpfs") != 0) {
        return 0;
    }

    if (ensure_char_device("/dev/null", 0666, 1U, 3U) != 0) {
        return -1;
    }
    if (ensure_char_device("/dev/console", 0600, 5U, 1U) != 0) {
        return -1;
    }
    if (config->log_kmsg && ensure_char_device("/dev/kmsg", 0600, 1U, 11U) != 0) {
        return -1;
    }
    if (config->log_pmsg && ensure_char_device("/dev/pmsg0", 0222, 250U, 0U) != 0) {
        return -1;
    }

    ensure_stdio_fds();
    return 0;
}

static int bootstrap_proc_stdio_links(const struct hello_init_config *config) {
    if (!config->mount_dev || !config->mount_proc || strcmp(config->dev_mount, "tmpfs") != 0) {
        return 0;
    }

    if (ensure_symlink_target("/dev/stdin", "/proc/self/fd/0") != 0) {
        return -1;
    }
    if (ensure_symlink_target("/dev/stdout", "/proc/self/fd/1") != 0) {
        return -1;
    }
    if (ensure_symlink_target("/dev/stderr", "/proc/self/fd/2") != 0) {
        return -1;
    }

    return 0;
}

static int mount_pseudofs(
    const char *source,
    const char *target,
    const char *fstype,
    unsigned long flags,
    const char *data
) {
    if (mount(source, target, fstype, flags, data) == 0 || errno == EBUSY) {
        log_boot("<6>", "mounted %s on %s as %s", source, target, fstype);
        return 0;
    }

    log_boot(
        "<3>",
        "mount(%s -> %s type=%s) failed: errno=%d",
        source,
        target,
        fstype,
        errno
    );
    return -1;
}

static char *trim_whitespace(char *value) {
    char *end;

    while (*value != '\0' && isspace((unsigned char)*value)) {
        value++;
    }

    end = value + strlen(value);
    while (end > value && isspace((unsigned char)end[-1])) {
        end--;
    }
    *end = '\0';

    return value;
}

static bool parse_unsigned_value(const char *raw, unsigned int *parsed) {
    char *end = NULL;
    unsigned long value;

    errno = 0;
    value = strtoul(raw, &end, 10);
    if (errno != 0 || end == raw || *trim_whitespace(end) != '\0') {
        return false;
    }
    if (value > SHADOW_HELLO_INIT_MAX_HOLD_SECONDS) {
        return false;
    }

    *parsed = (unsigned int)value;
    return true;
}

static bool parse_bool_value(const char *raw, bool *parsed) {
    char buffer[16];
    char *value;

    if (!copy_string(buffer, sizeof(buffer), raw)) {
        return false;
    }

    value = trim_whitespace(buffer);
    if (
        strcmp(value, "1") == 0 ||
        strcasecmp(value, "true") == 0 ||
        strcasecmp(value, "yes") == 0 ||
        strcasecmp(value, "on") == 0
    ) {
        *parsed = true;
        return true;
    }

    if (
        strcmp(value, "0") == 0 ||
        strcasecmp(value, "false") == 0 ||
        strcasecmp(value, "no") == 0 ||
        strcasecmp(value, "off") == 0
    ) {
        *parsed = false;
        return true;
    }

    return false;
}

static bool parse_dev_mount_value(const char *raw, char *dest, size_t dest_size) {
    char buffer[16];
    char *value;

    if (!copy_string(buffer, sizeof(buffer), raw)) {
        return false;
    }

    value = trim_whitespace(buffer);
    if (strcmp(value, "devtmpfs") != 0 && strcmp(value, "tmpfs") != 0) {
        return false;
    }

    return copy_string(dest, dest_size, value);
}

static bool parse_run_token_value(const char *raw, char *dest, size_t dest_size) {
    char buffer[64];
    char *value;
    size_t index;

    if (!copy_string(buffer, sizeof(buffer), raw)) {
        return false;
    }

    value = trim_whitespace(buffer);
    if (*value == '\0') {
        return false;
    }

    for (index = 0; value[index] != '\0'; index++) {
        unsigned char ch = (unsigned char)value[index];

        if (!isalnum(ch) && ch != '.' && ch != '_' && ch != '-') {
            return false;
        }
    }

    return copy_string(dest, dest_size, value);
}

static void apply_config_value(
    struct hello_init_config *config,
    const char *key,
    const char *value
) {
    unsigned int parsed_hold_seconds;
    bool parsed_bool;

    if (strcmp(key, "payload") == 0) {
        if (!copy_string(config->payload, sizeof(config->payload), value)) {
            log_boot("<4>", "payload value truncated to %zu bytes", sizeof(config->payload) - 1);
        }
        return;
    }

    if (strcmp(key, "hold_seconds") == 0 || strcmp(key, "hold_secs") == 0) {
        if (!parse_unsigned_value(value, &parsed_hold_seconds)) {
            log_boot("<3>", "invalid hold_seconds value: %s", value);
            return;
        }
        config->hold_seconds = parsed_hold_seconds;
        return;
    }

    if (strcmp(key, "reboot_target") == 0) {
        if (!copy_string(config->reboot_target, sizeof(config->reboot_target), value)) {
            log_boot(
                "<4>",
                "reboot_target value truncated to %zu bytes",
                sizeof(config->reboot_target) - 1
            );
        }
        return;
    }

    if (strcmp(key, "run_token") == 0) {
        if (!parse_run_token_value(value, config->run_token, sizeof(config->run_token))) {
            log_boot("<3>", "invalid run_token value: %s", value);
            return;
        }
        return;
    }

    if (strcmp(key, "mount_dev") == 0 || strcmp(key, "mount_devtmpfs") == 0) {
        if (!parse_bool_value(value, &parsed_bool)) {
            log_boot("<3>", "invalid mount_dev value: %s", value);
            return;
        }
        config->mount_dev = parsed_bool;
        return;
    }

    if (strcmp(key, "dev_mount") == 0 || strcmp(key, "dev_mount_style") == 0) {
        if (!parse_dev_mount_value(value, config->dev_mount, sizeof(config->dev_mount))) {
            log_boot("<3>", "invalid dev_mount value: %s", value);
            return;
        }
        return;
    }

    if (strcmp(key, "mount_proc") == 0) {
        if (!parse_bool_value(value, &parsed_bool)) {
            log_boot("<3>", "invalid mount_proc value: %s", value);
            return;
        }
        config->mount_proc = parsed_bool;
        return;
    }

    if (strcmp(key, "mount_sys") == 0) {
        if (!parse_bool_value(value, &parsed_bool)) {
            log_boot("<3>", "invalid mount_sys value: %s", value);
            return;
        }
        config->mount_sys = parsed_bool;
        return;
    }

    if (strcmp(key, "log_kmsg") == 0) {
        if (!parse_bool_value(value, &parsed_bool)) {
            log_boot("<3>", "invalid log_kmsg value: %s", value);
            return;
        }
        config->log_kmsg = parsed_bool;
        return;
    }

    if (strcmp(key, "log_pmsg") == 0) {
        if (!parse_bool_value(value, &parsed_bool)) {
            log_boot("<3>", "invalid log_pmsg value: %s", value);
            return;
        }
        config->log_pmsg = parsed_bool;
        return;
    }

    log_boot("<4>", "ignoring unknown config key: %s", key);
}

static void load_config(struct hello_init_config *config) {
    char buffer[1024];
    ssize_t bytes_read;
    int config_fd;
    char *line;
    char *saveptr = NULL;

    config_fd = open(SHADOW_HELLO_INIT_CONFIG_PATH, O_RDONLY | O_CLOEXEC);
    if (config_fd < 0) {
        log_boot("<4>", "config not found at %s; using defaults", SHADOW_HELLO_INIT_CONFIG_PATH);
        return;
    }

    bytes_read = read(config_fd, buffer, sizeof(buffer) - 1);
    close(config_fd);
    if (bytes_read < 0) {
        log_boot("<3>", "failed to read %s: errno=%d", SHADOW_HELLO_INIT_CONFIG_PATH, errno);
        return;
    }

    buffer[bytes_read] = '\0';
    for (line = strtok_r(buffer, "\n", &saveptr); line != NULL; line = strtok_r(NULL, "\n", &saveptr)) {
        char *key;
        char *value;
        char *separator;

        line = trim_whitespace(line);
        if (*line == '\0' || *line == '#') {
            continue;
        }

        separator = strchr(line, '=');
        if (separator == NULL) {
            log_boot("<4>", "ignoring config line without '=': %s", line);
            continue;
        }

        *separator = '\0';
        key = trim_whitespace(line);
        value = trim_whitespace(separator + 1);
        if (*key == '\0' || *value == '\0') {
            log_boot("<4>", "ignoring empty config assignment");
            continue;
        }

        apply_config_value(config, key, value);
    }
}

static void sleep_seconds(unsigned int seconds) {
    struct timespec request;
    struct timespec remaining;

    request.tv_sec = (time_t)seconds;
    request.tv_nsec = 0;

    while (nanosleep(&request, &remaining) != 0) {
        if (errno != EINTR) {
            return;
        }
        request = remaining;
    }
}

static void hold_for_observation(unsigned int hold_seconds) {
    const unsigned int heartbeat_interval = 10U;
    unsigned int remaining = hold_seconds;
    unsigned int elapsed = 0;

    if (remaining == 0) {
        log_stage("<6>", "hold-skip", "reason=hold_seconds_zero");
        log_boot("<6>", "hold_seconds=0; skipping observation hold");
        return;
    }

    log_stage("<6>", "hold-start", "seconds=%u", remaining);
    log_boot("<6>", "holding for %u second(s)", remaining);
    while (remaining > 0) {
        unsigned int chunk = remaining > 5U ? 5U : remaining;
        sleep_seconds(chunk);
        remaining -= chunk;
        elapsed += chunk;
        if (remaining > 0 && elapsed % heartbeat_interval == 0) {
            log_stage("<6>", "hold-heartbeat", "seconds_remaining=%u", remaining);
        }
    }
    log_stage("<6>", "hold-complete", "seconds=%u", hold_seconds);
}

static bool payload_is_orange_init(const struct hello_init_config *config) {
    return strcmp(config->payload, "orange-init") == 0;
}

static int run_orange_init_payload(const struct hello_init_config *config) {
    pid_t child_pid;
    int status;
    char hold_seconds[16];
    unsigned int waited_seconds = 0;

    log_stage(
        "<6>",
        "orange-launch",
        "path=%s hold_seconds=%u",
        SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
        config->hold_seconds
    );
    log_boot("<6>", "%s", kOwnedInitOrangePayloadSentinel);
    log_boot("<6>", "launching payload %s", SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH);

    child_pid = fork();
    if (child_pid < 0) {
        log_stage("<3>", "orange-fork-failed", "errno=%d", errno);
        log_boot("<3>", "fork for %s failed: errno=%d", SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH, errno);
        return 1;
    }
    if (child_pid > 0) {
        log_stage("<6>", "orange-forked", "pid=%d", child_pid);
    }

    if (child_pid == 0) {
        if (snprintf(hold_seconds, sizeof(hold_seconds), "%u", config->hold_seconds) <= 0) {
            log_stage("<3>", "orange-child-hold-format-failed", "status=126");
            _exit(126);
        }
        if (setenv(SHADOW_HELLO_INIT_ORANGE_MODE_ENV, "orange-init", 1) != 0) {
            log_stage("<3>", "orange-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_ORANGE_MODE_ENV, errno);
            _exit(126);
        }
        if (setenv(SHADOW_HELLO_INIT_ORANGE_HOLD_ENV, hold_seconds, 1) != 0) {
            log_stage("<3>", "orange-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_ORANGE_HOLD_ENV, errno);
            _exit(126);
        }
        log_stage("<6>", "orange-child-exec", "argv0=%s", SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH);
        execl(
            SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
            SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
            (char *)NULL
        );
        log_stage("<3>", "orange-exec-failed", "errno=%d", errno);
        log_boot("<3>", "exec %s failed: errno=%d", SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH, errno);
        _exit(127);
    }

    for (;;) {
        pid_t waited = waitpid(child_pid, &status, WNOHANG);

        if (waited == child_pid) {
            break;
        }
        if (waited == 0) {
            sleep_seconds(5);
            waited_seconds += 5;
            log_stage("<6>", "orange-wait", "pid=%d seconds=%u", child_pid, waited_seconds);
            continue;
        }
        if (errno != EINTR) {
            log_stage("<3>", "orange-waitpid-failed", "pid=%d errno=%d", child_pid, errno);
            log_boot("<3>", "waitpid(%d) failed: errno=%d", child_pid, errno);
            return 1;
        }
    }

    if (WIFEXITED(status)) {
        log_stage("<6>", "orange-exit", "status=%d", WEXITSTATUS(status));
        log_boot(
            "<6>",
            "payload %s exited with status=%d",
            SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
            WEXITSTATUS(status)
        );
        return WEXITSTATUS(status) == 0 ? 0 : WEXITSTATUS(status);
    }

    if (WIFSIGNALED(status)) {
        log_stage("<3>", "orange-signal", "signal=%d", WTERMSIG(status));
        log_boot(
            "<3>",
            "payload %s died from signal=%d",
            SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
            WTERMSIG(status)
        );
        return 128 + WTERMSIG(status);
    }

    log_stage("<4>", "orange-unknown-status", "status=%d", status);
    log_boot("<4>", "payload %s returned unknown wait status=%d", SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH, status);
    return 1;
}

static int raw_reboot(unsigned int cmd, const char *arg) {
    return (int)syscall(
        SYS_reboot,
        LINUX_REBOOT_MAGIC1,
        LINUX_REBOOT_MAGIC2,
        cmd,
        arg
    );
}

static void reboot_from_config(const struct hello_init_config *config) {
    const char *target = config->reboot_target;

    sync();
    log_stage("<6>", "reboot-request", "target=%s", target);
    log_boot("<6>", "reboot target: %s", target);

    if (strcmp(target, "halt") == 0) {
        (void)raw_reboot(LINUX_REBOOT_CMD_HALT, NULL);
    } else if (strcmp(target, "poweroff") == 0) {
        (void)raw_reboot(LINUX_REBOOT_CMD_POWER_OFF, NULL);
    } else if (strcmp(target, "restart") == 0 || strcmp(target, "reboot") == 0) {
        (void)raw_reboot(LINUX_REBOOT_CMD_RESTART, NULL);
    } else {
        if (raw_reboot(LINUX_REBOOT_CMD_RESTART2, target) == 0) {
            return;
        }
        log_stage("<4>", "reboot-fallback", "target=%s", target);
        log_boot("<4>", "restart2 failed for target=%s; falling back to restart", target);
        (void)raw_reboot(LINUX_REBOOT_CMD_RESTART, NULL);
    }

    log_stage("<3>", "reboot-returned", "target=%s", target);
    log_boot("<3>", "reboot syscall returned; sleeping forever");
    for (;;) {
        sleep_seconds(60);
    }
}

int main(void) {
    struct hello_init_config config;
    int payload_status;

    shadow_boot_start_ms = monotonic_millis();
    if (getpid() != 1) {
        return 1;
    }

    init_default_config(&config);
    load_config(&config);
    (void)copy_string(shadow_run_token, sizeof(shadow_run_token), config.run_token);
    shadow_log_kmsg = config.log_kmsg;
    shadow_log_pmsg = config.log_pmsg;

    if (config.mount_dev) {
        if (ensure_directory("/dev", 0755) != 0) {
            return 1;
        }
        if (mount(config.dev_mount, "/dev", config.dev_mount, MS_NOSUID, "mode=0755") != 0 && errno != EBUSY) {
            return 1;
        }
        if (bootstrap_tmpfs_dev_runtime(&config) != 0) {
            return 1;
        }
        log_boot("<6>", "mounted %s on /dev", config.dev_mount);
    }

    log_boot("<6>", "starting owned PID 1");
    log_stage("<6>", "pid1-start", "pid=%d", getpid());
    log_boot("<6>", "%s", kOwnedInitRoleSentinel);
    log_boot("<6>", "%s", kOwnedInitImplSentinel);
    log_boot("<6>", "%s", kOwnedInitConfigSentinel);
    log_boot(
        "<6>",
        "%sdev=%s,proc=%s,sys=%s",
        kOwnedInitMountsSentinelPrefix,
        bool_word(config.mount_dev),
        bool_word(config.mount_proc),
        bool_word(config.mount_sys)
    );
    log_boot("<6>", "%s%s", kOwnedInitRunTokenSentinelPrefix, run_token_or_unset());
    log_observability_status();

    if (config.mount_proc) {
        if (ensure_directory("/proc", 0555) != 0) {
            return 1;
        }
        if (mount_pseudofs("proc", "/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, "") != 0) {
            return 1;
        }
        if (bootstrap_proc_stdio_links(&config) != 0) {
            return 1;
        }
    }

    if (config.mount_sys) {
        if (ensure_directory("/sys", 0555) != 0) {
            return 1;
        }
        if (mount_pseudofs("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NOEXEC | MS_NODEV, "") != 0) {
            return 1;
        }
    }
    log_stage(
        "<6>",
        "pseudofs-mounted",
        "proc=%s sys=%s",
        bool_word(config.mount_proc),
        bool_word(config.mount_sys)
    );

    log_stage(
        "<6>",
        "config-loaded",
        "payload=%s hold_seconds=%u reboot_target=%s run_token=%s dev_mount=%s mount_dev=%s mount_proc=%s mount_sys=%s log_kmsg=%s log_pmsg=%s",
        config.payload,
        config.hold_seconds,
        config.reboot_target,
        run_token_or_unset(),
        config.dev_mount,
        bool_word(config.mount_dev),
        bool_word(config.mount_proc),
        bool_word(config.mount_sys),
        bool_word(config.log_kmsg),
        bool_word(config.log_pmsg)
    );
    log_boot(
        "<6>",
        "config payload=%s hold_seconds=%u reboot_target=%s run_token=%s dev_mount=%s mount_dev=%s mount_proc=%s mount_sys=%s log_kmsg=%s log_pmsg=%s",
        config.payload,
        config.hold_seconds,
        config.reboot_target,
        run_token_or_unset(),
        config.dev_mount,
        bool_word(config.mount_dev),
        bool_word(config.mount_proc),
        bool_word(config.mount_sys),
        bool_word(config.log_kmsg),
        bool_word(config.log_pmsg)
    );
    if (payload_is_orange_init(&config)) {
        log_stage("<6>", "payload-dispatch", "payload=orange-init");
        payload_status = run_orange_init_payload(&config);
        if (payload_status != 0) {
            log_stage(
                "<4>",
                "payload-failed",
                "payload=orange-init status=%d hold_seconds=%u",
                payload_status,
                config.hold_seconds
            );
            log_boot(
                "<4>",
                "orange-init payload failed with status=%d; holding for observation before reboot",
                payload_status
            );
            hold_for_observation(config.hold_seconds);
        }
    } else {
        log_stage("<6>", "payload-observation-only", "payload=%s", config.payload);
        log_boot("<6>", "payload '%s' is observation-only in hello-init", config.payload);
        hold_for_observation(config.hold_seconds);
    }
    reboot_from_config(&config);
    return 0;
}
