#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

usage() {
  cat <<'EOF'
usage: pixel_ci.sh [--suite <name>] [--target <serial>] [--stage-only|--run-only] [--list-suites]

Suites:
  quick     timeline + camera
  shell     timeline + camera
  timeline  timeline lifecycle only
  camera    camera launch + capture only
  nostr     runtime Nostr timeline against a host-local relay over USB
  sound     runtime sound app only
  audio     runtime sound + podcast
  podcast   runtime podcast app only
  runtime   sound + podcast + nostr
  full      timeline + camera + sound + podcast + nostr

Use PIXEL_SERIAL or --target to select a specific rooted Pixel.
`--stage-only` stages artifacts onto the rooted Pixel without executing the suite.
`--run-only` executes the suite against already-staged artifacts.
EOF
}

list_suites() {
  cat <<'EOF'
quick
shell
timeline
camera
nostr
sound
audio
podcast
runtime
full
EOF
}

suite="full"
requested_target=""
stage_only=0
run_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)
      suite="${2:?pixel-ci: --suite requires a value}"
      shift 2
      ;;
    --target|-t)
      requested_target="${2:?pixel-ci: --target requires a value}"
      shift 2
      ;;
    --list-suites)
      list_suites
      exit 0
      ;;
    --stage-only)
      stage_only=1
      shift
      ;;
    --run-only)
      run_only=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    suite=*)
      suite="${1#suite=}"
      shift
      ;;
    target=*|serial=*)
      requested_target="${1#*=}"
      shift
      ;;
    quick|shell|timeline|camera|nostr|sound|audio|podcast|runtime|full)
      suite="$1"
      shift
      ;;
    *)
      echo "pixel-ci: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if (( stage_only == 1 && run_only == 1 )); then
  echo "pixel-ci: --stage-only and --run-only are mutually exclusive" >&2
  exit 64
fi

case "$suite" in
  suite=*)
    suite="${suite#suite=}"
    ;;
esac

case "$requested_target" in
  target=*|serial=*)
    requested_target="${requested_target#*=}"
    ;;
esac

if [[ -n "$requested_target" ]]; then
  export PIXEL_SERIAL="$requested_target"
fi

serial="$(pixel_resolve_serial)"
export PIXEL_SERIAL="$serial"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_runs_dir)/ci")"
steps_tsv_path="$run_dir/steps.tsv"
summary_path="$run_dir/summary.json"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
start_epoch="$(date +%s)"
touch "$steps_tsv_path"

suite_steps=()
case "$suite" in
  quick|shell)
    suite_steps=(timeline camera)
    ;;
  timeline)
    suite_steps=(timeline)
    ;;
  camera)
    suite_steps=(camera)
    ;;
  nostr)
    suite_steps=(nostr)
    ;;
  sound)
    suite_steps=(sound)
    ;;
  audio)
    suite_steps=(sound podcast)
    ;;
  runtime)
    suite_steps=(sound podcast nostr)
    ;;
  podcast)
    suite_steps=(podcast)
    ;;
  full)
    suite_steps=(timeline camera sound podcast nostr)
    ;;
  *)
    echo "pixel-ci: unsupported suite '$suite'" >&2
    usage >&2
    exit 64
    ;;
esac

need_shell=0
need_sound=0
need_podcast=0
need_camera_runtime=0
need_nostr=0
for step in "${suite_steps[@]}"; do
  case "$step" in
    timeline|camera)
      need_shell=1
      ;;
    sound)
      need_sound=1
      ;;
    podcast)
      need_podcast=1
      ;;
    nostr)
      need_nostr=1
      ;;
  esac
  if [[ "$step" == "camera" ]]; then
    need_camera_runtime=1
  fi
done

runtime_run_only_step_count=0
for step in "${suite_steps[@]}"; do
  case "$step" in
    sound|podcast|nostr)
      runtime_run_only_step_count=$((runtime_run_only_step_count + 1))
      ;;
  esac
done
if (( run_only == 1 && runtime_run_only_step_count > 1 )); then
  echo "pixel-ci: --run-only cannot run multiple runtime app steps because they share one staged runtime app bundle" >&2
  echo "pixel-ci: run each runtime subset separately with --run-only, or omit --run-only so artifacts are staged per step" >&2
  exit 64
fi

cleanup() {
  pixel_stop_shadow_session_best_effort "$serial"
  if pixel_android_display_stack_restored "$serial"; then
    return 0
  fi
  pixel_restore_android_best_effort "$serial" 60
}

trap cleanup EXIT

