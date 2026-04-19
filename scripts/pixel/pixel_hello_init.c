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
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef SHADOW_HELLO_INIT_CONFIG_PATH
#define SHADOW_HELLO_INIT_CONFIG_PATH "/shadow-init.cfg"
#endif

#define SHADOW_HELLO_INIT_TAG "shadow-hello-init"
#define SHADOW_HELLO_INIT_DEFAULT_HOLD_SECONDS 30U
#define SHADOW_HELLO_INIT_MAX_HOLD_SECONDS 3600U

static const char kOwnedInitRoleSentinel[] = "shadow-owned-init-role:hello-init";
static const char kOwnedInitImplSentinel[] = "shadow-owned-init-impl:c-static";
static const char kOwnedInitConfigSentinel[] =
    "shadow-owned-init-config:" SHADOW_HELLO_INIT_CONFIG_PATH;
static const char kOwnedInitMountsSentinel[] =
    "shadow-owned-init-mounts:/dev,/proc,/sys";

struct hello_init_config {
    char payload[32];
    unsigned int hold_seconds;
    char reboot_target[32];
};

static int shadow_kmsg_fd = -1;

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
}

static void ensure_kmsg_fd(void) {
    if (shadow_kmsg_fd >= 0) {
        return;
    }

    shadow_kmsg_fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC | O_NOCTTY);
}

static void log_kmsg(const char *level, const char *fmt, ...) {
    char message[512];
    int prefix_len;
    int payload_len;
    va_list args;

    ensure_kmsg_fd();
    if (shadow_kmsg_fd < 0) {
        return;
    }

    prefix_len = snprintf(message, sizeof(message), "%s[%s] ", level, SHADOW_HELLO_INIT_TAG);
    if (prefix_len < 0 || (size_t)prefix_len >= sizeof(message)) {
        return;
    }

    va_start(args, fmt);
    payload_len = vsnprintf(
        message + (size_t)prefix_len,
        sizeof(message) - (size_t)prefix_len,
        fmt,
        args
    );
    va_end(args);
    if (payload_len < 0) {
        return;
    }

    if ((size_t)(prefix_len + payload_len) >= sizeof(message) - 1) {
        message[sizeof(message) - 2] = '\n';
        message[sizeof(message) - 1] = '\0';
    } else {
        message[(size_t)prefix_len + (size_t)payload_len] = '\n';
        message[(size_t)prefix_len + (size_t)payload_len + 1] = '\0';
    }

    (void)write(shadow_kmsg_fd, message, strlen(message));
}

static int ensure_directory(const char *path, mode_t mode) {
    struct stat st;

    if (mkdir(path, mode) == 0) {
        return 0;
    }
    if (errno == EEXIST && stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
        return 0;
    }

    log_kmsg("<3>", "mkdir(%s) failed: errno=%d", path, errno);
    return -1;
}

