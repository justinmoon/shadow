import { createSignal, invalidateRuntimeApp } from "@shadow/app-runtime-solid";
import {
  createPlayer,
  getStatus,
  pause,
  play,
  release,
  stop,
} from "@shadow/app-runtime-os";

type AudioStatus = {
  backend: string;
  durationMs: number;
  error?: string;
  id: number;
  path?: string;
  sourceKind: string;
  state: string;
};

type EpisodeConfig = {
  durationMs: number;
  id: string;
  path: string;
  sourceUrl?: string;
  title: string;
};

type RuntimeAppConfig = {
  episodes?: Partial<EpisodeConfig>[];
  podcastLicense?: string;
  podcastPageUrl?: string;
  podcastTitle?: string;
};

type CommandKind =
  | "pause"
  | "refresh"
  | "release"
  | "stop"
  | `play:${string}`;

const DEFAULT_EPISODES: EpisodeConfig[] = [
  {
    durationMs: 2_290_00,
    id: "00",
    path: "assets/podcast/00-test-recording-teaser-w-pablo.mp3",
    title: "#00: Test Recording / Teaser w/ Pablo",
  },
];

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
    radial-gradient(circle at top left, rgba(56, 189, 248, 0.22), transparent 28%),
    radial-gradient(circle at bottom right, rgba(249, 115, 22, 0.24), transparent 36%),
    linear-gradient(180deg, #07111b 0%, #102033 42%, #050b12 100%);
  color: #e0f2fe;
  font: 500 16px/1.45 "Google Sans", "Roboto", "Droid Sans", "Noto Sans", "DejaVu Sans", sans-serif;
}

#shadow-blitz-root {
  width: 100%;
  height: 100%;
}

.podcast-shell {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  overflow-y: auto;
  padding: 22px;
}

.podcast-card {
  display: flex;
  min-height: calc(100% - 44px);
  flex-direction: column;
  gap: 18px;
  border: 1px solid rgba(56, 189, 248, 0.16);
  border-radius: 32px;
  padding: 28px 24px 24px;
  background: rgba(7, 18, 30, 0.9);
  box-shadow: 0 24px 72px rgba(0, 0, 0, 0.34);
}

.podcast-eyebrow {
  margin: 0;
  color: #7dd3fc;
  font-size: 13px;
  font-weight: 800;
  letter-spacing: 0.18em;
  text-transform: uppercase;
}

.podcast-headline {
  margin: 0;
  color: #f8fafc;
  font-size: 52px;
  line-height: 0.94;
  letter-spacing: -0.05em;
}

.podcast-body {
  margin: 0;
  color: #bae6fd;
  font-size: 22px;
  line-height: 1.34;
}

.podcast-status {
  display: grid;
  gap: 10px;
  border: 1px solid rgba(125, 211, 252, 0.12);
  border-radius: 24px;
  padding: 18px 20px;
  background: rgba(8, 24, 41, 0.92);
}

.podcast-status-line {
  margin: 0;
  font-size: 19px;
}

.podcast-status-label {
  color: #7dd3fc;
  font-weight: 800;
}

.podcast-controls {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 12px;
}

.podcast-button {
  min-height: 78px;
  border: none;
  border-radius: 999px;
  padding: 14px 18px;
  color: #f8fafc;
  font: inherit;
  font-size: 24px;
  font-weight: 800;
  letter-spacing: -0.03em;
}

