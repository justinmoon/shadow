Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# Podcast Player Audio

## Intent

Make the pre-existing No Solutions podcast player a real end-to-end audio app for Shadow: visible app UX, audible playback on rooted Pixel, and a path that converges with native boot audio instead of growing a separate Android-only setup.

## Scope

- [~] Support the existing podcast player UX through `Shadow.os.audio`.
- [~] Prove rooted Pixel playback through the shared `linux_bridge` audio backend.
- [~] Exercise play, pause, seek, stop, volume, previous, and next in automated checks where practical.
- [ ] Keep VM/host smokes useful with the memory backend.
- [ ] Keep rooted Pixel as a hardware testbed while leaving the bridge contract usable from native boot.
- [ ] Avoid a second independent rooted-only podcast audio stack.

Out of scope for this phase:

- Full OS media session policy.
- Background audio across app lifecycle transitions.
- Multiple app audio focus and mixing.
- Streaming without up-front decode/buffering.

## Approach

Use the current app and suite model:

- Host smoke proves the UX state machine against the memory backend.
- Linux URL smoke proves URL source handling through `shadow-audio-bridge` in validate-only mode.
- Rooted Pixel `podcast` suite stages the podcast app, the fixture assets, and the shared audio bridge, then proves audible ALSA-backed playback.
- Native boot support should reuse the same bridge contract once the boot environment can stage ALSA config, routes, and assets.

## Steps

- [x] Establish the shared `linux_bridge` backend and `shadow-audio-bridge` binary.
- [x] Point rooted Pixel sound and podcast staging at the shared bridge contract.
- [x] Baseline current podcast player behavior on host and Pixel.
- [x] Tighten the podcast Pixel lane so it proves more than the initial auto-play marker.
- [ ] Add/manual-document a run path for the full UX on a rooted Pixel.
- [ ] Capture remaining bridge/service limitations after the UX proof.

## Implementation Notes

- Current `runtime/app-podcast-player` already calls `createPlayer`, `play`, `pause`, `seek`, `setVolume`, `stop`, `release`, and platform media handlers.
- Current `scripts/pixel/pixel_runtime_app_podcast_player_drm.sh` auto-clicks `play-00` and requires a `backend=linux_bridge` log marker.
- The bridge is still process-per-playback. Pause uses `SIGSTOP`; seek and volume restart playback from the requested offset.
- Baseline: host UX smoke passes, rooted Pixel podcast suite passes on `09051JEC202061`, but the old Pixel marker only proved bridge spawn, not completed ALSA playback.
- Tightening: the Blitz runtime wrapper can auto-click the app refresh control during CI, so completed/error state is visible without JS timers; the Pixel podcast lane should pull the bridge summary and fail unless ALSA playback succeeds.
- Current proof: rooted Pixel `podcast` now writes `audio-proof.json` from the bridge summary and requires completed ALSA playback for episode `00`; the Linux URL smoke also validates URL-backed playback through `shadow-audio-bridge`.
