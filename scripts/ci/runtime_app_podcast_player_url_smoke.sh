#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REMOTE_HOST="${SHADOW_PODCAST_URL_SMOKE_REMOTE_HOST:-${CUTTLEFISH_REMOTE_HOST:-justin@100.73.239.5}}"
REMOTE_DIR_CACHE="${SHADOW_PODCAST_URL_SMOKE_REMOTE_DIR:-}"
URL_SMOKE_NAMESPACE="${SHADOW_PODCAST_URL_SMOKE_NAMESPACE:-$(basename "$REPO_ROOT")-$$}"
URL_SMOKE_REMOTE="${SHADOW_PODCAST_URL_SMOKE_REMOTE:-0}"
SSH_RETRIES="${SHADOW_PODCAST_URL_SMOKE_SSH_RETRIES:-3}"
SSH_RETRY_SLEEP="${SHADOW_PODCAST_URL_SMOKE_SSH_RETRY_SLEEP:-2}"
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
)

remote_ssh() {
  local script attempt status
  script="${1:?remote_ssh requires a script}"
  status=0
  for attempt in $(seq 1 "$SSH_RETRIES"); do
    if ssh \
      "${SSH_OPTS[@]}" \
      "$REMOTE_HOST" \
      /bin/bash -lc "$(printf '%q' "$script")"; then
      return 0
    fi
    status=$?
    if (( attempt == SSH_RETRIES )); then
      return "$status"
    fi
    sleep "$SSH_RETRY_SLEEP"
  done
  return "$status"
}

remote_home() {
  remote_ssh 'printf %s "$HOME"'
}

remote_dir() {
  if [[ -n "${REMOTE_DIR_CACHE:-}" ]]; then
    printf '%s\n' "$REMOTE_DIR_CACHE"
    return
  fi

  REMOTE_DIR_CACHE="$(remote_home)/.cache/shadow-podcast-url-smoke-${URL_SMOKE_NAMESPACE}"
  printf '%s\n' "$REMOTE_DIR_CACHE"
}