ensure_android_display_ready() {
  if pixel_wait_for_condition 5 1 pixel_android_display_restored "$serial"; then
    return 0
  fi

  echo "pixel-ci: Android display/window stack not ready; attempting restore" >&2
  pixel_stop_shadow_session_best_effort "$serial"
  pixel_restore_android_best_effort "$serial" 60
  if pixel_wait_for_condition 30 1 pixel_android_display_restored "$serial"; then
    return 0
  fi

  echo "pixel-ci: Android display/window stack still not ready; rebooting device" >&2
  pixel_adb "$serial" reboot
  sleep 5
  pixel_wait_for_adb "$serial" 180
  pixel_wait_for_boot_completed "$serial" 240
  pixel_wait_for_condition 90 1 pixel_android_display_restored "$serial"
}

run_display_ready_gate() {
  local step_name
  step_name="$1"
  run_step "preflight_android_display_${step_name}" "wait for Android display/window stack ready before ${step_name}" \
    ensure_android_display_ready
}

record_step() {
  local step_id="$1"
  local description="$2"
  local result="$3"
  local duration_secs="$4"
  local log_path="$5"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$step_id" \
    "$description" \
    "$result" \
    "$duration_secs" \
    "$log_path" >>"$steps_tsv_path"
}

run_step() {
  local step_id="$1"
  local description="$2"
  shift 2

  local log_path="$run_dir/${step_id}.log"
  local step_start="$SECONDS"
  local exit_code=0

  printf 'pixel-ci: start %s\n' "$description"
  if "$@" >"$log_path" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  local duration_secs=$((SECONDS - step_start))
  if (( exit_code == 0 )); then
    record_step "$step_id" "$description" "passed" "$duration_secs" "$log_path"
    printf 'pixel-ci: pass %s (%ss)\n' "$step_id" "$duration_secs"
    return 0
  fi

  record_step "$step_id" "$description" "failed" "$duration_secs" "$log_path"
  printf 'pixel-ci: fail %s (%ss)\n' "$step_id" "$duration_secs" >&2
  write_summary failed
  printf 'pixel-ci: summary=%s\n' "$summary_path" >&2
  printf '\n== %s log ==\n' "$step_id" >&2
  sed -n '1,260p' "$log_path" >&2 || true
  exit "$exit_code"
}

