#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
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
#define SHADOW_HELLO_INIT_ORANGE_VISUAL_ENV "SHADOW_DRM_RECT_VISUAL"
#define SHADOW_HELLO_INIT_ORANGE_STAGE_ENV "SHADOW_DRM_RECT_STAGE"
#define SHADOW_HELLO_INIT_ORANGE_GPU_ROOT "/orange-gpu"
#define SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH "/orange-gpu/shadow-gpu-smoke"
#define SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH "/orange-gpu/lib/ld-linux-aarch64.so.1"
#define SHADOW_HELLO_INIT_ORANGE_GPU_LIBRARY_PATH "/orange-gpu/lib"
#define SHADOW_HELLO_INIT_ORANGE_GPU_ICD_PATH "/orange-gpu/share/vulkan/icd.d/freedreno_icd.aarch64.json"
#define SHADOW_HELLO_INIT_ORANGE_GPU_HOME "/orange-gpu/home"
#define SHADOW_HELLO_INIT_ORANGE_GPU_CACHE_HOME "/orange-gpu/home/.cache"
#define SHADOW_HELLO_INIT_ORANGE_GPU_CONFIG_HOME "/orange-gpu/home/.config"
#define SHADOW_HELLO_INIT_ORANGE_GPU_MESA_CACHE_DIR "/orange-gpu/home/.cache/mesa"
#define SHADOW_HELLO_INIT_METADATA_MOUNT_PATH "/metadata"
#define SHADOW_HELLO_INIT_METADATA_DEVICE_PATH "/dev/block/by-name/metadata"
#define SHADOW_HELLO_INIT_METADATA_ROOT "/metadata/shadow-hello-init"
#define SHADOW_HELLO_INIT_METADATA_BY_TOKEN_ROOT "/metadata/shadow-hello-init/by-token"
#define SHADOW_HELLO_INIT_METADATA_SYSFS_BLOCK_ROOT "/sys/class/block"
#define SHADOW_HELLO_INIT_METADATA_PARTNAME "metadata"
#define SHADOW_HELLO_INIT_TRACEFS_ROOT "/sys/kernel/tracing"
#define SHADOW_HELLO_INIT_TRACEFS_TRACE_PATH "/sys/kernel/tracing/trace"
#define SHADOW_HELLO_INIT_TRACEFS_TRACE_ON_PATH "/sys/kernel/tracing/tracing_on"
#define SHADOW_HELLO_INIT_TRACEFS_CURRENT_TRACER_PATH "/sys/kernel/tracing/current_tracer"
#define SHADOW_HELLO_INIT_TRACEFS_SET_GRAPH_FUNCTION_PATH "/sys/kernel/tracing/set_graph_function"
#define SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH "/orange-gpu/summary.json"
#define SHADOW_HELLO_INIT_ORANGE_GPU_OUTPUT_PATH "/orange-gpu/output.log"
#define SHADOW_HELLO_INIT_ORANGE_GPU_PROBE_SUMMARY_PATH "/orange-gpu/probe-summary.json"
#define SHADOW_HELLO_INIT_ORANGE_GPU_PROBE_OUTPUT_PATH "/orange-gpu/probe-output.log"
#define SHADOW_HELLO_INIT_GPU_BACKEND_ENV "WGPU_BACKEND"
#define SHADOW_HELLO_INIT_VK_ICD_FILENAMES_ENV "VK_ICD_FILENAMES"
#define SHADOW_HELLO_INIT_MESA_DRIVER_OVERRIDE_ENV "MESA_LOADER_DRIVER_OVERRIDE"
#define SHADOW_HELLO_INIT_TU_DEBUG_ENV "TU_DEBUG"
#define SHADOW_HELLO_INIT_HOME_ENV "HOME"
#define SHADOW_HELLO_INIT_XDG_CACHE_HOME_ENV "XDG_CACHE_HOME"
#define SHADOW_HELLO_INIT_XDG_CONFIG_HOME_ENV "XDG_CONFIG_HOME"
#define SHADOW_HELLO_INIT_MESA_SHADER_CACHE_ENV "MESA_SHADER_CACHE_DIR"
#define SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PATH_ENV "SHADOW_GPU_SMOKE_STAGE_PATH"
#define SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PREFIX_ENV "SHADOW_GPU_SMOKE_STAGE_PREFIX"

#define SHADOW_HELLO_INIT_TAG "shadow-hello-init"
#define SHADOW_HELLO_INIT_DEFAULT_HOLD_SECONDS 30U
#define SHADOW_HELLO_INIT_MAX_HOLD_SECONDS 3600U
#define SHADOW_HELLO_INIT_ORANGE_GPU_WATCHDOG_GRACE_SECONDS 30U
#define SHADOW_HELLO_INIT_ORANGE_GPU_CHECKPOINT_HOLD_SECONDS 1U
#define SHADOW_HELLO_INIT_FIRMWARE_PROBE_CHECKPOINT_HOLD_SECONDS 2U
#define SHADOW_HELLO_INIT_TIMEOUT_CLASSIFIER_HOLD_SECONDS 3U

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
    char orange_gpu_mode[64];
    bool orange_gpu_mode_seen;
    bool orange_gpu_mode_invalid;
    unsigned int orange_gpu_launch_delay_secs;
    unsigned int orange_gpu_parent_probe_attempts;
    unsigned int orange_gpu_parent_probe_interval_secs;
    bool orange_gpu_metadata_stage_breadcrumb;
    char orange_gpu_timeout_action[24];
    unsigned int orange_gpu_watchdog_timeout_secs;
    unsigned int hold_seconds;
    unsigned int prelude_hold_seconds;
    char reboot_target[32];
    char run_token[64];
    char dev_mount[16];
    char dri_bootstrap[48];
    char firmware_bootstrap[48];
    bool mount_dev;
    bool mount_proc;
    bool mount_sys;
    bool log_kmsg;
    bool log_pmsg;
};

struct block_device_identity {
    bool available;
    unsigned int major_num;
    unsigned int minor_num;
};

struct metadata_stage_runtime {
    bool enabled;
    bool prepared;
    bool write_failed;
    struct block_device_identity block_device;
    char stage_dir[192];
    char stage_path[224];
    char temp_stage_path[224];
    char probe_stage_path[224];
    char temp_probe_stage_path[224];
    char probe_fingerprint_path[224];
    char temp_probe_fingerprint_path[224];
    char probe_report_path[224];
    char temp_probe_report_path[224];
    char probe_timeout_class_path[224];
    char temp_probe_timeout_class_path[224];
};

static int shadow_kmsg_fd = -1;
static int shadow_pmsg_fd = -1;
static uint64_t shadow_boot_start_ms = 0;
static bool shadow_log_stdio = true;
static bool shadow_log_kmsg = false;
static bool shadow_log_pmsg = false;
static char shadow_run_token[64] = "";

static void unlink_best_effort(const char *path);
static char *trim_whitespace(char *value);

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
    config->orange_gpu_launch_delay_secs = 0U;
    config->orange_gpu_parent_probe_attempts = 0U;
    config->orange_gpu_parent_probe_interval_secs = 0U;
    config->orange_gpu_metadata_stage_breadcrumb = false;
    (void)copy_string(
        config->orange_gpu_timeout_action,
        sizeof(config->orange_gpu_timeout_action),
        "reboot"
    );
    config->orange_gpu_watchdog_timeout_secs = 0U;
    config->hold_seconds = SHADOW_HELLO_INIT_DEFAULT_HOLD_SECONDS;
    config->prelude_hold_seconds = 0U;
    (void)copy_string(config->reboot_target, sizeof(config->reboot_target), "bootloader");
    config->run_token[0] = '\0';
    (void)copy_string(config->dev_mount, sizeof(config->dev_mount), "devtmpfs");
    (void)copy_string(config->dri_bootstrap, sizeof(config->dri_bootstrap), "none");
    (void)copy_string(
        config->firmware_bootstrap,
        sizeof(config->firmware_bootstrap),
        "none"
    );
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

