use super::*;

pub(super) fn redirect_output(path: &str) -> io::Result<(Stdio, Stdio)> {
    let file = File::create(path)?;
    let stderr = file.try_clone()?;
    Ok((Stdio::from(file), Stdio::from(stderr)))
}

pub(super) fn trigger_sysrq_best_effort(command: char) {
    let _ = fs::write("/proc/sysrq-trigger", [command as u8]);
}

pub(super) fn run_orange_init_payload(
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

pub(super) fn ensure_orange_gpu_runtime_dirs() -> io::Result<()> {
    ensure_directory(Path::new(ORANGE_GPU_ROOT), 0o755)?;
    ensure_directory(Path::new(ORANGE_GPU_COMPOSITOR_RUNTIME_DIR), 0o755)?;
    ensure_directory(Path::new(ORANGE_GPU_HOME), 0o755)?;
    ensure_directory(Path::new(ORANGE_GPU_CACHE_HOME), 0o755)?;
    ensure_directory(Path::new(ORANGE_GPU_CONFIG_HOME), 0o755)?;
    ensure_directory(Path::new(ORANGE_GPU_MESA_CACHE_DIR), 0o755)?;
    Ok(())
}

pub(super) fn expand_orange_gpu_bundle_archive(config: &Config) -> io::Result<()> {
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

pub(super) fn orange_gpu_bundle_archive_needs_shadow_logical_payload(config: &Config) -> bool {
    !config.orange_gpu_bundle_archive_path.is_empty()
        && Path::new(&config.orange_gpu_bundle_archive_path).starts_with(SHADOW_PAYLOAD_MOUNT_PATH)
}

pub(super) fn set_orange_gpu_env(
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

pub(super) fn probe_stage_path_from_env() -> Option<PathBuf> {
    std::env::var_os(GPU_SMOKE_STAGE_PATH_ENV)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

pub(super) fn probe_stage_prefix_from_env() -> Option<String> {
    std::env::var(GPU_SMOKE_STAGE_PREFIX_ENV)
        .ok()
        .filter(|value| !value.is_empty())
}

pub(super) fn probe_bootstrap_gpu_firmware(
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

pub(super) fn firmware_request_path_is_safe(filename: &str) -> bool {
    !filename.is_empty()
        && Path::new(filename)
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

pub(super) fn firmware_source_path(filename: &str) -> Option<PathBuf> {
    let decoded_filename = filename.replace('!', "/");
    if !firmware_request_path_is_safe(filename) && !firmware_request_path_is_safe(&decoded_filename)
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

pub(super) fn service_firmware_request_from_ramdisk(filename: &str) -> io::Result<PathBuf> {
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

pub(super) fn service_available_ramdisk_firmware_requests(serviced: &mut Vec<String>) {
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

pub(super) fn run_ramdisk_firmware_any_helper_loop(stop: Arc<AtomicBool>, label: &'static str) {
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

pub(super) fn run_ramdisk_firmware_helper_loop(
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
                for (index, (filename, stage_token)) in GPU_FIRMWARE_ENTRIES.iter().enumerate() {
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

pub(super) fn run_timeout_control_smoke(
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

pub(super) fn run_c_kgsl_open_readonly_smoke_internal(
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

pub(super) fn run_internal_orange_gpu_child(config: &Config, mode: &str) -> i32 {
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
        "c-kgsl-open-readonly-firmware-helper-smoke" => run_c_kgsl_open_readonly_smoke_internal(
            config,
            probe_stage_path.as_deref(),
            probe_stage_prefix.as_deref(),
            true,
        ),
        _ => 1,
    }
}

pub(super) fn run_orange_gpu_parent_probe(
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

pub(super) fn scene_for_mode(mode: &str) -> (&'static str, bool, bool) {
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
        "vulkan-enumerate-adapters-count-smoke" => ("enumerate-adapters-count-smoke", false, false),
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

pub(super) fn resolve_watchdog_timeout(config: &Config) -> u32 {
    if config.orange_gpu_watchdog_timeout_secs > 0 {
        config.orange_gpu_watchdog_timeout_secs
    } else {
        config
            .hold_seconds
            .saturating_add(ORANGE_GPU_WATCHDOG_GRACE_SECONDS)
    }
}

pub(super) fn wait_for_child_with_watchdog(
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

pub(super) fn orange_gpu_mode_uses_success_postlude(mode: &str) -> bool {
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

pub(super) fn run_orange_gpu_checkpoint(
    config: &Config,
    checkpoint_name: &str,
    hold_seconds: u32,
) -> i32 {
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

pub(super) fn run_orange_gpu_prelude(config: &Config) -> i32 {
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

pub(super) fn run_orange_gpu_postlude(config: &Config) -> i32 {
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

pub(super) fn validate_orange_gpu_config(config: &Config) -> bool {
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
    if config.orange_gpu_firmware_helper && config.firmware_bootstrap != "ramdisk-lib-firmware" {
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
    if config.orange_gpu_mode == "c-kgsl-open-readonly-firmware-helper-smoke" && !config.mount_sys {
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
        log_line(
            "payload-partition-probe requires payload_probe_strategy=metadata-shadow-payload-v1",
        );
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
            log_line("payload-partition-probe shadow-logical-partition requires mount_sys=true");
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

pub(super) fn run_payload_partition_probe(
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

pub(super) fn run_orange_gpu_payload(
    config: &Config,
    metadata_stage: &mut MetadataStageRuntime,
    self_exec_path: Option<&Path>,
) -> i32 {
    if ensure_orange_gpu_runtime_dirs().is_err() {
        return 1;
    }
    if orange_gpu_bundle_archive_needs_shadow_logical_payload(config) {
        match prepare_shadow_logical_payload_root(config, Path::new(SHADOW_PAYLOAD_MOUNT_PATH)) {
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
        let _ =
            run_orange_gpu_checkpoint(config, "probe-ready", ORANGE_GPU_CHECKPOINT_HOLD_SECONDS);
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
    let mut wifi_runtime_network_summary: Option<String> = None;
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
            wifi_runtime_network_summary = Some(runtime_start.json.clone());
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
    let mut timeout_observer = |observed_pid: u32, waited_seconds: u32, timeout_seconds: u32| {
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
    if orange_gpu_mode_is_shell_session_held(&config.orange_gpu_mode) && !watch_result.timed_out {
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
    let wifi_linux_surface_blocked =
        config.orange_gpu_mode == "wifi-linux-surface-probe" && watch_result.exit_status == Some(2);
    if (watch_result.exit_status == Some(0) || wifi_linux_surface_blocked) && metadata_stage.enabled
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
                wifi_runtime_network_summary.as_deref(),
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
            let recorded_summary = record_probe_summary(metadata_stage, ORANGE_GPU_SUMMARY_PATH);
            if config.orange_gpu_mode == "wifi-linux-surface-probe" && recorded_summary.is_none() {
                log_line(
                    "wifi-linux-surface-probe summary missing or could not be persisted to metadata",
                );
            }
            if config.orange_gpu_mode == "gpu-render" {
                let Some(summary_text) = recorded_summary.as_deref() else {
                    log_line("gpu-render summary missing or could not be persisted to metadata");
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
        if orange_gpu_mode_is_shell_session_held(&config.orange_gpu_mode) && metadata_stage.enabled
        {
            let summary_kind = "shell-session-held";
            let touch_counter_profile = if orange_gpu_config_is_held_runtime_touch_counter(config) {
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
                wifi_runtime_network_summary.as_deref(),
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
                let payload_cleanup = stop_child_json(&mut child);
                append_wrapper_log(&format!("held-shell-payload-cleanup {payload_cleanup}"));
                stop_wifi_runtime_network(
                    &mut wifi_runtime_network,
                    probe_stage_path.as_deref(),
                    probe_stage_prefix.as_deref(),
                    "held-shell-watchdog-proved",
                );
                return 0;
            }
        }
        if config.orange_gpu_timeout_action == "hold" {
            let payload_cleanup = stop_child_json(&mut child);
            append_wrapper_log(&format!("timed-out-payload-cleanup {payload_cleanup}"));
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
        let _ =
            run_orange_gpu_checkpoint(config, "child-signal", ORANGE_GPU_CHECKPOINT_HOLD_SECONDS);
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
