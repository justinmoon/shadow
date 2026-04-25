#![cfg_attr(target_os = "linux", no_main)]

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("hello-init only supports linux targets");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
mod linux {
    use sha2::{Digest, Sha256};
    use std::ffi::{CStr, CString};
    use std::fmt::Write as _;
    use std::fs::{self, File, OpenOptions};
    use std::io::{self, BufReader, BufWriter, Read, Write};
    use std::net::{TcpStream, ToSocketAddrs};
    use std::os::unix::ffi::{OsStrExt, OsStringExt};
    use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
    use std::os::unix::io::AsRawFd;
    use std::os::unix::net::UnixDatagram;
    use std::path::{Component, Path, PathBuf};
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
    const ORANGE_GPU_DRI_DRIVER_PATH: &str = "/orange-gpu/lib/dri";
    const ORANGE_GPU_ICD_PATH: &str = "/orange-gpu/share/vulkan/icd.d/freedreno_icd.aarch64.json";
    const ORANGE_GPU_EGL_VENDOR_LIBRARY_DIRS: &str = "/orange-gpu/share/glvnd/egl_vendor.d";
    const ORANGE_GPU_XKB_CONFIG_EXTRA_PATH: &str = "/orange-gpu/etc/xkb";
    const ORANGE_GPU_XKB_CONFIG_ROOT: &str = "/orange-gpu/share/X11/xkb";
    const ORANGE_GPU_HOME: &str = "/orange-gpu/home";
    const ORANGE_GPU_CACHE_HOME: &str = "/orange-gpu/home/.cache";
    const ORANGE_GPU_CONFIG_HOME: &str = "/orange-gpu/home/.config";
    const ORANGE_GPU_MESA_CACHE_DIR: &str = "/orange-gpu/home/.cache/mesa";
    const ORANGE_GPU_COMPOSITOR_SESSION_PATH: &str = "/orange-gpu/shadow-session";
    const ORANGE_GPU_COMPOSITOR_BINARY_PATH: &str = "/orange-gpu/shadow-compositor-guest";
    const ORANGE_GPU_COMPOSITOR_STARTUP_CONFIG_PATH: &str =
        "/orange-gpu/compositor-scene-startup.json";
    const ORANGE_GPU_SHELL_SESSION_STARTUP_CONFIG_PATH: &str =
        "/orange-gpu/shell-session-startup.json";
    const ORANGE_GPU_APP_DIRECT_PRESENT_STARTUP_CONFIG_PATH: &str =
        "/orange-gpu/app-direct-present-startup.json";
    const ORANGE_GPU_COMPOSITOR_RUNTIME_DIR: &str = "/shadow-runtime";
    const ORANGE_GPU_COMPOSITOR_DUMMY_CLIENT_PATH: &str = "/orange-gpu/shadow-shell-dummy-client";
    const ORANGE_GPU_SUMMARY_PATH: &str = "/orange-gpu/summary.json";
    const ORANGE_GPU_OUTPUT_PATH: &str = "/orange-gpu/output.log";
    const ORANGE_GPU_PROBE_SUMMARY_PATH: &str = "/orange-gpu/probe-summary.json";
    const ORANGE_GPU_PROBE_OUTPUT_PATH: &str = "/orange-gpu/probe-output.log";
    const CAMERA_HAL_PATH: &str = "/vendor/lib64/hw/camera.sm6150.so";
    const CAMERA_BOOT_HAL_CAMERA_ID: &str = "0";
    const CAMERA_HAL_BIONIC_PROBE_PATH: &str = "/orange-gpu/camera-hal-bionic-probe";
    const CAMERA_HAL_BIONIC_LINKER_PATH: &str = "/apex/com.android.runtime/bin/linker64";
    const CAMERA_HAL_BIONIC_PROBE_SUMMARY_PATH: &str =
        "/orange-gpu/camera-hal-bionic-probe-summary.json";
    const CAMERA_HAL_BIONIC_PROBE_OUTPUT_PATH: &str =
        "/orange-gpu/camera-hal-bionic-probe-output.log";
    const CAMERA_HAL_BIONIC_LIBRARY_PATH: &str = concat!(
        "/vendor/lib64/hw:",
        "/vendor/lib64:",
        "/vendor/lib64/camera:",
        "/vendor/lib64/camera/components:",
        "/odm/lib64:",
        "/system/lib64:",
        "/system_ext/lib64:",
        "/apex/com.android.vndk.v33/lib64:",
        "/apex/com.android.runtime/lib64/bionic:",
        "/apex/com.android.runtime/lib64"
    );
    const FIRMWARE_CLASS_ROOT: &str = "/sys/class/firmware";
    const TRACEFS_ROOT: &str = "/sys/kernel/tracing";
    const TRACEFS_TRACE_PATH: &str = "/sys/kernel/tracing/trace";
    const TRACEFS_TRACING_ON_PATH: &str = "/sys/kernel/tracing/tracing_on";
    const TRACEFS_CURRENT_TRACER_PATH: &str = "/sys/kernel/tracing/current_tracer";
    const TRACEFS_SET_GRAPH_FUNCTION_PATH: &str = "/sys/kernel/tracing/set_graph_function";
    const METADATA_MOUNT_PATH: &str = "/metadata";
    const METADATA_DEVICE_PATH: &str = "/dev/block/by-name/metadata";
    const USERDATA_MOUNT_PATH: &str = "/data";
    const USERDATA_DEVICE_PATH: &str = "/dev/block/by-name/userdata";
    const USERDATA_BOOTDEVICE_PATH: &str = "/dev/block/bootdevice/by-name/userdata";
    const SUPER_DEVICE_PATH: &str = "/dev/block/by-name/super";
    const SHADOW_PAYLOAD_MOUNT_PATH: &str = "/shadow-payload";
    const SHADOW_PAYLOAD_PARTITION_PREFIX: &str = "shadow_payload";
    const METADATA_ROOT: &str = "/metadata/shadow-hello-init";
    const METADATA_BY_TOKEN_ROOT: &str = "/metadata/shadow-hello-init/by-token";
    const METADATA_SYSFS_BLOCK_ROOT: &str = "/sys/class/block";
    const METADATA_PARTNAME: &str = "metadata";
    const USERDATA_PARTNAME: &str = "userdata";
    const SUPER_PARTNAME: &str = "super";
    const METADATA_PREPARE_RETRY_ATTEMPTS: u32 = 10;
    const METADATA_PREPARE_RETRY_SLEEP_SECS: u32 = 1;
    const PAYLOAD_PROBE_STRATEGY: &str = "metadata-shadow-payload-v1";
    const PAYLOAD_PROBE_SOURCE: &str = "metadata";
    const PAYLOAD_PROBE_LOGICAL_SOURCE: &str = "shadow-logical-partition";
    const PAYLOAD_PROBE_METADATA_BY_TOKEN_ROOT: &str = "/metadata/shadow-payload/by-token";
    const PAYLOAD_PROBE_MANIFEST_NAME: &str = "manifest.env";
    const PAYLOAD_PROBE_DEFAULT_MARKER_NAME: &str = "payload.txt";
    const PAYLOAD_PROBE_FALLBACK_PATH: &str = "/orange-gpu";
    const GPU_BACKEND_ENV: &str = "WGPU_BACKEND";
    const VK_ICD_FILENAMES_ENV: &str = "VK_ICD_FILENAMES";
    const MESA_DRIVER_OVERRIDE_ENV: &str = "MESA_LOADER_DRIVER_OVERRIDE";
    const TU_DEBUG_ENV: &str = "TU_DEBUG";
    const LD_LIBRARY_PATH_ENV: &str = "LD_LIBRARY_PATH";
    const LIBGL_DRIVERS_PATH_ENV: &str = "LIBGL_DRIVERS_PATH";
    const EGL_VENDOR_LIBRARY_DIRS_ENV: &str = "__EGL_VENDOR_LIBRARY_DIRS";
    const HOME_ENV: &str = "HOME";
    const XDG_CACHE_HOME_ENV: &str = "XDG_CACHE_HOME";
    const XDG_CONFIG_HOME_ENV: &str = "XDG_CONFIG_HOME";
    const XKB_CONFIG_EXTRA_PATH_ENV: &str = "XKB_CONFIG_EXTRA_PATH";
    const XKB_CONFIG_ROOT_ENV: &str = "XKB_CONFIG_ROOT";
    const MESA_SHADER_CACHE_ENV: &str = "MESA_SHADER_CACHE_DIR";
    const GUEST_COMPOSITOR_LOADER_ENV: &str = "SHADOW_GUEST_COMPOSITOR_LOADER";
    const GUEST_COMPOSITOR_LIBRARY_PATH_ENV: &str = "SHADOW_GUEST_COMPOSITOR_LIBRARY_PATH";
    const SYSTEM_STAGE_LOADER_PATH_ENV: &str = "SHADOW_SYSTEM_STAGE_LOADER_PATH";
    const SYSTEM_STAGE_LIBRARY_PATH_ENV: &str = "SHADOW_SYSTEM_STAGE_LIBRARY_PATH";
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
    const FIRMWARE_HELPER_TIMEOUT_SECONDS: u64 = 35;
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
    const SUNFISH_TOUCH_MODULES: [&str; 2] = ["heatmap.ko", "ftm5.ko"];

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
        orange_gpu_metadata_prune_token_root: bool,
        orange_gpu_firmware_helper: bool,
        orange_gpu_timeout_action: String,
        orange_gpu_watchdog_timeout_secs: u32,
        orange_gpu_bundle_archive_path: String,
        payload_probe_strategy: String,
        payload_probe_source: String,
        payload_probe_root: String,
        payload_probe_manifest_path: String,
        payload_probe_fallback_path: String,
        camera_hal_camera_id: String,
        camera_hal_call_open: bool,
        shell_session_start_app_id: String,
        app_direct_present_app_id: String,
        app_direct_present_runtime_bundle_env: String,
        app_direct_present_runtime_bundle_path: String,
        app_direct_present_manual_touch: bool,
        hold_seconds: u32,
        prelude_hold_seconds: u32,
        reboot_target: String,
        run_token: String,
        dev_mount: String,
        dri_bootstrap: String,
        input_bootstrap: String,
        firmware_bootstrap: String,
        wifi_bootstrap: String,
        wifi_helper_profile: String,
        wifi_supplicant_probe: bool,
        wifi_association_probe: bool,
        wifi_ip_probe: bool,
        wifi_runtime_network: bool,
        wifi_runtime_clock_unix_secs: u64,
        wifi_credentials_path: String,
        wifi_dhcp_client_path: String,
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
                orange_gpu_metadata_prune_token_root: false,
                orange_gpu_firmware_helper: false,
                orange_gpu_timeout_action: "reboot".to_string(),
                orange_gpu_watchdog_timeout_secs: 0,
                orange_gpu_bundle_archive_path: String::new(),
                payload_probe_strategy: PAYLOAD_PROBE_STRATEGY.to_string(),
                payload_probe_source: PAYLOAD_PROBE_SOURCE.to_string(),
                payload_probe_root: String::new(),
                payload_probe_manifest_path: String::new(),
                payload_probe_fallback_path: PAYLOAD_PROBE_FALLBACK_PATH.to_string(),
                camera_hal_camera_id: CAMERA_BOOT_HAL_CAMERA_ID.to_string(),
                camera_hal_call_open: false,
                shell_session_start_app_id: "counter".to_string(),
                app_direct_present_app_id: "rust-demo".to_string(),
                app_direct_present_runtime_bundle_env: String::new(),
                app_direct_present_runtime_bundle_path: String::new(),
                app_direct_present_manual_touch: false,
                hold_seconds: DEFAULT_HOLD_SECONDS,
                prelude_hold_seconds: 0,
                reboot_target: "bootloader".to_string(),
                run_token: String::new(),
                dev_mount: "devtmpfs".to_string(),
                dri_bootstrap: "none".to_string(),
                input_bootstrap: "none".to_string(),
                firmware_bootstrap: "none".to_string(),
                wifi_bootstrap: "none".to_string(),
                wifi_helper_profile: "vnd-sm-core-binder-node".to_string(),
                wifi_supplicant_probe: true,
                wifi_association_probe: false,
                wifi_ip_probe: false,
                wifi_runtime_network: false,
                wifi_runtime_clock_unix_secs: 0,
                wifi_credentials_path: String::new(),
                wifi_dhcp_client_path: "/orange-gpu/busybox".to_string(),
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

    #[repr(C)]
    struct HwModuleMethods {
        open: Option<
            unsafe extern "C" fn(
                *const HwModulePartial,
                *const libc::c_char,
                *mut *mut HwDevicePartial,
            ) -> libc::c_int,
        >,
    }

    #[repr(C)]
    struct HwModulePartial {
        tag: u32,
        module_api_version: u16,
        hal_api_version: u16,
        id: *const libc::c_char,
        name: *const libc::c_char,
        author: *const libc::c_char,
        methods: *const HwModuleMethods,
        dso: *mut libc::c_void,
        reserved: [u64; 32 - 7],
    }

    #[repr(C)]
    struct HwDevicePartial {
        tag: u32,
        version: u32,
        module: *mut HwModulePartial,
        reserved: [u64; 12],
        close: Option<unsafe extern "C" fn(*mut HwDevicePartial) -> libc::c_int>,
    }

    #[repr(C)]
    struct CameraInfoPartial {
        facing: i32,
        orientation: i32,
        device_version: u32,
        static_camera_characteristics: *const libc::c_void,
        resource_cost: i32,
        conflicting_devices: *mut *mut libc::c_char,
        conflicting_devices_length: usize,
    }

    #[repr(C)]
    struct CameraModulePartial {
        common: HwModulePartial,
        get_number_of_cameras: Option<unsafe extern "C" fn() -> libc::c_int>,
        get_camera_info:
            Option<unsafe extern "C" fn(libc::c_int, *mut CameraInfoPartial) -> libc::c_int>,
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
        ensure_node(
            path,
            libc::S_IFCHR | perm,
            libc::makedev(major as u32, minor as u32),
        )
    }

