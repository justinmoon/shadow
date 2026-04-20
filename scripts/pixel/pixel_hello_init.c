#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <signal.h>
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
#define SHADOW_HELLO_INIT_ORANGE_GPU_ROOT "/orange-gpu"
#define SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH "/orange-gpu/shadow-gpu-smoke"
#define SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH "/orange-gpu/lib/ld-linux-aarch64.so.1"
#define SHADOW_HELLO_INIT_ORANGE_GPU_LIBRARY_PATH "/orange-gpu/lib"
#define SHADOW_HELLO_INIT_ORANGE_GPU_ICD_PATH "/orange-gpu/share/vulkan/icd.d/freedreno_icd.aarch64.json"
#define SHADOW_HELLO_INIT_ORANGE_GPU_HOME "/orange-gpu/home"
#define SHADOW_HELLO_INIT_ORANGE_GPU_CACHE_HOME "/orange-gpu/home/.cache"
#define SHADOW_HELLO_INIT_ORANGE_GPU_CONFIG_HOME "/orange-gpu/home/.config"
#define SHADOW_HELLO_INIT_ORANGE_GPU_MESA_CACHE_DIR "/orange-gpu/home/.cache/mesa"
#define SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH "/orange-gpu/summary.json"
#define SHADOW_HELLO_INIT_ORANGE_GPU_OUTPUT_PATH "/orange-gpu/output.log"
#define SHADOW_HELLO_INIT_GPU_BACKEND_ENV "WGPU_BACKEND"
#define SHADOW_HELLO_INIT_VK_ICD_FILENAMES_ENV "VK_ICD_FILENAMES"
#define SHADOW_HELLO_INIT_MESA_DRIVER_OVERRIDE_ENV "MESA_LOADER_DRIVER_OVERRIDE"
#define SHADOW_HELLO_INIT_TU_DEBUG_ENV "TU_DEBUG"
#define SHADOW_HELLO_INIT_HOME_ENV "HOME"
#define SHADOW_HELLO_INIT_XDG_CACHE_HOME_ENV "XDG_CACHE_HOME"
#define SHADOW_HELLO_INIT_XDG_CONFIG_HOME_ENV "XDG_CONFIG_HOME"
#define SHADOW_HELLO_INIT_MESA_SHADER_CACHE_ENV "MESA_SHADER_CACHE_DIR"

#define SHADOW_HELLO_INIT_TAG "shadow-hello-init"
#define SHADOW_HELLO_INIT_DEFAULT_HOLD_SECONDS 30U
#define SHADOW_HELLO_INIT_MAX_HOLD_SECONDS 3600U
#define SHADOW_HELLO_INIT_ORANGE_GPU_WATCHDOG_GRACE_SECONDS 30U
#define SHADOW_HELLO_INIT_ORANGE_GPU_CHECKPOINT_HOLD_SECONDS 1U

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
static const char kOwnedInitOrangeGpuPayloadSentinel[] =
    "shadow-owned-init-payload-path:" SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH;

