# Config Scope

Status: draft

This document fixes the configuration boundary for the repo so the living plan can stay short.

## Problem

The repo already has some good config seams, but they are incomplete:

- static app metadata already lives in `runtime/apps.json`
- generated Rust metadata already flows from that manifest
- VM runtime artifacts are already generated on the host

The remaining surface is fragmented across:

- shell export files
- inline shell defaults
- `PIXEL_*` control and debug knobs
- `SHADOW_*` launcher and runtime knobs
- duplicated legacy namespaces such as `SHADOW_BLITZ_*`
- Nix `builtins.getEnv` overrides
- per-service env parsing in Rust and TypeScript paths

The result is not one problem. It is several different classes of config sharing one transport by accident.

## Definition Of A Good Config System Here

For this repo, a good config system means:

- typed, schema-checked config for the supported VM and rooted-Pixel session surfaces
- one clear owner per config field
- one canonical source for static app metadata
- generated per-run config artifacts for dynamic target/session state
- small explicit env surfaces at real process and OS boundaries
- deliberate debug and private override channels instead of accidental ones
- predictable migration and compatibility rules

It does not mean:

- replacing every env var in the repo with a config file
- removing all operator/debug overrides
- forcing boot-lab or CI-only experimentation through product-grade config immediately
- turning `shadowctl` into a giant stateful control plane

## Config Taxonomy

### 1. Static Product Metadata

Examples:

- app id
- profiles
- app model
- runtime bundle identity
- Wayland app id
- window metadata
- launch capabilities

Desired home:

- checked-in manifest(s), generated code, schema validation

### 2. Generated Session Config

Examples:

- target kind
- selected app / startup action
- runtime bundle paths
- system binary path
- viewport / surface metrics
- compositor policy
- service paths
- target-local state dirs

Desired home:

- generated per-run config artifact, not ad hoc shell export text

### 3. Process-Boundary Env

Examples:

- `WAYLAND_DISPLAY`
- `XDG_RUNTIME_DIR`
- `TMPDIR`
- `LD_LIBRARY_PATH`
- graphics-driver variables

Desired home:

- env vars remain the transport, but the set is intentionally small

### 4. Runtime Service Config

Examples:

- camera endpoint / mock policy
- nostr db path and socket path
- cashu data dir
- audio backend and helper paths

Desired home:

- structured session/service config, with optional env compatibility during migration

### 5. Operator And Target Overrides

Examples:

- target serial selection
- selected target profile
- intentional local source overrides
- explicit run-mode or stage-only switches

Desired home:

- CLI flags first, config overlays second, env only when unavoidable

### 6. Debug, CI, And Boot-Lab Knobs

Examples:

- most `PIXEL_BOOT_*`
- smoke timing overrides
- frame capture toggles
- mock/test-only inputs

Desired home:

- explicit private/debug namespaces
- documented as non-product config
- not allowed to leak into the supported product surface by default

## Env Family Policy

### `SHADOW_*`

- Use for canonical product/runtime/operator config only.
- New keys need an owner, a documented layer, and a reason env is still the right transport.
- Avoid introducing more duplicate namespaces.

### `SHADOW_BLITZ_*`

- Treat as legacy compatibility only.
- No new canonical config should start here.
- Remove in stages after the supported launch/session path reads one canonical model.

### `PIXEL_*`

- Split conceptually into:
  - supported Pixel operator inputs
  - session-build/session-debug inputs
  - boot-lab/private bring-up inputs
  - smoke/test-only inputs
- Do not try to flatten all `PIXEL_*` into product config.
- The supported Pixel session subset should converge on structured target/session config first.

### `MOCK_*`

- Keep test-only.
- Do not promote into runtime or operator-facing config.

## Current Architectural Rule

The supported front door remains:

- VM shell/home plus app launch
- rooted Pixel shell/home plus app launch

Config cleanup should optimize for those lanes first. Boot-lab, Cuttlefish legacy, and one-off debug paths should follow the rules eventually, but they should not block the primary seam cleanup.

## Repo Rules

- Static metadata must be schema-checked and code-generated where consumption crosses languages.
- Dynamic target/session config must be generated once and consumed many times.
- Shell text blobs are not an acceptable long-term transport for structured config.
- New launcher-managed fields must not be duplicated across multiple env namespaces.
- New config should be added to the owning schema first, then projected into env only when that boundary truly needs env.
