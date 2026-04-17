import {
  For,
  Match,
  Show,
  Switch,
  createSignal,
  invalidateRuntimeApp,
  onMount,
} from "@shadow/app-runtime-solid";
import { captureStill, listCameras, logCamera } from "@shadow/app-runtime-os";

type CameraDevice = {
  id: string;
  label: string;
  lensFacing: string;
};

type CaptureReceipt = {
  bytes: number;
  cameraId: string;
  capturedAtMs: number;
  imageDataUrl: string;
  isMock: boolean;
  mimeType: string;
};

type StatusState =
  | { kind: "loading"; message: string }
  | { kind: "ready"; message: string }
  | { kind: "capturing"; message: string }
  | { kind: "error"; message: string };

export const runtimeDocumentCss = `
:root {
  color-scheme: dark;
}

* {
  box-sizing: border-box;
}

html,
body {
  margin: 0;
  min-height: 100%;
}

body {
  min-height: 100vh;
  background:
    radial-gradient(circle at top, rgba(249, 115, 22, 0.18), transparent 28%),
    linear-gradient(180deg, #160f0b 0%, #1f1a16 34%, #0b1018 100%);
  color: #f8fafc;
  font: 500 16px/1.45 "Google Sans", "Roboto", "Droid Sans", "Noto Sans", "DejaVu Sans", sans-serif;
}

#shadow-blitz-root {
  width: 100%;
  height: 100%;
}

.camera-shell {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  gap: 18px;
  padding: 20px 20px 28px;
}

.camera-hero {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 8px 4px 0;
}

.camera-eyebrow {
  margin: 0;
  color: #fdba74;
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
}

.camera-title {
  margin: 0;
  font-size: 54px;
  line-height: 0.94;
  letter-spacing: -0.05em;
  color: #fff7ed;
}

.camera-subtitle {
  margin: 0;
  color: #fed7aa;
  font-size: 22px;
  line-height: 1.32;
}

.camera-panel {
  display: flex;
  flex-direction: column;
  gap: 16px;
  padding: 20px;
  border-radius: 30px;
  background: rgba(15, 23, 42, 0.74);
  border: 1px solid rgba(251, 146, 60, 0.18);
  box-shadow: 0 24px 54px rgba(0, 0, 0, 0.24);
}

.camera-toolbar {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
}

.camera-chip-row {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
}

.camera-chip {
  min-height: 56px;
  border: none;
  border-radius: 999px;
  padding: 14px 18px;
  font: inherit;
  font-size: 20px;
  font-weight: 800;
  letter-spacing: -0.02em;
  background: rgba(148, 163, 184, 0.14);
  color: #e2e8f0;
}

.camera-chip-active {
  background: linear-gradient(135deg, #fdba74 0%, #fb923c 48%, #f97316 100%);
  color: #431407;
}

.camera-status {
  margin: 0;
  padding: 16px 18px;
  border-radius: 24px;
  font-size: 20px;
  line-height: 1.35;
}

.camera-status-loading,
.camera-status-ready,
.camera-status-capturing {
  background: rgba(251, 146, 60, 0.12);
  border: 1px solid rgba(253, 186, 116, 0.16);
  color: #ffedd5;
}

.camera-status-error {
  background: rgba(127, 29, 29, 0.22);
  border: 1px solid rgba(251, 113, 133, 0.16);
  color: #fecdd3;
}

.camera-action {
  width: 100%;
  min-height: 92px;
  border: none;
  border-radius: 999px;
  padding: 18px 24px;
  font: inherit;
  font-size: 36px;
  font-weight: 900;
  letter-spacing: -0.04em;
  background: linear-gradient(135deg, #fdba74 0%, #fb923c 42%, #ea580c 100%);
  color: #431407;
}

.camera-action[disabled] {
  opacity: 0.72;
}

.camera-action-secondary {
  min-height: 68px;
  padding: 16px 22px;
  font-size: 24px;
  background: rgba(251, 146, 60, 0.12);
  border: 1px solid rgba(253, 186, 116, 0.2);
  color: #ffedd5;
}

.camera-preview {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 16px;
  border-radius: 28px;
  background: rgba(2, 6, 23, 0.86);
  border: 1px solid rgba(148, 163, 184, 0.16);
}

.camera-preview-frame {
  width: 100%;
  aspect-ratio: 3 / 4;
  overflow: hidden;
  border-radius: 24px;
  background: #020617;
}

.camera-preview-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.camera-preview-empty {
  width: 100%;
  aspect-ratio: 3 / 4;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 28px;
  border-radius: 24px;
  background:
    radial-gradient(circle at top, rgba(249, 115, 22, 0.18), transparent 28%),
    linear-gradient(180deg, #0f172a 0%, #111827 100%);
  color: #cbd5e1;
  font-size: 22px;
  line-height: 1.4;
  text-align: center;
}

.camera-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 12px 18px;
  color: #cbd5e1;
  font-size: 18px;
}
`;

function timestampLabel(capturedAtMs: number) {
  const date = new Date(capturedAtMs);
  return date.toISOString().replace("T", " ").replace("Z", " UTC");
}

function logCameraMarker(message: string) {
  try {
    logCamera(message);
  } catch {
    // Keep app behavior independent from debug logging.
  }
}