struct hello_init_config {
    char payload[32];
    char prelude[32];
    char orange_gpu_mode[32];
    bool orange_gpu_mode_seen;
    bool orange_gpu_mode_invalid;
    unsigned int hold_seconds;
    unsigned int prelude_hold_seconds;
    char reboot_target[32];
    char run_token[64];
    char dev_mount[16];
    char dri_bootstrap[48];
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
    (void)copy_string(config->prelude, sizeof(config->prelude), "none");
    (void)copy_string(config->orange_gpu_mode, sizeof(config->orange_gpu_mode), "gpu-render");
    config->orange_gpu_mode_seen = false;
    config->orange_gpu_mode_invalid = false;
    config->hold_seconds = SHADOW_HELLO_INIT_DEFAULT_HOLD_SECONDS;
    config->prelude_hold_seconds = 0U;
    (void)copy_string(config->reboot_target, sizeof(config->reboot_target), "bootloader");
    config->run_token[0] = '\0';
    (void)copy_string(config->dev_mount, sizeof(config->dev_mount), "devtmpfs");
    (void)copy_string(config->dri_bootstrap, sizeof(config->dri_bootstrap), "none");
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

static int bootstrap_tmpfs_dri_runtime(const struct hello_init_config *config) {
    if (!config->mount_dev || strcmp(config->dev_mount, "tmpfs") != 0) {
        return 0;
    }

    if (strcmp(config->dri_bootstrap, "none") == 0) {
        log_stage("<6>", "tmpfs-coldboot-skip", "reason=dri_bootstrap_none");
        return 0;
    }

    if (
        strcmp(config->dri_bootstrap, "sunfish-card0-renderD128") != 0 &&
        strcmp(config->dri_bootstrap, "sunfish-card0-renderD128-kgsl3d0") != 0
    ) {
        log_boot("<3>", "unsupported dri_bootstrap value: %s", config->dri_bootstrap);
        return -1;
    }

    log_stage("<6>", "tmpfs-coldboot-start", "mode=%s", config->dri_bootstrap);

    if (ensure_directory("/dev/dri", 0755) != 0) {
        return -1;
    }
    if (ensure_char_device("/dev/dri/card0", 0600, 226U, 0U) != 0) {
        return -1;
    }
    if (ensure_char_device("/dev/dri/renderD128", 0600, 226U, 128U) != 0) {
        return -1;
    }
    if (
        strcmp(config->dri_bootstrap, "sunfish-card0-renderD128-kgsl3d0") == 0 &&
        ensure_char_device("/dev/kgsl-3d0", 0666, 508U, 0U) != 0
    ) {
        return -1;
    }

    if (strcmp(config->dri_bootstrap, "sunfish-card0-renderD128-kgsl3d0") == 0) {
        log_stage(
            "<6>",
            "tmpfs-coldboot-complete",
            "mode=%s card0=226:0 renderD128=226:128 kgsl3d0=508:0",
            config->dri_bootstrap
        );
    } else {
        log_stage(
            "<6>",
            "tmpfs-coldboot-complete",
            "mode=%s card0=226:0 renderD128=226:128",
            config->dri_bootstrap
        );
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

static bool parse_dri_bootstrap_value(const char *raw, char *dest, size_t dest_size) {
    char buffer[48];
    char *value;

    if (!copy_string(buffer, sizeof(buffer), raw)) {
        return false;
    }

    value = trim_whitespace(buffer);
    if (
        strcmp(value, "none") != 0 &&
        strcmp(value, "sunfish-card0-renderD128") != 0 &&
        strcmp(value, "sunfish-card0-renderD128-kgsl3d0") != 0
    ) {
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

static bool parse_prelude_value(const char *raw, char *dest, size_t dest_size) {
    char buffer[32];
    char *value;

    if (!copy_string(buffer, sizeof(buffer), raw)) {
        return false;
    }

    value = trim_whitespace(buffer);
    if (strcmp(value, "none") != 0 && strcmp(value, "orange-init") != 0) {
        return false;
    }

    return copy_string(dest, dest_size, value);
}

static bool parse_orange_gpu_mode_value(const char *raw, char *dest, size_t dest_size) {
    char buffer[32];
    char *value;

    if (!copy_string(buffer, sizeof(buffer), raw)) {
        return false;
    }

    value = trim_whitespace(buffer);
    if (
        strcmp(value, "gpu-render") != 0 &&
        strcmp(value, "bundle-smoke") != 0 &&
        strcmp(value, "vulkan-device-request-smoke") != 0 &&
        strcmp(value, "vulkan-device-smoke") != 0 &&
        strcmp(value, "vulkan-offscreen") != 0
    ) {
        return false;
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

    if (strcmp(key, "prelude") == 0) {
        if (!parse_prelude_value(value, config->prelude, sizeof(config->prelude))) {
            log_boot("<3>", "invalid prelude value: %s", value);
            return;
        }
        return;
    }

    if (strcmp(key, "orange_gpu_mode") == 0 || strcmp(key, "orange-gpu-mode") == 0) {
        if (
            !parse_orange_gpu_mode_value(
                value,
                config->orange_gpu_mode,
                sizeof(config->orange_gpu_mode)
            )
        ) {
            config->orange_gpu_mode_invalid = true;
            log_boot("<3>", "invalid orange_gpu_mode value: %s", value);
            return;
        }
        config->orange_gpu_mode_seen = true;
        config->orange_gpu_mode_invalid = false;
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

    if (strcmp(key, "prelude_hold_seconds") == 0 || strcmp(key, "prelude_hold_secs") == 0) {
        if (!parse_unsigned_value(value, &parsed_hold_seconds)) {
            log_boot("<3>", "invalid prelude_hold_seconds value: %s", value);
            return;
        }
        config->prelude_hold_seconds = parsed_hold_seconds;
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

    if (strcmp(key, "dri_bootstrap") == 0) {
        if (
            !parse_dri_bootstrap_value(
                value,
                config->dri_bootstrap,
                sizeof(config->dri_bootstrap)
            )
        ) {
            log_boot("<3>", "invalid dri_bootstrap value: %s", value);
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

static bool payload_is_orange_gpu(const struct hello_init_config *config) {
    return strcmp(config->payload, "orange-gpu") == 0;
}

static bool orange_gpu_mode_is_bundle_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "bundle-smoke") == 0;
}

static bool orange_gpu_mode_is_vulkan_offscreen(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "vulkan-offscreen") == 0;
}

static bool orange_gpu_mode_is_vulkan_device_request_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "vulkan-device-request-smoke") == 0;
}

static bool orange_gpu_mode_is_vulkan_device_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "vulkan-device-smoke") == 0;
}

static bool orange_gpu_mode_uses_success_postlude(const struct hello_init_config *config) {
    return orange_gpu_mode_is_bundle_smoke(config) ||
           orange_gpu_mode_is_vulkan_device_request_smoke(config) ||
           orange_gpu_mode_is_vulkan_device_smoke(config) ||
           orange_gpu_mode_is_vulkan_offscreen(config);
}

static bool validate_orange_gpu_config(const struct hello_init_config *config) {
    if (!config->orange_gpu_mode_seen) {
        log_stage("<3>", "orange-gpu-config-missing-mode", "payload=%s", config->payload);
        log_boot("<3>", "missing required orange_gpu_mode config for payload=orange-gpu");
        return false;
    }
    if (config->orange_gpu_mode_invalid) {
        log_stage("<3>", "orange-gpu-config-invalid-mode", "payload=%s", config->payload);
        log_boot("<3>", "invalid orange_gpu_mode config for payload=orange-gpu");
        return false;
    }
    return true;
}

static bool prelude_is_orange_init(const struct hello_init_config *config) {
    return strcmp(config->prelude, "orange-init") == 0;
}

static void unlink_best_effort(const char *path) {
    if (unlink(path) == 0 || errno == ENOENT) {
        return;
    }

    log_boot("<4>", "unlink(%s) failed: errno=%d", path, errno);
}

static void trim_line_endings(char *buffer) {
    size_t length;

    length = strlen(buffer);
    while (length > 0 && (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) {
        buffer[length - 1] = '\0';
        length--;
    }
}

static void log_file_best_effort(const char *label, const char *path) {
    FILE *fp;
    char line[512];
    unsigned int line_count = 0;

    fp = fopen(path, "r");
    if (fp == NULL) {
        log_stage("<4>", "payload-artifact-missing", "label=%s path=%s errno=%d", label, path, errno);
        return;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        trim_line_endings(line);
        log_boot("<6>", "%s %s", label, line);
        line_count++;
        if (line_count >= 64U) {
            log_boot("<4>", "%s output truncated after %u line(s)", label, line_count);
            break;
        }
    }

    fclose(fp);
}

static int redirect_child_output_to_path(const char *path) {
    int output_fd;

    output_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOCTTY, 0644);
    if (output_fd < 0) {
        return -1;
    }

    if (dup2(output_fd, STDOUT_FILENO) < 0 || dup2(output_fd, STDERR_FILENO) < 0) {
        int saved_errno = errno;

        close(output_fd);
        errno = saved_errno;
        return -1;
    }

    if (output_fd > STDERR_FILENO) {
        close(output_fd);
    }

    return 0;
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

static int ensure_orange_gpu_runtime_dirs(void) {
    if (ensure_directory(SHADOW_HELLO_INIT_ORANGE_GPU_ROOT, 0755) != 0) {
        return -1;
    }
    if (ensure_directory(SHADOW_HELLO_INIT_ORANGE_GPU_HOME, 0755) != 0) {
        return -1;
    }
    if (ensure_directory(SHADOW_HELLO_INIT_ORANGE_GPU_CACHE_HOME, 0755) != 0) {
        return -1;
    }
    if (ensure_directory(SHADOW_HELLO_INIT_ORANGE_GPU_CONFIG_HOME, 0755) != 0) {
        return -1;
    }
    if (ensure_directory(SHADOW_HELLO_INIT_ORANGE_GPU_MESA_CACHE_DIR, 0755) != 0) {
        return -1;
    }

    return 0;
}

static int set_orange_gpu_child_env(void) {
    if (setenv(SHADOW_HELLO_INIT_GPU_BACKEND_ENV, "vulkan", 1) != 0) {
        log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_GPU_BACKEND_ENV, errno);
        return -1;
    }
    if (setenv(SHADOW_HELLO_INIT_VK_ICD_FILENAMES_ENV, SHADOW_HELLO_INIT_ORANGE_GPU_ICD_PATH, 1) != 0) {
        log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_VK_ICD_FILENAMES_ENV, errno);
        return -1;
    }
    if (setenv(SHADOW_HELLO_INIT_MESA_DRIVER_OVERRIDE_ENV, "kgsl", 1) != 0) {
        log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_MESA_DRIVER_OVERRIDE_ENV, errno);
        return -1;
    }
    if (setenv(SHADOW_HELLO_INIT_TU_DEBUG_ENV, "noconform", 1) != 0) {
        log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_TU_DEBUG_ENV, errno);
        return -1;
    }
    if (setenv(SHADOW_HELLO_INIT_HOME_ENV, SHADOW_HELLO_INIT_ORANGE_GPU_HOME, 1) != 0) {
        log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_HOME_ENV, errno);
        return -1;
    }
    if (setenv(SHADOW_HELLO_INIT_XDG_CACHE_HOME_ENV, SHADOW_HELLO_INIT_ORANGE_GPU_CACHE_HOME, 1) != 0) {
        log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_XDG_CACHE_HOME_ENV, errno);
        return -1;
    }
    if (setenv(SHADOW_HELLO_INIT_XDG_CONFIG_HOME_ENV, SHADOW_HELLO_INIT_ORANGE_GPU_CONFIG_HOME, 1) != 0) {
        log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_XDG_CONFIG_HOME_ENV, errno);
        return -1;
    }
    if (setenv(SHADOW_HELLO_INIT_MESA_SHADER_CACHE_ENV, SHADOW_HELLO_INIT_ORANGE_GPU_MESA_CACHE_DIR, 1) != 0) {
        log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_MESA_SHADER_CACHE_ENV, errno);
        return -1;
    }

    return 0;
}

