import {
  createPlayer,
  createSignal,
  getStatus,
  invalidateRuntimeApp,
  pause,
  play,
  release,
  seek,
  setVolume,
  stop,
} from "@shadow/sdk";

type AudioStatus = {
  backend: string;
  durationMs: number;
  error?: string;
  frequencyHz?: number;
  id: number;
  path?: string;
  positionMs: number;
  url?: string;
  sourceKind: string;
  state: string;
  volume: number;
};

type ToneSourceConfig = {
  kind: "tone";
  durationMs: number;
  frequencyHz: number;
};

type FileSourceConfig = {
  kind: "file";
  durationMs: number;
  path: string;
};

type UrlSourceConfig = {
  kind: "url";
  durationMs: number;
  url: string;
};

type AudioSourceConfig = ToneSourceConfig | FileSourceConfig | UrlSourceConfig;

type RuntimeAppConfig = {
  source?: Partial<ToneSourceConfig & FileSourceConfig & UrlSourceConfig> & {
    kind?: string;
  };
};

type CommandKind =
  | "prepare"
  | "play"
  | "pause"
  | "stop"
  | "refresh"
  | "release"
  | "seek_forward"
  | "volume_down";

const DEFAULT_SOURCE = {
  kind: "tone",
  durationMs: 2_600,
  frequencyHz: 440,
} satisfies ToneSourceConfig;

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
    radial-gradient(circle at top left, rgba(249, 115, 22, 0.24), transparent 28%),
    radial-gradient(circle at top right, rgba(250, 204, 21, 0.18), transparent 32%),
    linear-gradient(180deg, #140b05 0%, #2f1504 42%, #120902 100%);
  color: #fff8ee;
  font: 500 16px/1.45 "Google Sans", "Roboto", "Droid Sans", "Noto Sans", "DejaVu Sans", sans-serif;
}

#shadow-blitz-root {
  min-height: 100vh;
}

.sound-shell {
  min-height: 100vh;
  display: flex;
  padding: 24px;
}

.sound-card {
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 18px;
  padding: 30px 24px 28px;
  border-radius: 34px;
  background: rgba(20, 12, 5, 0.84);
  border: 1px solid rgba(251, 191, 36, 0.2);
  box-shadow: 0 24px 72px rgba(0, 0, 0, 0.32);
}

.sound-eyebrow {
  margin: 0;
  color: #fdba74;
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.16em;
  text-transform: uppercase;
}

.sound-headline {
  margin: 0;
  font-size: 58px;
  line-height: 0.94;
  letter-spacing: -0.05em;
}

.sound-body {
  margin: 0;
  color: #fed7aa;
  font-size: 24px;
  line-height: 1.34;
}

.sound-status {
  display: grid;
  gap: 12px;
  padding: 18px 20px;
  border-radius: 26px;
  background: rgba(68, 30, 10, 0.84);
  border: 1px solid rgba(251, 191, 36, 0.18);
}

.sound-status-line {
  margin: 0;
  font-size: 21px;
  line-height: 1.35;
}

.sound-status-label {
  color: #fdba74;
  font-weight: 700;
}

.sound-actions {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 14px;
}

.sound-button {
  min-height: 84px;
  border: none;
  border-radius: 999px;
  padding: 18px 22px;
  font: inherit;
  font-size: 30px;
  font-weight: 800;
  letter-spacing: -0.03em;
}

