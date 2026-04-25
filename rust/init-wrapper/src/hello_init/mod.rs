#![cfg(target_os = "linux")]

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
const ORANGE_GPU_COMPOSITOR_STARTUP_CONFIG_PATH: &str = "/orange-gpu/compositor-scene-startup.json";
const ORANGE_GPU_SHELL_SESSION_STARTUP_CONFIG_PATH: &str = "/orange-gpu/shell-session-startup.json";
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
const CAMERA_HAL_BIONIC_PROBE_OUTPUT_PATH: &str = "/orange-gpu/camera-hal-bionic-probe-output.log";
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum BootMode {
    Lab,
    Product,
}

impl BootMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Lab => "lab",
            Self::Product => "product",
        }
    }
}

#[derive(Clone, Debug)]
struct Config {
    boot_mode: BootMode,
    boot_mode_invalid: bool,
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
            boot_mode: BootMode::Lab,
            boot_mode_invalid: false,
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

mod bootstrap;
mod camera;
mod config;
mod diagnostics;
mod entry;
mod payload;
mod payload_probe;
mod product;
mod proof;
mod reboot;
mod storage;
mod support;
mod wifi;

pub use self::entry::main_linux_raw;

use self::bootstrap::*;
use self::camera::*;
use self::config::*;
use self::diagnostics::*;
use self::payload::*;
use self::payload_probe::*;
use self::product::*;
use self::proof::*;
use self::reboot::*;
use self::storage::*;
use self::support::*;
use self::wifi::*;
