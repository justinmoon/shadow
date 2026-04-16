#!/usr/bin/env python3
import argparse
import json
import re
from datetime import datetime
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
CLIENT_START_RE = re.compile(
    r"\[shadow-runtime-demo[^\]]*\+\s*\d+ms\] gpu-summary-start (\{.*\})$"
)
CLIENT_SUMMARY_RE = re.compile(
    r"\[shadow-runtime-demo[^\]]*\+\s*\d+ms\] gpu-summary-client (\{.*\})$"
)
DISPATCH_RE = re.compile(
    r"runtime-dispatch-start source=(\S+) type=(\S+) target=(\S+) wall_ms=(\d+)"
)
BOOT_SPLASH_RE = re.compile(
    r"\[shadow-guest-compositor\] boot-splash-frame-generated checksum=([0-9a-f]+) size=([0-9]+x[0-9]+)"
)
CAPTURED_RE = re.compile(
    r"\[shadow-guest-compositor\] captured-frame checksum=([0-9a-f]+) size=([0-9]+x[0-9]+)"
)
OPENLOG_PATH_RE = re.compile(r"\[shadow-openlog\] (\S+) path=(\S+)")
OPENLOG_IOCTL_RE = re.compile(r"\[shadow-openlog\] ioctl kind=(\S+)\s")
RUNTIME_LOG_RE = re.compile(r"\[shadow-runtime-demo ts_ms=(\d+)\s+\+\s*\d+ms\]")
RUNTIME_LOG_LINE_RE = re.compile(r"\[shadow-runtime-demo ts_ms=\d+\s+\+\s*\d+ms\] (.+)$")
TIMESTAMP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)")
DISPLAY_ENV_WGPU_RE = re.compile(r"wgpu_backend_env=Some\(\"([^\"]+)\"\)")
DISPLAY_ENV_PRELOAD_RE = re.compile(r"shadow_linux_ld_preload=Some\(\"([^\"]+)\"\)")
NO_COMPAT_DEVICE_RE = re.compile(r"No compatible device found: (.+)$")
EGL_DRI2_FAIL_RE = re.compile(r"libEGL warning: egl: failed to create dri2 screen")
BUFFER_TYPE_RE = re.compile(r"\[shadow-guest-compositor\] buffer-observed type=(\S+) size=")
STARTUP_STAGE_RE = re.compile(
    r"\[shadow-runtime-demo ts_ms=(\d+)\s+\+\s*\d+ms\] startup-stage=([A-Za-z0-9_.:-]+)"
)
WINDOW_RESUME_START_RE = re.compile(
    r"\[shadow-runtime-demo ts_ms=(\d+)\s+\+\s*\d+ms\] window-resume-start"
)
WINDOW_RESUME_DONE_RE = re.compile(
    r"\[shadow-runtime-demo ts_ms=(\d+)\s+\+\s*\d+ms\] window-resume-done"
)
RUNTIME_READY_RE = re.compile(
    r"\[shadow-runtime-demo ts_ms=(\d+)\s+\+\s*\d+ms\] runtime-document-ready"
)
CLIENT_DISCONNECTED_RE = re.compile(
    r"\[shadow-guest-compositor\] client-disconnected(?: reason=(\S+))?"
)
PRESENTED_FRAME_RE = re.compile(r"\[shadow-guest-compositor\] presented-frame")
SURFACE_RENDERER_NEW_RE = re.compile(
    r"\[shadow-wgpu-context\] surface-renderer-new configure-begin "
)
SURFACE_CONFIGURE_RE = re.compile(r"\[shadow-wgpu-context\] surface-configure ")
SURFACE_CONFIGURE_DONE_RE = re.compile(r"\[shadow-wgpu-context\] surface-configure-done")
SURFACE_ADAPTER_RE = re.compile(
    r"\[shadow-wgpu-context\] surface-adapter index=(\d+) supported=(true|false) backend=([^ ]+) "
)
SELECTED_ADAPTER_SURFACE_RE = re.compile(
    r"\[shadow-wgpu-context\] selected-adapter-surface supported=(true|false) "
)
RUN_APP_ERROR_RE = re.compile(r"\[shadow-blitz-demo\] run-app-error: (.+)$")
CHECKPOINT_TIMEOUT_RE = re.compile(r"timed out waiting for checkpoint: (.+)$")
SESSION_EXITED_CHECKPOINT_RE = re.compile(r"session exited before checkpoint: (.+)$")
STARTUP_FAILURE_TIMEOUT_RE = re.compile(
    r"startup checkpoint failure: timed out waiting for (.+):"
)
STARTUP_FAILURE_SESSION_EXIT_RE = re.compile(
    r"startup checkpoint failure: session exited before checkpoint: (.+)$"
)
TOUCH_HANDLE_RE = re.compile(
    r"\[shadow-guest-compositor\] touch-latency-handle seq=(\d+) phase=(\S+) queue_us=(\d+) wall_ms=(\d+) "
)
TOUCH_DISPATCH_RE = re.compile(
    r"\[shadow-guest-compositor\] touch-latency-dispatch seq=(\d+) route=(\S+) phase=(\S+) handle_to_flush_us=(\d+) input_wall_ms=(\d+) dispatch_wall_ms=(\d+)"
)
TOUCH_COMMIT_RE = re.compile(
    r"\[shadow-guest-compositor\] touch-latency-commit seq=(\d+) route=(\S+) phase=(\S+) input_to_commit_us=(\d+) dispatch_to_commit_us=(\d+)"
)
TOUCH_PRESENT_RE = re.compile(
    r"\[shadow-guest-compositor\] touch-latency-present seq=(\d+) route=(\S+) phase=(\S+) frame_marker=(\S+) input_wall_ms=(\d+) dispatch_wall_ms=(\d+) input_to_present_us=(\d+) dispatch_to_present_us=(\d+)(?: commit_to_present_us=(\d+))?"
)
TOUCH_REPLACED_RE = re.compile(
    r"\[shadow-guest-compositor\] touch-latency-replaced prev_seq=(\d+) prev_route=(\S+) seq=(\d+) route=(\S+)"
)
TOUCH_SIGNAL_WRITE_RE = re.compile(
    r"\[shadow-guest-compositor\] touch-signal-write counter=(\d+) seq=(\d+) wall_ms=(\d+)"
)
TOUCH_SIGNAL_DETECTED_RE = re.compile(
    r"\[shadow-runtime-demo ts_ms=(\d+)\s+\+\s*\d+ms\] touch-signal-detected token=(\d+)"
)
RUNTIME_SESSION_RESPONSE_RE = re.compile(
    r"\[shadow-runtime-demo ts_ms=(\d+)\s+\+\s*\d+ms\] runtime-session-response op=(\S+) elapsed_ms=(\d+)"
)
SOFTBUFFER_RENDER_RE = re.compile(
    r"\[shadow-softbuffer \+\s*(\d+)ms\] render-to-vec-done"
)
SOFTBUFFER_SWIZZLE_RE = re.compile(
    r"\[shadow-softbuffer \+\s*(\d+)ms\] swizzle-done"
)
SOFTBUFFER_PRESENT_RE = re.compile(
    r"\[shadow-softbuffer \+\s*(\d+)ms\] present-done"
)
WROTE_FRAME_ARTIFACT_RE = re.compile(
    r"\[shadow-guest-compositor\] wrote-frame-artifact path=\S+ checksum=([0-9a-f]+) size=([0-9]+x[0-9]+)"
)


