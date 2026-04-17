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
- Include audio/media button support so focused audio apps can react to play/pause and track navigation.
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
- [ ] Player semantics are minimally productized.
  Add the smallest missing controls/status needed by real apps.
- [ ] Audio/media button support exists.
  Focused audio apps should be able to respond to play/pause and next/previous from platform controls.
- [~] Audio branch gate is trustworthy.
  Dedicated file and URL smokes exist; the remaining gap is deciding where the URL smoke belongs in the canonical branch gate.
- [~] Backend decision is explicit.
  Current assumption: `linux_spike` is acceptable for v0 unless new failures show up.

## Near-Term Steps

- [x] Add `source.kind = "url"` and `source.url` in `runtime-audio-host`.
- [x] Refactor the Linux helper decode path so it is not hard-wired to `File::open(...)`.
- [x] Update the podcast app so runtime config can opt into `episode.sourceUrl` playback while file-backed fixtures remain the default offline path.
- [x] Add a Linux-authoritative smoke that serves the checked-in podcast fixture over local HTTP on the same executor as the helper and proves URL playback end to end.
- [ ] Add an audio/media button path that routes play/pause/next/previous to the focused audio app without hard-coding podcast UI behavior.
- [x] Decide the v0 behavior for URL playback:
  Buffer the full response in memory before play for v0; defer true progressive playback until an app proves it is necessary.
- [ ] Add `positionMs` to status if app work immediately needs visible progress.
- [ ] Add `seek` only if the first consumer actually needs it.
- [ ] Add `volume` only if the first consumer actually needs per-player gain.
- [ ] Revisit the standard remote smoke timeout if audio adoption depends on it; today the longer `ui-smoke` timeout is more trustworthy than the default cold-build budget.

## Implementation Notes

- `runtime-audio-host` now supports `tone`, `file`, and `url`.
- The podcast app can now switch between file-backed and URL-backed playback via runtime config (`playbackSource`), while default fixtures stay file-backed.
- The Linux helper can now fetch a URL into memory, then decode it through the same Symphonia path used for file playback.
- The Linux helper also has a `SHADOW_AUDIO_SPIKE_VALIDATE_ONLY=1` mode so URL fetch/decode can be proved without depending on ALSA device availability.
- `scripts/ci/runtime_app_podcast_player_url_smoke.sh` is Linux-authoritative: on macOS it syncs to a Linux executor, serves a local HTTP fixture there, and runs the real helper through the runtime host seam.
- The shared artifact builder already has a clean place to keep offline podcast fixtures and app-local assets.
- VM/master now uses a checked-in local podcast fixture so branch gates do not need the live RSS/media path just to boot the app.
- The clean v0 split is:
  - fixtures and branch gates stay file-backed and offline-safe
  - optional URL smoke proves the new network-backed path against a local test server
- Audio/media buttons should land as platform-level control routing, not as podcast-app-specific button handling.
- If URL playback turns out to need true streaming rather than in-memory buffering, that is the point to decide whether `linux_spike` is still the right backend for v0.
