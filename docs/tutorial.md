---
summary: Historical bring-up walkthrough and deeper system context beyond the front-door operator docs
read_when:
  - you need historical or subsystem context that is intentionally omitted from architecture.md
  - you are tracing the full Shadow stack end to end during bring-up or debugging
---

# Shadow Tutorial

Shadow is a custom mobile OS stack built from the ground up. We take a rooted Android phone, stop the Android display server, and run our own compositor, runtime, and apps directly on the Linux kernel. This tutorial explains every layer of the system.

For the current supported operator surface, start with `docs/architecture.md`. That doc now defines the front door: local VM/QEMU shell/home plus app launch and rooted-Pixel shell/home plus app launch, with `just run target=...` / `just stop target=...` as the target-aware session entrypoints. This tutorial still carries older bring-up and probe material for deeper context.

---

## Development Environments

Shadow runs on two targets during development: a QEMU virtual machine for fast iteration on macOS, and a rooted Pixel 4a for real hardware validation.

### QEMU Emulator

The QEMU VM gives you a full Linux environment running the Shadow compositor in a native macOS window. It's built with NixOS via microvm.nix.

**What it provides:**
- 4 vCPUs, 4 GB RAM
- virtio-gpu display at 660x1240 (phone-like portrait)
- USB keyboard and tablet input
- 9P share mounting staged runtime artifacts at `/opt/shadow-runtime`
- SSH access on a worktree-scoped forwarded port (`sc -t vm ssh` picks the right one)

**Startup flow:**
1. `just run target=vm` stages runtime bundles under `.shadow-vm/runtime-artifacts`, builds the NixOS image, and launches QEMU
2. The guest boots, greetd starts a user session via cage (a minimal Wayland kiosk)
3. `shadow-ui-session` sources the staged runtime env, launches the packaged compositor, and exposes a control socket
4. The VM reaches steady state — compositor running, control socket ready

**Common commands:**
```bash
just run target=vm                    # Launch the VM
sc -t vm ssh                          # SSH into the guest
sc -t vm logs                         # Tail compositor session logs
sc -t vm status                       # Show running processes and state
sc -t vm open counter                 # Launch an app in the compositor
sc -t vm home                         # Return to the home screen
just stop target=vm                   # Shut down the VM
```

Behind these recipes, `scripts/shadowctl` is the unified Python CLI for VM and rooted-Pixel iteration. In the devshell, `sc` is a thin wrapper on `PATH` that runs it; use `-t vm`, `-t pixel`, or an explicit Pixel serial from `sc devices`.

### Rooted Pixel

The Pixel 4a is our real hardware target. Android phones normally don't let you run arbitrary code as the superuser — "rooting" means patching the boot image so we get full `su` (superuser) access while keeping the stock Android system intact. We use Magisk, a popular rooting tool, to do this.

**What we turn off:**
When Shadow takes over the display, we stop the Android graphics stack. Android is a full OS with its own display pipeline, and we need to shut all of it down so our code can talk to the hardware directly:

- `surfaceflinger` — Android's compositor. Just like Shadow has its own compositor (explained below), Android has one too. SurfaceFlinger takes buffers from every Android app and composites them onto the screen. We stop it so we can draw to the screen ourselves.
- `vendor.hwcomposer-2-4` — the hardware composer HAL (Hardware Abstraction Layer). This is a vendor-provided service that SurfaceFlinger delegates to for efficient compositing on Qualcomm hardware. With SurfaceFlinger gone, this needs to go too.
- `vendor.qti.hardware.display.allocator` — Qualcomm's graphics memory allocator. It manages GPU-accessible memory buffers for Android's graphics pipeline. We stop it to fully release the GPU and display resources.
- `bootanim` — the boot animation service. Trivial, but it also holds a graphics context.
- SELinux is set to permissive — SELinux is a Linux kernel security module that restricts what processes can do. Android runs it in "enforcing" mode, which would block our binaries from accessing hardware devices. Permissive mode logs violations instead of blocking them.

