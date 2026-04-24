#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-recover.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
RUN_TOKEN="recover-run-token-1234"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN"

rewrite_dynamic_bash_shebangs() {
  local root="${1:-$TMP_DIR}" path first_line
  while IFS= read -r -d '' path; do
    IFS= read -r first_line <"$path" || continue
    if [[ "$first_line" == "#!/usr/bin/env bash" ]]; then
      sed -i "1s|^#!/usr/bin/env bash$|#!$BASH|" "$path"
    fi
  done < <(find "$root" -type f -print0 2>/dev/null)
}

cat >"$MOCK_BIN/adb" <<'MOCK_ADB_EOF'
#!/usr/bin/env bash
set -euo pipefail

TRACE_MODE="${MOCK_TRACE_MODE:?}"
TRACE_RUN_TOKEN="${MOCK_TRACE_RUN_TOKEN:-}"
TRACE_ROOT_MODE="${MOCK_TRACE_ROOT_MODE:-available}"

emit_shell_command() {
  local cmd="$1"

  case "$cmd" in
    "cat /proc/sys/kernel/random/boot_id 2>/dev/null")
      printf '11111111-2222-3333-4444-555555555555\n'
      ;;
    "getprop sys.boot_completed")
      printf '1\n'
      ;;
    "getprop ro.boot.slot_suffix")
      printf '_a\n'
      ;;
    "logcat -L -d -v threadtime")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf '04-19 10:00:00.000 root root I shadow-hello-init: previous boot breadcrumb run_token=%s\n' "$TRACE_RUN_TOKEN"
      elif [[ "$TRACE_MODE" == "token-only" ]]; then
        printf '04-19 10:00:00.000 root root I bootstat: previous boot breadcrumb run_token=%s\n' "$TRACE_RUN_TOKEN"
      else
        printf '04-19 10:00:00.000 root root I bootstat: cold boot\n'
      fi
      ;;
    "dumpsys dropbox --print SYSTEM_BOOT")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf 'SYSTEM_BOOT\n[shadow-drm] restored previous boot trace run_token=%s\n' "$TRACE_RUN_TOKEN"
      else
        printf 'SYSTEM_BOOT\nBoot completed normally\n'
      fi
      ;;
    "dumpsys dropbox --print SYSTEM_LAST_KMSG")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf 'SYSTEM_LAST_KMSG\n<6>[shadow-hello-init] previous kernel breadcrumb\n'
      else
        printf 'SYSTEM_LAST_KMSG\nkernel boot without shadow tags\n'
      fi
      ;;
    "cat /dev/pmsg0")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf 'shadow-owned-init-run-token:%s\nshadow-owned-init-role:hello-init\nshadow-owned-init-impl:c-static\n' "$TRACE_RUN_TOKEN"
      elif [[ "$TRACE_MODE" == "token-only" ]]; then
        printf 'run_token=%s\n' "$TRACE_RUN_TOKEN"
      else
        printf 'audit: pmsg readable but empty of shadow tags\n'
      fi
      ;;
    *"/sys/fs/pstore"*)
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf '== /sys/fs/pstore/console-ramoops-0 ==\n<6>[shadow-hello-init] pstore breadcrumb run_token=%s\nshadow-owned-init-role:hello-init\n' "$TRACE_RUN_TOKEN"
      else
        printf 'no pstore entries\n'
      fi
      ;;
    *"ro.boot.bootreason"* )
      if [[ "$TRACE_MODE" == "matched" ]]; then
        cat <<PROPS
ro.boot.bootreason=reboot,adb
sys.boot.reason=reboot,adb
sys.boot.reason.last=
persist.sys.boot.reason.history=
ro.boot.bootreason_history=
ro.boot.bootreason_last=
PROPS
      else
        cat <<PROPS
ro.boot.bootreason=reboot,recovery
sys.boot.reason=reboot,recovery
sys.boot.reason.last=
persist.sys.boot.reason.history=
ro.boot.bootreason_history=
ro.boot.bootreason_last=
PROPS
      fi
      ;;
    "getprop")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        cat <<PROP
[ro.boot.slot_suffix]: [_a]
[ro.boot.bootreason]: [reboot,adb]
[shadow.boot.marker]: [shadow-hello-init]
PROP
      else
        cat <<PROP
[ro.boot.slot_suffix]: [_a]
[ro.boot.bootreason]: [reboot,recovery]
PROP
      fi
      ;;
    "logcat -d -v threadtime")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf '04-19 10:05:00.000 root root I shadow-drm: current boot kernel handoff summary\n'
      else
        printf '04-19 10:05:00.000 root root I ActivityManager: idle\n'
      fi
      ;;
    "dmesg 2>/dev/null")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf '<6>[shadow-drm] current kernel snapshot run_token=%s\n' "$TRACE_RUN_TOKEN"
      elif [[ "$TRACE_MODE" == "token-only" ]]; then
        printf '<6>[kernel] run_token=%s without shadow tag\n' "$TRACE_RUN_TOKEN"
      else
        printf '<6>[kernel] boot complete\n'
      fi
      ;;
    "logcat -b kernel -d -v threadtime")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf '<6>[shadow-drm] current kernel snapshot\n'
      else
        printf '<6>[kernel] boot complete\n'
      fi
      ;;
    *"shadow-kgsl-holder-scan-v1"*)
      if [[ "$TRACE_MODE" == "holder-timeout" ]]; then
        sleep 2
        exit 0
      fi
      printf 'format\tshadow-kgsl-holder-scan-v1\n'
      printf 'device_path\t/dev/kgsl-3d0\n'
      printf 'limits\t8192\t64\n'
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf 'holder\t432\t7\tsurfaceflinger\t/system/bin/surfaceflinger\n'
        printf 'summary\t18\t103\t1\tfalse\n'
      else
        printf 'summary\t17\t88\t0\tfalse\n'
      fi
      ;;
    *"/metadata/shadow-hello-init/by-token/"*"/stage.txt"* )
      if [[ "$TRACE_MODE" == "matched" || "$TRACE_MODE" == "token-only" ]]; then
        printf 'parent-probe-result=exit-0\n'
        exit 0
      elif [[ "$TRACE_MODE" == "probe-only-success" || "$TRACE_MODE" == "orange-gpu-loop-success" ]]; then
        printf 'parent-probe-result=skipped\n'
        exit 0
      elif [[ "$TRACE_MODE" == "compositor-scene-success" ]]; then
        printf 'parent-probe-result=exit-0\n'
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-success" || "$TRACE_MODE" == "shell-session-held-success" || "$TRACE_MODE" == "shell-session-runtime-touch-counter-success" || "$TRACE_MODE" == "app-direct-present-success" || "$TRACE_MODE" == "app-direct-present-touch-counter-success" || "$TRACE_MODE" == "app-direct-present-runtime-touch-counter-success" || "$TRACE_MODE" == "payload-partition-success" ]]; then
        printf 'parent-probe-result=exit-0\n'
        exit 0
      fi
      exit 3
      ;;
    *"/metadata/shadow-hello-init/by-token/"*"/probe-stage.txt"* )
      if [[ "$TRACE_MODE" == "matched" || "$TRACE_MODE" == "token-only" ]]; then
        printf 'parent-probe-attempt-3:vkCreateInstance-ok\n'
        exit 0
      elif [[ "$TRACE_MODE" == "probe-only-success" ]]; then
        printf 'orange-gpu-payload:vkEnumeratePhysicalDevices-ok\n'
        exit 0
      elif [[ "$TRACE_MODE" == "orange-gpu-loop-success" ]]; then
        printf 'orange-gpu-payload:firmware-probe-ok\n'
        exit 0
      elif [[ "$TRACE_MODE" == "compositor-scene-success" ]]; then
        printf 'orange-gpu-payload:compositor-scene-frame-captured\n'
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-success" ]]; then
        printf 'orange-gpu-payload:shell-session-app-frame-captured\n'
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-held-success" ]]; then
        printf 'orange-gpu-payload:shell-session-held-watchdog-proved\n'
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-runtime-touch-counter-success" ]]; then
        printf 'orange-gpu-payload:shell-session-runtime-touch-counter-proved\n'
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-success" ]]; then
        printf 'orange-gpu-payload:app-direct-present-frame-captured\n'
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-touch-counter-success" ]]; then
        printf 'orange-gpu-payload:app-direct-present-touch-counter-proved\n'
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-runtime-touch-counter-success" ]]; then
        printf 'orange-gpu-payload:app-direct-present-runtime-touch-counter-proved\n'
        exit 0
      elif [[ "$TRACE_MODE" == "payload-partition-success" ]]; then
        printf 'payload-partition-probe:payload-mounted\n'
        exit 0
      fi
      exit 3
      ;;
    *"/metadata/shadow-hello-init/by-token/"*"/probe-fingerprint.txt"* )
      if [[ "$TRACE_MODE" == "matched" || "$TRACE_MODE" == "token-only" || "$TRACE_MODE" == "probe-only-success" || "$TRACE_MODE" == "orange-gpu-loop-success" || "$TRACE_MODE" == "compositor-scene-success" || "$TRACE_MODE" == "shell-session-success" || "$TRACE_MODE" == "shell-session-held-success" || "$TRACE_MODE" == "shell-session-runtime-touch-counter-success" || "$TRACE_MODE" == "app-direct-present-success" || "$TRACE_MODE" == "app-direct-present-touch-counter-success" || "$TRACE_MODE" == "app-direct-present-runtime-touch-counter-success" || "$TRACE_MODE" == "payload-partition-success" ]]; then
        printf 'path=/dev/kgsl-3d0 present=true kind=char mode=666 uid=1000 gid=1000 major=508 minor=0\n'
        exit 0
      fi
      exit 3
      ;;
    *"/metadata/shadow-hello-init/by-token/"*"/probe-report.txt"* )
      if [[ "$TRACE_MODE" == "matched" || "$TRACE_MODE" == "token-only" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=orange-gpu-payload:kgsl-open-readonly
child_timed_out=true
child_completed=false
exit_status=
wchan=do_wait
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "probe-only-success" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=orange-gpu-payload:vkEnumeratePhysicalDevices-ok
child_timed_out=false
child_completed=true
exit_status=0
wchan=
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "orange-gpu-loop-success" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=firmware-probe-ok
child_timed_out=false
child_completed=true
exit_status=0
wchan=
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "compositor-scene-success" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=orange-gpu-payload:compositor-scene-frame-captured
child_timed_out=false
child_completed=true
exit_status=0
wchan=
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-success" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=orange-gpu-payload:shell-session-app-frame-captured
child_timed_out=false
child_completed=true
exit_status=0
wchan=
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-held-success" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=orange-gpu-payload:shell-session-held-watchdog-proved
child_timed_out=true
child_completed=false
exit_status=
wchan=do_wait
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-runtime-touch-counter-success" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=orange-gpu-payload:shell-session-runtime-touch-counter-proved
child_timed_out=false
child_completed=true
exit_status=0
wchan=
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-success" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=orange-gpu-payload:app-direct-present-frame-captured
child_timed_out=false
child_completed=true
exit_status=0
wchan=
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-touch-counter-success" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=orange-gpu-payload:app-direct-present-touch-counter-proved
child_timed_out=false
child_completed=true
exit_status=0
wchan=
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-runtime-touch-counter-success" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
observed_probe_stage=orange-gpu-payload:app-direct-present-runtime-touch-counter-proved
child_timed_out=false
child_completed=true
exit_status=0
wchan=
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "payload-partition-success" ]]; then
        cat <<EOF