def strip_ansi(value: str) -> str:
    return ANSI_RE.sub("", value)


def parse_timestamp_ms(value: str) -> int:
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)


def percentile(sorted_values: list[float], fraction: float) -> float | None:
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = max(0.0, min(1.0, fraction)) * (len(sorted_values) - 1)
    lower = int(position)
    upper = min(len(sorted_values) - 1, lower + 1)
    if lower == upper:
        return sorted_values[lower]
    weight = position - lower
    return sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight


def summarize_samples(values: list[float]) -> dict:
    if not values:
        return {"count": 0}
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "min_ms": round(ordered[0], 3),
        "avg_ms": round(sum(ordered) / len(ordered), 3),
        "p50_ms": round(percentile(ordered, 0.50) or 0.0, 3),
        "p95_ms": round(percentile(ordered, 0.95) or 0.0, 3),
        "max_ms": round(ordered[-1], 3),
    }


def summarize_micros(values: list[int]) -> dict:
    return summarize_samples([value / 1000.0 for value in values])


def compute_first_visible_ms(
    client_start: dict | None, captures: list[dict], boot_checksum: str | None
) -> tuple[int | None, str | None]:
    if not client_start or not captures:
        return None, None
    wall_ms = client_start.get("wall_ms")
    if wall_ms is None:
        return None, None

    for capture in captures:
        if capture["timestamp_ms"] < wall_ms:
            continue
        if boot_checksum is not None and capture["checksum"] == boot_checksum:
            continue
        return capture["timestamp_ms"] - wall_ms, capture["checksum"]

    return None, None


