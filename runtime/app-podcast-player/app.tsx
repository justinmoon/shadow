import {
  clearMediaButtonHandler,
  createPlayer,
  createSignal,
  getStatus,
  invalidateRuntimeApp,
  onCleanup,
  pause,
  play,
  release,
  seek,
  setMediaButtonHandler,
  setVolume,
  stop,
} from "@shadow/sdk";

type AudioStatus = {
  backend: string;
  durationMs: number;
  error?: string;
  id: number;
  path?: string;
  positionMs: number;
  url?: string;
  sourceKind: string;
  state: string;
  volume: number;
};

type PlaybackSource = "file" | "url";

type EpisodeConfig = {
  durationMs: number;
  id: string;
  path: string;
  sourceUrl?: string;
  title: string;
};

type RuntimeAppConfig = {
  episodes?: Partial<EpisodeConfig>[];
  playbackSource?: string;
  podcastLicense?: string;
  podcastPageUrl?: string;
  podcastTitle?: string;
};

type CommandKind =
  | "next"
  | "pause"
  | "play_pause"
  | "previous"
  | "refresh"
  | "release"
  | "seek_back"
  | "seek_forward"
  | "stop"
  | "volume_down"
  | "volume_up"
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
  playbackSource: PlaybackSource;
  podcastLicense: string | null;
  podcastPageUrl: string | null;
  podcastTitle: string;
} {
  const runtimeConfig = (globalThis as Record<string, unknown>)
    .SHADOW_RUNTIME_APP_CONFIG as RuntimeAppConfig | undefined;
  const episodes = Array.isArray(runtimeConfig?.episodes) &&
      runtimeConfig.episodes.length > 0
    ? runtimeConfig.episodes.map(normalizeEpisode).filter(
      Boolean,
    ) as EpisodeConfig[]
    : DEFAULT_EPISODES;

  return {
    episodes,
    playbackSource: normalizePlaybackSource(runtimeConfig?.playbackSource),
    podcastLicense: normalizeString(runtimeConfig?.podcastLicense),
    podcastPageUrl: normalizeString(runtimeConfig?.podcastPageUrl),
    podcastTitle: normalizeString(runtimeConfig?.podcastTitle) ??
      "No Solutions",
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

function normalizePlaybackSource(value: unknown): PlaybackSource {
  return value === "url" ? "url" : "file";
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

function formatPosition(positionMs: number) {
  const totalSeconds = Math.max(0, Math.floor(positionMs / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}

function logPodcastStatus(
  command: CommandKind,
  nextStatus: AudioStatus | null,
  episodeId: string | null,
  fallbackSource?: string,
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
    `source=${nextStatus.url ?? nextStatus.path ?? fallbackSource ?? "n/a"}`,
  ];
  console.error(parts.join(" "));
}

function buildEpisodeSource(
  episode: EpisodeConfig,
  playbackSource: PlaybackSource,
) {
  if (playbackSource === "url" && episode.sourceUrl) {
    return {
      durationMs: episode.durationMs,
      kind: "url",
      url: episode.sourceUrl,
    } as const;
  }

  return {
    durationMs: episode.durationMs,
    kind: "file",
    path: episode.path,
  } as const;
}

function episodeSourceLabel(
  episode: EpisodeConfig | null,
  playbackSource: PlaybackSource,
) {
  if (!episode) {
    return "missing";
  }
  if (playbackSource === "url" && episode.sourceUrl) {
    return episode.sourceUrl;
  }
  return episode.path;
}

export default function renderApp() {
  const config = readAppConfig();
  const [status, setStatus] = createSignal<AudioStatus | null>(null);
  const [activeEpisodeId, setActiveEpisodeId] = createSignal<string | null>(
    null,
  );
  const [busy, setBusy] = createSignal<CommandKind | null>(null);
  const [message, setMessage] = createSignal(
    "Pick an episode. The current Pixel backend uses the Linux audio bridge.",
  );
  const [error, setError] = createSignal<string | null>(null);

  function activeEpisode() {
    return config.episodes.find((episode) =>
      episode.id === activeEpisodeId()
    ) ?? null;
  }

  function defaultEpisode() {
    return config.episodes[0] ?? null;
  }

  function adjacentEpisode(step: 1 | -1) {
    if (config.episodes.length === 0) {
      return null;
    }
    const currentIndex = config.episodes.findIndex((episode) =>
      episode.id === activeEpisodeId()
    );
    if (currentIndex === -1) {
      return step > 0
        ? defaultEpisode()
        : config.episodes[config.episodes.length - 1] ?? null;
    }
    const nextIndex = (currentIndex + step + config.episodes.length) %
      config.episodes.length;
    return config.episodes[nextIndex] ?? null;
  }

  function playbackEpisode() {
    return activeEpisode() ?? defaultEpisode();
  }

  function clampSeekPosition(currentStatus: AudioStatus, deltaMs: number) {
    return Math.max(
      0,
      Math.min(
        currentStatus.durationMs,
        Math.round(currentStatus.positionMs + deltaMs),
      ),
    );
  }

  function clampVolume(currentStatus: AudioStatus, delta: number) {
    return Math.max(
      0,
      Math.min(1, Math.round((currentStatus.volume + delta) * 100) / 100),
    );
  }

  async function ensurePlayerForEpisode(
    episode: EpisodeConfig,
    forceCreate = false,
  ) {
    const current = status();
    if (
      !forceCreate && current && current.state !== "released" &&
      activeEpisodeId() === episode.id
    ) {
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
      source: buildEpisodeSource(episode, config.playbackSource),
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
        case "next":
        case "previous": {
          const targetEpisode = episode ??
            adjacentEpisode(command === "next" ? 1 : -1);
          if (!targetEpisode) {
            setMessage("No configured episodes.");
            break;
          }
          nextStatus = await play({
            id: (await ensurePlayerForEpisode(targetEpisode)).id,
          }) as AudioStatus;
          setMessage(
            `${
              command === "next" ? "Next" : "Previous"
            } episode requested: ${targetEpisode.title}.`,
          );
          break;
        }
        case "pause":
          if (!status() || status()!.state === "released") {
            setMessage("No active player yet.");
            break;
          }
          nextStatus = await pause({ id: status()!.id }) as AudioStatus;
          setMessage("Playback paused.");
          break;
        case "play_pause": {
          const currentStatus = status();
          if (currentStatus && currentStatus.state === "playing") {
            nextStatus = await pause({ id: currentStatus.id }) as AudioStatus;
            setMessage("Playback paused.");
            break;
          }
          const targetEpisode = episode ?? playbackEpisode();
          if (!targetEpisode) {
            setMessage("No configured episodes.");
            break;
          }
          nextStatus = await play({
            id: (await ensurePlayerForEpisode(targetEpisode)).id,
          }) as AudioStatus;
          setMessage(`Playback requested for ${targetEpisode.title}.`);
          break;
        }
        case "refresh":
          if (!status() || status()!.state === "released") {
            setMessage("No live player to refresh.");
            break;
          }
          nextStatus = await getStatus({ id: status()!.id }) as AudioStatus;
          setMessage("Player status refreshed.");
          break;
        case "release":
          if (!status() || status()!.state === "released") {
            setMessage("No player to release.");
            break;
          }
          nextStatus = await release({ id: status()!.id }) as AudioStatus;
          setMessage("Player released.");
          break;
        case "seek_back":
        case "seek_forward": {
          const currentStatus = status();
          if (!currentStatus || currentStatus.state === "released") {
            setMessage("No active player yet.");
            break;
          }
          const refreshedStatus = await getStatus({
            id: currentStatus.id,
          }) as AudioStatus;
          const positionMs = clampSeekPosition(
            refreshedStatus,
            command === "seek_forward" ? 30_000 : -30_000,
          );
          nextStatus = await seek({
            id: refreshedStatus.id,
            positionMs,
          }) as AudioStatus;
          setMessage(
            `${
              command === "seek_forward" ? "Skipped forward" : "Skipped back"
            } to ${formatPosition(positionMs)}.`,
          );
          break;
        }
        case "stop":
          if (!status() || status()!.state === "released") {
            setMessage("No active player yet.");
            break;
          }
          nextStatus = await stop({ id: status()!.id }) as AudioStatus;
          setMessage("Playback stopped.");
          break;
        case "volume_down":
        case "volume_up": {
          const currentStatus = status();
          if (!currentStatus || currentStatus.state === "released") {
            setMessage("No active player yet.");
            break;
          }
          const volume = clampVolume(
            currentStatus,
            command === "volume_up" ? 0.1 : -0.1,
          );
          nextStatus = await setVolume({
            id: currentStatus.id,
            volume,
          }) as AudioStatus;
          setMessage(`Player volume set to ${Math.round(volume * 100)}%.`);
          break;
        }
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
          episodeSourceLabel(episode ?? activeEpisode(), config.playbackSource),
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

  setMediaButtonHandler(async ({ action }: { action: string }) => {
    if (busy() !== null) {
      return false;
    }
    switch (action) {
      case "next":
        await runCommand("next");
        return true;
      case "pause":
        await runCommand("pause");
        return true;
      case "play": {
        const episode = playbackEpisode();
        if (episode) {
          await runCommand(`play:${episode.id}`, episode);
          return true;
        }
        return false;
      }
      case "play_pause":
        await runCommand("play_pause");
        return true;
      case "previous":
        await runCommand("previous");
        return true;
      case "volume_down":
        await runCommand("volume_down");
        return true;
      case "volume_up":
        await runCommand("volume_up");
        return true;
      default:
        return false;
    }
  });
  onCleanup(() => {
    clearMediaButtonHandler();
  });

  const activeStatus = () => status();
  const sourcePath = () =>
    activeStatus()?.url ??
      activeStatus()?.path ??
      episodeSourceLabel(activeEpisode(), config.playbackSource);

  return (
    <main class="podcast-shell">
      <section class="podcast-card">
        <p class="podcast-eyebrow">Shadow Audio</p>
        <h1 class="podcast-headline">{config.podcastTitle} player</h1>
        <p class="podcast-body">
          Runtime app sample: configured episodes are played through
          `Shadow.os.audio`, using {config.playbackSource === "url"
            ? "source URLs"
            : "staged local files"}.
        </p>

        <div class="podcast-status">
          <p class="podcast-status-line">
            <span class="podcast-status-label">State:</span>{" "}
            {activeStatus()?.state ?? "missing"}
          </p>
          <p class="podcast-status-line">
            <span class="podcast-status-label">Backend:</span>{" "}
            {activeStatus()?.backend ?? "missing"}
          </p>
          <p class="podcast-status-line">
            <span class="podcast-status-label">Current:</span>{" "}
            {activeEpisode()?.title ?? "none"}
          </p>
          <p class="podcast-status-line">
            <span class="podcast-status-label">Position:</span>{" "}
            {formatPosition(activeStatus()?.positionMs ?? 0)} /{" "}
            {formatDuration(activeStatus()?.durationMs ?? 0)}
          </p>
          <p class="podcast-status-line">
            <span class="podcast-status-label">Volume:</span>{" "}
            {Math.round((activeStatus()?.volume ?? 1) * 100)}%
          </p>
          <p class="podcast-status-line">
            <span class="podcast-status-label">Source:</span> {sourcePath()}
          </p>
        </div>

        <div class="podcast-controls">
          <button
            class="podcast-button podcast-button-secondary"
            data-shadow-id="previous"
            disabled={busy() !== null}
            onClick={() => void runCommand("previous")}
          >
            Previous
          </button>
          <button
            class="podcast-button podcast-button-primary"
            data-shadow-id="play-pause"
            disabled={busy() !== null}
            onClick={() => void runCommand("play_pause")}
          >
            {activeStatus()?.state === "playing"
              ? "Pause Track"
              : "Play / Pause"}
          </button>
          <button
            class="podcast-button podcast-button-secondary"
            data-shadow-id="next"
            disabled={busy() !== null}
            onClick={() => void runCommand("next")}
          >
            Next
          </button>
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
            class="podcast-button podcast-button-secondary"
            data-shadow-id="seek-back"
            disabled={busy() !== null}
            onClick={() => void runCommand("seek_back")}
          >
            Back 30s
          </button>
          <button
            class="podcast-button podcast-button-secondary"
            data-shadow-id="seek-forward"
            disabled={busy() !== null}
            onClick={() => void runCommand("seek_forward")}
          >
            Fwd 30s
          </button>
          <button
            class="podcast-button podcast-button-secondary"
            data-shadow-id="volume-down"
            disabled={busy() !== null}
            onClick={() => void runCommand("volume_down")}
          >
            Vol -
          </button>
          <button
            class="podcast-button podcast-button-secondary"
            data-shadow-id="volume-up"
            disabled={busy() !== null}
            onClick={() => void runCommand("volume_up")}
          >
            Vol +
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
                activeEpisodeId() === episode.id
                  ? " podcast-episode-active"
                  : ""
              }`}
            >
              <div class="podcast-episode-top">
                <h2 class="podcast-episode-title">{episode.title}</h2>
                <p class="podcast-episode-meta">
                  {formatDuration(episode.durationMs)}
                </p>
              </div>
              <p class="podcast-episode-source">
                {episodeSourceLabel(episode, config.playbackSource)}
              </p>
              <button
                class="podcast-button podcast-button-primary"
                data-shadow-id={`play-${episode.id}`}
                disabled={busy() !== null}
                onClick={() => void runCommand(`play:${episode.id}`, episode)}
              >
                {busy() === `play:${episode.id}`
                  ? "Playing..."
                  : `Play #${episode.id}`}
              </button>
            </article>
          ))}
        </div>

        <p class={`podcast-message${error() ? " podcast-message-error" : ""}`}>
          {error() ?? message()}
        </p>

        <div class="podcast-chips">
          <span class="podcast-chip">
            {config.episodes.length} configured episodes
          </span>
          <span class="podcast-chip">
            {config.playbackSource === "url"
              ? "URL playback"
              : "local file playback"}
          </span>
          {config.podcastLicense
            ? <span class="podcast-chip">{config.podcastLicense}</span>
            : null}
          {config.podcastPageUrl
            ? <span class="podcast-chip">{config.podcastPageUrl}</span>
            : null}
        </div>
      </section>
    </main>
  );
}