probe_label=payload-partition-probe
observed_probe_stage=payload-partition-probe:payload-mounted
child_timed_out=false
child_completed=true
exit_status=0
wchan=
EOF
        exit 0
      fi
      exit 3
      ;;
    *"/metadata/shadow-hello-init/by-token/"*"/probe-summary.json"* )
      if [[ "$TRACE_MODE" == "probe-only-success" ]]; then
        cat <<'EOF'
{
  "scene": "flat-orange",
  "present_kms": true,
  "software_backed": false,
  "distinct_color_count": 1,
  "distinct_color_samples_rgba8": [
    "ff7a00ff"
  ],
  "checksum_fnv1a64": "summary-checksum",
  "adapter": {
    "backend": "Vulkan"
  },
  "kms_present": {
    "connector": "DSI-1"
  }
}
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "orange-gpu-loop-success" ]]; then
        cat <<'EOF'
{
  "mode": "orange-gpu-loop",
  "scene": "orange-gpu-loop",
  "target_duration_secs": 3,
  "frame_interval_millis": 250,
  "frames_rendered": 11,
  "scanout_updates": 11,
  "distinct_frame_count": 2,
  "frame_label_samples": [
    "flat-orange",
    "smoke"
  ],
  "frame_checksum_samples_fnv1a64": [
    "bb77813ec3232325",
    "e317ffe624895aa5"
  ],
  "first_frame": {
    "label": "flat-orange",
    "byte_len": 65536,
    "checksum_fnv1a64": "bb77813ec3232325",
    "distinct_color_count": 1,
    "distinct_color_samples_rgba8": [
      "ff7a00ff"
    ],
    "opaque_pixel_count": 16384,
    "nonzero_alpha_pixel_count": 16384
  },
  "last_frame": {
    "label": "smoke",
    "byte_len": 65536,
    "checksum_fnv1a64": "e317ffe624895aa5",
    "distinct_color_count": 3,
    "distinct_color_samples_rgba8": [
      "651c00ff",
      "ff8a42ff",
      "ffe0a6ff"
    ],
    "opaque_pixel_count": 16384,
    "nonzero_alpha_pixel_count": 16384
  },
  "present_kms": true,
  "software_backed": false,
  "adapter": {
    "backend": "Vulkan"
  },
  "kms_present": {
    "connector": "DSI-1",
    "present_count": 11,
    "hold_secs": 3
  }
}
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "compositor-scene-success" ]]; then
        cat <<EOF
{
  "kind": "compositor-scene",
  "frame_path": "/metadata/shadow-hello-init/by-token/$TRACE_RUN_TOKEN/compositor-frame.ppm",
  "frame_bytes": 17
}
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-success" ]]; then
        trace_app_id="${MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID:-counter}"
        cat <<EOF
{
  "kind": "shell-session",
  "startup_mode": "shell",
  "app_id": "$trace_app_id",
  "shell_session_probe": {
    "shell_mode_enabled": true,
    "home_frame_done": true,
    "start_app_requested": true,
    "app_launch_mode_logged": true,
    "mapped_window": true,
    "surface_app_tracked": true,
    "app_frame_artifact_logged": true,
    "app_frame_captured": true
  },
  "shell_session_probe_ok": true,
  "frame_path": "/metadata/shadow-hello-init/by-token/$TRACE_RUN_TOKEN/compositor-frame.ppm",
  "frame_bytes": 20
}
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-held-success" ]]; then
        trace_app_id="${MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID:-counter}"
        cat <<EOF
{
  "kind": "shell-session-held",
  "startup_mode": "shell",
  "app_id": "$trace_app_id",
  "shell_session_probe": {
    "shell_mode_enabled": true,
    "home_frame_done": true,
    "start_app_requested": true,
    "app_launch_mode_logged": true,
    "mapped_window": true,
    "surface_app_tracked": true,
    "app_frame_artifact_logged": true,
    "app_frame_captured": true
  },
  "shell_session_probe_ok": true,
  "frame_path": "/metadata/shadow-hello-init/by-token/$TRACE_RUN_TOKEN/compositor-frame.ppm",
  "frame_bytes": 20
}
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-runtime-touch-counter-success" ]]; then
        cat <<EOF
{
  "kind": "shell-session-runtime-touch-counter",
  "startup_mode": "shell",
  "app_id": "counter",
  "shell_session_probe": {
    "shell_mode_enabled": true,
    "home_frame_done": true,
    "start_app_requested": true,
    "app_launch_mode_logged": true,
    "mapped_window": true,
    "surface_app_tracked": true,
    "app_frame_artifact_logged": true,
    "app_frame_captured": true
  },
  "shell_session_probe_ok": true,
  "touch_counter_probe": {
    "injection": "synthetic-compositor",
    "input_observed": true,
    "tap_dispatched": true,
    "counter_incremented": true,
    "post_touch_frame_committed": true,
    "post_touch_frame_artifact_logged": true,
    "touch_latency_present": true,
    "post_touch_frame_captured": true
  },
  "touch_counter_probe_ok": true,
  "frame_path": "/metadata/shadow-hello-init/by-token/$TRACE_RUN_TOKEN/compositor-frame.ppm",
  "frame_bytes": 20
}
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-success" ]]; then
        trace_app_id="${MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID:-rust-demo}"
        cat <<EOF
{
  "kind": "app-direct-present",
  "startup_mode": "app",
  "app_id": "$trace_app_id",
  "frame_path": "/metadata/shadow-hello-init/by-token/$TRACE_RUN_TOKEN/compositor-frame.ppm",
  "frame_bytes": 20
}
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-touch-counter-success" ]]; then
        cat <<EOF
{
  "kind": "app-direct-present-touch-counter",
  "startup_mode": "app",
  "app_id": "rust-demo",
  "touch_counter_probe": {
    "injection": "synthetic-compositor",
    "input_observed": true,
    "tap_dispatched": true,
    "counter_incremented": true,
    "post_touch_frame_committed": true,
    "post_touch_frame_artifact_logged": true,
    "touch_latency_present": true,
    "post_touch_frame_captured": true
  },
  "touch_counter_probe_ok": true,
  "frame_path": "/metadata/shadow-hello-init/by-token/$TRACE_RUN_TOKEN/compositor-frame.ppm",
  "frame_bytes": 20
}
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-runtime-touch-counter-success" ]]; then
        cat <<EOF
{
  "kind": "app-direct-present-runtime-touch-counter",
  "startup_mode": "app",
  "app_id": "counter",
  "touch_counter_probe": {
    "injection": "synthetic-compositor",
    "input_observed": true,
    "tap_dispatched": true,
    "counter_incremented": true,
    "post_touch_frame_committed": true,
    "post_touch_frame_artifact_logged": true,
    "touch_latency_present": true,
    "post_touch_frame_captured": true
  },
  "touch_counter_probe_ok": true,
  "frame_path": "/metadata/shadow-hello-init/by-token/$TRACE_RUN_TOKEN/compositor-frame.ppm",
  "frame_bytes": 20
}
EOF
        exit 0
      elif [[ "$TRACE_MODE" == "payload-partition-success" || "$TRACE_MODE" == "payload-partition-data-success" || "$TRACE_MODE" == "payload-partition-data-missing-mount" || "$TRACE_MODE" == "payload-partition-shadow-logical-success" || "$TRACE_MODE" == "payload-partition-shadow-logical-missing-mount" ]]; then
        payload_root="/metadata/shadow-payload/by-token/$TRACE_RUN_TOKEN"
        payload_manifest_path="$payload_root/manifest.env"
        payload_marker_path="$payload_root/payload.txt"
        mounted_roots_json='[
    "/metadata"
  ]'
        userdata_mount_error=""
        shadow_logical_mount_error=""
        payload_source="metadata"
        if [[ "$TRACE_MODE" == "payload-partition-data-success" || "$TRACE_MODE" == "payload-partition-data-missing-mount" ]]; then
          payload_root="/data/local/tmp/shadow-payload/by-token/$TRACE_RUN_TOKEN"
          payload_manifest_path="/metadata/shadow-payload/by-token/$TRACE_RUN_TOKEN/manifest.env"
          payload_marker_path="$payload_root/payload.txt"
          if [[ "$TRACE_MODE" == "payload-partition-data-success" ]]; then
            mounted_roots_json='[
    "/metadata",
    "/data"
  ]'
          else
            userdata_mount_error="userdata-mount-f2fs:Invalid argument (os error 22)"
          fi
        elif [[ "$TRACE_MODE" == "payload-partition-shadow-logical-success" || "$TRACE_MODE" == "payload-partition-shadow-logical-missing-mount" ]]; then
          payload_source="shadow-logical-partition"
          payload_root="/shadow-payload"
          payload_manifest_path="/shadow-payload/manifest.env"
          payload_marker_path="/shadow-payload/payload.txt"
          if [[ "$TRACE_MODE" == "payload-partition-shadow-logical-success" ]]; then
            mounted_roots_json='[
    "/metadata",
    "/shadow-payload"
  ]'
          else
            shadow_logical_mount_error="shadow-logical-dm:lp-partition-missing:shadow_payload_a"
          fi
        fi
        cat <<EOF
{
  "kind": "payload-partition-probe",
  "ok": true,
  "payload_strategy": "metadata-shadow-payload-v1",
  "payload_source": "$payload_source",
  "payload_root": "$payload_root",
  "payload_manifest_path": "$payload_manifest_path",
  "payload_marker_path": "$payload_marker_path",
  "payload_version": "shadow-payload-probe-v1",
  "payload_fingerprint": "sha256:payloadfingerprint",
  "payload_marker_fingerprint": "sha256:payloadfingerprint",
  "payload_fingerprint_verified": true,
  "mounted_roots": $mounted_roots_json,
  "userdata_mount_error": "$userdata_mount_error",
  "shadow_logical_mount_error": "$shadow_logical_mount_error",
  "fallback_path": "/orange-gpu",
  "blocker": "none",
  "blocker_detail": ""
}
EOF
        exit 0
      fi
      exit 3
      ;;
    *"/metadata/shadow-hello-init/by-token/"*"/compositor-frame.ppm"* )
      if [[ "$TRACE_MODE" == "compositor-scene-success" ]]; then
        printf 'P6\n2 1\n255\n\xff\x7a\x00\x00\x00\x00'
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-success" || "$TRACE_MODE" == "shell-session-held-success" ]]; then
        case "${MOCK_TRACE_APP_DIRECT_PRESENT_FRAME_APP_ID:-${MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID:-counter}}" in
          rust-demo)
            printf 'P6\n3 1\n255\n\x17\x36\x2c\x74\xd3\xae\xf7\xfa\xfc'
            ;;
          timeline)
            printf 'P6\n3 1\n255\n\x31\x1f\x09\x2b\x18\x0e\x32\x20\x08'
            ;;
          *)
            printf 'P6\n3 1\n255\n\x30\x16\x0b\xff\xb8\x2f\xff\xda\x89'
            ;;
        esac
        exit 0
      elif [[ "$TRACE_MODE" == "shell-session-runtime-touch-counter-success" ]]; then
        printf 'P6\n3 1\n255\n\x1b\x12\x08\x18\x16\x16\xee\xec\xec'
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-success" ]]; then
        case "${MOCK_TRACE_APP_DIRECT_PRESENT_FRAME_APP_ID:-${MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID:-rust-demo}}" in
          counter)
            printf 'P6\n3 1\n255\n\x0b\x16\x30\x10\x24\x3b\x2f\xb8\xff'
            ;;
          timeline)
            printf 'P6\n3 1\n255\n\x31\x1f\x09\x2b\x18\x0e\x32\x20\x08'
            ;;
          *)
            printf 'P6\n3 1\n255\n\x17\x36\x2c\x74\xd3\xae\xf7\xfa\xfc'
            ;;
        esac
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-touch-counter-success" ]]; then
        printf 'P6\n3 1\n255\n\x17\x36\x2c\x74\xd3\xae\xf7\xfa\xfc'
        exit 0
      elif [[ "$TRACE_MODE" == "app-direct-present-runtime-touch-counter-success" ]]; then
        printf 'P6\n3 1\n255\n\x2a\x12\x09\xff\x8a\x42\xff\xe0\xa6'
        exit 0
      fi
      exit 3
      ;;
    *"/metadata/shadow-hello-init/by-token/"*"/probe-timeout-class.txt"* )
      if [[ "$TRACE_MODE" == "matched" || "$TRACE_MODE" == "token-only" ]]; then
        cat <<EOF