.podcast-button-primary {
  background: linear-gradient(135deg, #38bdf8 0%, #0ea5e9 100%);
  color: #082f49;
}

.podcast-button-secondary {
  border: 1px solid rgba(125, 211, 252, 0.18);
  background: rgba(14, 116, 144, 0.24);
}

.podcast-button-danger {
  background: linear-gradient(135deg, #fb7185 0%, #ef4444 100%);
}

.podcast-button[disabled] {
  opacity: 0.66;
}

.podcast-list {
  display: grid;
  gap: 12px;
}

.podcast-episode {
  display: grid;
  gap: 12px;
  border: 1px solid rgba(125, 211, 252, 0.12);
  border-radius: 24px;
  padding: 16px 18px;
  background: rgba(15, 23, 42, 0.82);
}

.podcast-episode-active {
  border-color: rgba(56, 189, 248, 0.42);
  background: rgba(12, 74, 110, 0.28);
}

.podcast-episode-top {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  align-items: baseline;
}

.podcast-episode-title {
  margin: 0;
  color: #f8fafc;
  font-size: 24px;
  line-height: 1.2;
}

.podcast-episode-meta {
  margin: 0;
  color: #7dd3fc;
  font-size: 17px;
  font-weight: 700;
}

.podcast-episode-source {
  margin: 0;
  color: #93c5fd;
  font-size: 15px;
  line-height: 1.3;
}

.podcast-message {
  margin: 0;
  padding: 16px 18px;
  border-radius: 22px;
  background: rgba(56, 189, 248, 0.08);
  color: #e0f2fe;
  font-size: 18px;
}

.podcast-message-error {
  background: rgba(127, 29, 29, 0.28);
  color: #fecaca;
}

.podcast-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
}

.podcast-chip {
  padding: 10px 14px;
  border-radius: 999px;
  background: rgba(14, 165, 233, 0.16);
  color: #7dd3fc;
  font-size: 16px;
  font-weight: 800;
}
`;

function readAppConfig(): {
  episodes: EpisodeConfig[];
  podcastLicense: string | null;
  podcastPageUrl: string | null;
  podcastTitle: string;
} {
  const runtimeConfig = (globalThis as Record<string, unknown>)
    .SHADOW_RUNTIME_APP_CONFIG as RuntimeAppConfig | undefined;
  const episodes = Array.isArray(runtimeConfig?.episodes) &&
      runtimeConfig.episodes.length > 0
    ? runtimeConfig.episodes.map(normalizeEpisode).filter(Boolean) as EpisodeConfig[]
    : DEFAULT_EPISODES;

  return {
    episodes,
    podcastLicense: normalizeString(runtimeConfig?.podcastLicense),
    podcastPageUrl: normalizeString(runtimeConfig?.podcastPageUrl),
    podcastTitle: normalizeString(runtimeConfig?.podcastTitle) ?? "No Solutions",
  };
}

function normalizeEpisode(value: Partial<EpisodeConfig> | null | undefined) {
  const id = normalizeString(value?.id);
  const path = normalizeString(value?.path);
  const title = normalizeString(value?.title);
  if (!id || !path || !title) {
    return null;
  }

  return {
    durationMs: normalizeDurationMs(value?.durationMs),
    id,
    path,
    sourceUrl: normalizeString(value?.sourceUrl) ?? undefined,
    title,
  } satisfies EpisodeConfig;
}

function normalizeDurationMs(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.round(value)
    : 60_000;
}

function normalizeString(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function formatDuration(durationMs: number) {
  const totalSeconds = Math.max(1, Math.round(durationMs / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}

function logPodcastStatus(
  command: CommandKind,
  nextStatus: AudioStatus | null,
  episodeId: string | null,
  fallbackPath?: string,
) {
  if (!nextStatus) {
    return;
  }
  const normalizedCommand = command.startsWith("play:") ? "play" : command;
  const parts = [
    "[shadow-runtime-podcast-player]",
    `command=${normalizedCommand}`,
    `episode=${episodeId ?? "none"}`,
    `state=${nextStatus.state}`,
    `backend=${nextStatus.backend}`,
    `path=${nextStatus.path ?? fallbackPath ?? "n/a"}`,
  ];
  console.error(parts.join(" "));
}

export default function renderApp() {
  const config = readAppConfig();
  const [status, setStatus] = createSignal<AudioStatus | null>(null);
  const [activeEpisodeId, setActiveEpisodeId] = createSignal<string | null>(null);
  const [busy, setBusy] = createSignal<CommandKind | null>(null);
  const [message, setMessage] = createSignal(
    "Pick an episode. The current Pixel backend uses the Linux audio spike.",
  );
  const [error, setError] = createSignal<string | null>(null);

  function activeEpisode() {
    return config.episodes.find((episode) => episode.id === activeEpisodeId()) ?? null;
  }

  async function ensurePlayerForEpisode(episode: EpisodeConfig, forceCreate = false) {
    const current = status();
    if (!forceCreate && current && current.state !== "released" &&
      activeEpisodeId() === episode.id) {
      return current;
    }

    if (current && current.state !== "released") {
      try {
        await release({ id: current.id });
      } catch {
        // Ignore stale-player cleanup errors; the next createPlayer call will surface real failures.
      }
    }

    const created = await createPlayer({
      source: {
        durationMs: episode.durationMs,
        kind: "file",
        path: episode.path,
      },
    }) as AudioStatus;
    setStatus(created);
    setActiveEpisodeId(episode.id);
    return created;
  }

  async function runCommand(command: CommandKind, episode?: EpisodeConfig) {
    setBusy(command);
    setError(null);

    try {
      let nextStatus = status();
      switch (command) {
        case "pause":
          if (!status()) {
            setMessage("No active player yet.");
            break;
          }
          nextStatus = await pause({ id: status()!.id }) as AudioStatus;
          setMessage("Playback paused.");
          break;
        case "refresh":
          if (!status() || status()!.state === "released") {
            setMessage("No live player to refresh.");
            break;
          }
          nextStatus = await getStatus({ id: status()!.id }) as AudioStatus;
          setMessage("Player status refreshed.");
          break;
        case "release":
          if (!status()) {
            setMessage("No player to release.");
            break;
          }
          nextStatus = await release({ id: status()!.id }) as AudioStatus;
          setMessage("Player released.");
          break;
        case "stop":
          if (!status()) {
            setMessage("No active player yet.");
            break;
          }
          nextStatus = await stop({ id: status()!.id }) as AudioStatus;
          setMessage("Playback stopped.");
          break;
        default:
          if (!episode) {
            throw new Error("podcast play command requires an episode");
          }
          nextStatus = await play({
            id: (await ensurePlayerForEpisode(episode)).id,
          }) as AudioStatus;
          setMessage(`Playback requested for ${episode.title}.`);
          break;
      }

      if (nextStatus) {
        setStatus(nextStatus);
        logPodcastStatus(
          command,
          nextStatus,
          activeEpisodeId() ?? episode?.id ?? null,
          episode?.path,
        );
      }
    } catch (nextError) {
      const nextMessage = nextError instanceof Error
        ? nextError.message
        : String(nextError);
      setError(nextMessage);
      setMessage("Podcast command failed.");
      const normalizedCommand = command.startsWith("play:") ? "play" : command;
      console.error(
        `[shadow-runtime-podcast-player] command=${normalizedCommand} error=${
          JSON.stringify(nextMessage)
        }`,
      );
    } finally {
      setBusy(null);
      invalidateRuntimeApp();
    }
  }

  const activeStatus = () => status();
  const sourcePath = () => activeStatus()?.path ?? activeEpisode()?.path ?? "missing";

  return (
    <main class="podcast-shell">
      <section class="podcast-card">
        <p class="podcast-eyebrow">Shadow Audio</p>
        <h1 class="podcast-headline">{config.podcastTitle} player</h1>
        <p class="podcast-body">
          Runtime app sample: configured episodes are staged as local files and
          played through `Shadow.os.audio`.
        </p>

        <div class="podcast-status">
          <p class="podcast-status-line">
            <span class="podcast-status-label">State:</span> {activeStatus()?.state ?? "missing"}
          </p>
          <p class="podcast-status-line">
            <span class="podcast-status-label">Backend:</span> {activeStatus()?.backend ?? "missing"}
          </p>
          <p class="podcast-status-line">
            <span class="podcast-status-label">Current:</span> {activeEpisode()?.title ?? "none"}
          </p>
          <p class="podcast-status-line">
            <span class="podcast-status-label">Source:</span> {sourcePath()}
          </p>
        </div>

        <div class="podcast-controls">
          <button
            class="podcast-button podcast-button-secondary"
            data-shadow-id="pause"
            disabled={busy() !== null}
            onClick={() => void runCommand("pause")}
          >
            Pause
          </button>
          <button
            class="podcast-button podcast-button-secondary"
            data-shadow-id="stop"
            disabled={busy() !== null}
            onClick={() => void runCommand("stop")}
          >
            Stop
          </button>
          <button
            class="podcast-button podcast-button-secondary"
            data-shadow-id="refresh"
            disabled={busy() !== null}
            onClick={() => void runCommand("refresh")}
          >
            Refresh
          </button>
          <button
            class="podcast-button podcast-button-danger"
            data-shadow-id="release"
            disabled={busy() !== null}
            onClick={() => void runCommand("release")}
          >
            Release
          </button>
        </div>

        <div class="podcast-list">
          {config.episodes.map((episode) => (
            <article
              class={`podcast-episode${
                activeEpisodeId() === episode.id ? " podcast-episode-active" : ""
              }`}
            >
              <div class="podcast-episode-top">
                <h2 class="podcast-episode-title">{episode.title}</h2>
                <p class="podcast-episode-meta">{formatDuration(episode.durationMs)}</p>
              </div>
              <p class="podcast-episode-source">{episode.path}</p>
              <button
                class="podcast-button podcast-button-primary"
                data-shadow-id={`play-${episode.id}`}
                disabled={busy() !== null}
                onClick={() => void runCommand(`play:${episode.id}`, episode)}
              >
                {busy() === `play:${episode.id}` ? "Playing..." : `Play #${episode.id}`}
              </button>
            </article>
          ))}
        </div>

        <p class={`podcast-message${error() ? " podcast-message-error" : ""}`}>
          {error() ?? message()}
        </p>

        <div class="podcast-chips">
          <span class="podcast-chip">{config.episodes.length} configured episodes</span>
          <span class="podcast-chip">local file playback</span>
          {config.podcastLicense ? <span class="podcast-chip">{config.podcastLicense}</span> : null}
          {config.podcastPageUrl ? <span class="podcast-chip">{config.podcastPageUrl}</span> : null}
        </div>
      </section>
    </main>
  );
}