static int write_fd_all_checked(int fd, const char *message) {
    size_t total = 0;
    size_t remaining = strlen(message);

    while (remaining > 0) {
        ssize_t written = write(fd, message + total, remaining);

        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (written == 0) {
            errno = EIO;
            return -1;
        }

        total += (size_t)written;
        remaining -= (size_t)written;
    }

    return 0;
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

static int ensure_device_node(
    const char *path,
    mode_t mode,
    mode_t expected_type,
    unsigned int major_num,
    unsigned int minor_num
) {
    struct stat st;
    dev_t expected_device;
    mode_t old_umask;

    expected_device = makedev(major_num, minor_num);

    if (lstat(path, &st) == 0) {
        if (
            ((expected_type == S_IFCHR && S_ISCHR(st.st_mode)) ||
             (expected_type == S_IFBLK && S_ISBLK(st.st_mode))) &&
            st.st_rdev == expected_device
        ) {
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
    if (mknod(path, expected_type | mode, expected_device) != 0 && errno != EEXIST) {
        int saved_errno = errno;

        (void)umask(old_umask);
        log_boot(
            "<3>",
            "mknod(%s type=%s major=%u minor=%u) failed: errno=%d",
            path,
            expected_type == S_IFBLK ? "block" : "char",
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
    if (
        !(
            (expected_type == S_IFCHR && S_ISCHR(st.st_mode)) ||
            (expected_type == S_IFBLK && S_ISBLK(st.st_mode))
        ) ||
        st.st_rdev != expected_device
    ) {
        log_boot(
            "<3>",
            "device path %s did not resolve to expected %s device %u:%u",
            path,
            expected_type == S_IFBLK ? "block" : "char",
            major_num,
            minor_num
        );
        return -1;
    }

    return 0;
}

static int ensure_char_device(
    const char *path,
    mode_t mode,
    unsigned int major_num,
    unsigned int minor_num
) {
    return ensure_device_node(path, mode, S_IFCHR, major_num, minor_num);
}

static int ensure_block_device(
    const char *path,
    mode_t mode,
    unsigned int major_num,
    unsigned int minor_num
) {
    return ensure_device_node(path, mode, S_IFBLK, major_num, minor_num);
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

static void init_metadata_stage_runtime(
    const struct hello_init_config *config,
    struct metadata_stage_runtime *runtime
) {
    int dir_len;
    int stage_len;
    int temp_len;
    int probe_stage_len;
    int probe_temp_len;
    int probe_fingerprint_len;
    int probe_fingerprint_temp_len;
    int probe_report_len;
    int probe_report_temp_len;
    int probe_timeout_class_len;
    int probe_timeout_class_temp_len;

    memset(runtime, 0, sizeof(*runtime));
    runtime->enabled = config->orange_gpu_metadata_stage_breadcrumb;
    if (!runtime->enabled) {
        return;
    }

    if (config->run_token[0] == '\0') {
        runtime->enabled = false;
        log_stage("<4>", "metadata-stage-disabled", "reason=run_token_unset");
        return;
    }
    if (!config->mount_dev) {
        runtime->enabled = false;
        log_stage("<4>", "metadata-stage-disabled", "reason=mount_dev_false");
        return;
    }

    dir_len = snprintf(
        runtime->stage_dir,
        sizeof(runtime->stage_dir),
        "%s/%s",
        SHADOW_HELLO_INIT_METADATA_BY_TOKEN_ROOT,
        config->run_token
    );
    stage_len = snprintf(
        runtime->stage_path,
        sizeof(runtime->stage_path),
        "%s/stage.txt",
        runtime->stage_dir
    );
    temp_len = snprintf(
        runtime->temp_stage_path,
        sizeof(runtime->temp_stage_path),
        "%s/.stage.txt.tmp",
        runtime->stage_dir
    );
    probe_stage_len = snprintf(
        runtime->probe_stage_path,
        sizeof(runtime->probe_stage_path),
        "%s/probe-stage.txt",
        runtime->stage_dir
    );
    probe_temp_len = snprintf(
        runtime->temp_probe_stage_path,
        sizeof(runtime->temp_probe_stage_path),
        "%s/.probe-stage.txt.tmp",
        runtime->stage_dir
    );
    probe_fingerprint_len = snprintf(
        runtime->probe_fingerprint_path,
        sizeof(runtime->probe_fingerprint_path),
        "%s/probe-fingerprint.txt",
        runtime->stage_dir
    );
    probe_fingerprint_temp_len = snprintf(
        runtime->temp_probe_fingerprint_path,
        sizeof(runtime->temp_probe_fingerprint_path),
        "%s/.probe-fingerprint.txt.tmp",
        runtime->stage_dir
    );
    probe_report_len = snprintf(
        runtime->probe_report_path,
        sizeof(runtime->probe_report_path),
        "%s/probe-report.txt",
        runtime->stage_dir
    );
    probe_report_temp_len = snprintf(
        runtime->temp_probe_report_path,
        sizeof(runtime->temp_probe_report_path),
        "%s/.probe-report.txt.tmp",
        runtime->stage_dir
    );
    probe_timeout_class_len = snprintf(
        runtime->probe_timeout_class_path,
        sizeof(runtime->probe_timeout_class_path),
        "%s/probe-timeout-class.txt",
        runtime->stage_dir
    );
    probe_timeout_class_temp_len = snprintf(
        runtime->temp_probe_timeout_class_path,
        sizeof(runtime->temp_probe_timeout_class_path),
        "%s/.probe-timeout-class.txt.tmp",
        runtime->stage_dir
    );
    if (
        dir_len < 0 || (size_t)dir_len >= sizeof(runtime->stage_dir) ||
        stage_len < 0 || (size_t)stage_len >= sizeof(runtime->stage_path) ||
        temp_len < 0 || (size_t)temp_len >= sizeof(runtime->temp_stage_path) ||
        probe_stage_len < 0 || (size_t)probe_stage_len >= sizeof(runtime->probe_stage_path) ||
        probe_temp_len < 0 || (size_t)probe_temp_len >= sizeof(runtime->temp_probe_stage_path) ||
        probe_fingerprint_len < 0 || (size_t)probe_fingerprint_len >= sizeof(runtime->probe_fingerprint_path) ||
        probe_fingerprint_temp_len < 0 || (size_t)probe_fingerprint_temp_len >= sizeof(runtime->temp_probe_fingerprint_path) ||
        probe_report_len < 0 || (size_t)probe_report_len >= sizeof(runtime->probe_report_path) ||
        probe_report_temp_len < 0 || (size_t)probe_report_temp_len >= sizeof(runtime->temp_probe_report_path) ||
        probe_timeout_class_len < 0 ||
        (size_t)probe_timeout_class_len >= sizeof(runtime->probe_timeout_class_path) ||
        probe_timeout_class_temp_len < 0 ||
        (size_t)probe_timeout_class_temp_len >= sizeof(runtime->temp_probe_timeout_class_path)
    ) {
        runtime->enabled = false;
        log_stage("<4>", "metadata-stage-disabled", "reason=path_too_long");
    }
}

static void capture_metadata_block_identity(
    const struct hello_init_config *config,
    struct metadata_stage_runtime *runtime
) {
    struct stat st;

    if (!runtime->enabled || strcmp(config->dev_mount, "tmpfs") != 0) {
        return;
    }

    if (stat(SHADOW_HELLO_INIT_METADATA_DEVICE_PATH, &st) != 0) {
        log_stage(
            "<4>",
            "metadata-stage-device-identity-missing",
            "path=%s errno=%d",
            SHADOW_HELLO_INIT_METADATA_DEVICE_PATH,
            errno
        );
        return;
    }
    if (!S_ISBLK(st.st_mode)) {
        log_stage(
            "<4>",
            "metadata-stage-device-identity-invalid",
            "path=%s mode=%o",
            SHADOW_HELLO_INIT_METADATA_DEVICE_PATH,
            st.st_mode
        );
        return;
    }

    runtime->block_device.available = true;
    runtime->block_device.major_num = major(st.st_rdev);
    runtime->block_device.minor_num = minor(st.st_rdev);
    log_stage(
        "<6>",
        "metadata-stage-device-identity",
        "source=pre-dev path=%s major=%u minor=%u",
        SHADOW_HELLO_INIT_METADATA_DEVICE_PATH,
        runtime->block_device.major_num,
        runtime->block_device.minor_num
    );
}

static bool parse_unbounded_unsigned_value(const char *raw, unsigned int *parsed) {
    char *end = NULL;
    unsigned long value;

    errno = 0;
    value = strtoul(raw, &end, 10);
    if (
        errno != 0 ||
        end == raw ||
        *trim_whitespace(end) != '\0' ||
        value > (unsigned long)UINT_MAX
    ) {
        return false;
    }

    *parsed = (unsigned int)value;
    return true;
}

static bool read_metadata_block_identity_from_uevent(
    const char *uevent_path,
    struct block_device_identity *block_device
) {
    FILE *uevent_file;
    char line[256];
    bool partname_matches = false;
    bool major_seen = false;
    bool minor_seen = false;
    unsigned int major_num = 0U;
    unsigned int minor_num = 0U;

    uevent_file = fopen(uevent_path, "r");
    if (uevent_file == NULL) {
        return false;
    }

    while (fgets(line, sizeof(line), uevent_file) != NULL) {
        char *value = trim_whitespace(line);

        if (strncmp(value, "PARTNAME=", 9) == 0) {
            partname_matches =
                strcmp(value + 9, SHADOW_HELLO_INIT_METADATA_PARTNAME) == 0;
            continue;
        }
        if (strncmp(value, "MAJOR=", 6) == 0) {
            major_seen = parse_unbounded_unsigned_value(value + 6, &major_num);
            continue;
        }
        if (strncmp(value, "MINOR=", 6) == 0) {
            minor_seen = parse_unbounded_unsigned_value(value + 6, &minor_num);
        }
    }

    fclose(uevent_file);

    if (!partname_matches || !major_seen || !minor_seen) {
        return false;
    }

    block_device->available = true;
    block_device->major_num = major_num;
    block_device->minor_num = minor_num;
    return true;
}

static bool discover_metadata_block_identity_from_sysfs(
    const struct hello_init_config *config,
    struct metadata_stage_runtime *runtime
) {
    DIR *block_dir;
    struct dirent *entry;
    struct block_device_identity discovered_block_device;
    char matched_uevent_path[192];
    int saved_errno = 0;

    if (
        !runtime->enabled ||
        runtime->block_device.available ||
        strcmp(config->dev_mount, "tmpfs") != 0 ||
        !config->mount_sys
    ) {
        return runtime->block_device.available;
    }

    block_dir = opendir(SHADOW_HELLO_INIT_METADATA_SYSFS_BLOCK_ROOT);
    if (block_dir == NULL) {
        log_stage(
            "<4>",
            "metadata-stage-device-identity-sysfs-open-failed",
            "path=%s errno=%d",
            SHADOW_HELLO_INIT_METADATA_SYSFS_BLOCK_ROOT,
            errno
        );
        return false;
    }

    memset(&discovered_block_device, 0, sizeof(discovered_block_device));
    matched_uevent_path[0] = '\0';
    errno = 0;
    while ((entry = readdir(block_dir)) != NULL) {
        char uevent_path[192];
        int path_len;

        if (entry->d_name[0] == '.') {
            continue;
        }

        path_len = snprintf(
            uevent_path,
            sizeof(uevent_path),
            "%s/%s/uevent",
            SHADOW_HELLO_INIT_METADATA_SYSFS_BLOCK_ROOT,
            entry->d_name
        );
        if (path_len < 0 || (size_t)path_len >= sizeof(uevent_path)) {
            continue;
        }

        if (
            read_metadata_block_identity_from_uevent(
                uevent_path,
                &discovered_block_device
            )
        ) {
            (void)copy_string(
                matched_uevent_path,
                sizeof(matched_uevent_path),
                uevent_path
            );
            break;
        }
    }
    saved_errno = errno;
    closedir(block_dir);

    if (!discovered_block_device.available) {
        if (saved_errno != 0) {
            log_stage(
                "<4>",
                "metadata-stage-device-identity-sysfs-scan-failed",
                "path=%s errno=%d",
                SHADOW_HELLO_INIT_METADATA_SYSFS_BLOCK_ROOT,
                saved_errno
            );
        } else {
            log_stage(
                "<4>",
                "metadata-stage-device-identity-missing",
                "path=%s partname=%s reason=sysfs_partname_missing",
                SHADOW_HELLO_INIT_METADATA_SYSFS_BLOCK_ROOT,
                SHADOW_HELLO_INIT_METADATA_PARTNAME
            );
        }
        return false;
    }

    runtime->block_device = discovered_block_device;
    log_stage(
        "<6>",
        "metadata-stage-device-identity",
        "source=sysfs path=%s major=%u minor=%u partname=%s",
        matched_uevent_path,
        runtime->block_device.major_num,
        runtime->block_device.minor_num,
        SHADOW_HELLO_INIT_METADATA_PARTNAME
    );
    return true;
}

static int bootstrap_tmpfs_metadata_block_runtime(
    const struct hello_init_config *config,
    const struct metadata_stage_runtime *runtime
) {
    if (strcmp(config->dev_mount, "tmpfs") != 0) {
        return 0;
    }
    if (!runtime->block_device.available) {
        errno = ENOENT;
        return -1;
    }
    if (ensure_directory("/dev/block", 0755) != 0) {
        return -1;
    }
    if (ensure_directory("/dev/block/by-name", 0755) != 0) {
        return -1;
    }
    return ensure_block_device(
        SHADOW_HELLO_INIT_METADATA_DEVICE_PATH,
        0600,
        runtime->block_device.major_num,
        runtime->block_device.minor_num
    );
}

static int fsync_directory_path(const char *path) {
    int dir_fd;

    dir_fd = open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY);
    if (dir_fd < 0) {
        return -1;
    }
    if (fsync(dir_fd) != 0) {
        int saved_errno = errno;

        close(dir_fd);
        errno = saved_errno;
        return -1;
    }

    close(dir_fd);
    return 0;
}

static int write_atomic_text_file(
    const char *directory_path,
    const char *temp_path,
    const char *final_path,
    const char *contents
) {
    int temp_fd;
    int final_fd;

    temp_fd = open(
        temp_path,
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOCTTY,
        0644
    );
    if (temp_fd < 0) {
        return -1;
    }

    if (write_fd_all_checked(temp_fd, contents) != 0) {
        int saved_errno = errno;

        close(temp_fd);
        unlink_best_effort(temp_path);
        errno = saved_errno;
        return -1;
    }
    if (fsync(temp_fd) != 0) {
        int saved_errno = errno;

        close(temp_fd);
        unlink_best_effort(temp_path);
        errno = saved_errno;
        return -1;
    }
    if (close(temp_fd) != 0) {
        int saved_errno = errno;

        unlink_best_effort(temp_path);
        errno = saved_errno;
        return -1;
    }
    if (rename(temp_path, final_path) != 0) {
        int saved_errno = errno;

        unlink_best_effort(temp_path);
        errno = saved_errno;
        return -1;
    }

    final_fd = open(final_path, O_RDONLY | O_CLOEXEC | O_NOCTTY);
    if (final_fd < 0) {
        return -1;
    }
    if (fsync(final_fd) != 0) {
        int saved_errno = errno;

        close(final_fd);
        errno = saved_errno;
        return -1;
    }
    close(final_fd);

    return fsync_directory_path(directory_path);
}

static bool prepare_metadata_stage_runtime_best_effort(
    const struct hello_init_config *config,
    struct metadata_stage_runtime *runtime
) {
    unsigned long mount_flags = MS_NOATIME | MS_NODEV | MS_NOSUID;
    const char *fstypes[] = {"ext4", "f2fs"};
    size_t index;

    if (!runtime->enabled) {
        return false;
    }
    if (runtime->prepared) {
        return true;
    }

    if (!runtime->block_device.available) {
        (void)discover_metadata_block_identity_from_sysfs(config, runtime);
    }
    if (bootstrap_tmpfs_metadata_block_runtime(config, runtime) != 0) {
        runtime->write_failed = true;
        log_stage(
            "<4>",
            "metadata-stage-bootstrap-failed",
            "path=%s errno=%d",
            SHADOW_HELLO_INIT_METADATA_DEVICE_PATH,
            errno
        );
        return false;
    }
    if (ensure_directory(SHADOW_HELLO_INIT_METADATA_MOUNT_PATH, 0755) != 0) {
        runtime->write_failed = true;
        log_stage(
            "<4>",
            "metadata-stage-mountpoint-failed",
            "path=%s errno=%d",
            SHADOW_HELLO_INIT_METADATA_MOUNT_PATH,
            errno
        );
        return false;
    }

    for (index = 0; index < sizeof(fstypes) / sizeof(fstypes[0]); index++) {
        if (
            mount(
                SHADOW_HELLO_INIT_METADATA_DEVICE_PATH,
                SHADOW_HELLO_INIT_METADATA_MOUNT_PATH,
                fstypes[index],
                mount_flags,
                ""
            ) == 0 ||
            errno == EBUSY
        ) {
            log_stage(
                "<6>",
                "metadata-stage-mounted",
                "path=%s fstype=%s",
                SHADOW_HELLO_INIT_METADATA_MOUNT_PATH,
                fstypes[index]
            );
            break;
        }
    }
    if (index == sizeof(fstypes) / sizeof(fstypes[0])) {
        runtime->write_failed = true;
        log_stage(
            "<4>",
            "metadata-stage-mount-failed",
            "source=%s target=%s errno=%d",
            SHADOW_HELLO_INIT_METADATA_DEVICE_PATH,
            SHADOW_HELLO_INIT_METADATA_MOUNT_PATH,
            errno
        );
        return false;
    }

    if (
        ensure_directory(SHADOW_HELLO_INIT_METADATA_ROOT, 0755) != 0 ||
        ensure_directory(SHADOW_HELLO_INIT_METADATA_BY_TOKEN_ROOT, 0755) != 0 ||
        ensure_directory(runtime->stage_dir, 0755) != 0
    ) {
        runtime->write_failed = true;
        log_stage(
            "<4>",
            "metadata-stage-dir-failed",
            "dir=%s errno=%d",
            runtime->stage_dir,
            errno
        );
        return false;
    }

    runtime->prepared = true;
    return true;
}

static bool write_metadata_stage_best_effort(
    struct metadata_stage_runtime *runtime,
    const char *stage_value
) {
    char contents[128];
    int contents_len;

    if (!runtime->enabled || runtime->write_failed) {
        return false;
    }
    if (!runtime->prepared) {
        runtime->write_failed = true;
        log_stage("<4>", "metadata-stage-write-skipped", "reason=not_prepared");
        return false;
    }

    contents_len = snprintf(contents, sizeof(contents), "%s\n", stage_value);
    if (contents_len < 0 || (size_t)contents_len >= sizeof(contents)) {
        runtime->write_failed = true;
        log_stage("<4>", "metadata-stage-write-skipped", "reason=stage_too_long");
        return false;
    }
    if (
        write_atomic_text_file(
            runtime->stage_dir,
            runtime->temp_stage_path,
            runtime->stage_path,
            contents
        ) != 0
    ) {
        runtime->write_failed = true;
        log_stage(
            "<4>",
            "metadata-stage-write-failed",
            "stage=%s path=%s errno=%d",
            stage_value,
            runtime->stage_path,
            errno
        );
        return false;
    }

    log_stage(
        "<6>",
        "metadata-stage-write",
        "stage=%s path=%s",
        stage_value,
        runtime->stage_path
    );
    return true;
}

static void write_payload_probe_stage_best_effort(
    const char *stage_path,
    const char *stage_prefix,
    const char *stage_value
) {
    char directory_path[PATH_MAX];
    char temp_path[PATH_MAX];
    char contents[256];
    char *last_slash;
    int contents_len;
    int temp_len;

    if (stage_path == NULL || stage_prefix == NULL || stage_value == NULL) {
        return;
    }
    contents_len = snprintf(contents, sizeof(contents), "%s:%s\n", stage_prefix, stage_value);
    if (contents_len < 0 || (size_t)contents_len >= sizeof(contents)) {
        log_stage("<4>", "payload-probe-stage-write-skipped", "reason=stage_too_long");
        return;
    }
    if (!copy_string(directory_path, sizeof(directory_path), stage_path)) {
        log_stage("<4>", "payload-probe-stage-write-skipped", "reason=path_too_long");
        return;
    }
    last_slash = strrchr(directory_path, '/');
    if (last_slash == NULL || last_slash == directory_path) {
        log_stage("<4>", "payload-probe-stage-write-skipped", "reason=missing_parent_dir");
        return;
    }
    *last_slash = '\0';
    temp_len = snprintf(temp_path, sizeof(temp_path), "%s.tmp", stage_path);
    if (temp_len < 0 || (size_t)temp_len >= sizeof(temp_path)) {
        log_stage("<4>", "payload-probe-stage-write-skipped", "reason=temp_path_too_long");
        return;
    }
    if (write_atomic_text_file(directory_path, temp_path, stage_path, contents) != 0) {
        log_stage(
            "<4>",
            "payload-probe-stage-write-failed",
            "stage=%s path=%s errno=%d",
            stage_value,
            stage_path,
            errno
        );
        return;
    }
    log_stage(
        "<6>",
        "payload-probe-stage-write",
        "stage=%s path=%s",
        stage_value,
        stage_path
    );
}

static bool append_fingerprintf(
    char *buffer,
    size_t buffer_size,
    size_t *used,
    const char *fmt,
    ...
) {
    int written;
    va_list args;

    if (*used >= buffer_size) {
        return false;
    }

    va_start(args, fmt);
    written = vsnprintf(buffer + *used, buffer_size - *used, fmt, args);
    va_end(args);
    if (written < 0 || (size_t)written >= buffer_size - *used) {
        *used = buffer_size;
        return false;
    }

    *used += (size_t)written;
    return true;
}

static bool append_path_fingerprint_line(
    char *buffer,
    size_t buffer_size,
    size_t *used,
    const char *path
) {
    struct stat st;

    if (stat(path, &st) != 0) {
        return append_fingerprintf(
            buffer,
            buffer_size,
            used,
            "path=%s present=false errno=%d\n",
            path,
            errno
        );
    }

    if (S_ISCHR(st.st_mode) || S_ISBLK(st.st_mode)) {
        return append_fingerprintf(
            buffer,
            buffer_size,
            used,
            "path=%s present=true kind=%s mode=%o uid=%u gid=%u major=%u minor=%u\n",
            path,
            S_ISCHR(st.st_mode) ? "char" : "block",
            st.st_mode & 07777,
            st.st_uid,
            st.st_gid,
            major(st.st_rdev),
            minor(st.st_rdev)
        );
    }

    return append_fingerprintf(
        buffer,
        buffer_size,
        used,
        "path=%s present=true kind=%s mode=%o uid=%u gid=%u size=%lld\n",
        path,
        S_ISDIR(st.st_mode) ? "dir" : "file",
        st.st_mode & 07777,
        st.st_uid,
        st.st_gid,
        (long long)st.st_size
    );
}

static bool append_file_excerpt(
    char *buffer,
    size_t buffer_size,
    size_t *used,
    const char *path,
    size_t max_bytes
) {
    int fd;
    ssize_t bytes_read;
    char excerpt[1024];

    if (max_bytes > sizeof(excerpt) - 1U) {
        max_bytes = sizeof(excerpt) - 1U;
    }

    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOCTTY);
    if (fd < 0) {
        return append_fingerprintf(
            buffer,
            buffer_size,
            used,
            "file-excerpt path=%s present=false errno=%d\n",
            path,
            errno
        );
    }

    bytes_read = read(fd, excerpt, max_bytes);
    if (bytes_read < 0) {
        int saved_errno = errno;

        close(fd);
        return append_fingerprintf(
            buffer,
            buffer_size,
            used,
            "file-excerpt path=%s read_failed=true errno=%d\n",
            path,
            saved_errno
        );
    }
    close(fd);

    excerpt[bytes_read] = '\0';
    if (
        !append_fingerprintf(
            buffer,
            buffer_size,
            used,
            "file-excerpt path=%s bytes=%zd\n",
            path,
            bytes_read
        )
    ) {
        return false;
    }
    return append_fingerprintf(buffer, buffer_size, used, "%s\n", excerpt);
}

static bool append_groups_fingerprint_line(
    char *buffer,
    size_t buffer_size,
    size_t *used
) {
    gid_t groups[32];
    int groups_count;
    int groups_read;
    bool groups_truncated = false;
    int index;

    groups_count = getgroups(0, NULL);
    if (groups_count < 0) {
        return append_fingerprintf(
            buffer,
            buffer_size,
            used,
            "identity pid=%d ppid=%d uid=%u euid=%u gid=%u egid=%u groups_present=false errno=%d\n",
            getpid(),
            getppid(),
            getuid(),
            geteuid(),
            getgid(),
            getegid(),
            errno
        );
    }

    groups_read = groups_count;
    if (groups_read > (int)(sizeof(groups) / sizeof(groups[0]))) {
        groups_read = (int)(sizeof(groups) / sizeof(groups[0]));
        groups_truncated = true;
    }
    if (groups_read > 0 && getgroups(groups_read, groups) < 0) {
        return append_fingerprintf(
            buffer,
            buffer_size,
            used,
            "identity pid=%d ppid=%d uid=%u euid=%u gid=%u egid=%u groups_present=false errno=%d\n",
            getpid(),
            getppid(),
            getuid(),
            geteuid(),
            getgid(),
            getegid(),
            errno
        );
    }

    if (
        !append_fingerprintf(
            buffer,
            buffer_size,
            used,
            "identity pid=%d ppid=%d uid=%u euid=%u gid=%u egid=%u groups_count=%d groups_truncated=%s groups=",
            getpid(),
            getppid(),
            getuid(),
            geteuid(),
            getgid(),
            getegid(),
            groups_count,
            bool_word(groups_truncated)
        )
    ) {
        return false;
    }

    for (index = 0; index < groups_read; index++) {
        if (
            !append_fingerprintf(
                buffer,
                buffer_size,
                used,
                "%s%u",
                index == 0 ? "" : ",",
                groups[index]
            )
        ) {
            return false;
        }
    }

    return append_fingerprintf(buffer, buffer_size, used, "\n");
}

static bool append_symlink_target_line(
    char *buffer,
    size_t buffer_size,
    size_t *used,
    const char *label,
    const char *path
) {
    char target[256];
    ssize_t target_length;

    target_length = readlink(path, target, sizeof(target) - 1U);
    if (target_length < 0) {
        return append_fingerprintf(
            buffer,
            buffer_size,
            used,
            "namespace label=%s path=%s present=false errno=%d\n",
            label,
            path,
            errno
        );
    }

    target[target_length] = '\0';
    return append_fingerprintf(
        buffer,
        buffer_size,
        used,
        "namespace label=%s path=%s present=true target=%s\n",
        label,
        path,
        target
    );
}

static bool append_pid_namespace_fingerprint_lines(
    char *buffer,
    size_t buffer_size,
    size_t *used,
    pid_t pid
) {
    char path[64];
    int path_length;
    const char *labels[] = {"mnt", "pid", "net", "uts", "ipc", "user", "cgroup"};
    size_t label_index;

    for (label_index = 0; label_index < sizeof(labels) / sizeof(labels[0]); label_index++) {
        path_length = snprintf(path, sizeof(path), "/proc/%d/ns/%s", pid, labels[label_index]);
        if (path_length < 0 || (size_t)path_length >= sizeof(path)) {
            return false;
        }
        if (!append_symlink_target_line(buffer, buffer_size, used, labels[label_index], path)) {
            return false;
        }
    }

    return true;
}

static bool write_metadata_probe_fingerprint_best_effort(
    const struct hello_init_config *config,
    struct metadata_stage_runtime *runtime
) {
    char contents[8192];
    size_t used = 0U;

    if (!runtime->enabled || runtime->write_failed) {
        return false;
    }
    if (!runtime->prepared) {
        runtime->write_failed = true;
        log_stage("<4>", "metadata-probe-fingerprint-write-skipped", "reason=not_prepared");
        return false;
    }

    if (
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "run_token=%s\nmount_dev=%s mount_proc=%s mount_sys=%s dev_mount=%s metadata_prepared=%s\n",
            config->run_token,
            bool_word(config->mount_dev),
            bool_word(config->mount_proc),
            bool_word(config->mount_sys),
            config->dev_mount,
            bool_word(runtime->prepared)
        ) ||
        !append_groups_fingerprint_line(contents, sizeof(contents), &used) ||
        !append_file_excerpt(contents, sizeof(contents), &used, "/proc/self/attr/current", 256U) ||
        !append_file_excerpt(contents, sizeof(contents), &used, "/proc/self/cgroup", 512U) ||
        !append_pid_namespace_fingerprint_lines(contents, sizeof(contents), &used, getpid()) ||
        !append_file_excerpt(contents, sizeof(contents), &used, "/proc/self/mountinfo", 1536U) ||
        !append_path_fingerprint_line(contents, sizeof(contents), &used, "/dev/kgsl-3d0") ||
        !append_path_fingerprint_line(contents, sizeof(contents), &used, "/dev/dri/card0") ||
        !append_path_fingerprint_line(contents, sizeof(contents), &used, "/dev/dri/renderD128") ||
        !append_path_fingerprint_line(contents, sizeof(contents), &used, "/dev/dma_heap/system") ||
        !append_path_fingerprint_line(contents, sizeof(contents), &used, "/dev/ion") ||
        !append_path_fingerprint_line(
            contents,
            sizeof(contents),
            &used,
            SHADOW_HELLO_INIT_ORANGE_GPU_ICD_PATH
        ) ||
        !append_file_excerpt(contents, sizeof(contents), &used, "/proc/mounts", 1024U) ||
        !append_file_excerpt(
            contents,
            sizeof(contents),
            &used,
            SHADOW_HELLO_INIT_ORANGE_GPU_ICD_PATH,
            512U
        )
    ) {
        runtime->write_failed = true;
        log_stage("<4>", "metadata-probe-fingerprint-write-skipped", "reason=buffer_overflow");
        return false;
    }

    if (
        write_atomic_text_file(
            runtime->stage_dir,
            runtime->temp_probe_fingerprint_path,
            runtime->probe_fingerprint_path,
            contents
        ) != 0
    ) {
        runtime->write_failed = true;
        log_stage(
            "<4>",
            "metadata-probe-fingerprint-write-failed",
            "path=%s errno=%d",
            runtime->probe_fingerprint_path,
            errno
        );
        return false;
    }

    log_stage(
        "<6>",
        "metadata-probe-fingerprint-write",
        "path=%s",
        runtime->probe_fingerprint_path
    );
    return true;
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

static bool write_text_path_best_effort(const char *path, const char *contents) {
    int fd;
    bool ok = false;

    fd = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOCTTY);
    if (fd < 0) {
        return false;
    }

    ok = write_fd_all_checked(fd, contents) == 0;
    close(fd);
    return ok;
}

static void teardown_kgsl_trace_best_effort(void) {
    (void)write_text_path_best_effort(
        SHADOW_HELLO_INIT_TRACEFS_TRACE_ON_PATH,
        "0\n"
    );
    (void)write_text_path_best_effort(
        SHADOW_HELLO_INIT_TRACEFS_CURRENT_TRACER_PATH,
        "nop\n"
    );
}

static bool setup_kgsl_trace_best_effort(void) {
    static const char kKgslTraceFunctions[] =
        "a6xx_microcode_read\n"
        "a6xx_gmu_load_firmware\n"
        "subsystem_get\n"
        "pil_boot\n"
        "gmu_start\n"
        "a6xx_gmu_fw_start\n"
        "a6xx_gmu_start\n"
        "a6xx_gmu_hfi_start\n"
        "hfi_send_cmd\n"
        "a6xx_gmu_oob_set\n"
        "a6xx_send_cp_init\n";

    if (
        mount_pseudofs(
            "tracefs",
            SHADOW_HELLO_INIT_TRACEFS_ROOT,
            "tracefs",
            MS_NOSUID | MS_NODEV | MS_NOEXEC,
            NULL
        ) != 0
    ) {
        return false;
    }

    if (
        !write_text_path_best_effort(SHADOW_HELLO_INIT_TRACEFS_TRACE_ON_PATH, "0\n") ||
        !write_text_path_best_effort(
            SHADOW_HELLO_INIT_TRACEFS_CURRENT_TRACER_PATH,
            "nop\n"
        ) ||
        !write_text_path_best_effort(SHADOW_HELLO_INIT_TRACEFS_TRACE_PATH, "") ||
        !write_text_path_best_effort(
            SHADOW_HELLO_INIT_TRACEFS_SET_GRAPH_FUNCTION_PATH,
            kKgslTraceFunctions
        ) ||
        !write_text_path_best_effort(
            SHADOW_HELLO_INIT_TRACEFS_CURRENT_TRACER_PATH,
            "function_graph\n"
        ) ||
        !write_text_path_best_effort(SHADOW_HELLO_INIT_TRACEFS_TRACE_ON_PATH, "1\n")
    ) {
        teardown_kgsl_trace_best_effort();
        return false;
    }

    return true;
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

static bool parse_firmware_bootstrap_value(
    const char *raw,
    char *dest,
    size_t dest_size
) {
    char buffer[48];
    char *value;

    if (!copy_string(buffer, sizeof(buffer), raw)) {
        return false;
    }

    value = trim_whitespace(buffer);
    if (strcmp(value, "none") != 0 && strcmp(value, "ramdisk-lib-firmware") != 0) {
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
    char buffer[64];
    char *value;

    if (!copy_string(buffer, sizeof(buffer), raw)) {
        return false;
    }

    value = trim_whitespace(buffer);
    if (
        strcmp(value, "gpu-render") != 0 &&
        strcmp(value, "bundle-smoke") != 0 &&
        strcmp(value, "vulkan-instance-smoke") != 0 &&
        strcmp(value, "raw-vulkan-instance-smoke") != 0 &&
        strcmp(value, "firmware-probe-only") != 0 &&
        strcmp(value, "timeout-control-smoke") != 0 &&
        strcmp(value, "c-kgsl-open-readonly-smoke") != 0 &&
        strcmp(value, "c-kgsl-open-readonly-pid1-smoke") != 0 &&
        strcmp(value, "raw-kgsl-open-readonly-smoke") != 0 &&
        strcmp(value, "raw-kgsl-getproperties-smoke") != 0 &&
        strcmp(value, "raw-vulkan-physical-device-count-query-exit-smoke") != 0 &&
        strcmp(value, "raw-vulkan-physical-device-count-query-no-destroy-smoke") != 0 &&
        strcmp(value, "raw-vulkan-physical-device-count-query-smoke") != 0 &&
        strcmp(value, "raw-vulkan-physical-device-count-smoke") != 0 &&
        strcmp(value, "vulkan-enumerate-adapters-count-smoke") != 0 &&
        strcmp(value, "vulkan-enumerate-adapters-smoke") != 0 &&
        strcmp(value, "vulkan-adapter-smoke") != 0 &&
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

    if (
        strcmp(key, "orange_gpu_launch_delay_secs") == 0 ||
        strcmp(key, "orange-gpu-launch-delay-secs") == 0
    ) {
        if (!parse_unsigned_value(value, &parsed_hold_seconds)) {
            log_boot("<3>", "invalid orange_gpu_launch_delay_secs value: %s", value);
            return;
        }
        config->orange_gpu_launch_delay_secs = parsed_hold_seconds;
        return;
    }

    if (
        strcmp(key, "orange_gpu_parent_probe_attempts") == 0 ||
        strcmp(key, "orange-gpu-parent-probe-attempts") == 0
    ) {
        if (!parse_unsigned_value(value, &parsed_hold_seconds)) {
            log_boot("<3>", "invalid orange_gpu_parent_probe_attempts value: %s", value);
            return;
        }
        config->orange_gpu_parent_probe_attempts = parsed_hold_seconds;
        return;
    }

    if (
        strcmp(key, "orange_gpu_parent_probe_interval_secs") == 0 ||
        strcmp(key, "orange-gpu-parent-probe-interval-secs") == 0
    ) {
        if (!parse_unsigned_value(value, &parsed_hold_seconds)) {
            log_boot("<3>", "invalid orange_gpu_parent_probe_interval_secs value: %s", value);
            return;
        }
        config->orange_gpu_parent_probe_interval_secs = parsed_hold_seconds;
        return;
    }

    if (
        strcmp(key, "orange_gpu_metadata_stage_breadcrumb") == 0 ||
        strcmp(key, "orange-gpu-metadata-stage-breadcrumb") == 0
    ) {
        if (!parse_bool_value(value, &parsed_bool)) {
            log_boot("<3>", "invalid orange_gpu_metadata_stage_breadcrumb value: %s", value);
            return;
        }
        config->orange_gpu_metadata_stage_breadcrumb = parsed_bool;
        return;
    }

    if (
        strcmp(key, "orange_gpu_timeout_action") == 0 ||
        strcmp(key, "orange-gpu-timeout-action") == 0
    ) {
        if (
            strcmp(value, "reboot") != 0 &&
            strcmp(value, "panic") != 0
        ) {
            log_boot("<3>", "invalid orange_gpu_timeout_action value: %s", value);
            return;
        }
        (void)copy_string(
            config->orange_gpu_timeout_action,
            sizeof(config->orange_gpu_timeout_action),
            value
        );
        return;
    }

    if (
        strcmp(key, "orange_gpu_watchdog_timeout_secs") == 0 ||
        strcmp(key, "orange-gpu-watchdog-timeout-secs") == 0
    ) {
        if (!parse_unsigned_value(value, &parsed_hold_seconds)) {
            log_boot("<3>", "invalid orange_gpu_watchdog_timeout_secs value: %s", value);
            return;
        }
        config->orange_gpu_watchdog_timeout_secs = parsed_hold_seconds;
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

    if (strcmp(key, "firmware_bootstrap") == 0) {
        if (
            !parse_firmware_bootstrap_value(
                value,
                config->firmware_bootstrap,
                sizeof(config->firmware_bootstrap)
            )
        ) {
            log_boot("<3>", "invalid firmware_bootstrap value: %s", value);
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

static void trigger_sysrq_best_effort(char trigger) {
    int fd;
    char payload[2];

    fd = open("/proc/sysrq-trigger", O_WRONLY | O_CLOEXEC | O_NOCTTY);
    if (fd < 0) {
        log_stage("<3>", "sysrq-open-failed", "errno=%d", errno);
        log_boot("<3>", "open /proc/sysrq-trigger failed: errno=%d", errno);
        return;
    }

    payload[0] = trigger;
    payload[1] = '\n';
    if (write(fd, payload, sizeof(payload)) != (ssize_t)sizeof(payload)) {
        int saved_errno = errno;

        close(fd);
        log_stage("<3>", "sysrq-write-failed", "trigger=%c errno=%d", trigger, saved_errno);
        log_boot("<3>", "write /proc/sysrq-trigger trigger=%c failed: errno=%d", trigger, saved_errno);
        return;
    }
    close(fd);
    log_stage("<4>", "sysrq-write", "trigger=%c", trigger);
    log_boot("<4>", "sysrq trigger=%c", trigger);
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

static bool orange_gpu_mode_is_vulkan_instance_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "vulkan-instance-smoke") == 0;
}

static bool orange_gpu_mode_is_raw_vulkan_instance_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "raw-vulkan-instance-smoke") == 0;
}

static bool orange_gpu_mode_is_firmware_probe_only(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "firmware-probe-only") == 0;
}

static bool orange_gpu_mode_is_timeout_control_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "timeout-control-smoke") == 0;
}

static bool orange_gpu_mode_is_c_kgsl_open_readonly_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "c-kgsl-open-readonly-smoke") == 0;
}

static bool orange_gpu_mode_is_c_kgsl_open_readonly_pid1_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "c-kgsl-open-readonly-pid1-smoke") == 0;
}

