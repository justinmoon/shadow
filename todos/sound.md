Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Finish sound support to the point where other app/platform work can treat it as stable infrastructure instead of an active bring-up project.
- Keep `Shadow.os.audio` as the only app-facing seam.
- Support the current operator surface:
  - VM/QEMU shell apps
  - rooted Pixel shell apps
  - bundled runtime apps on host
- Add URL-backed podcast playback without requiring MP3 downloads to disk.
- Keep file-backed playback working for fixtures, demos, and offline branch gates.
- Include audio/media button support so focused audio apps can react to play/pause, track navigation, and volume buttons.
- Non-goals for this wrap-up:
  - recording
  - browser-compatible `<audio>` / Web Audio
  - mixing graphs / multi-track editing
  - native Android bridge work unless the current Linux backend proves too brittle

## Approach

- Treat the current `linux_spike` backend as the working v0 default unless it blocks real app work.
- Keep the handle-based API shape:
  - `createPlayer`
  - `play`
  - `pause`
  - `stop`
  - `release`
  - `getStatus`
- Add one new source kind first: `url`.
- For v0 URL playback, prefer the smallest useful implementation:
  - fetch response in the runtime audio host or helper
  - decode from memory / stream
  - avoid persisting the media to disk
- Do not turn `Shadow.os.audio` into a general network abstraction.
- Treat audio/media buttons as control input wired onto the same player/app seam, not as a separate special-case podcast API.
- Keep CI offline-safe by continuing to use checked-in/local fixtures for default VM and host paths.
- Prove URL playback with a tiny local HTTP fixture smoke before touching real third-party feeds in gates.
- Defer true progressive streaming until a concrete app needs “start before full fetch completes.”

## Agent Handoff

- This plan is mostly complete. New agents should only take it if working on visible progress, seek, volume, timeouts, or backend hardening.
- Avoid long audible playback while validating. Start playback only long enough to observe success, then stop/restore promptly.
- Keep default branch gates offline-safe. File-backed fixtures remain the default; URL playback should use local HTTP fixtures unless explicitly running an external/manual test.
- Do not make the macOS aggregate gate depend on a private remote Linux host. Linux-authoritative URL tests should stay explicit or run where Linux is available.
- Likely write areas: `rust/runtime-audio-host/`, audio helper crates, podcast runtime app code, `scripts/ci/runtime_app_podcast_player_url_smoke.sh`, and media control handling in UI/compositor code.
- Coordinate with app-metadata before changing podcast bundle/config metadata.
- Validate with host/file smokes first; run the URL smoke on Linux or explicitly opt in; use targeted `just pixel-ci sound` or `just pixel-ci podcast` only when rooted hardware behavior changes.
- Use `SHADOW_AUDIO_SPIKE_VALIDATE_ONLY=1` where possible to prove fetch/decode without depending on ALSA hardware.

## Milestones

- [x] App-facing audio seam exists.
  `Shadow.os.audio` is installed by the runtime host and already used by runtime apps.
- [x] Host/mock backend exists.
  The host can exercise the API without Pixel audio hardware.
- [x] Rooted Pixel Linux backend exists.
  The current `linux_spike` path is audible on the device.
- [x] File-backed playback exists.
  Runtime apps can play staged local assets on host, VM, and Pixel lanes.
- [x] Shared artifact builder knows about audio/podcast apps.
  Sound is no longer a one-off staging path.
- [x] URL-backed playback exists.
  The host/helper/app plumbing is landed and a Linux-authoritative local-HTTP end-to-end smoke now proves the podcast path.
- [x] Player semantics are minimally productized.
  The first consumer now has play/pause/previous/next controls, platform media routing, and a sane default launch surface.
- [x] Audio/media button support exists.
  Focused runtime apps can now receive play/pause/play/next/previous through the compositor control path and handle them through `Shadow.os.audio`.
- [~] Audio branch gate is trustworthy.
  Dedicated file and URL smokes exist. The URL smoke remains explicit/Linux-first rather than silently depending on a private remote host from the default macOS aggregate lane.
- [x] Backend decision is explicit.
  `linux_spike` remains the accepted v0 backend until a real app proves it too brittle.

## Near-Term Steps

- [x] Add `source.kind = "url"` and `source.url` in `runtime-audio-host`.
- [x] Refactor the Linux helper decode path so it is not hard-wired to `File::open(...)`.
- [x] Update the podcast app so runtime config can opt into `episode.sourceUrl` playback while file-backed fixtures remain the default offline path.
- [x] Add a Linux-authoritative smoke that serves the checked-in podcast fixture over local HTTP on the same executor as the helper and proves URL playback end to end.
- [x] Add an audio/media button path that routes play/pause/next/previous to the focused audio app without hard-coding podcast UI behavior.
- [x] Decide the v0 behavior for URL playback:
  Buffer the full response in memory before play for v0; defer true progressive playback until an app proves it is necessary.
- [x] Add `positionMs` to status.
- [x] Add `seek` for the first consumer.
- [x] Add `volume` for per-player gain.
- [ ] Revisit the standard remote smoke timeout if audio adoption depends on it; today the longer `ui-smoke` timeout is more trustworthy than the default cold-build budget.

## Implementation Notes

- `runtime-audio-host` now supports `tone`, `file`, and `url`.
- The podcast app can now switch between file-backed and URL-backed playback via runtime config (`playbackSource`), while default fixtures stay file-backed.
- The Linux helper can now fetch a URL into memory, then decode it through the same Symphonia path used for file playback.
- `just run` now defaults to the podcast app so the audio path is the front-door demo instead of a hidden app id.
- Platform media actions now flow through the compositor control socket into the focused Blitz app, then into the runtime host as a dedicated session request, and finally into app code through `Shadow.os.audio`.
- `shadowctl media <action>` now exists for VM and Pixel and returns nonzero when the focused app does not actually handle the action; supported actions now include `volume-up` and `volume-down`.
- `Shadow.os.audio` status now reports `positionMs` and `volume`, and the host exposes `seek` plus `setVolume`.
- The first consumer now uses `seek` and per-player volume from app UI and platform media-button handlers.
- Rooted Pixel sessions now read physical media/volume button events directly from `/dev/input/event*` and route them through the same focused-app media control path as `shadowctl media`.
- The Linux helper also has a `SHADOW_AUDIO_SPIKE_VALIDATE_ONLY=1` mode so URL fetch/decode can be proved without depending on ALSA device availability.
- The Linux helper now bounds in-memory URL fetch size with `SHADOW_AUDIO_SPIKE_MAX_URL_BYTES` so v0 URL playback cannot buffer unbounded responses.
- `scripts/ci/runtime_app_podcast_player_url_smoke.sh` is Linux-authoritative: on macOS it syncs to a Linux executor, serves a local HTTP fixture there, and runs the real helper through the runtime host seam.
- The shared artifact builder already has a clean place to keep offline podcast fixtures and app-local assets.
- VM/master now uses a checked-in local podcast fixture so branch gates do not need the live RSS/media path just to boot the app.
- The clean v0 split is:
  - fixtures and branch gates stay file-backed and offline-safe
  - optional URL smoke proves the new network-backed path against a local test server
- The aggregate host smoke keeps the direct file-backed podcast/media-control smoke in the default lane and only pulls in the URL smoke automatically on Linux or when explicitly opted in.
- If URL playback turns out to need true streaming rather than in-memory buffering, that is the point to decide whether `linux_spike` is still the right backend for v0.
