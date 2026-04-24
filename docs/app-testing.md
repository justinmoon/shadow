---
summary: Best practices for staging, running, and validating individual Shadow apps on VM and rooted Pixel
read_when:
  - adding or changing a Shadow app or runtime host integration
  - deciding between `run`, `stage`, `ci`, and `run-only`
  - trimming rooted-Pixel staging to the app or suite under test
---

# App Testing

The public contract is:

- `just run target=<vm|pixel> app=<id>` for manual sessions.
- `sc -t pixel stage <suite>` or `just pixel-stage <suite>` to build and push the artifacts needed for one rooted-Pixel validation suite.
- `sc -t pixel ci --run-only <suite>` or `just pixel-run <suite>` to execute a suite against already-staged artifacts.
- `sc -t pixel ci <suite>` or `just pixel-ci <suite>` to stage and then execute the suite end to end.

Do not add a new top-level script or `just` recipe for every app. The reusable operator surface already exists in `shadowctl`.

## Best Practice

- Treat `run` as the manual developer loop. It is allowed to be interactive and broad.
- Treat `stage` and `ci` as deterministic validation lanes. They should stage only the artifacts required by the selected suite.
- Keep app selection inside the existing suite model. Extend `shadowctl` and `scripts/ci/pixel_ci.sh`; do not create parallel ad hoc wrappers.
- For rooted-Pixel hardware features, use live-or-fail behavior. Do not silently fall back to mocks in the device lane.
- The supported rooted-Pixel camera lane no longer accepts `PIXEL_CAMERA_ALLOW_MOCK`; if the live camera broker is unavailable, the lane should fail.
- Put reusable behavior in `shadowctl` or shared helper libraries under `scripts/lib/`. Do not grow more one-off scripts in `scripts/`.

## Current Suite Model

- `timeline` stages the shell runtime for `timeline` only, then runs the timeline lifecycle smoke.
- `camera` stages the shell runtime for `camera` only, then runs the live camera capture smoke.
- `quick` and `shell` stage the shell runtime for `timeline,camera`, then run both shell-facing smokes.
- `sound`, `podcast`, and `nostr` stage their own runtime-app lanes instead of the shell runtime.
- `full` composes the shell lanes plus the runtime-app lanes.

This is the right abstraction. The suite should describe the product slice under test, and staging should derive the minimal artifact set from that suite.

## Requirements For A New App Lane

1. The app must be buildable through the shared runtime artifact pipeline.
2. If the app is shell-launchable, it must be registered in [scripts/lib/session_apps.txt](../scripts/lib/session_apps.txt).
3. The lane needs a deterministic smoke or assertion path. Prefer log markers, control-socket state checks, captured output, or pulled artifacts over manual inspection.
4. The Pixel suite must declare exactly which staged artifacts it needs.
5. The docs must say how to run it manually and how to validate it in CI.

## When To Add A New Suite

- Add a suite when the staged artifact set or the validation contract is materially different.
- Reuse an existing suite when the new app fits the same staged product slice.
- If you need multiple apps together, prefer composing one suite from multiple steps over creating a second command surface.

## Validation Strategy

- For VM work, start with `just run target=vm app=<id>` and `just smoke target=vm`.
- For rooted Pixel bring-up, use `just pixel-stage <suite>` until staging is stable, then `just pixel-run <suite>` for fast reruns, and `just pixel-ci <suite>` before claiming the lane is green.
- Every rooted-Pixel lane should leave behind a run directory under `build/pixel/runs/ci/` or the relevant smoke directory with logs and a machine-readable summary.
- `sound` additionally writes `audio-proof.json` and `audio-spike-summary.json` in its `build/pixel/drm-guest/<run>/` directory. The lane is green only when the Linux ALSA helper proves file-backed playback on a non-proxy PCM route.
- For manual audible sound checks, keep the same lane but raise the helper gain, for example `PIXEL_RUNTIME_AUDIO_SPIKE_GAIN=0.35 just pixel-ci sound --target <serial> --run-only`. The CI default is intentionally quieter.