probe_label=orange-gpu-payload
classification_checkpoint=kgsl-timeout-gmu-hfi
classification_bucket=gmu-hfi
classification_matched_needle=a6xx_gmu_hfi_start
wchan=do_wait
EOF
        exit 0
      fi
      exit 3
      ;;
    *)
      echo "mock adb: unexpected shell command: $cmd" >&2
      exit 1
      ;;
  esac
}

if [[ "${1:-}" == "devices" ]]; then
  printf 'List of devices attached\nTESTSERIAL\tdevice\n'
  exit 0
fi

if [[ "${1:-}" == "-s" ]]; then
  serial="${2:-}"
  shift 2
  [[ "$serial" == "TESTSERIAL" ]] || {
    echo "mock adb: unexpected serial $serial" >&2
    exit 1
  }
fi

case "${1:-}" in
  shell)
    shift
    if [[ "$#" -eq 1 && ( "$1" == "/debug_ramdisk/su 0 sh -c id" || "$1" == "su 0 sh -c id" ) ]]; then
      if [[ "$TRACE_ROOT_MODE" == "available" ]]; then
        printf 'uid=0(root) gid=0(root) groups=0(root)\n'
        exit 0
      fi
      exit 1
    fi
    if [[ "$#" -eq 3 && ( "$1" == "/debug_ramdisk/su" || "$1" == "su" ) && "$2" == "0" && "$3" == "sh" ]]; then
      if [[ "$TRACE_ROOT_MODE" != "available" ]]; then
        exit 1
      fi
      cmd="$(cat)"
      emit_shell_command "$cmd"
      exit 0
    fi
    cmd="$*"
    emit_shell_command "$cmd"
    ;;
  *)
    echo "mock adb: unexpected args: $*" >&2
    exit 1
    ;;
esac
MOCK_ADB_EOF

chmod 0755 "$MOCK_BIN/adb"
rewrite_dynamic_bash_shebangs

assert_json_field() {
  local json_path key_path expected
  json_path="$1"
  key_path="$2"
  expected="$3"
  python3 - "$json_path" "$key_path" "$expected" <<'PY'
import json
import sys

path, key_path, expected = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

value = data
for part in key_path.split("/"):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]

if isinstance(value, bool):
    rendered = "true" if value else "false"
elif value is None:
    rendered = ""
else:
    rendered = str(value)

if rendered != expected:
    raise SystemExit(f"{key_path}: expected {expected!r}, got {rendered!r}")
PY
}

write_recover_context() {
  local parent_dir image_path run_token orange_gpu_mode app_direct_present_app_id
  local app_direct_present_client_kind app_direct_present_runtime_bundle_env
  local app_direct_present_runtime_bundle_path app_direct_present_typescript_renderer
  local app_direct_present_metadata_shape app_direct_present_contract_metadata
  parent_dir="$1"
  image_path="$2"
  run_token="$3"
  orange_gpu_mode="${4:-gpu-render}"
  app_direct_present_app_id="${5:-rust-demo}"
  app_direct_present_metadata_shape="${6:-current}"
  app_direct_present_client_kind=rust
  app_direct_present_runtime_bundle_env=""
  app_direct_present_runtime_bundle_path=""
  app_direct_present_typescript_renderer=""
  case "$app_direct_present_app_id" in
    counter)
      app_direct_present_client_kind=typescript
      app_direct_present_runtime_bundle_env=SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
      app_direct_present_runtime_bundle_path=/orange-gpu/app-direct-present/runtime-app-counter-bundle.js
      app_direct_present_typescript_renderer=gpu
      ;;
    timeline)
      app_direct_present_client_kind=typescript
      app_direct_present_runtime_bundle_env=SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH
      app_direct_present_runtime_bundle_path=/orange-gpu/app-direct-present/runtime-app-timeline-bundle.js
      app_direct_present_typescript_renderer=gpu
      ;;
  esac
  app_direct_present_contract_metadata=""
  if [[ "$app_direct_present_metadata_shape" != "legacy" ]]; then
    app_direct_present_contract_metadata="$(cat <<EOF
  "app_direct_present_app_id": "$app_direct_present_app_id",
  "app_direct_present_client_kind": "$app_direct_present_client_kind",
  "app_direct_present_runtime_bundle_env": "$app_direct_present_runtime_bundle_env",
  "app_direct_present_runtime_bundle_path": "$app_direct_present_runtime_bundle_path",
  "app_direct_present_typescript_renderer": "$app_direct_present_typescript_renderer",
