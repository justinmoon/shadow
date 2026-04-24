Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Add the first app-facing sound API for runtime apps.
- First target: rooted Pixel runtime lane.
- MVP: play, pause, stop, and release one MP3-backed player from an app.
- Keep the app-facing API stable across host and Pixel even if the backend differs.
- Shipping preference order:
  Linux-native while it keeps producing hardware proof; use Android/vendor pieces only as narrow compatibility capsules when Linux-direct access is brittle or incomplete.
- JVM-backed playback is acceptable only as a demo/unblocker lane, not the intended shipped backend.
- Non-goals for v0: recording, mixing graphs, browser-compatible Web Audio, perfect AV sync, or ultra-low-latency synth input.

## Approach

- Keep sound below the existing OS API seam: apps call `@shadow/app-runtime-os`, not a renderer-specific hook.
- Add `Shadow.os.audio` beside `Shadow.os.nostr`.
- Keep audio off the render/dispatch JSON contract; use async OS ops and let the existing `renderIfDirty()` poll pick up UI state changes.
- Treat the rooted Pixel backend as Linux-first:
  1. prove playback from the current GNU helper against real `/dev/snd` and `/proc/asound`
  2. only add native Android/bionic or vendor HAL code for the smallest missing hardware seam
- Do not commit to a shipped JVM backend.
- Fallback Android-native shape: a tiny C++ bridge that uses Oboe/AAudio from a bionic process.
- For compressed assets, keep decode separate from output:
  - simplest native MVP: decode MP3 in-process to PCM, then feed Oboe
  - platform-native growth path: `AMediaExtractor` / `AMediaCodec` decode to PCM, then feed Oboe/AAudio
- Temporary demo/unblocker path: framework `MediaPlayer` for local-file or URL-backed MP3 playback.
- Connect `shadow-runtime-host` to the chosen bridge over a narrow IPC seam. Prefer a local socket or stdio-like command protocol over coupling audio to the Blitz client.
- Start with one active player and file-backed sources. Add multi-player or SFX-specialized paths only after the single-track seam is proven.
- Add asset staging so runtime apps can ship audio files next to the bundled JS on host and Pixel.

## Milestones

- [x] Backend decision proved on hardware.
  Linux-direct playback is the current rooted Pixel path. Reopen the native Android/bionic bridge only for a concrete Linux blocker.
- [x] App-facing audio API agreed.
  Land a small handle-based `Shadow.os.audio` contract before writing platform code.
- [x] Host/mock backend.
  Add a mock or no-op backend so app code and host smokes can land before Pixel audio is fully wired.
- [x] Pixel audio bridge MVP.
  The runtime host now drives the Linux ALSA helper against a staged MP3 and proves non-proxy playback through the normal rooted Pixel sound lane.
- [x] Runtime host extension.
  Add a `runtime-audio-host` crate/ops and inject `Shadow.os.audio` into `shadow-runtime-host`.
- [x] Asset pipeline.
  Runtime apps can now ship a sibling `assets/` directory, and host plus Pixel bundle prep stage that tree beside `bundle.js` automatically.
- [x] Smokes and operator recipes.
  Host API smoke, visible runtime sound app, and rooted Pixel automated sound proof now exist on the same `Shadow.os.audio` seam.
- [ ] Productize.
  Add volume, loop, seek, focus/interruption policy, and decide whether tiny UI sounds need a second fast path.

## Near-Term Steps

- [x] Run the Linux-direct probe first.
  Historical note: the deleted `pixel_linux_audio_spike.sh` proof produced audible output on the rooted Pixel. Current audio validation should use `just pixel-ci sound` or `just pixel-ci podcast`.
- [x] Harden the rooted Pixel Linux proof.
  `just pixel-ci sound` now waits long enough for the Linux helper to finish, pulls its root-owned `audio-spike-summary.json`, writes `audio-proof.json`, and fails unless file-backed ALSA playback reaches a non-proxy PCM route.
- [ ] Prove the native Android bridge shape on a real Pixel.
  Keep this as a fallback only. If Linux-direct routing or decode becomes unstable, play a known MP3 through a bionic-native helper from `adb shell` and confirm the smallest Android/vendor surface that solves the blocker.
- [ ] Pick packaging and IPC.
  Preferred shipped shape: `shadow-audio-bridge` native daemon plus local socket. Demo fallback: `app_process` with a tiny Java entrypoint.
- [ ] Lock the MVP API.
  Prefer `createPlayer`, `play`, `pause`, `stop`, `release`, and `getStatus` over raw PCM streaming for v0.
- [x] Add one demo app.
  Create `runtime/app-sound-smoke/app.tsx` with Play, Pause, Stop, Loop, and visible status/error state.
- [x] Add one operator command.
  Add host and rooted-Pixel validation paths for the runtime sound app.
- [x] Prove staged file-backed playback.
  The runtime sound app now accepts a configured `file` source, stages a bundle-relative audio file into the runtime bundle, and auto-clicked Pixel runs spawn the file-backed Linux helper instead of the tone-only path.
- [x] Swap the demo asset to a compressed file.
  The staged demo asset is now the checked-in MP3 fixture `assets/demo-tone.mp3`, not the generated WAV placeholder.
- [x] Generalize app-local asset staging.
  `runtime_prepare_app_bundle.ts` now copies sibling `assets/` into the compiled bundle dir, and Pixel runtime artifact prep carries that same tree to `/data/local/tmp/shadow-runtime-gnu` without a sound-demo-specific overlay hook.