static int run_orange_gpu_payload(const struct hello_init_config *config) {
    pid_t child_pid;
    int status;
    char hold_seconds[16];
    unsigned int waited_seconds = 0;
    unsigned int watchdog_timeout =
        orange_gpu_mode_uses_success_postlude(config)
            ? SHADOW_HELLO_INIT_ORANGE_GPU_WATCHDOG_GRACE_SECONDS
            : config->hold_seconds + SHADOW_HELLO_INIT_ORANGE_GPU_WATCHDOG_GRACE_SECONDS;

    if (ensure_orange_gpu_runtime_dirs() != 0) {
        return 1;
    }

    unlink_best_effort(SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH);
    unlink_best_effort(SHADOW_HELLO_INIT_ORANGE_GPU_OUTPUT_PATH);

    log_stage(
        "<6>",
        "orange-gpu-launch",
        "loader=%s binary=%s mode=%s hold_seconds=%u",
        SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
        SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
        config->orange_gpu_mode,
        config->hold_seconds
    );
    log_boot("<6>", "%s", kOwnedInitOrangeGpuPayloadSentinel);
    log_boot(
        "<6>",
        "launching payload %s via %s",
        SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
        SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH
    );

    child_pid = fork();
    if (child_pid < 0) {
        log_stage("<3>", "orange-gpu-fork-failed", "errno=%d", errno);
        log_boot("<3>", "fork for %s failed: errno=%d", SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH, errno);
        return 1;
    }
    if (child_pid > 0) {
        log_stage("<6>", "orange-gpu-forked", "pid=%d", child_pid);
    }

    if (child_pid == 0) {
        if (redirect_child_output_to_path(SHADOW_HELLO_INIT_ORANGE_GPU_OUTPUT_PATH) != 0) {
            log_stage("<3>", "orange-gpu-child-redirect-failed", "errno=%d", errno);
            _exit(126);
        }
        if (orange_gpu_mode_is_bundle_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=bundle-smoke",
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH
            );
            execl(
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                "--library-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_LIBRARY_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
                "--scene",
                "bundle-smoke",
                "--hold-secs",
                "0",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_vulkan_offscreen(config)) {
            if (set_orange_gpu_child_env() != 0) {
                _exit(126);
            }
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=smoke mode=vulkan-offscreen",
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH
            );
            execl(
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                "--library-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_LIBRARY_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
                "--scene",
                "smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_vulkan_device_request_smoke(config)) {
            if (set_orange_gpu_child_env() != 0) {
                _exit(126);
            }
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=device-request-smoke mode=vulkan-device-request-smoke",
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH
            );
            execl(
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                "--library-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_LIBRARY_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
                "--scene",
                "device-request-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_vulkan_device_smoke(config)) {
            if (set_orange_gpu_child_env() != 0) {
                _exit(126);
            }
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=device-smoke mode=vulkan-device-smoke",
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH
            );
            execl(
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                "--library-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_LIBRARY_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
                "--scene",
                "device-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else {
            if (snprintf(hold_seconds, sizeof(hold_seconds), "%u", config->hold_seconds) <= 0) {
                log_stage("<3>", "orange-gpu-child-hold-format-failed", "status=126");
                _exit(126);
            }
            if (set_orange_gpu_child_env() != 0) {
                _exit(126);
            }
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=flat-orange",
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH
            );
            execl(
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                "--library-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_LIBRARY_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
                "--scene",
                "flat-orange",
                "--present-kms",
                "--hold-secs",
                hold_seconds,
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        }
        log_stage("<3>", "orange-gpu-exec-failed", "errno=%d", errno);
        log_boot(
            "<3>",
            "exec %s via %s failed: errno=%d",
            SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
            SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
            errno
        );
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
            log_stage("<6>", "orange-gpu-wait", "pid=%d seconds=%u", child_pid, waited_seconds);
            if (waited_seconds >= watchdog_timeout) {
                log_stage(
                    "<4>",
                    "orange-gpu-watchdog-timeout",
                    "pid=%d waited_seconds=%u timeout_seconds=%u",
                    child_pid,
                    waited_seconds,
                    watchdog_timeout
                );
                log_boot(
                    "<4>",
                    "orange-gpu payload exceeded watchdog timeout=%u second(s); sending SIGKILL",
                    watchdog_timeout
                );
                if (kill(child_pid, SIGKILL) != 0 && errno != ESRCH) {
                    log_stage("<3>", "orange-gpu-watchdog-kill-failed", "pid=%d errno=%d", child_pid, errno);
                    log_boot("<3>", "kill(%d, SIGKILL) failed: errno=%d", child_pid, errno);
                    return 1;
                }
                for (;;) {
                    waited = waitpid(child_pid, &status, 0);
                    if (waited == child_pid) {
                        break;
                    }
                    if (waited < 0 && errno == EINTR) {
                        continue;
                    }

                    log_stage("<3>", "orange-gpu-watchdog-reap-failed", "pid=%d errno=%d", child_pid, errno);
                    log_boot("<3>", "watchdog waitpid(%d) failed: errno=%d", child_pid, errno);
                    return 1;
                }
                break;
            }
            continue;
        }
        if (errno != EINTR) {
            log_stage("<3>", "orange-gpu-waitpid-failed", "pid=%d errno=%d", child_pid, errno);
            log_boot("<3>", "waitpid(%d) failed: errno=%d", child_pid, errno);
            return 1;
        }
    }

    log_file_best_effort("orange-gpu-output", SHADOW_HELLO_INIT_ORANGE_GPU_OUTPUT_PATH);
    log_file_best_effort("orange-gpu-summary", SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH);

    if (WIFEXITED(status)) {
        log_stage("<6>", "orange-gpu-exit", "status=%d", WEXITSTATUS(status));
        log_boot(
            "<6>",
            "payload %s exited with status=%d",
            SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
            WEXITSTATUS(status)
        );
        return WEXITSTATUS(status) == 0 ? 0 : WEXITSTATUS(status);
    }

    if (WIFSIGNALED(status)) {
        log_stage("<3>", "orange-gpu-signal", "signal=%d", WTERMSIG(status));
        log_boot(
            "<3>",
            "payload %s died from signal=%d",
            SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
            WTERMSIG(status)
        );
        return 128 + WTERMSIG(status);
    }

    log_stage("<4>", "orange-gpu-unknown-status", "status=%d", status);
    log_boot(
        "<4>",
        "payload %s returned unknown wait status=%d",
        SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
        status
    );
    return 1;
}