static bool orange_gpu_mode_uses_success_postlude(const struct hello_init_config *config);

static bool orange_gpu_timeout_action_is_panic(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_timeout_action, "panic") == 0;
}

static unsigned int resolve_orange_gpu_payload_watchdog_timeout(
    const struct hello_init_config *config
) {
    if (config->orange_gpu_watchdog_timeout_secs > 0U) {
        return config->orange_gpu_watchdog_timeout_secs;
    }

    return orange_gpu_mode_uses_success_postlude(config)
               ? SHADOW_HELLO_INIT_ORANGE_GPU_WATCHDOG_GRACE_SECONDS
               : config->hold_seconds + SHADOW_HELLO_INIT_ORANGE_GPU_WATCHDOG_GRACE_SECONDS;
}

static bool orange_gpu_mode_is_raw_kgsl_open_readonly_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "raw-kgsl-open-readonly-smoke") == 0;
}

static bool orange_gpu_mode_is_raw_kgsl_getproperties_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "raw-kgsl-getproperties-smoke") == 0;
}

static bool orange_gpu_mode_is_raw_vulkan_physical_device_count_query_exit_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "raw-vulkan-physical-device-count-query-exit-smoke") == 0;
}

static bool orange_gpu_mode_is_raw_vulkan_physical_device_count_query_no_destroy_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "raw-vulkan-physical-device-count-query-no-destroy-smoke") == 0;
}

