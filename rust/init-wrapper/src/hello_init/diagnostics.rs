use super::*;

pub(super) fn read_probe_stage_value(runtime: &MetadataStageRuntime) -> String {
    let Ok(text) = fs::read_to_string(&runtime.probe_stage_path) else {
        return String::new();
    };
    normalize_probe_stage_value(&text)
}

pub(super) fn normalize_probe_stage_value(value: &str) -> String {
    let trimmed = value.trim();
    match trimmed.split_once(':') {
        Some((_, suffix)) => suffix.to_string(),
        None => trimmed.to_string(),
    }
}

pub(super) fn sanitize_inline_text(value: &str) -> String {
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

pub(super) fn read_inline_text_file(path: &str) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|text| sanitize_inline_text(&text))
}

pub(super) fn append_pid_namespace_fingerprint_lines(payload: &mut String, pid: u32) {
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

pub(super) fn append_pid_proc_excerpt(
    payload: &mut String,
    pid: u32,
    name: &str,
    max_bytes: usize,
) {
    append_file_excerpt(payload, &format!("/proc/{pid}/{name}"), max_bytes);
}

pub(super) fn append_pid_children_tree_excerpt(payload: &mut String, pid: u32, depth: u32) {
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

pub(super) fn extract_text_key_value_line(text: &str, key: &str) -> Option<String> {
    text.lines()
        .find_map(|line| line.strip_prefix(&format!("{key}=")))
        .map(ToString::to_string)
}

pub(super) fn text_contains_any_needle(text: &str, needles: &[&str]) -> Option<String> {
    if text.is_empty() {
        return None;
    }
    needles
        .iter()
        .find(|needle| text.contains(**needle))
        .map(|needle| (*needle).to_string())
}

pub(super) fn classify_kgsl_timeout_from_text(
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

pub(super) fn orange_gpu_checkpoint_is_firmware_probe(checkpoint_name: &str) -> bool {
    checkpoint_name.starts_with("firmware-probe-")
}

pub(super) fn orange_gpu_checkpoint_is_timeout_classifier(checkpoint_name: &str) -> bool {
    checkpoint_name.starts_with("kgsl-timeout-")
}

pub(super) fn orange_gpu_mode_is_any_c_kgsl_open_readonly_smoke(mode: &str) -> bool {
    matches!(
        mode,
        "c-kgsl-open-readonly-smoke" | "c-kgsl-open-readonly-firmware-helper-smoke"
    )
}

pub(super) fn orange_gpu_mode_is_c_kgsl_open_readonly_pid1_smoke(mode: &str) -> bool {
    mode == "c-kgsl-open-readonly-pid1-smoke"
}

pub(super) fn orange_gpu_mode_is_compositor_scene(mode: &str) -> bool {
    mode == "compositor-scene"
}

pub(super) fn orange_gpu_mode_is_shell_session(mode: &str) -> bool {
    matches!(
        mode,
        "shell-session" | "shell-session-held" | "shell-session-runtime-touch-counter"
    )
}

pub(super) fn orange_gpu_mode_is_shell_session_held(mode: &str) -> bool {
    mode == "shell-session-held"
}

pub(super) fn orange_gpu_mode_is_shell_session_runtime_touch_counter(mode: &str) -> bool {
    mode == "shell-session-runtime-touch-counter"
}

pub(super) fn orange_gpu_config_is_held_runtime_touch_counter(config: &Config) -> bool {
    orange_gpu_mode_is_shell_session_held(&config.orange_gpu_mode)
        && config.shell_session_start_app_id == "counter"
}

pub(super) fn orange_gpu_mode_is_app_direct_present(mode: &str) -> bool {
    matches!(
        mode,
        "app-direct-present"
            | "app-direct-present-touch-counter"
            | "app-direct-present-runtime-touch-counter"
    )
}

pub(super) fn orange_gpu_mode_is_app_direct_present_touch_counter(mode: &str) -> bool {
    matches!(
        mode,
        "app-direct-present-touch-counter" | "app-direct-present-runtime-touch-counter"
    )
}

pub(super) fn orange_gpu_mode_is_app_direct_present_runtime_touch_counter(mode: &str) -> bool {
    mode == "app-direct-present-runtime-touch-counter"
}

pub(super) fn orange_gpu_mode_uses_session_frame_capture(mode: &str) -> bool {
    orange_gpu_mode_is_compositor_scene(mode)
        || orange_gpu_mode_is_shell_session(mode)
        || orange_gpu_mode_is_app_direct_present(mode)
}

pub(super) fn orange_gpu_mode_uses_visible_checkpoints(mode: &str, checkpoint_name: &str) -> bool {
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

pub(super) fn orange_gpu_checkpoint_visual(checkpoint_name: &str) -> &'static str {
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

pub(super) fn write_text_path_best_effort(path: &str, contents: &str) -> bool {
    fs::write(path, contents).is_ok()
}

pub(super) fn teardown_kgsl_trace_best_effort() {
    let _ = write_text_path_best_effort(TRACEFS_TRACING_ON_PATH, "0\n");
    let _ = write_text_path_best_effort(TRACEFS_CURRENT_TRACER_PATH, "nop\n");
}

pub(super) fn setup_kgsl_trace_best_effort() -> bool {
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

pub(super) fn highest_kgsl_trace_stage_from_text(trace_text: &str) -> Option<&'static str> {
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

pub(super) fn run_kgsl_trace_monitor_loop(
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

pub(super) fn classify_kgsl_timeout_from_probe_report(
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

pub(super) fn write_metadata_probe_timeout_class(
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

pub(super) fn classify_orange_gpu_timeout(
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

pub(super) fn remove_file_best_effort(path: &str) {
    let _ = fs::remove_file(path);
}

pub(super) fn read_file_excerpt(path: &str, max_bytes: usize) -> String {
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

pub(super) fn append_file_excerpt(payload: &mut String, path: &str, max_bytes: usize) {
    let _ = writeln!(payload, "begin:{}<<", path);
    payload.push_str(&read_file_excerpt(path, max_bytes));
    let _ = writeln!(payload, ">>end:{}", path);
}

pub(super) fn append_namespace_fingerprint_lines(payload: &mut String) {
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

pub(super) fn append_path_fingerprint_line(payload: &mut String, path: &str) {
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

pub(super) fn json_escape(value: &str) -> String {
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

pub(super) fn json_string(value: &str) -> String {
    format!("\"{}\"", json_escape(value))
}

pub(super) fn json_optional_string(value: Option<String>) -> String {
    match value {
        Some(value) => json_string(&value),
        None => "null".to_string(),
    }
}

pub(super) fn json_string_array(values: &[String]) -> String {
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

pub(super) fn json_pointer(ptr: *mut libc::c_void) -> String {
    if ptr.is_null() {
        "null".to_string()
    } else {
        json_string(&format!("0x{:x}", ptr as usize))
    }
}