EOF
)"
  fi

  mkdir -p "$parent_dir"
  cat >"$parent_dir/status.json" <<EOF
{
  "image": "$image_path",
  "kind": "boot_oneshot"
}
EOF
  if [[ "$orange_gpu_mode" == "compositor-scene" ]]; then
    cat >"$image_path.hello-init.json" <<EOF
{
  "kind": "hello_init_build",
  "run_token": "$run_token",
  "orange_gpu_mode": "compositor-scene",
  "orange_gpu_firmware_helper": true,
  "log_kmsg": true,
  "log_pmsg": true,
  "orange_gpu_metadata_stage_breadcrumb": true,
  "metadata_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/stage.txt",
  "metadata_probe_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-stage.txt",
  "metadata_probe_fingerprint_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-fingerprint.txt",
  "metadata_probe_report_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-report.txt",
  "metadata_probe_timeout_class_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-timeout-class.txt",
  "metadata_probe_summary_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-summary.json",
  "metadata_compositor_frame_path": "/metadata/shadow-hello-init/by-token/$run_token/compositor-frame.ppm"
}
EOF
  elif [[ "$orange_gpu_mode" == "shell-session" || "$orange_gpu_mode" == "shell-session-held" || "$orange_gpu_mode" == "shell-session-runtime-touch-counter" ]]; then
    cat >"$image_path.hello-init.json" <<EOF
{
  "kind": "hello_init_build",
  "run_token": "$run_token",
  "orange_gpu_mode": "$orange_gpu_mode",
  "orange_gpu_firmware_helper": true,
  "shell_session_start_app_id": "$app_direct_present_app_id",
  "log_kmsg": true,
  "log_pmsg": true,
$app_direct_present_contract_metadata
  "orange_gpu_metadata_stage_breadcrumb": true,
  "metadata_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/stage.txt",
  "metadata_probe_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-stage.txt",
  "metadata_probe_fingerprint_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-fingerprint.txt",
  "metadata_probe_report_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-report.txt",
  "metadata_probe_timeout_class_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-timeout-class.txt",
  "metadata_probe_summary_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-summary.json",
  "metadata_compositor_frame_path": "/metadata/shadow-hello-init/by-token/$run_token/compositor-frame.ppm"
}
EOF
  elif [[ "$orange_gpu_mode" == "app-direct-present" || "$orange_gpu_mode" == "app-direct-present-touch-counter" || "$orange_gpu_mode" == "app-direct-present-runtime-touch-counter" ]]; then
    cat >"$image_path.hello-init.json" <<EOF
{
  "kind": "hello_init_build",
  "run_token": "$run_token",
  "orange_gpu_mode": "$orange_gpu_mode",
  "orange_gpu_firmware_helper": true,
  "log_kmsg": true,
  "log_pmsg": true,
$app_direct_present_contract_metadata
  "orange_gpu_metadata_stage_breadcrumb": true,
  "metadata_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/stage.txt",
  "metadata_probe_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-stage.txt",
  "metadata_probe_fingerprint_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-fingerprint.txt",
  "metadata_probe_report_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-report.txt",
  "metadata_probe_timeout_class_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-timeout-class.txt",
  "metadata_probe_summary_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-summary.json",
  "metadata_compositor_frame_path": "/metadata/shadow-hello-init/by-token/$run_token/compositor-frame.ppm"
}
EOF
  elif [[ "$orange_gpu_mode" == "orange-gpu-loop" ]]; then
    cat >"$image_path.hello-init.json" <<EOF
{
  "kind": "hello_init_build",
  "run_token": "$run_token",
  "orange_gpu_mode": "orange-gpu-loop",
  "orange_gpu_scene": "orange-gpu-loop",
  "orange_gpu_firmware_helper": true,
  "log_kmsg": true,
  "log_pmsg": true,
  "orange_gpu_metadata_stage_breadcrumb": true,
  "metadata_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/stage.txt",
  "metadata_probe_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-stage.txt",
  "metadata_probe_fingerprint_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-fingerprint.txt",
  "metadata_probe_report_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-report.txt",
  "metadata_probe_timeout_class_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-timeout-class.txt",
  "metadata_probe_summary_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-summary.json"
}
EOF
  elif [[ "$orange_gpu_mode" == "payload-partition-probe" ]]; then
    cat >"$image_path.hello-init.json" <<EOF
{
  "kind": "hello_init_build",
  "run_token": "$run_token",
  "orange_gpu_mode": "payload-partition-probe",
  "orange_gpu_metadata_stage_breadcrumb": true,
  "log_kmsg": true,
  "log_pmsg": true,
  "metadata_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/stage.txt",
  "metadata_probe_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-stage.txt",
  "metadata_probe_fingerprint_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-fingerprint.txt",
  "metadata_probe_report_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-report.txt",
  "metadata_probe_timeout_class_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-timeout-class.txt",
  "metadata_probe_summary_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-summary.json",
  "payload_probe_strategy": "metadata-shadow-payload-v1",
  "payload_probe_source": "metadata",
  "payload_probe_root": "/metadata/shadow-payload/by-token/$run_token",
  "payload_probe_manifest_path": "/metadata/shadow-payload/by-token/$run_token/manifest.env",
  "payload_probe_fallback_path": "/orange-gpu"
}
EOF
  else
    cat >"$image_path.hello-init.json" <<EOF
{
  "kind": "hello_init_build",
  "run_token": "$run_token",
  "orange_gpu_mode": "gpu-render",
  "orange_gpu_scene": "flat-orange",
  "orange_gpu_firmware_helper": true,
  "log_kmsg": true,
  "log_pmsg": true,
  "orange_gpu_metadata_stage_breadcrumb": true,
  "metadata_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/stage.txt",
  "metadata_probe_stage_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-stage.txt",
  "metadata_probe_fingerprint_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-fingerprint.txt",
  "metadata_probe_report_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-report.txt",
  "metadata_probe_timeout_class_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-timeout-class.txt",
  "metadata_probe_summary_path": "/metadata/shadow-hello-init/by-token/$run_token/probe-summary.json"
}
EOF
  fi
}

MATCHED_PARENT="$TMP_DIR/output-matched"
MATCHED_IMAGE="$TMP_DIR/output-matched.img"
MATCHED_OUTPUT="$MATCHED_PARENT/recover-traces"
write_recover_context "$MATCHED_PARENT" "$MATCHED_IMAGE" "$RUN_TOKEN"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=matched \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$MATCHED_OUTPUT" >/dev/null

test -f "$MATCHED_OUTPUT/channels/logcat-last.txt"
test -f "$MATCHED_OUTPUT/channels/pstore.txt"
test -f "$MATCHED_OUTPUT/meta/bootreason-props-summary.txt"
test -f "$MATCHED_OUTPUT/meta/expected-run-token.txt"
test -f "$MATCHED_OUTPUT/meta/root-state.txt"
test -f "$MATCHED_OUTPUT/matches/all-shadow-tags.txt"
test -f "$MATCHED_OUTPUT/matches/all-run-token-matches.txt"
grep -Fq 'shadow-hello-init' "$MATCHED_OUTPUT/matches/all-shadow-tags.txt"
grep -Fq 'shadow-owned-init-role:hello-init' "$MATCHED_OUTPUT/matches/all-shadow-tags.txt"
grep -Fq "$RUN_TOKEN" "$MATCHED_OUTPUT/matches/all-run-token-matches.txt"
assert_json_field "$MATCHED_OUTPUT/status.json" recovered_previous_boot_traces true
assert_json_field "$MATCHED_OUTPUT/status.json" matched_any_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" matched_any_correlated_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" proof_ok false
assert_json_field "$MATCHED_OUTPUT/status.json" expected_run_token "$RUN_TOKEN"
assert_json_field "$MATCHED_OUTPUT/status.json" expected_run_token_source image-metadata
assert_json_field "$MATCHED_OUTPUT/status.json" expected_durable_logging_summary "kmsg=true,pmsg=true"
assert_json_field "$MATCHED_OUTPUT/status.json" expected_metadata_stage_breadcrumb true
assert_json_field "$MATCHED_OUTPUT/status.json" expected_metadata_stage_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/stage.txt"
assert_json_field "$MATCHED_OUTPUT/status.json" expected_metadata_probe_stage_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/probe-stage.txt"
assert_json_field "$MATCHED_OUTPUT/status.json" expected_metadata_probe_fingerprint_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/probe-fingerprint.txt"
assert_json_field "$MATCHED_OUTPUT/status.json" expected_metadata_probe_report_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/probe-report.txt"
assert_json_field "$MATCHED_OUTPUT/status.json" expected_metadata_probe_timeout_class_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/probe-timeout-class.txt"
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_stage_present true
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_stage_value "parent-probe-result=exit-0"
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_stage_actual_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_stage_exit_code "0"
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_stage_present true
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_stage_value "parent-probe-attempt-3:vkCreateInstance-ok"
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_stage_actual_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_stage_exit_code "0"
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_fingerprint_present true
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_fingerprint_actual_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_fingerprint_exit_code "0"
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_report_present true
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_report_actual_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_report_exit_code "0"
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_report_observed_stage "orange-gpu-payload:kgsl-open-readonly"
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_report_timed_out true
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_report_wchan do_wait
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_timeout_class_present true
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_timeout_class_checkpoint kgsl-timeout-gmu-hfi
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_timeout_class_bucket gmu-hfi
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_timeout_class_matched_needle a6xx_gmu_hfi_start
assert_json_field "$MATCHED_OUTPUT/status.json" metadata_probe_timeout_class_wchan do_wait
assert_json_field "$MATCHED_OUTPUT/status.json" absence_reason_summary ""
assert_json_field "$MATCHED_OUTPUT/status.json" previous_boot_channel_attempts 5
assert_json_field "$MATCHED_OUTPUT/status.json" previous_boot_channels_with_matches 4
assert_json_field "$MATCHED_OUTPUT/status.json" current_boot_channel_attempts 6
assert_json_field "$MATCHED_OUTPUT/status.json" current_boot_channels_with_matches 1
assert_json_field "$MATCHED_OUTPUT/status.json" uncorrelated_previous_boot_channels_with_matches 1
assert_json_field "$MATCHED_OUTPUT/status.json" previous_boot_channels_with_shadow_hints 1
assert_json_field "$MATCHED_OUTPUT/status.json" matched_any_uncorrelated_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" android_has_kgsl_holders true
assert_json_field "$MATCHED_OUTPUT/status.json" android_kgsl_holder_count 1
assert_json_field "$MATCHED_OUTPUT/status.json" root_available true
assert_json_field "$MATCHED_OUTPUT/status.json" root_id "uid=0(root) gid=0(root) groups=0(root)"
assert_json_field "$MATCHED_OUTPUT/status.json" channels/logcat-last/matched_expected_run_token true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/logcat-last/correlated true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/logcat-last/correlation_state correlated
assert_json_field "$MATCHED_OUTPUT/status.json" channels/logcat-last/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-boot/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-boot/matched_expected_run_token true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-last-kmsg/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-last-kmsg/matched_expected_run_token false
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-last-kmsg/correlation_state shadow-hint-only
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pmsg0/requested_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pmsg0/actual_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pmsg0/matched_expected_run_token true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/requested_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/actual_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/matched_expected_run_token true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/correlated true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/kernel-current-best-effort/source_kind root-dmesg
assert_json_field "$MATCHED_OUTPUT/status.json" channels/kernel-current-best-effort/requested_access_mode root-preferred
assert_json_field "$MATCHED_OUTPUT/status.json" channels/kernel-current-best-effort/actual_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" channels/kernel-current-best-effort/matched_expected_run_token true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/kernel-current-best-effort/correlated true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/kgsl-holder-scan/source_kind root-proc-fd-scan
assert_json_field "$MATCHED_OUTPUT/status.json" channels/kgsl-holder-scan/holder_count 1
assert_json_field "$MATCHED_OUTPUT/status.json" channels/kgsl-holder-scan/has_holders true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/kgsl-holder-scan/holders/0/comm surfaceflinger
assert_json_field "$MATCHED_OUTPUT/status.json" channels/bootreason-props/available true
assert_json_field "$MATCHED_OUTPUT/status.json" bootreason_props/ro.boot.bootreason reboot,adb