def compute_click_latency_ms(
    dispatches: list[dict],
    captures: list[dict],
    boot_checksum: str | None,
    first_visible_checksum: str | None,
) -> tuple[int | None, str | None, str | None]:
    if not dispatches or not captures:
        return None, None, None

    for dispatch in dispatches:
        dispatch_ms = dispatch["wall_ms"]
        baseline_checksum = None
        for capture in captures:
            if capture["timestamp_ms"] <= dispatch_ms:
                baseline_checksum = capture["checksum"]
            else:
                break
        if baseline_checksum is None:
            baseline_checksum = first_visible_checksum or boot_checksum or captures[0]["checksum"]

        for capture in captures:
            if capture["timestamp_ms"] < dispatch_ms:
                continue
            if capture["checksum"] != baseline_checksum:
                return (
                    capture["timestamp_ms"] - dispatch_ms,
                    dispatch["source"],
                    capture["checksum"],
                )

    return None, None, None


def infer_failure_phase(
    last_startup_stage: str | None,
    runtime_document_ready_wall_ms: int | None,
    last_runtime_log: str | None,
    probe_error: str | None,
    timeout_checkpoint: str | None,
    egl_dri2_failed: bool,
    run_app_error: str | None,
    client_disconnect_reason: str | None,
    surface_adapter_supported: bool | None,
    selected_adapter_surface_supported: bool | None,
    window_resume_started: bool,
    window_resume_done: bool,
    surface_renderer_new_started: bool,
    surface_configure_started: bool,
    surface_configure_done: bool,
    presented_frame_count: int,
    first_visible_ms: int | None,
) -> str | None:
    if first_visible_ms is not None:
        return None
    if run_app_error:
        return "run-app"
    if timeout_checkpoint:
        if last_runtime_log and last_runtime_log.startswith("window-resume-start "):
            return "window-resume"
        if last_startup_stage == "run-app-begin":
            return "surface-configure-or-first-present"
        if last_startup_stage == "window-config-ready":
            return "resume-or-first-present"
        return f"checkpoint:{timeout_checkpoint}"
    if probe_error:
        if "NoCompatibleDevice" in probe_error or "No compatible device" in probe_error:
            if last_startup_stage is None:
                return "gpu-probe"
            if last_startup_stage.startswith(("renderer-summary-probe", "cpu-summary")):
                return "renderer-probe"
            if last_startup_stage.startswith(("create-event-loop", "proxy-ready", "window-config")):
                return "surface-create"
            return f"after:{last_startup_stage}"
        return "probe-error"
    if client_disconnect_reason:
        if selected_adapter_surface_supported is True and not surface_configure_started:
            return "surface-configure-entry"
        if surface_adapter_supported is True and not selected_adapter_surface_supported:
            return "surface-compat-selection"
        if surface_configure_started and not surface_configure_done:
            return "surface-configure"
        if surface_renderer_new_started and not surface_configure_started:
            return "surface-renderer-init"
        if window_resume_started and not window_resume_done:
            return "window-resume"
        if runtime_document_ready_wall_ms is not None:
            return "post-runtime-ready-client-disconnect"
        return "client-disconnect"
    if surface_configure_started and not surface_configure_done:
        return "surface-configure"
    if window_resume_started and not window_resume_done:
        return "window-resume"
    if runtime_document_ready_wall_ms is not None and presented_frame_count == 0:
        return "post-runtime-ready-no-frame"
    if egl_dri2_failed:
        return "egl-init"
    return None