static bool orange_gpu_mode_is_raw_vulkan_physical_device_count_query_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "raw-vulkan-physical-device-count-query-smoke") == 0;
}

static bool orange_gpu_mode_is_raw_vulkan_physical_device_count_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "raw-vulkan-physical-device-count-smoke") == 0;
}

static bool orange_gpu_mode_is_vulkan_enumerate_adapters_count_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "vulkan-enumerate-adapters-count-smoke") == 0;
}

static bool orange_gpu_mode_is_vulkan_enumerate_adapters_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "vulkan-enumerate-adapters-smoke") == 0;
}

static bool orange_gpu_mode_is_vulkan_adapter_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "vulkan-adapter-smoke") == 0;
}

static bool orange_gpu_mode_is_vulkan_device_request_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "vulkan-device-request-smoke") == 0;
}

static bool orange_gpu_mode_is_vulkan_device_smoke(const struct hello_init_config *config) {
    return strcmp(config->orange_gpu_mode, "vulkan-device-smoke") == 0;
}

static int run_orange_gpu_checkpoint(
    const struct hello_init_config *config,
    const char *checkpoint_name,
    unsigned int hold_seconds
);

static bool orange_gpu_mode_uses_success_postlude(const struct hello_init_config *config) {
    return orange_gpu_mode_is_bundle_smoke(config) ||
           orange_gpu_mode_is_vulkan_instance_smoke(config) ||
           orange_gpu_mode_is_raw_vulkan_instance_smoke(config) ||
           orange_gpu_mode_is_raw_vulkan_physical_device_count_query_exit_smoke(config) ||
           orange_gpu_mode_is_raw_vulkan_physical_device_count_query_no_destroy_smoke(config) ||
           orange_gpu_mode_is_raw_vulkan_physical_device_count_query_smoke(config) ||
           orange_gpu_mode_is_raw_vulkan_physical_device_count_smoke(config) ||
           orange_gpu_mode_is_vulkan_enumerate_adapters_count_smoke(config) ||
           orange_gpu_mode_is_vulkan_enumerate_adapters_smoke(config) ||
           orange_gpu_mode_is_vulkan_adapter_smoke(config) ||
           orange_gpu_mode_is_vulkan_device_request_smoke(config) ||
           orange_gpu_mode_is_vulkan_device_smoke(config) ||
           orange_gpu_mode_is_vulkan_offscreen(config);
}

static bool orange_gpu_checkpoint_is_firmware_probe(const char *checkpoint_name) {
    return checkpoint_name != NULL && strncmp(checkpoint_name, "firmware-probe-", 15U) == 0;
}

static bool orange_gpu_checkpoint_is_timeout_classifier(const char *checkpoint_name) {
    return checkpoint_name != NULL && strncmp(checkpoint_name, "kgsl-timeout-", 13U) == 0;
}