CLEAN_PARENT="$TMP_DIR/output-clean"
CLEAN_IMAGE="$TMP_DIR/output-clean.img"
CLEAN_OUTPUT="$CLEAN_PARENT/recover-traces"
write_recover_context "$CLEAN_PARENT" "$CLEAN_IMAGE" "$RUN_TOKEN"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=clean \
  MOCK_TRACE_ROOT_MODE=unavailable \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$CLEAN_OUTPUT" >/dev/null

test -f "$CLEAN_OUTPUT/channels/getprop.txt"
assert_json_field "$CLEAN_OUTPUT/status.json" recovered_previous_boot_traces false
assert_json_field "$CLEAN_OUTPUT/status.json" matched_any_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" proof_ok false
assert_json_field "$CLEAN_OUTPUT/status.json" matched_any_uncorrelated_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" expected_durable_logging_summary "kmsg=true,pmsg=true"
assert_json_field "$CLEAN_OUTPUT/status.json" expected_metadata_stage_breadcrumb true
assert_json_field "$CLEAN_OUTPUT/status.json" metadata_stage_present false
assert_json_field "$CLEAN_OUTPUT/status.json" metadata_stage_actual_access_mode root-unavailable
assert_json_field "$CLEAN_OUTPUT/status.json" metadata_stage_exit_code "125"
assert_json_field "$CLEAN_OUTPUT/status.json" metadata_probe_stage_present false
assert_json_field "$CLEAN_OUTPUT/status.json" metadata_probe_stage_actual_access_mode root-unavailable
assert_json_field "$CLEAN_OUTPUT/status.json" metadata_probe_stage_exit_code "125"
assert_json_field "$CLEAN_OUTPUT/status.json" metadata_probe_fingerprint_present false
assert_json_field "$CLEAN_OUTPUT/status.json" metadata_probe_fingerprint_actual_access_mode root-unavailable
assert_json_field "$CLEAN_OUTPUT/status.json" metadata_probe_fingerprint_exit_code "125"
assert_json_field "$CLEAN_OUTPUT/status.json" absence_reason_summary "pmsg_root_unavailable,pstore_root_unavailable"
assert_json_field "$CLEAN_OUTPUT/status.json" previous_boot_channel_attempts 5
assert_json_field "$CLEAN_OUTPUT/status.json" previous_boot_channels_with_matches 0
assert_json_field "$CLEAN_OUTPUT/status.json" current_boot_channel_attempts 6
assert_json_field "$CLEAN_OUTPUT/status.json" current_boot_channels_with_matches 0
assert_json_field "$CLEAN_OUTPUT/status.json" android_has_kgsl_holders ""
assert_json_field "$CLEAN_OUTPUT/status.json" android_kgsl_holder_count ""
assert_json_field "$CLEAN_OUTPUT/status.json" root_available false
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pmsg0/requested_access_mode root
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pmsg0/actual_access_mode root-unavailable
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pmsg0/available false
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pmsg0/matched_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pstore/requested_access_mode root
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pstore/actual_access_mode root-unavailable
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pstore/available false
assert_json_field "$CLEAN_OUTPUT/status.json" channels/kernel-current-best-effort/source_kind adb-logcat-kernel
assert_json_field "$CLEAN_OUTPUT/status.json" channels/kernel-current-best-effort/actual_access_mode adb
assert_json_field "$CLEAN_OUTPUT/status.json" channels/kgsl-holder-scan/actual_access_mode root-unavailable
assert_json_field "$CLEAN_OUTPUT/status.json" channels/kgsl-holder-scan/available false
assert_json_field "$CLEAN_OUTPUT/status.json" bootreason_props/sys.boot.reason reboot,recovery

TOKEN_ONLY_PARENT="$TMP_DIR/output-token-only"
TOKEN_ONLY_IMAGE="$TMP_DIR/output-token-only.img"
TOKEN_ONLY_OUTPUT="$TOKEN_ONLY_PARENT/recover-traces"
write_recover_context "$TOKEN_ONLY_PARENT" "$TOKEN_ONLY_IMAGE" "$RUN_TOKEN"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=token-only \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$TOKEN_ONLY_OUTPUT" >/dev/null

assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" matched_any_shadow_tags false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" matched_any_expected_run_token true
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" proof_ok false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" recovered_previous_boot_traces false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" expected_durable_logging_summary "kmsg=true,pmsg=true"
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" expected_metadata_stage_breadcrumb true
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" metadata_stage_present true
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" metadata_stage_value "parent-probe-result=exit-0"
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" metadata_stage_actual_access_mode root
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" metadata_probe_stage_present true
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" metadata_probe_stage_value "parent-probe-attempt-3:vkCreateInstance-ok"
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" metadata_probe_stage_actual_access_mode root
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" metadata_probe_fingerprint_present true
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" metadata_probe_fingerprint_actual_access_mode root
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" previous_boot_channels_with_matches 0
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" current_boot_channel_attempts 6
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/kernel-current-best-effort/source_kind root-dmesg
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/kernel-current-best-effort/correlation_state token-only
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" android_has_kgsl_holders false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/kgsl-holder-scan/holder_count 0
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/logcat-last/correlation_state token-only
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/logcat-last/correlated false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/logcat-last/matched_expected_run_token true
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/logcat-last/matched_shadow_tags false

PROBE_ONLY_PARENT="$TMP_DIR/output-probe-only"
PROBE_ONLY_IMAGE="$TMP_DIR/output-probe-only.img"
PROBE_ONLY_OUTPUT="$PROBE_ONLY_PARENT/recover-traces"
write_recover_context "$PROBE_ONLY_PARENT" "$PROBE_ONLY_IMAGE" "$RUN_TOKEN"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=probe-only-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$PROBE_ONLY_OUTPUT" >/dev/null

assert_json_field "$PROBE_ONLY_OUTPUT/status.json" matched_any_shadow_tags false
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" probe_report_proves_child_success true
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" probe_summary_proves_gpu_render true
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" proof_ok true
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" metadata_probe_report_child_completed true
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" metadata_probe_report_child_exit_status 0
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" metadata_probe_report_timed_out false
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" metadata_probe_summary_present true
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" metadata_probe_summary_scene flat-orange
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" metadata_probe_summary_present_kms true
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" metadata_probe_summary_adapter_backend Vulkan
assert_json_field "$PROBE_ONLY_OUTPUT/status.json" metadata_probe_summary_distinct_color_count 1

LOOP_PARENT="$TMP_DIR/output-orange-gpu-loop"
LOOP_IMAGE="$TMP_DIR/output-orange-gpu-loop.img"
LOOP_OUTPUT="$LOOP_PARENT/recover-traces"
write_recover_context "$LOOP_PARENT" "$LOOP_IMAGE" "$RUN_TOKEN" orange-gpu-loop
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=orange-gpu-loop-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$LOOP_OUTPUT" >/dev/null

assert_json_field "$LOOP_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$LOOP_OUTPUT/status.json" probe_report_proves_child_success true
assert_json_field "$LOOP_OUTPUT/status.json" probe_summary_proves_orange_gpu_loop true
assert_json_field "$LOOP_OUTPUT/status.json" proof_ok true
assert_json_field "$LOOP_OUTPUT/status.json" expected_orange_gpu_mode orange-gpu-loop
assert_json_field "$LOOP_OUTPUT/status.json" expected_orange_gpu_scene orange-gpu-loop
assert_json_field "$LOOP_OUTPUT/status.json" metadata_probe_summary_present true
assert_json_field "$LOOP_OUTPUT/status.json" metadata_probe_summary_scene orange-gpu-loop
assert_json_field "$LOOP_OUTPUT/status.json" metadata_probe_summary_present_kms true
assert_json_field "$LOOP_OUTPUT/status.json" metadata_probe_summary_adapter_backend Vulkan
assert_json_field "$LOOP_OUTPUT/status.json" metadata_probe_summary_kms_present/present_count 11
assert_json_field "$LOOP_OUTPUT/status.json" metadata_probe_summary_kms_present/hold_secs 3

PAYLOAD_PARTITION_PARENT="$TMP_DIR/output-payload-partition"
PAYLOAD_PARTITION_IMAGE="$TMP_DIR/output-payload-partition.img"
PAYLOAD_PARTITION_OUTPUT="$PAYLOAD_PARTITION_PARENT/recover-traces"
write_recover_context "$PAYLOAD_PARTITION_PARENT" "$PAYLOAD_PARTITION_IMAGE" "$RUN_TOKEN" payload-partition-probe
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=payload-partition-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$PAYLOAD_PARTITION_OUTPUT" >/dev/null

assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" expected_orange_gpu_mode payload-partition-probe
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" expected_payload_probe_strategy metadata-shadow-payload-v1
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" expected_payload_probe_source metadata
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" expected_payload_probe_root "/metadata/shadow-payload/by-token/$RUN_TOKEN"
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" expected_payload_probe_manifest_path "/metadata/shadow-payload/by-token/$RUN_TOKEN/manifest.env"
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" expected_payload_probe_fallback_path /orange-gpu
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" probe_summary_proves_payload_partition true
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" proof_ok true
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_kind payload-partition-probe
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_ok true
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_strategy metadata-shadow-payload-v1
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_source metadata
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_root "/metadata/shadow-payload/by-token/$RUN_TOKEN"
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_manifest_path "/metadata/shadow-payload/by-token/$RUN_TOKEN/manifest.env"
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_marker_path "/metadata/shadow-payload/by-token/$RUN_TOKEN/payload.txt"
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_version shadow-payload-probe-v1
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_fingerprint sha256:payloadfingerprint
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_marker_fingerprint sha256:payloadfingerprint
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_fingerprint_verified true
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_mounted_roots/0 /metadata
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_fallback_path /orange-gpu
assert_json_field "$PAYLOAD_PARTITION_OUTPUT/status.json" metadata_probe_summary_payload_blocker none