static int mount_pseudofs(
    const char *source,
    const char *target,
    const char *fstype,
    unsigned long flags,
    const char *data
) {
    if (mount(source, target, fstype, flags, data) == 0 || errno == EBUSY) {
        log_kmsg("<6>", "mounted %s on %s as %s", source, target, fstype);
        return 0;
    }

    log_kmsg(
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

static void apply_config_value(
    struct hello_init_config *config,
    const char *key,
    const char *value
) {
    unsigned int parsed_hold_seconds;

    if (strcmp(key, "payload") == 0) {
        if (!copy_string(config->payload, sizeof(config->payload), value)) {
            log_kmsg("<4>", "payload value truncated to %zu bytes", sizeof(config->payload) - 1);
        }
        return;
    }

    if (strcmp(key, "hold_seconds") == 0 || strcmp(key, "hold_secs") == 0) {
        if (!parse_unsigned_value(value, &parsed_hold_seconds)) {
            log_kmsg("<3>", "invalid hold_seconds value: %s", value);
            return;
        }
        config->hold_seconds = parsed_hold_seconds;
        return;
    }

    if (strcmp(key, "reboot_target") == 0) {
        if (!copy_string(config->reboot_target, sizeof(config->reboot_target), value)) {
            log_kmsg(
                "<4>",
                "reboot_target value truncated to %zu bytes",
                sizeof(config->reboot_target) - 1
            );
        }
        return;
    }

    log_kmsg("<4>", "ignoring unknown config key: %s", key);
}

static void load_config(struct hello_init_config *config) {
    char buffer[1024];
    ssize_t bytes_read;
    int config_fd;
    char *line;
    char *saveptr = NULL;

    config_fd = open(SHADOW_HELLO_INIT_CONFIG_PATH, O_RDONLY | O_CLOEXEC);
    if (config_fd < 0) {
        log_kmsg("<4>", "config not found at %s; using defaults", SHADOW_HELLO_INIT_CONFIG_PATH);
        return;
    }

    bytes_read = read(config_fd, buffer, sizeof(buffer) - 1);
    close(config_fd);
    if (bytes_read < 0) {
        log_kmsg("<3>", "failed to read %s: errno=%d", SHADOW_HELLO_INIT_CONFIG_PATH, errno);
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
            log_kmsg("<4>", "ignoring config line without '=': %s", line);
            continue;
        }

        *separator = '\0';
        key = trim_whitespace(line);
        value = trim_whitespace(separator + 1);
        if (*key == '\0' || *value == '\0') {
            log_kmsg("<4>", "ignoring empty config assignment");
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
    unsigned int remaining = hold_seconds;

    if (remaining == 0) {
        log_kmsg("<6>", "hold_seconds=0; skipping observation hold");
        return;
    }

    log_kmsg("<6>", "holding for %u second(s)", remaining);
    while (remaining > 0) {
        unsigned int chunk = remaining > 5U ? 5U : remaining;
        sleep_seconds(chunk);
        remaining -= chunk;
        if (remaining > 0) {
            log_kmsg("<6>", "hold heartbeat: %u second(s) remaining", remaining);
        }
    }
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
    log_kmsg("<6>", "reboot target: %s", target);

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
        log_kmsg("<4>", "restart2 failed for target=%s; falling back to restart", target);
        (void)raw_reboot(LINUX_REBOOT_CMD_RESTART, NULL);
    }

    log_kmsg("<3>", "reboot syscall returned; sleeping forever");
    for (;;) {
        sleep_seconds(60);
    }
}

int main(void) {
    struct hello_init_config config;

    if (getpid() != 1) {
        return 1;
    }

    if (ensure_directory("/dev", 0755) != 0) {
        return 1;
    }
    if (mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755") != 0 && errno != EBUSY) {
        return 1;
    }

    log_kmsg("<6>", "mounted devtmpfs on /dev");
    log_kmsg("<6>", "starting owned PID 1");
    log_kmsg("<6>", "%s", kOwnedInitRoleSentinel);
    log_kmsg("<6>", "%s", kOwnedInitImplSentinel);
    log_kmsg("<6>", "%s", kOwnedInitConfigSentinel);
    log_kmsg("<6>", "%s", kOwnedInitMountsSentinel);

    if (ensure_directory("/proc", 0555) != 0) {
        return 1;
    }
    if (ensure_directory("/sys", 0555) != 0) {
        return 1;
    }

    if (mount_pseudofs("proc", "/proc", "proc", MS_NOSUID | MS_NOEXEC | MS_NODEV, "") != 0) {
        return 1;
    }
    if (mount_pseudofs("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NOEXEC | MS_NODEV, "") != 0) {
        return 1;
    }

    init_default_config(&config);
    load_config(&config);

    log_kmsg(
        "<6>",
        "config payload=%s hold_seconds=%u reboot_target=%s",
        config.payload,
        config.hold_seconds,
        config.reboot_target
    );
    log_kmsg("<6>", "payload '%s' is observation-only in hello-init", config.payload);

    hold_for_observation(config.hold_seconds);
    reboot_from_config(&config);
    return 0;
}
