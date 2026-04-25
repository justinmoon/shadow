use super::*;

pub(super) fn current_group_ids() -> Option<Vec<u32>> {
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

pub(super) fn write_metadata_probe_fingerprint(
    runtime: &mut MetadataStageRuntime,
    config: &Config,
) {
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

pub(super) fn write_probe_report(
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

pub(super) fn record_probe_summary(
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
pub(super) struct TouchCounterEvidence {
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
pub(super) struct TouchCounterEvidenceProfile {
    injection: &'static str,
    tap_dispatched_needle: &'static str,
    counter_incremented_needle: &'static str,
    post_touch_frame_marker_needle: &'static str,
    post_touch_frame_artifact_needle: &'static str,
    post_touch_frame_committed_needle: &'static str,
}

impl TouchCounterEvidenceProfile {
    pub(super) fn rust_counter(injection: &'static str) -> Self {
        Self {
            injection,
            tap_dispatched_needle: "[shadow-guest-compositor] touch-app-tap-dispatch",
            counter_incremented_needle: "shadow-rust-demo: counter_incremented count=1",
            post_touch_frame_marker_needle: "shadow-rust-demo: frame_committed counter=1",
            post_touch_frame_artifact_needle: "[shadow-guest-compositor] wrote-frame-artifact",
            post_touch_frame_committed_needle: "shadow-rust-demo: frame_committed counter=1",
        }
    }

    pub(super) fn runtime_counter(
        injection: &'static str,
        post_touch_frame_artifact: &'static str,
        post_touch_frame_presented: &'static str,
    ) -> Self {
        Self {
            injection,
            tap_dispatched_needle: "route=app-tap",
            counter_incremented_needle: "[shadow-runtime-counter] counter_incremented count=2",
            post_touch_frame_marker_needle: "[shadow-runtime-counter] counter_incremented count=2",
            post_touch_frame_artifact_needle: post_touch_frame_artifact,
            post_touch_frame_committed_needle: post_touch_frame_presented,
        }
    }
}

pub(super) fn touch_counter_evidence_from_output(
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
        input_observed: output_text.contains("[shadow-guest-compositor] touch-input phase=Down")
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
pub(super) struct ShellSessionEvidence {
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

pub(super) fn shell_session_evidence_from_output(
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
            .map(|index| output_text[index..].contains("[shadow-guest-compositor] mapped-window"))
            .unwrap_or(false);
    let app_frame_artifact_logged = start_app_index
        .and_then(|index| {
            output_text[index..].find("[shadow-guest-compositor] wrote-frame-artifact")
        })
        .is_some();
    ShellSessionEvidence {
        shell_mode_enabled: output_text.contains("[shadow-guest-compositor] shell-mode enabled"),
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

pub(super) fn record_session_frame_summary(
    runtime: &mut MetadataStageRuntime,
    kind: &str,
    startup_mode: &str,
    app_id: Option<&str>,
    touch_counter_profile: Option<TouchCounterEvidenceProfile>,
    wifi_runtime_network_summary: Option<&str>,
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
    if let Some(wifi_summary) = wifi_runtime_network_summary {
        let _ = write!(
            payload,
            "  \"wifi_runtime_network\": {},\n  \"wifi_runtime_network_ok\": true,\n",
            wifi_summary
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

pub(super) fn validate_gpu_render_summary(summary_text: &str) -> Result<(), &'static str> {
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

pub(super) fn validate_orange_gpu_loop_summary(summary_text: &str) -> Result<(), &'static str> {
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

pub(super) fn bootstrap_tmpfs_metadata_block_runtime(
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

pub(super) fn prune_metadata_token_root(config: &Config) -> io::Result<()> {
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

pub(super) fn try_prepare_metadata_stage_runtime(
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

pub(super) fn prepare_metadata_stage_runtime(runtime: &mut MetadataStageRuntime, config: &Config) {
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