static bool orange_gpu_mode_uses_visible_checkpoints(
    const struct hello_init_config *config,
    const char *checkpoint_name
) {
    if (orange_gpu_mode_uses_success_postlude(config)) {
        return true;
    }

    if (orange_gpu_checkpoint_is_firmware_probe(checkpoint_name)) {
        return orange_gpu_mode_is_firmware_probe_only(config) ||
               orange_gpu_mode_is_timeout_control_smoke(config) ||
               orange_gpu_mode_is_c_kgsl_open_readonly_smoke(config) ||
               orange_gpu_mode_is_c_kgsl_open_readonly_pid1_smoke(config);
    }

    if (orange_gpu_checkpoint_is_timeout_classifier(checkpoint_name)) {
        return orange_gpu_mode_is_timeout_control_smoke(config) ||
               orange_gpu_mode_is_c_kgsl_open_readonly_smoke(config) ||
               orange_gpu_mode_is_c_kgsl_open_readonly_pid1_smoke(config);
    }

    return false;
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
    if (config->orange_gpu_metadata_stage_breadcrumb && !config->mount_dev) {
        log_stage("<3>", "orange-gpu-config-invalid-metadata-stage", "reason=mount_dev_false");
        log_boot("<3>", "orange_gpu_metadata_stage_breadcrumb requires mount_dev=true");
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

static const char *orange_gpu_checkpoint_visual(const char *checkpoint_name) {
    if (checkpoint_name == NULL) {
        return NULL;
    }

    if (strcmp(checkpoint_name, "kgsl-timeout-firmware") == 0) {
        return "solid-red";
    }
    if (strcmp(checkpoint_name, "kgsl-timeout-gmu-hfi") == 0) {
        return "solid-blue";
    }
    if (strcmp(checkpoint_name, "kgsl-timeout-zap") == 0) {
        return "solid-yellow";
    }
    if (strcmp(checkpoint_name, "kgsl-timeout-cp-init") == 0) {
        return "solid-cyan";
    }
    if (strcmp(checkpoint_name, "kgsl-timeout-gx-oob") == 0) {
        return "solid-magenta";
    }
    if (strcmp(checkpoint_name, "kgsl-timeout-control") == 0) {
        return "success-solid";
    }
    if (strcmp(checkpoint_name, "firmware-probe-ok") == 0) {
        return "checker-orange";
    }
    if (
        strcmp(checkpoint_name, "firmware-probe-a630-sqe-open-failed") == 0 ||
        strcmp(checkpoint_name, "firmware-probe-a630-sqe-read-failed") == 0
    ) {
        return "bands-orange";
    }
    if (
        strcmp(checkpoint_name, "firmware-probe-a618-gmu-open-failed") == 0 ||
        strcmp(checkpoint_name, "firmware-probe-a618-gmu-read-failed") == 0
    ) {
        return "orange-vertical-band";
    }
    if (
        strcmp(checkpoint_name, "firmware-probe-a615-zap-mdt-open-failed") == 0 ||
        strcmp(checkpoint_name, "firmware-probe-a615-zap-mdt-read-failed") == 0
    ) {
        return "frame-orange";
    }
    if (strcmp(checkpoint_name, "validated") == 0) {
        return "code-orange-2";
    }
    if (strcmp(checkpoint_name, "probe-ready") == 0) {
        return "code-orange-3";
    }
    if (strcmp(checkpoint_name, "postlude") == 0) {
        return "code-orange-4";
    }
    if (strcmp(checkpoint_name, "watchdog-timeout") == 0) {
        return "code-orange-9";
    }
    if (strcmp(checkpoint_name, "child-signal") == 0) {
        return "code-orange-10";
    }
    if (strcmp(checkpoint_name, "child-exit-nonzero") == 0) {
        return "code-orange-11";
    }
    if (
        strcmp(checkpoint_name, "firmware-probe-a615-zap-b02-open-failed") == 0 ||
        strcmp(checkpoint_name, "firmware-probe-a615-zap-b02-read-failed") == 0
    ) {
        return "frame-orange";
    }

    return "solid-orange";
}

typedef void (*child_watch_timeout_observer_fn)(
    pid_t child_pid,
    unsigned int waited_seconds,
    unsigned int timeout_seconds,
    void *context
);

struct child_watch_result {
    int status;
    bool completed;
    bool timed_out;
    unsigned int waited_seconds;
};

struct probe_timeout_observer_context {
    const char *label;
    const char *probe_stage_path;
    struct metadata_stage_runtime *metadata_stage;
};

struct orange_gpu_timeout_classification {
    const char *checkpoint_name;
    const char *bucket_name;
    const char *matched_needle;
    bool report_present;
};

static void init_child_watch_result(struct child_watch_result *result) {
    memset(result, 0, sizeof(*result));
}

static void sanitize_inline_text(char *text) {
    size_t length;
    size_t index;

    length = strlen(text);
    for (index = 0; index < length; index++) {
        if (text[index] == '\r' || text[index] == '\n' || text[index] == '\t') {
            text[index] = ' ';
        }
    }
    while (length > 0 && text[length - 1] == ' ') {
        text[length - 1] = '\0';
        length--;
    }
}

static bool read_text_file_best_effort(const char *path, char *dest, size_t dest_size) {
    int fd;
    ssize_t bytes_read;

    if (dest_size == 0U) {
        return false;
    }

    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOCTTY);
    if (fd < 0) {
        dest[0] = '\0';
        return false;
    }

    bytes_read = read(fd, dest, dest_size - 1U);
    close(fd);
    if (bytes_read < 0) {
        dest[0] = '\0';
        return false;
    }

    dest[bytes_read] = '\0';
    sanitize_inline_text(dest);
    return true;
}

static bool extract_text_key_value_line(
    const char *text,
    const char *key,
    char *dest,
    size_t dest_size
) {
    const char *line_start = text;
    size_t key_len;

    if (
        text == NULL ||
        key == NULL ||
        dest == NULL ||
        dest_size == 0U
    ) {
        return false;
    }

    dest[0] = '\0';
    key_len = strlen(key);
    while (*line_start != '\0') {
        const char *line_end = strchr(line_start, '\n');
        size_t line_len;

        if (line_end == NULL) {
            line_end = line_start + strlen(line_start);
        }
        line_len = (size_t)(line_end - line_start);
        if (
            line_len > key_len &&
            strncmp(line_start, key, key_len) == 0 &&
            line_start[key_len] == '='
        ) {
            size_t value_len = line_len - key_len - 1U;

            if (value_len >= dest_size) {
                value_len = dest_size - 1U;
            }
            memcpy(dest, line_start + key_len + 1U, value_len);
            dest[value_len] = '\0';
            return true;
        }
        if (*line_end == '\0') {
            break;
        }
        line_start = line_end + 1;
    }

    return false;
}

static bool text_contains_any_needle(
    const char *text,
    const char *const *needles,
    size_t needle_count,
    const char **matched_needle
) {
    size_t index;

    if (matched_needle != NULL) {
        *matched_needle = "";
    }
    if (text == NULL || text[0] == '\0') {
        return false;
    }

    for (index = 0U; index < needle_count; index++) {
        if (strstr(text, needles[index]) != NULL) {
            if (matched_needle != NULL) {
                *matched_needle = needles[index];
            }
            return true;
        }
    }

    return false;
}

static void init_orange_gpu_timeout_classification(
    struct orange_gpu_timeout_classification *classification
) {
    memset(classification, 0, sizeof(*classification));
    classification->checkpoint_name = "watchdog-timeout";
    classification->bucket_name = "generic-watchdog";
    classification->matched_needle = "";
}

static void classify_kgsl_timeout_from_text(
    const char *text,
    struct orange_gpu_timeout_classification *classification
) {
    static const char *const firmware_needles[] = {
        "_request_firmware",
        "request_firmware",
        "a6xx_microcode_read",
        "a6xx_gmu_load_firmware",
    };
    static const char *const zap_needles[] = {
        "subsystem_get",
        "pil_boot",
        "a615_zap",
    };
    static const char *const gx_oob_needles[] = {
        "a6xx_gmu_oob_set",
        "oob_gpu",
        "oob_boot_slumber",
        "a6xx_gmu_gfx_rail_on",
        "a6xx_rpmh_power_on_gpu",
        "a6xx_complete_rpmh_votes",
        "a6xx_gmu_wait_for_lowest_idle",
        "a6xx_gmu_wait_for_idle",
        "a6xx_gmu_notify_slumber",
    };
    static const char *const gmu_hfi_needles[] = {
        "a6xx_gmu_start",
        "a6xx_gmu_fw_start",
        "a6xx_gmu_hfi_start",
        "hfi_start",
        "hfi_send_cmd",
        "hfi_send_gmu_init",
        "hfi_send_core_fw_start",
        "GMU doesn't boot",
        "GMU HFI init failed",
        "Timed out waiting on ack",
    };
    static const char *const cp_init_needles[] = {
        "a6xx_rb_start",
        "a6xx_send_cp_init",
        "adreno_ringbuffer_submit_spin",
        "adreno_spin_idle",
        "adreno_set_unsecured_mode",
        "adreno_switch_to_unsecure_mode",
    };
    const char *matched_needle = "";
    if (
        text_contains_any_needle(
            text,
            firmware_needles,
            sizeof(firmware_needles) / sizeof(firmware_needles[0]),
            &matched_needle
        )
    ) {
        classification->checkpoint_name = "kgsl-timeout-firmware";
        classification->bucket_name = "firmware";
        classification->matched_needle = matched_needle;
        return;
    }
    if (
        text_contains_any_needle(
            text,
            zap_needles,
            sizeof(zap_needles) / sizeof(zap_needles[0]),
            &matched_needle
        )
    ) {
        classification->checkpoint_name = "kgsl-timeout-zap";
        classification->bucket_name = "zap";
        classification->matched_needle = matched_needle;
        return;
    }
    if (
        text_contains_any_needle(
            text,
            gx_oob_needles,
            sizeof(gx_oob_needles) / sizeof(gx_oob_needles[0]),
            &matched_needle
        )
    ) {
        classification->checkpoint_name = "kgsl-timeout-gx-oob";
        classification->bucket_name = "gx-oob";
        classification->matched_needle = matched_needle;
        return;
    }
    if (
        text_contains_any_needle(
            text,
            gmu_hfi_needles,
            sizeof(gmu_hfi_needles) / sizeof(gmu_hfi_needles[0]),
            &matched_needle
        )
    ) {
        classification->checkpoint_name = "kgsl-timeout-gmu-hfi";
        classification->bucket_name = "gmu-hfi";
        classification->matched_needle = matched_needle;
        return;
    }
    if (
        text_contains_any_needle(
            text,
            cp_init_needles,
            sizeof(cp_init_needles) / sizeof(cp_init_needles[0]),
            &matched_needle
        )
    ) {
        classification->checkpoint_name = "kgsl-timeout-cp-init";
        classification->bucket_name = "cp-init";
        classification->matched_needle = matched_needle;
        return;
    }
}

static void classify_kgsl_timeout_from_probe_report(
    const struct metadata_stage_runtime *runtime,
    struct orange_gpu_timeout_classification *classification
) {
    char timeout_class_text[4096];
    char checkpoint_name[128];
    char bucket_name[128];
    char report_text[32768];

    if (
        runtime == NULL ||
        !runtime->enabled ||
        runtime->write_failed ||
        !runtime->prepared
    ) {
        return;
    }

    if (
        read_text_file_best_effort(
            runtime->probe_timeout_class_path,
            timeout_class_text,
            sizeof(timeout_class_text)
        )
    ) {
        classification->report_present = true;
        classify_kgsl_timeout_from_text(timeout_class_text, classification);
        checkpoint_name[0] = '\0';
        bucket_name[0] = '\0';
        (void)extract_text_key_value_line(
            timeout_class_text,
            "classification_checkpoint",
            checkpoint_name,
            sizeof(checkpoint_name)
        );
        (void)extract_text_key_value_line(
            timeout_class_text,
            "classification_bucket",
            bucket_name,
            sizeof(bucket_name)
        );
        if (strcmp(checkpoint_name, "kgsl-timeout-firmware") == 0) {
            classification->checkpoint_name = "kgsl-timeout-firmware";
        } else if (strcmp(checkpoint_name, "kgsl-timeout-zap") == 0) {
            classification->checkpoint_name = "kgsl-timeout-zap";
        } else if (strcmp(checkpoint_name, "kgsl-timeout-gx-oob") == 0) {
            classification->checkpoint_name = "kgsl-timeout-gx-oob";
        } else if (strcmp(checkpoint_name, "kgsl-timeout-gmu-hfi") == 0) {
            classification->checkpoint_name = "kgsl-timeout-gmu-hfi";
        } else if (strcmp(checkpoint_name, "kgsl-timeout-cp-init") == 0) {
            classification->checkpoint_name = "kgsl-timeout-cp-init";
        } else if (strcmp(checkpoint_name, "kgsl-timeout-control") == 0) {
            classification->checkpoint_name = "kgsl-timeout-control";
        }
        if (strcmp(bucket_name, "firmware") == 0) {
            classification->bucket_name = "firmware";
        } else if (strcmp(bucket_name, "zap") == 0) {
            classification->bucket_name = "zap";
        } else if (strcmp(bucket_name, "gx-oob") == 0) {
            classification->bucket_name = "gx-oob";
        } else if (strcmp(bucket_name, "gmu-hfi") == 0) {
            classification->bucket_name = "gmu-hfi";
        } else if (strcmp(bucket_name, "cp-init") == 0) {
            classification->bucket_name = "cp-init";
        } else if (strcmp(bucket_name, "timeout-control") == 0) {
            classification->bucket_name = "timeout-control";
        }
        if (checkpoint_name[0] != '\0' || bucket_name[0] != '\0') {
            return;
        }
        if (strcmp(classification->checkpoint_name, "watchdog-timeout") != 0) {
            return;
        }
    }

    if (!read_text_file_best_effort(runtime->probe_report_path, report_text, sizeof(report_text))) {
        return;
    }

    classification->report_present = true;
    classify_kgsl_timeout_from_text(report_text, classification);
}

static bool append_pid_proc_excerpt(
    char *buffer,
    size_t buffer_size,
    size_t *used,
    pid_t pid,
    const char *name,
    size_t max_bytes
) {
    char path[64];
    int path_len;

    path_len = snprintf(path, sizeof(path), "/proc/%d/%s", pid, name);
    if (path_len < 0 || (size_t)path_len >= sizeof(path)) {
        return false;
    }

    return append_file_excerpt(buffer, buffer_size, used, path, max_bytes);
}

static bool write_metadata_probe_timeout_class_best_effort(
    struct metadata_stage_runtime *runtime,
    const char *label,
    const char *probe_stage_path,
    pid_t observed_pid
) {
    char contents[4096];
    char observed_probe_stage[256];
    char wchan[256];
    char stack_excerpt[2048];
    char classification_text[3072];
    size_t used = 0U;
    bool observed_probe_stage_present = false;
    bool wchan_present = false;
    bool stack_excerpt_present = false;
    struct orange_gpu_timeout_classification classification;

    if (
        runtime == NULL ||
        !runtime->enabled ||
        runtime->write_failed ||
        !runtime->prepared
    ) {
        return false;
    }

    observed_probe_stage_present =
        probe_stage_path != NULL &&
        probe_stage_path[0] != '\0' &&
        read_text_file_best_effort(
            probe_stage_path,
            observed_probe_stage,
            sizeof(observed_probe_stage)
        );
    if (observed_pid > 0) {
        char proc_path[64];
        int proc_path_len;

        proc_path_len = snprintf(proc_path, sizeof(proc_path), "/proc/%d/wchan", observed_pid);
        if (proc_path_len > 0 && (size_t)proc_path_len < sizeof(proc_path)) {
            wchan_present = read_text_file_best_effort(proc_path, wchan, sizeof(wchan));
        }
        proc_path_len = snprintf(proc_path, sizeof(proc_path), "/proc/%d/stack", observed_pid);
        if (proc_path_len > 0 && (size_t)proc_path_len < sizeof(proc_path)) {
            stack_excerpt_present = read_text_file_best_effort(
                proc_path,
                stack_excerpt,
                sizeof(stack_excerpt)
            );
        }
    }

    init_orange_gpu_timeout_classification(&classification);
    classification_text[0] = '\0';
    if (
        snprintf(
            classification_text,
            sizeof(classification_text),
            "observed_probe_stage=%s\nwchan=%s\nstack=%s\n",
            observed_probe_stage_present ? observed_probe_stage : "",
            wchan_present ? wchan : "",
            stack_excerpt_present ? stack_excerpt : ""
    ) < 0
    ) {
        return false;
    }
    classify_kgsl_timeout_from_text(classification_text, &classification);
    log_stage(
        "<4>",
        "orange-gpu-timeout-live-class",
        "label=%s pid=%d observed_probe_stage=%s checkpoint=%s bucket=%s matched_needle=%s wchan=%s",
        label != NULL ? label : "",
        observed_pid,
        observed_probe_stage_present ? observed_probe_stage : "",
        classification.checkpoint_name != NULL ? classification.checkpoint_name : "",
        classification.bucket_name != NULL ? classification.bucket_name : "",
        classification.matched_needle != NULL ? classification.matched_needle : "",
        wchan_present ? wchan : ""
    );
    log_boot(
        "<4>",
        "payload timeout live classification: label=%s pid=%d stage=%s checkpoint=%s bucket=%s matched_needle=%s wchan=%s",
        label != NULL ? label : "",
        observed_pid,
        observed_probe_stage_present ? observed_probe_stage : "",
        classification.checkpoint_name != NULL ? classification.checkpoint_name : "",
        classification.bucket_name != NULL ? classification.bucket_name : "",
        classification.matched_needle != NULL ? classification.matched_needle : "",
        wchan_present ? wchan : ""
    );

    if (
        !append_fingerprintf(contents, sizeof(contents), &used, "probe_label=%s\n", label) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "probe_stage_path=%s\n",
            probe_stage_path != NULL ? probe_stage_path : ""
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "observed_probe_stage_present=%s\n",
            bool_word(observed_probe_stage_present)
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "observed_probe_stage=%s\n",
            observed_probe_stage_present ? observed_probe_stage : ""
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "observed_pid=%d\nwchan_present=%s\nwchan=%s\n",
            observed_pid,
            bool_word(wchan_present),
            wchan_present ? wchan : ""
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "stack_excerpt_present=%s\n",
            bool_word(stack_excerpt_present)
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "classification_checkpoint=%s\nclassification_bucket=%s\nclassification_matched_needle=%s\n",
            classification.checkpoint_name != NULL ? classification.checkpoint_name : "",
            classification.bucket_name != NULL ? classification.bucket_name : "",
            classification.matched_needle != NULL ? classification.matched_needle : ""
        )
    ) {
        log_stage(
            "<4>",
            "metadata-probe-timeout-class-write-skipped",
            "reason=buffer_overflow"
        );
        return false;
    }

    if (
        write_atomic_text_file(
            runtime->stage_dir,
            runtime->temp_probe_timeout_class_path,
            runtime->probe_timeout_class_path,
            contents
        ) != 0
    ) {
        log_stage(
            "<4>",
            "metadata-probe-timeout-class-write-failed",
            "path=%s errno=%d",
            runtime->probe_timeout_class_path,
            errno
        );
        return false;
    }

    log_stage(
        "<6>",
        "metadata-probe-timeout-class-write",
        "path=%s checkpoint=%s bucket=%s matched_needle=%s",
        runtime->probe_timeout_class_path,
        classification.checkpoint_name != NULL ? classification.checkpoint_name : "",
        classification.bucket_name != NULL ? classification.bucket_name : "",
        classification.matched_needle != NULL ? classification.matched_needle : ""
    );
    return true;
}