    fn ensure_block_device(path: &Path, perm: u32, major: u64, minor: u64) -> io::Result<()> {
        ensure_node(
            path,
            libc::S_IFBLK | perm,
            libc::makedev(major as u32, minor as u32),
        )
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
                                | "camera-hal-link-probe"
                                | "wifi-linux-surface-probe"
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
                            "camera-hal-link-probe",
                            "wifi-linux-surface-probe",
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
                            "shell-session",
                            "shell-session-held",
                            "shell-session-runtime-touch-counter",
                            "app-direct-present",
                            "app-direct-present-touch-counter",
                            "app-direct-present-runtime-touch-counter",
                            "firmware-probe-only",
                            "payload-partition-probe",
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
                "orange_gpu_metadata_prune_token_root" | "orange-gpu-metadata-prune-token-root" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.orange_gpu_metadata_prune_token_root = parsed;
                    }
                }
                "orange_gpu_firmware_helper" | "orange-gpu-firmware-helper" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.orange_gpu_firmware_helper = parsed;
                    }
                }
                "orange_gpu_timeout_action" | "orange-gpu-timeout-action" => {
                    if let Some(parsed) = parse_allowed(value, &["reboot", "panic", "hold"]) {
                        config.orange_gpu_timeout_action = parsed;
                    }
                }
                "orange_gpu_watchdog_timeout_secs" | "orange-gpu-watchdog-timeout-secs" => {
                    if let Some(parsed) = parse_u32(value) {
                        config.orange_gpu_watchdog_timeout_secs = parsed;
                    }
                }
                "orange_gpu_bundle_archive_path" | "orange-gpu-bundle-archive-path" => {
                    config.orange_gpu_bundle_archive_path = value.trim().to_string();
                }
                "payload_probe_strategy" | "payload-probe-strategy" => {
                    config.payload_probe_strategy = value.trim().to_string();
                }
                "payload_probe_source" | "payload-probe-source" => {
                    config.payload_probe_source = value.trim().to_string();
                }
                "payload_probe_root" | "payload-probe-root" => {
                    config.payload_probe_root = value.trim().to_string();
                }
                "payload_probe_manifest_path" | "payload-probe-manifest-path" => {
                    config.payload_probe_manifest_path = value.trim().to_string();
                }
                "payload_probe_fallback_path" | "payload-probe-fallback-path" => {
                    config.payload_probe_fallback_path = value.trim().to_string();
                }
                "camera_hal_camera_id" | "camera-hal-camera-id" => {
                    let trimmed = value.trim();
                    if !trimmed.is_empty()
                        && trimmed.bytes().all(|byte| {
                            byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'
                        })
                    {
                        config.camera_hal_camera_id = trimmed.to_string();
                    }
                }
                "camera_hal_call_open" | "camera-hal-call-open" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.camera_hal_call_open = parsed;
                    }
                }
                "shell_session_start_app_id" | "shell-session-start-app-id" => {
                    config.shell_session_start_app_id = value.trim().to_string();
                }
                "app_direct_present_app_id" | "app-direct-present-app-id" => {
                    config.app_direct_present_app_id = value.trim().to_string();
                }
                "app_direct_present_runtime_bundle_env"
                | "app-direct-present-runtime-bundle-env" => {
                    config.app_direct_present_runtime_bundle_env = value.trim().to_string();
                }
                "app_direct_present_runtime_bundle_path"
                | "app-direct-present-runtime-bundle-path" => {
                    config.app_direct_present_runtime_bundle_path = value.trim().to_string();
                }
                "app_direct_present_manual_touch" | "app-direct-present-manual-touch" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.app_direct_present_manual_touch = parsed;
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
                "input_bootstrap" => {
                    if let Some(parsed) = parse_allowed(value, &["none", "sunfish-touch-event2"]) {
                        config.input_bootstrap = parsed;
                    }
                }
                "firmware_bootstrap" => {
                    if let Some(parsed) = parse_allowed(value, &["none", "ramdisk-lib-firmware"]) {
                        config.firmware_bootstrap = parsed;
                    }
                }
                "wifi_bootstrap" => {
                    if let Some(parsed) = parse_allowed(value, &["none", "sunfish-wlan0"]) {
                        config.wifi_bootstrap = parsed;
                    }
                }
                "wifi_helper_profile" => {
                    if let Some(parsed) = parse_allowed(
                        value,
                        &[
                            "full",
                            "no-service-managers",
                            "no-pm",
                            "no-modem-svc",
                            "no-rfs-storage",
                            "no-pd-mapper",
                            "no-cnss",
                            "qrtr-only",
                            "qrtr-pd",
                            "qrtr-pd-tftp",
                            "qrtr-pd-rfs",
                            "qrtr-pd-rfs-cnss",
                            "qrtr-pd-rfs-modem",
                            "qrtr-pd-rfs-modem-cnss",
                            "qrtr-pd-rfs-modem-pm",
                            "qrtr-pd-rfs-modem-pm-cnss",
                            "aidl-sm-core",
                            "vnd-sm-core",
                            "vnd-sm-core-binder-node",
                            "all-sm-core",
                            "none",
                        ],
                    ) {
                        config.wifi_helper_profile = parsed;
                    }
                }
                "wifi_supplicant_probe" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.wifi_supplicant_probe = parsed;
                    }
                }
                "wifi_association_probe" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.wifi_association_probe = parsed;
                    }
                }
                "wifi_ip_probe" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.wifi_ip_probe = parsed;
                    }
                }
                "wifi_runtime_network" => {
                    if let Some(parsed) = parse_bool(value) {
                        config.wifi_runtime_network = parsed;
                    }
                }
                "wifi_runtime_clock_unix_secs" => {
                    if let Ok(parsed) = value.trim().parse::<u64>() {
                        config.wifi_runtime_clock_unix_secs = parsed;
                    }
                }
                "wifi_credentials_path" => {
                    config.wifi_credentials_path = value.trim().to_string();
                }
                "wifi_dhcp_client_path" => {
                    config.wifi_dhcp_client_path = value.trim().to_string();
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

    fn discover_block_identity_by_partname(config: &Config, partname: &str) -> BlockDeviceIdentity {
        if config.dev_mount != "tmpfs" || !config.mount_sys {
            return BlockDeviceIdentity::default();
        }
        let Ok(entries) = fs::read_dir(METADATA_SYSFS_BLOCK_ROOT) else {
            return BlockDeviceIdentity::default();
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
                    partname_matches = value == partname;
                } else if let Some(value) = line.strip_prefix("MAJOR=") {
                    major_num = value.parse::<u32>().ok();
                } else if let Some(value) = line.strip_prefix("MINOR=") {
                    minor_num = value.parse::<u32>().ok();
                }
            }
            if partname_matches {
                if let (Some(major_num), Some(minor_num)) = (major_num, minor_num) {
                    return BlockDeviceIdentity {
                        available: true,
                        major_num,
                        minor_num,
                    };
                }
            }
        }
        BlockDeviceIdentity::default()
    }

    fn bootstrap_tmpfs_userdata_block_runtime(config: &Config) -> io::Result<()> {
        if config.dev_mount != "tmpfs" {
            return Ok(());
        }
        let block_device = discover_block_identity_by_partname(config, USERDATA_PARTNAME);
        if !block_device.available {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "userdata block device unavailable",
            ));
        }
        ensure_directory(Path::new("/dev/block"), 0o755)?;
        ensure_directory(Path::new("/dev/block/by-name"), 0o755)?;
        ensure_directory(Path::new("/dev/block/bootdevice"), 0o755)?;
        ensure_directory(Path::new("/dev/block/bootdevice/by-name"), 0o755)?;
        ensure_block_device(
            Path::new(USERDATA_DEVICE_PATH),
            0o600,
            block_device.major_num as u64,
            block_device.minor_num as u64,
        )?;
        ensure_block_device(
            Path::new(USERDATA_BOOTDEVICE_PATH),
            0o600,
            block_device.major_num as u64,
            block_device.minor_num as u64,
        )
    }

    fn bootstrap_tmpfs_named_block_device(
        config: &Config,
        partname: &str,
        path: &Path,
    ) -> io::Result<()> {
        if config.dev_mount != "tmpfs" {
            return Ok(());
        }
        let block_device = discover_block_identity_by_partname(config, partname);
        if !block_device.available {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("{partname} block device unavailable"),
            ));
        }
        ensure_directory(Path::new("/dev/block"), 0o755)?;
        ensure_directory(Path::new("/dev/block/by-name"), 0o755)?;
        ensure_block_device(
            path,
            0o600,
            block_device.major_num as u64,
            block_device.minor_num as u64,
        )
    }

    fn prepare_userdata_payload_root(config: &Config, payload_root: &Path) -> Result<bool, String> {
        if !payload_root.starts_with(USERDATA_MOUNT_PATH) {
            return Ok(false);
        }
        bootstrap_tmpfs_userdata_block_runtime(config)
            .map_err(|error| format!("userdata-block-bootstrap:{error}"))?;
        ensure_directory(Path::new(USERDATA_MOUNT_PATH), 0o771)
            .map_err(|error| format!("userdata-mkdir:{error}"))?;
        let mount_flags = (libc::MS_NOATIME | libc::MS_NODEV | libc::MS_NOSUID) as libc::c_ulong;
        mount_fs(
            USERDATA_DEVICE_PATH,
            USERDATA_MOUNT_PATH,
            "f2fs",
            mount_flags,
            Some(""),
        )
        .map_err(|error| format!("userdata-mount-f2fs:{error}"))?;
        Ok(true)
    }

    fn prepare_shadow_logical_payload_root(
        config: &Config,
        payload_root: &Path,
    ) -> Result<bool, String> {
        if !payload_root.starts_with(SHADOW_PAYLOAD_MOUNT_PATH) {
            return Ok(false);
        }
        bootstrap_tmpfs_named_block_device(config, SUPER_PARTNAME, Path::new(SUPER_DEVICE_PATH))
            .map_err(|error| format!("shadow-logical-super-bootstrap:{error}"))?;
        let slot_suffix = active_slot_suffix().unwrap_or_else(|| "_a".to_string());
        let partition_name = format!("{SHADOW_PAYLOAD_PARTITION_PREFIX}{slot_suffix}");
        let dm_path = create_shadow_payload_dm_linear(&partition_name)
            .map_err(|error| format!("shadow-logical-dm:{error}"))?;
        ensure_directory(Path::new(SHADOW_PAYLOAD_MOUNT_PATH), 0o755)
            .map_err(|error| format!("shadow-logical-mkdir:{error}"))?;
        let mount_flags = (libc::MS_RDONLY | libc::MS_NOATIME | libc::MS_NODEV | libc::MS_NOSUID)
            as libc::c_ulong;
        mount_fs(
            &dm_path,
            SHADOW_PAYLOAD_MOUNT_PATH,
            "ext4",
            mount_flags,
            Some(""),
        )
        .map_err(|error| format!("shadow-logical-mount-ext4:{error}"))?;
        Ok(true)
    }

    fn active_slot_suffix() -> Option<String> {
        for path in ["/proc/bootconfig", "/proc/cmdline"] {
            let Ok(text) = fs::read_to_string(path) else {
                continue;
            };
            for token in text.split_whitespace() {
                let token = token.trim_matches('"');
                for prefix in ["androidboot.slot_suffix=", "androidboot.slot="] {
                    if let Some(value) = token.strip_prefix(prefix) {
                        let value = value.trim_matches('"');
                        if value == "a" || value == "b" {
                            return Some(format!("_{value}"));
                        }
                        if value == "_a" || value == "_b" {
                            return Some(value.to_string());
                        }
                    }
                }
            }
        }
        None
    }

    #[derive(Clone, Debug)]
    struct LogicalExtent {
        logical_start: u64,
        sectors: u64,
        physical_sector: u64,
    }

    fn read_exact_at(path: &Path, offset: u64, size: usize) -> io::Result<Vec<u8>> {
        use std::os::unix::fs::FileExt;
        let file = File::open(path)?;
        let mut buffer = vec![0_u8; size];
        let mut read_total = 0_usize;
        while read_total < size {
            let count = file.read_at(&mut buffer[read_total..], offset + read_total as u64)?;
            if count == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "short positioned read",
                ));
            }
            read_total += count;
        }
        Ok(buffer)
    }

    fn le_u16(data: &[u8], offset: usize) -> Result<u16, String> {
        let bytes: [u8; 2] = data
            .get(offset..offset + 2)
            .ok_or_else(|| "lp-read-u16-oob".to_string())?
            .try_into()
            .map_err(|_| "lp-read-u16-slice".to_string())?;
        Ok(u16::from_le_bytes(bytes))
    }

    fn le_u32(data: &[u8], offset: usize) -> Result<u32, String> {
        let bytes: [u8; 4] = data
            .get(offset..offset + 4)
            .ok_or_else(|| "lp-read-u32-oob".to_string())?
            .try_into()
            .map_err(|_| "lp-read-u32-slice".to_string())?;
        Ok(u32::from_le_bytes(bytes))
    }

    fn le_u64(data: &[u8], offset: usize) -> Result<u64, String> {
        let bytes: [u8; 8] = data
            .get(offset..offset + 8)
            .ok_or_else(|| "lp-read-u64-oob".to_string())?
            .try_into()
            .map_err(|_| "lp-read-u64-slice".to_string())?;
        Ok(u64::from_le_bytes(bytes))
    }

    fn c_name(data: &[u8]) -> String {
        let end = data
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(data.len());
        String::from_utf8_lossy(&data[..end]).into_owned()
    }

    fn sha256_bytes(data: &[u8]) -> [u8; 32] {
        let digest = Sha256::digest(data);
        let mut out = [0_u8; 32];
        out.copy_from_slice(&digest);
        out
    }

    fn validate_lp_geometry_checksum(geometry: &[u8]) -> Result<(), String> {
        let struct_size = le_u32(geometry, 4)? as usize;
        if struct_size > geometry.len() || struct_size < 52 {
            return Err(format!("lp-geometry-size:{struct_size}"));
        }
        let expected = geometry
            .get(8..40)
            .ok_or_else(|| "lp-geometry-checksum-oob".to_string())?;
        let mut checksum_input = geometry[..struct_size].to_vec();
        checksum_input[8..40].fill(0);
        if sha256_bytes(&checksum_input) != expected {
            return Err("lp-geometry-checksum".to_string());
        }
        Ok(())
    }

    fn validate_lp_header_checksum(header: &[u8], header_size: usize) -> Result<(), String> {
        let expected = header
            .get(12..44)
            .ok_or_else(|| "lp-header-checksum-oob".to_string())?;
        let mut checksum_input = header
            .get(..header_size)
            .ok_or_else(|| "lp-header-checksum-size".to_string())?
            .to_vec();
        checksum_input[12..44].fill(0);
        if sha256_bytes(&checksum_input) != expected {
            return Err("lp-header-checksum".to_string());
        }
        Ok(())
    }

    fn validate_lp_table_checksum(header: &[u8], tables: &[u8]) -> Result<(), String> {
        let expected = header
            .get(48..80)
            .ok_or_else(|| "lp-tables-checksum-oob".to_string())?;
        if sha256_bytes(tables) != expected {
            return Err("lp-tables-checksum".to_string());
        }
        Ok(())
    }

    fn validate_lp_table_bounds(
        tables_size: usize,
        offset: usize,
        count: usize,
        entry_size: usize,
        label: &str,
    ) -> Result<(), String> {
        let table_size = count
            .checked_mul(entry_size)
            .ok_or_else(|| format!("lp-{label}-table-size-overflow"))?;
        let end = offset
            .checked_add(table_size)
            .ok_or_else(|| format!("lp-{label}-table-end-overflow"))?;
        if end > tables_size {
            return Err(format!(
                "lp-{label}-table-bounds:{offset}+{table_size}>{tables_size}"
            ));
        }
        Ok(())
    }

    fn find_logical_partition_extents(partition_name: &str) -> Result<Vec<LogicalExtent>, String> {
        const LP_METADATA_GEOMETRY_MAGIC: u32 = 0x616c4467;
        const LP_METADATA_HEADER_MAGIC: u32 = 0x414c5030;
        const LP_METADATA_GEOMETRY_SIZE: u64 = 4096;
        const LP_PARTITION_RESERVED_BYTES: u64 = 4096;
        const LP_TARGET_TYPE_LINEAR: u32 = 0;
        const LP_PARTITION_ENTRY_SIZE: usize = 52;
        const LP_EXTENT_ENTRY_SIZE: usize = 24;

        let geometry = read_exact_at(
            Path::new(SUPER_DEVICE_PATH),
            LP_PARTITION_RESERVED_BYTES,
            LP_METADATA_GEOMETRY_SIZE as usize,
        )
        .map_err(|error| format!("lp-geometry-read:{error}"))?;
        if le_u32(&geometry, 0)? != LP_METADATA_GEOMETRY_MAGIC {
            return Err("lp-geometry-magic".to_string());
        }
        validate_lp_geometry_checksum(&geometry)?;
        let metadata_max_size = le_u32(&geometry, 40)? as u64;
        let slot_count = le_u32(&geometry, 44)? as u64;
        if metadata_max_size == 0 || metadata_max_size % 512 != 0 {
            return Err(format!("lp-metadata-max-size:{metadata_max_size}"));
        }
        let slot_suffix = active_slot_suffix().unwrap_or_else(|| "_a".to_string());
        let slot_index = match slot_suffix.as_str() {
            "_a" => 0_u64,
            "_b" => 1_u64,
            _ => 0_u64,
        };
        if slot_index >= slot_count {
            return Err(format!("lp-slot-out-of-range:{slot_suffix}/{slot_count}"));
        }
        let metadata_offset = LP_PARTITION_RESERVED_BYTES
            + (LP_METADATA_GEOMETRY_SIZE * 2)
            + metadata_max_size * slot_index;
        let header_prefix = read_exact_at(Path::new(SUPER_DEVICE_PATH), metadata_offset, 256)
            .map_err(|error| format!("lp-header-read:{error}"))?;
        if le_u32(&header_prefix, 0)? != LP_METADATA_HEADER_MAGIC {
            return Err("lp-header-magic".to_string());
        }
        if le_u16(&header_prefix, 4)? != 10 {
            return Err(format!("lp-header-major:{}", le_u16(&header_prefix, 4)?));
        }
        let header_size = le_u32(&header_prefix, 8)? as usize;
        if header_size > header_prefix.len() || header_size < 128 {
            return Err(format!("lp-header-size:{header_size}"));
        }
        validate_lp_header_checksum(&header_prefix, header_size)?;
        let tables_size = le_u32(&header_prefix, 44)? as usize;
        if tables_size > metadata_max_size as usize {
            return Err(format!("lp-tables-size:{tables_size}>{metadata_max_size}"));
        }
        let partitions_offset = le_u32(&header_prefix, 80)? as usize;
        let partitions_count = le_u32(&header_prefix, 84)? as usize;
        let partitions_entry_size = le_u32(&header_prefix, 88)? as usize;
        let extents_offset = le_u32(&header_prefix, 92)? as usize;
        let extents_count = le_u32(&header_prefix, 96)? as usize;
        let extents_entry_size = le_u32(&header_prefix, 100)? as usize;
        if partitions_entry_size < LP_PARTITION_ENTRY_SIZE {
            return Err(format!("lp-partition-entry-size:{partitions_entry_size}"));
        }
        if extents_entry_size < LP_EXTENT_ENTRY_SIZE {
            return Err(format!("lp-extent-entry-size:{extents_entry_size}"));
        }
        validate_lp_table_bounds(
            tables_size,
            partitions_offset,
            partitions_count,
            partitions_entry_size,
            "partition",
        )?;
        validate_lp_table_bounds(
            tables_size,
            extents_offset,
            extents_count,
            extents_entry_size,
            "extent",
        )?;
        let tables = read_exact_at(
            Path::new(SUPER_DEVICE_PATH),
            metadata_offset + header_size as u64,
            tables_size,
        )
        .map_err(|error| format!("lp-tables-read:{error}"))?;
        validate_lp_table_checksum(&header_prefix, &tables)?;
        let partition_table = tables
            .get(partitions_offset..)
            .ok_or_else(|| "lp-partition-table-oob".to_string())?;
        let extent_table = tables
            .get(extents_offset..)
            .ok_or_else(|| "lp-extent-table-oob".to_string())?;

        for index in 0..partitions_count {
            let start = index * partitions_entry_size;
            let Some(entry) = partition_table.get(start..start + partitions_entry_size) else {
                return Err("lp-partition-entry-oob".to_string());
            };
            let name = c_name(&entry[..36]);
            if name != partition_name {
                continue;
            }
            let first_extent = le_u32(entry, 40)? as usize;
            let num_extents = le_u32(entry, 44)? as usize;
            if first_extent + num_extents > extents_count {
                return Err("lp-partition-extents-oob".to_string());
            }
            let mut logical_start = 0_u64;
            let mut extents = Vec::new();
            for extent_index in first_extent..first_extent + num_extents {
                let extent_start = extent_index * extents_entry_size;
                let Some(extent) =
                    extent_table.get(extent_start..extent_start + extents_entry_size)
                else {
                    return Err("lp-extent-entry-oob".to_string());
                };
                let sectors = le_u64(extent, 0)?;
                let target_type = le_u32(extent, 8)?;
                let physical_sector = le_u64(extent, 12)?;
                let target_source = le_u32(extent, 20)?;
                if target_type != LP_TARGET_TYPE_LINEAR {
                    return Err(format!("lp-extent-target-type:{target_type}"));
                }
                if target_source != 0 {
                    return Err(format!("lp-extent-target-source:{target_source}"));
                }
                extents.push(LogicalExtent {
                    logical_start,
                    sectors,
                    physical_sector,
                });
                logical_start = logical_start.saturating_add(sectors);
            }
            if extents.is_empty() {
                return Err("lp-partition-empty".to_string());
            }
            return Ok(extents);
        }
        Err(format!("lp-partition-missing:{partition_name}"))
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct DmIoctl {
        version: [u32; 3],
        data_size: u32,
        data_start: u32,
        target_count: u32,
        open_count: i32,
        flags: u32,
        event_nr: u32,
        padding: u32,
        dev: u64,
        name: [u8; 128],
        uuid: [u8; 129],
        data: [u8; 7],
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct DmTargetSpec {
        sector_start: u64,
        length: u64,
        status: i32,
        next: u32,
        target_type: [u8; 16],
    }

    fn dm_ioctl_init(name: &str) -> DmIoctl {
        let mut io = DmIoctl {
            version: [4, 0, 0],
            data_size: std::mem::size_of::<DmIoctl>() as u32,
            data_start: 0,
            target_count: 0,
            open_count: 0,
            flags: 0,
            event_nr: 0,
            padding: 0,
            dev: 0,
            name: [0; 128],
            uuid: [0; 129],
            data: [0; 7],
        };
        let bytes = name.as_bytes();
        let len = bytes.len().min(io.name.len() - 1);
        io.name[..len].copy_from_slice(&bytes[..len]);
        io
    }

    fn align8(value: usize) -> usize {
        (value + 7) & !7
    }

    fn append_dm_linear_target(buffer: &mut Vec<u8>, extent: &LogicalExtent) {
        let params = format!("{SUPER_DEVICE_PATH} {}", extent.physical_sector);
        let record_len = align8(std::mem::size_of::<DmTargetSpec>() + params.len() + 1);
        let mut spec = DmTargetSpec {
            sector_start: extent.logical_start,
            length: extent.sectors,
            status: 0,
            next: record_len as u32,
            target_type: [0; 16],
        };
        spec.target_type[..6].copy_from_slice(b"linear");
        let spec_bytes = unsafe {
            std::slice::from_raw_parts(
                (&spec as *const DmTargetSpec).cast::<u8>(),
                std::mem::size_of::<DmTargetSpec>(),
            )
        };
        buffer.extend_from_slice(spec_bytes);
        buffer.extend_from_slice(params.as_bytes());
        buffer.push(0);
        while buffer.len() % 8 != 0 {
            buffer.push(0);
        }
    }

    fn create_shadow_payload_dm_linear(partition_name: &str) -> Result<String, String> {
        const DM_DEV_CREATE: libc::c_int = 0xc138fd03_u32 as libc::c_int;
        const DM_DEV_SUSPEND: libc::c_int = 0xc138fd06_u32 as libc::c_int;
        const DM_TABLE_LOAD: libc::c_int = 0xc138fd09_u32 as libc::c_int;
        const DM_READONLY_FLAG: u32 = 1 << 0;

        let extents = find_logical_partition_extents(partition_name)?;
        ensure_directory(Path::new("/dev/block/mapper"), 0o755)
            .map_err(|error| format!("dm-mapper-dir:{error}"))?;
        ensure_char_device(Path::new("/dev/device-mapper"), 0o600, 10, 236)
            .map_err(|error| format!("dm-control-node:{error}"))?;

        let control = CString::new("/dev/device-mapper").unwrap();
        let fd = unsafe { libc::open(control.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(format!("dm-control-open:{}", io::Error::last_os_error()));
        }

        let mut create = dm_ioctl_init(partition_name);
        let rc = unsafe { libc::ioctl(fd, DM_DEV_CREATE, &mut create) };
        if rc != 0 {
            let error = io::Error::last_os_error();
            unsafe {
                libc::close(fd);
            }
            return Err(format!("dm-dev-create:{error}"));
        }

        let mut payload = vec![0_u8; std::mem::size_of::<DmIoctl>()];
        for extent in &extents {
            append_dm_linear_target(&mut payload, extent);
        }
        let io = payload.as_mut_ptr().cast::<DmIoctl>();
        unsafe {
            *io = dm_ioctl_init(partition_name);
            (*io).data_size = payload.len() as u32;
            (*io).data_start = std::mem::size_of::<DmIoctl>() as u32;
            (*io).target_count = extents.len() as u32;
            (*io).flags |= DM_READONLY_FLAG;
        }
        let rc = unsafe { libc::ioctl(fd, DM_TABLE_LOAD, io) };
        if rc != 0 {
            let error = io::Error::last_os_error();
            unsafe {
                libc::close(fd);
            }
            return Err(format!("dm-table-load:{error}"));
        }

        let mut suspend = dm_ioctl_init(partition_name);
        let rc = unsafe { libc::ioctl(fd, DM_DEV_SUSPEND, &mut suspend) };
        if rc != 0 {
            let error = io::Error::last_os_error();
            unsafe {
                libc::close(fd);
            }
            return Err(format!("dm-dev-suspend:{error}"));
        }
        unsafe {
            libc::close(fd);
        }

        let major_num = libc::major(suspend.dev as libc::dev_t) as u64;
        let minor_num = libc::minor(suspend.dev as libc::dev_t) as u64;
        let dm_path = format!("/dev/block/mapper/{partition_name}");
        ensure_block_device(Path::new(&dm_path), 0o600, major_num, minor_num)
            .map_err(|error| format!("dm-node:{error}"))?;
        Ok(dm_path)
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

    fn sync_directory(path: &Path) -> io::Result<()> {
        File::open(path)?.sync_all()
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

    fn append_pid_children_tree_excerpt(payload: &mut String, pid: u32, depth: u32) {
        if depth == 0 {
            return;
        }

        let children_path = format!("/proc/{pid}/task/{pid}/children");
        let children = fs::read_to_string(&children_path).unwrap_or_else(|error| {
            format!(
                "<unavailable errno={:?} error={}>\n",
                error.raw_os_error(),
                error
            )
        });
        let _ = writeln!(payload, "begin:{children_path}<<");
        payload.push_str(&children);
        if !children.ends_with('\n') {
            payload.push('\n');
        }
        let _ = writeln!(payload, ">>end:{children_path}");

        for child_pid in children
            .split_whitespace()
            .filter_map(|value| value.parse::<u32>().ok())
            .take(16)
        {
            append_pid_proc_excerpt(payload, child_pid, "cmdline", 512);
            append_pid_proc_excerpt(payload, child_pid, "wchan", 128);
            append_pid_proc_excerpt(payload, child_pid, "status", 2048);
            append_pid_proc_excerpt(payload, child_pid, "stack", 4096);
            append_pid_children_tree_excerpt(payload, child_pid, depth - 1);
        }
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

    fn orange_gpu_mode_is_shell_session(mode: &str) -> bool {
        matches!(
            mode,
            "shell-session" | "shell-session-held" | "shell-session-runtime-touch-counter"
        )
    }

    fn orange_gpu_mode_is_shell_session_held(mode: &str) -> bool {
        mode == "shell-session-held"
    }

    fn orange_gpu_mode_is_shell_session_runtime_touch_counter(mode: &str) -> bool {
        mode == "shell-session-runtime-touch-counter"
    }

    fn orange_gpu_config_is_held_runtime_touch_counter(config: &Config) -> bool {
        orange_gpu_mode_is_shell_session_held(&config.orange_gpu_mode)
            && config.shell_session_start_app_id == "counter"
    }

    fn orange_gpu_mode_is_app_direct_present(mode: &str) -> bool {
        matches!(
            mode,
            "app-direct-present"
                | "app-direct-present-touch-counter"
                | "app-direct-present-runtime-touch-counter"
        )
    }

    fn orange_gpu_mode_is_app_direct_present_touch_counter(mode: &str) -> bool {
        matches!(
            mode,
            "app-direct-present-touch-counter" | "app-direct-present-runtime-touch-counter"
        )
    }

    fn orange_gpu_mode_is_app_direct_present_runtime_touch_counter(mode: &str) -> bool {
        mode == "app-direct-present-runtime-touch-counter"
    }

    fn orange_gpu_mode_uses_session_frame_capture(mode: &str) -> bool {
        orange_gpu_mode_is_compositor_scene(mode)
            || orange_gpu_mode_is_shell_session(mode)
            || orange_gpu_mode_is_app_direct_present(mode)
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

    fn json_escape(value: &str) -> String {
        let mut escaped = String::new();
        for ch in value.chars() {
            match ch {
                '"' => escaped.push_str("\\\""),
                '\\' => escaped.push_str("\\\\"),
                '\n' => escaped.push_str("\\n"),
                '\r' => escaped.push_str("\\r"),
                '\t' => escaped.push_str("\\t"),
                ch if ch < ' ' => {
                    let _ = write!(escaped, "\\u{:04x}", ch as u32);
                }
                ch => escaped.push(ch),
            }
        }
        escaped
    }

    fn json_string(value: &str) -> String {
        format!("\"{}\"", json_escape(value))
    }

    fn json_optional_string(value: Option<String>) -> String {
        match value {
            Some(value) => json_string(&value),
            None => "null".to_string(),
        }
    }

    fn json_string_array(values: &[String]) -> String {
        let mut payload = String::new();
        payload.push('[');
        for (index, value) in values.iter().enumerate() {
            if index > 0 {
                payload.push_str(", ");
            }
            payload.push_str(&json_string(value));
        }
        payload.push(']');
        payload
    }

    fn json_pointer(ptr: *mut libc::c_void) -> String {
        if ptr.is_null() {
            "null".to_string()
        } else {
            json_string(&format!("0x{:x}", ptr as usize))
        }
    }

    #[derive(Default)]
    struct PayloadProbeManifest {
        schema: String,
        payload_source: String,
        payload_version: String,
        payload_fingerprint: String,
        payload_root: String,
        payload_marker: String,
    }

    fn payload_probe_root_path(config: &Config) -> PathBuf {
        if !config.payload_probe_root.is_empty() {
            return PathBuf::from(&config.payload_probe_root);
        }
        Path::new(PAYLOAD_PROBE_METADATA_BY_TOKEN_ROOT).join(&config.run_token)
    }

    fn payload_probe_manifest_path(config: &Config, payload_root: &Path) -> PathBuf {
        if !config.payload_probe_manifest_path.is_empty() {
            return PathBuf::from(&config.payload_probe_manifest_path);
        }
        payload_root.join(PAYLOAD_PROBE_MANIFEST_NAME)
    }

    fn payload_probe_marker_path(payload_root: &Path, manifest: &PayloadProbeManifest) -> PathBuf {
        let marker = if manifest.payload_marker.is_empty() {
            PAYLOAD_PROBE_DEFAULT_MARKER_NAME
        } else {
            manifest.payload_marker.as_str()
        };
        let marker_path = Path::new(marker);
        if marker_path.is_absolute() {
            marker_path.to_path_buf()
        } else {
            payload_root.join(marker_path)
        }
    }

    fn read_payload_probe_manifest(path: &Path) -> Result<PayloadProbeManifest, String> {
        let text = fs::read_to_string(path).map_err(|error| format!("manifest-read:{error}"))?;
        let mut manifest = PayloadProbeManifest::default();
        for raw_line in text.lines() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let value = value.trim().to_string();
            match key.trim() {
                "schema" => manifest.schema = value,
                "payload_source" | "source" => manifest.payload_source = value,
                "payload_version" | "version" => manifest.payload_version = value,
                "payload_fingerprint" | "fingerprint" => manifest.payload_fingerprint = value,
                "payload_root" | "root" => manifest.payload_root = value,
                "payload_marker" | "marker" => manifest.payload_marker = value,
                _ => {}
            }
        }
        if manifest.schema != PAYLOAD_PROBE_STRATEGY {
            return Err(format!("unsupported-schema:{}", manifest.schema));
        }
        if manifest.payload_source.is_empty() {
            manifest.payload_source = PAYLOAD_PROBE_SOURCE.to_string();
        }
        if manifest.payload_version.is_empty() {
            return Err("missing-payload-version".to_string());
        }
        if manifest.payload_fingerprint.is_empty() {
            return Err("missing-payload-fingerprint".to_string());
        }
        Ok(manifest)
    }

    fn sha256_file_fingerprint(path: &Path) -> Result<String, String> {
        let mut file = File::open(path).map_err(|error| format!("marker-open:{error}"))?;
        let mut hasher = Sha256::new();
        let mut buffer = [0_u8; 8192];
        loop {
            let count = file
                .read(&mut buffer)
                .map_err(|error| format!("marker-read:{error}"))?;
            if count == 0 {
                break;
            }
            hasher.update(&buffer[..count]);
        }
        let digest = hasher.finalize();
        let mut hex = String::with_capacity(64);
        for byte in digest {
            let _ = write!(&mut hex, "{byte:02x}");
        }
        Ok(format!("sha256:{hex}"))
    }

    fn c_string_from_ptr(ptr: *const libc::c_char) -> Option<String> {
        if ptr.is_null() {
            None
        } else {
            Some(
                unsafe { CStr::from_ptr(ptr) }
                    .to_string_lossy()
                    .into_owned(),
            )
        }
    }

    fn dl_error_message(prefix: &str) -> String {
        let error = unsafe { libc::dlerror() };
        if error.is_null() {
            prefix.to_string()
        } else {
            format!(
                "{}: {}",
                prefix,
                unsafe { CStr::from_ptr(error) }.to_string_lossy()
            )
        }
    }

    fn camera_boot_hal_path_status_json(path: &str) -> String {
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
                format!(
                    "{{\"path\":{},\"exists\":true,\"type\":{},\"mode\":\"{:o}\",\"uid\":{},\"gid\":{},\"size\":{}}}",
                    json_string(path),
                    json_string(file_type),
                    metadata.mode() & 0o7777,
                    metadata.uid(),
                    metadata.gid(),
                    metadata.len()
                )
            }
            Err(error) => format!(
                "{{\"path\":{},\"exists\":false,\"errno\":{},\"error\":{}}}",
                json_string(path),
                error.raw_os_error().unwrap_or(0),
                json_string(&error.to_string())
            ),
        }
    }

    fn push_camera_boot_hal_stage(
        stages: &mut Vec<String>,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
        stage: &str,
        status: &str,
        detail: &str,
    ) {
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            &format!("{stage}-{status}"),
        );
        stages.push(format!(
            "{{\"stage\":{},\"status\":{},\"detail\":{}}}",
            json_string(stage),
            json_string(status),
            json_string(detail)
        ));
    }

    fn write_camera_boot_hal_summary(summary: &str) -> io::Result<()> {
        let temp_path = Path::new(ORANGE_GPU_ROOT).join(".camera-boot-hal-summary.json.tmp");
        write_atomic_text_file(&temp_path, Path::new(ORANGE_GPU_SUMMARY_PATH), summary)
    }

    fn wifi_boot_path_status_json(path: &str) -> String {
        camera_boot_hal_path_status_json(path)
    }

    fn read_trimmed_file(path: &str, max_bytes: usize) -> Option<String> {
        fs::read(path).ok().map(|bytes| {
            String::from_utf8_lossy(&bytes[..bytes.len().min(max_bytes)])
                .trim()
                .to_string()
        })
    }

    fn read_dir_names(path: &str, max_entries: usize) -> Vec<String> {
        let mut names = Vec::new();
        if let Ok(entries) = fs::read_dir(path) {
            for entry in entries.flatten().take(max_entries) {
                names.push(entry.file_name().to_string_lossy().into_owned());
            }
        }
        names.sort();
        names
    }

    const WIFI_HELPER_PROCESS_NAMES: &[&str] = &[
        "servicemanager",
        "hwservicemanager",
        "vndservicemanager",
        "qseecomd",
        "irsc_util",
        "qrtr-ns",
        "rmt_storage",
        "tftp_server",
        "modem_svc",
        "pd-mapper",
        "pm-service",
        "pm-proxy",
        "cnss-daemon",
        "wpa_supplicant",
    ];

    const WIFI_PROFILE_CONTRACT_HELPERS: &[&str] = &[
        "servicemanager",
        "hwservicemanager",
        "vndservicemanager",
        "qrtr-ns",
        "rmt_storage",
        "tftp_server",
        "modem_svc",
        "pd-mapper",
        "pm-service",
        "pm-proxy",
        "cnss-daemon",
    ];

    fn json_str_array(values: &[&str]) -> String {
        format!(
            "[{}]",
            values
                .iter()
                .map(|value| json_string(value))
                .collect::<Vec<_>>()
                .join(",")
        )
    }

    fn wifi_helper_logs_json() -> String {
        let entries = WIFI_HELPER_PROCESS_NAMES
            .iter()
            .map(|name| {
                let path = format!("/orange-gpu/wifi-helper-{name}.log");
                format!(
                    "{{\"name\":{},\"path\":{},\"excerpt\":{}}}",
                    json_string(name),
                    json_string(&path),
                    json_string(&redact_wifi_sensitive_text(&read_file_excerpt(&path, 8192)))
                )
            })
            .collect::<Vec<_>>()
            .join(",\n    ");
        format!("[\n    {}\n  ]", entries)
    }

    struct WifiHelperProcessSnapshot {
        processes_json: String,
        running_names: Vec<String>,
    }

    fn wifi_helper_process_snapshot() -> WifiHelperProcessSnapshot {
        let mut processes = Vec::new();
        let mut running_names = Vec::new();
        if let Ok(entries) = fs::read_dir("/proc") {
            for entry in entries.flatten() {
                let pid = entry.file_name().to_string_lossy().into_owned();
                if pid.is_empty() || pid.chars().any(|ch| !ch.is_ascii_digit()) {
                    continue;
                }
                let cmdline = read_trimmed_file(&format!("/proc/{pid}/cmdline"), 2048)
                    .unwrap_or_default()
                    .replace('\0', " ");
                let Some(name) = WIFI_HELPER_PROCESS_NAMES.iter().find(|name| {
                    cmdline.split_whitespace().any(|part| {
                        Path::new(part)
                            .file_name()
                            .and_then(|file_name| file_name.to_str())
                            == Some(*name)
                    })
                }) else {
                    continue;
                };
                if !running_names.iter().any(|running| running == name) {
                    running_names.push((*name).to_string());
                }
                let comm = read_trimmed_file(&format!("/proc/{pid}/comm"), 128).unwrap_or_default();
                processes.push(format!(
                    "{{\"pid\":{},\"name\":{},\"comm\":{},\"cmdline\":{}}}",
                    json_string(&pid),
                    json_string(name),
                    json_string(&comm),
                    json_string(&cmdline)
                ));
            }
        }
        WifiHelperProcessSnapshot {
            processes_json: format!("[{}]", processes.join(",")),
            running_names,
        }
    }

    fn wifi_helper_processes_json() -> String {
        wifi_helper_process_snapshot().processes_json
    }

    fn wifi_helper_profile_is_known(profile: &str) -> bool {
        matches!(
            profile,
            "full"
                | "no-service-managers"
                | "no-pm"
                | "no-modem-svc"
                | "no-rfs-storage"
                | "no-pd-mapper"
                | "no-cnss"
                | "qrtr-only"
                | "qrtr-pd"
                | "qrtr-pd-tftp"
                | "qrtr-pd-rfs"
                | "qrtr-pd-rfs-cnss"
                | "qrtr-pd-rfs-modem"
                | "qrtr-pd-rfs-modem-cnss"
                | "qrtr-pd-rfs-modem-pm"
                | "qrtr-pd-rfs-modem-pm-cnss"
                | "aidl-sm-core"
                | "vnd-sm-core"
                | "vnd-sm-core-binder-node"
                | "all-sm-core"
                | "none"
        )
    }

    fn wifi_helper_profile_expected_helpers(profile: &str) -> Vec<&'static str> {
        WIFI_PROFILE_CONTRACT_HELPERS
            .iter()
            .copied()
            .filter(|name| wifi_helper_profile_allows(profile, name))
            .collect()
    }

    fn wifi_helper_contract_missing(
        expected: &[&str],
        snapshot: &WifiHelperProcessSnapshot,
    ) -> Vec<String> {
        expected
            .iter()
            .filter(|name| {
                !snapshot
                    .running_names
                    .iter()
                    .any(|running_name| running_name == **name)
            })
            .map(|name| (*name).to_string())
            .collect()
    }

    fn wifi_helper_contract_unexpected(
        profile: &str,
        snapshot: &WifiHelperProcessSnapshot,
    ) -> Vec<String> {
        WIFI_PROFILE_CONTRACT_HELPERS
            .iter()
            .filter(|name| {
                !wifi_helper_profile_allows(profile, name)
                    && snapshot
                        .running_names
                        .iter()
                        .any(|running_name| running_name == **name)
            })
            .map(|name| (*name).to_string())
            .collect()
    }

    fn wifi_helper_contract_ok(profile: &str, snapshot: &WifiHelperProcessSnapshot) -> bool {
        let expected = wifi_helper_profile_expected_helpers(profile);
        wifi_helper_profile_is_known(profile)
            && wifi_helper_contract_missing(&expected, snapshot).is_empty()
            && wifi_helper_contract_unexpected(profile, snapshot).is_empty()
    }

    fn wifi_helper_contract_json(profile: &str, snapshot: &WifiHelperProcessSnapshot) -> String {
        let expected = wifi_helper_profile_expected_helpers(profile);
        let missing = wifi_helper_contract_missing(&expected, snapshot);
        let unexpected = wifi_helper_contract_unexpected(profile, snapshot);
        format!(
            concat!(
                "{{\"profile\":{},\"knownProfile\":{},\"expected\":{},",
                "\"running\":{},\"missing\":{},\"unexpectedRunning\":{},\"requiredOk\":{}}}"
            ),
            json_string(profile),
            bool_word(wifi_helper_profile_is_known(profile)),
            json_str_array(&expected),
            json_string_array(&snapshot.running_names),
            json_string_array(&missing),
            json_string_array(&unexpected),
            bool_word(
                wifi_helper_profile_is_known(profile)
                    && missing.is_empty()
                    && unexpected.is_empty()
            )
        )
    }

    fn wifi_module_details_json() -> String {
        let fields = [
            ("/sys/module/wlan/initstate", "initstate"),
            ("/sys/module/wlan/refcnt", "refcnt"),
            ("/sys/module/wlan/taint", "taint"),
            ("/sys/module/wlan/parameters/fwpath", "fwpath"),
            ("/sys/module/wlan/parameters/con_mode", "conMode"),
            ("/sys/module/wlan/uevent", "uevent"),
        ];
        let entries = fields
            .iter()
            .map(|(path, key)| {
                format!(
                    "{}:{}",
                    json_string(key),
                    json_optional_string(read_trimmed_file(path, 2048))
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        format!("{{{entries}}}")
    }

    fn wifi_kernel_log_excerpt() -> String {
        let toybox = Path::new("/system/bin/toybox");
        if !toybox.is_file() {
            return "<unavailable missing /system/bin/toybox>\n".to_string();
        }
        match Command::new(toybox).arg("dmesg").output() {
            Ok(output) => {
                let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
                if text.len() > 131072 {
                    text = text[text.len() - 131072..].to_string();
                    text.insert_str(0, "<truncated>\n");
                }
                if !text.ends_with('\n') {
                    text.push('\n');
                }
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    text.push_str(&format!(
                        "<dmesg-exit status={} stderr={}>\n",
                        output.status, stderr
                    ));
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

    fn wifi_interface_json(iface: &str) -> String {
        let root = format!("/sys/class/net/{iface}");
        let present = Path::new(&root).exists();
        let device_link = fs::read_link(format!("{root}/device"))
            .map(|path| path.display().to_string())
            .unwrap_or_default();
        format!(
            concat!(
                "{{\"name\":{},\"present\":{},\"operstate\":{},\"address\":{},",
                "\"ifindex\":{},\"type\":{},\"uevent\":{},\"deviceLink\":{}}}"
            ),
            json_string(iface),
            bool_word(present),
            json_optional_string(read_trimmed_file(&format!("{root}/operstate"), 128)),
            json_optional_string(read_trimmed_file(&format!("{root}/address"), 128).map(
                |address| {
                    if address.is_empty() {
                        address
                    } else {
                        "<redacted>".to_string()
                    }
                }
            )),
            json_optional_string(read_trimmed_file(&format!("{root}/ifindex"), 64)),
            json_optional_string(read_trimmed_file(&format!("{root}/type"), 64)),
            json_optional_string(
                read_trimmed_file(&format!("{root}/uevent"), 1024)
                    .map(|text| redact_wifi_sensitive_text(&text))
            ),
            json_string(&device_link)
        )
    }

    fn wifi_interface_is_admin_up(iface: &str) -> bool {
        read_trimmed_file(&format!("/sys/class/net/{iface}/flags"), 64)
            .and_then(|flags| {
                let value = flags
                    .strip_prefix("0x")
                    .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                    .or_else(|| flags.parse::<u32>().ok())?;
                Some((value & 0x1) != 0)
            })
            .unwrap_or(false)
    }

    fn wifi_command_text(bytes: &[u8], max_bytes: usize) -> String {
        let mut text = String::from_utf8_lossy(&bytes[..bytes.len().min(max_bytes)]).into_owned();
        if bytes.len() > max_bytes {
            text.push_str("\n<truncated>");
        }
        redact_wifi_sensitive_text(&text)
    }

    fn redact_wifi_sensitive_text(text: &str) -> String {
        let mut lines = Vec::new();
        for line in text.lines() {
            let trimmed = line.trim_start();
            let mut redacted_line = redact_wpa_network_command_line(line, trimmed);
            for key in [
                "address=",
                "bssid=",
                "ssid=",
                "psk=",
                "password=",
                "passphrase=",
                "uuid=",
                "p2p_device_address=",
                "ip_address=",
            ] {
                if redacted_line.is_some() {
                    break;
                }
                if let Some(value) = trimmed.strip_prefix(key) {
                    if !value.is_empty() {
                        let indent_len = line.len() - trimmed.len();
                        redacted_line = Some(format!("{}{}<redacted>", &line[..indent_len], key));
                        break;
                    }
                }
            }
            let line = redacted_line.unwrap_or_else(|| {
                redact_mac_like_tokens(&redact_inline_wifi_sensitive_tokens(line))
            });
            lines.push(line);
        }
        let mut output = lines.join("\n");
        if text.ends_with('\n') {
            output.push('\n');
        }
        output
    }

    fn redact_wpa_network_command_line(line: &str, trimmed: &str) -> Option<String> {
        let mut parts = trimmed.split_whitespace();
        if parts.next()? != "SET_NETWORK" {
            return None;
        }
        let network_id = parts.next()?;
        let field = parts.next()?;
        if !matches!(field, "ssid" | "psk" | "password" | "passphrase") {
            return None;
        }
        let indent_len = line.len() - trimmed.len();
        Some(format!(
            "{}SET_NETWORK {} {} <redacted>",
            &line[..indent_len],
            network_id,
            field
        ))
    }

    fn redact_inline_wifi_sensitive_tokens(line: &str) -> String {
        let mut output = line.to_string();
        for marker in ["ssid:", "SSID:"] {
            let mut cursor = 0_usize;
            while cursor < output.len() {
                let Some(relative_start) = output[cursor..].find(marker) else {
                    break;
                };
                let start = cursor + relative_start;
                let value_start = start + marker.len();
                let rest = &output[value_start..];
                let value_len = [
                    " bssid",
                    " BSSID",
                    " rssi",
                    " RSSI",
                    " channel",
                    " country_code",
                ]
                .iter()
                .filter_map(|terminator| rest.find(terminator))
                .min()
                .unwrap_or(rest.len());
                output.replace_range(value_start..value_start + value_len, "<redacted>");
                cursor = value_start + "<redacted>".len();
            }
        }
        output
    }

    fn redact_mac_like_tokens(text: &str) -> String {
        let mut output = String::new();
        let bytes = text.as_bytes();
        let mut index = 0_usize;
        while index < bytes.len() {
            if index + 17 <= bytes.len() && looks_like_mac(&bytes[index..index + 17]) {
                output.push_str("<redacted-mac>");
                index += 17;
            } else {
                output.push(bytes[index] as char);
                index += 1;
            }
        }
        output
    }

    fn looks_like_mac(bytes: &[u8]) -> bool {
        if bytes.len() != 17 {
            return false;
        }
        for (index, byte) in bytes.iter().enumerate() {
            if index % 3 == 2 {
                if *byte != b':' {
                    return false;
                }
            } else if !byte.is_ascii_hexdigit() {
                return false;
            }
        }
        true
    }

    fn wifi_interface_activation_probe_json(
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> String {
        let before = wifi_interface_json("wlan0");
        let before_flags = read_trimmed_file("/sys/class/net/wlan0/flags", 64);
        let before_admin_up = wifi_interface_is_admin_up("wlan0");
        let toybox = Path::new("/system/bin/toybox");
        if !Path::new("/sys/class/net/wlan0").exists() {
            return format!(
                "{{\"attempted\":false,\"reason\":\"missing-wlan0\",\"before\":{},\"beforeFlags\":{},\"beforeAdminUp\":{}}}",
                before,
                json_optional_string(before_flags),
                bool_word(before_admin_up)
            );
        }
        if !toybox.is_file() {
            return format!(
                "{{\"attempted\":false,\"reason\":\"missing-toybox\",\"before\":{},\"beforeFlags\":{},\"beforeAdminUp\":{}}}",
                before,
                json_optional_string(before_flags),
                bool_word(before_admin_up)
            );
        }

        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-ifconfig-up-start",
        );
        let output = Command::new(toybox)
            .args(["ifconfig", "wlan0", "up"])
            .output();
        thread::sleep(Duration::from_millis(300));
        let after = wifi_interface_json("wlan0");
        let after_flags = read_trimmed_file("/sys/class/net/wlan0/flags", 64);
        let after_admin_up = wifi_interface_is_admin_up("wlan0");
        let ifconfig_after = Command::new(toybox)
            .args(["ifconfig", "wlan0"])
            .output()
            .ok();
        let ifconfig_after_text = ifconfig_after
            .as_ref()
            .map(|output| wifi_command_text(&output.stdout, 4096))
            .unwrap_or_default();

        match output {
            Ok(output) => {
                let exit_code = output
                    .status
                    .code()
                    .map(|code| code.to_string())
                    .unwrap_or_else(|| "null".to_string());
                let success = output.status.success() && after_admin_up;
                write_payload_probe_stage(
                    probe_stage_path,
                    probe_stage_prefix,
                    if success {
                        "wifi-ifconfig-up-ok"
                    } else {
                        "wifi-ifconfig-up-failed"
                    },
                );
                format!(
                    concat!(
                        "{{\"attempted\":true,\"command\":\"/system/bin/toybox ifconfig wlan0 up\",",
                        "\"exitCode\":{},\"success\":{},\"stdout\":{},\"stderr\":{},",
                        "\"before\":{},\"beforeFlags\":{},\"beforeAdminUp\":{},",
                        "\"after\":{},\"afterFlags\":{},\"afterAdminUp\":{},\"ifconfigAfter\":{}}}"
                    ),
                    exit_code,
                    bool_word(success),
                    json_string(&wifi_command_text(&output.stdout, 4096)),
                    json_string(&wifi_command_text(&output.stderr, 4096)),
                    before,
                    json_optional_string(before_flags),
                    bool_word(before_admin_up),
                    after,
                    json_optional_string(after_flags),
                    bool_word(after_admin_up),
                    json_string(&ifconfig_after_text)
                )
            }
            Err(error) => {
                write_payload_probe_stage(
                    probe_stage_path,
                    probe_stage_prefix,
                    "wifi-ifconfig-up-spawn-failed",
                );
                format!(
                    concat!(
                        "{{\"attempted\":true,\"command\":\"/system/bin/toybox ifconfig wlan0 up\",",
                        "\"exitCode\":null,\"success\":false,\"spawnError\":{},",
                        "\"before\":{},\"beforeFlags\":{},\"beforeAdminUp\":{},",
                        "\"after\":{},\"afterFlags\":{},\"afterAdminUp\":{},\"ifconfigAfter\":{}}}"
                    ),
                    json_string(&error.to_string()),
                    before,
                    json_optional_string(before_flags),
                    bool_word(before_admin_up),
                    after,
                    json_optional_string(after_flags),
                    bool_word(after_admin_up),
                    json_string(&ifconfig_after_text)
                )
            }
        }
    }

    fn ensure_sunfish_wpa_supplicant_config() -> io::Result<()> {
        prepare_sunfish_wifi_android_runtime_dirs();
        let config_path = Path::new("/data/vendor/wifi/wpa/wpa_supplicant.conf");
        if !config_path.is_file() {
            fs::write(
                config_path,
                concat!(
                    "update_config=1\n",
                    "eapol_version=1\n",
                    "ap_scan=1\n",
                    "fast_reauth=1\n",
                    "pmf=1\n",
                    "p2p_add_cli_chan=1\n",
                    "oce=1\n",
                    "sae_pwe=2\n"
                ),
            )?;
        }
        fs::set_permissions(config_path, fs::Permissions::from_mode(0o660))?;
        let c_config_path = CString::new(config_path.as_os_str().as_bytes())?;
        let _ = unsafe { libc::chown(c_config_path.as_ptr(), 1010, 1010) };
        Ok(())
    }

    fn wpa_ctrl_response_text(bytes: &[u8]) -> String {
        String::from_utf8_lossy(bytes)
            .trim_end_matches('\0')
            .trim()
            .to_string()
    }

    struct WpaCtrlCommandResult {
        command_label: String,
        ok: bool,
        response: String,
        error: String,
    }

    struct WifiCredentials {
        ssid: Vec<u8>,
        psk_config_value: String,
        psk_kind: &'static str,
    }

    struct WifiCredentialLoad {
        attempted: bool,
        path_configured: bool,
        read_ok: bool,
        remove_ok: bool,
        error: String,
        credentials: Option<WifiCredentials>,
    }

    struct WifiAssociationRun {
        json: String,
        completed: bool,
        network_id: Option<u32>,
    }

    struct WifiRuntimeNetwork {
        child: Child,
        socket_path: PathBuf,
        busybox_path: PathBuf,
        network_id: u32,
    }

    struct WifiRuntimeNetworkStart {
        json: String,
        completed: bool,
        network: Option<WifiRuntimeNetwork>,
    }

    struct WifiRuntimeClockSet {
        json: String,
        ready: bool,
    }

    struct WifiChildLiveness {
        json: String,
        alive: bool,
    }

    struct TcpConnectProbe {
        json: String,
        connected: bool,
    }

    fn wpa_ctrl_command_label(command: &str) -> String {
        let redacted = redact_wifi_sensitive_text(command.trim());
        if redacted.is_empty() {
            return "<empty>".to_string();
        }
        if redacted.chars().count() <= 160 {
            return redacted;
        }
        let mut truncated = redacted.chars().take(160).collect::<String>();
        truncated.push_str("<truncated>");
        truncated
    }

    fn wpa_ctrl_client_suffix(command_label: &str) -> String {
        let suffix = command_label
            .chars()
            .filter(|ch| ch.is_ascii_alphanumeric())
            .take(48)
            .collect::<String>()
            .to_ascii_lowercase();
        if suffix.is_empty() {
            "cmd".to_string()
        } else {
            suffix
        }
    }

    fn wpa_ctrl_command_ok(command: &str, response: &str) -> bool {
        let command_word = command.split_whitespace().next().unwrap_or_default();
        match command_word {
            "PING" => response == "PONG",
            "SCAN" => response == "OK",
            "STATUS" => !response.is_empty(),
            "ADD_NETWORK" => response.parse::<u32>().is_ok(),
            _ => !response.starts_with("FAIL") && !response.is_empty(),
        }
    }

    fn wpa_ctrl_command(
        socket_path: &Path,
        command: &str,
        timeout: Duration,
    ) -> WpaCtrlCommandResult {
        let command_label = wpa_ctrl_command_label(command);
        let client_path = PathBuf::from(format!(
            "/data/vendor/wifi/wpa/sockets/shadow-wpa-{}-{}",
            process::id(),
            wpa_ctrl_client_suffix(&command_label)
        ));
        let _ = fs::remove_file(&client_path);
        let socket = match UnixDatagram::bind(&client_path) {
            Ok(socket) => socket,
            Err(error) => {
                return WpaCtrlCommandResult {
                    command_label,
                    ok: false,
                    response: String::new(),
                    error: format!("bind {client_path:?}: {error}"),
                }
            }
        };
        let _ = fs::set_permissions(&client_path, fs::Permissions::from_mode(0o770));
        if let Ok(c_client_path) = CString::new(client_path.as_os_str().as_bytes()) {
            let _ = unsafe { libc::chown(c_client_path.as_ptr(), 1010, 1010) };
        }
        let _ = socket.set_read_timeout(Some(timeout));
        let result = if let Err(error) = socket.connect(socket_path) {
            WpaCtrlCommandResult {
                command_label,
                ok: false,
                response: String::new(),
                error: format!("connect {socket_path:?}: {error}"),
            }
        } else if let Err(error) = socket.send(command.as_bytes()) {
            WpaCtrlCommandResult {
                command_label,
                ok: false,
                response: String::new(),
                error: format!("send: {error}"),
            }
        } else {
            let mut buf = vec![0_u8; 65536];
            match socket.recv(&mut buf) {
                Ok(size) => {
                    let response = wpa_ctrl_response_text(&buf[..size]);
                    WpaCtrlCommandResult {
                        command_label,
                        ok: wpa_ctrl_command_ok(command, &response),
                        response,
                        error: String::new(),
                    }
                }
                Err(error) => WpaCtrlCommandResult {
                    command_label,
                    ok: false,
                    response: String::new(),
                    error: format!("recv: {error}"),
                },
            }
        };
        let _ = fs::remove_file(&client_path);
        result
    }

    fn wpa_ctrl_result_json(result: &WpaCtrlCommandResult) -> String {
        if result.error.is_empty() {
            format!(
                "{{\"command\":{},\"ok\":{},\"response\":{}}}",
                json_string(&result.command_label),
                bool_word(result.ok),
                json_string(&wifi_command_text(result.response.as_bytes(), 8192))
            )
        } else {
            format!(
                "{{\"command\":{},\"ok\":false,\"error\":{}}}",
                json_string(&result.command_label),
                json_string(&result.error)
            )
        }
    }

    fn wpa_ctrl_command_result_json(
        socket_path: &Path,
        command: &str,
        timeout: Duration,
    ) -> String {
        wpa_ctrl_result_json(&wpa_ctrl_command(socket_path, command, timeout))
    }

    fn hex_encode(bytes: &[u8]) -> String {
        let mut output = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            let _ = write!(&mut output, "{byte:02x}");
        }
        output
    }

    fn sha256_hex_digest(bytes: &[u8]) -> String {
        hex_encode(&sha256_bytes(bytes))
    }

    fn parse_hex_bytes(value: &str) -> Option<Vec<u8>> {
        let trimmed = value.trim();
        if trimmed.is_empty() || trimmed.len() % 2 != 0 {
            return None;
        }
        let mut output = Vec::with_capacity(trimmed.len() / 2);
        let bytes = trimmed.as_bytes();
        let mut index = 0_usize;
        while index < bytes.len() {
            let pair = std::str::from_utf8(&bytes[index..index + 2]).ok()?;
            output.push(u8::from_str_radix(pair, 16).ok()?);
            index += 2;
        }
        Some(output)
    }

    fn is_hex_psk(value: &str) -> bool {
        value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
    }

    fn wpa_config_quote(value: &str) -> String {
        let mut output = String::with_capacity(value.len() + 2);
        output.push('"');
        for ch in value.chars() {
            if ch == '"' || ch == '\\' {
                output.push('\\');
            }
            output.push(ch);
        }
        output.push('"');
        output
    }

    fn parse_wifi_credentials_text(text: &str) -> Result<WifiCredentials, String> {
        let mut ssid_text = None;
        let mut ssid_hex = None;
        let mut psk_text = None;

        for raw_line in text.lines() {
            let line = raw_line.trim_start();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let value = value.trim_end_matches('\r').to_string();
            match key.trim().to_ascii_lowercase().as_str() {
                "ssid" => ssid_text = Some(value),
                "ssid_hex" => ssid_hex = Some(value),
                "psk" | "password" | "passphrase" => psk_text = Some(value),
                _ => {}
            }
        }

        let ssid = if let Some(value) = ssid_hex {
            parse_hex_bytes(&value).ok_or_else(|| "invalid-ssid-hex".to_string())?
        } else {
            ssid_text
                .ok_or_else(|| "missing-ssid".to_string())?
                .into_bytes()
        };
        if ssid.is_empty() || ssid.len() > 32 {
            return Err("invalid-ssid-length".to_string());
        }

        let psk = psk_text.ok_or_else(|| "missing-psk".to_string())?;
        let (psk_config_value, psk_kind) = if is_hex_psk(&psk) {
            (psk, "raw-psk")
        } else {
            let psk_len = psk.as_bytes().len();
            if !(8..=63).contains(&psk_len) {
                return Err("invalid-passphrase-length".to_string());
            }
            (wpa_config_quote(&psk), "passphrase")
        };

        Ok(WifiCredentials {
            ssid,
            psk_config_value,
            psk_kind,
        })
    }

    fn read_wifi_credentials_once(path: &str) -> WifiCredentialLoad {
        let path = path.trim();
        if path.is_empty() {
            return WifiCredentialLoad {
                attempted: true,
                path_configured: false,
                read_ok: false,
                remove_ok: false,
                error: "missing-credentials-path".to_string(),
                credentials: None,
            };
        }

        let read_result = fs::read_to_string(path);
        let remove_ok = fs::remove_file(path).is_ok();
        match read_result {
            Ok(text) => match parse_wifi_credentials_text(&text) {
                Ok(credentials) => WifiCredentialLoad {
                    attempted: true,
                    path_configured: true,
                    read_ok: true,
                    remove_ok,
                    error: String::new(),
                    credentials: Some(credentials),
                },
                Err(error) => WifiCredentialLoad {
                    attempted: true,
                    path_configured: true,
                    read_ok: true,
                    remove_ok,
                    error,
                    credentials: None,
                },
            },
            Err(error) => WifiCredentialLoad {
                attempted: true,
                path_configured: true,
                read_ok: false,
                remove_ok,
                error: format!("read-failed:{error}"),
                credentials: None,
            },
        }
    }

    fn wifi_credential_load_json(load: &WifiCredentialLoad) -> String {
        let (ssid_len, ssid_sha256, psk_kind) = match &load.credentials {
            Some(credentials) => (
                credentials.ssid.len().to_string(),
                format!("sha256:{}", sha256_hex_digest(&credentials.ssid)),
                credentials.psk_kind.to_string(),
            ),
            None => ("null".to_string(), String::new(), String::new()),
        };
        format!(
            concat!(
                "{{\"attempted\":{},\"pathConfigured\":{},\"readOk\":{},",
                "\"removeOk\":{},\"error\":{},\"ssidLen\":{},",
                "\"ssidSha256\":{},\"pskKind\":{}}}"
            ),
            bool_word(load.attempted),
            bool_word(load.path_configured),
            bool_word(load.read_ok),
            bool_word(load.remove_ok),
            json_string(&load.error),
            ssid_len,
            json_string(&ssid_sha256),
            json_string(&psk_kind)
        )
    }

    fn wpa_status_value(status: &str, key: &str) -> Option<String> {
        let prefix = format!("{key}=");
        status
            .lines()
            .find_map(|line| line.strip_prefix(&prefix).map(|value| value.to_string()))
    }

    fn wifi_association_status_poll_json(attempt: u32, result: &WpaCtrlCommandResult) -> String {
        let state = wpa_status_value(&result.response, "wpa_state").unwrap_or_default();
        format!(
            "{{\"attempt\":{},\"state\":{},\"result\":{}}}",
            attempt,
            json_string(&state),
            wpa_ctrl_result_json(result)
        )
    }

    fn wifi_association_cleanup_json(socket_path: &Path, network_id: u32) -> String {
        let mut cleanup = Vec::new();
        let cleanup_disconnect =
            wpa_ctrl_command(socket_path, "DISCONNECT", Duration::from_secs(2));
        cleanup.push(format!(
            "{{\"step\":\"disconnect\",\"result\":{}}}",
            wpa_ctrl_result_json(&cleanup_disconnect)
        ));
        let cleanup_remove = wpa_ctrl_command(
            socket_path,
            &format!("REMOVE_NETWORK {network_id}"),
            Duration::from_secs(2),
        );
        cleanup.push(format!(
            "{{\"step\":\"remove-network\",\"result\":{}}}",
            wpa_ctrl_result_json(&cleanup_remove)
        ));
        let cleanup_status = wpa_ctrl_command(socket_path, "STATUS", Duration::from_secs(2));
        cleanup.push(format!(
            "{{\"step\":\"status\",\"result\":{}}}",
            wpa_ctrl_result_json(&cleanup_status)
        ));
        format!("[{}]", cleanup.join(","))
    }

    fn run_wifi_association(
        socket_path: &Path,
        credential_load: &WifiCredentialLoad,
        cleanup_after: bool,
    ) -> WifiAssociationRun {
        let credentials_json = wifi_credential_load_json(credential_load);
        let Some(credentials) = credential_load.credentials.as_ref() else {
            return WifiAssociationRun {
                json: format!(
                    "{{\"attempted\":false,\"reason\":\"credentials-unavailable\",\"credentials\":{credentials_json}}}"
                ),
                completed: false,
                network_id: None,
            };
        };
        if !credential_load.remove_ok {
            return WifiAssociationRun {
                json: format!(
                    "{{\"attempted\":false,\"reason\":\"credentials-not-removed\",\"credentials\":{credentials_json}}}"
                ),
                completed: false,
                network_id: None,
            };
        }

        let mut steps = Vec::new();
        let disconnect = wpa_ctrl_command(socket_path, "DISCONNECT", Duration::from_secs(2));
        steps.push(format!(
            "{{\"step\":\"disconnect\",\"result\":{}}}",
            wpa_ctrl_result_json(&disconnect)
        ));
        let remove_all =
            wpa_ctrl_command(socket_path, "REMOVE_NETWORK all", Duration::from_secs(2));
        steps.push(format!(
            "{{\"step\":\"remove-all\",\"result\":{}}}",
            wpa_ctrl_result_json(&remove_all)
        ));
        let add_network = wpa_ctrl_command(socket_path, "ADD_NETWORK", Duration::from_secs(2));
        steps.push(format!(
            "{{\"step\":\"add-network\",\"result\":{}}}",
            wpa_ctrl_result_json(&add_network)
        ));
        let network_id = add_network.response.trim().parse::<u32>().ok();
        let Some(network_id) = network_id else {
            return WifiAssociationRun {
                json: format!(
                    concat!(
                        "{{\"attempted\":true,\"completed\":false,\"reason\":\"add-network-failed\",",
                        "\"credentials\":{},\"steps\":[{}],\"polls\":[],\"cleanup\":[]}}"
                    ),
                    credentials_json,
                    steps.join(",")
                ),
                completed: false,
                network_id: None,
            };
        };

        let set_commands = [
            (
                "set-ssid",
                format!(
                    "SET_NETWORK {network_id} ssid {}",
                    hex_encode(&credentials.ssid)
                ),
            ),
            (
                "set-key-mgmt",
                format!("SET_NETWORK {network_id} key_mgmt WPA-PSK"),
            ),
            (
                "set-mem-only-psk",
                format!("SET_NETWORK {network_id} mem_only_psk 1"),
            ),
            (
                "set-psk",
                format!(
                    "SET_NETWORK {network_id} psk {}",
                    credentials.psk_config_value
                ),
            ),
            ("select-network", format!("SELECT_NETWORK {network_id}")),
        ];
        let mut setup_ok = true;
        for (step, command) in set_commands {
            let result = wpa_ctrl_command(socket_path, &command, Duration::from_secs(2));
            setup_ok = setup_ok && result.ok;
            steps.push(format!(
                "{{\"step\":{},\"result\":{}}}",
                json_string(step),
                wpa_ctrl_result_json(&result)
            ));
            if !setup_ok {
                break;
            }
        }

        let mut polls = Vec::new();
        let mut completed = false;
        let mut final_state = String::new();
        if setup_ok {
            for attempt in 0..60_u32 {
                if attempt > 0 {
                    thread::sleep(Duration::from_millis(500));
                }
                let status = wpa_ctrl_command(socket_path, "STATUS", Duration::from_secs(2));
                final_state = wpa_status_value(&status.response, "wpa_state").unwrap_or_default();
                completed = status.ok && final_state == "COMPLETED";
                polls.push(wifi_association_status_poll_json(attempt, &status));
                if completed {
                    break;
                }
            }
        }

        let cleanup = if cleanup_after {
            wifi_association_cleanup_json(socket_path, network_id)
        } else {
            "[]".to_string()
        };

        WifiAssociationRun {
            json: format!(
                concat!(
                    "{{\"attempted\":true,\"completed\":{},\"reason\":{},",
                    "\"networkId\":{},\"finalState\":{},\"credentials\":{},",
                    "\"steps\":[{}],\"polls\":[{}],\"cleanup\":{}}}"
                ),
                bool_word(completed),
                json_string(if completed {
                    ""
                } else if setup_ok {
                    "association-timeout"
                } else {
                    "network-setup-failed"
                }),
                network_id,
                json_string(&final_state),
                credentials_json,
                steps.join(","),
                polls.join(","),
                cleanup
            ),
            completed,
            network_id: Some(network_id),
        }
    }

    fn wifi_association_probe_json(
        socket_path: &Path,
        credential_load: &WifiCredentialLoad,
    ) -> String {
        run_wifi_association(socket_path, credential_load, true).json
    }

    fn write_udhcpc_script(script_path: &Path, busybox_path: &str) -> io::Result<()> {
        let script = format!(
            concat!(
                "#!{} sh\n",
                "set -eu\n",
                "bb={}\n",
                "case \"${{1:-}}\" in\n",
                "  deconfig)\n",
                "    \"$bb\" ifconfig \"${{interface:-wlan0}}\" 0.0.0.0 || true\n",
                "    ;;\n",
                "  bound|renew)\n",
                "    \"$bb\" ifconfig \"$interface\" \"$ip\" netmask \"$subnet\"\n",
                "    \"$bb\" route del default dev \"$interface\" 2>/dev/null || true\n",
                "    for r in ${{router:-}}; do \"$bb\" route add default gw \"$r\" dev \"$interface\"; break; done\n",
                "    \"$bb\" mkdir -p /etc\n",
                "    : > /etc/resolv.conf\n",
                "    for d in ${{dns:-}}; do echo \"nameserver $d\" >> /etc/resolv.conf; done\n",
                "    ;;\n",
                "esac\n"
            ),
            busybox_path, busybox_path
        );
        fs::write(script_path, script)?;
        fs::set_permissions(script_path, fs::Permissions::from_mode(0o755))
    }

    fn command_output_json(command: &str, output: io::Result<std::process::Output>) -> String {
        match output {
            Ok(output) => format!(
                "{{\"command\":{},\"exitCode\":{},\"success\":{},\"stdout\":{},\"stderr\":{}}}",
                json_string(command),
                output
                    .status
                    .code()
                    .map(|code| code.to_string())
                    .unwrap_or_else(|| "null".to_string()),
                bool_word(output.status.success()),
                json_string(&wifi_command_text(&output.stdout, 8192)),
                json_string(&wifi_command_text(&output.stderr, 8192))
            ),
            Err(error) => format!(
                "{{\"command\":{},\"exitCode\":null,\"success\":false,\"spawnError\":{}}}",
                json_string(command),
                json_string(&error.to_string())
            ),
        }
    }

    fn command_success(output: &io::Result<std::process::Output>) -> bool {
        output
            .as_ref()
            .map(|output| output.status.success())
            .unwrap_or(false)
    }

    fn wifi_ip_state_cleanup_json(busybox_path: &Path) -> String {
        let busybox_label = busybox_path.display().to_string();
        let route_del = Command::new(busybox_path)
            .args(["route", "del", "default", "dev", "wlan0"])
            .output();
        let ifconfig_clear = Command::new(busybox_path)
            .args(["ifconfig", "wlan0", "0.0.0.0"])
            .output();
        let resolv_remove = Command::new(busybox_path)
            .args(["rm", "-f", "/etc/resolv.conf"])
            .output();
        format!(
            concat!(
                "[{{\"step\":\"route-del-default\",\"result\":{}}},",
                "{{\"step\":\"ifconfig-clear\",\"result\":{}}},",
                "{{\"step\":\"resolv-conf-remove\",\"result\":{}}}]"
            ),
            command_output_json(
                &format!("{busybox_label} route del default dev wlan0"),
                route_del
            ),
            command_output_json(
                &format!("{busybox_label} ifconfig wlan0 0.0.0.0"),
                ifconfig_clear
            ),
            command_output_json(
                &format!("{busybox_label} rm -f /etc/resolv.conf"),
                resolv_remove
            )
        )
    }

    fn proc_net_route_has_default_wlan0(text: &str) -> bool {
        text.lines().skip(1).any(|line| {
            let fields = line.split_whitespace().collect::<Vec<_>>();
            fields.len() > 2 && fields[0] == "wlan0" && fields[1] == "00000000"
        })
    }

    fn resolv_conf_has_nameserver(text: &str) -> bool {
        text.lines().any(|line| {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                return false;
            }
            let fields = trimmed.split_whitespace().collect::<Vec<_>>();
            fields.len() >= 2 && fields[0] == "nameserver" && !fields[1].is_empty()
        })
    }

    fn wlan0_has_ipv4_address(ifconfig_text: &str) -> bool {
        ifconfig_text.contains("inet addr:") || ifconfig_text.contains("inet ")
    }

    fn tcp_connect_probe(host: &str, port: u16) -> TcpConnectProbe {
        let target = format!("{host}:{port}");
        let mut resolved = Vec::new();
        let mut connected = false;
        let mut error = String::new();
        match target.to_socket_addrs() {
            Ok(addrs) => {
                for addr in addrs.take(8) {
                    resolved.push(addr.to_string());
                    match TcpStream::connect_timeout(&addr, Duration::from_secs(4)) {
                        Ok(_) => {
                            connected = true;
                            break;
                        }
                        Err(connect_error) => {
                            if error.is_empty() {
                                error = connect_error.to_string();
                            }
                        }
                    }
                }
            }
            Err(resolve_error) => error = resolve_error.to_string(),
        }
        TcpConnectProbe {
            json: format!(
                "{{\"target\":{},\"resolved\":{},\"connected\":{},\"error\":{}}}",
                json_string(&target),
                json_string_array(&resolved),
                bool_word(connected),
                json_string(&error)
            ),
            connected,
        }
    }

    fn wifi_ip_probe_json(
        config: &Config,
        socket_path: &Path,
        credential_load: &WifiCredentialLoad,
    ) -> String {
        let association = run_wifi_association(socket_path, credential_load, false);
        let Some(network_id) = association.network_id else {
            return format!(
                "{{\"attempted\":true,\"completed\":false,\"reason\":\"association-setup-failed\",\"association\":{},\"dhcp\":null,\"cleanup\":[]}}",
                association.json
            );
        };
        if !association.completed {
            let cleanup = wifi_association_cleanup_json(socket_path, network_id);
            return format!(
                "{{\"attempted\":true,\"completed\":false,\"reason\":\"association-failed\",\"association\":{},\"dhcp\":null,\"cleanup\":{}}}",
                association.json, cleanup
            );
        }

        let busybox_path = Path::new(&config.wifi_dhcp_client_path);
        if !busybox_path.is_file() {
            let cleanup = wifi_association_cleanup_json(socket_path, network_id);
            return format!(
                "{{\"attempted\":true,\"completed\":false,\"reason\":\"missing-dhcp-client\",\"association\":{},\"dhcp\":null,\"cleanup\":{}}}",
                association.json, cleanup
            );
        }

        let script_path = Path::new("/orange-gpu/udhcpc-script");
        let script_result = write_udhcpc_script(script_path, &config.wifi_dhcp_client_path);
        if let Err(error) = script_result {
            let cleanup = wifi_association_cleanup_json(socket_path, network_id);
            return format!(
                "{{\"attempted\":true,\"completed\":false,\"reason\":\"dhcp-script-failed\",\"association\":{},\"dhcpScriptError\":{},\"dhcp\":null,\"cleanup\":{}}}",
                association.json,
                json_string(&error.to_string()),
                cleanup
            );
        }

        let pre_dhcp_cleanup = wifi_ip_state_cleanup_json(busybox_path);
        let dhcp_output = Command::new(busybox_path)
            .args([
                "udhcpc",
                "-i",
                "wlan0",
                "-n",
                "-q",
                "-t",
                "5",
                "-T",
                "3",
                "-s",
                "/orange-gpu/udhcpc-script",
            ])
            .output();
        let dhcp_success = command_success(&dhcp_output);
        let busybox_label = busybox_path.display().to_string();
        let dhcp_json = command_output_json(
            &format!(
                "{busybox_label} udhcpc -i wlan0 -n -q -t 5 -T 3 -s /orange-gpu/udhcpc-script"
            ),
            dhcp_output,
        );
        let ifconfig_output = Command::new(busybox_path)
            .args(["ifconfig", "wlan0"])
            .output();
        let ifconfig_text = ifconfig_output
            .as_ref()
            .ok()
            .map(|output| wifi_command_text(&output.stdout, 8192))
            .unwrap_or_default();
        let ifconfig_json =
            command_output_json(&format!("{busybox_label} ifconfig wlan0"), ifconfig_output);
        let route_text = read_file_excerpt("/proc/net/route", 8192);
        let resolv_conf = read_file_excerpt("/etc/resolv.conf", 4096);
        let default_route = proc_net_route_has_default_wlan0(&route_text);
        let ipv4_address = wlan0_has_ipv4_address(&ifconfig_text);
        let relay_connect = tcp_connect_probe("relay.damus.io", 443);
        let fallback_connect = tcp_connect_probe("1.1.1.1", 53);
        let connected = relay_connect.connected || fallback_connect.connected;
        let completed = dhcp_success && ipv4_address && default_route && connected;
        let post_dhcp_cleanup = wifi_ip_state_cleanup_json(busybox_path);
        let cleanup = wifi_association_cleanup_json(socket_path, network_id);

        format!(
            concat!(
                "{{\"attempted\":true,\"completed\":{},\"reason\":{},",
                "\"association\":{},\"preDhcpCleanup\":{},\"dhcp\":{},\"dhcpSuccess\":{},",
                "\"ifconfig\":{},\"ipv4AddressPresent\":{},\"defaultRoutePresent\":{},",
                "\"procNetRoute\":{},\"resolvConf\":{},",
                "\"tcpConnect\":[{},{}],\"postDhcpCleanup\":{},\"cleanup\":{}}}"
            ),
            bool_word(completed),
            json_string(if completed { "" } else { "ip-proof-failed" }),
            association.json,
            pre_dhcp_cleanup,
            dhcp_json,
            bool_word(dhcp_success),
            ifconfig_json,
            bool_word(ipv4_address),
            bool_word(default_route),
            json_string(&route_text),
            json_string(&resolv_conf),
            relay_connect.json,
            fallback_connect.json,
            post_dhcp_cleanup,
            cleanup
        )
    }

    fn wifi_runtime_clock_json(config: &Config) -> WifiRuntimeClockSet {
        let secs = config.wifi_runtime_clock_unix_secs;
        if secs == 0 {
            return WifiRuntimeClockSet {
                json: "{\"attempted\":false,\"reason\":\"disabled\"}".to_string(),
                ready: true,
            };
        }
        let timespec = libc::timespec {
            tv_sec: secs as libc::time_t,
            tv_nsec: 0,
        };
        let rc = unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &timespec) };
        if rc == 0 {
            WifiRuntimeClockSet {
                json: format!("{{\"attempted\":true,\"ok\":true,\"unixSecs\":{secs}}}"),
                ready: true,
            }
        } else {
            WifiRuntimeClockSet {
                json: format!(
                    "{{\"attempted\":true,\"ok\":false,\"unixSecs\":{},\"error\":{}}}",
                    secs,
                    json_string(&io::Error::last_os_error().to_string())
                ),
                ready: false,
            }
        }
    }

    fn start_wifi_runtime_network(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> WifiRuntimeNetworkStart {
        let clock = wifi_runtime_clock_json(config);
        let clock_json = clock.json;
        if !clock.ready {
            return WifiRuntimeNetworkStart {
                json: format!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"clock-set-failed\",\"clock\":{clock_json}}}"
                ),
                completed: false,
                network: None,
            };
        }
        let binary_path = Path::new("/vendor/bin/hw/wpa_supplicant");
        let socket_path = Path::new("/data/vendor/wifi/wpa/sockets/wlan0");
        if !Path::new("/sys/class/net/wlan0").exists() {
            return WifiRuntimeNetworkStart {
                json: format!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"missing-wlan0\",\"clock\":{clock_json}}}"
                ),
                completed: false,
                network: None,
            };
        }
        if !binary_path.is_file() {
            return WifiRuntimeNetworkStart {
                json: format!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"missing-binary\",\"clock\":{},\"binary\":{}}}",
                    clock_json,
                    wifi_boot_path_status_json("/vendor/bin/hw/wpa_supplicant")
                ),
                completed: false,
                network: None,
            };
        }
        if let Err(error) = ensure_sunfish_wpa_supplicant_config() {
            return WifiRuntimeNetworkStart {
                json: format!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"config-setup-failed\",\"clock\":{},\"error\":{}}}",
                    clock_json,
                    json_string(&error.to_string())
                ),
                completed: false,
                network: None,
            };
        }

        thread::sleep(Duration::from_secs(2));
        let _ = fs::remove_file(socket_path);
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-runtime-wpa-supplicant-start",
        );
        let mut child = spawn_sunfish_wifi_android_helper(
            "wpa_supplicant",
            &[
                "-iwlan0",
                "-Dnl80211",
                "-c/data/vendor/wifi/wpa/wpa_supplicant.conf",
                "-O/data/vendor/wifi/wpa/sockets",
                "-puse_p2p_group_interface=1",
                "-dd",
            ],
            probe_stage_path,
            probe_stage_prefix,
        );
        let Some(mut child) = child.take() else {
            return WifiRuntimeNetworkStart {
                json: format!(
                    "{{\"attempted\":true,\"completed\":false,\"started\":false,\"reason\":\"spawn-failed\",\"clock\":{clock_json}}}"
                ),
                completed: false,
                network: None,
            };
        };

        let start = Instant::now();
        let mut early_exit_status = String::new();
        while start.elapsed() < Duration::from_secs(12) {
            if socket_path.exists() {
                break;
            }
            match child.try_wait() {
                Ok(Some(status)) => {
                    early_exit_status = status.to_string();
                    break;
                }
                Ok(None) => {}
                Err(error) => {
                    early_exit_status = format!("status-error: {error}");
                    break;
                }
            }
            thread::sleep(Duration::from_millis(250));
        }

        let socket_ready = socket_path.exists();
        if !socket_ready {
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                "wifi-runtime-wpa-supplicant-socket-missing",
            );
            let child_pid = child.id();
            let cleanup = stop_wifi_child_json(&mut child);
            return WifiRuntimeNetworkStart {
                json: format!(
                    concat!(
                        "{{\"attempted\":true,\"completed\":false,\"reason\":\"socket-missing\",",
                        "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":false,",
                        "\"earlyExit\":{},\"socket\":{},\"cleanup\":{},\"logExcerpt\":{}}}"
                    ),
                    clock_json,
                    child_pid,
                    json_string(&early_exit_status),
                    wifi_boot_path_status_json("/data/vendor/wifi/wpa/sockets/wlan0"),
                    cleanup,
                    json_string(&redact_wifi_sensitive_text(&read_file_excerpt(
                        "/orange-gpu/wifi-helper-wpa_supplicant.log",
                        8192
                    )))
                ),
                completed: false,
                network: None,
            };
        }

        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-runtime-wpa-ping",
        );
        let ping = wpa_ctrl_command_result_json(socket_path, "PING", Duration::from_secs(2));
        let status_before_scan =
            wpa_ctrl_command_result_json(socket_path, "STATUS", Duration::from_secs(2));
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-runtime-wpa-scan",
        );
        let scan = wpa_ctrl_command_result_json(socket_path, "SCAN", Duration::from_secs(2));
        thread::sleep(Duration::from_secs(6));
        let scan_results = wpa_scan_results_json(socket_path, Duration::from_secs(2));
        let status_after_scan =
            wpa_ctrl_command_result_json(socket_path, "STATUS", Duration::from_secs(2));
        let credentials = read_wifi_credentials_once(&config.wifi_credentials_path);
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-runtime-association-start",
        );
        let association = run_wifi_association(socket_path, &credentials, false);
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-runtime-association-done",
        );
        let Some(network_id) = association.network_id else {
            let cleanup = stop_wifi_child_json(&mut child);
            return WifiRuntimeNetworkStart {
                json: format!(
                    concat!(
                        "{{\"attempted\":true,\"completed\":false,\"reason\":\"association-setup-failed\",",
                        "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":true,",
                        "\"earlyExit\":{},\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
                        "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},\"cleanup\":{}}}"
                    ),
                    clock_json,
                    child.id(),
                    json_string(&early_exit_status),
                    ping,
                    status_before_scan,
                    scan,
                    scan_results,
                    status_after_scan,
                    association.json,
                    cleanup
                ),
                completed: false,
                network: None,
            };
        };
        if !association.completed {
            let association_cleanup = wifi_association_cleanup_json(socket_path, network_id);
            let child_cleanup = stop_wifi_child_json(&mut child);
            return WifiRuntimeNetworkStart {
                json: format!(
                    concat!(
                        "{{\"attempted\":true,\"completed\":false,\"reason\":\"association-failed\",",
                        "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":true,",
                        "\"earlyExit\":{},\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
                        "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},",
                        "\"associationCleanup\":{},\"cleanup\":{}}}"
                    ),
                    clock_json,
                    child.id(),
                    json_string(&early_exit_status),
                    ping,
                    status_before_scan,
                    scan,
                    scan_results,
                    status_after_scan,
                    association.json,
                    association_cleanup,
                    child_cleanup
                ),
                completed: false,
                network: None,
            };
        }

        let busybox_path = Path::new(&config.wifi_dhcp_client_path);
        if !busybox_path.is_file() {
            let association_cleanup = wifi_association_cleanup_json(socket_path, network_id);
            let child_cleanup = stop_wifi_child_json(&mut child);
            return WifiRuntimeNetworkStart {
                json: format!(
                    concat!(
                        "{{\"attempted\":true,\"completed\":false,\"reason\":\"missing-dhcp-client\",",
                        "\"clock\":{},\"association\":{},\"associationCleanup\":{},\"cleanup\":{}}}"
                    ),
                    clock_json, association.json, association_cleanup, child_cleanup
                ),
                completed: false,
                network: None,
            };
        }

        let script_path = Path::new("/orange-gpu/udhcpc-script");
        if let Err(error) = write_udhcpc_script(script_path, &config.wifi_dhcp_client_path) {
            let association_cleanup = wifi_association_cleanup_json(socket_path, network_id);
            let child_cleanup = stop_wifi_child_json(&mut child);
            return WifiRuntimeNetworkStart {
                json: format!(
                    concat!(
                        "{{\"attempted\":true,\"completed\":false,\"reason\":\"dhcp-script-failed\",",
                        "\"clock\":{},\"association\":{},\"dhcpScriptError\":{},",
                        "\"associationCleanup\":{},\"cleanup\":{}}}"
                    ),
                    clock_json,
                    association.json,
                    json_string(&error.to_string()),
                    association_cleanup,
                    child_cleanup
                ),
                completed: false,
                network: None,
            };
        }

        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-runtime-dhcp-start",
        );
        let pre_dhcp_cleanup = wifi_ip_state_cleanup_json(busybox_path);
        let dhcp_output = Command::new(busybox_path)
            .args([
                "udhcpc",
                "-i",
                "wlan0",
                "-n",
                "-q",
                "-t",
                "5",
                "-T",
                "3",
                "-s",
                "/orange-gpu/udhcpc-script",
            ])
            .output();
        let dhcp_success = command_success(&dhcp_output);
        let busybox_label = busybox_path.display().to_string();
        let dhcp_json = command_output_json(
            &format!(
                "{busybox_label} udhcpc -i wlan0 -n -q -t 5 -T 3 -s /orange-gpu/udhcpc-script"
            ),
            dhcp_output,
        );
        let ifconfig_output = Command::new(busybox_path)
            .args(["ifconfig", "wlan0"])
            .output();
        let ifconfig_text = ifconfig_output
            .as_ref()
            .ok()
            .map(|output| wifi_command_text(&output.stdout, 8192))
            .unwrap_or_default();
        let ifconfig_json =
            command_output_json(&format!("{busybox_label} ifconfig wlan0"), ifconfig_output);
        let route_text = read_file_excerpt("/proc/net/route", 8192);
        let resolv_conf = read_file_excerpt("/etc/resolv.conf", 4096);
        let default_route = proc_net_route_has_default_wlan0(&route_text);
        let ipv4_address = wlan0_has_ipv4_address(&ifconfig_text);
        let dns_ready = resolv_conf_has_nameserver(&resolv_conf);
        let relay_connect = tcp_connect_probe("relay.damus.io", 443);
        let fallback_connect = tcp_connect_probe("1.1.1.1", 53);
        let supplicant_liveness = wifi_child_liveness_json(&mut child);
        let connected = relay_connect.connected;
        let completed = dhcp_success
            && ipv4_address
            && default_route
            && dns_ready
            && connected
            && supplicant_liveness.alive;
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-runtime-dhcp-done",
        );

        if !completed {
            let post_dhcp_cleanup = wifi_ip_state_cleanup_json(busybox_path);
            let association_cleanup = wifi_association_cleanup_json(socket_path, network_id);
            let child_cleanup = stop_wifi_child_json(&mut child);
            return WifiRuntimeNetworkStart {
                json: format!(
                    concat!(
                        "{{\"attempted\":true,\"completed\":false,\"reason\":\"runtime-network-failed\",",
                        "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":true,",
                        "\"earlyExit\":{},\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
                        "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},",
                        "\"preDhcpCleanup\":{},\"dhcp\":{},\"dhcpSuccess\":{},\"ifconfig\":{},",
                        "\"ipv4AddressPresent\":{},\"defaultRoutePresent\":{},\"dnsReady\":{},",
                        "\"procNetRoute\":{},\"resolvConf\":{},\"tcpConnect\":[{},{}],",
                        "\"supplicant\":{},\"postDhcpCleanup\":{},\"associationCleanup\":{},",
                        "\"cleanup\":{}}}"
                    ),
                    clock_json,
                    child.id(),
                    json_string(&early_exit_status),
                    ping,
                    status_before_scan,
                    scan,
                    scan_results,
                    status_after_scan,
                    association.json,
                    pre_dhcp_cleanup,
                    dhcp_json,
                    bool_word(dhcp_success),
                    ifconfig_json,
                    bool_word(ipv4_address),
                    bool_word(default_route),
                    bool_word(dns_ready),
                    json_string(&route_text),
                    json_string(&resolv_conf),
                    relay_connect.json,
                    fallback_connect.json,
                    supplicant_liveness.json,
                    post_dhcp_cleanup,
                    association_cleanup,
                    child_cleanup
                ),
                completed: false,
                network: None,
            };
        }

        let child_pid = child.id();
        WifiRuntimeNetworkStart {
            json: format!(
                concat!(
                    "{{\"attempted\":true,\"completed\":true,\"reason\":\"\",",
                    "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":true,",
                    "\"earlyExit\":{},\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
                    "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},",
                    "\"preDhcpCleanup\":{},\"dhcp\":{},\"dhcpSuccess\":true,\"ifconfig\":{},",
                    "\"ipv4AddressPresent\":true,\"defaultRoutePresent\":true,\"dnsReady\":true,",
                    "\"procNetRoute\":{},\"resolvConf\":{},\"tcpConnect\":[{},{}],",
                    "\"supplicant\":{},\"cleanup\":[]}}"
                ),
                clock_json,
                child_pid,
                json_string(&early_exit_status),
                ping,
                status_before_scan,
                scan,
                scan_results,
                status_after_scan,
                association.json,
                pre_dhcp_cleanup,
                dhcp_json,
                ifconfig_json,
                json_string(&route_text),
                json_string(&resolv_conf),
                relay_connect.json,
                fallback_connect.json,
                supplicant_liveness.json
            ),
            completed: true,
            network: Some(WifiRuntimeNetwork {
                child,
                socket_path: socket_path.to_path_buf(),
                busybox_path: busybox_path.to_path_buf(),
                network_id,
            }),
        }
    }

    fn stop_wifi_runtime_network_json(network: &mut WifiRuntimeNetwork, reason: &str) -> String {
        let ip_cleanup = wifi_ip_state_cleanup_json(&network.busybox_path);
        let association_cleanup =
            wifi_association_cleanup_json(&network.socket_path, network.network_id);
        let child_cleanup = stop_wifi_child_json(&mut network.child);
        format!(
            "{{\"attempted\":true,\"reason\":{},\"ipCleanup\":{},\"associationCleanup\":{},\"childCleanup\":{}}}",
            json_string(reason),
            ip_cleanup,
            association_cleanup,
            child_cleanup
        )
    }

    fn stop_wifi_runtime_network(
        network: &mut Option<WifiRuntimeNetwork>,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
        reason: &str,
    ) {
        let Some(mut network) = network.take() else {
            return;
        };
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-runtime-network-stop",
        );
        let cleanup = stop_wifi_runtime_network_json(&mut network, reason);
        append_wrapper_log(&format!("wifi-runtime-network-cleanup {cleanup}"));
    }

    fn wpa_scan_results_json(socket_path: &Path, timeout: Duration) -> String {
        let client_path = format!(
            "/data/vendor/wifi/wpa/sockets/shadow-wpa-{}-scanresults",
            process::id()
        );
        let client_path = Path::new(&client_path);
        let _ = fs::remove_file(client_path);
        let socket = match UnixDatagram::bind(client_path) {
            Ok(socket) => socket,
            Err(error) => {
                return format!(
                    "{{\"command\":\"SCAN_RESULTS\",\"ok\":false,\"error\":{}}}",
                    json_string(&format!("bind {client_path:?}: {error}"))
                )
            }
        };
        let _ = fs::set_permissions(client_path, fs::Permissions::from_mode(0o770));
        if let Ok(c_client_path) = CString::new(client_path.as_os_str().as_bytes()) {
            let _ = unsafe { libc::chown(c_client_path.as_ptr(), 1010, 1010) };
        }
        let _ = socket.set_read_timeout(Some(timeout));
        let result = if let Err(error) = socket.connect(socket_path) {
            format!(
                "{{\"command\":\"SCAN_RESULTS\",\"ok\":false,\"error\":{}}}",
                json_string(&format!("connect {socket_path:?}: {error}"))
            )
        } else if let Err(error) = socket.send(b"SCAN_RESULTS") {
            format!(
                "{{\"command\":\"SCAN_RESULTS\",\"ok\":false,\"error\":{}}}",
                json_string(&format!("send: {error}"))
            )
        } else {
            let mut buf = vec![0_u8; 131072];
            match socket.recv(&mut buf) {
                Ok(size) => {
                    let response = wpa_ctrl_response_text(&buf[..size]);
                    let mut networks = Vec::new();
                    let mut bss_count = 0_usize;
                    for line in response.lines().skip(1) {
                        let fields = line.split('\t').collect::<Vec<_>>();
                        if fields.len() < 4 {
                            continue;
                        }
                        bss_count += 1;
                        if networks.len() < 20 {
                            networks.push(format!(
                                "{{\"frequency\":{},\"signalLevel\":{},\"flags\":{}}}",
                                json_string(fields[1]),
                                json_string(fields[2]),
                                json_string(fields[3])
                            ));
                        }
                    }
                    format!(
                        concat!(
                            "{{\"command\":\"SCAN_RESULTS\",\"ok\":{},",
                            "\"bssCount\":{},\"networks\":[{}]}}"
                        ),
                        bool_word(bss_count > 0 || response.starts_with("bssid")),
                        bss_count,
                        networks.join(",")
                    )
                }
                Err(error) => format!(
                    "{{\"command\":\"SCAN_RESULTS\",\"ok\":false,\"error\":{}}}",
                    json_string(&format!("recv: {error}"))
                ),
            }
        };
        let _ = fs::remove_file(client_path);
        result
    }

    fn wifi_child_liveness_json(child: &mut Child) -> WifiChildLiveness {
        match child.try_wait() {
            Ok(Some(status)) => WifiChildLiveness {
                json: format!(
                    "{{\"alive\":false,\"status\":{},\"error\":\"\"}}",
                    json_string(&status.to_string())
                ),
                alive: false,
            },
            Ok(None) => WifiChildLiveness {
                json: "{\"alive\":true,\"status\":\"\",\"error\":\"\"}".to_string(),
                alive: true,
            },
            Err(error) => WifiChildLiveness {
                json: format!(
                    "{{\"alive\":false,\"status\":\"\",\"error\":{}}}",
                    json_string(&error.to_string())
                ),
                alive: false,
            },
        }
    }

    fn stop_wifi_child_json(child: &mut Child) -> String {
        match child.try_wait() {
            Ok(Some(status)) => format!(
                "{{\"attempted\":true,\"alreadyExited\":true,\"status\":{}}}",
                json_string(&status.to_string())
            ),
            Ok(None) => {
                let kill_result = child.kill();
                let wait_result = child.wait();
                format!(
                    concat!(
                        "{{\"attempted\":true,\"alreadyExited\":false,",
                        "\"killOk\":{},\"killError\":{},\"waitOk\":{},\"waitStatus\":{},\"waitError\":{}}}"
                    ),
                    bool_word(kill_result.is_ok()),
                    json_optional_string(kill_result.err().map(|error| error.to_string())),
                    bool_word(wait_result.is_ok()),
                    json_optional_string(wait_result.as_ref().ok().map(|status| status.to_string())),
                    json_optional_string(wait_result.err().map(|error| error.to_string()))
                )
            }
            Err(error) => format!(
                "{{\"attempted\":true,\"alreadyExited\":false,\"statusError\":{}}}",
                json_string(&error.to_string())
            ),
        }
    }

    fn wifi_supplicant_probe_json(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> String {
        let binary_path = Path::new("/vendor/bin/hw/wpa_supplicant");
        let socket_path = Path::new("/data/vendor/wifi/wpa/sockets/wlan0");
        if !Path::new("/sys/class/net/wlan0").exists() {
            return "{\"attempted\":false,\"reason\":\"missing-wlan0\"}".to_string();
        }
        if !binary_path.is_file() {
            return format!(
                "{{\"attempted\":false,\"reason\":\"missing-binary\",\"binary\":{}}}",
                wifi_boot_path_status_json("/vendor/bin/hw/wpa_supplicant")
            );
        }
        if let Err(error) = ensure_sunfish_wpa_supplicant_config() {
            return format!(
                "{{\"attempted\":false,\"reason\":\"config-setup-failed\",\"error\":{}}}",
                json_string(&error.to_string())
            );
        }

        thread::sleep(Duration::from_secs(2));
        let _ = fs::remove_file(socket_path);
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-wpa-supplicant-start",
        );
        let mut child = spawn_sunfish_wifi_android_helper(
            "wpa_supplicant",
            &[
                "-iwlan0",
                "-Dnl80211",
                "-c/data/vendor/wifi/wpa/wpa_supplicant.conf",
                "-O/data/vendor/wifi/wpa/sockets",
                "-puse_p2p_group_interface=1",
                "-dd",
            ],
            probe_stage_path,
            probe_stage_prefix,
        );
        let Some(child) = child.as_mut() else {
            return "{\"attempted\":true,\"started\":false,\"reason\":\"spawn-failed\"}"
                .to_string();
        };

        let start = Instant::now();
        let mut early_exit_status = String::new();
        while start.elapsed() < Duration::from_secs(12) {
            if socket_path.exists() {
                break;
            }
            match child.try_wait() {
                Ok(Some(status)) => {
                    early_exit_status = status.to_string();
                    break;
                }
                Ok(None) => {}
                Err(error) => {
                    early_exit_status = format!("status-error: {error}");
                    break;
                }
            }
            thread::sleep(Duration::from_millis(250));
        }

        let socket_ready = socket_path.exists();
        if !socket_ready {
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                "wifi-wpa-supplicant-socket-missing",
            );
            let child_pid = child.id();
            let cleanup = stop_wifi_child_json(child);
            return format!(
                concat!(
                    "{{\"attempted\":true,\"started\":true,\"pid\":{},",
                    "\"socketReady\":false,\"earlyExit\":{},\"socket\":{},",
                    "\"cleanup\":{},\"logExcerpt\":{}}}"
                ),
                child_pid,
                json_string(&early_exit_status),
                wifi_boot_path_status_json("/data/vendor/wifi/wpa/sockets/wlan0"),
                cleanup,
                json_string(&redact_wifi_sensitive_text(&read_file_excerpt(
                    "/orange-gpu/wifi-helper-wpa_supplicant.log",
                    8192
                )))
            );
        }

        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wpa-ping-start");
        let ping = wpa_ctrl_command_result_json(socket_path, "PING", Duration::from_secs(2));
        let status_before_scan =
            wpa_ctrl_command_result_json(socket_path, "STATUS", Duration::from_secs(2));
        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wpa-scan-start");
        let scan = wpa_ctrl_command_result_json(socket_path, "SCAN", Duration::from_secs(2));
        thread::sleep(Duration::from_secs(6));
        let scan_results = wpa_scan_results_json(socket_path, Duration::from_secs(2));
        let status_after_scan =
            wpa_ctrl_command_result_json(socket_path, "STATUS", Duration::from_secs(2));
        let association_credentials = if config.wifi_association_probe || config.wifi_ip_probe {
            Some(read_wifi_credentials_once(&config.wifi_credentials_path))
        } else {
            None
        };
        let association = if config.wifi_association_probe
            && !config.wifi_ip_probe
            && association_credentials.is_some()
        {
            let credentials = association_credentials.as_ref().expect("checked is_some");
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                "wifi-wpa-association-start",
            );
            let association = wifi_association_probe_json(socket_path, credentials);
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                "wifi-wpa-association-done",
            );
            association
        } else {
            "{\"attempted\":false,\"reason\":\"disabled\"}".to_string()
        };
        let ip = if config.wifi_ip_probe {
            if let Some(credentials) = association_credentials.as_ref() {
                write_payload_probe_stage(
                    probe_stage_path,
                    probe_stage_prefix,
                    "wifi-wpa-ip-start",
                );
                let ip = wifi_ip_probe_json(config, socket_path, credentials);
                write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wpa-ip-done");
                ip
            } else {
                "{\"attempted\":false,\"reason\":\"credentials-unavailable\"}".to_string()
            }
        } else {
            "{\"attempted\":false,\"reason\":\"disabled\"}".to_string()
        };
        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wpa-probe-done");
        let child_pid = child.id();
        let cleanup = stop_wifi_child_json(child);

        format!(
            concat!(
                "{{\"attempted\":true,\"started\":true,\"pid\":{},",
                "\"socketReady\":true,\"earlyExit\":{},\"socket\":{},",
                "\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
                "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},\"ip\":{},",
                "\"cleanup\":{},\"logExcerpt\":{}}}"
            ),
            child_pid,
            json_string(&early_exit_status),
            wifi_boot_path_status_json("/data/vendor/wifi/wpa/sockets/wlan0"),
            ping,
            status_before_scan,
            scan,
            scan_results,
            status_after_scan,
            association,
            ip,
            cleanup,
            json_string(&redact_wifi_sensitive_text(&read_file_excerpt(
                "/orange-gpu/wifi-helper-wpa_supplicant.log",
                8192
            )))
        )
    }

    fn write_wifi_boot_summary(summary: &str) -> io::Result<()> {
        let temp_path = Path::new(ORANGE_GPU_ROOT).join(".wifi-linux-surface-summary.json.tmp");
        write_atomic_text_file(&temp_path, Path::new(ORANGE_GPU_SUMMARY_PATH), summary)
    }

    fn run_wifi_linux_surface_probe_internal(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> i32 {
        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-surface-start");

        let path_statuses = [
            "/sys/class/net/wlan0",
            "/sys/class/net/wlan1",
            "/sys/class/net/p2p0",
            "/sys/module/wlan",
            "/sys/kernel/wlan",
            "/sys/kernel/debug/wlan0",
            "/sys/kernel/debug/icnss",
            "/sys/kernel/debug/icnss/stats",
            "/dev/wlan",
            "/proc/net/wireless",
            "/lib/modules/wlan.ko",
            "/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini",
            "/lib/firmware/wlanmdsp.mbn",
            "/lib/firmware/wlan/qca_cld",
        ]
        .iter()
        .map(|path| wifi_boot_path_status_json(path))
        .collect::<Vec<_>>()
        .join(",\n    ");
        let activation_probe =
            wifi_interface_activation_probe_json(probe_stage_path, probe_stage_prefix);
        let supplicant_probe = if config.wifi_supplicant_probe {
            wifi_supplicant_probe_json(config, probe_stage_path, probe_stage_prefix)
        } else {
            "{\"attempted\":false,\"reason\":\"disabled\"}".to_string()
        };
        let net_interfaces = ["wlan0", "wlan1", "p2p0"]
            .iter()
            .map(|iface| wifi_interface_json(iface))
            .collect::<Vec<_>>()
            .join(",\n    ");
        let sys_module_wlan = read_dir_names("/sys/module/wlan", 64);
        let sys_kernel_wlan = read_dir_names("/sys/kernel/wlan", 64);
        let debug_wlan0 = read_dir_names("/sys/kernel/debug/wlan0", 64);
        let debug_icnss = read_dir_names("/sys/kernel/debug/icnss", 64);
        let debug_icnss_stats = read_file_excerpt("/sys/kernel/debug/icnss/stats", 16384);
        let proc_wireless = read_file_excerpt("/proc/net/wireless", 4096);
        let module_details = wifi_module_details_json();
        let helper_snapshot = wifi_helper_process_snapshot();
        let helper_processes = &helper_snapshot.processes_json;
        let helper_contract =
            wifi_helper_contract_json(&config.wifi_helper_profile, &helper_snapshot);
        let helper_logs = wifi_helper_logs_json();
        let kernel_log = redact_wifi_sensitive_text(&wifi_kernel_log_excerpt());
        let helper_contract_ok =
            wifi_helper_contract_ok(&config.wifi_helper_profile, &helper_snapshot);
        let blocker = if !helper_contract_ok {
            "wifi helper profile contract is not satisfied"
        } else if !Path::new("/sys/class/net/wlan0").exists() {
            "wlan0 is not visible in Shadow boot userspace"
        } else if !Path::new("/dev/wlan").exists() {
            "wlan0 exists but /dev/wlan vendor control node is missing"
        } else {
            ""
        };
        let stage = if blocker.is_empty() {
            "surface-ready"
        } else {
            "surface-blocked"
        };
        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, stage);

        let summary = format!(
            concat!(
                "{{\n",
                "  \"schemaVersion\": 1,\n",
                "  \"kind\": \"wifi-linux-surface-probe\",\n",
                "  \"mode\": \"wifi-linux-surface-probe\",\n",
                "  \"pid\": {},\n",
                "  \"runToken\": {},\n",
                "  \"mounts\": {{\"dev\": {}, \"proc\": {}, \"sys\": {}, \"devMount\": {}}},\n",
                "  \"wifiBootstrap\": {},\n",
                "  \"wifiHelperProfile\": {},\n",
                "  \"wifiSupplicantProbe\": {},\n",
                "  \"wifiAssociationProbe\": {},\n",
                "  \"wifiIpProbe\": {},\n",
                "  \"wifiCredentialsPathConfigured\": {},\n",
                "  \"wifiDhcpClientPathConfigured\": {},\n",
                "  \"androidWifiApiUse\": {{\"WifiManager\": false, \"wificond\": false, \"wpaSupplicantService\": false, \"vendorWpaSupplicantControlSocket\": {}, \"rootedAndroidShellWifiApi\": false, \"rootedAndroidShellRecoveryOnly\": true}},\n",
                "  \"pathStatus\": [\n    {}\n  ],\n",
                "  \"interfaces\": [\n    {}\n  ],\n",
                "  \"sysModuleWlanEntries\": {},\n",
                "  \"sysModuleWlanDetails\": {},\n",
                "  \"sysKernelWlanEntries\": {},\n",
                "  \"debugWlan0Entries\": {},\n",
                "  \"debugIcnssEntries\": {},\n",
                "  \"debugIcnssStats\": {},\n",
                "  \"procNetWireless\": {},\n",
                "  \"wifiHelperProcesses\": {},\n",
                "  \"wifiHelperContract\": {},\n",
                "  \"wifiHelperLogs\": {},\n",
                "  \"activationProbe\": {},\n",
                "  \"supplicantProbe\": {},\n",
                "  \"kernelLogExcerpt\": {},\n",
                "  \"surfaceReady\": {},\n",
                "  \"blockerStage\": {},\n",
                "  \"blocker\": {},\n",
                "  \"nextStep\": {}\n",
                "}}\n"
            ),
            process::id(),
            json_string(run_token_or_unset(config)),
            bool_word(config.mount_dev),
            bool_word(config.mount_proc),
            bool_word(config.mount_sys),
            json_string(&config.dev_mount),
            json_string(&config.wifi_bootstrap),
            json_string(&config.wifi_helper_profile),
            bool_word(config.wifi_supplicant_probe),
            bool_word(config.wifi_association_probe),
            bool_word(config.wifi_ip_probe),
            bool_word(!config.wifi_credentials_path.is_empty()),
            bool_word(!config.wifi_dhcp_client_path.is_empty()),
            bool_word(config.wifi_supplicant_probe),
            path_statuses,
            net_interfaces,
            json_string_array(&sys_module_wlan),
            module_details,
            json_string_array(&sys_kernel_wlan),
            json_string_array(&debug_wlan0),
            json_string_array(&debug_icnss),
            json_string(&debug_icnss_stats),
            json_string(&proc_wireless),
            helper_processes,
            helper_contract,
            helper_logs,
            activation_probe,
            supplicant_probe,
            json_string(&kernel_log),
            bool_word(blocker.is_empty()),
            json_string(stage),
            json_string(blocker),
            json_string(if blocker.is_empty() {
                "run a contained WPA association probe against wlan0 using nl80211 or the vendor supplicant binary"
            } else {
                "stage/load wlan.ko plus the minimal qca_cld firmware/config roots, then rerun this probe"
            })
        );

        match write_wifi_boot_summary(&summary) {
            Ok(()) => {
                if blocker.is_empty() {
                    0
                } else {
                    2
                }
            }
            Err(error) => {
                log_line(&format!(
                    "failed to write wifi linux surface summary: {error}"
                ));
                1
            }
        }
    }

    fn run_camera_hal_bionic_probe_helper(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
        stages: &mut Vec<String>,
    ) -> Option<i32> {
        if !Path::new(CAMERA_HAL_BIONIC_PROBE_PATH).is_file()
            || !Path::new(CAMERA_HAL_BIONIC_LINKER_PATH).is_file()
        {
            return None;
        }

        push_camera_boot_hal_stage(
            stages,
            probe_stage_path,
            probe_stage_prefix,
            "link",
            "bionic-helper-start",
            CAMERA_HAL_BIONIC_PROBE_PATH,
        );
        remove_file_best_effort(CAMERA_HAL_BIONIC_PROBE_SUMMARY_PATH);
        remove_file_best_effort(CAMERA_HAL_BIONIC_PROBE_OUTPUT_PATH);

        let mut command = Command::new(CAMERA_HAL_BIONIC_LINKER_PATH);
        command.arg(CAMERA_HAL_BIONIC_PROBE_PATH);
        command.arg("--output");
        command.arg(CAMERA_HAL_BIONIC_PROBE_SUMMARY_PATH);
        command.arg("--run-token");
        command.arg(run_token_or_unset(config));
        command.arg("--camera-id");
        command.arg(&config.camera_hal_camera_id);
        command.arg("--dev-mount");
        command.arg(&config.dev_mount);
        command.arg("--mount-dev");
        command.arg(bool_word(config.mount_dev));
        command.arg("--mount-proc");
        command.arg(bool_word(config.mount_proc));
        command.arg("--mount-sys");
        command.arg(bool_word(config.mount_sys));
        command.arg("--call-open");
        command.arg(bool_word(config.camera_hal_call_open));
        command.arg("--child-timeout-secs");
        command.arg(
            resolve_watchdog_timeout(config)
                .saturating_sub(10)
                .max(1)
                .to_string(),
        );
        command.env(LD_LIBRARY_PATH_ENV, CAMERA_HAL_BIONIC_LIBRARY_PATH);
        command.env("ANDROID_ROOT", "/system");
        command.env("ANDROID_DATA", "/data");
        command.env("LD_CONFIG_FILE", "/linkerconfig/ld.config.txt");
        if let Ok((stdout, stderr)) = redirect_output(CAMERA_HAL_BIONIC_PROBE_OUTPUT_PATH) {
            command.stdout(stdout);
            command.stderr(stderr);
        }

        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                log_line(&format!(
                    "camera HAL bionic helper failed to spawn: {error}"
                ));
                return None;
            }
        };
        let watch_result = match wait_for_child_with_watchdog(
            &mut child,
            "camera-hal-bionic-probe",
            1,
            resolve_watchdog_timeout(config),
            true,
            None,
        ) {
            Ok(result) => result,
            Err(error) => {
                log_line(&format!("camera HAL bionic helper wait failed: {error}"));
                return None;
            }
        };
        if watch_result.timed_out {
            log_line("camera HAL bionic helper timed out before writing a summary");
            return None;
        }
        if watch_result.exit_status != Some(0) {
            log_line(&format!(
                "camera HAL bionic helper exited nonzero: {:?}",
                watch_result.exit_status
            ));
        }

        match fs::read_to_string(CAMERA_HAL_BIONIC_PROBE_SUMMARY_PATH) {
            Ok(summary) => match write_camera_boot_hal_summary(&summary) {
                Ok(()) => Some(0),
                Err(error) => {
                    log_line(&format!(
                        "failed to persist camera HAL bionic helper summary: {error}"
                    ));
                    Some(1)
                }
            },
            Err(error) => {
                log_line(&format!(
                    "camera HAL bionic helper did not write a readable summary: {error}"
                ));
                None
            }
        }
    }

    fn run_camera_hal_link_probe_internal(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> i32 {
        let mut stages = Vec::new();
        let path_probe_targets = [
            CAMERA_HAL_PATH,
            "/vendor",
            "/vendor/lib64",
            "/vendor/lib64/hw",
            "/system/lib64/libhardware.so",
            "/system/lib64/libcamera_metadata.so",
            "/apex/com.android.runtime/bin/linker64",
            "/linkerconfig/ld.config.txt",
            "/dev/binder",
            "/dev/hwbinder",
            "/dev/vndbinder",
            "/dev/video0",
            "/dev/video1",
            "/dev/media0",
            "/dev/dma_heap/system",
        ];
        let path_statuses = path_probe_targets
            .iter()
            .map(|path| camera_boot_hal_path_status_json(path))
            .collect::<Vec<_>>()
            .join(",\n    ");

        let mut link_json =
            "{\"attempted\":false,\"ok\":false,\"handle\":null,\"error\":null}".to_string();
        let mut hmi_json =
            "{\"attempted\":false,\"ok\":false,\"address\":null,\"error\":null}".to_string();
        let mut module_json = "{\"attempted\":false,\"ok\":false,\"cameraCount\":null}".to_string();
        let mut open_json =
            "{\"attempted\":false,\"ok\":false,\"ready\":false,\"blocker\":\"not reached\"}"
                .to_string();
        let configure_json =
            "{\"attempted\":false,\"ok\":false,\"blocker\":\"not reached\"}".to_string();
        let request_json =
            "{\"attempted\":false,\"ok\":false,\"blocker\":\"not reached\"}".to_string();
        let mut blocker_stage = "link";
        let mut blocker = "vendor camera HAL path is not visible in Shadow boot userspace";
        let mut next_step = "mount or stage the vendor partition plus the Android bionic/linker namespace before attempting HMI/open";

        push_camera_boot_hal_stage(
            &mut stages,
            probe_stage_path,
            probe_stage_prefix,
            "link",
            "start",
            CAMERA_HAL_PATH,
        );
        if let Some(status) = run_camera_hal_bionic_probe_helper(
            config,
            probe_stage_path,
            probe_stage_prefix,
            &mut stages,
        ) {
            return status;
        }

        let hal_metadata = fs::metadata(CAMERA_HAL_PATH);
        let hal_file_visible = match &hal_metadata {
            Ok(metadata) => metadata.is_file(),
            Err(_) => false,
        };
        if !hal_file_visible {
            let detail = match hal_metadata {
                Ok(_) => "path resolves but is not a regular file".to_string(),
                Err(error) => error.to_string(),
            };
            link_json = format!(
                "{{\"attempted\":false,\"ok\":false,\"handle\":null,\"error\":{},\"fileVisible\":false}}",
                json_string(&detail)
            );
            push_camera_boot_hal_stage(
                &mut stages,
                probe_stage_path,
                probe_stage_prefix,
                "link",
                "blocked",
                "vendor HAL file missing from boot namespace",
            );
        } else {
            let path_c = CString::new(CAMERA_HAL_PATH).expect("static camera HAL path CString");
            let handle = unsafe {
                let _ = libc::dlerror();
                libc::dlopen(path_c.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL)
            };
            if handle.is_null() {
                let error = dl_error_message("dlopen camera HAL");
                link_json = format!(
                    "{{\"attempted\":true,\"ok\":false,\"handle\":null,\"error\":{}}}",
                    json_string(&error)
                );
                blocker = "dlopen failed from Shadow boot userspace";
                next_step = "provide the Android bionic linker namespace and dependent vendor/system/apex libraries without starting cameraserver";
                push_camera_boot_hal_stage(
                    &mut stages,
                    probe_stage_path,
                    probe_stage_prefix,
                    "link",
                    "blocked",
                    &error,
                );
            } else {
                link_json = format!(
                    "{{\"attempted\":true,\"ok\":true,\"handle\":{},\"error\":null}}",
                    json_pointer(handle)
                );
                push_camera_boot_hal_stage(
                    &mut stages,
                    probe_stage_path,
                    probe_stage_prefix,
                    "link",
                    "ok",
                    "dlopen succeeded",
                );

                push_camera_boot_hal_stage(
                    &mut stages,
                    probe_stage_path,
                    probe_stage_prefix,
                    "hmi",
                    "start",
                    "dlsym HMI",
                );
                let symbol = CString::new("HMI").expect("static HMI symbol CString");
                let hmi_ptr = unsafe {
                    let _ = libc::dlerror();
                    libc::dlsym(handle, symbol.as_ptr())
                };
                if hmi_ptr.is_null() {
                    let error = dl_error_message("dlsym HMI");
                    hmi_json = format!(
                        "{{\"attempted\":true,\"ok\":false,\"address\":null,\"error\":{}}}",
                        json_string(&error)
                    );
                    blocker_stage = "hmi";
                    blocker = "camera HAL loaded but did not expose HAL_MODULE_INFO_SYM/HMI";
                    next_step = "verify the vendor HAL export surface and whether the direct path needs hw_get_module-style loading";
                    push_camera_boot_hal_stage(
                        &mut stages,
                        probe_stage_path,
                        probe_stage_prefix,
                        "hmi",
                        "blocked",
                        &error,
                    );
                } else {
                    let module = unsafe { &*(hmi_ptr as *const CameraModulePartial) };
                    let id = c_string_from_ptr(module.common.id);
                    let name = c_string_from_ptr(module.common.name);
                    let author = c_string_from_ptr(module.common.author);
                    hmi_json = format!(
                        "{{\"attempted\":true,\"ok\":true,\"address\":{},\"tag\":{},\"moduleApiVersion\":{},\"halApiVersion\":{},\"id\":{},\"name\":{},\"author\":{},\"methods\":{}}}",
                        json_pointer(hmi_ptr),
                        module.common.tag,
                        module.common.module_api_version,
                        module.common.hal_api_version,
                        json_optional_string(id.clone()),
                        json_optional_string(name),
                        json_optional_string(author),
                        json_pointer(module.common.methods as *mut libc::c_void)
                    );
                    push_camera_boot_hal_stage(
                        &mut stages,
                        probe_stage_path,
                        probe_stage_prefix,
                        "hmi",
                        "ok",
                        "HMI identified",
                    );

                    push_camera_boot_hal_stage(
                        &mut stages,
                        probe_stage_path,
                        probe_stage_prefix,
                        "module",
                        "start",
                        "camera_module_t prefix",
                    );
                    let mut camera_count_json = "null".to_string();
                    let mut camera_info_json = "null".to_string();
                    if let Some(get_number_of_cameras) = module.get_number_of_cameras {
                        let count = unsafe { get_number_of_cameras() };
                        camera_count_json = count.to_string();
                        if count > 0 {
                            if let Some(get_camera_info) = module.get_camera_info {
                                let mut info = std::mem::MaybeUninit::<CameraInfoPartial>::zeroed();
                                let status = unsafe { get_camera_info(0, info.as_mut_ptr()) };
                                if status == 0 {
                                    let info = unsafe { info.assume_init() };
                                    camera_info_json = format!(
                                        "{{\"attempted\":true,\"status\":0,\"facing\":{},\"orientation\":{},\"deviceVersion\":{},\"staticMetadata\":{},\"resourceCost\":{},\"conflictingDevicesLength\":{}}}",
                                        info.facing,
                                        info.orientation,
                                        info.device_version,
                                        json_pointer(info.static_camera_characteristics as *mut libc::c_void),
                                        info.resource_cost,
                                        info.conflicting_devices_length
                                    );
                                } else {
                                    camera_info_json = format!(
                                        "{{\"attempted\":true,\"status\":{},\"ok\":false}}",
                                        status
                                    );
                                }
                            }
                        }
                    }
                    let module_ok =
                        id.as_deref() == Some("camera") && !module.common.methods.is_null();
                    module_json = format!(
                        "{{\"attempted\":true,\"ok\":{},\"id\":{},\"methodsPresent\":{},\"getNumberOfCamerasPresent\":{},\"getCameraInfoPresent\":{},\"cameraCount\":{},\"camera0\":{}}}",
                        bool_word(module_ok),
                        json_optional_string(id),
                        bool_word(!module.common.methods.is_null()),
                        bool_word(module.get_number_of_cameras.is_some()),
                        bool_word(module.get_camera_info.is_some()),
                        camera_count_json,
                        camera_info_json
                    );
                    if module_ok {
                        push_camera_boot_hal_stage(
                            &mut stages,
                            probe_stage_path,
                            probe_stage_prefix,
                            "module",
                            "ok",
                            "camera_module_t prefix readable",
                        );
                        let open_ready = unsafe { (*module.common.methods).open.is_some() };
                        open_json = format!(
                            "{{\"attempted\":false,\"ok\":false,\"ready\":{},\"cameraId\":{},\"blocker\":{}}}",
                            bool_word(open_ready),
                            json_string(&config.camera_hal_camera_id),
                            json_string("first boot probe stops before invoking camera_module_t.open; next slice must own close/error recovery plus native buffer, fence, and gralloc policy")
                        );
                        blocker_stage = "open";
                        blocker = "HMI/module is reachable, but direct camera_module_t.open/configure/request is intentionally left to the next contained shim slice";
                        next_step = "add a tiny open/close shim with watchdog-safe cleanup, then wire camera3 stream configuration and a single native buffer request";
                        push_camera_boot_hal_stage(
                            &mut stages,
                            probe_stage_path,
                            probe_stage_prefix,
                            "open",
                            "blocked",
                            "open shim not invoked in this boot-safe probe",
                        );
                    } else {
                        blocker_stage = "module";
                        blocker = "HMI was found but did not look like a camera module with usable methods";
                        next_step = "tighten the camera_module_t shim against the vendor module layout before open/configure/request";
                        push_camera_boot_hal_stage(
                            &mut stages,
                            probe_stage_path,
                            probe_stage_prefix,
                            "module",
                            "blocked",
                            "camera module prefix unusable",
                        );
                    }
                }
            }
        }

        if blocker_stage != "open" {
            push_camera_boot_hal_stage(
                &mut stages,
                probe_stage_path,
                probe_stage_prefix,
                "open",
                "not-reached",
                blocker,
            );
        }
        push_camera_boot_hal_stage(
            &mut stages,
            probe_stage_path,
            probe_stage_prefix,
            "configure",
            "not-reached",
            blocker,
        );
        push_camera_boot_hal_stage(
            &mut stages,
            probe_stage_path,
            probe_stage_prefix,
            "request",
            "not-reached",
            blocker,
        );

        let summary = format!(
            concat!(
                "{{\n",
                "  \"schemaVersion\": 1,\n",
                "  \"kind\": \"camera-boot-hal-probe\",\n",
                "  \"mode\": \"camera-hal-link-probe\",\n",
                "  \"pid\": {},\n",
                "  \"runToken\": {},\n",
                "  \"halPath\": {},\n",
                "  \"cameraId\": {},\n",
                "  \"mounts\": {{\"dev\": {}, \"proc\": {}, \"sys\": {}, \"devMount\": {}}},\n",
                "  \"androidCameraApiUse\": {{\"ICameraProvider\": false, \"cameraserver\": false, \"javaCamera2\": false, \"rootedAndroidShellCameraApi\": false, \"rootedAndroidShellRecoveryOnly\": true}},\n",
                "  \"pathStatus\": [\n    {}\n  ],\n",
                "  \"stages\": [\n    {}\n  ],\n",
                "  \"link\": {},\n",
                "  \"hmi\": {},\n",
                "  \"module\": {},\n",
                "  \"open\": {},\n",
                "  \"configure\": {},\n",
                "  \"request\": {},\n",
                "  \"frameCapture\": {{\"attempted\": false, \"captured\": false, \"artifactPath\": null}},\n",
                "  \"blockerStage\": {},\n",
                "  \"blocker\": {},\n",
                "  \"nextStep\": {}\n",
                "}}\n"
            ),
            process::id(),
            json_string(run_token_or_unset(config)),
            json_string(CAMERA_HAL_PATH),
            json_string(&config.camera_hal_camera_id),
            bool_word(config.mount_dev),
            bool_word(config.mount_proc),
            bool_word(config.mount_sys),
            json_string(&config.dev_mount),
            path_statuses,
            stages.join(",\n    "),
            link_json,
            hmi_json,
            module_json,
            open_json,
            configure_json,
            request_json,
            json_string(blocker_stage),
            json_string(blocker),
            json_string(next_step)
        );

        match write_camera_boot_hal_summary(&summary) {
            Ok(()) => 0,
            Err(error) => {
                log_line(&format!("failed to write camera boot HAL summary: {error}"));
                1
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
        append_path_fingerprint_line(&mut payload, "/dev/video0");
        append_path_fingerprint_line(&mut payload, "/dev/video1");
        append_path_fingerprint_line(&mut payload, "/dev/video2");
        append_path_fingerprint_line(&mut payload, "/dev/video32");
        append_path_fingerprint_line(&mut payload, "/dev/media0");
        append_path_fingerprint_line(&mut payload, "/dev/media1");
        append_path_fingerprint_line(&mut payload, "/dev/v4l-subdev0");
        append_path_fingerprint_line(&mut payload, "/dev/v4l-subdev16");
        append_path_fingerprint_line(&mut payload, "/dev/wlan");
        append_path_fingerprint_line(&mut payload, "/sys/class/net/wlan0");
        append_path_fingerprint_line(&mut payload, "/sys/class/net/p2p0");
        append_path_fingerprint_line(&mut payload, "/sys/module/wlan");
        append_path_fingerprint_line(&mut payload, "/sys/kernel/wlan");
        append_path_fingerprint_line(&mut payload, ORANGE_GPU_ICD_PATH);
        append_file_excerpt(&mut payload, "/proc/mounts", 1024);
        append_file_excerpt(&mut payload, "/proc/net/wireless", 1024);
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
                append_pid_children_tree_excerpt(&mut payload, pid, 2);
            }
        }

        append_file_excerpt(&mut payload, ORANGE_GPU_OUTPUT_PATH, 16384);
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

    #[derive(Default)]
    struct TouchCounterEvidence {
        input_observed: bool,
        tap_dispatched: bool,
        counter_incremented: bool,
        post_touch_frame_committed: bool,
        post_touch_frame_artifact_logged: bool,
        touch_latency_present: bool,
        post_touch_frame_captured: bool,
    }

    impl TouchCounterEvidence {
        fn ok(&self) -> bool {
            self.input_observed
                && self.tap_dispatched
                && self.counter_incremented
                && self.post_touch_frame_committed
                && self.post_touch_frame_artifact_logged
                && self.touch_latency_present
                && self.post_touch_frame_captured
        }
    }

    #[derive(Clone, Copy)]
    struct TouchCounterEvidenceProfile {
        injection: &'static str,
        tap_dispatched_needle: &'static str,
        counter_incremented_needle: &'static str,
        post_touch_frame_marker_needle: &'static str,
        post_touch_frame_artifact_needle: &'static str,
        post_touch_frame_committed_needle: &'static str,
    }

    impl TouchCounterEvidenceProfile {
        fn rust_counter(injection: &'static str) -> Self {
            Self {
                injection,
                tap_dispatched_needle: "[shadow-guest-compositor] touch-app-tap-dispatch",
                counter_incremented_needle: "shadow-rust-demo: counter_incremented count=1",
                post_touch_frame_marker_needle: "shadow-rust-demo: frame_committed counter=1",
                post_touch_frame_artifact_needle: "[shadow-guest-compositor] wrote-frame-artifact",
                post_touch_frame_committed_needle: "shadow-rust-demo: frame_committed counter=1",
            }
        }

        fn runtime_counter(
            injection: &'static str,
            post_touch_frame_artifact: &'static str,
            post_touch_frame_presented: &'static str,
        ) -> Self {
            Self {
                injection,
                tap_dispatched_needle: "route=app-tap",
                counter_incremented_needle: "[shadow-runtime-counter] counter_incremented count=2",
                post_touch_frame_marker_needle:
                    "[shadow-runtime-counter] counter_incremented count=2",
                post_touch_frame_artifact_needle: post_touch_frame_artifact,
                post_touch_frame_committed_needle: post_touch_frame_presented,
            }
        }
    }

    fn touch_counter_evidence_from_output(
        output_text: &str,
        frame_bytes: u64,
        profile: TouchCounterEvidenceProfile,
    ) -> TouchCounterEvidence {
        let post_touch_frame_index = output_text.find(profile.post_touch_frame_marker_needle);
        let post_touch_frame_artifact_index = post_touch_frame_index.and_then(|index| {
            output_text[index..]
                .find(profile.post_touch_frame_artifact_needle)
                .map(|offset| index + offset)
        });
        let post_touch_frame_committed = post_touch_frame_artifact_index
            .map(|index| output_text[index..].contains(profile.post_touch_frame_committed_needle))
            .unwrap_or(false);
        let post_touch_frame_artifact_logged = post_touch_frame_artifact_index.is_some();
        TouchCounterEvidence {
            input_observed: output_text
                .contains("[shadow-guest-compositor] touch-input phase=Down")
                || output_text
                    .contains("[shadow-guest-compositor] synthetic-touch-observed phase=Down"),
            tap_dispatched: output_text.contains(profile.tap_dispatched_needle),
            counter_incremented: output_text.contains(profile.counter_incremented_needle),
            post_touch_frame_committed,
            post_touch_frame_artifact_logged,
            touch_latency_present: output_text
                .contains("[shadow-guest-compositor] touch-latency-present"),
            post_touch_frame_captured: frame_bytes > 0 && post_touch_frame_artifact_logged,
        }
    }

    #[derive(Default)]
    struct ShellSessionEvidence {
        shell_mode_enabled: bool,
        home_frame_done: bool,
        start_app_requested: bool,
        app_launch_mode_logged: bool,
        mapped_window: bool,
        surface_app_tracked: bool,
        app_frame_artifact_logged: bool,
        app_frame_captured: bool,
    }

    impl ShellSessionEvidence {
        fn ok(&self) -> bool {
            self.shell_mode_enabled
                && self.home_frame_done
                && self.start_app_requested
                && self.app_launch_mode_logged
                && self.mapped_window
                && self.surface_app_tracked
                && self.app_frame_artifact_logged
                && self.app_frame_captured
        }
    }

    fn shell_session_evidence_from_output(
        output_text: &str,
        frame_bytes: u64,
        app_id: &str,
    ) -> ShellSessionEvidence {
        let start_app_needle = format!("[shadow-guest-compositor] shell-start-app-id={app_id}");
        let app_launch_needle = format!("[shadow-guest-compositor] app-launch-mode app={app_id}");
        let mapped_window_needle = format!("[shadow-guest-compositor] mapped-window app={app_id}");
        let surface_tracked_needle =
            format!("[shadow-guest-compositor] surface-app-tracked app={app_id}");
        let start_app_index = output_text.find(&start_app_needle);
        let mapped_window = output_text.contains(&mapped_window_needle)
            || start_app_index
                .map(|index| {
                    output_text[index..].contains("[shadow-guest-compositor] mapped-window")
                })
                .unwrap_or(false);
        let app_frame_artifact_logged = start_app_index
            .and_then(|index| {
                output_text[index..].find("[shadow-guest-compositor] wrote-frame-artifact")
            })
            .is_some();
        ShellSessionEvidence {
            shell_mode_enabled: output_text
                .contains("[shadow-guest-compositor] shell-mode enabled"),
            home_frame_done: output_text
                .contains("[shadow-guest-compositor] shell-startup-home-frame-done"),
            start_app_requested: start_app_index.is_some(),
            app_launch_mode_logged: output_text.contains(&app_launch_needle),
            mapped_window,
            surface_app_tracked: output_text.contains(&surface_tracked_needle),
            app_frame_artifact_logged,
            app_frame_captured: frame_bytes > 0 && app_frame_artifact_logged,
        }
    }

    fn record_session_frame_summary(
        runtime: &mut MetadataStageRuntime,
        kind: &str,
        startup_mode: &str,
        app_id: Option<&str>,
        touch_counter_profile: Option<TouchCounterEvidenceProfile>,
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
        let shell_summary_kind = matches!(
            kind,
            "shell-session" | "shell-session-held" | "shell-session-runtime-touch-counter"
        );
        let output_text = if touch_counter_profile.is_some() || shell_summary_kind {
            Some(fs::read_to_string(ORANGE_GPU_OUTPUT_PATH).map_err(|_| "output-log-missing")?)
        } else {
            None
        };
        let touch_counter_evidence = if let Some(profile) = touch_counter_profile {
            Some(touch_counter_evidence_from_output(
                output_text.as_deref().unwrap_or(""),
                frame_bytes,
                profile,
            ))
        } else {
            None
        };
        let shell_session_evidence = if shell_summary_kind {
            let Some(app_id) = app_id else {
                return Err("shell-session-app-id-missing");
            };
            Some(shell_session_evidence_from_output(
                output_text.as_deref().unwrap_or(""),
                frame_bytes,
                app_id,
            ))
        } else {
            None
        };
        let mut payload =
            format!("{{\n  \"kind\": \"{kind}\",\n  \"startup_mode\": \"{startup_mode}\",\n");
        if let Some(app_id) = app_id {
            let _ = write!(payload, "  \"app_id\": \"{app_id}\",\n");
        }
        if let Some(evidence) = shell_session_evidence.as_ref() {
            let _ = write!(
                payload,
                "  \"shell_session_probe\": {{\n    \"shell_mode_enabled\": {},\n    \"home_frame_done\": {},\n    \"start_app_requested\": {},\n    \"app_launch_mode_logged\": {},\n    \"mapped_window\": {},\n    \"surface_app_tracked\": {},\n    \"app_frame_artifact_logged\": {},\n    \"app_frame_captured\": {}\n  }},\n  \"shell_session_probe_ok\": {},\n",
                evidence.shell_mode_enabled,
                evidence.home_frame_done,
                evidence.start_app_requested,
                evidence.app_launch_mode_logged,
                evidence.mapped_window,
                evidence.surface_app_tracked,
                evidence.app_frame_artifact_logged,
                evidence.app_frame_captured,
                evidence.ok()
            );
        }
        if let Some(evidence) = touch_counter_evidence.as_ref() {
            let injection = touch_counter_profile
                .map(|profile| profile.injection)
                .unwrap_or("unknown");
            let _ = write!(
                payload,
                "  \"touch_counter_probe\": {{\n    \"injection\": \"{}\",\n    \"input_observed\": {},\n    \"tap_dispatched\": {},\n    \"counter_incremented\": {},\n    \"post_touch_frame_committed\": {},\n    \"post_touch_frame_artifact_logged\": {},\n    \"touch_latency_present\": {},\n    \"post_touch_frame_captured\": {}\n  }},\n  \"touch_counter_probe_ok\": {},\n",
                injection,
                evidence.input_observed,
                evidence.tap_dispatched,
                evidence.counter_incremented,
                evidence.post_touch_frame_committed,
                evidence.post_touch_frame_artifact_logged,
                evidence.touch_latency_present,
                evidence.post_touch_frame_captured,
                evidence.ok()
            );
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
        if touch_counter_profile.is_some()
            && !touch_counter_evidence
                .as_ref()
                .map(TouchCounterEvidence::ok)
                .unwrap_or(false)
        {
            return Err("touch-counter-proof-missing");
        }
        if shell_summary_kind
            && !shell_session_evidence
                .as_ref()
                .map(ShellSessionEvidence::ok)
                .unwrap_or(false)
        {
            return Err("shell-session-proof-missing");
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

    fn prune_metadata_token_root(config: &Config) -> io::Result<()> {
        if !config.orange_gpu_metadata_prune_token_root || config.run_token.is_empty() {
            return Ok(());
        }
        let root = Path::new(METADATA_BY_TOKEN_ROOT);
        let entries = match fs::read_dir(root) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        };
        for entry in entries {
            let entry = entry?;
            if entry.file_name().as_bytes() == config.run_token.as_bytes() {
                continue;
            }
            let path = entry.path();
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                fs::remove_dir_all(&path)?;
            } else {
                fs::remove_file(&path)?;
            }
        }
        Ok(())
    }

    fn try_prepare_metadata_stage_runtime(
        runtime: &mut MetadataStageRuntime,
        config: &Config,
    ) -> io::Result<()> {
        discover_metadata_block_identity_from_sysfs(runtime, config);
        bootstrap_tmpfs_metadata_block_runtime(runtime, config)?;
        ensure_directory(Path::new(METADATA_MOUNT_PATH), 0o755)?;
        let mount_flags = (libc::MS_NOATIME | libc::MS_NODEV | libc::MS_NOSUID) as libc::c_ulong;
        mount_fs(
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
        })?;
        ensure_directory(Path::new(METADATA_ROOT), 0o755)?;
        sync_directory(Path::new(METADATA_MOUNT_PATH))?;
        ensure_directory(Path::new(METADATA_BY_TOKEN_ROOT), 0o755)?;
        sync_directory(Path::new(METADATA_ROOT))?;
        prune_metadata_token_root(config)?;
        ensure_directory(&runtime.stage_dir, 0o755)?;
        sync_directory(Path::new(METADATA_BY_TOKEN_ROOT))?;
        Ok(())
    }

    fn prepare_metadata_stage_runtime(runtime: &mut MetadataStageRuntime, config: &Config) {
        if !runtime.enabled || runtime.prepared {
            return;
        }
        for attempt in 1..=METADATA_PREPARE_RETRY_ATTEMPTS {
            match try_prepare_metadata_stage_runtime(runtime, config) {
                Ok(()) => {
                    runtime.prepared = true;
                    return;
                }
                Err(error) => {
                    append_wrapper_log(&format!(
                        "metadata stage prepare attempt {attempt}/{METADATA_PREPARE_RETRY_ATTEMPTS} failed: {error}"
                    ));
                    if attempt < METADATA_PREPARE_RETRY_ATTEMPTS {
                        sleep_seconds(METADATA_PREPARE_RETRY_SLEEP_SECS);
                    }
                }
            }
        }
        runtime.write_failed = true;
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
        ensure_directory(Path::new(ORANGE_GPU_COMPOSITOR_RUNTIME_DIR), 0o755)?;
        ensure_directory(Path::new(ORANGE_GPU_HOME), 0o755)?;
        ensure_directory(Path::new(ORANGE_GPU_CACHE_HOME), 0o755)?;
        ensure_directory(Path::new(ORANGE_GPU_CONFIG_HOME), 0o755)?;
        ensure_directory(Path::new(ORANGE_GPU_MESA_CACHE_DIR), 0o755)?;
        Ok(())
    }

    fn expand_orange_gpu_bundle_archive(config: &Config) -> io::Result<()> {
        if config.orange_gpu_bundle_archive_path.is_empty() {
            return Ok(());
        }

        let source_path = Path::new(&config.orange_gpu_bundle_archive_path);
        let temp_tar_path = Path::new(ORANGE_GPU_COMPOSITOR_RUNTIME_DIR)
            .join(format!("orange-gpu-bundle.{}.tar", process::id()));
        let input = File::open(source_path)?;
        let output = File::create(&temp_tar_path)?;
        let mut reader = BufReader::new(input);
        let mut writer = BufWriter::new(output);
        lzma_rs::xz_decompress(&mut reader, &mut writer)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;
        writer.flush()?;
        drop(writer);

        ensure_directory(Path::new(ORANGE_GPU_ROOT), 0o755)?;
        let tar_input = File::open(&temp_tar_path)?;
        let mut archive = tar::Archive::new(tar_input);
        archive.unpack(ORANGE_GPU_ROOT)?;
        let _ = fs::remove_file(&temp_tar_path);
        Ok(())
    }

    fn orange_gpu_bundle_archive_needs_shadow_logical_payload(config: &Config) -> bool {
        !config.orange_gpu_bundle_archive_path.is_empty()
            && Path::new(&config.orange_gpu_bundle_archive_path)
                .starts_with(SHADOW_PAYLOAD_MOUNT_PATH)
    }

    fn set_orange_gpu_env(
        command: &mut Command,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) {
        command.env(GPU_BACKEND_ENV, "vulkan");
        command.env(LD_LIBRARY_PATH_ENV, ORANGE_GPU_LIBRARY_PATH);
        command.env(LIBGL_DRIVERS_PATH_ENV, ORANGE_GPU_DRI_DRIVER_PATH);
        command.env(VK_ICD_FILENAMES_ENV, ORANGE_GPU_ICD_PATH);
        command.env(
            EGL_VENDOR_LIBRARY_DIRS_ENV,
            ORANGE_GPU_EGL_VENDOR_LIBRARY_DIRS,
        );
        command.env(MESA_DRIVER_OVERRIDE_ENV, "kgsl");
        command.env(TU_DEBUG_ENV, "noconform");
        command.env(HOME_ENV, ORANGE_GPU_HOME);
        command.env(XDG_CACHE_HOME_ENV, ORANGE_GPU_CACHE_HOME);
        command.env(XDG_CONFIG_HOME_ENV, ORANGE_GPU_CONFIG_HOME);
        command.env(XKB_CONFIG_EXTRA_PATH_ENV, ORANGE_GPU_XKB_CONFIG_EXTRA_PATH);
        command.env(XKB_CONFIG_ROOT_ENV, ORANGE_GPU_XKB_CONFIG_ROOT);
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

    fn firmware_request_path_is_safe(filename: &str) -> bool {
        !filename.is_empty()
            && Path::new(filename)
                .components()
                .all(|component| matches!(component, Component::Normal(_)))
    }

    fn firmware_source_path(filename: &str) -> Option<PathBuf> {
        let decoded_filename = filename.replace('!', "/");
        if !firmware_request_path_is_safe(filename)
            && !firmware_request_path_is_safe(&decoded_filename)
        {
            return None;
        }
        [
            "/lib/firmware",
            "/vendor/firmware_mnt/image",
            "/vendor/firmware",
        ]
        .iter()
        .flat_map(|root| {
            [
                Path::new(root).join(filename),
                Path::new(root).join(&decoded_filename),
            ]
        })
        .find(|path| path.is_file())
    }

    fn service_firmware_request_from_ramdisk(filename: &str) -> io::Result<PathBuf> {
        let request_root = Path::new(FIRMWARE_CLASS_ROOT).join(filename);
        let loading_path = request_root.join("loading");
        let data_path = request_root.join("data");
        let firmware_path = firmware_source_path(filename).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("missing firmware {filename}"),
            )
        })?;

        let mut loading_file = OpenOptions::new().write(true).open(&loading_path)?;
        let mut data_file = OpenOptions::new().write(true).open(&data_path)?;
        let mut firmware_file = File::open(&firmware_path)?;

        loading_file.write_all(b"1")?;
        io::copy(&mut firmware_file, &mut data_file)?;
        loading_file.write_all(b"0")?;
        Ok(firmware_path)
    }

    fn service_available_ramdisk_firmware_requests(serviced: &mut Vec<String>) {
        let Ok(entries) = fs::read_dir(FIRMWARE_CLASS_ROOT) else {
            return;
        };

        for entry in entries.flatten() {
            let filename = entry.file_name().to_string_lossy().to_string();
            if serviced.iter().any(|value| value == &filename) {
                continue;
            }
            if firmware_source_path(&filename).is_none() {
                continue;
            }
            match service_firmware_request_from_ramdisk(&filename) {
                Ok(firmware_path) => {
                    serviced.push(filename.clone());
                    append_wrapper_log(&format!(
                        "firmware-helper-ramdisk-ok filename={} source={}",
                        filename,
                        firmware_path.display()
                    ));
                }
                Err(error) => {
                    append_wrapper_log(&format!(
                        "firmware-helper-ramdisk-failed filename={} error={}",
                        filename, error
                    ));
                }
            }
        }
    }

    fn run_ramdisk_firmware_any_helper_loop(stop: Arc<AtomicBool>, label: &'static str) {
        let deadline = Instant::now() + Duration::from_secs(FIRMWARE_HELPER_TIMEOUT_SECONDS);
        let mut serviced = Vec::new();
        append_wrapper_log(&format!("{label}-firmware-helper-waiting"));

        while !stop.load(Ordering::Relaxed) && Instant::now() < deadline {
            service_available_ramdisk_firmware_requests(&mut serviced);
            thread::sleep(Duration::from_millis(FIRMWARE_HELPER_POLL_MILLIS));
        }

        let outcome = if stop.load(Ordering::Relaxed) {
            "stopped"
        } else {
            "timeout"
        };
        append_wrapper_log(&format!(
            "{label}-firmware-helper-{outcome} serviced={}",
            serviced.join(",")
        ));
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
                            Ok(_) => {
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
            "camera-hal-link-probe" => run_camera_hal_link_probe_internal(
                config,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
            ),
            "wifi-linux-surface-probe" => run_wifi_linux_surface_probe_internal(
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
                true,
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
            "shell-session" => ("flat-orange", false, false),
            "shell-session-held" => ("flat-orange", false, false),
            "app-direct-present" => ("flat-orange", false, false),
            "app-direct-present-touch-counter" => ("flat-orange", false, false),
            "app-direct-present-runtime-touch-counter" => ("flat-orange", false, false),
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
        kill_on_timeout: bool,
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
                        if kill_on_timeout {
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
        if config.orange_gpu_mode == "camera-hal-link-probe"
            && !config.orange_gpu_metadata_stage_breadcrumb
        {
            log_line("camera-hal-link-probe requires orange_gpu_metadata_stage_breadcrumb=true");
            return false;
        }
        if config.orange_gpu_mode == "wifi-linux-surface-probe"
            && !config.orange_gpu_metadata_stage_breadcrumb
        {
            log_line("wifi-linux-surface-probe requires orange_gpu_metadata_stage_breadcrumb=true");
            return false;
        }
        if config.wifi_association_probe && !config.wifi_supplicant_probe {
            log_line("wifi_association_probe requires wifi_supplicant_probe=true");
            return false;
        }
        if config.wifi_association_probe && config.wifi_credentials_path.is_empty() {
            log_line("wifi_association_probe requires wifi_credentials_path");
            return false;
        }
        if config.wifi_ip_probe && !config.wifi_supplicant_probe {
            log_line("wifi_ip_probe requires wifi_supplicant_probe=true");
            return false;
        }
        if config.wifi_ip_probe && config.wifi_credentials_path.is_empty() {
            log_line("wifi_ip_probe requires wifi_credentials_path");
            return false;
        }
        if config.wifi_ip_probe && config.wifi_dhcp_client_path.is_empty() {
            log_line("wifi_ip_probe requires wifi_dhcp_client_path");
            return false;
        }
        if config.wifi_runtime_network && config.wifi_bootstrap != "sunfish-wlan0" {
            log_line("wifi_runtime_network requires wifi_bootstrap=sunfish-wlan0");
            return false;
        }
        if config.wifi_runtime_network && config.wifi_credentials_path.is_empty() {
            log_line("wifi_runtime_network requires wifi_credentials_path");
            return false;
        }
        if config.wifi_runtime_network && config.wifi_dhcp_client_path.is_empty() {
            log_line("wifi_runtime_network requires wifi_dhcp_client_path");
            return false;
        }
        if config.orange_gpu_mode == "payload-partition-probe"
            && !config.orange_gpu_metadata_stage_breadcrumb
        {
            log_line("payload-partition-probe requires orange_gpu_metadata_stage_breadcrumb=true");
            return false;
        }
        if config.orange_gpu_mode == "payload-partition-probe" && config.run_token.is_empty() {
            log_line("payload-partition-probe requires run_token");
            return false;
        }
        if config.orange_gpu_mode == "payload-partition-probe"
            && config.payload_probe_strategy != PAYLOAD_PROBE_STRATEGY
        {
            log_line("payload-partition-probe requires payload_probe_strategy=metadata-shadow-payload-v1");
            return false;
        }
        if config.orange_gpu_mode == "payload-partition-probe"
            && config.payload_probe_source != PAYLOAD_PROBE_SOURCE
            && config.payload_probe_source != PAYLOAD_PROBE_LOGICAL_SOURCE
        {
            log_line(
                "payload-partition-probe requires payload_probe_source=metadata or shadow-logical-partition",
            );
            return false;
        }
        if config.orange_gpu_mode == "payload-partition-probe"
            && config.payload_probe_source == PAYLOAD_PROBE_LOGICAL_SOURCE
        {
            if !config.mount_sys {
                log_line(
                    "payload-partition-probe shadow-logical-partition requires mount_sys=true",
                );
                return false;
            }
            if config.payload_probe_root != SHADOW_PAYLOAD_MOUNT_PATH
                || config.payload_probe_manifest_path
                    != format!("{SHADOW_PAYLOAD_MOUNT_PATH}/manifest.env")
            {
                log_line(
                    "payload-partition-probe shadow-logical-partition requires root=/shadow-payload manifest=/shadow-payload/manifest.env",
                );
                return false;
            }
        }
        if config.orange_gpu_mode == "payload-partition-probe"
            && config.payload_probe_source == PAYLOAD_PROBE_SOURCE
            && config.payload_probe_root == SHADOW_PAYLOAD_MOUNT_PATH
        {
            log_line("payload-partition-probe /shadow-payload requires payload_probe_source=shadow-logical-partition");
            return false;
        }
        if orange_gpu_bundle_archive_needs_shadow_logical_payload(config) {
            if config.payload_probe_source != PAYLOAD_PROBE_LOGICAL_SOURCE {
                log_line("orange_gpu_bundle_archive_path under /shadow-payload requires payload_probe_source=shadow-logical-partition");
                return false;
            }
            if !config.mount_sys {
                log_line(
                    "orange_gpu_bundle_archive_path under /shadow-payload requires mount_sys=true",
                );
                return false;
            }
            if config.payload_probe_root != SHADOW_PAYLOAD_MOUNT_PATH
                || config.payload_probe_manifest_path
                    != format!("{SHADOW_PAYLOAD_MOUNT_PATH}/manifest.env")
            {
                log_line("orange_gpu_bundle_archive_path under /shadow-payload requires root=/shadow-payload manifest=/shadow-payload/manifest.env");
                return false;
            }
        }
        true
    }

    fn run_payload_partition_probe(
        config: &Config,
        metadata_stage: &mut MetadataStageRuntime,
    ) -> i32 {
        let probe_stage_path =
            if metadata_stage.enabled && metadata_stage.prepared && !metadata_stage.write_failed {
                Some(metadata_stage.probe_stage_path.clone())
            } else {
                None
            };
        let probe_stage_prefix = Some("payload-partition-probe".to_string());
        write_payload_probe_stage(
            probe_stage_path.as_deref(),
            probe_stage_prefix.as_deref(),
            "start",
        );

        let payload_root = payload_probe_root_path(config);
        let manifest_path = payload_probe_manifest_path(config, &payload_root);
        let fallback_path = if config.payload_probe_fallback_path.is_empty() {
            PAYLOAD_PROBE_FALLBACK_PATH
        } else {
            config.payload_probe_fallback_path.as_str()
        };
        let mut mounted_roots = Vec::new();
        if metadata_stage.prepared {
            mounted_roots.push(METADATA_MOUNT_PATH.to_string());
        }
        let mut shadow_logical_mount_error = String::new();
        match prepare_shadow_logical_payload_root(config, &payload_root) {
            Ok(true) => mounted_roots.push(SHADOW_PAYLOAD_MOUNT_PATH.to_string()),
            Ok(false) => {}
            Err(reason) => shadow_logical_mount_error = reason,
        }
        let mut userdata_mount_error = String::new();
        match prepare_userdata_payload_root(config, &payload_root) {
            Ok(true) => mounted_roots.push(USERDATA_MOUNT_PATH.to_string()),
            Ok(false) => {}
            Err(reason) => userdata_mount_error = reason,
        }

        let payload_root_present = payload_root.is_dir();
        let manifest_present = manifest_path.is_file();
        let mut manifest = PayloadProbeManifest {
            payload_source: config.payload_probe_source.clone(),
            ..PayloadProbeManifest::default()
        };
        let mut marker_path = payload_root.join(PAYLOAD_PROBE_DEFAULT_MARKER_NAME);
        let mut marker_fingerprint = String::new();
        let mut payload_fingerprint_verified = false;
        let mut marker_present = false;
        let mut ok = false;
        let mut blocker = "none".to_string();
        let mut blocker_detail = String::new();

        if !metadata_stage.prepared {
            blocker = "metadata-stage-unprepared".to_string();
            blocker_detail = "metadata partition was not mounted for the payload probe".to_string();
        } else if !shadow_logical_mount_error.is_empty() {
            blocker = "shadow-logical-mount-failed".to_string();
            blocker_detail = shadow_logical_mount_error.clone();
        } else if !userdata_mount_error.is_empty() {
            blocker = "userdata-mount-failed".to_string();
            blocker_detail = userdata_mount_error.clone();
        } else if config.payload_probe_strategy != PAYLOAD_PROBE_STRATEGY {
            blocker = "payload-probe-strategy-unsupported".to_string();
            blocker_detail = config.payload_probe_strategy.clone();
        } else if config.payload_probe_source != PAYLOAD_PROBE_SOURCE
            && config.payload_probe_source != PAYLOAD_PROBE_LOGICAL_SOURCE
        {
            blocker = "payload-probe-source-unsupported".to_string();
            blocker_detail = config.payload_probe_source.clone();
        } else if !payload_root_present {
            blocker = "payload-root-missing".to_string();
            blocker_detail = payload_root.display().to_string();
        } else if !manifest_present {
            blocker = "payload-manifest-missing".to_string();
            blocker_detail = manifest_path.display().to_string();
        } else {
            match read_payload_probe_manifest(&manifest_path) {
                Ok(parsed_manifest) => {
                    marker_path = payload_probe_marker_path(&payload_root, &parsed_manifest);
                    manifest = parsed_manifest;
                    if manifest.payload_root.is_empty() {
                        manifest.payload_root = payload_root.display().to_string();
                    }
                    if manifest.payload_root != payload_root.display().to_string() {
                        blocker = "payload-root-mismatch".to_string();
                        blocker_detail = format!(
                            "manifest={} expected={}",
                            manifest.payload_root,
                            payload_root.display()
                        );
                    } else if marker_path.is_absolute() && !marker_path.starts_with(&payload_root) {
                        blocker = "payload-marker-outside-root".to_string();
                        blocker_detail = marker_path.display().to_string();
                    } else if !marker_path.is_file() {
                        blocker = "payload-marker-missing".to_string();
                        blocker_detail = marker_path.display().to_string();
                    } else {
                        marker_present = true;
                        match sha256_file_fingerprint(&marker_path) {
                            Ok(fingerprint) => {
                                marker_fingerprint = fingerprint;
                                if marker_fingerprint != manifest.payload_fingerprint {
                                    blocker = "payload-marker-fingerprint-mismatch".to_string();
                                    blocker_detail = format!(
                                        "manifest={} actual={}",
                                        manifest.payload_fingerprint, marker_fingerprint
                                    );
                                } else {
                                    payload_fingerprint_verified = true;
                                    ok = true;
                                }
                            }
                            Err(reason) => {
                                blocker = "payload-marker-fingerprint-read-failed".to_string();
                                blocker_detail = reason;
                            }
                        }
                    }
                }
                Err(reason) => {
                    blocker = "payload-manifest-invalid".to_string();
                    blocker_detail = reason;
                }
            }
        }

        let stage = if ok {
            "payload-mounted"
        } else {
            "payload-blocked"
        };
        write_payload_probe_stage(
            probe_stage_path.as_deref(),
            probe_stage_prefix.as_deref(),
            stage,
        );

        let status = if ok { 0 } else { 1 };
        let summary = format!(
            concat!(
                "{{\n",
                "  \"kind\": \"payload-partition-probe\",\n",
                "  \"ok\": {},\n",
                "  \"payload_strategy\": {},\n",
                "  \"payload_source\": {},\n",
                "  \"payload_root\": {},\n",
                "  \"payload_manifest_path\": {},\n",
                "  \"payload_marker_path\": {},\n",
                "  \"payload_version\": {},\n",
                "  \"payload_fingerprint\": {},\n",
                "  \"payload_marker_fingerprint\": {},\n",
                "  \"payload_fingerprint_verified\": {},\n",
                "  \"mounted_roots\": {},\n",
                "  \"fallback_path\": {},\n",
                "  \"blocker\": {},\n",
                "  \"blocker_detail\": {},\n",
                "  \"metadata_stage_prepared\": {},\n",
                "  \"userdata_mount_error\": {},\n",
                "  \"shadow_logical_mount_error\": {},\n",
                "  \"payload_root_present\": {},\n",
                "  \"manifest_present\": {},\n",
                "  \"marker_present\": {}\n",
                "}}\n"
            ),
            bool_word(ok),
            json_string(&config.payload_probe_strategy),
            json_string(&manifest.payload_source),
            json_string(&payload_root.display().to_string()),
            json_string(&manifest_path.display().to_string()),
            json_string(&marker_path.display().to_string()),
            json_string(&manifest.payload_version),
            json_string(&manifest.payload_fingerprint),
            json_string(&marker_fingerprint),
            bool_word(payload_fingerprint_verified),
            json_string_array(&mounted_roots),
            json_string(fallback_path),
            json_string(&blocker),
            json_string(&blocker_detail),
            bool_word(metadata_stage.prepared),
            json_string(&userdata_mount_error),
            json_string(&shadow_logical_mount_error),
            bool_word(payload_root_present),
            bool_word(manifest_present),
            bool_word(marker_present),
        );
        if write_atomic_text_file(
            &metadata_stage.temp_probe_summary_path,
            &metadata_stage.probe_summary_path,
            &summary,
        )
        .is_err()
        {
            metadata_stage.write_failed = true;
            return 1;
        }

        let probe_result = ChildWatchResult {
            completed: true,
            timed_out: false,
            waited_seconds: 0,
            exit_status: Some(status),
            signal: None,
            raw_wait_status: 0,
        };
        write_probe_report(
            metadata_stage,
            "payload-partition-probe",
            probe_stage_path.as_deref(),
            &probe_result,
            None,
            false,
            0,
        );
        status
    }

    fn run_orange_gpu_payload(
        config: &Config,
        metadata_stage: &mut MetadataStageRuntime,
        self_exec_path: Option<&Path>,
    ) -> i32 {
        if ensure_orange_gpu_runtime_dirs().is_err() {
            return 1;
        }
        if orange_gpu_bundle_archive_needs_shadow_logical_payload(config) {
            match prepare_shadow_logical_payload_root(config, Path::new(SHADOW_PAYLOAD_MOUNT_PATH))
            {
                Ok(true) => {
                    if metadata_stage.prepared {
                        write_payload_probe_stage(
                            Some(&metadata_stage.probe_stage_path),
                            Some("orange-gpu-bundle"),
                            "shadow-logical-mounted",
                        );
                    }
                }
                Ok(false) => {}
                Err(error) => {
                    log_line(&format!(
                        "failed to mount shadow logical payload for orange-gpu bundle: {error}"
                    ));
                    return 1;
                }
            }
        }
        if let Err(error) = expand_orange_gpu_bundle_archive(config) {
            log_line(&format!(
                "failed to expand orange-gpu bundle archive: {error}"
            ));
            return 1;
        }

        if config.orange_gpu_launch_delay_secs > 0 {
            sleep_seconds(config.orange_gpu_launch_delay_secs);
        }

        if config.orange_gpu_mode == "payload-partition-probe" {
            return run_payload_partition_probe(config, metadata_stage);
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
                | "camera-hal-link-probe"
                | "wifi-linux-surface-probe"
                | "c-kgsl-open-readonly-smoke"
                | "c-kgsl-open-readonly-firmware-helper-smoke"
        );

        let mut wifi_runtime_network: Option<WifiRuntimeNetwork> = None;
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
            if config.wifi_runtime_network {
                write_payload_probe_stage(
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                    "wifi-runtime-network-start",
                );
                let runtime_start = start_wifi_runtime_network(
                    config,
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                );
                append_wrapper_log(&format!(
                    "wifi-runtime-network-start {}",
                    runtime_start.json
                ));
                if !runtime_start.completed {
                    log_line("wifi runtime network failed before payload launch");
                    if let Some(helper) = firmware_helper {
                        helper.stop();
                    }
                    return 1;
                }
                wifi_runtime_network = runtime_start.network;
                write_payload_probe_stage(
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                    "wifi-runtime-network-ready",
                );
            }

            if orange_gpu_mode_uses_session_frame_capture(&config.orange_gpu_mode) {
                let session_config_path =
                    if orange_gpu_mode_is_compositor_scene(&config.orange_gpu_mode) {
                        ORANGE_GPU_COMPOSITOR_STARTUP_CONFIG_PATH
                    } else if orange_gpu_mode_is_shell_session(&config.orange_gpu_mode) {
                        ORANGE_GPU_SHELL_SESSION_STARTUP_CONFIG_PATH
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
                if orange_gpu_mode_is_shell_session(&config.orange_gpu_mode) {
                    command.env(GUEST_COMPOSITOR_LOADER_ENV, ORANGE_GPU_LOADER_PATH);
                    command.env(GUEST_COMPOSITOR_LIBRARY_PATH_ENV, ORANGE_GPU_LIBRARY_PATH);
                }
                command.env(
                    "RUST_LOG",
                    "shadow_session=info,shadow_compositor_guest=info,smithay=warn",
                );
                if !orange_gpu_mode_is_compositor_scene(&config.orange_gpu_mode)
                    && !config.app_direct_present_runtime_bundle_env.is_empty()
                    && !config.app_direct_present_runtime_bundle_path.is_empty()
                {
                    command.env(
                        &config.app_direct_present_runtime_bundle_env,
                        &config.app_direct_present_runtime_bundle_path,
                    );
                    command.env(SYSTEM_STAGE_LOADER_PATH_ENV, ORANGE_GPU_LOADER_PATH);
                    command.env(SYSTEM_STAGE_LIBRARY_PATH_ENV, ORANGE_GPU_LIBRARY_PATH);
                }
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
                stop_wifi_runtime_network(
                    &mut wifi_runtime_network,
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                    "payload-spawn-failed",
                );
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
            config.orange_gpu_timeout_action != "hold",
            Some(&mut timeout_observer),
        ) {
            Ok(result) => result,
            Err(error) => {
                log_line(&format!("orange-gpu wait failed: {error}"));
                stop_wifi_runtime_network(
                    &mut wifi_runtime_network,
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                    "payload-wait-failed",
                );
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
        if orange_gpu_mode_is_shell_session_held(&config.orange_gpu_mode) && !watch_result.timed_out
        {
            log_line("held shell-session exited before the watchdog proof window");
            let _ = run_orange_gpu_checkpoint(
                config,
                "child-exit-nonzero",
                ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
            );
            stop_wifi_runtime_network(
                &mut wifi_runtime_network,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
                "held-shell-exited-before-watchdog",
            );
            return 125;
        }
        let wifi_linux_surface_blocked = config.orange_gpu_mode == "wifi-linux-surface-probe"
            && watch_result.exit_status == Some(2);
        if (watch_result.exit_status == Some(0) || wifi_linux_surface_blocked)
            && metadata_stage.enabled
        {
            if orange_gpu_mode_uses_session_frame_capture(&config.orange_gpu_mode) {
                let (summary_kind, startup_mode, app_id, stage_name, touch_counter_profile) =
                    if orange_gpu_mode_is_compositor_scene(&config.orange_gpu_mode) {
                        (
                            "compositor-scene",
                            "shell",
                            None,
                            "compositor-scene-frame-captured",
                            None,
                        )
                    } else if orange_gpu_mode_is_shell_session(&config.orange_gpu_mode) {
                        if orange_gpu_mode_is_shell_session_runtime_touch_counter(
                            &config.orange_gpu_mode,
                        ) {
                            let injection = if config.app_direct_present_manual_touch {
                                "physical-touch"
                            } else {
                                "synthetic-compositor"
                            };
                            (
                                "shell-session-runtime-touch-counter",
                                "shell",
                                Some("counter"),
                                "shell-session-runtime-touch-counter-proved",
                                Some(TouchCounterEvidenceProfile::runtime_counter(
                                    injection,
                                    "wrote-frame-artifact frame_marker=hosted-touch-",
                                    "[shadow-guest-compositor] touch-latency-present",
                                )),
                            )
                        } else {
                            (
                                "shell-session",
                                "shell",
                                Some(config.shell_session_start_app_id.as_str()),
                                "shell-session-app-frame-captured",
                                None,
                            )
                        }
                    } else if orange_gpu_mode_is_app_direct_present_runtime_touch_counter(
                        &config.orange_gpu_mode,
                    ) {
                        let injection = if config.app_direct_present_manual_touch {
                            "physical-touch"
                        } else {
                            "synthetic-compositor"
                        };
                        (
                            "app-direct-present-runtime-touch-counter",
                            "app",
                            Some("counter"),
                            "app-direct-present-runtime-touch-counter-proved",
                            Some(TouchCounterEvidenceProfile::runtime_counter(
                                injection,
                                "[shadow-guest-compositor] wrote-frame-artifact",
                                "[shadow-guest-compositor] touch-latency-present",
                            )),
                        )
                    } else if orange_gpu_mode_is_app_direct_present_touch_counter(
                        &config.orange_gpu_mode,
                    ) {
                        let injection = if config.app_direct_present_manual_touch {
                            "physical-touch"
                        } else {
                            "synthetic-compositor"
                        };
                        (
                            "app-direct-present-touch-counter",
                            "app",
                            Some("rust-demo"),
                            "app-direct-present-touch-counter-proved",
                            Some(TouchCounterEvidenceProfile::rust_counter(injection)),
                        )
                    } else {
                        (
                            "app-direct-present",
                            "app",
                            Some(config.app_direct_present_app_id.as_str()),
                            "app-direct-present-frame-captured",
                            None,
                        )
                    };
                if let Err(reason) = record_session_frame_summary(
                    metadata_stage,
                    summary_kind,
                    startup_mode,
                    app_id,
                    touch_counter_profile,
                ) {
                    log_line(&format!(
                        "{summary_kind} frame missing or could not be summarized: {reason}"
                    ));
                    let _ = run_orange_gpu_checkpoint(
                        config,
                        "child-exit-nonzero",
                        ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
                    );
                    stop_wifi_runtime_network(
                        &mut wifi_runtime_network,
                        probe_stage_path.as_deref(),
                        probe_stage_prefix.as_deref(),
                        "session-frame-summary-failed",
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
                if config.orange_gpu_mode == "wifi-linux-surface-probe"
                    && recorded_summary.is_none()
                {
                    log_line(
                        "wifi-linux-surface-probe summary missing or could not be persisted to metadata",
                    );
                }
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
                        stop_wifi_runtime_network(
                            &mut wifi_runtime_network,
                            probe_stage_path.as_deref(),
                            probe_stage_prefix.as_deref(),
                            "gpu-render-summary-missing",
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
                        stop_wifi_runtime_network(
                            &mut wifi_runtime_network,
                            probe_stage_path.as_deref(),
                            probe_stage_prefix.as_deref(),
                            "gpu-render-summary-invalid",
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
                        stop_wifi_runtime_network(
                            &mut wifi_runtime_network,
                            probe_stage_path.as_deref(),
                            probe_stage_prefix.as_deref(),
                            "orange-gpu-loop-summary-missing",
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
                        stop_wifi_runtime_network(
                            &mut wifi_runtime_network,
                            probe_stage_path.as_deref(),
                            probe_stage_prefix.as_deref(),
                            "orange-gpu-loop-summary-invalid",
                        );
                        return 1;
                    }
                }
            }
        }

        if watch_result.timed_out {
            if orange_gpu_mode_is_shell_session_held(&config.orange_gpu_mode)
                && metadata_stage.enabled
            {
                let summary_kind = "shell-session-held";
                let touch_counter_profile =
                    if orange_gpu_config_is_held_runtime_touch_counter(config) {
                        let injection = if config.app_direct_present_manual_touch {
                            "physical-touch"
                        } else {
                            "synthetic-compositor"
                        };
                        Some(TouchCounterEvidenceProfile::runtime_counter(
                            injection,
                            "wrote-frame-artifact frame_marker=hosted-touch-",
                            "[shadow-guest-compositor] touch-latency-present",
                        ))
                    } else {
                        None
                    };
                if let Err(reason) = record_session_frame_summary(
                    metadata_stage,
                    summary_kind,
                    "shell",
                    Some(config.shell_session_start_app_id.as_str()),
                    touch_counter_profile,
                ) {
                    log_line(&format!(
                        "{summary_kind} watchdog proof missing or could not be summarized: {reason}"
                    ));
                } else {
                    write_payload_probe_stage(
                        probe_stage_path.as_deref(),
                        probe_stage_prefix.as_deref(),
                        "shell-session-held-watchdog-proved",
                    );
                    if config.orange_gpu_timeout_action == "hold" {
                        log_line(
                            "held shell-session proof recorded; holding boot-owned session for operator observation",
                        );
                        hold_for_observation(config.hold_seconds);
                    }
                    stop_wifi_runtime_network(
                        &mut wifi_runtime_network,
                        probe_stage_path.as_deref(),
                        probe_stage_prefix.as_deref(),
                        "held-shell-watchdog-proved",
                    );
                    return 0;
                }
            }
            stop_wifi_runtime_network(
                &mut wifi_runtime_network,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
                "payload-timed-out",
            );
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
            stop_wifi_runtime_network(
                &mut wifi_runtime_network,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
                "payload-exited",
            );
            return exit_status;
        }
        if let Some(signal) = watch_result.signal {
            let _ = run_orange_gpu_checkpoint(
                config,
                "child-signal",
                ORANGE_GPU_CHECKPOINT_HOLD_SECONDS,
            );
            stop_wifi_runtime_network(
                &mut wifi_runtime_network,
                probe_stage_path.as_deref(),
                probe_stage_prefix.as_deref(),
                "payload-signaled",
            );
            return 128 + signal;
        }
        stop_wifi_runtime_network(
            &mut wifi_runtime_network,
            probe_stage_path.as_deref(),
            probe_stage_prefix.as_deref(),
            "payload-unknown-result",
        );
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

    fn android_ipc_nodes_for_config(config: &Config) -> &'static [&'static str] {
        if config.wifi_bootstrap == "sunfish-wlan0" {
            return match config.wifi_helper_profile.as_str() {
                "aidl-sm-core" => &["binder"],
                "vnd-sm-core" => &["vndbinder"],
                // Proven Pixel 4a scan seam: vndservicemanager owns the
                // vendor Binder registry for PM/CNSS, while /dev/binder is
                // only exposed so vendor wpa_supplicant's AIDL ProcessState
                // can initialize. No framework servicemanager is started.
                "vnd-sm-core-binder-node" => &["vndbinder", "binder"],
                "all-sm-core" | "full" => &["vndbinder", "hwbinder", "binder"],
                "none" => &[],
                _ => &["vndbinder", "hwbinder", "binder"],
            };
        }
        if config.orange_gpu_mode == "camera-hal-link-probe" {
            return &["vndbinder", "hwbinder", "binder"];
        }
        &[]
    }

    fn bootstrap_tmpfs_android_ipc_runtime(config: &Config) -> io::Result<()> {
        let android_ipc_nodes = android_ipc_nodes_for_config(config);
        if android_ipc_nodes.is_empty() || !config.mount_dev || config.dev_mount != "tmpfs" {
            return Ok(());
        }
        for name in android_ipc_nodes {
            let sysfs_path = format!("/sys/class/misc/{name}/dev");
            let device_path = format!("/dev/{name}");
            ensure_char_device_from_sysfs(Path::new(&sysfs_path), Path::new(&device_path), 0o666)?;
        }
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
            ensure_char_device(Path::new("/dev/ion"), 0o666, 10, 63)?;
        }
        Ok(())
    }

    fn bootstrap_tmpfs_camera_runtime(config: &Config) -> io::Result<()> {
        if !config.mount_dev
            || config.dev_mount != "tmpfs"
            || config.orange_gpu_mode != "camera-hal-link-probe"
        {
            return Ok(());
        }

        let video_nodes = [(0, 0), (1, 1), (2, 2), (32, 32), (33, 33), (34, 34)];
        for (index, minor) in video_nodes {
            ensure_char_device(Path::new(&format!("/dev/video{index}")), 0o660, 81, minor)?;
        }
        ensure_char_device(Path::new("/dev/media0"), 0o660, 247, 0)?;
        ensure_char_device(Path::new("/dev/media1"), 0o660, 247, 1)?;
        for index in 0..=16 {
            ensure_char_device(
                Path::new(&format!("/dev/v4l-subdev{index}")),
                0o660,
                81,
                128 + index,
            )?;
        }
        ensure_char_device(Path::new("/dev/ion"), 0o666, 10, 63)?;
        Ok(())
    }

    fn insert_kernel_module_from_path(path: &Path) -> io::Result<()> {
        let params = CString::new("").unwrap();
        let file = File::open(path)?;
        let rc =
            unsafe { libc::syscall(libc::SYS_finit_module, file.as_raw_fd(), params.as_ptr(), 0) };
        if rc == 0 {
            return Ok(());
        }

        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EEXIST) {
            return Ok(());
        }
        if error.raw_os_error() != Some(libc::ENOSYS) {
            return Err(error);
        }

        let module = fs::read(path)?;
        let rc = unsafe {
            libc::syscall(
                libc::SYS_init_module,
                module.as_ptr(),
                module.len(),
                params.as_ptr(),
            )
        };
        if rc == 0 {
            Ok(())
        } else {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EEXIST) {
                Ok(())
            } else {
                Err(error)
            }
        }
    }

    fn load_sunfish_touch_modules() -> io::Result<()> {
        for module in SUNFISH_TOUCH_MODULES {
            let module_path = Path::new("/lib/modules").join(module);
            append_wrapper_log(&format!(
                "input-bootstrap-module-loading module={} path={}",
                module,
                module_path.display()
            ));
            insert_kernel_module_from_path(&module_path).map_err(|error| {
                append_wrapper_log(&format!(
                    "input-bootstrap-module-failed module={} error={}",
                    module, error
                ));
                error
            })?;
            append_wrapper_log(&format!("input-bootstrap-module-ready module={module}"));
        }
        Ok(())
    }

    fn load_sunfish_wifi_modules(
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> io::Result<()> {
        for module in ["wlan.ko"] {
            let module_path = Path::new("/lib/modules").join(module);
            append_wrapper_log(&format!(
                "wifi-bootstrap-module-loading module={} path={}",
                module,
                module_path.display()
            ));
            write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-module-loading");
            insert_kernel_module_from_path(&module_path).map_err(|error| {
                append_wrapper_log(&format!(
                    "wifi-bootstrap-module-failed module={} error={}",
                    module, error
                ));
                write_payload_probe_stage(
                    probe_stage_path,
                    probe_stage_prefix,
                    "wifi-module-failed",
                );
                error
            })?;
            append_wrapper_log(&format!("wifi-bootstrap-module-ready module={module}"));
            write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-module-ready");
        }
        Ok(())
    }

    fn ensure_char_device_from_sysfs(
        sysfs_dev_path: &Path,
        device_path: &Path,
        mode: u32,
    ) -> io::Result<(u64, u64)> {
        let dev = fs::read_to_string(sysfs_dev_path)?;
        let Some((major, minor)) = dev.trim().split_once(':') else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid sysfs dev value at {}", sysfs_dev_path.display()),
            ));
        };
        let major = major.parse::<u64>().map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid major at {}: {error}", sysfs_dev_path.display()),
            )
        })?;
        let minor = minor.parse::<u64>().map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid minor at {}: {error}", sysfs_dev_path.display()),
            )
        })?;
        ensure_char_device(device_path, mode, major, minor)?;
        Ok((major, minor))
    }

    fn ensure_sunfish_subsystem_node(name: &str) -> io::Result<(String, u64, u64)> {
        let sysfs_dev_path = format!("/sys/class/subsys/subsys_{name}/dev");
        let device_path = format!("/dev/subsys_{name}");
        let (major, minor) = ensure_char_device_from_sysfs(
            Path::new(&sysfs_dev_path),
            Path::new(&device_path),
            0o660,
        )?;
        Ok((device_path, major, minor))
    }

    fn open_sunfish_subsystem(
        name: &str,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> io::Result<File> {
        let (device_path, major, minor) = ensure_sunfish_subsystem_node(name)?;
        append_wrapper_log(&format!(
            "wifi-bootstrap-subsys-node name={} device={} major={} minor={}",
            name, device_path, major, minor
        ));
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            &format!("wifi-subsys-{name}-opening"),
        );
        let file = File::open(&device_path).map_err(|error| {
            append_wrapper_log(&format!(
                "wifi-bootstrap-subsys-open-failed name={} error={}",
                name, error
            ));
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                &format!("wifi-subsys-{name}-open-failed"),
            );
            error
        })?;
        append_wrapper_log(&format!(
            "wifi-bootstrap-subsys-opened name={} device={}",
            name, device_path
        ));
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            &format!("wifi-subsys-{name}-opened"),
        );
        Ok(file)
    }

    fn prepare_sunfish_wifi_android_runtime_dirs() {
        let dirs = [
            ("/dev/socket", 0o755),
            ("/dev/socket/qmux_radio", 0o770),
            ("/data", 0o771),
            ("/data/vendor", 0o771),
            ("/data/vendor/firmware", 0o770),
            ("/data/vendor/firmware/wifi", 0o750),
            ("/data/vendor/pddump", 0o770),
            ("/data/vendor/rfs", 0o770),
            ("/data/vendor/rfs/mpss", 0o770),
            ("/data/vendor/tombstones", 0o770),
            ("/data/vendor/tombstones/rfs", 0o770),
            ("/data/vendor/tombstones/rfs/modem", 0o770),
            ("/data/vendor/tombstones/rfs/lpass", 0o770),
            ("/data/vendor/tombstones/rfs/tn", 0o770),
            ("/data/vendor/tombstones/rfs/slpi", 0o770),
            ("/data/vendor/tombstones/rfs/cdsp", 0o770),
            ("/data/vendor/tombstones/rfs/wpss", 0o770),
            ("/data/vendor/wifi", 0o771),
            ("/data/vendor/wifi/wpa", 0o770),
            ("/data/vendor/wifi/wpa/sockets", 0o770),
            ("/data/vendor/wifidump", 0o771),
            ("/mnt", 0o755),
            ("/mnt/vendor", 0o755),
            ("/mnt/vendor/persist", 0o771),
            ("/mnt/vendor/persist/hlos_rfs", 0o770),
            ("/mnt/vendor/persist/hlos_rfs/shared", 0o770),
            ("/mnt/vendor/persist/rfs", 0o770),
            ("/mnt/vendor/persist/rfs/shared", 0o770),
            ("/mnt/vendor/persist/rfs/msm", 0o770),
            ("/mnt/vendor/persist/rfs/msm/adsp", 0o770),
            ("/mnt/vendor/persist/rfs/msm/mpss", 0o770),
            ("/mnt/vendor/persist/rfs/msm/slpi", 0o770),
            ("/mnt/vendor/persist/rfs/mdm", 0o770),
            ("/mnt/vendor/persist/rfs/mdm/adsp", 0o770),
            ("/mnt/vendor/persist/rfs/mdm/mpss", 0o770),
            ("/mnt/vendor/persist/rfs/mdm/slpi", 0o770),
            ("/mnt/vendor/persist/rfs/mdm/tn", 0o770),
            ("/mnt/vendor/persist/rfs/apq", 0o770),
            ("/mnt/vendor/persist/rfs/apq/gnss", 0o770),
            ("/tombstones", 0o755),
            ("/tombstones/wcnss", 0o771),
            ("/sys/fs/selinux", 0o755),
            ("/vendor/rfs", 0o755),
            ("/vendor/rfs/msm", 0o755),
            ("/vendor/rfs/msm/mpss", 0o755),
        ];
        for (path, mode) in dirs {
            let _ = ensure_directory(Path::new(path), mode);
        }
        for (path, uid, gid) in [
            ("/data/vendor/rfs", 2903, 2903),
            ("/data/vendor/rfs/mpss", 2903, 2903),
            ("/data/vendor/wifi", 1010, 1010),
            ("/data/vendor/wifi/wpa", 1010, 1010),
            ("/data/vendor/wifi/wpa/sockets", 1010, 1010),
            ("/data/vendor/tombstones/rfs", 2903, 2903),
            ("/data/vendor/tombstones/rfs/modem", 2903, 2903),
            ("/data/vendor/tombstones/rfs/lpass", 2903, 2903),
            ("/data/vendor/tombstones/rfs/tn", 2903, 2903),
            ("/data/vendor/tombstones/rfs/slpi", 2903, 2903),
            ("/data/vendor/tombstones/rfs/cdsp", 2903, 2903),
            ("/data/vendor/tombstones/rfs/wpss", 2903, 2903),
            ("/mnt/vendor/persist/rfs", 0, 1000),
            ("/mnt/vendor/persist/rfs/shared", 0, 1000),
            ("/mnt/vendor/persist/rfs/msm", 0, 1000),
            ("/mnt/vendor/persist/rfs/msm/mpss", 0, 1000),
            ("/mnt/vendor/persist/hlos_rfs", 0, 1000),
            ("/mnt/vendor/persist/hlos_rfs/shared", 0, 1000),
        ] {
            let Ok(c_path) = CString::new(path) else {
                continue;
            };
            let rc = unsafe { libc::chown(c_path.as_ptr(), uid, gid) };
            if rc != 0 {
                append_wrapper_log(&format!(
                    "wifi-bootstrap-rfs-chown-failed path={} error={}",
                    path,
                    io::Error::last_os_error()
                ));
            }
        }
        for (path, target) in [
            ("/vendor/rfs/msm/mpss/readwrite", "/data/vendor/rfs/mpss"),
            (
                "/vendor/rfs/msm/mpss/ramdumps",
                "/data/vendor/tombstones/rfs/modem",
            ),
            (
                "/vendor/rfs/msm/mpss/hlos",
                "/mnt/vendor/persist/hlos_rfs/shared",
            ),
            (
                "/vendor/rfs/msm/mpss/shared",
                "/mnt/vendor/persist/rfs/shared",
            ),
        ] {
            if !Path::new(path).exists() {
                if let Err(error) = ensure_symlink_target(Path::new(path), Path::new(target)) {
                    append_wrapper_log(&format!(
                        "wifi-bootstrap-rfs-symlink-failed path={} target={} error={}",
                        path, target, error
                    ));
                }
            }
        }
        for (path, mode, major, minor) in [
            ("/dev/null", 0o666, 1, 3),
            ("/dev/zero", 0o666, 1, 5),
            ("/dev/random", 0o666, 1, 8),
            ("/dev/urandom", 0o666, 1, 9),
        ] {
            if let Err(error) = ensure_char_device(Path::new(path), mode, major, minor) {
                append_wrapper_log(&format!(
                    "wifi-bootstrap-android-dev-node-failed path={} error={}",
                    path, error
                ));
            }
        }
        if !Path::new("/sys/fs/selinux/status").exists() {
            match mount_fs("selinuxfs", "/sys/fs/selinux", "selinuxfs", 0, None) {
                Ok(()) => append_wrapper_log("wifi-bootstrap-selinuxfs-mounted"),
                Err(error) => append_wrapper_log(&format!(
                    "wifi-bootstrap-selinuxfs-mount-failed error={error}"
                )),
            }
        }
    }

    fn load_sunfish_wifi_selinux_policy(
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) {
        let policy_path = Path::new("/vendor/etc/selinux/precompiled_sepolicy");
        let load_path = Path::new("/sys/fs/selinux/load");
        if !policy_path.is_file() {
            append_wrapper_log("wifi-bootstrap-selinux-policy-missing path=/vendor/etc/selinux/precompiled_sepolicy");
            return;
        }
        if !load_path.exists() {
            append_wrapper_log(
                "wifi-bootstrap-selinux-policy-load-missing path=/sys/fs/selinux/load",
            );
            return;
        }
        let policy = match fs::read(policy_path) {
            Ok(policy) => policy,
            Err(error) => {
                append_wrapper_log(&format!(
                    "wifi-bootstrap-selinux-policy-read-failed error={error}"
                ));
                return;
            }
        };
        match OpenOptions::new()
            .write(true)
            .open(load_path)
            .and_then(|mut file| file.write_all(&policy))
        {
            Ok(()) => {
                append_wrapper_log(&format!(
                    "wifi-bootstrap-selinux-policy-loaded bytes={}",
                    policy.len()
                ));
                write_payload_probe_stage(
                    probe_stage_path,
                    probe_stage_prefix,
                    "wifi-selinux-policy-loaded",
                );
            }
            Err(error) => append_wrapper_log(&format!(
                "wifi-bootstrap-selinux-policy-load-failed error={error}"
            )),
        }
    }

    fn create_sunfish_android_core_device_nodes() {
        for (name, sysfs_path, device_path, mode) in [
            (
                "qseecom",
                "/sys/class/qseecom/qseecom/dev",
                "/dev/qseecom",
                0o660,
            ),
            (
                "smcinvoke",
                "/sys/class/smcinvoke/smcinvoke/dev",
                "/dev/smcinvoke",
                0o600,
            ),
            ("ion", "/sys/class/misc/ion/dev", "/dev/ion", 0o664),
            (
                "adsprpc-smd",
                "/sys/class/fastrpc/adsprpc-smd/dev",
                "/dev/adsprpc-smd",
                0o664,
            ),
            ("ipa", "/sys/class/ipa/ipa/dev", "/dev/ipa", 0o660),
            (
                "ipaNatTable",
                "/sys/class/ipaNatTable/ipaNatTable/dev",
                "/dev/ipaNatTable",
                0o660,
            ),
            (
                "ipa_adpl",
                "/sys/class/ipa_adpl/ipa_adpl/dev",
                "/dev/ipa_adpl",
                0o660,
            ),
        ] {
            match ensure_char_device_from_sysfs(Path::new(sysfs_path), Path::new(device_path), mode)
            {
                Ok((major, minor)) => append_wrapper_log(&format!(
                    "wifi-bootstrap-android-node name={} device={} major={} minor={}",
                    name, device_path, major, minor
                )),
                Err(error) => append_wrapper_log(&format!(
                    "wifi-bootstrap-android-node-failed name={} device={} error={}",
                    name, device_path, error
                )),
            }
        }
    }

    fn trigger_sunfish_ipa_firmware_load() {
        match OpenOptions::new()
            .write(true)
            .open("/dev/ipa")
            .and_then(|mut file| file.write_all(b"1"))
        {
            Ok(()) => append_wrapper_log("wifi-bootstrap-ipa-triggered path=/dev/ipa"),
            Err(error) => {
                append_wrapper_log(&format!("wifi-bootstrap-ipa-trigger-failed error={error}"))
            }
        }
    }

    fn find_block_device_by_partname(partname: &str) -> Option<(u32, u32)> {
        let entries = fs::read_dir(METADATA_SYSFS_BLOCK_ROOT).ok()?;
        for entry in entries.flatten() {
            let Ok(text) = fs::read_to_string(entry.path().join("uevent")) else {
                continue;
            };
            let mut partname_matches = false;
            let mut major_num = None;
            let mut minor_num = None;
            for line in text.lines() {
                if let Some(value) = line.strip_prefix("PARTNAME=") {
                    partname_matches = value == partname;
                } else if let Some(value) = line.strip_prefix("MAJOR=") {
                    major_num = value.parse::<u32>().ok();
                } else if let Some(value) = line.strip_prefix("MINOR=") {
                    minor_num = value.parse::<u32>().ok();
                }
            }
            if partname_matches {
                if let (Some(major_num), Some(minor_num)) = (major_num, minor_num) {
                    return Some((major_num, minor_num));
                }
            }
        }
        None
    }

    fn mount_sunfish_modem_firmware_partition(
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> io::Result<()> {
        if Path::new("/vendor/firmware_mnt/image/modem.mdt").is_file() {
            return Ok(());
        }
        ensure_directory(Path::new("/dev/block/by-name"), 0o755)?;
        ensure_directory(Path::new("/vendor"), 0o755)?;
        ensure_directory(Path::new("/vendor/firmware_mnt"), 0o755)?;

        for partname in sunfish_modem_partition_order() {
            let Some((major, minor)) = find_block_device_by_partname(partname) else {
                continue;
            };
            let device_path = Path::new("/dev/block/by-name").join(partname);
            ensure_block_device(&device_path, 0o600, major as u64, minor as u64)?;
            match mount_fs(
                device_path.to_string_lossy().as_ref(),
                "/vendor/firmware_mnt",
                "vfat",
                libc::MS_RDONLY,
                None,
            ) {
                Ok(()) => {
                    append_wrapper_log(&format!(
                        "wifi-bootstrap-modem-firmware-mounted part={} device={} major={} minor={}",
                        partname,
                        device_path.display(),
                        major,
                        minor
                    ));
                    write_payload_probe_stage(
                        probe_stage_path,
                        probe_stage_prefix,
                        "wifi-modem-firmware-mounted",
                    );
                    return Ok(());
                }
                Err(error) => {
                    append_wrapper_log(&format!(
                        "wifi-bootstrap-modem-firmware-mount-failed part={} error={}",
                        partname, error
                    ));
                }
            }
        }

        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-modem-firmware-mount-failed",
        );
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            "unable to mount sunfish modem firmware partition",
        ))
    }

    fn sunfish_modem_partition_order() -> [&'static str; 2] {
        let cmdline = fs::read_to_string("/proc/cmdline").unwrap_or_default();
        if cmdline.contains("androidboot.slot_suffix=_b")
            || cmdline.contains("androidboot.slot=b")
            || cmdline.contains("androidboot.slot_suffix=b")
        {
            ["modem_b", "modem_a"]
        } else {
            ["modem_a", "modem_b"]
        }
    }

    fn create_sunfish_remote_storage_block_nodes() {
        let _ = ensure_directory(Path::new("/dev/block/bootdevice/by-name"), 0o755);
        for partname in ["modemst1", "modemst2", "fsg", "fsc"] {
            let Some((major, minor)) = find_block_device_by_partname(partname) else {
                append_wrapper_log(&format!(
                    "wifi-bootstrap-rmt-storage-block-missing part={partname}"
                ));
                continue;
            };
            let device_path = Path::new("/dev/block/bootdevice/by-name").join(partname);
            match ensure_block_device(&device_path, 0o600, major as u64, minor as u64) {
                Ok(()) => append_wrapper_log(&format!(
                    "wifi-bootstrap-rmt-storage-block-node part={} device={} major={} minor={}",
                    partname,
                    device_path.display(),
                    major,
                    minor
                )),
                Err(error) => append_wrapper_log(&format!(
                    "wifi-bootstrap-rmt-storage-block-node-failed part={} error={}",
                    partname, error
                )),
            }
        }
    }

    fn create_sunfish_rmtfs_uio_node() {
        let Ok(entries) = fs::read_dir("/sys/class/uio") else {
            append_wrapper_log("wifi-bootstrap-rmtfs-uio-missing-root path=/sys/class/uio");
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = fs::read_to_string(path.join("name")).unwrap_or_default();
            if name.trim() != "rmtfs" {
                continue;
            }
            let device_path = Path::new("/dev").join(entry.file_name());
            match ensure_char_device_from_sysfs(&path.join("dev"), &device_path, 0o660) {
                Ok((major, minor)) => append_wrapper_log(&format!(
                    "wifi-bootstrap-rmtfs-uio-node device={} major={} minor={}",
                    device_path.display(),
                    major,
                    minor
                )),
                Err(error) => append_wrapper_log(&format!(
                    "wifi-bootstrap-rmtfs-uio-node-failed device={} error={}",
                    device_path.display(),
                    error
                )),
            }
            return;
        }
        append_wrapper_log("wifi-bootstrap-rmtfs-uio-missing-name name=rmtfs");
    }

    fn spawn_sunfish_wifi_android_helper(
        name: &str,
        args: &[&str],
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> Option<Child> {
        let helper_path = match name {
            "servicemanager" | "hwservicemanager" => Path::new("/system/bin").join(name),
            "wpa_supplicant" => Path::new("/vendor/bin/hw/wpa_supplicant").to_path_buf(),
            _ => Path::new("/vendor/bin").join(name),
        };
        let direct_exec = matches!(
            name,
            "servicemanager" | "hwservicemanager" | "vndservicemanager"
        );
        let linker_path = Path::new(CAMERA_HAL_BIONIC_LINKER_PATH);
        if (!direct_exec && !linker_path.is_file()) || !helper_path.is_file() {
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                &format!("wifi-android-helper-missing-{name}"),
            );
            return None;
        }

        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            &format!("wifi-android-helper-start-{name}"),
        );
        let mut command = if direct_exec {
            Command::new(&helper_path)
        } else if name == "wpa_supplicant" && Path::new("/system/bin/toybox").is_file() {
            let mut command = Command::new("/system/bin/toybox");
            command.arg("runcon");
            command.arg("u:r:hal_wifi_supplicant_default:s0");
            command.arg(linker_path);
            command.arg(&helper_path);
            command
        } else {
            let mut command = Command::new(linker_path);
            command.arg(&helper_path);
            command
        };
        for arg in args {
            command.arg(arg);
        }
        command.env(LD_LIBRARY_PATH_ENV, CAMERA_HAL_BIONIC_LIBRARY_PATH);
        command.env("ANDROID_ROOT", "/system");
        command.env("ANDROID_DATA", "/data");
        command.env("LD_CONFIG_FILE", "/linkerconfig/ld.config.txt");
        if Path::new("/vendor/lib64/libshadowprop.so").is_file() {
            command.env("LD_PRELOAD", "/vendor/lib64/libshadowprop.so");
        }
        if name == "wpa_supplicant" {
            command.env("SHADOW_FAKE_WIFI_SUPPLICANT_SERVICE_REGISTRATION", "1");
        }
        let output_path = format!("/orange-gpu/wifi-helper-{name}.log");
        if let Ok((stdout, stderr)) = redirect_output(&output_path) {
            command.stdout(stdout);
            command.stderr(stderr);
        }
        match command.spawn() {
            Ok(child) => {
                append_wrapper_log(&format!(
                    "wifi-android-helper-started name={} pid={}",
                    name,
                    child.id()
                ));
                Some(child)
            }
            Err(error) => {
                append_wrapper_log(&format!(
                    "wifi-android-helper-spawn-failed name={} error={}",
                    name, error
                ));
                write_payload_probe_stage(
                    probe_stage_path,
                    probe_stage_prefix,
                    &format!("wifi-android-helper-failed-{name}"),
                );
                None
            }
        }
    }

    fn wifi_helper_profile_allows(profile: &str, name: &str) -> bool {
        match profile {
            "full" => true,
            "no-service-managers" => !matches!(
                name,
                "servicemanager" | "hwservicemanager" | "vndservicemanager"
            ),
            "no-pm" => {
                wifi_helper_profile_allows("no-service-managers", name)
                    && !matches!(name, "pm-service" | "pm-proxy")
            }
            "no-modem-svc" => wifi_helper_profile_allows("no-pm", name) && name != "modem_svc",
            "no-rfs-storage" => {
                wifi_helper_profile_allows("no-modem-svc", name)
                    && !matches!(name, "rmt_storage" | "tftp_server")
            }
            "no-pd-mapper" => {
                wifi_helper_profile_allows("no-rfs-storage", name) && name != "pd-mapper"
            }
            "no-cnss" => wifi_helper_profile_allows("no-pd-mapper", name) && name != "cnss-daemon",
            "qrtr-only" => name == "qrtr-ns",
            "qrtr-pd" => matches!(name, "qrtr-ns" | "pd-mapper"),
            "qrtr-pd-tftp" => matches!(name, "qrtr-ns" | "pd-mapper" | "tftp_server"),
            "qrtr-pd-rfs" => matches!(
                name,
                "qrtr-ns" | "pd-mapper" | "rmt_storage" | "tftp_server"
            ),
            "qrtr-pd-rfs-cnss" => matches!(
                name,
                "qrtr-ns" | "pd-mapper" | "rmt_storage" | "tftp_server" | "cnss-daemon"
            ),
            "qrtr-pd-rfs-modem" => matches!(
                name,
                "qrtr-ns" | "pd-mapper" | "rmt_storage" | "tftp_server" | "modem_svc"
            ),
            "qrtr-pd-rfs-modem-cnss" => matches!(
                name,
                "qrtr-ns"
                    | "pd-mapper"
                    | "rmt_storage"
                    | "tftp_server"
                    | "modem_svc"
                    | "cnss-daemon"
            ),
            "qrtr-pd-rfs-modem-pm" => matches!(
                name,
                "qrtr-ns"
                    | "pd-mapper"
                    | "rmt_storage"
                    | "tftp_server"
                    | "modem_svc"
                    | "pm-service"
                    | "pm-proxy"
            ),
            "qrtr-pd-rfs-modem-pm-cnss" => matches!(
                name,
                "qrtr-ns"
                    | "pd-mapper"
                    | "rmt_storage"
                    | "tftp_server"
                    | "modem_svc"
                    | "pm-service"
                    | "pm-proxy"
                    | "cnss-daemon"
            ),
            // Research profile: isolate the framework Binder registry while
            // keeping Android init and the vendor/HIDL registries out of the
            // boot-owned Wi-Fi surface.
            "aidl-sm-core" => matches!(
                name,
                "servicemanager"
                    | "qrtr-ns"
                    | "pd-mapper"
                    | "rmt_storage"
                    | "tftp_server"
                    | "modem_svc"
                    | "pm-service"
                    | "pm-proxy"
                    | "cnss-daemon"
            ),
            "vnd-sm-core" => matches!(
                name,
                "vndservicemanager"
                    | "qrtr-ns"
                    | "pd-mapper"
                    | "rmt_storage"
                    | "tftp_server"
                    | "modem_svc"
                    | "pm-service"
                    | "pm-proxy"
                    | "cnss-daemon"
            ),
            // Proven Pixel 4a scan seam. The Qualcomm Wi-Fi chipset helpers
            // are a small distributed process graph; vndservicemanager is the
            // tiny vendor Binder name registry they use to find PM services.
            // This keeps Android init, hwservicemanager, and the framework
            // servicemanager out of the boot-owned Wi-Fi path.
            "vnd-sm-core-binder-node" => matches!(
                name,
                "vndservicemanager"
                    | "qrtr-ns"
                    | "pd-mapper"
                    | "rmt_storage"
                    | "tftp_server"
                    | "modem_svc"
                    | "pm-service"
                    | "pm-proxy"
                    | "cnss-daemon"
            ),
            "all-sm-core" => matches!(
                name,
                "servicemanager"
                    | "hwservicemanager"
                    | "vndservicemanager"
                    | "qrtr-ns"
                    | "pd-mapper"
                    | "rmt_storage"
                    | "tftp_server"
                    | "modem_svc"
                    | "pm-service"
                    | "pm-proxy"
                    | "cnss-daemon"
            ),
            "none" => false,
            _ => false,
        }
    }

    fn spawn_sunfish_wifi_profile_helper(
        profile: &str,
        name: &str,
        args: &[&str],
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> Option<Child> {
        if !wifi_helper_profile_allows(profile, name) {
            append_wrapper_log(&format!(
                "wifi-android-helper-skipped profile={} name={}",
                profile, name
            ));
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                &format!("wifi-android-helper-skipped-{name}"),
            );
            return None;
        }
        spawn_sunfish_wifi_android_helper(name, args, probe_stage_path, probe_stage_prefix)
    }

    fn start_sunfish_wifi_android_core_helpers(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) {
        prepare_sunfish_wifi_android_runtime_dirs();
        create_sunfish_android_core_device_nodes();
        load_sunfish_wifi_selinux_policy(probe_stage_path, probe_stage_prefix);
        if let Err(error) =
            mount_sunfish_modem_firmware_partition(probe_stage_path, probe_stage_prefix)
        {
            append_wrapper_log(&format!(
                "wifi-bootstrap-modem-firmware-unavailable error={error}"
            ));
        }
        create_sunfish_remote_storage_block_nodes();
        create_sunfish_rmtfs_uio_node();
        let helpers: [(&str, &[&str]); 10] = [
            ("servicemanager", &[]),
            ("hwservicemanager", &[]),
            ("vndservicemanager", &["/dev/vndbinder"]),
            ("qseecomd", &[]),
            ("irsc_util", &["/vendor/etc/sec_config"]),
            ("qrtr-ns", &["-f"]),
            ("pd-mapper", &[]),
            ("rmt_storage", &[]),
            ("tftp_server", &[]),
            ("modem_svc", &["-q"]),
        ];
        for (name, args) in helpers {
            let mut child = spawn_sunfish_wifi_profile_helper(
                &config.wifi_helper_profile,
                name,
                args,
                probe_stage_path,
                probe_stage_prefix,
            );
            thread::sleep(Duration::from_millis(250));
            if let Some(child) = child.as_mut() {
                match child.try_wait() {
                    Ok(Some(status)) => append_wrapper_log(&format!(
                        "wifi-android-helper-exited name={} status={}",
                        name, status
                    )),
                    Ok(None) => {}
                    Err(error) => append_wrapper_log(&format!(
                        "wifi-android-helper-status-failed name={} error={}",
                        name, error
                    )),
                }
            }
        }
        thread::sleep(Duration::from_secs(1));
        trigger_sunfish_ipa_firmware_load();
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-android-helpers-started",
        );
    }

    fn mount_sunfish_wifi_debugfs(
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) {
        if ensure_directory(Path::new("/sys/kernel/debug"), 0o755).is_err() {
            return;
        }
        match mount_fs("debugfs", "/sys/kernel/debug", "debugfs", 0, None) {
            Ok(()) => {
                append_wrapper_log("wifi-bootstrap-debugfs-mounted");
                write_payload_probe_stage(
                    probe_stage_path,
                    probe_stage_prefix,
                    "wifi-debugfs-mounted",
                );
            }
            Err(error) => append_wrapper_log(&format!(
                "wifi-bootstrap-debugfs-mount-failed error={error}"
            )),
        }
    }

    fn start_sunfish_wifi_peripheral_manager(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) {
        for (name, args) in [("pm-service", &[] as &[&str]), ("pm-proxy", &[])] {
            let mut child = spawn_sunfish_wifi_profile_helper(
                &config.wifi_helper_profile,
                name,
                args,
                probe_stage_path,
                probe_stage_prefix,
            );
            thread::sleep(Duration::from_millis(500));
            if let Some(child) = child.as_mut() {
                match child.try_wait() {
                    Ok(Some(status)) => append_wrapper_log(&format!(
                        "wifi-android-helper-exited name={} status={}",
                        name, status
                    )),
                    Ok(None) => {}
                    Err(error) => append_wrapper_log(&format!(
                        "wifi-android-helper-status-failed name={} error={}",
                        name, error
                    )),
                }
            }
        }
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-peripheral-manager-started",
        );
    }

    fn start_sunfish_wifi_cnss_daemon(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) {
        let _ = spawn_sunfish_wifi_profile_helper(
            &config.wifi_helper_profile,
            "cnss-daemon",
            &["-n", "-d", "-d"],
            probe_stage_path,
            probe_stage_prefix,
        );
        thread::sleep(Duration::from_secs(1));
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-cnss-daemon-started",
        );
    }

    fn bootstrap_tmpfs_input_runtime(config: &Config) -> io::Result<()> {
        if config.input_bootstrap != "sunfish-touch-event2" {
            return Ok(());
        }
        if !config.mount_sys {
            append_wrapper_log(
                "input-bootstrap-invalid-config mode=sunfish-touch-event2 reason=mount_sys_false",
            );
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "sunfish touch input bootstrap requires mount_sys=true",
            ));
        }
        if !config.mount_dev {
            append_wrapper_log(
                "input-bootstrap-invalid-config mode=sunfish-touch-event2 reason=mount_dev_false",
            );
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "sunfish touch input bootstrap requires mount_dev=true",
            ));
        }
        if config.dev_mount != "tmpfs" {
            append_wrapper_log(&format!(
                "input-bootstrap-invalid-config mode=sunfish-touch-event2 reason=dev_mount_{}",
                config.dev_mount
            ));
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "sunfish touch input bootstrap requires dev_mount=tmpfs",
            ));
        }

        ensure_directory(Path::new("/dev/input"), 0o755)?;
        if !Path::new("/lib/firmware/ftm5_fw.ftb").is_file() {
            append_wrapper_log("input-bootstrap-firmware-missing path=/lib/firmware/ftm5_fw.ftb");
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "missing sunfish touch firmware",
            ));
        }

        let firmware_stop = Arc::new(AtomicBool::new(false));
        let firmware_helper = {
            let thread_stop = Arc::clone(&firmware_stop);
            thread::spawn(move || run_ramdisk_firmware_any_helper_loop(thread_stop, "input"))
        };
        if let Err(error) = load_sunfish_touch_modules() {
            firmware_stop.store(true, Ordering::Relaxed);
            let _ = firmware_helper.join();
            return Err(error);
        }

        for attempt in 1..=300 {
            if let Some((event_name, major, minor)) = find_sunfish_touch_event()? {
                let device_path = Path::new("/dev/input").join(&event_name);
                ensure_char_device(&device_path, 0o660, major, minor)?;
                append_wrapper_log(&format!(
                    "input-bootstrap-ready mode={} device={} major={} minor={} attempts={}",
                    config.input_bootstrap, event_name, major, minor, attempt
                ));
                firmware_stop.store(true, Ordering::Relaxed);
                let _ = firmware_helper.join();
                return Ok(());
            }
            thread::sleep(Duration::from_millis(100));
        }

        firmware_stop.store(true, Ordering::Relaxed);
        let _ = firmware_helper.join();
        append_wrapper_log(&format!(
            "input-bootstrap-timeout mode={} waited_ms=12000",
            config.input_bootstrap
        ));
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "sunfish touch input event did not appear",
        ))
    }

    fn bootstrap_tmpfs_wifi_runtime(
        config: &Config,
        probe_stage_path: Option<&Path>,
        probe_stage_prefix: Option<&str>,
    ) -> io::Result<()> {
        if config.wifi_bootstrap != "sunfish-wlan0" {
            return Ok(());
        }
        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-bootstrap-start");
        if !config.mount_sys {
            append_wrapper_log(
                "wifi-bootstrap-invalid-config mode=sunfish-wlan0 reason=mount_sys_false",
            );
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                "wifi-bootstrap-invalid-mount-sys",
            );
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "sunfish wifi bootstrap requires mount_sys=true",
            ));
        }
        if !config.mount_dev {
            append_wrapper_log(
                "wifi-bootstrap-invalid-config mode=sunfish-wlan0 reason=mount_dev_false",
            );
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                "wifi-bootstrap-invalid-mount-dev",
            );
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "sunfish wifi bootstrap requires mount_dev=true",
            ));
        }
        if config.dev_mount != "tmpfs" {
            append_wrapper_log(&format!(
                "wifi-bootstrap-invalid-config mode=sunfish-wlan0 reason=dev_mount_{}",
                config.dev_mount
            ));
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                "wifi-bootstrap-invalid-dev-mount",
            );
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "sunfish wifi bootstrap requires dev_mount=tmpfs",
            ));
        }
        if !Path::new("/lib/modules/wlan.ko").is_file() {
            append_wrapper_log("wifi-bootstrap-module-missing path=/lib/modules/wlan.ko");
            write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-module-missing");
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "missing sunfish wlan.ko",
            ));
        }

        start_sunfish_wifi_android_core_helpers(config, probe_stage_path, probe_stage_prefix);
        mount_sunfish_wifi_debugfs(probe_stage_path, probe_stage_prefix);
        let firmware_stop = Arc::new(AtomicBool::new(false));
        let firmware_helper = {
            let thread_stop = Arc::clone(&firmware_stop);
            thread::spawn(move || run_ramdisk_firmware_any_helper_loop(thread_stop, "wifi"))
        };
        let mut subsystem_handles = Vec::new();
        if let Err(error) = load_sunfish_wifi_modules(probe_stage_path, probe_stage_prefix) {
            firmware_stop.store(true, Ordering::Relaxed);
            let _ = firmware_helper.join();
            return Err(error);
        }
        match ensure_char_device_from_sysfs(
            Path::new("/sys/class/wlan/wlan/dev"),
            Path::new("/dev/wlan"),
            0o666,
        ) {
            Ok((major, minor)) => append_wrapper_log(&format!(
                "wifi-bootstrap-wlan-control-node device=/dev/wlan major={} minor={}",
                major, minor
            )),
            Err(error) => append_wrapper_log(&format!(
                "wifi-bootstrap-wlan-control-node-failed error={error}"
            )),
        }
        match ensure_sunfish_subsystem_node("modem") {
            Ok((device_path, major, minor)) => append_wrapper_log(&format!(
                "wifi-bootstrap-subsys-node-prepared name=modem device={} major={} minor={}",
                device_path, major, minor
            )),
            Err(error) => append_wrapper_log(&format!(
                "wifi-bootstrap-subsys-node-prepare-failed name=modem error={error}"
            )),
        }
        start_sunfish_wifi_peripheral_manager(config, probe_stage_path, probe_stage_prefix);
        let modem_subsystem =
            match open_sunfish_subsystem("modem", probe_stage_path, probe_stage_prefix) {
                Ok(file) => file,
                Err(error) => {
                    firmware_stop.store(true, Ordering::Relaxed);
                    let _ = firmware_helper.join();
                    return Err(error);
                }
            };
        subsystem_handles.push(modem_subsystem);
        start_sunfish_wifi_cnss_daemon(config, probe_stage_path, probe_stage_prefix);

        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wait-wlan0");
        for attempt in 1..=250 {
            if Path::new("/sys/class/net/wlan0").exists() {
                let (major, minor) = ensure_char_device_from_sysfs(
                    Path::new("/sys/class/wlan/wlan/dev"),
                    Path::new("/dev/wlan"),
                    0o666,
                )?;
                append_wrapper_log(&format!(
                    "wifi-bootstrap-ready mode={} interface=wlan0 device=/dev/wlan major={} minor={} attempts={}",
                    config.wifi_bootstrap, major, minor, attempt
                ));
                write_payload_probe_stage(
                    probe_stage_path,
                    probe_stage_prefix,
                    "wifi-bootstrap-ready",
                );
                std::mem::forget(subsystem_handles);
                firmware_stop.store(true, Ordering::Relaxed);
                let _ = firmware_helper.join();
                return Ok(());
            }
            thread::sleep(Duration::from_millis(100));
        }
        firmware_stop.store(true, Ordering::Relaxed);
        let _ = firmware_helper.join();

        append_wrapper_log(&format!(
            "wifi-bootstrap-timeout mode={} waited_ms=25000",
            config.wifi_bootstrap
        ));
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-bootstrap-timeout",
        );
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "sunfish wlan0 did not appear",
        ))
    }

    fn find_sunfish_touch_event() -> io::Result<Option<(String, u64, u64)>> {
        let entries = match fs::read_dir("/sys/class/input") {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };

        for entry in entries {
            let entry = entry?;
            let event_name = entry.file_name();
            let Some(event_name) = event_name.to_str() else {
                continue;
            };
            if !event_name.starts_with("event") {
                continue;
            }

            let event_path = entry.path();
            let device_path = event_path.join("device");
            let name = read_trimmed(&device_path.join("name")).unwrap_or_default();
            let properties = read_trimmed(&device_path.join("properties")).unwrap_or_default();
            if name != "fts" || properties != "2" {
                continue;
            }

            let dev = read_trimmed(&event_path.join("dev"))?;
            let Some((major, minor)) = parse_major_minor(&dev) else {
                continue;
            };
            return Ok(Some((event_name.to_string(), major, minor)));
        }

        Ok(None)
    }

    fn read_trimmed(path: &Path) -> io::Result<String> {
        Ok(fs::read_to_string(path)?.trim().to_string())
    }

    fn parse_major_minor(value: &str) -> Option<(u64, u64)> {
        let (major, minor) = value.trim().split_once(':')?;
        Some((major.parse().ok()?, minor.parse().ok()?))
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
        if config.payload == "orange-gpu" && config.orange_gpu_metadata_stage_breadcrumb {
            prepare_metadata_stage_runtime(&mut metadata_stage, &config);
            if metadata_stage.prepared {
                write_metadata_probe_fingerprint(&mut metadata_stage, &config);
                write_metadata_stage(&mut metadata_stage, "early-bootstrap-start");
            }
        }
        if bootstrap_tmpfs_input_runtime(&config).is_err() {
            process::exit(1);
        }
        if bootstrap_tmpfs_android_ipc_runtime(&config).is_err() {
            process::exit(1);
        }
        if bootstrap_tmpfs_dri_runtime(&config).is_err() {
            process::exit(1);
        }
        if bootstrap_tmpfs_camera_runtime(&config).is_err() {
            process::exit(1);
        }
        if metadata_stage.prepared && config.wifi_bootstrap == "sunfish-wlan0" {
            write_metadata_stage(&mut metadata_stage, "wifi-bootstrap-start");
        }
        let wifi_probe_stage_path = if metadata_stage.prepared {
            Some(metadata_stage.probe_stage_path.as_path())
        } else {
            None
        };
        let wifi_bootstrap_failed =
            bootstrap_tmpfs_wifi_runtime(&config, wifi_probe_stage_path, Some("bootstrap"))
                .is_err();
        if wifi_bootstrap_failed {
            if metadata_stage.prepared {
                write_metadata_stage(&mut metadata_stage, "wifi-bootstrap-failed");
            }
        } else if metadata_stage.prepared && config.wifi_bootstrap == "sunfish-wlan0" {
            write_metadata_stage(&mut metadata_stage, "wifi-bootstrap-ready");
        }

        append_wrapper_log(&format!(
            "config payload={} prelude={} orange_gpu_mode={} orange_gpu_launch_delay_secs={} orange_gpu_parent_probe_attempts={} orange_gpu_parent_probe_interval_secs={} orange_gpu_metadata_stage_breadcrumb={} orange_gpu_metadata_prune_token_root={} orange_gpu_firmware_helper={} orange_gpu_timeout_action={} orange_gpu_watchdog_timeout_secs={} payload_probe_strategy={} payload_probe_source={} payload_probe_root={} payload_probe_manifest_path={} payload_probe_fallback_path={} app_direct_present_manual_touch={} hold_seconds={} prelude_hold_seconds={} reboot_target={} run_token={} dev_mount={} dri_bootstrap={} input_bootstrap={} firmware_bootstrap={} wifi_bootstrap={} wifi_helper_profile={} wifi_supplicant_probe={} wifi_association_probe={} wifi_ip_probe={} wifi_runtime_network={} wifi_runtime_clock_unix_secs_configured={} wifi_credentials_path_configured={} wifi_dhcp_client_path_configured={} mount_dev={} mount_proc={} mount_sys={} log_kmsg={} log_pmsg={}",
            config.payload,
            config.prelude,
            config.orange_gpu_mode,
            config.orange_gpu_launch_delay_secs,
            config.orange_gpu_parent_probe_attempts,
            config.orange_gpu_parent_probe_interval_secs,
            bool_word(config.orange_gpu_metadata_stage_breadcrumb),
            bool_word(config.orange_gpu_metadata_prune_token_root),
            bool_word(config.orange_gpu_firmware_helper),
            config.orange_gpu_timeout_action,
            config.orange_gpu_watchdog_timeout_secs,
            config.payload_probe_strategy,
            config.payload_probe_source,
            config.payload_probe_root,
            config.payload_probe_manifest_path,
            config.payload_probe_fallback_path,
            bool_word(config.app_direct_present_manual_touch),
            config.hold_seconds,
            config.prelude_hold_seconds,
            config.reboot_target,
            run_token_or_unset(&config),
            config.dev_mount,
            config.dri_bootstrap,
            config.input_bootstrap,
            config.firmware_bootstrap,
            config.wifi_bootstrap,
            config.wifi_helper_profile,
            bool_word(config.wifi_supplicant_probe),
            bool_word(config.wifi_association_probe),
            bool_word(config.wifi_ip_probe),
            bool_word(config.wifi_runtime_network),
            bool_word(config.wifi_runtime_clock_unix_secs != 0),
            bool_word(!config.wifi_credentials_path.is_empty()),
            bool_word(!config.wifi_dhcp_client_path.is_empty()),
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
