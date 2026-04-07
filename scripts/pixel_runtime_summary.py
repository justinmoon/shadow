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
    r"\[shadow-runtime-demo[^\]]*\+\s*\d+ms\] runtime-dispatch-start "
    r"source=(\S+) type=(\S+) target=(\S+) wall_ms=(\d+)"
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
STATIC_READY_RE = re.compile(r"\[shadow-blitz-demo\] static-document-ready")
TIMESTAMP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)")
DISPLAY_ENV_WGPU_RE = re.compile(r"wgpu_backend_env=Some\(\"([^\"]+)\"\)")
DISPLAY_ENV_PRELOAD_RE = re.compile(r"shadow_linux_ld_preload=Some\(\"([^\"]+)\"\)")
NO_COMPAT_DEVICE_RE = re.compile(r"No compatible device found: (.+)$")
EGL_DRI2_FAIL_RE = re.compile(r"libEGL warning: egl: failed to create dri2 screen")
BUFFER_TYPE_RE = re.compile(r"\[shadow-guest-compositor\] buffer-observed type=(\S+) size=")


def strip_ansi(value: str) -> str:
    return ANSI_RE.sub("", value)


def parse_timestamp_ms(value: str) -> int:
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)


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

        match = CLIENT_START_RE.search(line)
        if match:
            client_start = json.loads(match.group(1))
            continue

        runtime_log_match = RUNTIME_LOG_RE.search(line)
        if runtime_log_match and fallback_start_wall_ms is None:
            fallback_start_wall_ms = int(runtime_log_match.group(1))

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

        if STATIC_READY_RE.search(line):
            inferred_mode = "static"
            continue

        no_compat_match = NO_COMPAT_DEVICE_RE.search(line)
        if no_compat_match and probe_error is None:
            probe_error = no_compat_match.group(1)
            continue

        if EGL_DRI2_FAIL_RE.search(line):
            egl_dri2_failed = True
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
            captures.append(
                {
                    "timestamp_ms": parse_timestamp_ms(timestamp_match.group(1)),
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
        "first_visible_frame_ms": first_visible_ms,
        "first_visible_frame_checksum": first_visible_checksum,
        "click_to_updated_frame_ms": click_latency_ms,
        "click_source": click_source,
        "updated_frame_checksum": updated_frame_checksum,
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