static bool write_metadata_probe_report_best_effort(
    struct metadata_stage_runtime *runtime,
    const char *label,
    const char *probe_stage_path,
    const struct child_watch_result *result,
    pid_t observed_pid,
    bool capture_live_proc,
    unsigned int timeout_seconds
) {
    char contents[24576];
    char observed_probe_stage[256];
    char wchan[256];
    char syscall_text[512];
    size_t used = 0U;
    bool observed_probe_stage_present = false;
    bool wchan_present = false;
    bool syscall_present = false;

    if (
        runtime == NULL ||
        !runtime->enabled ||
        runtime->write_failed ||
        !runtime->prepared
    ) {
        return false;
    }

    observed_probe_stage_present =
        probe_stage_path != NULL &&
        probe_stage_path[0] != '\0' &&
        read_text_file_best_effort(
            probe_stage_path,
            observed_probe_stage,
            sizeof(observed_probe_stage)
        );
    if (capture_live_proc && observed_pid > 0) {
        char proc_path[64];
        int proc_path_len;

        proc_path_len = snprintf(proc_path, sizeof(proc_path), "/proc/%d/wchan", observed_pid);
        if (proc_path_len > 0 && (size_t)proc_path_len < sizeof(proc_path)) {
            wchan_present = read_text_file_best_effort(proc_path, wchan, sizeof(wchan));
        }
        proc_path_len = snprintf(proc_path, sizeof(proc_path), "/proc/%d/syscall", observed_pid);
        if (proc_path_len > 0 && (size_t)proc_path_len < sizeof(proc_path)) {
            syscall_present = read_text_file_best_effort(
                proc_path,
                syscall_text,
                sizeof(syscall_text)
            );
        }
    }

    if (
        !append_fingerprintf(contents, sizeof(contents), &used, "probe_label=%s\n", label) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "probe_stage_path=%s\n",
            probe_stage_path != NULL ? probe_stage_path : ""
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "observed_probe_stage_present=%s\n",
            bool_word(observed_probe_stage_present)
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "observed_probe_stage=%s\n",
            observed_probe_stage_present ? observed_probe_stage : ""
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "child_completed=%s\nchild_timed_out=%s\nwaited_seconds=%u\ntimeout_seconds=%u\n",
            bool_word(result != NULL && result->completed),
            bool_word(result != NULL && result->timed_out),
            result != NULL ? result->waited_seconds : 0U,
            timeout_seconds
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "exit_status=%d\nsignal=%d\nraw_wait_status=%d\n",
            result != NULL && result->completed && WIFEXITED(result->status)
                ? WEXITSTATUS(result->status)
                : -1,
            result != NULL && result->completed && WIFSIGNALED(result->status)
                ? WTERMSIG(result->status)
                : -1,
            result != NULL ? result->status : 0
        ) ||
        !append_fingerprintf(
            contents,
            sizeof(contents),
            &used,
            "proc_snapshot_attempted=%s\nobserved_pid=%d\nwchan_present=%s\nwchan=%s\nsyscall_present=%s\nsyscall=%s\n",
            bool_word(capture_live_proc && observed_pid > 0),
            observed_pid,
            bool_word(wchan_present),
            wchan_present ? wchan : "",
            bool_word(syscall_present),
            syscall_present ? syscall_text : ""
        )
    ) {
        log_stage("<4>", "metadata-probe-report-write-skipped", "reason=buffer_overflow");
        return false;
    }

    if (capture_live_proc && observed_pid > 0) {
        if (
            !append_pid_namespace_fingerprint_lines(
                contents,
                sizeof(contents),
                &used,
                observed_pid
            ) ||
            !append_pid_proc_excerpt(
                contents,
                sizeof(contents),
                &used,
                observed_pid,
                "attr/current",
                256U
            ) ||
            !append_pid_proc_excerpt(
                contents,
                sizeof(contents),
                &used,
                observed_pid,
                "cgroup",
                512U
            ) ||
            !append_pid_proc_excerpt(
                contents,
                sizeof(contents),
                &used,
                observed_pid,
                "status",
                2048U
            ) ||
            !append_pid_proc_excerpt(
                contents,
                sizeof(contents),
                &used,
                observed_pid,
                "stack",
                4096U
            )
        ) {
            log_stage("<4>", "metadata-probe-report-write-skipped", "reason=proc_excerpt_overflow");
            return false;
        }
    }

    if (
        !append_file_excerpt(
            contents,
            sizeof(contents),
            &used,
            SHADOW_HELLO_INIT_TRACEFS_CURRENT_TRACER_PATH,
            64U
        ) ||
        !append_file_excerpt(
            contents,
            sizeof(contents),
            &used,
            SHADOW_HELLO_INIT_TRACEFS_TRACE_PATH,
            4096U
        )
    ) {
        log_stage("<4>", "metadata-probe-report-write-skipped", "reason=trace_excerpt_overflow");
        return false;
    }

    if (
        write_atomic_text_file(
            runtime->stage_dir,
            runtime->temp_probe_report_path,
            runtime->probe_report_path,
            contents
        ) != 0
    ) {
        log_stage(
            "<4>",
            "metadata-probe-report-write-failed",
            "path=%s errno=%d",
            runtime->probe_report_path,
            errno
        );
        return false;
    }

    log_stage(
        "<6>",
        "metadata-probe-report-write",
        "label=%s path=%s",
        label,
        runtime->probe_report_path
    );
    return true;
}

static void capture_probe_timeout_observer(
    pid_t child_pid,
    unsigned int waited_seconds,
    unsigned int timeout_seconds,
    void *context
) {
    struct probe_timeout_observer_context *observer_context = context;
    struct child_watch_result result;

    if (observer_context == NULL) {
        return;
    }

    init_child_watch_result(&result);
    result.completed = false;
    result.timed_out = true;
    result.waited_seconds = waited_seconds;
    (void)write_metadata_probe_timeout_class_best_effort(
        observer_context->metadata_stage,
        observer_context->label,
        observer_context->probe_stage_path,
        child_pid
    );
    (void)write_metadata_probe_report_best_effort(
        observer_context->metadata_stage,
        observer_context->label,
        observer_context->probe_stage_path,
        &result,
        child_pid,
        true,
        timeout_seconds
    );
}

static void classify_orange_gpu_timeout(
    const struct hello_init_config *config,
    const struct metadata_stage_runtime *metadata_stage,
    struct orange_gpu_timeout_classification *classification
) {
    init_orange_gpu_timeout_classification(classification);
    if (orange_gpu_mode_is_timeout_control_smoke(config)) {
        classification->checkpoint_name = "kgsl-timeout-control";
        classification->bucket_name = "timeout-control";
        classification->matched_needle = "intentional-hang";
        classification->report_present = true;
        return;
    }
    if (!orange_gpu_mode_is_c_kgsl_open_readonly_smoke(config)) {
        return;
    }

    classify_kgsl_timeout_from_probe_report(metadata_stage, classification);
}

static int wait_for_child_with_watchdog(
    pid_t child_pid,
    const char *label,
    unsigned int poll_seconds,
    unsigned int timeout_seconds,
    child_watch_timeout_observer_fn observer,
    void *observer_context,
    struct child_watch_result *result
) {
    if (result == NULL) {
        errno = EINVAL;
        return -1;
    }

    init_child_watch_result(result);
    for (;;) {
        pid_t waited = waitpid(child_pid, &result->status, WNOHANG);

        if (waited == child_pid) {
            result->completed = true;
            return 0;
        }
        if (waited == 0) {
            sleep_seconds(poll_seconds);
            result->waited_seconds += poll_seconds;
            log_stage(
                "<6>",
                "child-wait",
                "label=%s pid=%d seconds=%u",
                label,
                child_pid,
                result->waited_seconds
            );
            if (timeout_seconds > 0U && result->waited_seconds >= timeout_seconds) {
                result->timed_out = true;
                log_stage(
                    "<4>",
                    "child-watchdog-timeout",
                    "label=%s pid=%d waited_seconds=%u timeout_seconds=%u",
                    label,
                    child_pid,
                    result->waited_seconds,
                    timeout_seconds
                );
                if (observer != NULL) {
                    observer(
                        child_pid,
                        result->waited_seconds,
                        timeout_seconds,
                        observer_context
                    );
                }
                if (kill(child_pid, SIGKILL) != 0 && errno != ESRCH) {
                    return -1;
                }
                for (;;) {
                    waited = waitpid(child_pid, &result->status, 0);
                    if (waited == child_pid) {
                        result->completed = true;
                        return 0;
                    }
                    if (waited < 0 && errno == EINTR) {
                        continue;
                    }
                    return -1;
                }
            }
            continue;
        }
        if (errno != EINTR) {
            return -1;
        }
    }
}