def load_summary(session_output: Path, renderer: str | None) -> dict:
    client_start = None
    client_summary = None
    dispatches: list[dict] = []
    captures: list[dict] = []
    boot_checksum = None
    fallback_start_wall_ms = None
    inferred_mode = None
    env_wgpu_backend = None
    env_preload = None
    probe_error = None
    egl_dri2_failed = False
    buffer_type = None
    startup_stage_last = None
    startup_stage_last_wall_ms = None
    startup_stage_count = 0
    timeout_checkpoint = None
    checkpoint_failure_kind = None
    last_runtime_log = None
    runtime_document_ready_wall_ms = None
    window_resume_started = False
    window_resume_done = False
    surface_renderer_new_started = False
    surface_configure_started = False
    surface_configure_done = False
    presented_frame_count = 0
    client_disconnect_reason = None
    run_app_error = None
    surface_adapter_seen = False
    surface_adapter_supported = None
    surface_adapter_backend = None
    selected_adapter_surface_seen = False
    selected_adapter_surface_supported = None
    touch_handle_queue_us: list[int] = []
    touch_dispatches: list[dict] = []
    touch_commits: list[dict] = []
    touch_presents: list[dict] = []
    touch_replaced_count = 0
    touch_signal_writes: dict[str, int] = {}
    touch_signal_detect_delays_ms: list[float] = []
    softbuffer_render_ms: list[float] = []
    softbuffer_swizzle_ms: list[float] = []
    softbuffer_present_ms: list[float] = []
    runtime_session_ms: dict[str, list[float]] = {}
    frame_capture_to_artifact_ms: list[float] = []
    frame_artifact_to_present_ms: list[float] = []
    frame_capture_to_present_ms: list[float] = []
    last_frame_capture_ts_ms = None
    last_frame_artifact_ts_ms = None
    openlog = {
        "dri_open_count": 0,
        "kgsl_open_count": 0,
        "dri_ioctl_count": 0,
        "kgsl_ioctl_count": 0,
        "dri_denied": False,
        "kgsl_denied": False,
    }

    for raw_line in session_output.read_text(encoding="utf-8", errors="replace").splitlines():
        line = strip_ansi(raw_line).strip()
        if not line:
            continue

        startup_stage_match = STARTUP_STAGE_RE.search(line)
        if startup_stage_match:
            startup_stage_last_wall_ms = int(startup_stage_match.group(1))
            startup_stage_last = startup_stage_match.group(2)
            startup_stage_count += 1
            continue

        runtime_ready_match = RUNTIME_READY_RE.search(line)
        if runtime_ready_match:
            runtime_document_ready_wall_ms = int(runtime_ready_match.group(1))
            continue

        if WINDOW_RESUME_START_RE.search(line):
            window_resume_started = True
            continue

        if WINDOW_RESUME_DONE_RE.search(line):
            window_resume_done = True
            continue

        touch_handle_match = TOUCH_HANDLE_RE.search(line)
        if touch_handle_match:
            touch_handle_queue_us.append(int(touch_handle_match.group(3)))
            continue

        touch_dispatch_match = TOUCH_DISPATCH_RE.search(line)
        if touch_dispatch_match:
            touch_dispatches.append(
                {
                    "seq": int(touch_dispatch_match.group(1)),
                    "route": touch_dispatch_match.group(2),
                    "phase": touch_dispatch_match.group(3),
                    "handle_to_flush_us": int(touch_dispatch_match.group(4)),
                }
            )
            continue

        touch_commit_match = TOUCH_COMMIT_RE.search(line)
        if touch_commit_match:
            touch_commits.append(
                {
                    "seq": int(touch_commit_match.group(1)),
                    "route": touch_commit_match.group(2),
                    "phase": touch_commit_match.group(3),
                    "input_to_commit_us": int(touch_commit_match.group(4)),
                    "dispatch_to_commit_us": int(touch_commit_match.group(5)),
                }
            )
            continue

        touch_present_match = TOUCH_PRESENT_RE.search(line)
        if touch_present_match:
            commit_to_present_us = touch_present_match.group(9)
            touch_presents.append(
                {
                    "seq": int(touch_present_match.group(1)),
                    "route": touch_present_match.group(2),
                    "phase": touch_present_match.group(3),
                    "frame_marker": touch_present_match.group(4),
                    "input_to_present_us": int(touch_present_match.group(7)),
                    "dispatch_to_present_us": int(touch_present_match.group(8)),
                    "commit_to_present_us": (
                        int(commit_to_present_us) if commit_to_present_us is not None else None
                    ),
                }
            )
            continue

        if TOUCH_REPLACED_RE.search(line):
            touch_replaced_count += 1
            continue

        touch_signal_write_match = TOUCH_SIGNAL_WRITE_RE.search(line)
        if touch_signal_write_match:
            touch_signal_writes[touch_signal_write_match.group(1)] = int(
                touch_signal_write_match.group(3)
            )
            continue

        touch_signal_detected_match = TOUCH_SIGNAL_DETECTED_RE.search(line)
        if touch_signal_detected_match:
            detected_ms = int(touch_signal_detected_match.group(1))
            written_ms = touch_signal_writes.get(touch_signal_detected_match.group(2))
            if written_ms is not None and detected_ms >= written_ms:
                touch_signal_detect_delays_ms.append(detected_ms - written_ms)
            continue

        runtime_session_response_match = RUNTIME_SESSION_RESPONSE_RE.search(line)
        if runtime_session_response_match:
            op = runtime_session_response_match.group(2)
            runtime_session_ms.setdefault(op, []).append(
                float(runtime_session_response_match.group(3))
            )

        softbuffer_render_match = SOFTBUFFER_RENDER_RE.search(line)
        if softbuffer_render_match:
            softbuffer_render_ms.append(float(softbuffer_render_match.group(1)))
            continue

        softbuffer_swizzle_match = SOFTBUFFER_SWIZZLE_RE.search(line)
        if softbuffer_swizzle_match:
            softbuffer_swizzle_ms.append(float(softbuffer_swizzle_match.group(1)))
            continue

        softbuffer_present_match = SOFTBUFFER_PRESENT_RE.search(line)
        if softbuffer_present_match:
            softbuffer_present_ms.append(float(softbuffer_present_match.group(1)))
            continue

        match = CLIENT_START_RE.search(line)
        if match:
            client_start = json.loads(match.group(1))
            continue

        runtime_log_match = RUNTIME_LOG_RE.search(line)
        if runtime_log_match and fallback_start_wall_ms is None:
            fallback_start_wall_ms = int(runtime_log_match.group(1))

        runtime_log_line_match = RUNTIME_LOG_LINE_RE.search(line)
        if runtime_log_line_match:
            last_runtime_log = runtime_log_line_match.group(1)

        display_env_backend_match = DISPLAY_ENV_WGPU_RE.search(line)
        if display_env_backend_match and env_wgpu_backend is None:
            env_wgpu_backend = display_env_backend_match.group(1)

        display_env_preload_match = DISPLAY_ENV_PRELOAD_RE.search(line)
        if display_env_preload_match and env_preload is None:
            env_preload = display_env_preload_match.group(1)

        match = CLIENT_SUMMARY_RE.search(line)
        if match:
            client_summary = json.loads(match.group(1))
            continue

        match = DISPATCH_RE.search(line)
        if match:
            dispatches.append(
                {
                    "source": match.group(1),
                    "event_type": match.group(2),
                    "target": match.group(3),
                    "wall_ms": int(match.group(4)),
                }
            )
            continue

        timestamp_match = TIMESTAMP_RE.match(line)
        boot_match = BOOT_SPLASH_RE.search(line)
        if timestamp_match and boot_match:
            boot_checksum = boot_match.group(1)
            continue

        no_compat_match = NO_COMPAT_DEVICE_RE.search(line)
        if no_compat_match and probe_error is None:
            probe_error = no_compat_match.group(1)
            continue

        surface_adapter_match = SURFACE_ADAPTER_RE.search(line)
        if surface_adapter_match:
            surface_adapter_seen = True
            surface_adapter_supported = surface_adapter_match.group(2) == "true"
            surface_adapter_backend = surface_adapter_match.group(3)
            continue

        selected_adapter_surface_match = SELECTED_ADAPTER_SURFACE_RE.search(line)
        if selected_adapter_surface_match:
            selected_adapter_surface_seen = True
            selected_adapter_surface_supported = (
                selected_adapter_surface_match.group(1) == "true"
            )
            continue

        checkpoint_timeout_match = CHECKPOINT_TIMEOUT_RE.search(line)
        if checkpoint_timeout_match and timeout_checkpoint is None:
            timeout_checkpoint = checkpoint_timeout_match.group(1)
            checkpoint_failure_kind = "checkpoint-timeout"
            continue

        session_exited_checkpoint_match = SESSION_EXITED_CHECKPOINT_RE.search(line)
        if session_exited_checkpoint_match and timeout_checkpoint is None:
            timeout_checkpoint = session_exited_checkpoint_match.group(1)
            checkpoint_failure_kind = "session-exited-before-checkpoint"
            continue

        startup_failure_timeout_match = STARTUP_FAILURE_TIMEOUT_RE.search(line)
        if startup_failure_timeout_match and timeout_checkpoint is None:
            timeout_checkpoint = startup_failure_timeout_match.group(1)
            checkpoint_failure_kind = "checkpoint-timeout"
            continue

        startup_failure_session_exit_match = STARTUP_FAILURE_SESSION_EXIT_RE.search(line)
        if startup_failure_session_exit_match and timeout_checkpoint is None:
            timeout_checkpoint = startup_failure_session_exit_match.group(1)
            checkpoint_failure_kind = "session-exited-before-checkpoint"
            continue

        if EGL_DRI2_FAIL_RE.search(line):
            egl_dri2_failed = True
            continue

        if SURFACE_RENDERER_NEW_RE.search(line):
            surface_renderer_new_started = True
            continue

        if SURFACE_CONFIGURE_DONE_RE.search(line):
            surface_configure_done = True
            continue

        if SURFACE_CONFIGURE_RE.search(line):
            surface_configure_started = True
            continue

        client_disconnect_match = CLIENT_DISCONNECTED_RE.search(line)
        if client_disconnect_match:
            client_disconnect_reason = client_disconnect_match.group(1) or "unknown"
            continue

        if PRESENTED_FRAME_RE.search(line):
            presented_frame_count += 1
            if timestamp_match and last_frame_capture_ts_ms is not None:
                presented_ts_ms = parse_timestamp_ms(timestamp_match.group(1))
                frame_capture_to_present_ms.append(presented_ts_ms - last_frame_capture_ts_ms)
                if last_frame_artifact_ts_ms is not None:
                    frame_artifact_to_present_ms.append(
                        presented_ts_ms - last_frame_artifact_ts_ms
                    )
            continue

        wrote_frame_artifact_match = WROTE_FRAME_ARTIFACT_RE.search(line)
        if timestamp_match and wrote_frame_artifact_match:
            last_frame_artifact_ts_ms = parse_timestamp_ms(timestamp_match.group(1))
            if last_frame_capture_ts_ms is not None:
                frame_capture_to_artifact_ms.append(
                    last_frame_artifact_ts_ms - last_frame_capture_ts_ms
                )
            continue

        run_app_error_match = RUN_APP_ERROR_RE.search(line)
        if run_app_error_match and run_app_error is None:
            run_app_error = run_app_error_match.group(1)
            continue

        openlog_path_match = OPENLOG_PATH_RE.search(line)
        if openlog_path_match:
            kind = openlog_path_match.group(1)
            path = openlog_path_match.group(2)
            if "/dev/dri" in path:
                openlog["dri_open_count"] += 1
                if kind.startswith("deny-"):
                    openlog["dri_denied"] = True
            if "/dev/kgsl" in path:
                openlog["kgsl_open_count"] += 1
                if kind.startswith("deny-"):
                    openlog["kgsl_denied"] = True
            continue

        openlog_ioctl_match = OPENLOG_IOCTL_RE.search(line)
        if openlog_ioctl_match:
            kind = openlog_ioctl_match.group(1)
            if kind == "dri":
                openlog["dri_ioctl_count"] += 1
            if kind == "kgsl":
                openlog["kgsl_ioctl_count"] += 1
            continue

        capture_match = CAPTURED_RE.search(line)
        if timestamp_match and capture_match:
            last_frame_capture_ts_ms = parse_timestamp_ms(timestamp_match.group(1))
            last_frame_artifact_ts_ms = None
            captures.append(
                {
                    "timestamp_ms": last_frame_capture_ts_ms,
                    "checksum": capture_match.group(1),
                    "size": capture_match.group(2),
                }
            )

        buffer_type_match = BUFFER_TYPE_RE.search(line)
        if buffer_type_match and buffer_type is None:
            buffer_type = buffer_type_match.group(1)

    effective_renderer = (
        renderer
        or (client_summary or {}).get("renderer")
        or (client_start or {}).get("renderer")
        or "unknown"
    )
    if client_start is None and fallback_start_wall_ms is not None:
        client_start = {
            "renderer": effective_renderer,
            "mode": inferred_mode,
            "wall_ms": fallback_start_wall_ms,
        }
    if client_summary is None and effective_renderer == "cpu":
        client_summary = {
            "renderer": "cpu",
            "mode": (client_start or {}).get("mode", inferred_mode or "runtime"),
            "backend": None,
            "device_type": None,
            "adapter_name": None,
            "driver": None,
            "driver_info": None,
            "software_backed": True,
            "source": "cpu",
            "probe_error": None,
        }

    summary_source = (client_summary or {}).get("source")
    software_backed = (client_summary or {}).get("software_backed")
    if software_backed is None:
        if (
            effective_renderer == "gpu_softbuffer"
            and openlog["dri_open_count"] > 0
            and openlog["kgsl_open_count"] == 0
            and egl_dri2_failed
            and buffer_type == "shm"
        ):
            software_backed = True
            summary_source = "openlog-egl-shm"

    if probe_error is None:
        probe_error = (client_summary or {}).get("probe_error")

    first_visible_ms, first_visible_checksum = compute_first_visible_ms(
        client_start, captures, boot_checksum
    )
    click_latency_ms, click_source, updated_frame_checksum = compute_click_latency_ms(
        dispatches, captures, boot_checksum, first_visible_checksum
    )
    touch_routes = sorted(
        {
            sample["route"]
            for sample in touch_dispatches + touch_commits + touch_presents
            if sample.get("route")
        }
    )
    touch_latency = {
        "handle_queue": summarize_micros(touch_handle_queue_us),
        "dispatch_to_flush": summarize_micros(
            [sample["handle_to_flush_us"] for sample in touch_dispatches]
        ),
        "input_to_commit": summarize_micros(
            [sample["input_to_commit_us"] for sample in touch_commits]
        ),
        "dispatch_to_commit": summarize_micros(
            [sample["dispatch_to_commit_us"] for sample in touch_commits]
        ),
        "input_to_present": summarize_micros(
            [sample["input_to_present_us"] for sample in touch_presents]
        ),
        "dispatch_to_present": summarize_micros(
            [sample["dispatch_to_present_us"] for sample in touch_presents]
        ),
        "commit_to_present": summarize_micros(
            [
                sample["commit_to_present_us"]
                for sample in touch_presents
                if sample["commit_to_present_us"] is not None
            ]
        ),
        "replaced_count": touch_replaced_count,
        "routes": {},
    }
    for route in touch_routes:
        route_dispatches = [
            sample["handle_to_flush_us"]
            for sample in touch_dispatches
            if sample["route"] == route
        ]
        route_commits = [
            sample["input_to_commit_us"]
            for sample in touch_commits
            if sample["route"] == route
        ]
        route_presents = [
            sample["input_to_present_us"]
            for sample in touch_presents
            if sample["route"] == route
        ]
        route_commit_to_present = [
            sample["commit_to_present_us"]
            for sample in touch_presents
            if sample["route"] == route and sample["commit_to_present_us"] is not None
        ]
        touch_latency["routes"][route] = {
            "dispatch_to_flush": summarize_micros(route_dispatches),
            "input_to_commit": summarize_micros(route_commits),
            "input_to_present": summarize_micros(route_presents),
            "commit_to_present": summarize_micros(route_commit_to_present),
        }
    touch_signal_latency = summarize_samples(touch_signal_detect_delays_ms)
    touch_signal_latency["count"] = len(touch_signal_detect_delays_ms)
    softbuffer_latency = {
        "render_to_vec": summarize_samples(softbuffer_render_ms),
        "swizzle": summarize_samples(softbuffer_swizzle_ms),
        "present": summarize_samples(softbuffer_present_ms),
    }
    compositor_frame_latency = {
        "capture_to_artifact": summarize_samples(frame_capture_to_artifact_ms),
        "artifact_to_present": summarize_samples(frame_artifact_to_present_ms),
        "capture_to_present": summarize_samples(frame_capture_to_present_ms),
    }
    runtime_session_latency = {
        op: summarize_samples(samples)
        for op, samples in sorted(runtime_session_ms.items())
    }
    failure_phase = infer_failure_phase(
        startup_stage_last,
        runtime_document_ready_wall_ms,
        last_runtime_log,
        probe_error,
        timeout_checkpoint,
        egl_dri2_failed,
        run_app_error,
        client_disconnect_reason,
        surface_adapter_supported,
        selected_adapter_surface_supported,
        window_resume_started,
        window_resume_done,
        surface_renderer_new_started,
        surface_configure_started,
        surface_configure_done,
        presented_frame_count,
        first_visible_ms,
    )

    summary = {
        "run_dir": str(session_output.parent),
        "renderer": effective_renderer,
        "mode": (client_summary or client_start or {}).get("mode") or inferred_mode,
        "wgpu_backend": (client_summary or {}).get("backend") or env_wgpu_backend,
        "adapter_name": (client_summary or {}).get("adapter_name"),
        "driver": (client_summary or {}).get("driver"),
        "driver_info": (client_summary or {}).get("driver_info"),
        "device_type": (client_summary or {}).get("device_type"),
        "software_backed": software_backed,
        "hardware_backed": None
        if software_backed is None
        else not bool(software_backed),
        "summary_source": summary_source,
        "probe_error": probe_error,
        "startup_stage_last": startup_stage_last,
        "last_startup_stage": startup_stage_last,
        "last_startup_stage_wall_ms": startup_stage_last_wall_ms,
        "startup_stage_count": startup_stage_count,
        "last_runtime_log": last_runtime_log,
        "failure_phase": failure_phase,
        "inferred_failure_phase": failure_phase,
        "failure_reason": (
            run_app_error
            or probe_error
            or (
                f"client-disconnect:{client_disconnect_reason}"
                if client_disconnect_reason is not None
                else None
            )
            or (
                f"{checkpoint_failure_kind}:{timeout_checkpoint}"
                if timeout_checkpoint is not None
                else None
            )
        ),
        "checkpoint_failure_kind": checkpoint_failure_kind,
        "adapter_ok": surface_adapter_supported,
        "surface_ok": selected_adapter_surface_supported,
        "configure_ok": surface_configure_done,
        "present_ok": presented_frame_count > 0,
        "runtime_document_ready_wall_ms": runtime_document_ready_wall_ms,
        "window_resume_started": window_resume_started,
        "window_resume_done": window_resume_done,
        "surface_renderer_new_started": surface_renderer_new_started,
        "surface_adapter_seen": surface_adapter_seen,
        "surface_adapter_supported": surface_adapter_supported,
        "surface_adapter_backend": surface_adapter_backend,
        "selected_adapter_surface_seen": selected_adapter_surface_seen,
        "selected_adapter_surface_supported": selected_adapter_surface_supported,
        "surface_configure_started": surface_configure_started,
        "surface_configure_done": surface_configure_done,
        "presented_frame_count": presented_frame_count,
        "client_disconnect_reason": client_disconnect_reason,
        "run_app_error": run_app_error,
        "first_visible_frame_ms": first_visible_ms,
        "first_visible_frame_checksum": first_visible_checksum,
        "click_to_updated_frame_ms": click_latency_ms,
        "click_source": click_source,
        "updated_frame_checksum": updated_frame_checksum,
        "touch_latency": touch_latency,
        "touch_signal_latency": touch_signal_latency,
        "softbuffer_latency": softbuffer_latency,
        "compositor_frame_latency": compositor_frame_latency,
        "runtime_session_latency": runtime_session_latency,
        "boot_splash_checksum": boot_checksum,
        "captured_frame_count": len(captures),
        "dispatch_count": len(dispatches),
        "openlog_dri_seen": bool(openlog["dri_open_count"] or openlog["dri_ioctl_count"]),
        "openlog_kgsl_seen": bool(openlog["kgsl_open_count"] or openlog["kgsl_ioctl_count"]),
        "openlog_dri_denied": openlog["dri_denied"],
        "openlog_kgsl_denied": openlog["kgsl_denied"],
        "openlog_dri_open_count": openlog["dri_open_count"],
        "openlog_kgsl_open_count": openlog["kgsl_open_count"],
        "openlog_dri_ioctl_count": openlog["dri_ioctl_count"],
        "openlog_kgsl_ioctl_count": openlog["kgsl_ioctl_count"],
        "env_preload": env_preload,
        "egl_dri2_failed": egl_dri2_failed,
        "observed_buffer_type": buffer_type,
    }
    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir")
    parser.add_argument("--renderer")
    parser.add_argument("--output")
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    session_output = run_dir / "session-output.txt"
    if not session_output.is_file():
        raise SystemExit(f"missing session output: {session_output}")

    summary = load_summary(session_output, args.renderer)
    encoded = json.dumps(summary, indent=2, sort_keys=True)

    if args.output:
        Path(args.output).write_text(encoded + "\n", encoding="utf-8")

    print(encoded)


if __name__ == "__main__":
    main()