PAYLOAD_PARTITION_WRONG_TOKEN_PARENT="$TMP_DIR/output-payload-partition-wrong-token"
PAYLOAD_PARTITION_WRONG_TOKEN_IMAGE="$TMP_DIR/output-payload-partition-wrong-token.img"
PAYLOAD_PARTITION_WRONG_TOKEN_OUTPUT="$PAYLOAD_PARTITION_WRONG_TOKEN_PARENT/recover-traces"
write_recover_context "$PAYLOAD_PARTITION_WRONG_TOKEN_PARENT" "$PAYLOAD_PARTITION_WRONG_TOKEN_IMAGE" "$RUN_TOKEN" payload-partition-probe
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=payload-partition-success \
  MOCK_TRACE_RUN_TOKEN=wrong-payload-token \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$PAYLOAD_PARTITION_WRONG_TOKEN_OUTPUT" >/dev/null

assert_json_field "$PAYLOAD_PARTITION_WRONG_TOKEN_OUTPUT/status.json" expected_orange_gpu_mode payload-partition-probe
assert_json_field "$PAYLOAD_PARTITION_WRONG_TOKEN_OUTPUT/status.json" probe_summary_proves_payload_partition false
assert_json_field "$PAYLOAD_PARTITION_WRONG_TOKEN_OUTPUT/status.json" proof_ok false
assert_json_field "$PAYLOAD_PARTITION_WRONG_TOKEN_OUTPUT/status.json" expected_payload_probe_root "/metadata/shadow-payload/by-token/$RUN_TOKEN"
assert_json_field "$PAYLOAD_PARTITION_WRONG_TOKEN_OUTPUT/status.json" metadata_probe_summary_payload_root /metadata/shadow-payload/by-token/wrong-payload-token

PAYLOAD_PARTITION_DATA_PARENT="$TMP_DIR/output-payload-partition-data"
PAYLOAD_PARTITION_DATA_IMAGE="$TMP_DIR/output-payload-partition-data.img"
PAYLOAD_PARTITION_DATA_OUTPUT="$PAYLOAD_PARTITION_DATA_PARENT/recover-traces"
write_recover_context "$PAYLOAD_PARTITION_DATA_PARENT" "$PAYLOAD_PARTITION_DATA_IMAGE" "$RUN_TOKEN" payload-partition-probe
python3 - "$PAYLOAD_PARTITION_DATA_IMAGE.hello-init.json" "$RUN_TOKEN" <<'PY'
import json
import sys

