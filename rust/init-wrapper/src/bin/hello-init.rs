#![cfg_attr(target_os = "linux", no_main)]

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("hello-init only supports linux targets");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
mod linux {
    use std::ffi::{CStr, CString};
    use std::fmt::Write as _;
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, Read, Write};
    use std::os::unix::ffi::OsStringExt;
    use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
    use std::path::{Path, PathBuf};
    use std::process::{self, Child, Command, Stdio};
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };
    use std::thread::{self, JoinHandle};
    use std::time::{Duration, Instant};

    const CONFIG_PATH: &str = "/shadow-init.cfg";
    const ORANGE_PAYLOAD_PATH: &str = "/orange-init";
    const ORANGE_MODE_ENV: &str = "SHADOW_DRM_RECT_MODE";
    const ORANGE_HOLD_ENV: &str = "SHADOW_DRM_RECT_HOLD_SECS";
    const ORANGE_VISUAL_ENV: &str = "SHADOW_DRM_RECT_VISUAL";
    const ORANGE_STAGE_ENV: &str = "SHADOW_DRM_RECT_STAGE";
    const ORANGE_GPU_ROOT: &str = "/orange-gpu";
    const ORANGE_GPU_BINARY_PATH: &str = "/orange-gpu/shadow-gpu-smoke";
    const ORANGE_GPU_LOADER_PATH: &str = "/orange-gpu/lib/ld-linux-aarch64.so.1";
    const ORANGE_GPU_LIBRARY_PATH: &str = "/orange-gpu/lib";
    const ORANGE_GPU_ICD_PATH: &str = "/orange-gpu/share/vulkan/icd.d/freedreno_icd.aarch64.json";
    const ORANGE_GPU_HOME: &str = "/orange-gpu/home";
    const ORANGE_GPU_CACHE_HOME: &str = "/orange-gpu/home/.cache";
    const ORANGE_GPU_CONFIG_HOME: &str = "/orange-gpu/home/.config";
    const ORANGE_GPU_MESA_CACHE_DIR: &str = "/orange-gpu/home/.cache/mesa";
    const ORANGE_GPU_COMPOSITOR_SESSION_PATH: &str = "/orange-gpu/shadow-session";
    const ORANGE_GPU_COMPOSITOR_BINARY_PATH: &str = "/orange-gpu/shadow-compositor-guest";
    const ORANGE_GPU_COMPOSITOR_STARTUP_CONFIG_PATH: &str =
        "/orange-gpu/compositor-scene-startup.json";
    const ORANGE_GPU_APP_DIRECT_PRESENT_STARTUP_CONFIG_PATH: &str =
        "/orange-gpu/app-direct-present-startup.json";
    const ORANGE_GPU_COMPOSITOR_RUNTIME_DIR: &str = "/shadow-runtime";
    const ORANGE_GPU_COMPOSITOR_DUMMY_CLIENT_PATH: &str = "/orange-gpu/shadow-shell-dummy-client";
    const ORANGE_GPU_SUMMARY_PATH: &str = "/orange-gpu/summary.json";
    const ORANGE_GPU_OUTPUT_PATH: &str = "/orange-gpu/output.log";
    const ORANGE_GPU_PROBE_SUMMARY_PATH: &str = "/orange-gpu/probe-summary.json";
    const ORANGE_GPU_PROBE_OUTPUT_PATH: &str = "/orange-gpu/probe-output.log";
    const FIRMWARE_CLASS_ROOT: &str = "/sys/class/firmware";
    const TRACEFS_ROOT: &str = "/sys/kernel/tracing";
    const TRACEFS_TRACE_PATH: &str = "/sys/kernel/tracing/trace";
    const TRACEFS_TRACING_ON_PATH: &str = "/sys/kernel/tracing/tracing_on";
    const TRACEFS_CURRENT_TRACER_PATH: &str = "/sys/kernel/tracing/current_tracer";
    const TRACEFS_SET_GRAPH_FUNCTION_PATH: &str = "/sys/kernel/tracing/set_graph_function";
    const METADATA_MOUNT_PATH: &str = "/metadata";
    const METADATA_DEVICE_PATH: &str = "/dev/block/by-name/metadata";
    const METADATA_ROOT: &str = "/metadata/shadow-hello-init";
    const METADATA_BY_TOKEN_ROOT: &str = "/metadata/shadow-hello-init/by-token";
    const METADATA_SYSFS_BLOCK_ROOT: &str = "/sys/class/block";
    const METADATA_PARTNAME: &str = "metadata";
    const GPU_BACKEND_ENV: &str = "WGPU_BACKEND";
    const VK_ICD_FILENAMES_ENV: &str = "VK_ICD_FILENAMES";
    const MESA_DRIVER_OVERRIDE_ENV: &str = "MESA_LOADER_DRIVER_OVERRIDE";
    const TU_DEBUG_ENV: &str = "TU_DEBUG";
    const LD_LIBRARY_PATH_ENV: &str = "LD_LIBRARY_PATH";
    const HOME_ENV: &str = "HOME";
    const XDG_CACHE_HOME_ENV: &str = "XDG_CACHE_HOME";
    const XDG_CONFIG_HOME_ENV: &str = "XDG_CONFIG_HOME";
    const MESA_SHADER_CACHE_ENV: &str = "MESA_SHADER_CACHE_DIR";
    const GPU_SMOKE_STAGE_PATH_ENV: &str = "SHADOW_GPU_SMOKE_STAGE_PATH";
    const GPU_SMOKE_STAGE_PREFIX_ENV: &str = "SHADOW_GPU_SMOKE_STAGE_PREFIX";

    const OWNED_INIT_ROLE_SENTINEL: &str = "shadow-owned-init-role:hello-init";
    const OWNED_INIT_IMPL_SENTINEL: &str = "shadow-owned-init-impl:rust-static";
    const OWNED_INIT_CONFIG_SENTINEL: &str = "shadow-owned-init-config:/shadow-init.cfg";
    const OWNED_INIT_ORANGE_SENTINEL: &str = "shadow-owned-init-payload-path:/orange-init";
    const OWNED_INIT_ORANGE_GPU_SENTINEL: &str =
        "shadow-owned-init-payload-path:/orange-gpu/shadow-gpu-smoke";

    const DEFAULT_HOLD_SECONDS: u32 = 30;
    const MAX_HOLD_SECONDS: u32 = 3600;
    const ORANGE_GPU_WATCHDOG_GRACE_SECONDS: u32 = 30;
    const FIRMWARE_HELPER_TIMEOUT_SECONDS: u64 = 15;
    const FIRMWARE_HELPER_POLL_MILLIS: u64 = 50;
    const FIRMWARE_PROBE_CHECKPOINT_HOLD_SECONDS: u32 = 2;
    const ORANGE_GPU_CHECKPOINT_HOLD_SECONDS: u32 = 1;
    const ORANGE_GPU_CHILD_WATCH_POLL_SECONDS: u32 = 5;
    const ORANGE_GPU_TIMEOUT_CLASSIFIER_HOLD_SECONDS: u32 = 3;

    const GPU_FIRMWARE_ENTRIES: [(&str, &str); 4] = [
        ("a630_sqe.fw", "a630-sqe"),
        ("a618_gmu.bin", "a618-gmu"),
        ("a615_zap.mdt", "a615-zap-mdt"),
        ("a615_zap.b02", "a615-zap-b02"),
    ];

    static LOG_KMSG_ENABLED: AtomicBool = AtomicBool::new(true);
    static LOG_PMSG_ENABLED: AtomicBool = AtomicBool::new(true);

    #[derive(Clone, Debug)]
    struct Config {
        payload: String,
        prelude: String,
        orange_gpu_mode: String,
        orange_gpu_mode_seen: bool,
        orange_gpu_mode_invalid: bool,
        orange_gpu_launch_delay_secs: u32,
        orange_gpu_parent_probe_attempts: u32,
        orange_gpu_parent_probe_interval_secs: u32,
        orange_gpu_metadata_stage_breadcrumb: bool,
        orange_gpu_firmware_helper: bool,
        orange_gpu_timeout_action: String,
        orange_gpu_watchdog_timeout_secs: u32,
        hold_seconds: u32,
        prelude_hold_seconds: u32,
        reboot_target: String,
        run_token: String,
        dev_mount: String,
        dri_bootstrap: String,
        firmware_bootstrap: String,
        mount_dev: bool,
        mount_proc: bool,
        mount_sys: bool,
        log_kmsg: bool,
        log_pmsg: bool,
    }

    impl Default for Config {
        fn default() -> Self {
            Self {
                payload: "hello".to_string(),
                prelude: "none".to_string(),
                orange_gpu_mode: "gpu-render".to_string(),
                orange_gpu_mode_seen: false,
                orange_gpu_mode_invalid: false,
                orange_gpu_launch_delay_secs: 0,
                orange_gpu_parent_probe_attempts: 0,
                orange_gpu_parent_probe_interval_secs: 0,
                orange_gpu_metadata_stage_breadcrumb: false,
                orange_gpu_firmware_helper: false,
                orange_gpu_timeout_action: "reboot".to_string(),
                orange_gpu_watchdog_timeout_secs: 0,
                hold_seconds: DEFAULT_HOLD_SECONDS,
                prelude_hold_seconds: 0,
                reboot_target: "bootloader".to_string(),
                run_token: String::new(),
                dev_mount: "devtmpfs".to_string(),
                dri_bootstrap: "none".to_string(),
                firmware_bootstrap: "none".to_string(),
                mount_dev: true,
                mount_proc: true,
                mount_sys: true,
                log_kmsg: true,
                log_pmsg: true,
            }
        }
    }

    #[derive(Clone, Debug, Default)]
    struct BlockDeviceIdentity {
        available: bool,
        major_num: u32,
        minor_num: u32,
    }

    #[derive(Clone, Debug, Default)]
    struct MetadataStageRuntime {
        enabled: bool,
        prepared: bool,
        write_failed: bool,
        block_device: BlockDeviceIdentity,
        stage_dir: PathBuf,
        stage_path: PathBuf,
        temp_stage_path: PathBuf,
        probe_stage_path: PathBuf,
        temp_probe_stage_path: PathBuf,
        probe_fingerprint_path: PathBuf,
        temp_probe_fingerprint_path: PathBuf,
        probe_report_path: PathBuf,
        temp_probe_report_path: PathBuf,
        probe_timeout_class_path: PathBuf,
        temp_probe_timeout_class_path: PathBuf,
        probe_summary_path: PathBuf,
        temp_probe_summary_path: PathBuf,
        compositor_frame_path: PathBuf,
    }

    struct FirmwareHelper {
        stop: Arc<AtomicBool>,
        handle: Option<JoinHandle<()>>,
    }

    struct KgslTraceMonitor {
        stop: Arc<AtomicBool>,
        handle: Option<JoinHandle<()>>,
    }

    #[derive(Default)]
    struct Args {
        selftest: bool,
        owned_child: bool,
        config_path: Option<String>,
        orange_gpu_child_mode: Option<String>,
        argv0: Option<String>,
    }

    impl FirmwareHelper {
        fn start(probe_stage_path: Option<PathBuf>, probe_stage_prefix: Option<String>) -> Self {
            let stop = Arc::new(AtomicBool::new(false));
            let thread_stop = Arc::clone(&stop);
            let handle = thread::spawn(move || {
                run_ramdisk_firmware_helper_loop(thread_stop, probe_stage_path, probe_stage_prefix);
            });
            Self {
                stop,
                handle: Some(handle),
            }
        }

        fn stop(mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(handle) = self.handle.take() {
                let _ = handle.join();
            }
        }
    }

    impl KgslTraceMonitor {
        fn start(probe_stage_path: PathBuf, probe_stage_prefix: String) -> Self {
            let stop = Arc::new(AtomicBool::new(false));
            let thread_stop = Arc::clone(&stop);
            let handle = thread::spawn(move || {
                run_kgsl_trace_monitor_loop(thread_stop, probe_stage_path, probe_stage_prefix);
            });
            Self {
                stop,
                handle: Some(handle),
            }
        }

        fn stop(mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(handle) = self.handle.take() {
                let _ = handle.join();
            }
        }
    }

    #[derive(Default)]
    struct ChildWatchResult {
        completed: bool,
        timed_out: bool,
        waited_seconds: u32,
        exit_status: Option<i32>,
        signal: Option<i32>,
        raw_wait_status: i32,
    }

    #[derive(Clone, Debug)]
    struct OrangeGpuTimeoutClassification {
        checkpoint_name: String,
        bucket_name: String,
        matched_needle: String,
        report_present: bool,
    }

    impl Default for OrangeGpuTimeoutClassification {
        fn default() -> Self {
            Self {
                checkpoint_name: "watchdog-timeout".to_string(),
                bucket_name: "generic-watchdog".to_string(),
                matched_needle: String::new(),
                report_present: false,
            }
        }
    }

    fn bool_word(value: bool) -> &'static str {
        if value {
            "true"
        } else {
            "false"
        }
    }

    fn current_boot_id() -> Option<String> {
        fs::read_to_string("/proc/sys/kernel/random/boot_id")
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    }

    fn raw_write_fd(fd: libc::c_int, payload: &[u8]) {
        unsafe {
            libc::write(fd, payload.as_ptr().cast(), payload.len());
        }
    }

    fn write_to_kmsg(message: &str) {
        if !LOG_KMSG_ENABLED.load(Ordering::Relaxed) {
            return;
        }
        let Ok(kmsg_path) = CString::new("/dev/kmsg") else {
            return;
        };
        let fd = unsafe {
            libc::open(
                kmsg_path.as_ptr(),
                libc::O_WRONLY | libc::O_CLOEXEC | libc::O_NOCTTY,
            )
        };
        if fd < 0 {
            return;
        }
        let payload = format!("<6>[shadow-hello-init] {message}\n");
        raw_write_fd(fd, payload.as_bytes());
        unsafe {
            libc::close(fd);
        }
    }

    fn write_to_pmsg(message: &str) {
        if !LOG_PMSG_ENABLED.load(Ordering::Relaxed) {
            return;
        }
        let Ok(pmsg_path) = CString::new("/dev/pmsg0") else {
            return;
        };
        let fd = unsafe {
            libc::open(
                pmsg_path.as_ptr(),
                libc::O_WRONLY | libc::O_CLOEXEC | libc::O_NOCTTY,
            )
        };
        if fd < 0 {
            return;
        }
        let payload = format!("[shadow-hello-init] {message}\n");
        raw_write_fd(fd, payload.as_bytes());
        unsafe {
            libc::close(fd);
        }
    }

    fn log_line(message: &str) {
        let payload = format!("[shadow-hello-init] {message}\n");
        raw_write_fd(1, payload.as_bytes());
        raw_write_fd(2, payload.as_bytes());
        write_to_kmsg(message);
        write_to_pmsg(message);
    }

    fn set_log_channel_preferences(config: &Config) {
        LOG_KMSG_ENABLED.store(config.log_kmsg, Ordering::Relaxed);
        LOG_PMSG_ENABLED.store(config.log_pmsg, Ordering::Relaxed);
    }

    fn ensure_directory(path: &Path, mode: u32) -> io::Result<()> {
        fs::create_dir_all(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
        Ok(())
    }

    fn ensure_node(path: &Path, mode: u32, dev: libc::dev_t) -> io::Result<()> {
        if let Ok(metadata) = fs::symlink_metadata(path) {
            if metadata.file_type().is_char_device() || metadata.file_type().is_block_device() {
                return Ok(());
            }
            fs::remove_file(path)?;
        }

        let c_path = CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
        let result = unsafe { libc::mknod(c_path.as_ptr(), mode as libc::mode_t, dev) };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        fs::set_permissions(path, fs::Permissions::from_mode(mode & 0o7777))?;
        Ok(())
    }

    fn ensure_char_device(path: &Path, perm: u32, major: u64, minor: u64) -> io::Result<()> {
        ensure_node(path, libc::S_IFCHR | perm, unsafe {
            libc::makedev(major as u32, minor as u32)
        })
    }

    fn ensure_block_device(path: &Path, perm: u32, major: u64, minor: u64) -> io::Result<()> {
        ensure_node(path, libc::S_IFBLK | perm, unsafe {
            libc::makedev(major as u32, minor as u32)
        })
    }

    fn ensure_symlink_target(path: &Path, target: &Path) -> io::Result<()> {
        match fs::symlink_metadata(path) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Ok(());
                }
                if metadata.is_file() {
                    fs::remove_file(path)?;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        std::os::unix::fs::symlink(target, path)
    }

    fn ensure_stdio_fds() -> io::Result<()> {
        let dev_null = CString::new("/dev/null").unwrap();
        for fd in [0, 1, 2] {
            let status = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if status >= 0 {
                continue;
            }
            let opened = unsafe { libc::open(dev_null.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
            if opened < 0 {
                return Err(io::Error::last_os_error());
            }
            if opened != fd {
                let dup_rc = unsafe { libc::dup2(opened, fd) };
                let saved = io::Error::last_os_error();
                unsafe {
                    libc::close(opened);
                }
                if dup_rc < 0 {
                    return Err(saved);
                }
            }
        }
        Ok(())
    }

    fn mount_fs(
        source: &str,
        target: &str,
        fstype: &str,
        flags: libc::c_ulong,
        data: Option<&str>,
    ) -> io::Result<()> {
        let source_c = CString::new(source).unwrap();
        let target_c = CString::new(target).unwrap();
        let fstype_c = CString::new(fstype).unwrap();
        let data_c = data.map(|value| CString::new(value).unwrap());
        let rc = unsafe {
            libc::mount(
                source_c.as_ptr(),
                target_c.as_ptr(),
                fstype_c.as_ptr(),
                flags,
                data_c
                    .as_ref()
                    .map(|value| value.as_ptr() as *const libc::c_void)
                    .unwrap_or(std::ptr::null()),
            )
        };
        if rc == 0 {
            return Ok(());
        }
        let err = io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EBUSY) {
            return Ok(());
        }
        Err(err)
    }

    fn sleep_seconds(seconds: u32) {
        thread::sleep(Duration::from_secs(seconds as u64));
    }

    fn hold_for_observation(seconds: u32) {
        if seconds == 0 {
            return;
        }
        sleep_seconds(seconds);
    }

    fn run_token_or_unset(config: &Config) -> &str {
        if config.run_token.is_empty() {
            "unset"
        } else {
            &config.run_token
        }
    }

    fn append_wrapper_log(message: &str) {
        log_line(message);
    }

    fn parse_bool(value: &str) -> Option<bool> {
        match value.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Some(true),
            "0" | "false" | "no" | "off" => Some(false),
            _ => None,
        }
    }

    fn parse_u32(value: &str) -> Option<u32> {
        let parsed = value.trim().parse::<u32>().ok()?;
        if parsed > MAX_HOLD_SECONDS {
            return None;
        }
        Some(parsed)
    }

    fn parse_allowed(value: &str, allowed: &[&str]) -> Option<String> {
        let trimmed = value.trim();
        if allowed.iter().any(|candidate| *candidate == trimmed) {
            Some(trimmed.to_string())
        } else {
            None
        }
    }

    fn parse_run_token(value: &str) -> Option<String> {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return None;
        }
        if trimmed
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            Some(trimmed.to_string())
        } else {
            None
        }
    }

    fn parse_args_raw(argc: libc::c_int, argv: *const *const libc::c_char) -> Args {
        let mut args = Args::default();
        if argc <= 1 || argv.is_null() {
            return args;
        }

        let argc = usize::try_from(argc).unwrap_or(0);
        if argc <= 1 {
            return args;
        }

        let raw_args = unsafe { std::slice::from_raw_parts(argv, argc) };
        if let Some(raw_argv0) = raw_args.first().copied() {
            if !raw_argv0.is_null() {
                let argv0_bytes = unsafe { CStr::from_ptr(raw_argv0) }.to_bytes().to_vec();
                let argv0 = std::ffi::OsString::from_vec(argv0_bytes);
                args.argv0 = Some(argv0.to_string_lossy().into_owned());
            }
        }
        let mut index = 1usize;
        while index < raw_args.len() {
            let Some(raw_arg) = raw_args.get(index).copied() else {
                break;
            };
            if raw_arg.is_null() {
                index += 1;
                continue;
            }

            let arg_bytes = unsafe { CStr::from_ptr(raw_arg) }.to_bytes();
            if arg_bytes == b"--selftest" {
                args.selftest = true;
                index += 1;
                continue;
            }
            if arg_bytes == b"--owned-child" {
                args.owned_child = true;
                index += 1;
                continue;
            }
            if arg_bytes == b"--orange-gpu-child-mode" {
                if let Some(raw_value) = raw_args.get(index + 1).copied() {
                    if !raw_value.is_null() {
                        let mode_bytes = unsafe { CStr::from_ptr(raw_value) }.to_bytes().to_vec();
                        let mode = std::ffi::OsString::from_vec(mode_bytes)
                            .to_string_lossy()
                            .into_owned();
                        if matches!(
                            mode.as_str(),
                            "timeout-control-smoke"
                                | "c-kgsl-open-readonly-smoke"
                                | "c-kgsl-open-readonly-firmware-helper-smoke"
                        ) {
                            args.orange_gpu_child_mode = Some(mode);
                        }
                    }
                    index += 2;
                    continue;
                }
            }
            if arg_bytes == b"--config" {
                if let Some(raw_value) = raw_args.get(index + 1).copied() {
                    if !raw_value.is_null() {
                        let config_bytes = unsafe { CStr::from_ptr(raw_value) }.to_bytes().to_vec();
                        let config_path = std::ffi::OsString::from_vec(config_bytes);
                        args.config_path = Some(config_path.to_string_lossy().into_owned());
                    }
                    index += 2;
                    continue;
                }
            }
            index += 1;
        }
        args
    }

    fn load_config(config_path: &str) -> Config {
        let mut config = Config::default();
        let payload = match fs::read_to_string(config_path) {
            Ok(payload) => payload,
            Err(error) => {
                log_line(&format!("failed to read {config_path}: {error}"));
                return config;
            }
        };

        for raw_line in payload.lines() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            match key.trim() {
                "payload" => config.payload = value.trim().to_string(),
                "prelude" => {
                    if let Some(parsed) = parse_allowed(value, &["none", "orange-init"]) {
                        config.prelude = parsed;
                    }
                }
                "orange_gpu_mode" | "orange-gpu-mode" => {
                    match parse_allowed(
                        value,
                        &[
                            "gpu-render",
                            "orange-gpu-loop",
                            "bundle-smoke",
                            "vulkan-instance-smoke",
                            "raw-vulkan-instance-smoke",
                            "timeout-control-smoke",
                            "c-kgsl-open-readonly-smoke",
                            "c-kgsl-open-readonly-firmware-helper-smoke",
                            "c-kgsl-open-readonly-pid1-smoke",
                            "raw-kgsl-open-readonly-smoke",
                            "raw-kgsl-getproperties-smoke",
                            "raw-vulkan-physical-device-count-query-exit-smoke",
                            "raw-vulkan-physical-device-count-query-no-destroy-smoke",
                            "raw-vulkan-physical-device-count-query-smoke",
                            "raw-vulkan-physical-device-count-smoke",
                            "vulkan-enumerate-adapters-count-smoke",
                            "vulkan-enumerate-adapters-smoke",
                            "vulkan-adapter-smoke",
                            "vulkan-device-request-smoke",
                            "vulkan-device-smoke",
                            "vulkan-offscreen",
                            "compositor-scene",
                            "app-direct-present",
                            "firmware-probe-only",
                        ],
                    ) {
                        Some(parsed) => {
                            config.orange_gpu_mode = parsed;
                            config.orange_gpu_mode_seen = true;
                            config.orange_gpu_mode_invalid = false;
                        }
                        None => {
                            config.orange_gpu_mode_invalid = true;
                        }
                    }
                }
                "orange_gpu_launch_delay_secs" | "orange-gpu-launch-delay-secs" => {
                    if let Some(parsed) = parse_u32(value) {
                        config.orange_gpu_launch_delay_secs = parsed;
                    }
                }
                "orange_gpu_parent_probe_attempts" | "orange-gpu-parent-probe-attempts" => {
                    if let Some(parsed) = parse_u32(value) {
                        config.orange_gpu_parent_probe_attempts = parsed;
                    }
                }
                "orange_gpu_parent_probe_interval_secs"
                | "orange-gpu-parent-probe-interval-secs" => {
                    if let Some(parsed) = parse_u32(value) {
                        config.orange_gpu_parent_probe_interval_secs = parsed;
                    }
                }
                "orange_gpu_metadata_stage_breadcrumb" | "orange-gpu-metadata-stage-breadcrumb" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.orange_gpu_metadata_stage_breadcrumb = parsed;
                    }
                }
                "orange_gpu_firmware_helper" | "orange-gpu-firmware-helper" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.orange_gpu_firmware_helper = parsed;
                    }
                }
                "orange_gpu_timeout_action" | "orange-gpu-timeout-action" => {
                    if let Some(parsed) = parse_allowed(value, &["reboot", "panic"]) {
                        config.orange_gpu_timeout_action = parsed;
                    }
                }
                "orange_gpu_watchdog_timeout_secs" | "orange-gpu-watchdog-timeout-secs" => {
                    if let Some(parsed) = parse_u32(value) {
                        config.orange_gpu_watchdog_timeout_secs = parsed;
                    }
                }
                "hold_seconds" | "hold_secs" => {
                    if let Some(parsed) = parse_u32(value) {
                        config.hold_seconds = parsed;
                    }
                }
                "prelude_hold_seconds" | "prelude_hold_secs" => {
                    if let Some(parsed) = parse_u32(value) {
                        config.prelude_hold_seconds = parsed;
                    }
                }
                "reboot_target" => config.reboot_target = value.trim().to_string(),
                "run_token" => {
                    if let Some(parsed) = parse_run_token(value) {
                        config.run_token = parsed;
                    }
                }
                "mount_dev" | "mount_devtmpfs" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.mount_dev = parsed;
                    }
                }
                "dev_mount" | "dev_mount_style" => {
                    if let Some(parsed) = parse_allowed(value, &["devtmpfs", "tmpfs"]) {
                        config.dev_mount = parsed;
                    }
                }
                "dri_bootstrap" => {
                    if let Some(parsed) = parse_allowed(
                        value,
                        &[
                            "none",
                            "sunfish-card0-renderD128",
                            "sunfish-card0-renderD128-kgsl3d0",
                        ],
                    ) {
                        config.dri_bootstrap = parsed;
                    }
                }
                "firmware_bootstrap" => {
                    if let Some(parsed) = parse_allowed(value, &["none", "ramdisk-lib-firmware"]) {
                        config.firmware_bootstrap = parsed;
                    }
                }
                "mount_proc" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.mount_proc = parsed;
                    }
                }
                "mount_sys" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.mount_sys = parsed;
                    }
                }
                "log_kmsg" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.log_kmsg = parsed;
                    }
                }
                "log_pmsg" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.log_pmsg = parsed;
                    }
                }
                _ => {}
            }
        }

        config
    }

    fn init_metadata_stage_runtime(config: &Config) -> MetadataStageRuntime {
        let mut runtime = MetadataStageRuntime::default();
        runtime.enabled = config.orange_gpu_metadata_stage_breadcrumb
            && config.mount_dev
            && !config.run_token.is_empty();
        if !runtime.enabled {
            return runtime;
        }

        runtime.stage_dir = Path::new(METADATA_BY_TOKEN_ROOT).join(&config.run_token);
        runtime.stage_path = runtime.stage_dir.join("stage.txt");
        runtime.temp_stage_path = runtime.stage_dir.join(".stage.txt.tmp");
        runtime.probe_stage_path = runtime.stage_dir.join("probe-stage.txt");
        runtime.temp_probe_stage_path = runtime.stage_dir.join(".probe-stage.txt.tmp");
        runtime.probe_fingerprint_path = runtime.stage_dir.join("probe-fingerprint.txt");
        runtime.temp_probe_fingerprint_path = runtime.stage_dir.join(".probe-fingerprint.txt.tmp");
        runtime.probe_report_path = runtime.stage_dir.join("probe-report.txt");
        runtime.temp_probe_report_path = runtime.stage_dir.join(".probe-report.txt.tmp");
        runtime.probe_timeout_class_path = runtime.stage_dir.join("probe-timeout-class.txt");
        runtime.temp_probe_timeout_class_path =
            runtime.stage_dir.join(".probe-timeout-class.txt.tmp");
        runtime.probe_summary_path = runtime.stage_dir.join("probe-summary.json");
        runtime.temp_probe_summary_path = runtime.stage_dir.join(".probe-summary.json.tmp");
        runtime.compositor_frame_path = runtime.stage_dir.join("compositor-frame.ppm");
        runtime
    }

    fn capture_metadata_block_identity(runtime: &mut MetadataStageRuntime, config: &Config) {
        if !runtime.enabled || config.dev_mount != "tmpfs" {
            return;
        }
        let Ok(metadata) = fs::metadata(METADATA_DEVICE_PATH) else {
            return;
        };
        if !metadata.file_type().is_block_device() {
            return;
        }
        use std::os::unix::fs::MetadataExt;
        let rdev = metadata.rdev();
        runtime.block_device = BlockDeviceIdentity {
            available: true,
            major_num: libc::major(rdev) as u32,
            minor_num: libc::minor(rdev) as u32,
        };
    }

    fn discover_metadata_block_identity_from_sysfs(
        runtime: &mut MetadataStageRuntime,
        config: &Config,
    ) {
        if !runtime.enabled
            || runtime.block_device.available
            || config.dev_mount != "tmpfs"
            || !config.mount_sys
        {
            return;
        }
        let Ok(entries) = fs::read_dir(METADATA_SYSFS_BLOCK_ROOT) else {
            return;
        };
        for entry in entries.flatten() {
            let uevent_path = entry.path().join("uevent");
            let Ok(text) = fs::read_to_string(&uevent_path) else {
                continue;
            };
            let mut partname_matches = false;
            let mut major_num = None;
            let mut minor_num = None;
            for line in text.lines() {
                if let Some(value) = line.strip_prefix("PARTNAME=") {
                    partname_matches = value == METADATA_PARTNAME;
                } else if let Some(value) = line.strip_prefix("MAJOR=") {
                    major_num = value.parse::<u32>().ok();
                } else if let Some(value) = line.strip_prefix("MINOR=") {
                    minor_num = value.parse::<u32>().ok();
                }
            }
            if partname_matches {
                if let (Some(major_num), Some(minor_num)) = (major_num, minor_num) {
                    runtime.block_device = BlockDeviceIdentity {
                        available: true,
                        major_num,
                        minor_num,
                    };
                    break;
                }
            }
        }
    }

    fn write_atomic_text_file(
        temp_path: &Path,
        final_path: &Path,
        contents: &str,
    ) -> io::Result<()> {
        let parent = final_path
            .parent()
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "missing parent"))?;
        {
            let mut file = OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(temp_path)?;
            file.write_all(contents.as_bytes())?;
            file.sync_all()?;
        }
        fs::rename(temp_path, final_path)?;
        let dir = File::open(parent)?;
        dir.sync_all()?;
        Ok(())
    }

    fn write_metadata_stage(runtime: &mut MetadataStageRuntime, value: &str) {
        if !runtime.enabled || runtime.write_failed || !runtime.prepared {
            return;
        }
        let payload = format!("{value}\n");
        if write_atomic_text_file(&runtime.temp_stage_path, &runtime.stage_path, &payload).is_err()
        {
            runtime.write_failed = true;
        }
    }

    fn write_payload_probe_stage(path: Option<&Path>, prefix: Option<&str>, value: &str) {
        let (Some(path), Some(prefix)) = (path, prefix) else {
            return;
        };
        let temp_path = path.with_extension("tmp");
        let payload = format!("{prefix}:{value}\n");
        let _ = write_atomic_text_file(&temp_path, path, &payload);
    }

    fn read_probe_stage_value(runtime: &MetadataStageRuntime) -> String {
        let Ok(text) = fs::read_to_string(&runtime.probe_stage_path) else {
            return String::new();
        };
        normalize_probe_stage_value(&text)
    }

    fn normalize_probe_stage_value(value: &str) -> String {
        let trimmed = value.trim();
        match trimmed.split_once(':') {
            Some((_, suffix)) => suffix.to_string(),
            None => trimmed.to_string(),
        }
    }

    fn sanitize_inline_text(value: &str) -> String {
        value
            .trim_end_matches(['\r', '\n'])
            .chars()
            .map(|ch| match ch {
                '\r' | '\n' | '\t' => ' ',
                other => other,
            })
            .collect::<String>()
            .trim_end()
            .to_string()
    }

    fn read_inline_text_file(path: &str) -> Option<String> {
        fs::read_to_string(path)
            .ok()
            .map(|text| sanitize_inline_text(&text))
    }

    fn append_pid_namespace_fingerprint_lines(payload: &mut String, pid: u32) {
        for label in ["mnt", "pid", "uts", "ipc", "net"] {
            let path = format!("/proc/{pid}/ns/{label}");
            match fs::read_link(&path) {
                Ok(target) => {
                    let _ = writeln!(payload, "ns_{}={}", label, target.display());
                }
                Err(error) => {
                    let _ = writeln!(
                        payload,
                        "ns_{}=<unavailable errno={:?} error={}>",
                        label,
                        error.raw_os_error(),
                        error
                    );
                }
            }
        }
    }

    fn append_pid_proc_excerpt(payload: &mut String, pid: u32, name: &str, max_bytes: usize) {
        append_file_excerpt(payload, &format!("/proc/{pid}/{name}"), max_bytes);
    }

    fn extract_text_key_value_line(text: &str, key: &str) -> Option<String> {
        text.lines()
            .find_map(|line| line.strip_prefix(&format!("{key}=")))
            .map(ToString::to_string)
    }

    fn text_contains_any_needle(text: &str, needles: &[&str]) -> Option<String> {
        if text.is_empty() {
            return None;
        }
        needles
            .iter()
            .find(|needle| text.contains(**needle))
            .map(|needle| (*needle).to_string())
    }

    fn classify_kgsl_timeout_from_text(
        text: &str,
        classification: &mut OrangeGpuTimeoutClassification,
    ) {
        let firmware_needles = [
            "_request_firmware",
            "request_firmware",
            "a6xx_microcode_read",
            "a6xx_gmu_load_firmware",
        ];
        let zap_needles = ["subsystem_get", "pil_boot", "a615_zap"];
        let gx_oob_needles = [
            "a6xx_gmu_oob_set",
            "oob_gpu",
            "oob_boot_slumber",
            "a6xx_gmu_gfx_rail_on",
            "a6xx_rpmh_power_on_gpu",
            "a6xx_complete_rpmh_votes",
            "a6xx_gmu_wait_for_lowest_idle",
            "a6xx_gmu_wait_for_idle",
            "a6xx_gmu_notify_slumber",
        ];
        let gmu_hfi_needles = [
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
        ];
        let cp_init_needles = [
            "a6xx_rb_start",
            "a6xx_send_cp_init",
            "adreno_ringbuffer_submit_spin",
            "adreno_spin_idle",
            "adreno_set_unsecured_mode",
            "adreno_switch_to_unsecure_mode",
        ];

        if let Some(matched_needle) = text_contains_any_needle(text, &firmware_needles) {
            classification.checkpoint_name = "kgsl-timeout-firmware".to_string();
            classification.bucket_name = "firmware".to_string();
            classification.matched_needle = matched_needle;
            return;
        }
        if let Some(matched_needle) = text_contains_any_needle(text, &zap_needles) {
            classification.checkpoint_name = "kgsl-timeout-zap".to_string();
            classification.bucket_name = "zap".to_string();
            classification.matched_needle = matched_needle;
            return;
        }
        if let Some(matched_needle) = text_contains_any_needle(text, &gx_oob_needles) {
            classification.checkpoint_name = "kgsl-timeout-gx-oob".to_string();
            classification.bucket_name = "gx-oob".to_string();
            classification.matched_needle = matched_needle;
            return;
        }
        if let Some(matched_needle) = text_contains_any_needle(text, &gmu_hfi_needles) {
            classification.checkpoint_name = "kgsl-timeout-gmu-hfi".to_string();
            classification.bucket_name = "gmu-hfi".to_string();
            classification.matched_needle = matched_needle;
            return;
        }
        if let Some(matched_needle) = text_contains_any_needle(text, &cp_init_needles) {
            classification.checkpoint_name = "kgsl-timeout-cp-init".to_string();
            classification.bucket_name = "cp-init".to_string();
            classification.matched_needle = matched_needle;
        }
    }

    fn orange_gpu_checkpoint_is_firmware_probe(checkpoint_name: &str) -> bool {
        checkpoint_name.starts_with("firmware-probe-")
    }

    fn orange_gpu_checkpoint_is_timeout_classifier(checkpoint_name: &str) -> bool {
        checkpoint_name.starts_with("kgsl-timeout-")
    }

    fn orange_gpu_mode_is_any_c_kgsl_open_readonly_smoke(mode: &str) -> bool {
        matches!(
            mode,
            "c-kgsl-open-readonly-smoke" | "c-kgsl-open-readonly-firmware-helper-smoke"
        )
    }

    fn orange_gpu_mode_is_c_kgsl_open_readonly_pid1_smoke(mode: &str) -> bool {
        mode == "c-kgsl-open-readonly-pid1-smoke"
    }

    fn orange_gpu_mode_is_compositor_scene(mode: &str) -> bool {
        mode == "compositor-scene"
    }

    fn orange_gpu_mode_is_app_direct_present(mode: &str) -> bool {
        mode == "app-direct-present"
    }

    fn orange_gpu_mode_uses_session_frame_capture(mode: &str) -> bool {
        orange_gpu_mode_is_compositor_scene(mode) || orange_gpu_mode_is_app_direct_present(mode)
    }

    fn orange_gpu_mode_uses_visible_checkpoints(mode: &str, checkpoint_name: &str) -> bool {
        if orange_gpu_mode_uses_success_postlude(mode) {
            return true;
        }
        if orange_gpu_checkpoint_is_firmware_probe(checkpoint_name) {
            return matches!(
                mode,
                "firmware-probe-only"
                    | "timeout-control-smoke"
                    | "c-kgsl-open-readonly-smoke"
                    | "c-kgsl-open-readonly-firmware-helper-smoke"
                    | "c-kgsl-open-readonly-pid1-smoke"
            );
        }
        if orange_gpu_checkpoint_is_timeout_classifier(checkpoint_name) {
            return matches!(
                mode,
                "timeout-control-smoke"
                    | "c-kgsl-open-readonly-smoke"
                    | "c-kgsl-open-readonly-firmware-helper-smoke"
                    | "c-kgsl-open-readonly-pid1-smoke"
            );
        }
        false
    }

    fn orange_gpu_checkpoint_visual(checkpoint_name: &str) -> &'static str {
        match checkpoint_name {
            "kgsl-timeout-firmware" => "solid-red",
            "kgsl-timeout-gmu-hfi" => "solid-blue",
            "kgsl-timeout-zap" => "solid-yellow",
            "kgsl-timeout-cp-init" => "solid-cyan",
            "kgsl-timeout-gx-oob" => "solid-magenta",
            "kgsl-timeout-control" => "success-solid",
            "firmware-probe-ok" => "checker-orange",
            "firmware-probe-a630-sqe-open-failed" | "firmware-probe-a630-sqe-read-failed" => {
                "bands-orange"
            }
            "firmware-probe-a618-gmu-open-failed" | "firmware-probe-a618-gmu-read-failed" => {
                "orange-vertical-band"
            }
            "firmware-probe-a615-zap-mdt-open-failed"
            | "firmware-probe-a615-zap-mdt-read-failed"
            | "firmware-probe-a615-zap-b02-open-failed"
            | "firmware-probe-a615-zap-b02-read-failed" => "frame-orange",
            "validated" => "code-orange-2",
            "probe-ready" => "code-orange-3",
            "postlude" => "code-orange-4",
            "watchdog-timeout" => "code-orange-9",
            "child-signal" => "code-orange-10",
            "child-exit-nonzero" => "code-orange-11",
            _ => "solid-orange",
        }
    }

    fn write_text_path_best_effort(path: &str, contents: &str) -> bool {
        fs::write(path, contents).is_ok()
    }

    fn teardown_kgsl_trace_best_effort() {
        let _ = write_text_path_best_effort(TRACEFS_TRACING_ON_PATH, "0\n");
        let _ = write_text_path_best_effort(TRACEFS_CURRENT_TRACER_PATH, "nop\n");
    }

    fn setup_kgsl_trace_best_effort() -> bool {
        const KGSL_TRACE_FUNCTIONS: &str = concat!(
            "a6xx_microcode_read\n",
            "a6xx_gmu_load_firmware\n",
            "subsystem_get\n",
            "pil_boot\n",
            "gmu_start\n",
            "a6xx_gmu_fw_start\n",
            "a6xx_gmu_start\n",
            "a6xx_gmu_hfi_start\n",
            "hfi_send_cmd\n",
            "a6xx_gmu_oob_set\n",
            "a6xx_send_cp_init\n"
        );

        if mount_fs(
            "tracefs",
            TRACEFS_ROOT,
            "tracefs",
            (libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC) as libc::c_ulong,
            None,
        )
        .is_err()
        {
            return false;
        }
        if !write_text_path_best_effort(TRACEFS_TRACING_ON_PATH, "0\n")
            || !write_text_path_best_effort(TRACEFS_CURRENT_TRACER_PATH, "nop\n")
            || !write_text_path_best_effort(TRACEFS_TRACE_PATH, "")
            || !write_text_path_best_effort(TRACEFS_SET_GRAPH_FUNCTION_PATH, KGSL_TRACE_FUNCTIONS)
            || !write_text_path_best_effort(TRACEFS_CURRENT_TRACER_PATH, "function_graph\n")
            || !write_text_path_best_effort(TRACEFS_TRACING_ON_PATH, "1\n")
        {
            teardown_kgsl_trace_best_effort();
            return false;
        }
        true
    }

    fn highest_kgsl_trace_stage_from_text(trace_text: &str) -> Option<&'static str> {
        if trace_text.contains("a6xx_send_cp_init") {
            return Some("trace-cp-init");
        }
        if trace_text.contains("a6xx_gmu_hfi_start") {
            return Some("trace-gmu-hfi-start");
        }
        if [
            "a6xx_gmu_oob_set",
            "a6xx_gmu_start",
            "a6xx_gmu_fw_start",
            "gmu_start",
        ]
        .iter()
        .any(|needle| trace_text.contains(needle))
        {
            return Some("trace-gmu-start");
        }
        if trace_text.contains("pil_boot") {
            return Some("trace-pil-boot");
        }
        if trace_text.contains("subsystem_get") {
            return Some("trace-subsystem-get");
        }
        if ["a6xx_gmu_load_firmware", "a6xx_microcode_read"]
            .iter()
            .any(|needle| trace_text.contains(needle))
        {
            return Some("trace-microcode-read");
        }
        None
    }

    fn run_kgsl_trace_monitor_loop(
        stop: Arc<AtomicBool>,
        probe_stage_path: PathBuf,
        probe_stage_prefix: String,
    ) {
        let mut last_stage = String::new();
        while !stop.load(Ordering::Relaxed) {
            if let Ok(trace_text) = fs::read_to_string(TRACEFS_TRACE_PATH) {
                if let Some(trace_stage) = highest_kgsl_trace_stage_from_text(&trace_text) {
                    if trace_stage != last_stage {
                        write_payload_probe_stage(
                            Some(probe_stage_path.as_path()),
                            Some(probe_stage_prefix.as_str()),
                            trace_stage,
                        );
                        last_stage = trace_stage.to_string();
                    }
                }
            }
            sleep_seconds(1);
        }
    }

    fn classify_kgsl_timeout_from_probe_report(
        runtime: &MetadataStageRuntime,
        classification: &mut OrangeGpuTimeoutClassification,
    ) {
        if !runtime.enabled || runtime.write_failed || !runtime.prepared {
            return;
        }

        if let Ok(timeout_class_text) = fs::read_to_string(&runtime.probe_timeout_class_path) {
            classification.report_present = true;
            classify_kgsl_timeout_from_text(&timeout_class_text, classification);
            if let Some(checkpoint_name) =
                extract_text_key_value_line(&timeout_class_text, "classification_checkpoint")
            {
                if !checkpoint_name.is_empty() {
                    classification.checkpoint_name = checkpoint_name;
                }
            }
            if let Some(bucket_name) =
                extract_text_key_value_line(&timeout_class_text, "classification_bucket")
            {
                if !bucket_name.is_empty() {
                    classification.bucket_name = bucket_name;
                }
            }
            if let Some(matched_needle) =
                extract_text_key_value_line(&timeout_class_text, "classification_matched_needle")
            {
                classification.matched_needle = matched_needle;
            }
            if classification.checkpoint_name != "watchdog-timeout"
                || classification.bucket_name != "generic-watchdog"
            {
                return;
            }
        }

        if let Ok(report_text) = fs::read_to_string(&runtime.probe_report_path) {
            classification.report_present = true;
            classify_kgsl_timeout_from_text(&report_text, classification);
        }
    }

    fn write_metadata_probe_timeout_class(
        runtime: &mut MetadataStageRuntime,
        label: &str,
        probe_stage_path: Option<&Path>,
        observed_pid: u32,
    ) {
        if !runtime.enabled || runtime.write_failed || !runtime.prepared {
            return;
        }

        let observed_probe_stage = probe_stage_path
            .and_then(|path| fs::read_to_string(path).ok())
            .map(|text| normalize_probe_stage_value(&text))
            .unwrap_or_default();
        let observed_probe_stage_present = !observed_probe_stage.is_empty();
        let wchan_path = format!("/proc/{observed_pid}/wchan");
        let stack_path = format!("/proc/{observed_pid}/stack");
        let wchan = read_inline_text_file(&wchan_path).unwrap_or_default();
        let wchan_present = !wchan.is_empty();
        let stack_excerpt_present = fs::metadata(&stack_path).is_ok();

        let mut classification = OrangeGpuTimeoutClassification::default();
        let classification_text = format!(
            "observed_probe_stage={}\nwchan={}\nstack={}\n",
            observed_probe_stage,
            wchan,
            read_file_excerpt(&stack_path, 2048)
        );
        classify_kgsl_timeout_from_text(&classification_text, &mut classification);

        let mut payload = String::new();
        let _ = writeln!(payload, "probe_label={label}");
        let _ = writeln!(
            payload,
            "probe_stage_path={}",
            probe_stage_path
                .map(|path| path.display().to_string())
                .unwrap_or_default()
        );
        let _ = writeln!(
            payload,
            "observed_probe_stage_present={}",
            bool_word(observed_probe_stage_present)
        );
        let _ = writeln!(payload, "observed_probe_stage={observed_probe_stage}");
        let _ = writeln!(payload, "observed_pid={observed_pid}");
        let _ = writeln!(payload, "wchan_present={}", bool_word(wchan_present));
        let _ = writeln!(payload, "wchan={wchan}");
        let _ = writeln!(
            payload,
            "stack_excerpt_present={}",
            bool_word(stack_excerpt_present)
        );
        let _ = writeln!(
            payload,
            "classification_checkpoint={}",
            classification.checkpoint_name
        );
        let _ = writeln!(
            payload,
            "classification_bucket={}",
            classification.bucket_name
        );
        let _ = writeln!(
            payload,
            "classification_matched_needle={}",
            classification.matched_needle
        );
        if write_atomic_text_file(
            &runtime.temp_probe_timeout_class_path,
            &runtime.probe_timeout_class_path,
            &payload,
        )
        .is_err()
        {
            runtime.write_failed = true;
        }
    }

    fn classify_orange_gpu_timeout(
        config: &Config,
        runtime: &MetadataStageRuntime,
    ) -> OrangeGpuTimeoutClassification {
        if config.orange_gpu_mode == "timeout-control-smoke" {
            return OrangeGpuTimeoutClassification {
                checkpoint_name: "kgsl-timeout-control".to_string(),
                bucket_name: "timeout-control".to_string(),
                matched_needle: "intentional-hang".to_string(),
                report_present: true,
            };
        }
        let mut classification = OrangeGpuTimeoutClassification::default();
        if orange_gpu_mode_is_any_c_kgsl_open_readonly_smoke(&config.orange_gpu_mode) {
            classify_kgsl_timeout_from_probe_report(runtime, &mut classification);
        }
        classification
    }

    fn remove_file_best_effort(path: &str) {
        let _ = fs::remove_file(path);
    }

    fn read_file_excerpt(path: &str, max_bytes: usize) -> String {
        match fs::read(path) {
            Ok(bytes) => {
                let mut text =
                    String::from_utf8_lossy(&bytes[..bytes.len().min(max_bytes)]).into_owned();
                if bytes.len() > max_bytes {
                    if !text.ends_with('\n') {
                        text.push('\n');
                    }
                    text.push_str("<truncated>\n");
                } else if !text.ends_with('\n') {
                    text.push('\n');
                }
                text
            }
            Err(error) => format!(
                "<unavailable errno={:?} error={}>\n",
                error.raw_os_error(),
                error
            ),
        }
    }

    fn append_file_excerpt(payload: &mut String, path: &str, max_bytes: usize) {
        let _ = writeln!(payload, "begin:{}<<", path);
        payload.push_str(&read_file_excerpt(path, max_bytes));
        let _ = writeln!(payload, ">>end:{}", path);
    }

    fn append_namespace_fingerprint_lines(payload: &mut String) {
        for label in ["mnt", "pid", "uts", "ipc", "net"] {
            let path = format!("/proc/self/ns/{label}");
            match fs::read_link(&path) {
                Ok(target) => {
                    let _ = writeln!(payload, "ns_{}={}", label, target.display());
                }
                Err(error) => {
                    let _ = writeln!(
                        payload,
                        "ns_{}=<unavailable errno={:?} error={}>",
                        label,
                        error.raw_os_error(),
                        error
                    );
                }
            }
        }
    }

    fn append_path_fingerprint_line(payload: &mut String, path: &str) {
        match fs::symlink_metadata(path) {
            Ok(metadata) => {
                let file_type = if metadata.file_type().is_char_device() {
                    "char"
                } else if metadata.file_type().is_block_device() {
                    "block"
                } else if metadata.file_type().is_symlink() {
                    "symlink"
                } else if metadata.file_type().is_dir() {
                    "dir"
                } else if metadata.file_type().is_file() {
                    "file"
                } else {
                    "other"
                };
                let (major_num, minor_num) = if metadata.file_type().is_char_device()
                    || metadata.file_type().is_block_device()
                {
                    let rdev = metadata.rdev();
                    (libc::major(rdev) as u64, libc::minor(rdev) as u64)
                } else {
                    (0, 0)
                };
                let _ = writeln!(
                    payload,
                    "path={} exists=true type={} mode={:o} uid={} gid={} size={} major={} minor={}",
                    path,
                    file_type,
                    metadata.mode() & 0o7777,
                    metadata.uid(),
                    metadata.gid(),
                    metadata.len(),
                    major_num,
                    minor_num
                );
            }
            Err(error) => {
                let _ = writeln!(
                    payload,
                    "path={} exists=false errno={:?} error={}",
                    path,
                    error.raw_os_error(),
                    error
                );
            }
        }
    }

    fn current_group_ids() -> Option<Vec<u32>> {
        let group_count = unsafe { libc::getgroups(0, std::ptr::null_mut()) };
        if group_count < 0 {
            return None;
        }
        if group_count == 0 {
            return Some(Vec::new());
        }
        let mut groups = vec![0 as libc::gid_t; group_count as usize];
        let actual_count = unsafe { libc::getgroups(group_count, groups.as_mut_ptr()) };
        if actual_count < 0 {
            return None;
        }
        groups.truncate(actual_count as usize);
        Some(groups.into_iter().map(|group| group as u32).collect())
    }

    fn write_metadata_probe_fingerprint(runtime: &mut MetadataStageRuntime, config: &Config) {
        if !runtime.enabled || runtime.write_failed || !runtime.prepared {
            return;
        }

        let mut payload = String::new();
        let _ = writeln!(payload, "run_token={}", run_token_or_unset(config));
        let _ = writeln!(
            payload,
            "mount_dev={} mount_proc={} mount_sys={} dev_mount={} metadata_prepared={}",
            bool_word(config.mount_dev),
            bool_word(config.mount_proc),
            bool_word(config.mount_sys),
            config.dev_mount,
            bool_word(runtime.prepared)
        );
        if let Some(boot_id) = current_boot_id() {
            let _ = writeln!(payload, "boot_id={boot_id}");
        }
        match current_group_ids() {
            Some(groups) => {
                let _ = writeln!(
                    payload,
                    "groups={}",
                    groups
                        .iter()
                        .map(u32::to_string)
                        .collect::<Vec<_>>()
                        .join(",")
                );
            }
            None => {
                payload.push_str("groups=<unavailable>\n");
            }
        }
        append_file_excerpt(&mut payload, "/proc/self/attr/current", 256);
        append_file_excerpt(&mut payload, "/proc/self/cgroup", 512);
        append_namespace_fingerprint_lines(&mut payload);
        append_file_excerpt(&mut payload, "/proc/self/mountinfo", 1536);
        append_path_fingerprint_line(&mut payload, "/dev/kgsl-3d0");
        append_path_fingerprint_line(&mut payload, "/dev/dri/card0");
        append_path_fingerprint_line(&mut payload, "/dev/dri/renderD128");
        append_path_fingerprint_line(&mut payload, "/dev/dma_heap/system");
        append_path_fingerprint_line(&mut payload, "/dev/ion");
        append_path_fingerprint_line(&mut payload, ORANGE_GPU_ICD_PATH);
        append_file_excerpt(&mut payload, "/proc/mounts", 1024);
        append_file_excerpt(&mut payload, ORANGE_GPU_ICD_PATH, 512);

        if write_atomic_text_file(
            &runtime.temp_probe_fingerprint_path,
            &runtime.probe_fingerprint_path,
            &payload,
        )
        .is_err()
        {
            runtime.write_failed = true;
        }
    }

    fn write_probe_report(
        runtime: &mut MetadataStageRuntime,
        label: &str,
        probe_stage_path: Option<&Path>,
        child_result: &ChildWatchResult,
        observed_pid: Option<u32>,
        capture_live_proc: bool,
        timeout_seconds: u32,
    ) {
        if !runtime.enabled || runtime.write_failed || !runtime.prepared {
            return;
        }

        let observed_probe_stage = probe_stage_path
            .and_then(|path| fs::read_to_string(path).ok())
            .map(|text| normalize_probe_stage_value(&text))
            .unwrap_or_default();
        let observed_probe_stage_present = !observed_probe_stage.is_empty();
        let proc_snapshot_attempted = capture_live_proc && observed_pid.is_some();
        let wchan = observed_pid
            .filter(|_| capture_live_proc)
            .and_then(|pid| read_inline_text_file(&format!("/proc/{pid}/wchan")))
            .unwrap_or_default();
        let wchan_present = !wchan.is_empty();
        let syscall_text = observed_pid
            .filter(|_| capture_live_proc)
            .and_then(|pid| read_inline_text_file(&format!("/proc/{pid}/syscall")))
            .unwrap_or_default();
        let syscall_present = !syscall_text.is_empty();
        let mut payload = String::new();
        let _ = writeln!(payload, "probe_label={label}");
        let _ = writeln!(
            payload,
            "probe_stage_path={}",
            probe_stage_path
                .map(|path| path.display().to_string())
                .unwrap_or_default()
        );
        let _ = writeln!(
            payload,
            "observed_probe_stage_present={}",
            bool_word(observed_probe_stage_present)
        );
        let _ = writeln!(payload, "observed_probe_stage={observed_probe_stage}");
        let _ = writeln!(
            payload,
            "child_completed={}",
            bool_word(child_result.completed)
        );
        let _ = writeln!(
            payload,
            "child_timed_out={}",
            bool_word(child_result.timed_out)
        );
        let _ = writeln!(payload, "waited_seconds={}", child_result.waited_seconds);
        let _ = writeln!(payload, "timeout_seconds={timeout_seconds}");
        if let Some(exit_status) = child_result.exit_status {
            let _ = writeln!(payload, "exit_status={exit_status}");
        } else {
            payload.push_str("exit_status=\n");
        }
        if let Some(signal) = child_result.signal {
            let _ = writeln!(payload, "signal={signal}");
        } else {
            payload.push_str("signal=\n");
        }
        let _ = writeln!(payload, "raw_wait_status={}", child_result.raw_wait_status);
        let _ = writeln!(
            payload,
            "proc_snapshot_attempted={}",
            bool_word(proc_snapshot_attempted)
        );
        let _ = writeln!(payload, "observed_pid={}", observed_pid.unwrap_or(0));
        let _ = writeln!(payload, "wchan_present={}", bool_word(wchan_present));
        let _ = writeln!(payload, "wchan={wchan}");
        let _ = writeln!(payload, "syscall_present={}", bool_word(syscall_present));
        let _ = writeln!(payload, "syscall={syscall_text}");

        if capture_live_proc {
            if let Some(pid) = observed_pid {
                append_pid_namespace_fingerprint_lines(&mut payload, pid);
                append_pid_proc_excerpt(&mut payload, pid, "attr/current", 256);
                append_pid_proc_excerpt(&mut payload, pid, "cgroup", 512);
                append_pid_proc_excerpt(&mut payload, pid, "status", 2048);
                append_pid_proc_excerpt(&mut payload, pid, "stack", 4096);
            }
        }

        append_file_excerpt(&mut payload, TRACEFS_CURRENT_TRACER_PATH, 64);
        append_file_excerpt(&mut payload, TRACEFS_TRACE_PATH, 4096);

        if write_atomic_text_file(
            &runtime.temp_probe_report_path,
            &runtime.probe_report_path,
            &payload,
        )
        .is_err()
        {
            runtime.write_failed = true;
        }
    }

    fn record_probe_summary(
        runtime: &mut MetadataStageRuntime,
        source_path: &str,
    ) -> Option<String> {
        if !runtime.enabled || runtime.write_failed || !runtime.prepared {
            return None;
        }
        let summary_text = match fs::read_to_string(source_path) {
            Ok(summary_text) if !summary_text.trim().is_empty() => summary_text,
            _ => return None,
        };
        if write_atomic_text_file(
            &runtime.temp_probe_summary_path,
            &runtime.probe_summary_path,
            &summary_text,
        )
        .is_err()
        {
            runtime.write_failed = true;
            return None;
        }
        Some(summary_text)
    }

    fn record_session_frame_summary(
        runtime: &mut MetadataStageRuntime,
        kind: &str,
        startup_mode: &str,
        app_id: Option<&str>,
    ) -> Result<(), &'static str> {
        if !runtime.enabled || runtime.write_failed || !runtime.prepared {
            return Err("metadata-disabled");
        }
        let metadata = fs::metadata(&runtime.compositor_frame_path).map_err(|_| "frame-missing")?;
        let frame_bytes = metadata.len();
        if frame_bytes == 0 {
            return Err("frame-empty");
        }

        let frame_path = runtime.compositor_frame_path.display();
        let mut payload =
            format!("{{\n  \"kind\": \"{kind}\",\n  \"startup_mode\": \"{startup_mode}\",\n");
        if let Some(app_id) = app_id {
            let _ = write!(payload, "  \"app_id\": \"{app_id}\",\n");
        }
        let _ = write!(
            payload,
            "  \"frame_path\": \"{frame_path}\",\n  \"frame_bytes\": {frame_bytes}\n}}\n"
        );
        if write_atomic_text_file(
            &runtime.temp_probe_summary_path,
            &runtime.probe_summary_path,
            &payload,
        )
        .is_err()
        {
            runtime.write_failed = true;
            return Err("summary-write-failed");
        }
        Ok(())
    }

    fn validate_gpu_render_summary(summary_text: &str) -> Result<(), &'static str> {
        let normalized: String = summary_text
            .chars()
            .filter(|ch| !ch.is_ascii_whitespace())
            .collect();
        let required = [
            ("scene", "\"scene\":\"flat-orange\""),
            ("present_kms", "\"present_kms\":true"),
            ("kms_present", "\"kms_present\":{"),
            ("software_backed", "\"software_backed\":false"),
            ("backend", "\"backend\":\"Vulkan\""),
            ("distinct_color_count", "\"distinct_color_count\":1"),
            ("distinct_color_sample", "\"ff7a00ff\""),
        ];
        for (label, needle) in required {
            if !normalized.contains(needle) {
                return Err(label);
            }
        }
        Ok(())
    }

    fn validate_orange_gpu_loop_summary(summary_text: &str) -> Result<(), &'static str> {
        let normalized: String = summary_text
            .chars()
            .filter(|ch| !ch.is_ascii_whitespace())
            .collect();
        let required = [
            ("mode", "\"mode\":\"orange-gpu-loop\""),
            ("scene", "\"scene\":\"orange-gpu-loop\""),
            ("present_kms", "\"present_kms\":true"),
            ("kms_present", "\"kms_present\":{"),
            ("software_backed", "\"software_backed\":false"),
            ("backend", "\"backend\":\"Vulkan\""),
            ("distinct_frame_count", "\"distinct_frame_count\":2"),
            ("frames_rendered", "\"frames_rendered\":"),
            ("scanout_updates", "\"scanout_updates\":"),
            ("present_count", "\"present_count\":"),
            ("flat_orange_label", "\"flat-orange\""),
            ("smoke_label", "\"smoke\""),
            ("flat_orange_sample", "\"ff7a00ff\""),
            ("smoke_sample", "\"651c00ff\""),
            ("checksum_samples", "\"frame_checksum_samples_fnv1a64\":["),
        ];
        for (label, needle) in required {
            if !normalized.contains(needle) {
                return Err(label);
            }
        }
        Ok(())
    }

    fn bootstrap_tmpfs_metadata_block_runtime(
        runtime: &MetadataStageRuntime,
        config: &Config,
    ) -> io::Result<()> {
        if config.dev_mount != "tmpfs" {
            return Ok(());
        }
        if !runtime.block_device.available {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "metadata block device unavailable",
            ));
        }
        ensure_directory(Path::new("/dev/block"), 0o755)?;
        ensure_directory(Path::new("/dev/block/by-name"), 0o755)?;
        ensure_block_device(
            Path::new(METADATA_DEVICE_PATH),
            0o600,
            runtime.block_device.major_num as u64,
            runtime.block_device.minor_num as u64,
        )
    }

    fn prepare_metadata_stage_runtime(runtime: &mut MetadataStageRuntime, config: &Config) {
        if !runtime.enabled || runtime.prepared {
            return;
        }
        discover_metadata_block_identity_from_sysfs(runtime, config);
        if bootstrap_tmpfs_metadata_block_runtime(runtime, config).is_err() {
            runtime.write_failed = true;
            return;
        }
        if ensure_directory(Path::new(METADATA_MOUNT_PATH), 0o755).is_err() {
            runtime.write_failed = true;
            return;
        }
        let mount_flags = (libc::MS_NOATIME | libc::MS_NODEV | libc::MS_NOSUID) as libc::c_ulong;
        let mounted = mount_fs(
            METADATA_DEVICE_PATH,
            METADATA_MOUNT_PATH,
            "ext4",
            mount_flags,
            Some(""),
        )
        .or_else(|_| {
            mount_fs(
                METADATA_DEVICE_PATH,
                METADATA_MOUNT_PATH,
                "f2fs",
                mount_flags,
                Some(""),
            )
        });
        if mounted.is_err() {
            runtime.write_failed = true;
            return;
        }
        if ensure_directory(Path::new(METADATA_ROOT), 0o755).is_err()
            || ensure_directory(Path::new(METADATA_BY_TOKEN_ROOT), 0o755).is_err()
            || ensure_directory(&runtime.stage_dir, 0o755).is_err()
        {
            runtime.write_failed = true;
            return;
        }
        runtime.prepared = true;
    }

    fn redirect_output(path: &str) -> io::Result<(Stdio, Stdio)> {
        let file = File::create(path)?;
        let stderr = file.try_clone()?;
        Ok((Stdio::from(file), Stdio::from(stderr)))
    }

    fn trigger_sysrq_best_effort(command: char) {
        let _ = fs::write("/proc/sysrq-trigger", [command as u8]);
    }

    fn run_orange_init_payload(
        config: &Config,
        stage_label: Option<&str>,
        visual_preset: Option<&str>,
    ) -> i32 {
        let mut command = Command::new(ORANGE_PAYLOAD_PATH);
        command.env(ORANGE_MODE_ENV, "orange-init");
        command.env(ORANGE_HOLD_ENV, config.hold_seconds.to_string());
        if let Some(stage_label) = stage_label {
            command.env(ORANGE_STAGE_ENV, stage_label);
        }
        if let Some(visual_preset) = visual_preset {
            command.env(ORANGE_VISUAL_ENV, visual_preset);
        }
        match command.status() {
            Ok(status) => status.code().unwrap_or(1),
            Err(error) => {
                log_line(&format!("failed to exec {ORANGE_PAYLOAD_PATH}: {error}"));
                127
            }
        }
    }

    fn ensure_orange_gpu_runtime_dirs() -> io::Result<()> {
        ensure_directory(Path::new(ORANGE_GPU_ROOT), 0o755)?;
        ensure_directory(Path::new(ORANGE_GPU_HOME), 0o755)?;
        ensure_directory(Path::new(ORANGE_GPU_CACHE_HOME), 0o755)?;
        ensure_directory(Path::new(ORANGE_GPU_CONFIG_HOME), 0o755)?;
        ensure_directory(Path::new(ORANGE_GPU_MESA_CACHE_DIR), 0o755)?;
        Ok(())
    }

    fn set_orange_gpu_env(
        command: &mut Command,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) {
        command.env(GPU_BACKEND_ENV, "vulkan");
        command.env(LD_LIBRARY_PATH_ENV, ORANGE_GPU_LIBRARY_PATH);
        command.env(VK_ICD_FILENAMES_ENV, ORANGE_GPU_ICD_PATH);
        command.env(MESA_DRIVER_OVERRIDE_ENV, "kgsl");
        command.env(TU_DEBUG_ENV, "noconform");
        command.env(HOME_ENV, ORANGE_GPU_HOME);
        command.env(XDG_CACHE_HOME_ENV, ORANGE_GPU_CACHE_HOME);
        command.env(XDG_CONFIG_HOME_ENV, ORANGE_GPU_CONFIG_HOME);
        command.env(MESA_SHADER_CACHE_ENV, ORANGE_GPU_MESA_CACHE_DIR);
        if let Some(path) = probe_stage_path {
            command.env(GPU_SMOKE_STAGE_PATH_ENV, path);
        }
        if let Some(prefix) = probe_stage_prefix {
            command.env(GPU_SMOKE_STAGE_PREFIX_ENV, prefix);
        }
    }

    fn probe_stage_path_from_env() -> Option<PathBuf> {
        std::env::var_os(GPU_SMOKE_STAGE_PATH_ENV)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
    }

    fn probe_stage_prefix_from_env() -> Option<String> {
        std::env::var(GPU_SMOKE_STAGE_PREFIX_ENV)
            .ok()
            .filter(|value| !value.is_empty())
    }

    fn probe_bootstrap_gpu_firmware(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> io::Result<()> {
        if config.firmware_bootstrap != "ramdisk-lib-firmware" {
            return Ok(());
        }
        for (filename, stage_token) in GPU_FIRMWARE_ENTRIES {
            let path = Path::new("/lib/firmware").join(filename);
            let mut file = File::open(&path)?;
            let mut probe_byte = [0u8; 1];
            let _ = file.read(&mut probe_byte)?;
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                &format!("firmware-probe-{stage_token}-ok"),
            );
        }
        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "firmware-probe-ok");
        let _ = run_orange_gpu_checkpoint(
            config,
            "firmware-probe-ok",
            FIRMWARE_PROBE_CHECKPOINT_HOLD_SECONDS,
        );
        Ok(())
    }

    fn service_firmware_request_from_ramdisk(filename: &str) -> io::Result<()> {
        let request_root = Path::new(FIRMWARE_CLASS_ROOT).join(filename);
        let loading_path = request_root.join("loading");
        let data_path = request_root.join("data");
        let firmware_path = Path::new("/lib/firmware").join(filename);

        let mut loading_file = OpenOptions::new().write(true).open(&loading_path)?;
        let mut data_file = OpenOptions::new().write(true).open(&data_path)?;
        let mut firmware_file = File::open(&firmware_path)?;

        loading_file.write_all(b"1")?;
        io::copy(&mut firmware_file, &mut data_file)?;
        loading_file.write_all(b"0")?;
        Ok(())
    }

    fn run_ramdisk_firmware_helper_loop(
        stop: Arc<AtomicBool>,
        probe_stage_path: Option<PathBuf>,
        probe_stage_prefix: Option<String>,
    ) {
        let deadline = Instant::now() + Duration::from_secs(FIRMWARE_HELPER_TIMEOUT_SECONDS);
        let mut serviced = [false; GPU_FIRMWARE_ENTRIES.len()];
        write_payload_probe_stage(
            probe_stage_path.as_deref(),
            probe_stage_prefix.as_deref(),
            "firmware-helper-waiting",
        );

        while !stop.load(Ordering::Relaxed) {
            if let Ok(entries) = fs::read_dir(FIRMWARE_CLASS_ROOT) {
                for entry in entries.flatten() {
                    let name = entry.file_name();
                    let name = name.to_string_lossy();
                    for (index, (filename, stage_token)) in GPU_FIRMWARE_ENTRIES.iter().enumerate()
                    {
                        if serviced[index] || name.as_ref() != *filename {
                            continue;
                        }
                        match service_firmware_request_from_ramdisk(filename) {
                            Ok(()) => {
                                serviced[index] = true;
                                write_payload_probe_stage(
                                    probe_stage_path.as_deref(),
                                    probe_stage_prefix.as_deref(),
                                    &format!("firmware-helper-{stage_token}-ok"),
                                );
                            }
                            Err(_) => {
                                write_payload_probe_stage(
                                    probe_stage_path.as_deref(),
                                    probe_stage_prefix.as_deref(),
                                    &format!("firmware-helper-{stage_token}-failed"),
                                );
                            }
                        }
                    }
                }
            }
            if serviced.iter().all(|value| *value) {
                write_payload_probe_stage(
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                    "firmware-helper-all-serviced",
                );
                return;
            }
            if Instant::now() >= deadline {
                write_payload_probe_stage(
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                    "firmware-helper-timeout",
                );
                return;
            }
            thread::sleep(Duration::from_millis(FIRMWARE_HELPER_POLL_MILLIS));
        }
    }

    fn run_timeout_control_smoke(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> i32 {
        if probe_bootstrap_gpu_firmware(config, probe_stage_path, probe_stage_prefix).is_err() {
            return 1;
        }
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "timeout-control-sleep",
        );
        loop {
            unsafe {
                libc::pause();
            }
        }
    }

    fn run_c_kgsl_open_readonly_smoke_internal(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
        use_firmware_helper: bool,
    ) -> i32 {
        if probe_bootstrap_gpu_firmware(config, probe_stage_path, probe_stage_prefix).is_err() {
            return 1;
        }

        let firmware_helper = if use_firmware_helper {
            Some(FirmwareHelper::start(
                probe_stage_path.map(Path::to_path_buf),
                probe_stage_prefix.map(ToString::to_string),
            ))
        } else {
            None
        };

        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "kgsl-open-readonly");
        let trace_enabled = setup_kgsl_trace_best_effort();
        let trace_monitor = if trace_enabled {
            match (probe_stage_path, probe_stage_prefix) {
                (Some(path), Some(prefix)) => Some(KgslTraceMonitor::start(
                    path.to_path_buf(),
                    prefix.to_string(),
                )),
                _ => None,
            }
        } else {
            None
        };

        let device_path = CString::new("/dev/kgsl-3d0").unwrap();
        let kgsl_fd = unsafe {
            libc::open(
                device_path.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOCTTY,
            )
        };
        if kgsl_fd < 0 {
            if let Some(monitor) = trace_monitor {
                monitor.stop();
            }
            if trace_enabled {
                teardown_kgsl_trace_best_effort();
            }
            if let Some(helper) = firmware_helper {
                helper.stop();
            }
            return 1;
        }

        unsafe {
            libc::close(kgsl_fd);
        }
        if let Some(monitor) = trace_monitor {
            monitor.stop();
        }
        if trace_enabled {
            teardown_kgsl_trace_best_effort();
        }
        if let Some(helper) = firmware_helper {
            helper.stop();
        }
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "kgsl-open-readonly-ok",
        );
        0
    }

    fn run_internal_orange_gpu_child(config: &Config, mode: &str) -> i32 {
        let probe_stage_path = probe_stage_path_from_env();
        let probe_stage_prefix = probe_stage_prefix_from_env();
        match mode {
            "timeout-control-smoke" => run_timeout_control_smoke(
                config,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
            ),
            "c-kgsl-open-readonly-smoke" => run_c_kgsl_open_readonly_smoke_internal(
                config,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
                false,
            ),
            "c-kgsl-open-readonly-firmware-helper-smoke" => {
                run_c_kgsl_open_readonly_smoke_internal(
                    config,
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                    true,
                )
            }
            _ => 1,
        }
    }

    fn run_orange_gpu_parent_probe(
        config: &Config,
        metadata_stage: &MetadataStageRuntime,
    ) -> (i32, String) {
        if config.orange_gpu_parent_probe_attempts == 0 {
            return (0, "parent-probe-result=skipped".to_string());
        }

        let probe_stage_path =
            if metadata_stage.enabled && metadata_stage.prepared && !metadata_stage.write_failed {
                Some(metadata_stage.probe_stage_path.as_path())
            } else {
                None
            };
        let mut result_stage = "parent-probe-result=not-run".to_string();

        for attempt in 1..=config.orange_gpu_parent_probe_attempts {
            remove_file_best_effort(ORANGE_GPU_PROBE_SUMMARY_PATH);
            remove_file_best_effort(ORANGE_GPU_PROBE_OUTPUT_PATH);

            let probe_stage_prefix = format!("parent-probe-attempt-{attempt}");
            let mut command = Command::new(ORANGE_GPU_LOADER_PATH);
            command.arg("--library-path");
            command.arg(ORANGE_GPU_LIBRARY_PATH);
            command.arg(ORANGE_GPU_BINARY_PATH);
            command.arg("--scene");
            command.arg("raw-vulkan-physical-device-count-query-exit-smoke");
            command.arg("--summary-path");
            command.arg(ORANGE_GPU_PROBE_SUMMARY_PATH);
            set_orange_gpu_env(&mut command, probe_stage_path, Some(&probe_stage_prefix));
            if let Ok((stdout, stderr)) = redirect_output(ORANGE_GPU_PROBE_OUTPUT_PATH) {
                command.stdout(stdout);
                command.stderr(stderr);
            }

            let mut child = match command.spawn() {
                Ok(child) => child,
                Err(error) => {
                    log_line(&format!(
                        "orange-gpu parent probe attempt {attempt}/{} failed to spawn: {error}",
                        config.orange_gpu_parent_probe_attempts
                    ));
                    return (1, "parent-probe-result=spawn-failed".to_string());
                }
            };
            let watch_result = match wait_for_child_with_watchdog(
                &mut child,
                "orange-gpu-parent-probe",
                ORANGE_GPU_CHILD_WATCH_POLL_SECONDS,
                ORANGE_GPU_WATCHDOG_GRACE_SECONDS,
                None,
            ) {
                Ok(result) => result,
                Err(error) => {
                    log_line(&format!(
                        "orange-gpu parent probe attempt {attempt}/{} failed while waiting: {error}",
                        config.orange_gpu_parent_probe_attempts
                    ));
                    return (1, "parent-probe-result=wait-failed".to_string());
                }
            };

            result_stage = if let Some(exit_status) = watch_result.exit_status {
                format!("parent-probe-result=exit-{exit_status}")
            } else if let Some(signal) = watch_result.signal {
                format!(
                    "parent-probe-result={}-{}",
                    if watch_result.timed_out {
                        "watchdog-signal"
                    } else {
                        "signal"
                    },
                    signal
                )
            } else {
                "parent-probe-result=unknown-status".to_string()
            };

            if watch_result.exit_status == Some(0) {
                return (0, result_stage);
            }
            if attempt < config.orange_gpu_parent_probe_attempts
                && config.orange_gpu_parent_probe_interval_secs > 0
            {
                sleep_seconds(config.orange_gpu_parent_probe_interval_secs);
            }
        }

        (1, result_stage)
    }

    fn scene_for_mode(mode: &str) -> (&'static str, bool, bool) {
        match mode {
            "orange-gpu-loop" => ("orange-gpu-loop", true, true),
            "bundle-smoke" => ("bundle-smoke", false, false),
            "vulkan-instance-smoke" => ("instance-smoke", false, false),
            "raw-vulkan-instance-smoke" => ("raw-vulkan-instance-smoke", false, false),
            "raw-kgsl-open-readonly-smoke" => ("raw-kgsl-open-readonly-smoke", false, false),
            "raw-kgsl-getproperties-smoke" => ("raw-kgsl-getproperties-smoke", false, false),
            "raw-vulkan-physical-device-count-query-exit-smoke" => (
                "raw-vulkan-physical-device-count-query-exit-smoke",
                false,
                false,
            ),
            "raw-vulkan-physical-device-count-query-no-destroy-smoke" => (
                "raw-vulkan-physical-device-count-query-no-destroy-smoke",
                false,
                false,
            ),
            "raw-vulkan-physical-device-count-query-smoke" => {
                ("raw-vulkan-physical-device-count-query-smoke", false, false)
            }
            "raw-vulkan-physical-device-count-smoke" => {
                ("raw-vulkan-physical-device-count-smoke", false, false)
            }
            "vulkan-enumerate-adapters-count-smoke" => {
                ("enumerate-adapters-count-smoke", false, false)
            }
            "vulkan-enumerate-adapters-smoke" => ("enumerate-adapters-smoke", false, false),
            "vulkan-adapter-smoke" => ("adapter-smoke", false, false),
            "vulkan-device-request-smoke" => ("device-request-smoke", false, false),
            "vulkan-device-smoke" => ("device-smoke", false, false),
            "vulkan-offscreen" => ("smoke", false, false),
            "compositor-scene" => ("flat-orange", false, false),
            "app-direct-present" => ("flat-orange", false, false),
            _ => ("flat-orange", true, true),
        }
    }

    fn resolve_watchdog_timeout(config: &Config) -> u32 {
        if config.orange_gpu_watchdog_timeout_secs > 0 {
            config.orange_gpu_watchdog_timeout_secs
        } else {
            config
                .hold_seconds
                .saturating_add(ORANGE_GPU_WATCHDOG_GRACE_SECONDS)
        }
    }

    fn wait_for_child_with_watchdog(
        child: &mut Child,
        label: &str,
        poll_seconds: u32,
        timeout_seconds: u32,
        mut observer: Option<&mut dyn FnMut(u32, u32, u32)>,
    ) -> io::Result<ChildWatchResult> {
        let mut result = ChildWatchResult::default();
        loop {
            match child.try_wait()? {
                Some(status) => {
                    result.completed = true;
                    result.exit_status = status.code();
                    #[cfg(unix)]
                    {
                        use std::os::unix::process::ExitStatusExt;
                        result.signal = status.signal();
                        result.raw_wait_status = status.into_raw();
                    }
                    return Ok(result);
                }
                None => {
                    thread::sleep(Duration::from_secs(poll_seconds as u64));
                    result.waited_seconds = result.waited_seconds.saturating_add(poll_seconds);
                    if timeout_seconds > 0 && result.waited_seconds >= timeout_seconds {
                        result.timed_out = true;
                        if let Some(observer) = observer.as_mut() {
                            observer(child.id(), result.waited_seconds, timeout_seconds);
                        }
                        let _ = child.kill();
                        let status = child.wait()?;
                        result.completed = true;
                        result.exit_status = status.code();
                        #[cfg(unix)]
                        {
                            use std::os::unix::process::ExitStatusExt;
                            result.signal = status.signal();
                            result.raw_wait_status = status.into_raw();
                        }
                        log_line(&format!(
                            "{label} timed out after {} second(s)",
                            result.waited_seconds
                        ));
                        return Ok(result);
                    }
                }
            }
        }
    }

    fn orange_gpu_mode_uses_success_postlude(mode: &str) -> bool {
        matches!(
            mode,
            "gpu-render"
                | "orange-gpu-loop"
                | "bundle-smoke"
                | "vulkan-instance-smoke"
                | "raw-vulkan-instance-smoke"
                | "raw-vulkan-physical-device-count-query-exit-smoke"
                | "raw-vulkan-physical-device-count-query-no-destroy-smoke"
                | "raw-vulkan-physical-device-count-query-smoke"
                | "raw-vulkan-physical-device-count-smoke"
                | "vulkan-enumerate-adapters-count-smoke"
                | "vulkan-enumerate-adapters-smoke"
                | "vulkan-adapter-smoke"
                | "vulkan-device-request-smoke"
                | "vulkan-device-smoke"
                | "vulkan-offscreen"
        )
    }

    fn run_orange_gpu_checkpoint(config: &Config, checkpoint_name: &str, hold_seconds: u32) -> i32 {
        if !orange_gpu_mode_uses_visible_checkpoints(&config.orange_gpu_mode, checkpoint_name)
            || config.prelude != "orange-init"
            || hold_seconds == 0
        {
            return 0;
        }
        let mut checkpoint_config = config.clone();
        checkpoint_config.hold_seconds = hold_seconds;
        run_orange_init_payload(
            &checkpoint_config,
            Some(checkpoint_name),
            Some(orange_gpu_checkpoint_visual(checkpoint_name)),
        )
    }

    fn run_orange_gpu_prelude(config: &Config) -> i32 {
        if config.prelude != "orange-init" || config.prelude_hold_seconds == 0 {
            return 0;
        }
        let mut prelude_config = config.clone();
        prelude_config.hold_seconds = config.prelude_hold_seconds;
        run_orange_init_payload(
            &prelude_config,
            Some("orange-gpu-prelude"),
            Some("solid-orange"),
        )
    }

    fn run_orange_gpu_postlude(config: &Config) -> i32 {
        if config.prelude != "orange-init"
            || config.hold_seconds == 0
            || !orange_gpu_mode_uses_success_postlude(&config.orange_gpu_mode)
        {
            return 0;
        }
        let visual = if matches!(
            config.orange_gpu_mode.as_str(),
            "gpu-render" | "orange-gpu-loop"
        ) {
            "success-solid"
        } else {
            "frame-orange"
        };
        run_orange_init_payload(config, Some("orange-gpu-postlude"), Some(visual))
    }

    fn validate_orange_gpu_config(config: &Config) -> bool {
        if !config.orange_gpu_mode_seen || config.orange_gpu_mode_invalid {
            log_line("orange-gpu config missing or invalid orange_gpu_mode");
            return false;
        }
        if config.orange_gpu_metadata_stage_breadcrumb && !config.mount_dev {
            log_line("orange_gpu_metadata_stage_breadcrumb requires mount_dev=true");
            return false;
        }
        if config.orange_gpu_firmware_helper && !config.mount_sys {
            log_line("orange_gpu_firmware_helper requires mount_sys=true");
            return false;
        }
        if config.orange_gpu_firmware_helper && config.firmware_bootstrap != "ramdisk-lib-firmware"
        {
            log_line("orange_gpu_firmware_helper requires firmware_bootstrap=ramdisk-lib-firmware");
            return false;
        }
        if orange_gpu_mode_uses_session_frame_capture(&config.orange_gpu_mode)
            && !config.orange_gpu_metadata_stage_breadcrumb
        {
            log_line("session frame modes require orange_gpu_metadata_stage_breadcrumb=true");
            return false;
        }
        if orange_gpu_mode_uses_session_frame_capture(&config.orange_gpu_mode)
            && !config.orange_gpu_firmware_helper
        {
            log_line("session frame modes require orange_gpu_firmware_helper=true");
            return false;
        }
        if config.orange_gpu_mode == "c-kgsl-open-readonly-firmware-helper-smoke"
            && !config.mount_sys
        {
            log_line("c-kgsl-open-readonly-firmware-helper-smoke requires mount_sys=true");
            return false;
        }
        if config.orange_gpu_mode == "c-kgsl-open-readonly-firmware-helper-smoke"
            && !config.orange_gpu_metadata_stage_breadcrumb
        {
            log_line(
                "c-kgsl-open-readonly-firmware-helper-smoke requires orange_gpu_metadata_stage_breadcrumb=true",
            );
            return false;
        }
        true
    }

    fn run_orange_gpu_payload(
        config: &Config,
        metadata_stage: &mut MetadataStageRuntime,
        self_exec_path: Option<&Path>,
    ) -> i32 {
        if ensure_orange_gpu_runtime_dirs().is_err() {
            return 1;
        }

        if config.orange_gpu_launch_delay_secs > 0 {
            sleep_seconds(config.orange_gpu_launch_delay_secs);
        }

        if metadata_stage.prepared {
            write_metadata_probe_fingerprint(metadata_stage, config);
            write_metadata_stage(metadata_stage, "parent-probe-start");
        }

        let (parent_probe_status, parent_probe_result_stage) =
            run_orange_gpu_parent_probe(config, metadata_stage);
        if metadata_stage.prepared {
            write_metadata_stage(metadata_stage, &parent_probe_result_stage);
        }
        if parent_probe_status == 0 && config.orange_gpu_parent_probe_attempts > 0 {
            let _ = run_orange_gpu_checkpoint(
                config,
                "probe-ready",
                ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
            );
        } else if parent_probe_status != 0 {
            log_line(&format!(
                "orange-gpu parent probe returned status={parent_probe_status}; continuing to payload launch"
            ));
        }

        remove_file_best_effort(ORANGE_GPU_SUMMARY_PATH);
        remove_file_best_effort(ORANGE_GPU_OUTPUT_PATH);
        if metadata_stage.prepared {
            let _ = fs::remove_file(&metadata_stage.compositor_frame_path);
        }

        let probe_stage_path =
            if metadata_stage.enabled && metadata_stage.prepared && !metadata_stage.write_failed {
                Some(metadata_stage.probe_stage_path.clone())
            } else {
                None
            };
        let probe_stage_prefix = Some("orange-gpu-payload".to_string());
        let kgsl_trace_may_be_active =
            orange_gpu_mode_is_any_c_kgsl_open_readonly_smoke(&config.orange_gpu_mode);

        if config.orange_gpu_mode == "firmware-probe-only" {
            return match probe_bootstrap_gpu_firmware(
                config,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
            ) {
                Ok(()) => 0,
                Err(_) => 1,
            };
        }

        if orange_gpu_mode_is_c_kgsl_open_readonly_pid1_smoke(&config.orange_gpu_mode) {
            let direct_status = run_c_kgsl_open_readonly_smoke_internal(
                config,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
                false,
            );
            let direct_result = ChildWatchResult {
                completed: true,
                timed_out: false,
                waited_seconds: 0,
                exit_status: Some(direct_status),
                signal: None,
                raw_wait_status: 0,
            };
            write_probe_report(
                metadata_stage,
                "orange-gpu-payload",
                probe_stage_path.as_deref(),
                &direct_result,
                None,
                false,
                0,
            );
            return direct_status;
        }

        let firmware_helper = if config.orange_gpu_firmware_helper {
            Some(FirmwareHelper::start(
                probe_stage_path.clone(),
                probe_stage_prefix.clone(),
            ))
        } else {
            None
        };

        let child_mode = matches!(
            config.orange_gpu_mode.as_str(),
            "timeout-control-smoke"
                | "c-kgsl-open-readonly-smoke"
                | "c-kgsl-open-readonly-firmware-helper-smoke"
        );

        let mut command = if child_mode {
            let resolved_self_exec_path = self_exec_path
                .map(Path::to_path_buf)
                .or_else(|| std::env::current_exe().ok());
            let Some(resolved_self_exec_path) = resolved_self_exec_path else {
                log_line("failed to resolve hello-init path for owned orange-gpu child");
                if let Some(helper) = firmware_helper {
                    helper.stop();
                }
                return 127;
            };
            let mut command = Command::new(resolved_self_exec_path);
            command.arg("--owned-child");
            command.arg("--config");
            command.arg(CONFIG_PATH);
            command.arg("--orange-gpu-child-mode");
            command.arg(&config.orange_gpu_mode);
            command
        } else {
            if probe_bootstrap_gpu_firmware(
                config,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
            )
            .is_err()
            {
                if let Some(helper) = firmware_helper {
                    helper.stop();
                }
                return 1;
            }

            if orange_gpu_mode_uses_session_frame_capture(&config.orange_gpu_mode) {
                let session_config_path =
                    if orange_gpu_mode_is_compositor_scene(&config.orange_gpu_mode) {
                        ORANGE_GPU_COMPOSITOR_STARTUP_CONFIG_PATH
                    } else {
                        ORANGE_GPU_APP_DIRECT_PRESENT_STARTUP_CONFIG_PATH
                    };
                let mut command = Command::new(ORANGE_GPU_COMPOSITOR_SESSION_PATH);
                command.env("SHADOW_SESSION_MODE", "guest-ui");
                command.env("SHADOW_RUNTIME_DIR", ORANGE_GPU_COMPOSITOR_RUNTIME_DIR);
                command.env("SHADOW_GUEST_SESSION_CONFIG", session_config_path);
                command.env(
                    "SHADOW_GUEST_COMPOSITOR_BIN",
                    ORANGE_GPU_COMPOSITOR_BINARY_PATH,
                );
                if orange_gpu_mode_is_compositor_scene(&config.orange_gpu_mode) {
                    command.env(
                        "SHADOW_GUEST_CLIENT",
                        ORANGE_GPU_COMPOSITOR_DUMMY_CLIENT_PATH,
                    );
                }
                command.env("SHADOW_GUEST_COMPOSITOR_ENABLE_DRM", "1");
                command.env(
                    "RUST_LOG",
                    "shadow_session=info,shadow_compositor_guest=info,smithay=warn",
                );
                command
            } else {
                let (scene, summary_needed, _) = scene_for_mode(&config.orange_gpu_mode);
                let mut command = Command::new(ORANGE_GPU_LOADER_PATH);
                command.arg("--library-path");
                command.arg(ORANGE_GPU_LIBRARY_PATH);
                command.arg(ORANGE_GPU_BINARY_PATH);
                command.arg("--scene");
                command.arg(scene);
                if summary_needed {
                    command.arg("--present-kms");
                    command.arg("--hold-secs");
                    command.arg(config.hold_seconds.to_string());
                }
                command.arg("--summary-path");
                command.arg(ORANGE_GPU_SUMMARY_PATH);
                command
            }
        };
        set_orange_gpu_env(
            &mut command,
            probe_stage_path.as_deref(),
            probe_stage_prefix.as_deref(),
        );
        if let Ok((stdout, stderr)) = redirect_output(ORANGE_GPU_OUTPUT_PATH) {
            command.stdout(stdout);
            command.stderr(stderr);
        }
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                log_line(&format!("failed to spawn orange-gpu payload: {error}"));
                if let Some(helper) = firmware_helper {
                    helper.stop();
                }
                return 127;
            }
        };

        let watchdog_timeout = resolve_watchdog_timeout(config);
        let observed_probe_stage_path = probe_stage_path.clone();
        let mut timeout_observer =
            |observed_pid: u32, waited_seconds: u32, timeout_seconds: u32| {
                let timeout_result = ChildWatchResult {
                    completed: false,
                    timed_out: true,
                    waited_seconds,
                    exit_status: None,
                    signal: None,
                    raw_wait_status: 0,
                };
                write_metadata_probe_timeout_class(
                    metadata_stage,
                    "orange-gpu-payload",
                    observed_probe_stage_path.as_deref(),
                    observed_pid,
                );
                write_probe_report(
                    metadata_stage,
                    "orange-gpu-payload",
                    observed_probe_stage_path.as_deref(),
                    &timeout_result,
                    Some(observed_pid),
                    true,
                    timeout_seconds,
                );
            };
        let watch_result = match wait_for_child_with_watchdog(
            &mut child,
            "orange-gpu-payload",
            ORANGE_GPU_CHILD_WATCH_POLL_SECONDS,
            watchdog_timeout,
            Some(&mut timeout_observer),
        ) {
            Ok(result) => result,
            Err(error) => {
                log_line(&format!("orange-gpu wait failed: {error}"));
                if let Some(helper) = firmware_helper {
                    helper.stop();
                }
                if kgsl_trace_may_be_active {
                    teardown_kgsl_trace_best_effort();
                }
                return 1;
            }
        };

        if let Some(helper) = firmware_helper {
            helper.stop();
        }
        if kgsl_trace_may_be_active {
            teardown_kgsl_trace_best_effort();
        }
        if !watch_result.timed_out {
            write_probe_report(
                metadata_stage,
                "orange-gpu-payload",
                probe_stage_path.as_deref(),
                &watch_result,
                None,
                false,
                watchdog_timeout,
            );
        }
        if watch_result.exit_status == Some(0) && metadata_stage.enabled {
            if orange_gpu_mode_uses_session_frame_capture(&config.orange_gpu_mode) {
                let (summary_kind, startup_mode, app_id, stage_name) =
                    if orange_gpu_mode_is_compositor_scene(&config.orange_gpu_mode) {
                        (
                            "compositor-scene",
                            "shell",
                            None,
                            "compositor-scene-frame-captured",
                        )
                    } else {
                        (
                            "app-direct-present",
                            "app",
                            Some("rust-demo"),
                            "app-direct-present-frame-captured",
                        )
                    };
                if let Err(reason) =
                    record_session_frame_summary(metadata_stage, summary_kind, startup_mode, app_id)
                {
                    log_line(&format!(
                        "{summary_kind} frame missing or could not be summarized: {reason}"
                    ));
                    let _ = run_orange_gpu_checkpoint(
                        config,
                        "child-exit-nonzero",
                        ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
                    );
                    return 1;
                }
                write_payload_probe_stage(
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                    stage_name,
                );
            } else {
                let recorded_summary =
                    record_probe_summary(metadata_stage, ORANGE_GPU_SUMMARY_PATH);
                if config.orange_gpu_mode == "gpu-render" {
                    let Some(summary_text) = recorded_summary.as_deref() else {
                        log_line(
                            "gpu-render summary missing or could not be persisted to metadata",
                        );
                        let _ = run_orange_gpu_checkpoint(
                            config,
                            "child-exit-nonzero",
                            ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
                        );
                        return 1;
                    };
                    if let Err(reason) = validate_gpu_render_summary(summary_text) {
                        log_line(&format!(
                            "gpu-render summary failed validation: missing {reason}"
                        ));
                        let _ = run_orange_gpu_checkpoint(
                            config,
                            "child-exit-nonzero",
                            ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
                        );
                        return 1;
                    }
                } else if config.orange_gpu_mode == "orange-gpu-loop" {
                    let Some(summary_text) = recorded_summary.as_deref() else {
                        log_line(
                            "orange-gpu-loop summary missing or could not be persisted to metadata",
                        );
                        let _ = run_orange_gpu_checkpoint(
                            config,
                            "child-exit-nonzero",
                            ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
                        );
                        return 1;
                    };
                    if let Err(reason) = validate_orange_gpu_loop_summary(summary_text) {
                        log_line(&format!(
                            "orange-gpu-loop summary failed validation: missing {reason}"
                        ));
                        let _ = run_orange_gpu_checkpoint(
                            config,
                            "child-exit-nonzero",
                            ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
                        );
                        return 1;
                    }
                }
            }
        }

        if watch_result.timed_out {
            let timeout_classification = classify_orange_gpu_timeout(config, metadata_stage);
            let _ = run_orange_gpu_checkpoint(
                config,
                &timeout_classification.checkpoint_name,
                ORANGE_GPU_TIMEOUT_CLASSIFIER_HOLD_SECONDS,
            );
            if config.orange_gpu_timeout_action == "panic" {
                log_line("orange-gpu payload timed out; escalating to sysrq panic");
                trigger_sysrq_best_effort('w');
                sleep_seconds(1);
                trigger_sysrq_best_effort('c');
                loop {
                    sleep_seconds(60);
                }
            }
            return 124;
        }
        if let Some(exit_status) = watch_result.exit_status {
            if exit_status != 0 {
                let _ = run_orange_gpu_checkpoint(
                    config,
                    "child-exit-nonzero",
                    ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
                );
            } else if orange_gpu_mode_uses_session_frame_capture(&config.orange_gpu_mode) {
                hold_for_observation(config.hold_seconds);
            }
            return exit_status;
        }
        if let Some(signal) = watch_result.signal {
            let _ = run_orange_gpu_checkpoint(
                config,
                "child-signal",
                ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
            );
            return 128 + signal;
        }
        1
    }

    fn bootstrap_tmpfs_dev_runtime(config: &Config) -> io::Result<()> {
        if !config.mount_dev || config.dev_mount != "tmpfs" {
            return Ok(());
        }
        ensure_char_device(Path::new("/dev/null"), 0o666, 1, 3)?;
        ensure_char_device(Path::new("/dev/console"), 0o600, 5, 1)?;
        if config.log_kmsg {
            ensure_char_device(Path::new("/dev/kmsg"), 0o600, 1, 11)?;
        }
        if config.log_pmsg {
            ensure_char_device(Path::new("/dev/pmsg0"), 0o222, 250, 0)?;
        }
        ensure_stdio_fds()
    }

    fn bootstrap_proc_stdio_links(config: &Config) -> io::Result<()> {
        if !config.mount_dev || !config.mount_proc || config.dev_mount != "tmpfs" {
            return Ok(());
        }
        ensure_symlink_target(Path::new("/dev/stdin"), Path::new("/proc/self/fd/0"))?;
        ensure_symlink_target(Path::new("/dev/stdout"), Path::new("/proc/self/fd/1"))?;
        ensure_symlink_target(Path::new("/dev/stderr"), Path::new("/proc/self/fd/2"))?;
        Ok(())
    }

    fn bootstrap_tmpfs_dri_runtime(config: &Config) -> io::Result<()> {
        if !config.mount_dev || config.dev_mount != "tmpfs" || config.dri_bootstrap == "none" {
            return Ok(());
        }
        ensure_directory(Path::new("/dev/dri"), 0o755)?;
        ensure_char_device(Path::new("/dev/dri/card0"), 0o600, 226, 0)?;
        ensure_char_device(Path::new("/dev/dri/renderD128"), 0o600, 226, 128)?;
        if config.dri_bootstrap == "sunfish-card0-renderD128-kgsl3d0" {
            ensure_char_device(Path::new("/dev/kgsl-3d0"), 0o666, 508, 0)?;
        }
        Ok(())
    }

    fn raw_reboot(cmd: libc::c_int, arg: Option<&str>) -> io::Result<()> {
        let arg_c = arg.map(|value| CString::new(value).unwrap());
        let arg_ptr = arg_c
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null());
        let rc = unsafe {
            libc::syscall(
                libc::SYS_reboot,
                libc::LINUX_REBOOT_MAGIC1,
                libc::LINUX_REBOOT_MAGIC2,
                cmd,
                arg_ptr,
            )
        };
        if rc == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }

    fn reboot_from_config(config: &Config) -> ! {
        unsafe {
            libc::sync();
        }
        let target = config.reboot_target.as_str();
        let _ = match target {
            "halt" => raw_reboot(libc::LINUX_REBOOT_CMD_HALT, None),
            "poweroff" => raw_reboot(libc::LINUX_REBOOT_CMD_POWER_OFF, None),
            "restart" | "reboot" => raw_reboot(libc::LINUX_REBOOT_CMD_RESTART, None),
            other => raw_reboot(libc::LINUX_REBOOT_CMD_RESTART2, Some(other))
                .or_else(|_| raw_reboot(libc::LINUX_REBOOT_CMD_RESTART, None)),
        };
        loop {
            sleep_seconds(60);
        }
    }

    fn log_observability_status(config: &Config) {
        append_wrapper_log(&format!(
            "shadow-owned-init-observability:kmsg={},pmsg={},stdio=true,run_token={}",
            bool_word(config.log_kmsg),
            bool_word(config.log_pmsg),
            run_token_or_unset(config)
        ));
    }

    pub(crate) fn main_linux_raw(argc: libc::c_int, argv: *const *const libc::c_char) -> ! {
        let args = parse_args_raw(argc, argv);
        if !args.selftest && !args.owned_child && process::id() != 1 {
            process::exit(1);
        }

        let config = load_config(args.config_path.as_deref().unwrap_or(CONFIG_PATH));
        set_log_channel_preferences(&config);
        if let Some(mode) = args.orange_gpu_child_mode.as_deref() {
            process::exit(run_internal_orange_gpu_child(&config, mode));
        }
        let mut metadata_stage = init_metadata_stage_runtime(&config);

        if config.mount_dev {
            let _ = ensure_directory(Path::new("/dev"), 0o755);
            capture_metadata_block_identity(&mut metadata_stage, &config);
            if mount_fs(
                &config.dev_mount,
                "/dev",
                &config.dev_mount,
                libc::MS_NOSUID as libc::c_ulong,
                Some("mode=0755"),
            )
            .is_err()
            {
                process::exit(1);
            }
            if bootstrap_tmpfs_dev_runtime(&config).is_err() {
                process::exit(1);
            }
        }

        append_wrapper_log("starting owned PID 1");
        append_wrapper_log(OWNED_INIT_ROLE_SENTINEL);
        append_wrapper_log(OWNED_INIT_IMPL_SENTINEL);
        append_wrapper_log(OWNED_INIT_CONFIG_SENTINEL);
        append_wrapper_log(&format!(
            "shadow-owned-init-mounts:dev={},proc={},sys={}",
            bool_word(config.mount_dev),
            bool_word(config.mount_proc),
            bool_word(config.mount_sys)
        ));
        append_wrapper_log(&format!(
            "shadow-owned-init-run-token:{}",
            run_token_or_unset(&config)
        ));
        log_observability_status(&config);

        if config.mount_proc {
            let _ = ensure_directory(Path::new("/proc"), 0o555);
            if mount_fs(
                "proc",
                "/proc",
                "proc",
                (libc::MS_NOSUID | libc::MS_NOEXEC | libc::MS_NODEV) as libc::c_ulong,
                Some(""),
            )
            .is_err()
            {
                process::exit(1);
            }
            if bootstrap_proc_stdio_links(&config).is_err() {
                process::exit(1);
            }
        }
        if config.mount_sys {
            let _ = ensure_directory(Path::new("/sys"), 0o555);
            if mount_fs(
                "sysfs",
                "/sys",
                "sysfs",
                (libc::MS_NOSUID | libc::MS_NOEXEC | libc::MS_NODEV) as libc::c_ulong,
                Some(""),
            )
            .is_err()
            {
                process::exit(1);
            }
        }
        if bootstrap_tmpfs_dri_runtime(&config).is_err() {
            process::exit(1);
        }

        append_wrapper_log(&format!(
            "config payload={} prelude={} orange_gpu_mode={} orange_gpu_launch_delay_secs={} orange_gpu_parent_probe_attempts={} orange_gpu_parent_probe_interval_secs={} orange_gpu_metadata_stage_breadcrumb={} orange_gpu_firmware_helper={} orange_gpu_timeout_action={} orange_gpu_watchdog_timeout_secs={} hold_seconds={} prelude_hold_seconds={} reboot_target={} run_token={} dev_mount={} dri_bootstrap={} firmware_bootstrap={} mount_dev={} mount_proc={} mount_sys={} log_kmsg={} log_pmsg={}",
            config.payload,
            config.prelude,
            config.orange_gpu_mode,
            config.orange_gpu_launch_delay_secs,
            config.orange_gpu_parent_probe_attempts,
            config.orange_gpu_parent_probe_interval_secs,
            bool_word(config.orange_gpu_metadata_stage_breadcrumb),
            bool_word(config.orange_gpu_firmware_helper),
            config.orange_gpu_timeout_action,
            config.orange_gpu_watchdog_timeout_secs,
            config.hold_seconds,
            config.prelude_hold_seconds,
            config.reboot_target,
            run_token_or_unset(&config),
            config.dev_mount,
            config.dri_bootstrap,
            config.firmware_bootstrap,
            bool_word(config.mount_dev),
            bool_word(config.mount_proc),
            bool_word(config.mount_sys),
            bool_word(config.log_kmsg),
            bool_word(config.log_pmsg),
        ));

        if config.payload == "orange-init" {
            let status =
                run_orange_init_payload(&config, Some("direct-orange-init"), Some("solid-orange"));
            if status != 0 {
                hold_for_observation(config.hold_seconds);
            }
        } else if config.payload == "orange-gpu" {
            let prelude_status = run_orange_gpu_prelude(&config);
            if prelude_status != 0 {
                append_wrapper_log(&format!(
                    "orange-gpu prelude failed: status={prelude_status}"
                ));
            }
            if !validate_orange_gpu_config(&config) {
                hold_for_observation(config.hold_seconds);
                reboot_from_config(&config);
            }
            let _ =
                run_orange_gpu_checkpoint(&config, "validated", ORANGE_GPU_CHECKPOINT_HOLD_SECONDS);
            prepare_metadata_stage_runtime(&mut metadata_stage, &config);
            if metadata_stage.prepared {
                write_metadata_stage(&mut metadata_stage, "validated");
            }
            let payload_status = run_orange_gpu_payload(
                &config,
                &mut metadata_stage,
                args.argv0.as_deref().map(Path::new),
            );
            if payload_status == 0 {
                let postlude_status = run_orange_gpu_postlude(&config);
                if postlude_status != 0 {
                    hold_for_observation(config.hold_seconds);
                }
            } else {
                hold_for_observation(config.hold_seconds);
            }
        } else {
            hold_for_observation(config.hold_seconds);
        }

        if args.selftest {
            process::exit(0);
        }

        reboot_from_config(&config);
    }
}

#[cfg(target_os = "linux")]
#[unsafe(no_mangle)]
pub extern "C" fn main(argc: libc::c_int, argv: *const *const libc::c_char) -> libc::c_int {
    linux::main_linux_raw(argc, argv);
}