static int run_orange_gpu_prelude(const struct hello_init_config *config) {
    struct hello_init_config prelude_config;

    if (!prelude_is_orange_init(config) || config->prelude_hold_seconds == 0U) {
        return 0;
    }

    prelude_config = *config;
    (void)copy_string(
        prelude_config.payload,
        sizeof(prelude_config.payload),
        "orange-init"
    );
    prelude_config.hold_seconds = config->prelude_hold_seconds;

    log_stage(
        "<6>",
        "orange-gpu-prelude",
        "prelude=%s hold_seconds=%u",
        config->prelude,
        config->prelude_hold_seconds
    );
    log_boot(
        "<6>",
        "orange-gpu prelude=%s hold_seconds=%u",
        config->prelude,
        config->prelude_hold_seconds
    );

    return run_orange_init_payload(&prelude_config);
}

static int run_orange_gpu_checkpoint(
    const struct hello_init_config *config,
    const char *checkpoint_name,
    unsigned int hold_seconds
) {
    struct hello_init_config checkpoint_config;

    if (
        !orange_gpu_mode_uses_success_postlude(config) ||
        !prelude_is_orange_init(config) ||
        hold_seconds == 0U
    ) {
        return 0;
    }

    checkpoint_config = *config;
    (void)copy_string(
        checkpoint_config.payload,
        sizeof(checkpoint_config.payload),
        "orange-init"
    );
    checkpoint_config.hold_seconds = hold_seconds;

    log_stage(
        "<6>",
        "orange-gpu-checkpoint",
        "checkpoint=%s hold_seconds=%u",
        checkpoint_name,
        hold_seconds
    );
    log_boot(
        "<6>",
        "orange-gpu checkpoint=%s hold_seconds=%u",
        checkpoint_name,
        hold_seconds
    );

    return run_orange_init_payload(&checkpoint_config);
}