.sound-button-primary {
  background: linear-gradient(135deg, #fcd34d 0%, #fb923c 100%);
  color: #431407;
}

.sound-button-secondary {
  background: rgba(251, 191, 36, 0.14);
  border: 1px solid rgba(253, 186, 116, 0.22);
  color: #ffedd5;
}

.sound-button-danger {
  background: linear-gradient(135deg, #fb7185 0%, #ef4444 100%);
  color: #fff1f2;
}

.sound-button[disabled] {
  opacity: 0.66;
}

.sound-message {
  margin: 0;
  padding: 16px 18px;
  border-radius: 22px;
  background: rgba(255, 247, 237, 0.08);
  color: #ffedd5;
  font-size: 20px;
  line-height: 1.35;
}

.sound-message-error {
  background: rgba(127, 29, 29, 0.28);
  color: #fecaca;
}

.sound-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
}

.sound-chip {
  padding: 12px 16px;
  border-radius: 999px;
  background: rgba(249, 115, 22, 0.16);
  color: #fdba74;
  font-size: 18px;
  font-weight: 700;
}
`;

function readAppSourceConfig(): AudioSourceConfig {
  const runtimeConfig = (globalThis as Record<string, unknown>)
    .SHADOW_RUNTIME_APP_CONFIG as RuntimeAppConfig | undefined;
  const source = runtimeConfig?.source;
  if (
    source?.kind === "url" && typeof source.url === "string" &&
    source.url.trim()
  ) {
    return {
      durationMs: normalizeDurationMs(source.durationMs),
      kind: "url",
      url: source.url.trim(),
    };
  }
  if (
    source?.kind === "file" && typeof source.path === "string" &&
    source.path.trim()
  ) {
    return {
      durationMs: normalizeDurationMs(source.durationMs),
      kind: "file",
      path: source.path.trim(),
    };
  }

  return {
    durationMs: normalizeDurationMs(source?.durationMs),
    frequencyHz: normalizeFrequencyHz(source?.frequencyHz),
    kind: "tone",
  };
}

function normalizeDurationMs(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.round(value)
    : DEFAULT_SOURCE.durationMs;
}

function normalizeFrequencyHz(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.round(value)
    : DEFAULT_SOURCE.frequencyHz;
}

function isFileSource(
  source: AudioSourceConfig | AudioStatus,
): source is FileSourceConfig | AudioStatus {
  return "sourceKind" in source
    ? source.sourceKind === "file"
    : source.kind === "file";
}

function isUrlSource(
  source: AudioSourceConfig | AudioStatus,
): source is UrlSourceConfig | AudioStatus {
  return "sourceKind" in source
    ? source.sourceKind === "url"
    : source.kind === "url";
}

function formatSourceLabel(source: AudioSourceConfig | AudioStatus): string {
  if (isFileSource(source)) {
    return source.path ?? "missing-path";
  }
  if (isUrlSource(source)) {
    return source.url ?? "missing-url";
  }
  return `${
    source.frequencyHz ?? DEFAULT_SOURCE.frequencyHz
  } Hz / ${source.durationMs} ms`;
}

function logAudioStatus(command: CommandKind, nextStatus: AudioStatus | null) {
  if (!nextStatus) {
    return;
  }
  const parts = [
    "[shadow-runtime-audio-smoke]",
    `command=${command}`,
    `state=${nextStatus.state}`,
    `backend=${nextStatus.backend}`,
    `source_kind=${nextStatus.sourceKind}`,
    `source=${nextStatus.url ?? nextStatus.path ?? "n/a"}`,
  ];
  console.error(parts.join(" "));
}

export default function renderApp() {
  const appSource = readAppSourceConfig();
  const [status, setStatus] = createSignal<AudioStatus | null>(null);
  const [busy, setBusy] = createSignal<CommandKind | null>(null);
  const [message, setMessage] = createSignal(
    "Prepare a player or tap Play to create one on demand.",
  );
  const [error, setError] = createSignal<string | null>(null);

  async function ensurePlayer(forceCreate = false) {
    const current = status();
    if (!forceCreate && current && current.state !== "released") {
      return current;
    }

    const created = await createPlayer({
      source: appSource,
    }) as AudioStatus;
    setStatus(created);
    return created;
  }

  async function runCommand(command: CommandKind) {
    setBusy(command);
    setError(null);

    try {
      let nextStatus = status();

      switch (command) {
        case "prepare":
          nextStatus = await ensurePlayer(true);
          setMessage(
            appSource.kind === "file"
              ? "Player ready. Play should trigger the staged file-backed helper."
              : appSource.kind === "url"
              ? "Player ready. Play should trigger the URL-backed Linux helper path."
              : "Player ready. On Pixel, Play should trigger the Linux tone helper.",
          );
          break;
        case "play":
          nextStatus = await play({
            id: (await ensurePlayer()).id,
          }) as AudioStatus;
          setMessage("Playback requested.");
          break;
        case "pause":
          if (!status()) {
            nextStatus = await ensurePlayer(true);
            setMessage("Player prepared.");
            break;
          }
          nextStatus = await pause({ id: status()!.id }) as AudioStatus;
          setMessage("Playback paused.");
          break;
        case "stop":
          if (!status()) {
            nextStatus = await ensurePlayer(true);
            setMessage("Player prepared.");
            break;
          }
          nextStatus = await stop({ id: status()!.id }) as AudioStatus;
          setMessage("Playback stopped.");
          break;
        case "refresh":
          if (status() && status()!.state !== "released") {
            nextStatus = await getStatus({ id: status()!.id }) as AudioStatus;
            setMessage("Player status refreshed.");
          } else {
            setMessage("No live player to refresh.");
          }
          break;
        case "release":
          if (!status()) {
            setMessage("No player to release.");
            break;
          }
          nextStatus = await release({ id: status()!.id }) as AudioStatus;
          setMessage(
            "Player released. Play or Prepare will create a fresh one.",
          );
          break;
        case "seek_forward": {
          const current = status();
          if (!current || current.state === "released") {
            setMessage("No active player to seek.");
            break;
          }
          const refreshed = await getStatus({ id: current.id }) as AudioStatus;
          nextStatus = await seek({
            id: refreshed.id,
            positionMs: Math.min(
              refreshed.durationMs,
              refreshed.positionMs + 1_000,
            ),
          }) as AudioStatus;
          setMessage("Seeked forward by one second.");
          break;
        }
        case "volume_down": {
          const current = status();
          if (!current || current.state === "released") {
            setMessage("No active player to adjust.");
            break;
          }
          nextStatus = await setVolume({
            id: current.id,
            volume: Math.max(0, Math.round((current.volume - 0.6) * 10) / 10),
          }) as AudioStatus;
          setMessage("Player volume reduced.");
          break;
        }
      }

      if (nextStatus) {
        setStatus(nextStatus);
        logAudioStatus(command, nextStatus);
      }
    } catch (nextError) {
      const nextMessage = nextError instanceof Error
        ? nextError.message
        : String(nextError);
      setError(nextMessage);
      setMessage("Audio command failed.");
      console.error(
        `[shadow-runtime-audio-smoke] command=${command} error=${
          JSON.stringify(nextMessage)
        }`,
      );
    } finally {
      setBusy(null);
      invalidateRuntimeApp();
    }
  }

  const currentStatus = () => status();
  const busyCommand = () => busy();
  const statusValue = () => currentStatus()?.state ?? "missing";
  const backendValue = () => currentStatus()?.backend ?? "missing";
  const playerIdValue = () => currentStatus()?.id ?? "n/a";
  const positionValue = () => `${currentStatus()?.positionMs ?? 0} ms`;
  const sourceLabel = () => formatSourceLabel(currentStatus() ?? appSource);
  const sourceKindLabel = () => currentStatus()?.sourceKind ?? appSource.kind;
  const volumeValue = () =>
    `${Math.round((currentStatus()?.volume ?? 1) * 100)}%`;

  return (
    <main class="sound-shell">
      <section class="sound-card">
        <p class="sound-eyebrow">Shadow Audio</p>
        <h1 class="sound-headline">Linux audio seam</h1>
        <p class="sound-body">
          Runtime app buttons drive `Shadow.os.audio`. Host uses an in-memory
          backend; the Pixel sound lane switches to the rooted Linux{" "}
          {appSource.kind === "file"
            ? "file"
            : appSource.kind === "url"
            ? "URL"
            : "tone"} helper.
        </p>

        <div class="sound-status">
          <p class="sound-status-line">
            <span class="sound-status-label">State:</span> {statusValue()}
          </p>
          <p class="sound-status-line">
            <span class="sound-status-label">Backend:</span> {backendValue()}
          </p>
          <p class="sound-status-line">
            <span class="sound-status-label">Player:</span> {playerIdValue()}
          </p>
          <p class="sound-status-line">
            <span class="sound-status-label">Position:</span> {positionValue()}
          </p>
          <p class="sound-status-line">
            <span class="sound-status-label">Volume:</span> {volumeValue()}
          </p>
          <p class="sound-status-line">
            <span class="sound-status-label">Source:</span> {sourceKindLabel()}
            {" "}
            / {sourceLabel()}
          </p>
        </div>

        <div class="sound-actions">
          <button
            class="sound-button sound-button-primary"
            data-shadow-id="play"
            disabled={busyCommand() !== null}
            onClick={() => void runCommand("play")}
          >
            {busyCommand() === "play" ? "Playing..." : "Play"}
          </button>
          <button
            class="sound-button sound-button-secondary"
            data-shadow-id="pause"
            disabled={busyCommand() !== null}
            onClick={() => void runCommand("pause")}
          >
            Pause
          </button>
          <button
            class="sound-button sound-button-secondary"
            data-shadow-id="stop"
            disabled={busyCommand() !== null}
            onClick={() => void runCommand("stop")}
          >
            Stop
          </button>
          <button
            class="sound-button sound-button-secondary"
            data-shadow-id="refresh"
            disabled={busyCommand() !== null}
            onClick={() => void runCommand("refresh")}
          >
            Refresh
          </button>
          <button
            class="sound-button sound-button-secondary"
            data-shadow-id="prepare"
            disabled={busyCommand() !== null}
            onClick={() => void runCommand("prepare")}
          >
            Prepare
          </button>
          <button
            class="sound-button sound-button-secondary"
            data-shadow-id="seek-forward"
            disabled={busyCommand() !== null}
            onClick={() => void runCommand("seek_forward")}
          >
            Seek +1s
          </button>
          <button
            class="sound-button sound-button-secondary"
            data-shadow-id="volume-down"
            disabled={busyCommand() !== null}
            onClick={() => void runCommand("volume_down")}
          >
            Volume 40%
          </button>
          <button
            class="sound-button sound-button-danger"
            data-shadow-id="release"
            disabled={busyCommand() !== null}
            onClick={() => void runCommand("release")}
          >
            Release
          </button>
        </div>

        <p class={`sound-message${error() ? " sound-message-error" : ""}`}>
          {error() ?? message()}
        </p>

        <div class="sound-meta">
          <span class="sound-chip">
            {appSource.kind === "file"
              ? "file-backed demo"
              : appSource.kind === "url"
              ? "URL-backed demo"
              : "tone-backed MVP"}
          </span>
          <span class="sound-chip">pause via signal</span>
          <span class="sound-chip">
            {appSource.kind === "file"
              ? "bundle-relative path"
              : appSource.kind === "url"
              ? "URL env handoff"
              : "MP3/file path next"}
          </span>
        </div>
      </section>
    </main>
  );
}
