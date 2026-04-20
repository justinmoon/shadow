# Target Config Shape

Status: draft

This document describes the desired end-state config model for the supported VM and rooted-Pixel lanes.

## Design Goals

- one checked-in source for static app metadata
- one generated per-run config artifact for dynamic target/session state
- one small explicit env boundary for process-local concerns
- one typed config load near process startup for each major binary
- no multiline shell env blobs as structured transport

## Config Layers

### Layer 1: App Catalog

Purpose:

- checked-in, reviewable product metadata

Candidate file:

- `runtime/apps.json`

Owns:

- app identity
- display metadata
- profiles
- model kind
- bundle identity
- launch defaults
- capability declarations
- app-owned default service policy

Should grow to cover:

- capabilities and permissions
- lifecycle policy hints
- canonical launch model
- service defaults

Should not own:

- current target serial
- current runtime bundle path on disk
- current session viewport
- host-specific state directories

### Layer 2: Generated Target Session Config

Purpose:

- dynamic per-run, target-aware config for VM or Pixel launch/session

Candidate file:

- `.shadow-vm/runtime-artifacts/session-config.json`
- Pixel equivalent under the staged run/artifact root

Suggested top-level shape:

```json
{
  "schemaVersion": 1,
  "target": {
    "kind": "vm-shell",
    "serial": null
  },
  "startup": {
    "mode": "shell",
    "startAppId": "podcast",
    "shellStartAppId": null
  },
  "artifacts": {
    "artifactRoot": "/opt/shadow-runtime",
    "systemBinaryPath": "/opt/shadow-runtime/shadow-system",
    "defaultRuntimeBundlePath": "/opt/shadow-runtime/apps/counter/bundle.js",
    "appBundles": {
      "counter": "/opt/shadow-runtime/apps/counter/bundle.js"
    }
  },
  "window": {
    "surfaceWidth": 660,
    "surfaceHeight": 1240,
    "safeAreaInsets": {
      "left": 0,
      "top": 0,
      "right": 0,
      "bottom": 0
    },
    "undecorated": true
  },
  "compositor": {
    "transport": "direct",
    "bootSplashDrm": true,
    "enableDrm": true,
    "gpuShell": false,
    "backgroundAppResidentLimit": 3,
    "frameCapture": {
      "mode": "off",
      "artifactPath": "/shadow-frame.ppm",
      "snapshotCache": false,
      "checksum": false,
      "writeEveryFrame": false
    }
  },
  "runtime": {
    "runtimeDir": "/data/local/tmp/shadow-runtime",
    "stateDir": "/var/lib/shadow-ui"
  },
  "services": {
    "nostr": {
      "dbPath": "/var/lib/shadow-ui/runtime-nostr.sqlite3",
      "socketPath": "/var/lib/shadow-ui/runtime-nostr.sock"
    },
    "cashu": {
      "dataDir": "/var/lib/shadow-ui/runtime-cashu"
    },
    "camera": {
      "endpoint": "127.0.0.1:37656",
      "allowMock": false,
      "timeoutMs": 30000
    },
    "audio": {
      "backend": "memory"
    }
  },
  "graphics": {
    "wgpuBackend": "vulkan",
    "mesaShaderCacheDir": "/data/local/tmp/shadow-runtime-gnu/home/.cache/mesa"
  },
  "debug": {
    "touchSignalPath": "/data/local/tmp/shadow-runtime/touch-signal",
    "touchLatencyTrace": false
  }
}
```

The exact shape can change. The important part is the layer boundary:

- app catalog stays static
- session config is the generated, target-aware expansion

### Layer 3: Process Env Projection

Purpose:

- thin compatibility and OS-boundary transport

Examples that should remain env-driven:

- `WAYLAND_DISPLAY`
- `XDG_RUNTIME_DIR`
- `TMPDIR`
- `LD_LIBRARY_PATH`
- `LIBGL_DRIVERS_PATH`
- `VK_ICD_FILENAMES`

Examples that should become config-backed compatibility shims during migration:

- `SHADOW_RUNTIME_APP_BUNDLE_PATH`
- `SHADOW_SYSTEM_BINARY_PATH`
- `SHADOW_GUEST_START_APP_ID`
- `SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH`
- `SHADOW_RUNTIME_NOSTR_DB_PATH`
- `SHADOW_RUNTIME_CAMERA_ENDPOINT`

## Binary-Level Consumption Model

### `shadowctl` / host prep scripts

Should own:

- generating target/session config
- validating that config against schemas
- projecting only the minimal env surface needed by each launched process

Should not keep owning:

- long-lived duplicated logic for reassembling the same startup state in shell strings

### `shadow-session`

Should load:

- one session config artifact

Should keep from env:

- only values that are genuinely inherited from the launcher process environment and make sense there

### `shadow-compositor`

Should load:

- one host compositor launch/session config

Should stop owning:

- duplicated app/window safe-area env assembly as a primary model

### `shadow-compositor-guest`

Should load:

- one guest startup config artifact directly

Should stop requiring:

- `SHADOW_GUEST_CLIENT_ENV` as shell text
- `SHADOW_GUEST_SESSION_ENV` as shell text

### App binaries

Should receive:

- small, canonical launcher-managed env
- optional app-specific generated config payload when that is the natural boundary

Should stop depending on:

- duplicated canonical plus legacy field names forever

## Namespace Rules

### Canonical app/window namespace

Preferred long-term:

- `SHADOW_APP_*` for app/window/lifecycle fields

Compatibility:

- keep `SHADOW_BLITZ_*` reads temporarily
- stop adding new canonical fields there now

### Canonical session/runtime namespace

Preferred long-term:

- `SHADOW_SESSION_*`
- `SHADOW_RUNTIME_*`
- `SHADOW_SERVICE_*` only if a service-specific split becomes necessary

### Canonical target/operator namespace

Preferred long-term:

- CLI flags and generated config first
- env only for narrow local override seams

## What A Nice End State Looks Like

- Add a new app by editing one checked-in manifest entry and regenerating code.
- Launch VM or Pixel by generating one target/session config artifact.
- Inspect the exact startup state by opening one JSON file instead of reading five shell scripts.
- Change a compositor policy field in one schema-owned place and have both VM and Pixel consume it consistently.
- Keep boot-lab and CI knobs available, but clearly outside the supported session config model.
- Be able to answer:
  - where does this field come from?
  - who owns it?
  - is it static metadata, generated session state, or process env?
  - what compatibility burden does it still carry?
