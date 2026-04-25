use super::*;

pub(super) fn load_config(config_path: &str) -> Config {
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
            "boot_mode" | "boot-mode" => match value.trim() {
                "lab" => {
                    config.boot_mode = BootMode::Lab;
                    config.boot_mode_invalid = false;
                }
                "product" => {
                    config.boot_mode = BootMode::Product;
                    config.boot_mode_invalid = false;
                }
                _ => {
                    config.boot_mode_invalid = true;
                }
            },
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
            "orange_gpu_parent_probe_interval_secs" | "orange-gpu-parent-probe-interval-secs" => {
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
                    && trimmed
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
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
            "app_direct_present_runtime_bundle_env" | "app-direct-present-runtime-bundle-env" => {
                config.app_direct_present_runtime_bundle_env = value.trim().to_string();
            }
            "app_direct_present_runtime_bundle_path" | "app-direct-present-runtime-bundle-path" => {
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