static int run_orange_gpu_postlude(const struct hello_init_config *config) {
    struct hello_init_config postlude_config;

    if (
        !orange_gpu_mode_uses_success_postlude(config) ||
        !prelude_is_orange_init(config) ||
        config->hold_seconds == 0U
    ) {
        return 0;
    }

    postlude_config = *config;
    (void)copy_string(
        postlude_config.payload,
        sizeof(postlude_config.payload),
        "orange-init"
    );
    postlude_config.hold_seconds = config->hold_seconds;

    log_stage(
        "<6>",
        "orange-gpu-postlude",
        "postlude=orange-init hold_seconds=%u",
        config->hold_seconds
    );
    log_boot(
        "<6>",
        "orange-gpu postlude=orange-init hold_seconds=%u",
        config->hold_seconds
    );

    return run_orange_init_payload(&postlude_config);
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
    int prelude_status = 0;
    int checkpoint_status = 0;
    int postlude_status = 0;
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
    log_stage(
        "<6>",
        "pre-dev-bootstrap",
        "payload=%s mount_dev=%s dev_mount=%s dri_bootstrap=%s",
        config.payload,
        bool_word(config.mount_dev),
        config.dev_mount,
        config.dri_bootstrap
    );

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
        log_stage("<6>", "post-dev-bootstrap", "dev_mount=%s", config.dev_mount);
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
    if (bootstrap_tmpfs_dri_runtime(&config) != 0) {
        return 1;
    }

    log_stage(
        "<6>",
        "config-loaded",
        "payload=%s prelude=%s orange_gpu_mode=%s hold_seconds=%u prelude_hold_seconds=%u reboot_target=%s run_token=%s dev_mount=%s dri_bootstrap=%s mount_dev=%s mount_proc=%s mount_sys=%s log_kmsg=%s log_pmsg=%s",
        config.payload,
        config.prelude,
        config.orange_gpu_mode,
        config.hold_seconds,
        config.prelude_hold_seconds,
        config.reboot_target,
        run_token_or_unset(),
        config.dev_mount,
        config.dri_bootstrap,
        bool_word(config.mount_dev),
        bool_word(config.mount_proc),
        bool_word(config.mount_sys),
        bool_word(config.log_kmsg),
        bool_word(config.log_pmsg)
    );
    log_boot(
        "<6>",
        "config payload=%s prelude=%s orange_gpu_mode=%s hold_seconds=%u prelude_hold_seconds=%u reboot_target=%s run_token=%s dev_mount=%s dri_bootstrap=%s mount_dev=%s mount_proc=%s mount_sys=%s log_kmsg=%s log_pmsg=%s",
        config.payload,
        config.prelude,
        config.orange_gpu_mode,
        config.hold_seconds,
        config.prelude_hold_seconds,
        config.reboot_target,
        run_token_or_unset(),
        config.dev_mount,
        config.dri_bootstrap,
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
    } else if (payload_is_orange_gpu(&config)) {
        log_stage("<6>", "payload-dispatch", "payload=orange-gpu");
        prelude_status = run_orange_gpu_prelude(&config);
        if (prelude_status != 0) {
            log_stage(
                "<4>",
                "prelude-failed",
                "prelude=%s status=%d hold_seconds=%u",
                config.prelude,
                prelude_status,
                config.prelude_hold_seconds
            );
            log_boot(
                "<4>",
                "orange-gpu prelude=%s failed with status=%d; continuing to gpu payload",
                config.prelude,
                prelude_status
            );
        }
        if (!validate_orange_gpu_config(&config)) {
            payload_status = 1;
            log_stage(
                "<4>",
                "payload-invalid-config",
                "payload=orange-gpu hold_seconds=%u",
                config.hold_seconds
            );
            log_boot(
                "<4>",
                "orange-gpu config invalid after prelude; holding for observation before reboot"
            );
            hold_for_observation(config.hold_seconds);
            reboot_from_config(&config);
        }
        checkpoint_status = run_orange_gpu_checkpoint(
            &config,
            "validated",
            SHADOW_HELLO_INIT_ORANGE_GPU_CHECKPOINT_HOLD_SECONDS
        );
        if (checkpoint_status != 0) {
            log_stage(
                "<4>",
                "checkpoint-failed",
                "checkpoint=validated status=%d hold_seconds=%u",
                checkpoint_status,
                SHADOW_HELLO_INIT_ORANGE_GPU_CHECKPOINT_HOLD_SECONDS
            );
            log_boot(
                "<4>",
                "orange-gpu checkpoint=validated failed with status=%d; continuing to gpu payload",
                checkpoint_status
            );
        }
        payload_status = run_orange_gpu_payload(&config);
        if (payload_status == 0) {
            postlude_status = run_orange_gpu_postlude(&config);
            if (postlude_status != 0) {
                log_stage(
                    "<4>",
                    "postlude-failed",
                    "postlude=%s status=%d hold_seconds=%u",
                    config.prelude,
                    postlude_status,
                    config.hold_seconds
                );
                log_boot(
                    "<4>",
                    "orange-gpu postlude=%s failed with status=%d; holding for observation before reboot",
                    config.prelude,
                    postlude_status
                );
                hold_for_observation(config.hold_seconds);
            }
        } else {
            log_stage(
                "<4>",
                "payload-failed",
                "payload=orange-gpu status=%d hold_seconds=%u",
                payload_status,
                config.hold_seconds
            );
            log_boot(
                "<4>",
                "orange-gpu payload failed with status=%d; holding for observation before reboot",
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
