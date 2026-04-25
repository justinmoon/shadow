use super::*;

pub(super) fn log_observability_status(config: &Config) {
    append_wrapper_log(&format!(
        "shadow-owned-init-observability:kmsg={},pmsg={},stdio=true,run_token={}",
        bool_word(config.log_kmsg),
        bool_word(config.log_pmsg),
        run_token_or_unset(config)
    ));
}

fn validate_boot_profile(config: &Config) -> bool {
    if config.boot_mode_invalid {
        log_line("invalid boot_mode; expected lab or product");
        return false;
    }
    match config.boot_mode {
        BootMode::Lab => true,
        BootMode::Product => true,
    }
}

pub fn main_linux_raw(argc: libc::c_int, argv: *const *const libc::c_char) -> ! {
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
    if !validate_boot_profile(&config) {
        hold_for_observation(config.hold_seconds);
        reboot_from_config(&config);
    }

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
        bootstrap_tmpfs_wifi_runtime(&config, wifi_probe_stage_path, Some("bootstrap")).is_err();
    if wifi_bootstrap_failed {
        if metadata_stage.prepared {
            write_metadata_stage(&mut metadata_stage, "wifi-bootstrap-failed");
        }
    } else if metadata_stage.prepared && config.wifi_bootstrap == "sunfish-wlan0" {
        write_metadata_stage(&mut metadata_stage, "wifi-bootstrap-ready");
    }

    append_wrapper_log(&format!(
        "config boot_mode={} payload={} prelude={} orange_gpu_mode={} orange_gpu_launch_delay_secs={} orange_gpu_parent_probe_attempts={} orange_gpu_parent_probe_interval_secs={} orange_gpu_metadata_stage_breadcrumb={} orange_gpu_metadata_prune_token_root={} orange_gpu_firmware_helper={} orange_gpu_timeout_action={} orange_gpu_watchdog_timeout_secs={} payload_probe_strategy={} payload_probe_source={} payload_probe_root={} payload_probe_manifest_path={} payload_probe_fallback_path={} app_direct_present_manual_touch={} hold_seconds={} prelude_hold_seconds={} reboot_target={} run_token={} dev_mount={} dri_bootstrap={} input_bootstrap={} firmware_bootstrap={} wifi_bootstrap={} wifi_helper_profile={} wifi_supplicant_probe={} wifi_association_probe={} wifi_ip_probe={} wifi_runtime_network={} wifi_runtime_clock_unix_secs_configured={} wifi_credentials_path_configured={} wifi_dhcp_client_path_configured={} mount_dev={} mount_proc={} mount_sys={} log_kmsg={} log_pmsg={}",
        config.boot_mode.as_str(),
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

    if config.boot_mode == BootMode::Product {
        run_product_orange_gpu_runtime(&config);
    }

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
        let _ = run_orange_gpu_checkpoint(&config, "validated", ORANGE_GPU_CHECKPOINT_HOLD_SECONDS);
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