This frees `/dev/dri/card0` (the Linux kernel's device file for the display hardware) so our compositor can drive the display directly.

**Root acquisition (one-time setup):**
```bash
sc root-prep             # Download OTA, extract boot.img, fetch Magisk APK
sc -t pixel root-patch   # Run Magisk's patcher on device, pull patched boot.img
sc -t pixel root-flash   # Flash patched boot via fastboot
sc -t pixel root-check   # Verify root works
```

**Running apps on device:**
```bash
sc -t pixel stage shell             # Build and push shell/runtime artifacts
just run target=pixel app=shell     # Run the shell/home scene
just run target=pixel app=timeline  # Run and ask the shell to open timeline
just stop target=pixel              # Restore Android's display stack
sc -t pixel ci timeline             # Run the timeline hardware subset
sc -t pixel stage camera            # Stage artifacts without executing the suite
```

Artifacts are cross-compiled as static musl binaries (aarch64), pushed to `/data/local/tmp/`, and executed as root via `su`.

---

## How Apps Work

Shadow apps are built with three layers: SolidJS for UI components, Deno for JavaScript execution, and Blitz for rendering HTML/CSS to pixels.

### The App Stack

```
┌──────────────────────────────────┐
│  SolidJS (app.tsx)               │  Reactive components → virtual DOM
├──────────────────────────────────┤
│  Deno (shadow-system)            │  JS execution + Rust platform APIs
├──────────────────────────────────┤
│  Blitz (shadow-blitz-demo)       │  HTML/CSS → pixels via Vello/wgpu
└──────────────────────────────────┘
```

### SolidJS

Apps are written in pure TypeScript — just `.tsx` files with no build config to manage. SolidJS gives you reactive UI primitives (signals, effects, JSX) that compile down to efficient JavaScript. And because apps run in a real Deno runtime with Rust platform APIs underneath, they can do things like write to disk, play audio, access the camera, and talk to the network — not just render UI.

Here's the counter app (`runtime/app-counter/app.tsx`):

```tsx
import { createSignal } from "@shadow/sdk";

export function renderApp() {
  const [count, setCount] = createSignal(1);

  return (
    <main style="background:#0b1630">
      <section onClick={() => setCount((v) => v + 1)}>
        {count()}
      </section>
    </main>
  );
}
```

The SolidJS runtime (`runtime/app-runtime/shadow_runtime_solid.js`) is a custom renderer that builds a **virtual DOM tree** — not a real browser DOM. Each node is a plain object with `tagName`, `attributes`, `listeners`, and `children`. The tree gets serialized to an HTML string + CSS string for Blitz to render.

The build pipeline compiles TSX through Babel with `babel-preset-solid`, then bundles everything with esbuild into a single `bundle.js`.

### Deno

The JavaScript runtime is `shadow-system`, which embeds `deno_core` (not the full Deno CLI — just the V8 engine wrapper). It runs as a subprocess spawned by Blitz.

**Communication protocol:** Line-delimited JSON on stdin/stdout.

```
Blitz → Runtime:  {"op":"render"}
Runtime → Blitz:  {"html":"<main>...</main>", "css":"body {...}"}

Blitz → Runtime:  {"op":"dispatch","event":{"targetId":"counter","type":"click"}}
Runtime → Blitz:  {"html":"<main>...</main>", "css":"body {...}"}
```

**Rust platform APIs** are injected into JavaScript through Deno's extension system. Each extension registers Rust functions as ops and provides a bootstrap JS file that wires them onto `globalThis.Shadow.os`:

```javascript
// rust/runtime-nostr-host/js/bootstrap.js
globalThis.Shadow.os.nostr = {
  listKind1(query) { return core.ops.op_runtime_nostr_list_kind1(query); },
  publishKind1(request) { return core.ops.op_runtime_nostr_publish_kind1(request); },
  syncKind1(request) { return core.ops.op_runtime_nostr_sync_kind1(request); },
};

// rust/runtime-audio-host/js/bootstrap.js
globalThis.Shadow.os.audio = {
  async createPlayer(request) { return core.ops.op_runtime_audio_create_player(request); },
  async play(request) { return core.ops.op_runtime_audio_play(request); },
  async pause(request) { return core.ops.op_runtime_audio_pause(request); },
};
```

On the Rust side, ops are defined with the `#[op2]` macro and packaged into extensions:

```rust
#[op2]
#[serde]
fn op_runtime_nostr_list_kind1(
    state: &mut OpState,
    #[serde] query: ListKind1Query,
) -> Result<Vec<Kind1Event>, JsErrorBox> { ... }
```

Extensions are registered when the runtime starts:

```rust
let mut runtime = JsRuntime::new(RuntimeOptions {
    module_loader: Some(Rc::new(FsModuleLoader)),
    extensions: vec![
        runtime_nostr_host::init_extension(),
        runtime_audio_host::init_extension(),
    ],
    ..Default::default()
});
```

App code calls these APIs through a thin OS wrapper (`runtime/app-runtime/shadow_runtime_os.js`) that either uses the real Rust-backed implementation or falls back to mocks for testing.

### Blitz

Blitz is our rendering engine, forked from DioxusLabs' Blitz. It takes an HTML string and a CSS string and renders them to pixels.

**Rendering backends:**
- `gpu` — wgpu + Vello (GPU-accelerated vector rendering)
- `cpu` — Vello CPU rasterizer (no GPU needed)
- `gpu_softbuffer` — wgpu + softbuffer (software fallback)

Blitz runs as a Wayland client. The compositor gives it a surface, it renders the app's HTML/CSS into that surface every frame. When a user taps or clicks, Blitz captures the event, finds the target element by `data-shadow-id`, and dispatches it to the runtime.

---

## The Compositor

The compositor is the piece that owns the display and manages app windows. Shadow has two compositor variants built on Smithay (a Rust Wayland compositor framework).

### Nested Compositor (`shadow-compositor`)

Used in the QEMU VM and desktop development. Runs inside a Winit window as a nested Wayland compositor.

- Creates a Wayland socket that apps connect to
- Renders app surfaces via OpenGL ES (Smithay's GlesRenderer)
- Renders the shell UI (home screen, app switcher) via a software renderer
- Composites both layers with damage tracking

### Guest Compositor (`shadow-compositor-guest`)

Used on the rooted Pixel. Talks directly to the display hardware.

- Opens `/dev/dri/card0` for DRM/KMS output — `/dev/dri/card0` is the Linux kernel's device file for the first GPU/display controller. DRM (Direct Rendering Manager) and KMS (Kernel Mode Setting) are the Linux kernel subsystems for controlling displays: picking a resolution, allocating framebuffers, and flipping frames onto the screen.
- Creates dumb buffers in XRGB8888 format — a "dumb buffer" is a simple CPU-accessible block of pixel memory allocated through the kernel. XRGB8888 means each pixel is 4 bytes: one byte each for red, green, blue, and an unused padding byte.
- Captures app frames from shared memory or DMA-buf — apps render into buffers and share them with the compositor. Shared memory (SHM) is a simple CPU copy. DMA-buf is a Linux kernel mechanism for sharing GPU memory buffers between processes without copying.
- Composites app + shell onto the DRM framebuffer — paints the app's pixels and the shell UI (home screen, status bar) together into one final image, then tells the kernel to display it.
- Reads touch input from `/dev/input/event*` via evdev — evdev (event device) is the Linux kernel's generic input interface. Every input device (touchscreen, keyboard, mouse) shows up as a file like `/dev/input/event3`. The compositor reads raw touch events from these files.

### Shell & App Management

Both compositors share the same shell model (`ui/crates/shadow-ui-core/src/shell.rs`). The shell provides:

- A home screen showing app cards
- Navigation (arrow keys, tap) to select and launch apps
- App shelving — when you go home, the app's window state is preserved in `shelved_windows`
- A control socket accepting commands: `launch <app_id>`, `home`, `state`

When an app launches, the compositor spawns the Blitz process with environment variables pointing to the Wayland socket, viewport size, and runtime bundle path. The app connects as a Wayland client and gets a surface to render into.

---

## Sensors

Shadow interfaces with hardware at different levels depending on the sensor. Some go through Linux kernel APIs directly, some use Android's native (NDK/Binder) interfaces.

### Display

**Level: Linux DRM/KMS**

The guest compositor opens `/dev/dri/card0` and uses the DRM subsystem directly via the `drm` Rust crate.

- Enumerates connectors, CRTCs, and encoders
- Selects a display mode from the connected panel
- Allocates dumb buffers in XRGB8888
- Presents frames via `set_crtc()` page flips
- Acquires DRM master lock to get exclusive display control

On the Pixel 4a, this works because we stop SurfaceFlinger first — no other process is competing for the display.

The nested compositor skips all of this and just renders into a Winit window.

### Touch

**Level: Linux evdev**

Touch input on the Pixel is read from `/dev/input/event*` devices using the `evdev` crate.

- Scans `/dev/input/` for multitouch-capable devices
- Reads `ABS_MT_SLOT`, `ABS_MT_TRACKING_ID`, `ABS_MT_POSITION_X/Y` events
- Normalizes coordinates to 0.0–1.0 range
- Detects scroll gestures (18px threshold)
- Runs on a dedicated thread, sends events to the compositor via calloop channels

The compositor hit-tests touches against the shell UI and app surfaces, routing events appropriately.

### Sound

**Level: Linux ALSA**

Audio playback goes through ALSA via the `alsa` crate (`rust/shadow-linux-audio-spike/`).

- Discovers playback PCM devices from `/proc/asound/pcm`
- Priority-ranks devices (device 0, 13, 17 preferred on the Pixel 4a's Qualcomm codec)
- Configures hardware parameters: S16 format, stereo, negotiated sample rate
- Sets mixer controls to enable the speaker amplifier on the Pixel 4a:
  - `SEC_TDM_RX_0 Audio Mixer MultiMedia1/5/8`
  - `Main AMP Enable Switch`, `R Main AMP Enable Switch`

The audio spike binary runs as a separate process. The runtime extension (`runtime-audio-host`) manages player instances and delegates to the spike binary for actual playback. Apps use `Shadow.os.audio.createPlayer()`, `.play()`, `.pause()`, etc.

Sources can be tone synthesis (sine wave at configurable frequency) or file decoding (MP3/WAV via the Symphonia codec library).

### Camera

**Level: Android Binder NDK (AIDL)**

Camera is the one sensor where we use Android's native service layer rather than Linux kernel interfaces directly. The implementation lives in `worktrees/camera-rust/`.

**Architecture:**
```
JS app → Shadow.os.camera.captureStill()
  → runtime-camera-host (Deno extension, TCP/JSON client)
    → shadow-camera-provider-host (Android-side, TCP/JSON server)
      → Android Camera HAL via Binder IPC
```

The provider host (`shadow-camera-provider-host`) dynamically loads `libbinder_ndk.so` and talks to the camera service through AIDL interfaces:
- `ICameraProvider` — enumerate cameras
- `ICameraDevice` — open a specific camera
- `ICameraDeviceSession` — configure streams and submit capture requests

It allocates NDK `HardwareBuffer`s for JPEG capture, parses the blob footer to extract the image, and serves results over a TCP socket as JSON with base64-encoded image data.

The runtime extension (`runtime-camera-host`) connects to this socket and exposes two async ops to JavaScript:
- `Shadow.os.camera.listCameras()` — returns camera IDs, labels, and lens facing
- `Shadow.os.camera.captureStill(cameraId?)` — returns JPEG data as a base64 data URL

When the camera endpoint isn't configured, the extension falls back to mock cameras for local development.

### GPU

**Level: wgpu (Vulkan/GL abstraction)**

GPU rendering goes through wgpu, which abstracts over Vulkan, Metal, OpenGL, and DX12.

On the Pixel 4a, we use the **Turnip** driver (Mesa's open-source Vulkan driver for Qualcomm Adreno GPUs). The runtime bundles Mesa and Turnip libraries and sets:
- `WGPU_BACKEND=vulkan`
- `MESA_LOADER_DRIVER_OVERRIDE=kgsl` (use Qualcomm's kernel graphics support layer)
- `TU_DEBUG=noconform` (skip conformance checks)

Multiple GPU profiles are available for testing:
- `gl` — OpenGL via Mesa
- `vulkan_kgsl` — Vulkan via Turnip with KGSL
- `vulkan_kgsl_first` — Vulkan with DRI block-list (bypass DRM, go straight to KGSL)

The compositor's software renderer (`ui/crates/shadow-ui-software/`) handles shell UI rendering (rounded rectangles, text with bitmap fonts) on CPU, while Blitz uses wgpu for the app content.

### Summary Table

| Sensor  | API Layer              | Device/Path              | Rust Crate | Notes |
|---------|------------------------|--------------------------|------------|-------|
| Display | Linux DRM/KMS          | `/dev/dri/card0`         | `drm`      | Direct framebuffer control |
| Touch   | Linux evdev            | `/dev/input/event*`      | `evdev`    | Multitouch, dedicated thread |
| Sound   | Linux ALSA             | `/dev/snd/*`             | `alsa`     | PCM playback + mixer control |
| Camera  | Android Binder NDK     | AIDL service over Binder | `android-binder` | Two-tier broker, TCP/JSON |
| GPU     | Vulkan/GL via wgpu     | GPU device               | `wgpu`     | Turnip for Qualcomm Adreno |

---

## Nix Build Environment

Shadow uses Nix flakes as the build environment for everything: development shells, cross-compilation, and the VM image.

**Disk space:** The default dev shell (`nix develop`) downloads several GiB to the Nix store. Running the QEMU VM (`just run target=vm`) adds the Linux guest image, QEMU dependencies, Mesa/Wayland graphics libraries, and host-staged runtime artifacts. The VM is now an artifact consumer: it does not install Cargo/Rust and does not grow a guest-side compile cache.

### Dev Shells

Three shells serve different parts of the project:

**`bootimg`** (default) — General development and device work:
- cargo, rustc, zig, just, python3, adb, payload-dumper-go
- Used for: building, flashing, deploying to Pixel

**`ui`** — Compositor and rendering development:
- Everything in bootimg plus pkg-config and graphics libraries
- Linux-specific: libdrm, mesa, vulkan-loader, wayland, libxkbcommon
- Used for: `just ui-check`, compositor iteration

**`runtime`** — V8/Deno `shadow-system` work:
- cargo, cmake, deno, gn, ninja, sqlite
- Used for: building `shadow-system`, bundling apps

Enter any shell with `nix develop .#<name>` or use direnv (the `.envrc` calls `use flake` automatically).

### Cross-Compilation

The flake uses nixpkgs' `pkgsCross` to build for different targets from any host:

| Target | Nix Cross Config | Linkage | Purpose |
|--------|-----------------|---------|---------|
| aarch64-linux (musl) | `pkgsCross.aarch64-multiplatform-musl` | Static | Pixel binaries (session, compositor) |
| aarch64-linux (glibc) | `pkgsCross.aarch64-multiplatform` | Dynamic | Pixel runtime host, Blitz GPU |
| x86_64-linux (glibc) | `pkgsCross.gnu64` | Dynamic | Desktop/VM targets |
| x86_64-linux (musl) | `pkgsCross.musl64` | Static | Portable Linux binaries |

Static musl builds produce self-contained binaries that run on the Pixel without any system libraries.

### V8 Pre-built Binaries

Compiling V8 from source is extremely slow, so the flake pins pre-built `rusty_v8` static archives by platform:

```nix
rustyV8ReleaseVersion = "146.8.0";
rustyV8ReleaseShas = {
  "x86_64-linux" = "sha256-deV+...";
  "aarch64-linux" = "sha256-zkzE...";
  "x86_64-darwin" = "sha256-8HbK...";
  "aarch64-darwin" = "sha256-1AXP...";
};
```

These get fetched and pointed to via `RUSTY_V8_ARCHIVE` so cargo skips the V8 build.

### NixOS VM Image

The QEMU VM is a full NixOS system defined in `vm/shadow-ui-vm.nix`. Nix builds the entire guest image — kernel, init, services, user environment — as a reproducible derivation. The `microvm.nix` module configures QEMU hardware (virtio-gpu, USB input, 9P shares) and the guest runs greetd + cage to launch the compositor session automatically.

---

## Iterating On Runtime Apps

The public VM session currently launches registered shell apps: `counter`, `timeline`, `camera`, `podcast`, and `cashu`. For a brand-new app, add it to the runtime artifact metadata and session app list first, then launch it with `just run target=vm app=<id>`.

### 1. Create the app

Make a new directory under `runtime/`:

```
runtime/app-hello/
├── app.tsx
└── assets/       # optional: audio files, images
```

Write your app in `app.tsx`:

```tsx
import { createSignal } from "@shadow/sdk";

export function renderApp() {
  const [name, setName] = createSignal("world");

  return (
    <main style="width:100%;height:100%;display:flex;align-items:center;justify-content:center;background:#1a1a2e">
      <div style="display:flex;flex-direction:column;align-items:center;gap:16px">
        <h1 style="color:white;font-size:32px">Hello, {name()}!</h1>
        <button
          style="padding:12px 24px;background:#e94560;color:white;border:none;font-size:18px"
          onClick={() => setName("Shadow")}
        >
          Tap me
        </button>
      </div>
    </main>
  );
}
```

You have access to all SolidJS primitives: `createSignal`, `createEffect`, `createMemo`, `Show`, `For`, `Switch`/`Match`, etc.

For UI primitives and platform APIs, import from `@shadow/sdk`:

```tsx
import { createSignal } from "@shadow/sdk";                          // Solid primitives
import { listCameras, captureStill } from "@shadow/sdk";             // camera
import { createPlayer, play, pause } from "@shadow/sdk";             // audio
import { listKind1, publishKind1 } from "@shadow/sdk";               // nostr
```

### 2. Run it

```bash
just run target=vm app=counter
```

This handles everything for the supported VM shell apps: prepares runtime bundles, launches the artifact-consumer VM, starts the compositor, and opens the requested app.

### 3. Iterate

Edit an app under `runtime/`, re-run `just run target=vm app=<id>`. That's the loop.

Key checks:
```bash
just pre-commit    # Fast local gate (formatting, tests, compile)
just ui-check      # UI workspace checks
just smoke target=vm # Local VM shell/app smoke used by pre-merge
just pre-merge     # Required branch gate (pre-commit + VM smoke)
sc -t pixel ci     # Rooted-Pixel CI suite runner (`quick|shell|timeline|camera|nostr|sound|audio|podcast|runtime|full`)
```