write_summary() {
  local result="$1"
  local ended_at total_seconds

  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  total_seconds=$(( $(date +%s) - start_epoch ))

  python3 - "$summary_path" "$steps_tsv_path" "$suite" "$serial" "$run_dir" "$started_at" "$ended_at" "$result" "$total_seconds" <<'PY'
import json
import sys

summary_path, steps_tsv_path, suite, serial, run_dir, started_at, ended_at, result, total_seconds = sys.argv[1:10]

steps = []
with open(steps_tsv_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.rstrip("\n")
        if not line:
            continue
        step_id, description, status, duration_seconds, log_path = line.split("\t")
        steps.append(
            {
                "description": description,
                "durationSeconds": int(duration_seconds),
                "id": step_id,
                "logPath": log_path,
                "status": status,
            }
        )

summary = {
    "endedAt": ended_at,
    "result": result,
    "runDir": run_dir,
    "serial": serial,
    "startedAt": started_at,
    "steps": steps,
    "suite": suite,
    "totalSeconds": int(total_seconds),
}

with open(summary_path, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")
PY
}

printf 'pixel-ci: suite=%s serial=%s run_dir=%s\n' "$suite" "$serial" "$run_dir"

# Best-effort reset so a stale hold-mode takeover does not poison the next case.
if (( stage_only == 0 )); then
  pixel_stop_shadow_session_best_effort "$serial"
  if ! pixel_android_display_stack_restored "$serial"; then
    pixel_restore_android_best_effort "$serial" 60
  fi
fi

run_step preflight_root "verify Pixel root access" \
  "$SCRIPT_DIR/shadowctl" root-check -t "$serial"
if (( stage_only == 0 )); then
  run_step preflight_android_display "wait for Android display/window stack ready" \
    ensure_android_display_ready
fi
run_step preflight_doctor "inspect Pixel device state" \
  "$SCRIPT_DIR/shadowctl" doctor -t "$serial"

if (( run_only == 0 )); then
  if (( need_shell == 1 )); then
    shell_runtime_args=(--stage-only)
    if (( need_camera_runtime == 1 )); then
      shell_runtime_args+=(--camera-runtime)
    else
      shell_runtime_args+=(--no-camera-runtime)
    fi
    run_step prep_shell_runtime "stage rooted Pixel shell artifacts" \
      env PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel/pixel_shell_drm.sh" "${shell_runtime_args[@]}"
  fi

  if (( stage_only == 1 && need_sound == 1 )); then
    run_step prep_sound_runtime "stage rooted Pixel sound runtime artifacts" \
      env PIXEL_SERIAL="$serial" PIXEL_RUNTIME_APP_PREP_ONLY=1 "$SCRIPT_DIR/pixel/pixel_runtime_app_sound_drm.sh"
  fi

  if (( stage_only == 1 && need_podcast == 1 )); then
    run_step prep_podcast_runtime "stage rooted Pixel podcast runtime artifacts" \
      env PIXEL_SERIAL="$serial" SHADOW_PODCAST_PLAYER_EPISODE_IDS=00 PIXEL_RUNTIME_APP_PREP_ONLY=1 "$SCRIPT_DIR/pixel/pixel_runtime_app_podcast_player_drm.sh"
  fi

  if (( stage_only == 1 && need_nostr == 1 )); then
    run_step prep_nostr_runtime "stage rooted Pixel Nostr runtime artifacts" \
      env PIXEL_SERIAL="$serial" PIXEL_RUNTIME_APP_PREP_ONLY=1 "$SCRIPT_DIR/ci/pixel_runtime_app_nostr_timeline_local_smoke.sh"
  fi
fi

if (( stage_only == 1 )); then
  write_summary passed
  cat "$summary_path"
  exit 0
fi

for step in "${suite_steps[@]}"; do
  case "$step" in
    timeline)
      run_display_ready_gate "$step"
      run_step timeline "prove rooted Pixel shell timeline lifecycle" \
        env PIXEL_SERIAL="$serial" "$SCRIPT_DIR/ci/pixel_shell_timeline_smoke.sh" --run-only
      ;;
    camera)
      run_display_ready_gate "$step"
      run_step camera "prove rooted Pixel shell camera capture" \
        env PIXEL_SERIAL="$serial" "$SCRIPT_DIR/ci/pixel_shell_camera_smoke.sh" --run-only
      ;;
    sound)
      if (( run_only == 0 )); then
        run_step prep_sound_runtime "stage rooted Pixel sound runtime artifacts" \
          env PIXEL_SERIAL="$serial" PIXEL_RUNTIME_APP_PREP_ONLY=1 "$SCRIPT_DIR/pixel/pixel_runtime_app_sound_drm.sh"
      fi
      run_display_ready_gate "$step"
      run_step sound "prove rooted Pixel runtime sound playback" \
        env PIXEL_SERIAL="$serial" PIXEL_RUNTIME_APP_RUN_ONLY=1 "$SCRIPT_DIR/pixel/pixel_runtime_app_sound_drm.sh"
      ;;
    podcast)
      if (( run_only == 0 )); then
        run_step prep_podcast_runtime "stage rooted Pixel podcast runtime artifacts" \
          env PIXEL_SERIAL="$serial" SHADOW_PODCAST_PLAYER_EPISODE_IDS=00 PIXEL_RUNTIME_APP_PREP_ONLY=1 "$SCRIPT_DIR/pixel/pixel_runtime_app_podcast_player_drm.sh"
      fi
      run_display_ready_gate "$step"
      run_step podcast "prove rooted Pixel runtime podcast playback" \
        env PIXEL_SERIAL="$serial" SHADOW_PODCAST_PLAYER_EPISODE_IDS=00 PIXEL_RUNTIME_APP_RUN_ONLY=1 "$SCRIPT_DIR/pixel/pixel_runtime_app_podcast_player_drm.sh"
      ;;
    nostr)
      if (( run_only == 0 )); then
        run_step prep_nostr_runtime "stage rooted Pixel Nostr runtime artifacts" \
          env PIXEL_SERIAL="$serial" PIXEL_RUNTIME_APP_PREP_ONLY=1 "$SCRIPT_DIR/ci/pixel_runtime_app_nostr_timeline_local_smoke.sh"
      fi
      run_display_ready_gate "$step"
      run_step nostr "prove rooted Pixel runtime Nostr timeline against a host-local relay over USB" \
        env PIXEL_SERIAL="$serial" PIXEL_RUNTIME_APP_RUN_ONLY=1 "$SCRIPT_DIR/ci/pixel_runtime_app_nostr_timeline_local_smoke.sh"
      ;;
  esac
done

write_summary passed
cat "$summary_path"