- [x] Add a richer file-backed sample app.
  `runtime/app-podcast-player/app.tsx` now plays a staged local episode set, and the prep/launcher scripts prove the same runtime-audio seam with multiple downloaded files instead of one synthetic demo clip.

## Implementation Notes

- The current runtime seam is already the right insertion point:
  `@shadow/app-runtime-os` -> bundled JS helper -> `shadow-runtime-host` extension -> platform service.
- `runtime/app-runtime/shadow_runtime_os.js` is the obvious home for the JS-side audio wrapper and mock fallback.
- `rust/runtime-nostr-host` is the pattern to copy for a new `runtime-audio-host` crate.
- `scripts/runtime/runtime_prepare_app_bundle.ts` and `scripts/pixel/pixel_prepare_runtime_app_artifacts.sh` are the current staging seams for bundle-adjacent assets.
- The rooted Pixel takeover scripts stop display services, not audio services, so Android-owned playback should survive the current takeover model.
- The current helper is glibc/Linux and remains the preferred rooted Pixel path while it has hardware proof. A bionic helper is a fallback compatibility boundary, not the default product shape.
- Direct Linux audio from the GNU helper has real hardware evidence, but it still needs careful routing ownership because there is no desktop audio server and the Pixel mixer controls are device-specific.
- The first Linux-direct spike stays intentionally narrow: synthesized PCM tone, ALSA device candidates discovered from `/proc/asound/pcm`, copied `share/alsa` and an optional `lib/alsa-lib` plugin dir into the GNU bundle, and JSON summary capture under a dedicated Pixel run dir.
- The GNU launcher for the audio spike must not `chroot`; the process needs the device's real `/dev/snd` and `/proc/asound` surfaces to stay visible.
- The probe must not count proxy or hostless PCM success as "sound works." On this device, the actual audible proof came from `MultiMedia1` / `plughw:0,0` after applying the speaker route controls, while `AFE-PROXY` accepted PCM without audible output.
- The first runtime audio slice is now file-backed. It proves `Shadow.os.audio` end-to-end with a staged MP3 while keeping decode inside the Linux helper and output on ALSA.
- The rooted Pixel runtime lane cannot stay `chroot`ed if it needs Linux-direct audio. The sound-specific launcher has to execute in the real device root so the runtime host and its helper can keep `/dev/snd` and `/proc/asound`.
- The safest regression boundary is a sound-only no-`chroot` launcher. Keep the existing runtime-app launcher behavior unchanged for non-audio apps until the broader Pixel runtime lane is revalidated on the real phone.
- `runtime-audio-host` now owns the first durable contract: `createPlayer`, `play`, `pause`, `stop`, `release`, and `getStatus`, with a memory backend on host and a `linux_spike` backend on the rooted Pixel lane.
- The current rooted Pixel proof is now app-level and audible: the sound demo auto-clicked `play`, `Shadow.os.audio` spawned `run-shadow-linux-audio-spike`, and the device speaker emitted the tone during the rooted runtime session.
- The current runtime demo is file-backed too: `scripts/runtime/prepare_sound_demo_assets.sh` now hash-checks the checked-in MP3 fixture and points the app at `assets/demo-tone.mp3`, while generic runtime bundle prep stages sibling `assets/` beside `bundle.js` on host and Pixel.
- The current rooted Pixel sound CI proof is machine-readable too: `audio-proof.json` requires `summarySuccess=true`, `sourceKind=file`, the expected staged source path, and at least one successful non-proxy ALSA attempt. Latest proof on `09051JEC202061` selected `plughw:0,0` with route `speaker-mm1`.
- The Linux helper now accepts both `tone` and `file` sources. File decode is in-process via Symphonia, while ALSA routing/output stays the same as the audible tone spike.
- The compressed demo fixture is reproducible: `scripts/runtime/generate_sound_demo_fixture.sh` rebuilds it under Nix with `ffmpeg`, and `scripts/runtime/prepare_sound_demo_assets.sh` refuses unexpected hashes.
- `just runtime-app-sound-smoke` now covers two host-side contracts: the normal `memory` backend UI flow and a fake `linux_spike` helper that writes junk to stdout, so stdio pollution in the audio helper path fails locally instead of waiting for a Pixel run.
- Rooted Pixel runtime-app runs now also forbid `[shadow-runtime-demo] runtime-event-error:` in `session-output.txt`, so protocol decode errors no longer hide behind otherwise successful marker/frame checks.
- `shadow-runtime-host` now defaults `SHADOW_RUNTIME_BUNDLE_DIR` from the `--session` bundle path, so relative asset lookup works on host without per-smoke env glue.
- The first richer content sample is intentionally operator-staged, not checked in: `scripts/runtime/prepare_podcast_player_demo_assets.sh` downloads No Solutions episodes `#00` through `#04` into `build/runtime/app-podcast-player-assets`, converts the non-MP3 teaser to MP3, and feeds that set into a simple runtime player app.
- If we need a shipped native path, Android’s current guidance is to target Oboe or AAudio rather than new OpenSL ES designs.
- Start with file or URI playback, not PCM streaming. If we later need synthesis or latency-critical SFX, add a separate streaming/SFX API instead of overloading the MP3 path.