static int run_orange_init_payload(
    const struct hello_init_config *config,
    const char *stage_label,
    const char *visual_preset
) {
    pid_t child_pid;
    char hold_seconds[16];
    struct child_watch_result watch_result;

    log_stage(
        "<6>",
        "orange-launch",
        "path=%s hold_seconds=%u stage=%s visual=%s",
        SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
        config->hold_seconds,
        stage_label != NULL ? stage_label : "direct",
        visual_preset != NULL ? visual_preset : "default"
    );
    log_boot("<6>", "%s", kOwnedInitOrangePayloadSentinel);
    log_boot(
        "<6>",
        "launching payload %s stage=%s visual=%s",
        SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
        stage_label != NULL ? stage_label : "direct",
        visual_preset != NULL ? visual_preset : "default"
    );

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
        if (stage_label != NULL && stage_label[0] != '\0') {
            if (setenv(SHADOW_HELLO_INIT_ORANGE_STAGE_ENV, stage_label, 1) != 0) {
                log_stage("<3>", "orange-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_ORANGE_STAGE_ENV, errno);
                _exit(126);
            }
        } else if (unsetenv(SHADOW_HELLO_INIT_ORANGE_STAGE_ENV) != 0) {
            log_stage("<3>", "orange-child-unsetenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_ORANGE_STAGE_ENV, errno);
            _exit(126);
        }
        if (visual_preset != NULL && visual_preset[0] != '\0') {
            if (setenv(SHADOW_HELLO_INIT_ORANGE_VISUAL_ENV, visual_preset, 1) != 0) {
                log_stage("<3>", "orange-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_ORANGE_VISUAL_ENV, errno);
                _exit(126);
            }
        } else if (unsetenv(SHADOW_HELLO_INIT_ORANGE_VISUAL_ENV) != 0) {
            log_stage("<3>", "orange-child-unsetenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_ORANGE_VISUAL_ENV, errno);
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

    if (
        wait_for_child_with_watchdog(
            child_pid,
            "orange-init",
            5U,
            0U,
            NULL,
            NULL,
            &watch_result
        ) != 0
    ) {
        log_stage("<3>", "orange-waitpid-failed", "pid=%d errno=%d", child_pid, errno);
        log_boot("<3>", "waitpid(%d) failed: errno=%d", child_pid, errno);
        return 1;
    }

    if (WIFEXITED(watch_result.status)) {
        log_stage("<6>", "orange-exit", "status=%d", WEXITSTATUS(watch_result.status));
        log_boot(
            "<6>",
            "payload %s exited with status=%d",
            SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
            WEXITSTATUS(watch_result.status)
        );
        return WEXITSTATUS(watch_result.status) == 0 ? 0 : WEXITSTATUS(watch_result.status);
    }

    if (WIFSIGNALED(watch_result.status)) {
        log_stage("<3>", "orange-signal", "signal=%d", WTERMSIG(watch_result.status));
        log_boot(
            "<3>",
            "payload %s died from signal=%d",
            SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
            WTERMSIG(watch_result.status)
        );
        return 128 + WTERMSIG(watch_result.status);
    }

    log_stage("<4>", "orange-unknown-status", "status=%d", watch_result.status);
    log_boot(
        "<4>",
        "payload %s returned unknown wait status=%d",
        SHADOW_HELLO_INIT_ORANGE_PAYLOAD_PATH,
        watch_result.status
    );
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

static int set_orange_gpu_child_env(
    const char *gpu_smoke_stage_path,
    const char *gpu_smoke_stage_prefix
) {
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
    if (gpu_smoke_stage_path != NULL && gpu_smoke_stage_path[0] != '\0') {
        if (setenv(SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PATH_ENV, gpu_smoke_stage_path, 1) != 0) {
            log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PATH_ENV, errno);
            return -1;
        }
    } else if (unsetenv(SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PATH_ENV) != 0) {
        log_stage("<3>", "orange-gpu-child-unsetenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PATH_ENV, errno);
        return -1;
    }
    if (gpu_smoke_stage_prefix != NULL && gpu_smoke_stage_prefix[0] != '\0') {
        if (setenv(SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PREFIX_ENV, gpu_smoke_stage_prefix, 1) != 0) {
            log_stage("<3>", "orange-gpu-child-setenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PREFIX_ENV, errno);
            return -1;
        }
    } else if (unsetenv(SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PREFIX_ENV) != 0) {
        log_stage("<3>", "orange-gpu-child-unsetenv-failed", "name=%s errno=%d", SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PREFIX_ENV, errno);
        return -1;
    }

    return 0;
}

static int run_orange_gpu_parent_probe(
    const struct hello_init_config *config,
    const struct metadata_stage_runtime *metadata_stage,
    char *result_stage,
    size_t result_stage_size
) {
    bool any_succeeded = false;
    unsigned int attempt;

    if (result_stage != NULL && result_stage_size > 0U) {
        (void)copy_string(result_stage, result_stage_size, "parent-probe-result=not-run");
    }

    if (config->orange_gpu_parent_probe_attempts == 0U) {
        log_stage("<6>", "orange-gpu-parent-probe-skip", "attempts=0");
        if (result_stage != NULL && result_stage_size > 0U) {
            (void)copy_string(result_stage, result_stage_size, "parent-probe-result=skipped");
        }
        return 0;
    }

    log_stage(
        "<6>",
        "orange-gpu-parent-probe-start",
        "attempts=%u interval_secs=%u scene=raw-vulkan-physical-device-count-query-exit-smoke",
        config->orange_gpu_parent_probe_attempts,
        config->orange_gpu_parent_probe_interval_secs
    );
    log_boot(
        "<6>",
        "running orange-gpu parent probe attempts=%u interval_secs=%u scene=raw-vulkan-physical-device-count-query-exit-smoke",
        config->orange_gpu_parent_probe_attempts,
        config->orange_gpu_parent_probe_interval_secs
    );

    for (attempt = 1; attempt <= config->orange_gpu_parent_probe_attempts; attempt++) {
        pid_t child_pid;
        unsigned int watchdog_timeout = SHADOW_HELLO_INIT_ORANGE_GPU_WATCHDOG_GRACE_SECONDS;
        char probe_stage_prefix[64];
        const char *probe_stage_path = NULL;
        struct child_watch_result watch_result;

        unlink_best_effort(SHADOW_HELLO_INIT_ORANGE_GPU_PROBE_SUMMARY_PATH);
        unlink_best_effort(SHADOW_HELLO_INIT_ORANGE_GPU_PROBE_OUTPUT_PATH);

        log_stage(
            "<6>",
            "orange-gpu-parent-probe-attempt-start",
            "attempt=%u/%u",
            attempt,
            config->orange_gpu_parent_probe_attempts
        );

        child_pid = fork();
        if (child_pid < 0) {
            log_stage("<3>", "orange-gpu-parent-probe-fork-failed", "attempt=%u errno=%d", attempt, errno);
            log_boot("<3>", "fork for orange-gpu parent probe attempt=%u failed: errno=%d", attempt, errno);
            return 1;
        }
        if (child_pid == 0) {
            if (redirect_child_output_to_path(SHADOW_HELLO_INIT_ORANGE_GPU_PROBE_OUTPUT_PATH) != 0) {
                log_stage("<3>", "orange-gpu-parent-probe-child-redirect-failed", "errno=%d", errno);
                _exit(126);
            }
            if (
                metadata_stage != NULL &&
                metadata_stage->enabled &&
                metadata_stage->prepared &&
                !metadata_stage->write_failed
            ) {
                probe_stage_path = metadata_stage->probe_stage_path;
            }
            snprintf(
                probe_stage_prefix,
                sizeof(probe_stage_prefix),
                "parent-probe-attempt-%u",
                attempt
            );
            if (set_orange_gpu_child_env(probe_stage_path, probe_stage_prefix) != 0) {
                _exit(126);
            }
            log_stage(
                "<6>",
                "orange-gpu-parent-probe-child-exec",
                "argv0=%s binary=%s scene=raw-vulkan-physical-device-count-query-exit-smoke attempt=%u/%u",
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
                attempt,
                config->orange_gpu_parent_probe_attempts
            );
            execl(
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                "--library-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_LIBRARY_PATH,
                SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
                "--scene",
                "raw-vulkan-physical-device-count-query-exit-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_PROBE_SUMMARY_PATH,
                (char *)NULL
            );
            log_stage("<3>", "orange-gpu-parent-probe-exec-failed", "errno=%d", errno);
            log_boot(
                "<3>",
                "exec orange-gpu parent probe via %s failed: errno=%d",
                SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
                errno
            );
            _exit(127);
        }

        log_stage(
            "<6>",
            "orange-gpu-parent-probe-forked",
            "attempt=%u/%u pid=%d",
            attempt,
            config->orange_gpu_parent_probe_attempts,
            child_pid
        );

        if (
            wait_for_child_with_watchdog(
                child_pid,
                "orange-gpu-parent-probe",
                1U,
                watchdog_timeout,
                NULL,
                NULL,
                &watch_result
            ) != 0
        ) {
            log_stage(
                "<3>",
                "orange-gpu-parent-probe-waitpid-failed",
                "attempt=%u/%u pid=%d errno=%d",
                attempt,
                config->orange_gpu_parent_probe_attempts,
                child_pid,
                errno
            );
            log_boot(
                "<3>",
                "waitpid(%d) for orange-gpu parent probe attempt=%u/%u failed: errno=%d",
                child_pid,
                attempt,
                config->orange_gpu_parent_probe_attempts,
                errno
            );
            return 1;
        }

        log_file_best_effort("orange-gpu-parent-probe-output", SHADOW_HELLO_INIT_ORANGE_GPU_PROBE_OUTPUT_PATH);

        if (WIFEXITED(watch_result.status)) {
            if (result_stage != NULL && result_stage_size > 0U) {
                char stage_value[64];

                snprintf(
                    stage_value,
                    sizeof(stage_value),
                    "parent-probe-result=exit-%d",
                    WEXITSTATUS(watch_result.status)
                );
                (void)copy_string(result_stage, result_stage_size, stage_value);
            }
            if (WEXITSTATUS(watch_result.status) == 0) {
                any_succeeded = true;
                log_stage(
                    "<6>",
                    "orange-gpu-parent-probe-attempt-success",
                    "attempt=%u/%u status=0",
                    attempt,
                    config->orange_gpu_parent_probe_attempts
                );
                log_boot(
                    "<6>",
                    "orange-gpu parent probe attempt=%u/%u exited with status=0",
                    attempt,
                    config->orange_gpu_parent_probe_attempts
                );
                break;
            } else {
                log_stage(
                    "<4>",
                    "orange-gpu-parent-probe-attempt-failure",
                    "attempt=%u/%u status=%d",
                    attempt,
                    config->orange_gpu_parent_probe_attempts,
                    WEXITSTATUS(watch_result.status)
                );
                log_boot(
                    "<4>",
                    "orange-gpu parent probe attempt=%u/%u exited with status=%d",
                    attempt,
                    config->orange_gpu_parent_probe_attempts,
                    WEXITSTATUS(watch_result.status)
                );
            }
        } else if (WIFSIGNALED(watch_result.status)) {
            if (result_stage != NULL && result_stage_size > 0U) {
                char stage_value[64];

                snprintf(
                    stage_value,
                    sizeof(stage_value),
                    "parent-probe-result=%s-%d",
                    watch_result.timed_out ? "watchdog-signal" : "signal",
                    WTERMSIG(watch_result.status)
                );
                (void)copy_string(result_stage, result_stage_size, stage_value);
            }
            log_stage(
                "<4>",
                "orange-gpu-parent-probe-attempt-signal",
                "attempt=%u/%u signal=%d",
                attempt,
                config->orange_gpu_parent_probe_attempts,
                WTERMSIG(watch_result.status)
            );
            log_boot(
                "<4>",
                "orange-gpu parent probe attempt=%u/%u died from signal=%d",
                attempt,
                config->orange_gpu_parent_probe_attempts,
                WTERMSIG(watch_result.status)
            );
        } else {
            if (result_stage != NULL && result_stage_size > 0U) {
                char stage_value[64];

                snprintf(
                    stage_value,
                    sizeof(stage_value),
                    "parent-probe-result=unknown-status-%d",
                    watch_result.status
                );
                (void)copy_string(result_stage, result_stage_size, stage_value);
            }
            log_stage(
                "<4>",
                "orange-gpu-parent-probe-attempt-unknown-status",
                "attempt=%u/%u status=%d",
                attempt,
                config->orange_gpu_parent_probe_attempts,
                watch_result.status
            );
            log_boot(
                "<4>",
                "orange-gpu parent probe attempt=%u/%u returned unknown wait status=%d",
                attempt,
                config->orange_gpu_parent_probe_attempts,
                watch_result.status
            );
        }

        if (
            !any_succeeded &&
            attempt < config->orange_gpu_parent_probe_attempts &&
            config->orange_gpu_parent_probe_interval_secs > 0U
        ) {
            log_stage(
                "<6>",
                "orange-gpu-parent-probe-interval",
                "attempt=%u/%u seconds=%u",
                attempt,
                config->orange_gpu_parent_probe_attempts,
                config->orange_gpu_parent_probe_interval_secs
            );
            sleep_seconds(config->orange_gpu_parent_probe_interval_secs);
        }
    }

    log_stage(
        any_succeeded ? "<6>" : "<4>",
        "orange-gpu-parent-probe-complete",
        "attempts=%u interval_secs=%u status=%s",
        config->orange_gpu_parent_probe_attempts,
        config->orange_gpu_parent_probe_interval_secs,
        any_succeeded ? "success" : "failure"
    );
    return any_succeeded ? 0 : 1;
}

static int probe_bootstrap_gpu_firmware(
    const struct hello_init_config *config,
    const char *payload_probe_stage_path,
    const char *payload_probe_stage_prefix
) {
    static const struct {
        const char *path;
        const char *stage_token;
    } kSunfishGpuFirmwarePaths[] = {
        {"/lib/firmware/a630_sqe.fw", "a630-sqe"},
        {"/lib/firmware/a618_gmu.bin", "a618-gmu"},
        {"/lib/firmware/a615_zap.mdt", "a615-zap-mdt"},
        {"/lib/firmware/a615_zap.b02", "a615-zap-b02"},
    };
    size_t index;

    if (strcmp(config->firmware_bootstrap, "ramdisk-lib-firmware") != 0) {
        return 0;
    }

    write_payload_probe_stage_best_effort(
        payload_probe_stage_path,
        payload_probe_stage_prefix,
        "firmware-probe-start"
    );
    for (index = 0; index < sizeof(kSunfishGpuFirmwarePaths) / sizeof(kSunfishGpuFirmwarePaths[0]); index++) {
        int firmware_fd;
        char probe_byte = '\0';
        char stage_value[64];

        firmware_fd = open(
            kSunfishGpuFirmwarePaths[index].path,
            O_RDONLY | O_CLOEXEC | O_NOCTTY
        );
        if (firmware_fd < 0) {
            (void)snprintf(
                stage_value,
                sizeof(stage_value),
                "firmware-probe-%s-open-failed",
                kSunfishGpuFirmwarePaths[index].stage_token
            );
            log_stage(
                "<3>",
                "orange-gpu-firmware-probe-open-failed",
                "path=%s errno=%d",
                kSunfishGpuFirmwarePaths[index].path,
                errno
            );
            write_payload_probe_stage_best_effort(
                payload_probe_stage_path,
                payload_probe_stage_prefix,
                stage_value
            );
            (void)run_orange_gpu_checkpoint(
                config,
                stage_value,
                SHADOW_HELLO_INIT_FIRMWARE_PROBE_CHECKPOINT_HOLD_SECONDS
            );
            return 1;
        }
        if (read(firmware_fd, &probe_byte, 1) < 0) {
            int saved_errno = errno;

            close(firmware_fd);
            errno = saved_errno;
            (void)snprintf(
                stage_value,
                sizeof(stage_value),
                "firmware-probe-%s-read-failed",
                kSunfishGpuFirmwarePaths[index].stage_token
            );
            log_stage(
                "<3>",
                "orange-gpu-firmware-probe-read-failed",
                "path=%s errno=%d",
                kSunfishGpuFirmwarePaths[index].path,
                errno
            );
            write_payload_probe_stage_best_effort(
                payload_probe_stage_path,
                payload_probe_stage_prefix,
                stage_value
            );
            (void)run_orange_gpu_checkpoint(
                config,
                stage_value,
                SHADOW_HELLO_INIT_FIRMWARE_PROBE_CHECKPOINT_HOLD_SECONDS
            );
            return 1;
        }
        close(firmware_fd);
        (void)snprintf(
            stage_value,
            sizeof(stage_value),
            "firmware-probe-%s-ok",
            kSunfishGpuFirmwarePaths[index].stage_token
        );
        write_payload_probe_stage_best_effort(
            payload_probe_stage_path,
            payload_probe_stage_prefix,
            stage_value
        );
        log_stage(
            "<6>",
            "orange-gpu-firmware-probe-ok",
            "path=%s",
            kSunfishGpuFirmwarePaths[index].path
        );
    }

    write_payload_probe_stage_best_effort(
        payload_probe_stage_path,
        payload_probe_stage_prefix,
        "firmware-probe-ok"
    );
    (void)run_orange_gpu_checkpoint(
        config,
        "firmware-probe-ok",
        SHADOW_HELLO_INIT_FIRMWARE_PROBE_CHECKPOINT_HOLD_SECONDS
    );
    return 0;
}

static int run_c_kgsl_open_readonly_smoke(
    const struct hello_init_config *config,
    const char *payload_probe_stage_path,
    const char *payload_probe_stage_prefix
) {
    int kgsl_fd;
    int saved_errno = 0;
    bool trace_enabled = false;

    if (
        probe_bootstrap_gpu_firmware(
            config,
            payload_probe_stage_path,
            payload_probe_stage_prefix
        ) != 0
    ) {
        return 1;
    }

    write_payload_probe_stage_best_effort(
        payload_probe_stage_path,
        payload_probe_stage_prefix,
        "kgsl-open-readonly"
    );
    trace_enabled = setup_kgsl_trace_best_effort();
    log_stage(
        trace_enabled ? "<6>" : "<4>",
        "orange-gpu-c-kgsl-trace",
        "enabled=%s",
        bool_word(trace_enabled)
    );
    log_stage(
        "<6>",
        "orange-gpu-c-kgsl-open-readonly",
        "path=/dev/kgsl-3d0 flags=O_RDONLY|O_CLOEXEC|O_NOCTTY"
    );
    kgsl_fd = open("/dev/kgsl-3d0", O_RDONLY | O_CLOEXEC | O_NOCTTY);
    if (kgsl_fd < 0) {
        saved_errno = errno;
        if (trace_enabled) {
            teardown_kgsl_trace_best_effort();
        }
        errno = saved_errno;
        log_stage("<3>", "orange-gpu-c-kgsl-open-readonly-failed", "errno=%d", errno);
        return 1;
    }
    close(kgsl_fd);
    if (trace_enabled) {
        teardown_kgsl_trace_best_effort();
    }
    write_payload_probe_stage_best_effort(
        payload_probe_stage_path,
        payload_probe_stage_prefix,
        "kgsl-open-readonly-ok"
    );
    log_stage("<6>", "orange-gpu-c-kgsl-open-readonly-ok", "path=/dev/kgsl-3d0");
    return 0;
}

static int run_timeout_control_smoke(
    const struct hello_init_config *config,
    const char *payload_probe_stage_path,
    const char *payload_probe_stage_prefix
) {
    if (
        probe_bootstrap_gpu_firmware(
            config,
            payload_probe_stage_path,
            payload_probe_stage_prefix
        ) != 0
    ) {
        return 1;
    }

    write_payload_probe_stage_best_effort(
        payload_probe_stage_path,
        payload_probe_stage_prefix,
        "timeout-control-sleep"
    );
    log_stage(
        "<6>",
        "orange-gpu-timeout-control",
        "stage=timeout-control-sleep"
    );
    log_boot("<6>", "orange-gpu timeout-control entering intentional hang");

    for (;;) {
        pause();
    }

    return 0;
}

static int run_orange_gpu_payload(
    const struct hello_init_config *config,
    struct metadata_stage_runtime *metadata_stage
) {
    pid_t child_pid;
    int probe_status;
    int probe_checkpoint_status = 0;
    char probe_result_stage[64];
    char hold_seconds[16];
    const char *payload_probe_stage_path = NULL;
    const char *payload_probe_stage_prefix = NULL;
    unsigned int watchdog_timeout = resolve_orange_gpu_payload_watchdog_timeout(config);
    struct child_watch_result watch_result;
    struct orange_gpu_timeout_classification timeout_classification;
    struct probe_timeout_observer_context timeout_observer_context;
    bool kgsl_trace_may_be_active = orange_gpu_mode_is_c_kgsl_open_readonly_smoke(config);

    if (ensure_orange_gpu_runtime_dirs() != 0) {
        return 1;
    }

    unlink_best_effort(SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH);
    unlink_best_effort(SHADOW_HELLO_INIT_ORANGE_GPU_OUTPUT_PATH);

    if (config->orange_gpu_launch_delay_secs == 0U) {
        log_stage("<6>", "orange-gpu-launch-delay-skip", "seconds=0");
    } else {
        log_stage(
            "<6>",
            "orange-gpu-launch-delay",
            "seconds=%u",
            config->orange_gpu_launch_delay_secs
        );
        log_boot(
            "<6>",
            "delaying orange-gpu launch by %u second(s) before fork/exec",
            config->orange_gpu_launch_delay_secs
        );
        sleep_seconds(config->orange_gpu_launch_delay_secs);
        log_stage(
            "<6>",
            "orange-gpu-launch-delay-complete",
            "seconds=%u",
            config->orange_gpu_launch_delay_secs
        );
    }

    if (metadata_stage != NULL) {
        (void)write_metadata_probe_fingerprint_best_effort(config, metadata_stage);
        (void)write_metadata_stage_best_effort(
            metadata_stage,
            "parent-probe-start"
        );
        if (
            metadata_stage->enabled &&
            metadata_stage->prepared &&
            !metadata_stage->write_failed
        ) {
            payload_probe_stage_path = metadata_stage->probe_stage_path;
            payload_probe_stage_prefix = "orange-gpu-payload";
        }
    }
    memset(&timeout_observer_context, 0, sizeof(timeout_observer_context));
    timeout_observer_context.label = "orange-gpu-payload";
    timeout_observer_context.probe_stage_path = payload_probe_stage_path;
    timeout_observer_context.metadata_stage = metadata_stage;
    probe_status = run_orange_gpu_parent_probe(
        config,
        metadata_stage,
        probe_result_stage,
        sizeof(probe_result_stage)
    );
    if (metadata_stage != NULL) {
        (void)write_metadata_stage_best_effort(
            metadata_stage,
            probe_result_stage
        );
    }
    if (probe_status != 0) {
        log_stage(
            "<4>",
            "orange-gpu-parent-probe-continue",
            "status=%d attempts=%u interval_secs=%u",
            probe_status,
            config->orange_gpu_parent_probe_attempts,
            config->orange_gpu_parent_probe_interval_secs
        );
        log_boot(
            "<4>",
            "orange-gpu parent probe returned status=%d; continuing to real payload launch",
            probe_status
        );
    } else if (config->orange_gpu_parent_probe_attempts > 0U) {
        probe_checkpoint_status = run_orange_gpu_checkpoint(config, "probe-ready", 1U);
        if (probe_checkpoint_status != 0) {
            log_stage(
                "<4>",
                "probe-checkpoint-failed",
                "checkpoint=probe-ready status=%d hold_seconds=%u",
                probe_checkpoint_status,
                1U
            );
            log_boot(
                "<4>",
                "orange-gpu checkpoint=probe-ready failed with status=%d; continuing to real payload launch",
                probe_checkpoint_status
            );
        }
    }

    log_stage(
        "<6>",
        "orange-gpu-launch",
        "loader=%s binary=%s mode=%s launch_delay_secs=%u parent_probe_attempts=%u parent_probe_interval_secs=%u hold_seconds=%u",
        SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH,
        SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
        config->orange_gpu_mode,
        config->orange_gpu_launch_delay_secs,
        config->orange_gpu_parent_probe_attempts,
        config->orange_gpu_parent_probe_interval_secs,
        config->hold_seconds
    );
    log_boot("<6>", "%s", kOwnedInitOrangeGpuPayloadSentinel);
    log_boot(
        "<6>",
        "launching payload %s via %s",
        SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
        SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH
    );

    if (orange_gpu_mode_is_c_kgsl_open_readonly_pid1_smoke(config)) {
        log_stage(
            "<6>",
            "orange-gpu-pid1-c-probe",
            "mode=c-kgsl-open-readonly-pid1-smoke"
        );
        return run_c_kgsl_open_readonly_smoke(
            config,
            payload_probe_stage_path,
            payload_probe_stage_prefix
        );
    }

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
        if (set_orange_gpu_child_env(payload_probe_stage_path, payload_probe_stage_prefix) != 0) {
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
        } else if (orange_gpu_mode_is_vulkan_instance_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=instance-smoke mode=vulkan-instance-smoke",
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
                "instance-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_raw_vulkan_instance_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=raw-vulkan-instance-smoke mode=raw-vulkan-instance-smoke",
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
                "raw-vulkan-instance-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_firmware_probe_only(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-c-probe",
                "mode=firmware-probe-only"
            );
            _exit(probe_bootstrap_gpu_firmware(
                config,
                payload_probe_stage_path,
                payload_probe_stage_prefix
            ));
        } else if (orange_gpu_mode_is_timeout_control_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-c-probe",
                "mode=timeout-control-smoke"
            );
            _exit(run_timeout_control_smoke(
                config,
                payload_probe_stage_path,
                payload_probe_stage_prefix
            ));
        } else if (orange_gpu_mode_is_c_kgsl_open_readonly_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-c-probe",
                "mode=c-kgsl-open-readonly-smoke"
            );
            _exit(run_c_kgsl_open_readonly_smoke(
                config,
                payload_probe_stage_path,
                payload_probe_stage_prefix
            ));
        } else if (orange_gpu_mode_is_raw_kgsl_open_readonly_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=raw-kgsl-open-readonly-smoke mode=raw-kgsl-open-readonly-smoke",
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
                "raw-kgsl-open-readonly-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_raw_kgsl_getproperties_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=raw-kgsl-getproperties-smoke mode=raw-kgsl-getproperties-smoke",
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
                "raw-kgsl-getproperties-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=raw-vulkan-physical-device-count-smoke mode=raw-vulkan-physical-device-count-smoke",
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
                "raw-vulkan-physical-device-count-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_query_no_destroy_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=raw-vulkan-physical-device-count-query-no-destroy-smoke mode=raw-vulkan-physical-device-count-query-no-destroy-smoke",
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
                "raw-vulkan-physical-device-count-query-no-destroy-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_query_exit_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=raw-vulkan-physical-device-count-query-exit-smoke mode=raw-vulkan-physical-device-count-query-exit-smoke",
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
                "raw-vulkan-physical-device-count-query-exit-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_query_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=raw-vulkan-physical-device-count-query-smoke mode=raw-vulkan-physical-device-count-query-smoke",
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
                "raw-vulkan-physical-device-count-query-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_vulkan_enumerate_adapters_count_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=enumerate-adapters-count-smoke mode=vulkan-enumerate-adapters-count-smoke",
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
                "enumerate-adapters-count-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_vulkan_enumerate_adapters_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=enumerate-adapters-smoke mode=vulkan-enumerate-adapters-smoke",
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
                "enumerate-adapters-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_vulkan_adapter_smoke(config)) {
            log_stage(
                "<6>",
                "orange-gpu-child-exec",
                "argv0=%s binary=%s scene=adapter-smoke mode=vulkan-adapter-smoke",
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
                "adapter-smoke",
                "--summary-path",
                SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH,
                (char *)NULL
            );
        } else if (orange_gpu_mode_is_vulkan_device_request_smoke(config)) {
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

    if (
        wait_for_child_with_watchdog(
            child_pid,
            "orange-gpu-payload",
            5U,
            watchdog_timeout,
            capture_probe_timeout_observer,
            &timeout_observer_context,
            &watch_result
        ) != 0
    ) {
        if (kgsl_trace_may_be_active) {
            teardown_kgsl_trace_best_effort();
        }
        log_stage("<3>", "orange-gpu-waitpid-failed", "pid=%d errno=%d", child_pid, errno);
        log_boot("<3>", "waitpid(%d) failed: errno=%d", child_pid, errno);
        return 1;
    }

    log_file_best_effort("orange-gpu-output", SHADOW_HELLO_INIT_ORANGE_GPU_OUTPUT_PATH);
    log_file_best_effort("orange-gpu-summary", SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH);

    if (!watch_result.timed_out) {
        (void)write_metadata_probe_report_best_effort(
            metadata_stage,
            "orange-gpu-payload",
            payload_probe_stage_path,
            &watch_result,
            -1,
            false,
            watchdog_timeout
        );
    }
    if (kgsl_trace_may_be_active) {
        teardown_kgsl_trace_best_effort();
    }

    if (watch_result.timed_out) {
        int timeout_checkpoint_status;

        classify_orange_gpu_timeout(config, metadata_stage, &timeout_classification);
        timeout_checkpoint_status = run_orange_gpu_checkpoint(
            config,
            timeout_classification.checkpoint_name,
            SHADOW_HELLO_INIT_TIMEOUT_CLASSIFIER_HOLD_SECONDS
        );
        log_stage(
            "<4>",
            "orange-gpu-timeout",
            "pid=%d waited_seconds=%u timeout_seconds=%u checkpoint=%s checkpoint_status=%d checkpoint_hold_seconds=%u bucket=%s matched_needle=%s report_present=%s",
            child_pid,
            watch_result.waited_seconds,
            watchdog_timeout,
            timeout_classification.checkpoint_name,
            timeout_checkpoint_status,
            SHADOW_HELLO_INIT_TIMEOUT_CLASSIFIER_HOLD_SECONDS,
            timeout_classification.bucket_name,
            timeout_classification.matched_needle,
            bool_word(timeout_classification.report_present)
        );
        log_boot(
            "<4>",
            "payload %s timed out after %u second(s); checkpoint=%s checkpoint_status=%d checkpoint_hold_seconds=%u bucket=%s matched_needle=%s",
            SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
            watchdog_timeout,
            timeout_classification.checkpoint_name,
            timeout_checkpoint_status,
            SHADOW_HELLO_INIT_TIMEOUT_CLASSIFIER_HOLD_SECONDS,
            timeout_classification.bucket_name,
            timeout_classification.matched_needle
        );
        if (orange_gpu_timeout_action_is_panic(config)) {
            log_stage(
                "<4>",
                "orange-gpu-timeout-panic",
                "pid=%d checkpoint=%s bucket=%s matched_needle=%s",
                child_pid,
                timeout_classification.checkpoint_name,
                timeout_classification.bucket_name,
                timeout_classification.matched_needle
            );
            log_boot(
                "<4>",
                "payload timeout escalating to sysrq panic: checkpoint=%s bucket=%s matched_needle=%s",
                timeout_classification.checkpoint_name,
                timeout_classification.bucket_name,
                timeout_classification.matched_needle
            );
            trigger_sysrq_best_effort('w');
            sleep_seconds(1U);
            trigger_sysrq_best_effort('c');
            pause();
        }
        return 124;
    }

    if (WIFEXITED(watch_result.status)) {
        log_stage("<6>", "orange-gpu-exit", "status=%d", WEXITSTATUS(watch_result.status));
        log_boot(
            "<6>",
            "payload %s exited with status=%d",
            SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
            WEXITSTATUS(watch_result.status)
        );
        if (WEXITSTATUS(watch_result.status) != 0) {
            (void)run_orange_gpu_checkpoint(config, "child-exit-nonzero", 1U);
        }
        return WEXITSTATUS(watch_result.status) == 0
            ? 0
            : WEXITSTATUS(watch_result.status);
    }

    if (WIFSIGNALED(watch_result.status)) {
        log_stage("<3>", "orange-gpu-signal", "signal=%d", WTERMSIG(watch_result.status));
        log_boot(
            "<3>",
            "payload %s died from signal=%d",
            SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
            WTERMSIG(watch_result.status)
        );
        (void)run_orange_gpu_checkpoint(config, "child-signal", 1U);
        return 128 + WTERMSIG(watch_result.status);
    }

    log_stage("<4>", "orange-gpu-unknown-status", "status=%d", watch_result.status);
    log_boot(
        "<4>",
        "payload %s returned unknown wait status=%d",
        SHADOW_HELLO_INIT_ORANGE_GPU_BINARY_PATH,
        watch_result.status
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

    return run_orange_init_payload(&prelude_config, "orange-gpu-prelude", "solid-orange");
}

static int run_orange_gpu_checkpoint(
    const struct hello_init_config *config,
    const char *checkpoint_name,
    unsigned int hold_seconds
) {
    struct hello_init_config checkpoint_config;

    if (
        !orange_gpu_mode_uses_visible_checkpoints(config, checkpoint_name) ||
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

    return run_orange_init_payload(
        &checkpoint_config,
        checkpoint_name,
        orange_gpu_checkpoint_visual(checkpoint_name)
    );
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

    return run_orange_init_payload(&postlude_config, "orange-gpu-postlude", "frame-orange");
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
    struct metadata_stage_runtime metadata_stage;
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
    init_metadata_stage_runtime(&config, &metadata_stage);
    (void)copy_string(shadow_run_token, sizeof(shadow_run_token), config.run_token);
    shadow_log_kmsg = config.log_kmsg;
    shadow_log_pmsg = config.log_pmsg;
    log_stage(
        "<6>",
        "pre-dev-bootstrap",
        "payload=%s mount_dev=%s dev_mount=%s dri_bootstrap=%s"
        " firmware_bootstrap=%s",
        config.payload,
        bool_word(config.mount_dev),
        config.dev_mount,
        config.dri_bootstrap,
        config.firmware_bootstrap
    );

    if (config.mount_dev) {
        if (ensure_directory("/dev", 0755) != 0) {
            return 1;
        }
        capture_metadata_block_identity(&config, &metadata_stage);
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
        "payload=%s prelude=%s orange_gpu_mode=%s orange_gpu_launch_delay_secs=%u orange_gpu_parent_probe_attempts=%u orange_gpu_parent_probe_interval_secs=%u orange_gpu_metadata_stage_breadcrumb=%s orange_gpu_timeout_action=%s orange_gpu_watchdog_timeout_secs=%u hold_seconds=%u prelude_hold_seconds=%u reboot_target=%s run_token=%s dev_mount=%s dri_bootstrap=%s firmware_bootstrap=%s mount_dev=%s mount_proc=%s mount_sys=%s log_kmsg=%s log_pmsg=%s",
        config.payload,
        config.prelude,
        config.orange_gpu_mode,
        config.orange_gpu_launch_delay_secs,
        config.orange_gpu_parent_probe_attempts,
        config.orange_gpu_parent_probe_interval_secs,
        bool_word(config.orange_gpu_metadata_stage_breadcrumb),
        config.orange_gpu_timeout_action,
        config.orange_gpu_watchdog_timeout_secs,
        config.hold_seconds,
        config.prelude_hold_seconds,
        config.reboot_target,
        run_token_or_unset(),
        config.dev_mount,
        config.dri_bootstrap,
        config.firmware_bootstrap,
        bool_word(config.mount_dev),
        bool_word(config.mount_proc),
        bool_word(config.mount_sys),
        bool_word(config.log_kmsg),
        bool_word(config.log_pmsg)
    );
    log_boot(
        "<6>",
        "config payload=%s prelude=%s orange_gpu_mode=%s orange_gpu_launch_delay_secs=%u orange_gpu_parent_probe_attempts=%u orange_gpu_parent_probe_interval_secs=%u orange_gpu_metadata_stage_breadcrumb=%s orange_gpu_timeout_action=%s orange_gpu_watchdog_timeout_secs=%u hold_seconds=%u prelude_hold_seconds=%u reboot_target=%s run_token=%s dev_mount=%s dri_bootstrap=%s firmware_bootstrap=%s mount_dev=%s mount_proc=%s mount_sys=%s log_kmsg=%s log_pmsg=%s",
        config.payload,
        config.prelude,
        config.orange_gpu_mode,
        config.orange_gpu_launch_delay_secs,
        config.orange_gpu_parent_probe_attempts,
        config.orange_gpu_parent_probe_interval_secs,
        bool_word(config.orange_gpu_metadata_stage_breadcrumb),
        config.orange_gpu_timeout_action,
        config.orange_gpu_watchdog_timeout_secs,
        config.hold_seconds,
        config.prelude_hold_seconds,
        config.reboot_target,
        run_token_or_unset(),
        config.dev_mount,
        config.dri_bootstrap,
        config.firmware_bootstrap,
        bool_word(config.mount_dev),
        bool_word(config.mount_proc),
        bool_word(config.mount_sys),
        bool_word(config.log_kmsg),
        bool_word(config.log_pmsg)
    );
    if (payload_is_orange_init(&config)) {
        log_stage("<6>", "payload-dispatch", "payload=orange-init");
        payload_status = run_orange_init_payload(&config, "direct-orange-init", "solid-orange");
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
        if (prepare_metadata_stage_runtime_best_effort(&config, &metadata_stage)) {
            (void)write_metadata_stage_best_effort(&metadata_stage, "validated");
        }
        payload_status = run_orange_gpu_payload(&config, &metadata_stage);
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