metadata_path, run_token = sys.argv[1:3]
payload = json.loads(open(metadata_path, encoding="utf-8").read())
payload["payload_probe_root"] = f"/data/local/tmp/shadow-payload/by-token/{run_token}"
payload["payload_probe_manifest_path"] = f"/metadata/shadow-payload/by-token/{run_token}/manifest.env"
with open(metadata_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=payload-partition-data-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$PAYLOAD_PARTITION_DATA_OUTPUT" >/dev/null

assert_json_field "$PAYLOAD_PARTITION_DATA_OUTPUT/status.json" expected_payload_probe_root "/data/local/tmp/shadow-payload/by-token/$RUN_TOKEN"
assert_json_field "$PAYLOAD_PARTITION_DATA_OUTPUT/status.json" expected_payload_probe_manifest_path "/metadata/shadow-payload/by-token/$RUN_TOKEN/manifest.env"
assert_json_field "$PAYLOAD_PARTITION_DATA_OUTPUT/status.json" metadata_probe_summary_payload_mounted_roots/0 /metadata
assert_json_field "$PAYLOAD_PARTITION_DATA_OUTPUT/status.json" metadata_probe_summary_payload_mounted_roots/1 /data
assert_json_field "$PAYLOAD_PARTITION_DATA_OUTPUT/status.json" probe_summary_proves_payload_partition true
assert_json_field "$PAYLOAD_PARTITION_DATA_OUTPUT/status.json" proof_ok true

PAYLOAD_PARTITION_DATA_MISSING_MOUNT_PARENT="$TMP_DIR/output-payload-partition-data-missing-mount"
PAYLOAD_PARTITION_DATA_MISSING_MOUNT_IMAGE="$TMP_DIR/output-payload-partition-data-missing-mount.img"
PAYLOAD_PARTITION_DATA_MISSING_MOUNT_OUTPUT="$PAYLOAD_PARTITION_DATA_MISSING_MOUNT_PARENT/recover-traces"
write_recover_context "$PAYLOAD_PARTITION_DATA_MISSING_MOUNT_PARENT" "$PAYLOAD_PARTITION_DATA_MISSING_MOUNT_IMAGE" "$RUN_TOKEN" payload-partition-probe
python3 - "$PAYLOAD_PARTITION_DATA_MISSING_MOUNT_IMAGE.hello-init.json" "$RUN_TOKEN" <<'PY'
import json
import sys

metadata_path, run_token = sys.argv[1:3]
payload = json.loads(open(metadata_path, encoding="utf-8").read())
payload["payload_probe_root"] = f"/data/local/tmp/shadow-payload/by-token/{run_token}"
payload["payload_probe_manifest_path"] = f"/metadata/shadow-payload/by-token/{run_token}/manifest.env"
with open(metadata_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=payload-partition-data-missing-mount \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$PAYLOAD_PARTITION_DATA_MISSING_MOUNT_OUTPUT" >/dev/null

assert_json_field "$PAYLOAD_PARTITION_DATA_MISSING_MOUNT_OUTPUT/status.json" metadata_probe_summary_payload_mounted_roots/0 /metadata
assert_json_field "$PAYLOAD_PARTITION_DATA_MISSING_MOUNT_OUTPUT/status.json" metadata_probe_summary_payload_userdata_mount_error "userdata-mount-f2fs:Invalid argument (os error 22)"
assert_json_field "$PAYLOAD_PARTITION_DATA_MISSING_MOUNT_OUTPUT/status.json" probe_summary_proves_payload_partition false
assert_json_field "$PAYLOAD_PARTITION_DATA_MISSING_MOUNT_OUTPUT/status.json" proof_ok false

PAYLOAD_PARTITION_SHADOW_LOGICAL_PARENT="$TMP_DIR/output-payload-partition-shadow-logical"
PAYLOAD_PARTITION_SHADOW_LOGICAL_IMAGE="$TMP_DIR/output-payload-partition-shadow-logical.img"
PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT="$PAYLOAD_PARTITION_SHADOW_LOGICAL_PARENT/recover-traces"
write_recover_context "$PAYLOAD_PARTITION_SHADOW_LOGICAL_PARENT" "$PAYLOAD_PARTITION_SHADOW_LOGICAL_IMAGE" "$RUN_TOKEN" payload-partition-probe
python3 - "$PAYLOAD_PARTITION_SHADOW_LOGICAL_IMAGE.hello-init.json" <<'PY'
import json
import sys

metadata_path = sys.argv[1]
payload = json.loads(open(metadata_path, encoding="utf-8").read())
payload["payload_probe_source"] = "shadow-logical-partition"
payload["payload_probe_root"] = "/shadow-payload"
payload["payload_probe_manifest_path"] = "/shadow-payload/manifest.env"
with open(metadata_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=payload-partition-shadow-logical-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT" >/dev/null

assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT/status.json" expected_payload_probe_source shadow-logical-partition
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT/status.json" expected_payload_probe_root /shadow-payload
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT/status.json" expected_payload_probe_manifest_path /shadow-payload/manifest.env
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT/status.json" metadata_probe_summary_payload_source shadow-logical-partition
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT/status.json" metadata_probe_summary_payload_mounted_roots/0 /metadata
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT/status.json" metadata_probe_summary_payload_mounted_roots/1 /shadow-payload
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT/status.json" metadata_probe_summary_payload_shadow_logical_mount_error ""
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT/status.json" probe_summary_proves_payload_partition true
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_OUTPUT/status.json" proof_ok true

PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_PARENT="$TMP_DIR/output-payload-partition-shadow-logical-missing-mount"
PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_IMAGE="$TMP_DIR/output-payload-partition-shadow-logical-missing-mount.img"
PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_OUTPUT="$PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_PARENT/recover-traces"
write_recover_context "$PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_PARENT" "$PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_IMAGE" "$RUN_TOKEN" payload-partition-probe
python3 - "$PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_IMAGE.hello-init.json" <<'PY'
import json
import sys

metadata_path = sys.argv[1]
payload = json.loads(open(metadata_path, encoding="utf-8").read())
payload["payload_probe_source"] = "shadow-logical-partition"
payload["payload_probe_root"] = "/shadow-payload"
payload["payload_probe_manifest_path"] = "/shadow-payload/manifest.env"
with open(metadata_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=payload-partition-shadow-logical-missing-mount \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_OUTPUT" >/dev/null

assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_OUTPUT/status.json" metadata_probe_summary_payload_mounted_roots/0 /metadata
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_OUTPUT/status.json" metadata_probe_summary_payload_shadow_logical_mount_error "shadow-logical-dm:lp-partition-missing:shadow_payload_a"
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_OUTPUT/status.json" probe_summary_proves_payload_partition false
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_MISSING_MOUNT_OUTPUT/status.json" proof_ok false

PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_PARENT="$TMP_DIR/output-payload-partition-shadow-logical-wrong-source"
PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_IMAGE="$TMP_DIR/output-payload-partition-shadow-logical-wrong-source.img"
PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_OUTPUT="$PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_PARENT/recover-traces"
write_recover_context "$PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_PARENT" "$PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_IMAGE" "$RUN_TOKEN" payload-partition-probe
python3 - "$PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_IMAGE.hello-init.json" <<'PY'
import json
import sys

metadata_path = sys.argv[1]
payload = json.loads(open(metadata_path, encoding="utf-8").read())
payload["payload_probe_source"] = "metadata"
payload["payload_probe_root"] = "/shadow-payload"
payload["payload_probe_manifest_path"] = "/shadow-payload/manifest.env"
with open(metadata_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=payload-partition-shadow-logical-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_OUTPUT" >/dev/null

assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_OUTPUT/status.json" expected_payload_probe_source metadata
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_OUTPUT/status.json" expected_payload_probe_root /shadow-payload
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_OUTPUT/status.json" probe_summary_proves_payload_partition false
assert_json_field "$PAYLOAD_PARTITION_SHADOW_LOGICAL_WRONG_SOURCE_OUTPUT/status.json" proof_ok false

COMPOSITOR_PARENT="$TMP_DIR/output-compositor-scene"
COMPOSITOR_IMAGE="$TMP_DIR/output-compositor-scene.img"
COMPOSITOR_OUTPUT="$COMPOSITOR_PARENT/recover-traces"
write_recover_context "$COMPOSITOR_PARENT" "$COMPOSITOR_IMAGE" "$RUN_TOKEN" compositor-scene
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=compositor-scene-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$COMPOSITOR_OUTPUT" >/dev/null

assert_json_field "$COMPOSITOR_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$COMPOSITOR_OUTPUT/status.json" probe_report_proves_child_success true
assert_json_field "$COMPOSITOR_OUTPUT/status.json" probe_summary_proves_compositor_scene true
assert_json_field "$COMPOSITOR_OUTPUT/status.json" metadata_compositor_frame_proves_scene true
assert_json_field "$COMPOSITOR_OUTPUT/status.json" proof_ok true
assert_json_field "$COMPOSITOR_OUTPUT/status.json" expected_metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$COMPOSITOR_OUTPUT/status.json" metadata_probe_summary_kind compositor-scene
assert_json_field "$COMPOSITOR_OUTPUT/status.json" metadata_probe_summary_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$COMPOSITOR_OUTPUT/status.json" metadata_probe_summary_frame_bytes 17
assert_json_field "$COMPOSITOR_OUTPUT/status.json" metadata_compositor_frame_present true
assert_json_field "$COMPOSITOR_OUTPUT/status.json" metadata_compositor_frame_width 2
assert_json_field "$COMPOSITOR_OUTPUT/status.json" metadata_compositor_frame_height 1
assert_json_field "$COMPOSITOR_OUTPUT/status.json" metadata_compositor_frame_pixel_bytes 6
assert_json_field "$COMPOSITOR_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 2

SHELL_SESSION_PARENT="$TMP_DIR/output-shell-session"
SHELL_SESSION_IMAGE="$TMP_DIR/output-shell-session.img"
SHELL_SESSION_OUTPUT="$SHELL_SESSION_PARENT/recover-traces"
write_recover_context "$SHELL_SESSION_PARENT" "$SHELL_SESSION_IMAGE" "$RUN_TOKEN" shell-session counter
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=shell-session-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID=counter \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$SHELL_SESSION_OUTPUT" >/dev/null

assert_json_field "$SHELL_SESSION_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" probe_report_proves_child_success true
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" probe_summary_proves_shell_session true
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" proof_ok true
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" expected_shell_session_start_app_id counter
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" expected_app_direct_present_client_kind typescript
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" expected_app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_probe_summary_kind shell-session
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_probe_summary_startup_mode shell
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_probe_summary_app_id counter
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_probe_summary_shell_session_probe_ok true
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_probe_summary_shell_session_shell_mode_enabled true
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_probe_summary_shell_session_app_frame_captured true
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_compositor_frame_width 3
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_compositor_frame_height 1
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_compositor_frame_pixel_bytes 9
assert_json_field "$SHELL_SESSION_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

SHELL_SESSION_HELD_PARENT="$TMP_DIR/output-shell-session-held"
SHELL_SESSION_HELD_IMAGE="$TMP_DIR/output-shell-session-held.img"
SHELL_SESSION_HELD_OUTPUT="$SHELL_SESSION_HELD_PARENT/recover-traces"
write_recover_context "$SHELL_SESSION_HELD_PARENT" "$SHELL_SESSION_HELD_IMAGE" "$RUN_TOKEN" shell-session-held counter
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=shell-session-held-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID=counter \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$SHELL_SESSION_HELD_OUTPUT" >/dev/null

assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" probe_report_proves_child_success false
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" probe_report_proves_child_timeout true
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" probe_summary_proves_shell_session_held true
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" proof_ok true
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" expected_shell_session_start_app_id counter
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" metadata_probe_report_timed_out true
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" metadata_probe_report_child_completed false
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" metadata_probe_summary_kind shell-session-held
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" metadata_probe_summary_startup_mode shell
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" metadata_probe_summary_app_id counter
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" metadata_probe_summary_shell_session_probe_ok true
assert_json_field "$SHELL_SESSION_HELD_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

SHELL_SESSION_TIMELINE_PARENT="$TMP_DIR/output-shell-session-timeline"
SHELL_SESSION_TIMELINE_IMAGE="$TMP_DIR/output-shell-session-timeline.img"
SHELL_SESSION_TIMELINE_OUTPUT="$SHELL_SESSION_TIMELINE_PARENT/recover-traces"
write_recover_context "$SHELL_SESSION_TIMELINE_PARENT" "$SHELL_SESSION_TIMELINE_IMAGE" "$RUN_TOKEN" shell-session timeline
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=shell-session-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID=timeline \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$SHELL_SESSION_TIMELINE_OUTPUT" >/dev/null

assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" probe_summary_proves_shell_session true
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" shell_session_requires_app_direct_frame_samples true
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" proof_ok true
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" expected_shell_session_start_app_id timeline
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" expected_app_direct_present_client_kind typescript
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" expected_app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" metadata_probe_summary_kind shell-session
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" metadata_probe_summary_app_id timeline
assert_json_field "$SHELL_SESSION_TIMELINE_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

SHELL_SESSION_RUST_PARENT="$TMP_DIR/output-shell-session-rust-demo"
SHELL_SESSION_RUST_IMAGE="$TMP_DIR/output-shell-session-rust-demo.img"
SHELL_SESSION_RUST_OUTPUT="$SHELL_SESSION_RUST_PARENT/recover-traces"
write_recover_context "$SHELL_SESSION_RUST_PARENT" "$SHELL_SESSION_RUST_IMAGE" "$RUN_TOKEN" shell-session rust-demo
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=shell-session-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID=rust-demo \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$SHELL_SESSION_RUST_OUTPUT" >/dev/null

assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" probe_summary_proves_shell_session true
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" shell_session_requires_app_direct_frame_samples false
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" proof_ok true
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" expected_shell_session_start_app_id rust-demo
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" expected_app_direct_present_client_kind rust
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" expected_app_direct_present_runtime_bundle_env ""
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" metadata_probe_summary_kind shell-session
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" metadata_probe_summary_app_id rust-demo
assert_json_field "$SHELL_SESSION_RUST_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

SHELL_TOUCH_PARENT="$TMP_DIR/output-shell-session-runtime-touch-counter"
SHELL_TOUCH_IMAGE="$TMP_DIR/output-shell-session-runtime-touch-counter.img"
SHELL_TOUCH_OUTPUT="$SHELL_TOUCH_PARENT/recover-traces"
write_recover_context "$SHELL_TOUCH_PARENT" "$SHELL_TOUCH_IMAGE" "$RUN_TOKEN" shell-session-runtime-touch-counter counter
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=shell-session-runtime-touch-counter-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID=counter \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$SHELL_TOUCH_OUTPUT" >/dev/null

assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" probe_report_proves_child_success true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" probe_summary_proves_shell_session_runtime_touch_counter true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_compositor_frame_proves_shell_session_app true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" proof_ok true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" expected_shell_session_start_app_id counter
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" expected_app_direct_present_client_kind typescript
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" expected_app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_probe_summary_kind shell-session-runtime-touch-counter
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_probe_summary_startup_mode shell
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_probe_summary_app_id counter
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_probe_summary_shell_session_probe_ok true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_probe_ok true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_injection synthetic-compositor
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_counter_incremented true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_touch_latency_present true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_post_touch_frame_captured true
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_compositor_frame_width 3
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_compositor_frame_height 1
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_compositor_frame_pixel_bytes 9
assert_json_field "$SHELL_TOUCH_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

SHELL_TOUCH_MISMATCH_PARENT="$TMP_DIR/output-shell-session-runtime-touch-counter-mismatch"
SHELL_TOUCH_MISMATCH_IMAGE="$TMP_DIR/output-shell-session-runtime-touch-counter-mismatch.img"
SHELL_TOUCH_MISMATCH_OUTPUT="$SHELL_TOUCH_MISMATCH_PARENT/recover-traces"
write_recover_context "$SHELL_TOUCH_MISMATCH_PARENT" "$SHELL_TOUCH_MISMATCH_IMAGE" "$RUN_TOKEN" shell-session-runtime-touch-counter timeline
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=shell-session-runtime-touch-counter-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$SHELL_TOUCH_MISMATCH_OUTPUT" >/dev/null

assert_json_field "$SHELL_TOUCH_MISMATCH_OUTPUT/status.json" probe_summary_proves_shell_session_runtime_touch_counter false
assert_json_field "$SHELL_TOUCH_MISMATCH_OUTPUT/status.json" metadata_probe_summary_app_id counter
assert_json_field "$SHELL_TOUCH_MISMATCH_OUTPUT/status.json" expected_shell_session_start_app_id timeline
assert_json_field "$SHELL_TOUCH_MISMATCH_OUTPUT/status.json" expected_app_direct_present_app_id timeline
assert_json_field "$SHELL_TOUCH_MISMATCH_OUTPUT/status.json" proof_ok false

APP_DIRECT_PRESENT_PARENT="$TMP_DIR/output-app-direct-present"
APP_DIRECT_PRESENT_IMAGE="$TMP_DIR/output-app-direct-present.img"
APP_DIRECT_PRESENT_OUTPUT="$APP_DIRECT_PRESENT_PARENT/recover-traces"
write_recover_context "$APP_DIRECT_PRESENT_PARENT" "$APP_DIRECT_PRESENT_IMAGE" "$RUN_TOKEN" app-direct-present
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=app-direct-present-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$APP_DIRECT_PRESENT_OUTPUT" >/dev/null

assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" probe_report_proves_child_success true
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" probe_summary_proves_app_direct_present true
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" proof_ok true
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_client_kind rust
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" expected_metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/app_id rust-demo
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/client_kind rust
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/expected_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/recovered_frame_output_path channels/metadata-compositor-frame.ppm
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_probe_summary_kind app-direct-present
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_probe_summary_startup_mode app
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_probe_summary_app_id rust-demo
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_probe_summary_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_probe_summary_frame_bytes 20
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_present true
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_width 3
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_height 1
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_pixel_bytes 9
assert_json_field "$APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

LEGACY_APP_DIRECT_PRESENT_PARENT="$TMP_DIR/output-legacy-app-direct-present"
LEGACY_APP_DIRECT_PRESENT_IMAGE="$TMP_DIR/output-legacy-app-direct-present.img"
LEGACY_APP_DIRECT_PRESENT_OUTPUT="$LEGACY_APP_DIRECT_PRESENT_PARENT/recover-traces"
write_recover_context "$LEGACY_APP_DIRECT_PRESENT_PARENT" "$LEGACY_APP_DIRECT_PRESENT_IMAGE" "$RUN_TOKEN" app-direct-present rust-demo legacy
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=app-direct-present-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$LEGACY_APP_DIRECT_PRESENT_OUTPUT" >/dev/null

assert_json_field "$LEGACY_APP_DIRECT_PRESENT_OUTPUT/status.json" probe_summary_proves_app_direct_present true
assert_json_field "$LEGACY_APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$LEGACY_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract_required false
assert_json_field "$LEGACY_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract_ok false
assert_json_field "$LEGACY_APP_DIRECT_PRESENT_OUTPUT/status.json" proof_ok true
assert_json_field "$LEGACY_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_app_id rust-demo
assert_json_field "$LEGACY_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_client_kind ""

TS_APP_DIRECT_PRESENT_PARENT="$TMP_DIR/output-ts-app-direct-present"
TS_APP_DIRECT_PRESENT_IMAGE="$TMP_DIR/output-ts-app-direct-present.img"
TS_APP_DIRECT_PRESENT_OUTPUT="$TS_APP_DIRECT_PRESENT_PARENT/recover-traces"
write_recover_context "$TS_APP_DIRECT_PRESENT_PARENT" "$TS_APP_DIRECT_PRESENT_IMAGE" "$RUN_TOKEN" app-direct-present counter
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=app-direct-present-success \
  MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID=counter \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$TS_APP_DIRECT_PRESENT_OUTPUT" >/dev/null

assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" probe_summary_proves_app_direct_present true
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" proof_ok true
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_app_id counter
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_client_kind typescript
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_typescript_renderer gpu
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-counter-bundle.js
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/app_id counter
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/client_kind typescript
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/typescript_renderer gpu
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/runtime_bundle_env SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-counter-bundle.js
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/expected_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/probe_summary_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/recovered_frame_output_path channels/metadata-compositor-frame.ppm
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_probe_summary_app_id counter
assert_json_field "$TS_APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

TS_TIMELINE_APP_DIRECT_PRESENT_PARENT="$TMP_DIR/output-ts-timeline-app-direct-present"
TS_TIMELINE_APP_DIRECT_PRESENT_IMAGE="$TMP_DIR/output-ts-timeline-app-direct-present.img"
TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT="$TS_TIMELINE_APP_DIRECT_PRESENT_PARENT/recover-traces"
write_recover_context "$TS_TIMELINE_APP_DIRECT_PRESENT_PARENT" "$TS_TIMELINE_APP_DIRECT_PRESENT_IMAGE" "$RUN_TOKEN" app-direct-present timeline
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=app-direct-present-success \
  MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID=timeline \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT" >/dev/null

assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" probe_summary_proves_app_direct_present true
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" proof_ok true
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_app_id timeline
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_client_kind typescript
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_typescript_renderer gpu
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" expected_app_direct_present_runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-timeline-bundle.js
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/app_id timeline
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/client_kind typescript
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/typescript_renderer gpu
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/runtime_bundle_env SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-timeline-bundle.js
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/expected_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/probe_summary_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" app_direct_present_proof_contract/recovered_frame_output_path channels/metadata-compositor-frame.ppm
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_probe_summary_app_id timeline
assert_json_field "$TS_TIMELINE_APP_DIRECT_PRESENT_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

TS_TIMELINE_FRAME_MISMATCH_PARENT="$TMP_DIR/output-ts-timeline-app-direct-present-frame-mismatch"
TS_TIMELINE_FRAME_MISMATCH_IMAGE="$TMP_DIR/output-ts-timeline-app-direct-present-frame-mismatch.img"
TS_TIMELINE_FRAME_MISMATCH_OUTPUT="$TS_TIMELINE_FRAME_MISMATCH_PARENT/recover-traces"
write_recover_context "$TS_TIMELINE_FRAME_MISMATCH_PARENT" "$TS_TIMELINE_FRAME_MISMATCH_IMAGE" "$RUN_TOKEN" app-direct-present timeline
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=app-direct-present-success \
  MOCK_TRACE_APP_DIRECT_PRESENT_APP_ID=timeline \
  MOCK_TRACE_APP_DIRECT_PRESENT_FRAME_APP_ID=rust-demo \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$TS_TIMELINE_FRAME_MISMATCH_OUTPUT" >/dev/null

assert_json_field "$TS_TIMELINE_FRAME_MISMATCH_OUTPUT/status.json" probe_summary_proves_app_direct_present true
assert_json_field "$TS_TIMELINE_FRAME_MISMATCH_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$TS_TIMELINE_FRAME_MISMATCH_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$TS_TIMELINE_FRAME_MISMATCH_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present false
assert_json_field "$TS_TIMELINE_FRAME_MISMATCH_OUTPUT/status.json" proof_ok false
assert_json_field "$TS_TIMELINE_FRAME_MISMATCH_OUTPUT/status.json" expected_app_direct_present_app_id timeline
assert_json_field "$TS_TIMELINE_FRAME_MISMATCH_OUTPUT/status.json" metadata_probe_summary_app_id timeline
assert_json_field "$TS_TIMELINE_FRAME_MISMATCH_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

APP_DIRECT_TOUCH_PARENT="$TMP_DIR/output-app-direct-present-touch-counter"
APP_DIRECT_TOUCH_IMAGE="$TMP_DIR/output-app-direct-present-touch-counter.img"
APP_DIRECT_TOUCH_OUTPUT="$APP_DIRECT_TOUCH_PARENT/recover-traces"
write_recover_context "$APP_DIRECT_TOUCH_PARENT" "$APP_DIRECT_TOUCH_IMAGE" "$RUN_TOKEN" app-direct-present-touch-counter
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=app-direct-present-touch-counter-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$APP_DIRECT_TOUCH_OUTPUT" >/dev/null

assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" probe_report_proves_child_success true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" probe_summary_proves_app_direct_present_touch_counter true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" proof_ok true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_kind app-direct-present-touch-counter
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_probe_ok true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_injection synthetic-compositor
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_input_observed true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_tap_dispatched true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_counter_incremented true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_post_touch_frame_committed true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_post_touch_frame_artifact_logged true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_touch_latency_present true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_post_touch_frame_captured true
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$APP_DIRECT_TOUCH_OUTPUT/status.json" metadata_probe_summary_frame_bytes 20

APP_DIRECT_RUNTIME_TOUCH_PARENT="$TMP_DIR/output-app-direct-present-runtime-touch-counter"
APP_DIRECT_RUNTIME_TOUCH_IMAGE="$TMP_DIR/output-app-direct-present-runtime-touch-counter.img"
APP_DIRECT_RUNTIME_TOUCH_OUTPUT="$APP_DIRECT_RUNTIME_TOUCH_PARENT/recover-traces"
write_recover_context "$APP_DIRECT_RUNTIME_TOUCH_PARENT" "$APP_DIRECT_RUNTIME_TOUCH_IMAGE" "$RUN_TOKEN" app-direct-present-runtime-touch-counter counter
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=app-direct-present-runtime-touch-counter-success \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT" >/dev/null

assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" probe_report_proves_child_success true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" probe_summary_proves_app_direct_present_runtime_touch_counter true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" app_direct_present_proof_contract_required true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" app_direct_present_proof_contract_ok true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_compositor_frame_proves_app_direct_present true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" proof_ok true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" expected_app_direct_present_app_id counter
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" expected_app_direct_present_client_kind typescript
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_kind app-direct-present-runtime-touch-counter
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_app_id counter
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_probe_ok true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_injection synthetic-compositor
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_input_observed true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_tap_dispatched true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_counter_incremented true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_post_touch_frame_committed true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_post_touch_frame_artifact_logged true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_touch_latency_present true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_touch_counter_post_touch_frame_captured true
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_frame_path "/metadata/shadow-hello-init/by-token/$RUN_TOKEN/compositor-frame.ppm"
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_probe_summary_frame_bytes 20
assert_json_field "$APP_DIRECT_RUNTIME_TOUCH_OUTPUT/status.json" metadata_compositor_frame_distinct_color_count 3

ROOT_TIMEOUT_PARENT="$TMP_DIR/output-root-timeout"
ROOT_TIMEOUT_IMAGE="$TMP_DIR/output-root-timeout.img"
ROOT_TIMEOUT_OUTPUT="$ROOT_TIMEOUT_PARENT/recover-traces"
write_recover_context "$ROOT_TIMEOUT_PARENT" "$ROOT_TIMEOUT_IMAGE" "$RUN_TOKEN"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=holder-timeout \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  PIXEL_BOOT_RECOVER_TRACES_ROOT_TIMEOUT_SECS=1 \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$ROOT_TIMEOUT_OUTPUT" >/dev/null

assert_json_field "$ROOT_TIMEOUT_OUTPUT/status.json" root_available true
assert_json_field "$ROOT_TIMEOUT_OUTPUT/status.json" channels/kgsl-holder-scan/requested_access_mode root
assert_json_field "$ROOT_TIMEOUT_OUTPUT/status.json" channels/kgsl-holder-scan/actual_access_mode root-timeout
assert_json_field "$ROOT_TIMEOUT_OUTPUT/status.json" channels/kgsl-holder-scan/available false
assert_json_field "$ROOT_TIMEOUT_OUTPUT/status.json" channels/kgsl-holder-scan/exit_code 124

printf 'pixel_boot_recover_traces_smoke: ok\n'
