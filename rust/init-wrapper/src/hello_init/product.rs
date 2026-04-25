use super::*;

const PRODUCT_SESSION_OUTPUT_PATH: &str = "/orange-gpu/product-session.log";
const PRODUCT_RESTART_BACKOFF_INITIAL_SECS: u32 = 1;
const PRODUCT_RESTART_BACKOFF_MAX_SECS: u32 = 30;

pub(super) fn validate_product_boot_profile(config: &Config) -> bool {
    if config.payload != "orange-gpu" {
        log_line("product boot mode requires payload=orange-gpu");
        return false;
    }
    if !config.orange_gpu_mode_seen || config.orange_gpu_mode_invalid {
        log_line("product boot mode requires a valid orange_gpu_mode");
        return false;
    }
    if config.orange_gpu_mode != "shell-session" {
        log_line("product boot mode currently requires orange_gpu_mode=shell-session");
        return false;
    }
    if config.orange_gpu_parent_probe_attempts != 0 {
        log_line("product boot mode rejects lab-only orange_gpu_parent_probe_attempts");
        return false;
    }
    if config.orange_gpu_metadata_stage_breadcrumb {
        log_line("product boot mode rejects lab-only orange_gpu_metadata_stage_breadcrumb");
        return false;
    }
    if config.orange_gpu_metadata_prune_token_root {
        log_line("product boot mode rejects lab-only orange_gpu_metadata_prune_token_root");
        return false;
    }
    if config.orange_gpu_watchdog_timeout_secs != 0 {
        log_line("product boot mode rejects lab-only orange_gpu_watchdog_timeout_secs");
        return false;
    }
    if config.orange_gpu_firmware_helper && !config.mount_sys {
        log_line("product orange_gpu_firmware_helper requires mount_sys=true");
        return false;
    }
    if config.orange_gpu_firmware_helper && config.firmware_bootstrap != "ramdisk-lib-firmware" {
        log_line(
            "product orange_gpu_firmware_helper requires firmware_bootstrap=ramdisk-lib-firmware",
        );
        return false;
    }
    if config.wifi_runtime_network && config.wifi_bootstrap != "sunfish-wlan0" {
        log_line("product wifi_runtime_network requires wifi_bootstrap=sunfish-wlan0");
        return false;
    }
    if config.wifi_runtime_network && config.wifi_credentials_path.is_empty() {
        log_line("product wifi_runtime_network requires wifi_credentials_path");
        return false;
    }
    if config.wifi_runtime_network && config.wifi_dhcp_client_path.is_empty() {
        log_line("product wifi_runtime_network requires wifi_dhcp_client_path");
        return false;
    }
    if orange_gpu_bundle_archive_needs_shadow_logical_payload(config) {
        if config.payload_probe_source != PAYLOAD_PROBE_LOGICAL_SOURCE {
            log_line("product orange_gpu_bundle_archive_path under /shadow-payload requires payload_probe_source=shadow-logical-partition");
            return false;
        }
        if !config.mount_sys {
            log_line("product orange_gpu_bundle_archive_path under /shadow-payload requires mount_sys=true");
            return false;
        }
        if config.payload_probe_root != SHADOW_PAYLOAD_MOUNT_PATH
            || config.payload_probe_manifest_path
                != format!("{SHADOW_PAYLOAD_MOUNT_PATH}/manifest.env")
        {
            log_line("product orange_gpu_bundle_archive_path under /shadow-payload requires root=/shadow-payload manifest=/shadow-payload/manifest.env");
            return false;
        }
    }
    true
}

pub(super) fn run_product_orange_gpu_runtime(config: &Config) -> ! {
    append_wrapper_log("product-runtime-start");

    if !validate_product_boot_profile(config) {
        product_fatal_loop("invalid product boot profile");
    }
    if let Err(error) = prepare_product_payload(config) {
        product_fatal_loop(&format!("failed to prepare product payload: {error}"));
    }
    if config.orange_gpu_launch_delay_secs > 0 {
        append_wrapper_log(&format!(
            "product-runtime-launch-delay secs={}",
            config.orange_gpu_launch_delay_secs
        ));
        sleep_seconds(config.orange_gpu_launch_delay_secs);
    }
    if let Err(error) = probe_bootstrap_gpu_firmware(config, None, Some("product")) {
        append_wrapper_log(&format!(
            "product-runtime-firmware-preflight-failed error={error}"
        ));
    }

    let _firmware_helper = if config.orange_gpu_firmware_helper {
        append_wrapper_log("product-runtime-firmware-helper-start");
        Some(FirmwareHelper::start(None, Some("product".to_string())))
    } else {
        append_wrapper_log("product-runtime-firmware-helper-disabled");
        None
    };

    let mut wifi_runtime_network = start_product_wifi_runtime_network(config);
    supervise_product_session(config, &mut wifi_runtime_network)
}

fn prepare_product_payload(config: &Config) -> io::Result<()> {
    ensure_orange_gpu_runtime_dirs()?;
    if orange_gpu_bundle_archive_needs_shadow_logical_payload(config) {
        prepare_shadow_logical_payload_root(config, Path::new(SHADOW_PAYLOAD_MOUNT_PATH))
            .map_err(|error| io::Error::new(io::ErrorKind::Other, error))?;
    }
    expand_orange_gpu_bundle_archive(config)?;
    Ok(())
}