export function renderApp() {
  const [cameras, setCameras] = createSignal<CameraDevice[]>([]);
  const [selectedCameraId, setSelectedCameraId] = createSignal<string | null>(null);
  const [status, setStatus] = createSignal<StatusState>({
    kind: "loading",
    message: "Loading cameras from Shadow OS.",
  });
  const [lastCapture, setLastCapture] = createSignal<CaptureReceipt | null>(null);

  function setStatusState(next: StatusState) {
    setStatus(next);
    invalidateRuntimeApp();
  }

  async function refreshCameras() {
    setStatusState({
      kind: "loading",
      message: "Loading cameras from Shadow OS.",
    });

    try {
      const devices = await listCameras();
      const currentSelection = selectedCameraId();
      const nextSelected = currentSelection != null &&
          devices.some((camera) => camera.id === currentSelection)
        ? currentSelection
        : devices[0]?.id ?? null;
      setCameras(devices);
      setSelectedCameraId(nextSelected);
      setStatusState({
        kind: "ready",
        message: devices.length > 0
          ? `Ready on ${devices[0].label}.`
          : "No cameras reported by Shadow OS.",
      });
    } catch (error) {
      setStatusState({
        kind: "error",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  async function handleCapture() {
    const cameraId = selectedCameraId();
    if (!cameraId) {
      setStatusState({
        kind: "error",
        message: "Pick a camera before taking a photo.",
      });
      return;
    }

    setStatusState({
      kind: "capturing",
      message: "Taking photo through Shadow OS camera service.",
    });
    logCameraMarker(`camera-capture-start cameraId=${cameraId}`);

    try {
      const receipt = await captureStill({ cameraId });
      setLastCapture(receipt);
      logCameraMarker(
        `camera-capture-complete cameraId=${receipt.cameraId} isMock=${receipt.isMock} bytes=${receipt.bytes}`,
      );
      setStatusState({
        kind: "ready",
        message: receipt.isMock
          ? "Captured explicit mock frame."
          : "Photo captured from the live Pixel camera.",
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logCameraMarker(
        `camera-capture-error cameraId=${cameraId} message=${JSON.stringify(message)}`,
      );
      setStatusState({
        kind: "error",
        message,
      });
    }
  }

  onMount(() => {
    void refreshCameras();
  });

  return (
    <main
      class="camera-shell"
      data-shadow-camera-count={String(cameras().length)}
      data-shadow-selected-camera={selectedCameraId() ?? ""}
      data-shadow-status-kind={status().kind}
      data-shadow-last-capture-camera-id={lastCapture()?.cameraId ?? ""}
      data-shadow-last-capture-is-mock={lastCapture() == null ? "" : String(lastCapture()!.isMock)}
      data-shadow-last-capture-bytes={String(lastCapture()?.bytes ?? "")}
      data-shadow-last-capture-mime-type={lastCapture()?.mimeType ?? ""}
    >
      <section class="camera-hero">
        <p class="camera-eyebrow">Shadow Camera</p>
        <h1 class="camera-title">Take Photo</h1>
        <p class="camera-subtitle">
          A tiny TS app driving a platform camera API from the Shadow runtime.
        </p>
      </section>

      <section class="camera-panel">
        <div class="camera-chip-row">
          <For each={cameras()}>
            {(camera, index) => (
              <button
                classList={{
                  "camera-chip": true,
                  "camera-chip-active": selectedCameraId() === camera.id,
                }}
                data-shadow-id={`camera-${index()}`}
                onClick={() => {
                  setSelectedCameraId(camera.id);
                  setStatus({
                    kind: "ready",
                    message: `Ready on ${camera.label}.`,
                  });
                }}
                type="button"
              >
                {camera.label}
              </button>
            )}
          </For>
        </div>

        <p class={`camera-status camera-status-${status().kind}`}>
          {status().message}
        </p>

        <div class="camera-toolbar">
          <button
            class="camera-action"
            data-shadow-id="capture"
            disabled={status().kind === "capturing" || selectedCameraId() == null}
            onClick={() => {
              void handleCapture();
            }}
            type="button"
          >
            {status().kind === "capturing" ? "Capturing..." : "Take Photo"}
          </button>

          <button
            class="camera-action camera-action-secondary"
            data-shadow-id="refresh-cameras"
            disabled={status().kind === "capturing"}
            onClick={() => {
              void refreshCameras();
            }}
            type="button"
          >
            Reload Cameras
          </button>
        </div>

        <section class="camera-preview">
          <Switch>
            <Match when={lastCapture() != null}>
              <div class="camera-preview-frame">
                <img
                  alt="Latest Shadow camera capture"
                  class="camera-preview-image"
                  src={lastCapture()?.imageDataUrl ?? ""}
                />
              </div>
            </Match>
            <Match when={lastCapture() == null}>
              <div class="camera-preview-empty">
                The latest capture will appear here once the app takes a photo.
              </div>
            </Match>
          </Switch>

          <Show when={lastCapture() != null}>
            <div class="camera-meta">
              <span>{lastCapture()?.cameraId}</span>
              <span>{timestampLabel(lastCapture()?.capturedAtMs ?? 0)}</span>
              <span>{lastCapture()?.mimeType}</span>
              <span>{lastCapture()?.bytes} bytes</span>
            </div>
          </Show>
        </section>
      </section>
    </main>
  );
}