sync_remote_tree() {
  local dir
  dir="$(remote_dir)"

  tar \
    --exclude=.git \
    --exclude=artifacts \
    --exclude=build \
    --exclude=worktrees \
    --exclude=rust/*/target \
    --exclude=rust/*/target/** \
    -cf - \
    flake.nix \
    flake.lock \
    justfile \
    runtime \
    scripts \
    rust/Cargo.toml \
    rust/Cargo.lock \
    rust/shadow-linux-audio-spike \
    rust/shadow-runtime-host \
    rust/runtime-audio-host \
    rust/runtime-camera-host \
    rust/runtime-cashu-host \
    rust/runtime-nostr-host \
    rust/shadow-runtime-protocol \
    rust/vendor \
    | remote_ssh "mkdir -p $(printf '%q' "$dir") && rm -rf $(printf '%q' "$dir/runtime") $(printf '%q' "$dir/rust") $(printf '%q' "$dir/scripts") $(printf '%q' "$dir/flake.nix") $(printf '%q' "$dir/flake.lock") $(printf '%q' "$dir/justfile") && tar -xf - -C $(printf '%q' "$dir")"
}

run_remote_smoke() {
  local dir command status
  dir="$(remote_dir)"
  sync_remote_tree
  command="cd $(printf '%q' "$dir") && SHADOW_PODCAST_URL_SMOKE_REMOTE=1 SHADOW_PODCAST_URL_SMOKE_NAMESPACE=$(printf '%q' "$URL_SMOKE_NAMESPACE") nix develop --accept-flake-config .#runtime -c bash scripts/ci/runtime_app_podcast_player_url_smoke.sh"
  if remote_ssh "$command"; then
    status=0
  else
    status=$?
  fi
  remote_ssh "rm -rf $(printf '%q' "$dir")" >/dev/null 2>&1 || true
  return "$status"
}

run_local_linux_smoke() {
  REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import functools
import http.server
import json
import os
import select
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

REPO_ROOT = Path(os.environ["REPO_ROOT"])
SCRIPT_DIR = REPO_ROOT / "scripts"
RUNTIME_SCRIPT_DIR = SCRIPT_DIR / "runtime"
FIXTURE_DIR = REPO_ROOT / "runtime" / "app-podcast-player" / "fixture"
FIXTURE_METADATA_PATH = FIXTURE_DIR / "podcast-feed-cache.json"
EPISODE_ID = os.environ.get("SHADOW_PODCAST_URL_SMOKE_EPISODE_ID", "00")


class CountingHandler(http.server.SimpleHTTPRequestHandler):
    request_count = 0

    def do_GET(self):
        type(self).request_count += 1
        return super().do_GET()

    def log_message(self, format, *args):
        return


with FIXTURE_METADATA_PATH.open("r", encoding="utf-8") as handle:
    fixture = json.load(handle)

episode = next(
    (candidate for candidate in fixture.get("episodes", []) if candidate.get("id") == EPISODE_ID),
    None,
)
if episode is None:
    raise SystemExit(
        f"runtime-app-podcast-player-url-smoke: missing fixture episode {EPISODE_ID}"
    )

handler = functools.partial(CountingHandler, directory=str(FIXTURE_DIR))
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
server_thread = threading.Thread(target=server.serve_forever, daemon=True)
server_thread.start()

try:
    source_url = f"http://127.0.0.1:{server.server_address[1]}/{episode['path']}"
    runtime_app_config_json = json.dumps(
        {
            "episodes": [
                {
                    **episode,
                    "sourceUrl": source_url,
                }
            ],
            "playbackSource": "url",
            "podcastLicense": fixture.get("podcastLicense"),
            "podcastPageUrl": fixture.get("podcastPageUrl"),
            "podcastTitle": fixture.get("podcastTitle"),
        }
    )
    helper_prefix = subprocess.check_output(
        [
            "nix",
            "build",
            "--accept-flake-config",
            ".#shadow-linux-audio-spike",
            "--no-link",
            "--print-out-paths",
        ],
        cwd=REPO_ROOT,
        text=True,
    ).strip()
    helper_binary_path = Path(helper_prefix) / "bin" / "shadow-linux-audio-spike"

    session_json = subprocess.check_output(
        [str(RUNTIME_SCRIPT_DIR / "runtime_prepare_host_session.sh")],
        cwd=REPO_ROOT,
        env={
            **os.environ,
            "SHADOW_RUNTIME_APP_CACHE_DIR": "build/runtime/app-podcast-player-url-smoke",
            "SHADOW_RUNTIME_APP_CONFIG_JSON": runtime_app_config_json,
            "SHADOW_RUNTIME_APP_INPUT_PATH": "runtime/app-podcast-player/app.tsx",
        },
        text=True,
    )
    session = json.loads(session_json)
    bundle_dir = Path(session["bundleDir"])
    bundle_path = session["bundlePath"]
    binary_path = session["runtimeHostBinaryPath"]

    for name in os.listdir(FIXTURE_DIR):
        source_path = FIXTURE_DIR / name
        target_path = bundle_dir / name
        if source_path.is_dir():
            shutil.copytree(source_path, target_path, dirs_exist_ok=True)
        else:
            shutil.copy2(source_path, target_path)

    with tempfile.TemporaryDirectory(prefix="shadow-podcast-url-smoke.") as tmp_dir:
        summary_path = Path(tmp_dir) / "audio-spike-summary.json"
        process_env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("SHADOW_AUDIO_SPIKE_")
            and not key.startswith("SHADOW_RUNTIME_AUDIO_")
        }
        process_env.update(
            {
                "SHADOW_AUDIO_SPIKE_SUMMARY_PATH": str(summary_path),
                "SHADOW_AUDIO_SPIKE_VALIDATE_ONLY": "1",
                "SHADOW_RUNTIME_AUDIO_BACKEND": "linux_spike",
                "SHADOW_RUNTIME_AUDIO_SPIKE_BINARY": str(helper_binary_path),
            }
        )

        process = subprocess.Popen(
            [binary_path, "--session", bundle_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=process_env,
            text=True,
        )

        def wait_for_process_exit(context, timeout_seconds):
            try:
                return_code = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired:
                process.kill()
                return_code = process.wait(timeout=5)
                stderr = process.stderr.read() if process.stderr is not None else ""
                raise SystemExit(
                    "runtime-app-podcast-player-url-smoke: runtime host timed out "
                    f"during {context}\n{stderr}"
                )
            stderr = process.stderr.read() if process.stderr is not None else ""
            return return_code, stderr

        def send_raw(request):
            assert process.stdin is not None
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            assert process.stdout is not None
            while True:
                ready, _, _ = select.select([process.stdout], [], [], 5)
                if not ready:
                    raise SystemExit(
                        "runtime-app-podcast-player-url-smoke: timed out waiting for "
                        f"runtime host response to {json.dumps(request)}"
                    )
                line = process.stdout.readline()
                if not line:
                    return_code, stderr = wait_for_process_exit(
                        "stdout shutdown", timeout_seconds=5
                    )
                    raise SystemExit(
                        "runtime-app-podcast-player-url-smoke: runtime host closed stdout "
                        f"with exit code {return_code}\n"
                        f"{stderr}"
                    )
                try:
                    return json.loads(line)
                except json.JSONDecodeError as error:
                    if line.startswith("[shadow-runtime-"):
                        continue
                    raise SystemExit(
                        "runtime-app-podcast-player-url-smoke: decode response: "
                        f"{error}\nline={line!r}"
                    ) from error

        def send_ok(request):
            response = send_raw(request)
            if response.get("status") != "ok":
                raise SystemExit(
                    "runtime-app-podcast-player-url-smoke: unexpected response: "
                    f"{json.dumps(response)}"
                )
            return response["payload"]

        def wait_for_fragment(fragment, timeout_seconds=5):
            deadline = time.time() + timeout_seconds
            while time.time() < deadline:
                response = send_raw({"op": "render_if_dirty"})
                if response.get("status") == "no_update":
                    time.sleep(0.05)
                    continue
                if response.get("status") != "ok":
                    raise SystemExit(
                        "runtime-app-podcast-player-url-smoke: unexpected response: "
                        f"{json.dumps(response)}"
                    )
                html = response["payload"]["html"]
                if fragment in html:
                    return html
                time.sleep(0.05)
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: timed out waiting for fragment "
                f"{fragment!r}"
            )

        def dispatch_and_wait(target_id, fragment):
            payload = send_ok(
                {"op": "dispatch", "event": {"targetId": target_id, "type": "click"}}
            )
            html = payload["html"]
            if fragment in html:
                return html
            return wait_for_fragment(fragment)

        try:
            initial = send_ok({"op": "render"})
            play_target_id = f"play-{episode['id']}"
            playing_html = dispatch_and_wait(play_target_id, "Backend:</span> linux_spike")

            deadline = time.time() + 10
            while time.time() < deadline and not summary_path.exists():
                time.sleep(0.05)
            if not summary_path.exists():
                raise SystemExit(
                    "runtime-app-podcast-player-url-smoke: helper never wrote validation summary"
                )

            refresh_html = dispatch_and_wait("refresh", "State:</span> completed")
            released_html = dispatch_and_wait("release", "State:</span> released")
        finally:
            assert process.stdin is not None
            process.stdin.close()
            return_code, stderr = wait_for_process_exit("shutdown", timeout_seconds=10)
            if return_code != 0:
                raise SystemExit(
                    "runtime-app-podcast-player-url-smoke: runtime host exited "
                    f"{return_code}\n{stderr}"
                )

        initial_html = initial["html"]
        if "No Solutions player" not in initial_html:
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: initial render missing headline"
            )
        if "Backend:</span> linux_spike" not in playing_html:
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: expected linux_spike backend"
            )
        if f"Source:</span> {source_url}" not in playing_html:
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: expected URL source label"
            )
        if "State:</span> completed" not in refresh_html:
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: refresh did not surface completed state"
            )
        if "State:</span> released" not in released_html:
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: release did not update state"
            )

        with summary_path.open("r", encoding="utf-8") as handle:
            summary = json.load(handle)
        if summary.get("source_kind") != "url":
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: expected helper summary source_kind=url"
            )
        if summary.get("source_path") != source_url:
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: expected helper summary source URL"
            )
        if not summary.get("success"):
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: helper summary reported failure"
            )
        if not summary.get("validate_only"):
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: helper summary did not record validate_only"
            )
        if CountingHandler.request_count < 1:
            raise SystemExit(
                "runtime-app-podcast-player-url-smoke: local HTTP fixture was never requested"
            )

        print(
            json.dumps(
                {
                    "bundlePath": bundle_path,
                    "fixtureRequestCount": CountingHandler.request_count,
                    "helperBinaryPath": str(helper_binary_path),
                    "result": "podcast-player-url-audio-ok",
                    "runtimeHostBinaryName": session["runtimeHostBinaryName"],
                    "runtimeHostPackageAttr": session["runtimeHostPackageAttr"],
                    "sourceUrl": source_url,
                },
                indent=2,
            )
        )
finally:
    server.shutdown()
    server.server_close()
    server_thread.join(timeout=5)
PY
}

main() {
  if [[ "$(uname -s)" == "Linux" || "$URL_SMOKE_REMOTE" == "1" ]]; then
    run_local_linux_smoke
    return
  fi

  run_remote_smoke
}

main "$@"