fn start_product_wifi_runtime_network(config: &Config) -> Option<WifiRuntimeNetwork> {
    if !config.wifi_runtime_network {
        append_wrapper_log("product-runtime-wifi-disabled");
        return None;
    }
    let runtime_start = start_wifi_runtime_network(config, None, Some("product"));
    append_wrapper_log(&format!(
        "product-runtime-wifi-start {}",
        runtime_start.json
    ));
    if runtime_start.completed {
        runtime_start.network
    } else {
        None
    }
}

fn supervise_product_session(
    config: &Config,
    wifi_runtime_network: &mut Option<WifiRuntimeNetwork>,
) -> ! {
    let mut attempt: u64 = 0;
    let mut backoff_secs = PRODUCT_RESTART_BACKOFF_INITIAL_SECS;

    loop {
        attempt = attempt.saturating_add(1);
        remove_file_best_effort(ORANGE_GPU_OUTPUT_PATH);
        append_wrapper_log(&format!("product-session-start attempt={attempt}"));

        let mut command = product_session_command(config);
        set_orange_gpu_env(&mut command, None, Some("product-session"));
        if let Ok((stdout, stderr)) = redirect_product_output(PRODUCT_SESSION_OUTPUT_PATH) {
            command.stdout(stdout);
            command.stderr(stderr);
        }

        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                append_wrapper_log(&format!(
                    "product-session-spawn-failed attempt={attempt} error={error} backoff_secs={backoff_secs}"
                ));
                product_restart_sleep(backoff_secs);
                backoff_secs = next_product_backoff(backoff_secs);
                maybe_restart_product_wifi(config, wifi_runtime_network);
                continue;
            }
        };
        append_wrapper_log(&format!(
            "product-session-spawned attempt={attempt} pid={}",
            child.id()
        ));

        match child.wait() {
            Ok(status) => {
                let exit_code = status
                    .code()
                    .map(|code| code.to_string())
                    .unwrap_or_else(|| "none".to_string());
                #[cfg(unix)]
                let signal = {
                    use std::os::unix::process::ExitStatusExt;
                    status
                        .signal()
                        .map(|signal| signal.to_string())
                        .unwrap_or_else(|| "none".to_string())
                };
                #[cfg(not(unix))]
                let signal = "none".to_string();
                append_wrapper_log(&format!(
                    "product-session-exited attempt={attempt} exit_code={exit_code} signal={signal} backoff_secs={backoff_secs}"
                ));
            }
            Err(error) => {
                append_wrapper_log(&format!(
                    "product-session-wait-failed attempt={attempt} error={error} backoff_secs={backoff_secs}"
                ));
            }
        }

        product_restart_sleep(backoff_secs);
        backoff_secs = next_product_backoff(backoff_secs);
        maybe_restart_product_wifi(config, wifi_runtime_network);
    }
}

fn product_session_command(config: &Config) -> Command {
    let mut command = Command::new(ORANGE_GPU_COMPOSITOR_SESSION_PATH);
    command.env("SHADOW_SESSION_MODE", "guest-ui");
    command.env("SHADOW_RUNTIME_DIR", ORANGE_GPU_COMPOSITOR_RUNTIME_DIR);
    command.env(
        "SHADOW_GUEST_SESSION_CONFIG",
        ORANGE_GPU_SHELL_SESSION_STARTUP_CONFIG_PATH,
    );
    command.env(
        "SHADOW_GUEST_COMPOSITOR_BIN",
        ORANGE_GPU_COMPOSITOR_BINARY_PATH,
    );
    command.env("SHADOW_GUEST_COMPOSITOR_ENABLE_DRM", "1");
    command.env(GUEST_COMPOSITOR_LOADER_ENV, ORANGE_GPU_LOADER_PATH);
    command.env(GUEST_COMPOSITOR_LIBRARY_PATH_ENV, ORANGE_GPU_LIBRARY_PATH);
    command.env(
        "RUST_LOG",
        "shadow_session=info,shadow_compositor_guest=info,smithay=warn",
    );
    if !config.app_direct_present_runtime_bundle_env.is_empty()
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
}

fn maybe_restart_product_wifi(
    config: &Config,
    wifi_runtime_network: &mut Option<WifiRuntimeNetwork>,
) {
    if !config.wifi_runtime_network || wifi_runtime_network.is_some() {
        return;
    }
    *wifi_runtime_network = start_product_wifi_runtime_network(config);
}

fn redirect_product_output(path: &str) -> io::Result<(Stdio, Stdio)> {
    let file = OpenOptions::new().create(true).append(true).open(path)?;
    let stderr = file.try_clone()?;
    Ok((Stdio::from(file), Stdio::from(stderr)))
}

fn product_restart_sleep(backoff_secs: u32) {
    sleep_seconds(backoff_secs.max(1));
}

fn next_product_backoff(current_secs: u32) -> u32 {
    current_secs.saturating_mul(2).clamp(
        PRODUCT_RESTART_BACKOFF_INITIAL_SECS,
        PRODUCT_RESTART_BACKOFF_MAX_SECS,
    )
}

fn product_fatal_loop(reason: &str) -> ! {
    append_wrapper_log(&format!("product-runtime-fatal reason={reason}"));
    loop {
        sleep_seconds(60);
        append_wrapper_log(&format!("product-runtime-still-held reason={reason}"));
    }
}
