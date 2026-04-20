import {
  createSignal,
  For,
  invalidateRuntimeApp,
  onMount,
  queryNostr,
  Show,
  syncNostr,
} from "@shadow/sdk";
import type { NostrEvent, NostrSyncReceipt } from "@shadow/sdk/nostr";

type TimelineConfig = {
  limit?: number;
  relayUrls?: string[];
  syncOnStart?: boolean;
};

type StatusState =
  | { kind: "idle"; message: string }
  | { kind: "syncing"; message: string }
  | { kind: "ready"; message: string }
  | { kind: "error"; message: string };

type FeedSource = "cached" | "empty";

const DEFAULT_RELAY_URLS = ["wss://relay.primal.net/", "wss://relay.damus.io/"];
const DEFAULT_LIMIT = 12;
const SHELL_STYLE =
  'width:100%;height:100%;display:flex;flex-direction:column;align-items:stretch;overflow-y:auto;padding:24px 24px 40px;gap:20px;background:radial-gradient(circle at top, rgba(56, 189, 248, 0.16), transparent 36%),linear-gradient(180deg, #020617 0%, #082032 45%, #0f172a 100%);color:#e2e8f0;font:500 16px/1.45 "Google Sans","Roboto","Droid Sans","Noto Sans","DejaVu Sans",sans-serif;box-sizing:border-box';
const HERO_STYLE =
  "width:100%;display:flex;flex-direction:column;gap:18px;padding:6px 4px 4px";
const EYEBROW_STYLE =
  "margin:0;color:#7dd3fc;font-size:13px;font-weight:700;letter-spacing:0.14em;text-transform:uppercase";
const TITLE_STYLE =
  "margin:0;color:#f8fafc;font-size:56px;line-height:0.94;letter-spacing:-0.05em";
const SUBTITLE_STYLE = "margin:0;color:#bfdbfe;font-size:24px;line-height:1.3";
const TOOLBAR_STYLE = "display:flex;flex-wrap:wrap;gap:14px";
const INFO_NOTE_STYLE =
  "margin:0;padding:18px 20px;border-radius:24px;background:rgba(8, 47, 73, 0.34);border:1px solid rgba(125, 211, 252, 0.14);color:#cbd5e1;font-size:18px;line-height:1.35";
const FEED_STYLE = "width:100%;display:flex;flex-direction:column;gap:16px";
const FEED_EMPTY_STYLE =
  "width:100%;margin:0;padding:28px 22px;border-radius:28px;background:rgba(2, 6, 23, 0.68);color:#bfdbfe;font-size:24px";
const NOTE_STYLE =
  "width:100%;display:flex;flex-direction:column;gap:12px;padding:24px;border-radius:28px;background:rgba(248, 250, 252, 0.96);color:#0f172a;box-shadow:0 18px 44px rgba(0, 0, 0, 0.22)";
const NOTE_META_STYLE =
  "display:flex;justify-content:space-between;gap:16px;color:#475569;font-size:18px";
const NOTE_AUTHOR_STYLE = "font-weight:700";
const NOTE_CONTENT_STYLE =
  "margin:0;font-size:30px;line-height:1.32;white-space:pre-wrap;overflow-wrap:anywhere";

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
    radial-gradient(circle at top, rgba(56, 189, 248, 0.16), transparent 36%),
    linear-gradient(180deg, #020617 0%, #082032 45%, #0f172a 100%);
  color: #e2e8f0;
  font: 500 16px/1.45 "Google Sans", "Roboto", "Droid Sans", "Noto Sans", "DejaVu Sans", sans-serif;
}

#shadow-blitz-root {
  width: 100%;
  height: 100%;
}

.timeline-shell {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  overflow-y: auto;
  padding: 24px 24px 40px;
  gap: 20px;
}

.timeline-hero {
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 18px;
  padding: 6px 4px 4px;
}

.timeline-eyebrow {
  margin: 0;
  color: #7dd3fc;
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
}

.timeline-title {
  margin: 0;
  color: #f8fafc;
  font-size: 56px;
  line-height: 0.94;
  letter-spacing: -0.05em;
}

.timeline-subtitle {
  margin: 0;
  color: #bfdbfe;
  font-size: 24px;
  line-height: 1.3;
}

.timeline-toolbar {
  display: flex;
  flex-wrap: wrap;
  gap: 14px;
}

.timeline-button {
  min-height: 76px;
  border: none;
  border-radius: 999px;
  padding: 18px 26px;
  font: inherit;
  font-size: 28px;
  font-weight: 800;
  letter-spacing: -0.03em;
}

.timeline-button-primary {
  background: linear-gradient(135deg, #93c5fd 0%, #38bdf8 45%, #22d3ee 100%);
  color: #082f49;
}

.timeline-button-secondary {
  background: rgba(14, 165, 233, 0.14);
  border: 1px solid rgba(125, 211, 252, 0.2);
  color: #e0f2fe;
}

.timeline-button[disabled] {
  opacity: 0.7;
}

.timeline-status {
  margin: 0;
  padding: 18px 20px;
  border-radius: 24px;
  font-size: 22px;
  line-height: 1.35;
}

.timeline-status-idle,
.timeline-status-ready {
  background: rgba(14, 165, 233, 0.12);
  border: 1px solid rgba(125, 211, 252, 0.16);
  color: #bae6fd;
}

.timeline-status-syncing {
  background: rgba(34, 211, 238, 0.12);
  border: 1px solid rgba(103, 232, 249, 0.18);
  color: #ccfbf1;
}

.timeline-status-error {
  background: rgba(127, 29, 29, 0.18);
  border: 1px solid rgba(251, 113, 133, 0.18);
  color: #fecdd3;
}

.timeline-feed {
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.timeline-feed-empty {
  width: 100%;
  margin: 0;
  padding: 28px 22px;
  border-radius: 28px;
  background: rgba(2, 6, 23, 0.68);
  color: #bfdbfe;
  font-size: 24px;
}

.timeline-note {
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 24px;
  border-radius: 28px;
  background: rgba(248, 250, 252, 0.96);
  color: #0f172a;
  box-shadow: 0 18px 44px rgba(0, 0, 0, 0.22);
}

.timeline-note-meta {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  color: #475569;
  font-size: 18px;
}

.timeline-note-author {
  font-weight: 700;
}

.timeline-note-content {
  margin: 0;
  font-size: 30px;
  line-height: 1.32;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
`;

function buttonStyle(variant: "primary" | "secondary", disabled = false) {
  const base =
    "min-height:76px;border:none;border-radius:999px;padding:18px 26px;font:inherit;font-size:28px;font-weight:800;letter-spacing:-0.03em";
  const colors = variant === "primary"
    ? "background:linear-gradient(135deg, #93c5fd 0%, #38bdf8 45%, #22d3ee 100%);color:#082f49"
    : "background:rgba(14, 165, 233, 0.14);border:1px solid rgba(125, 211, 252, 0.2);color:#e0f2fe";
  return `${base};${colors}${disabled ? ";opacity:0.7" : ""}`;
}

function statusStyle(kind: StatusState["kind"]) {
  const base =
    "margin:0;padding:18px 20px;border-radius:24px;font-size:22px;line-height:1.35";
  switch (kind) {
    case "syncing":
      return `${base};background:rgba(34, 211, 238, 0.12);border:1px solid rgba(103, 232, 249, 0.18);color:#ccfbf1`;
    case "error":
      return `${base};background:rgba(127, 29, 29, 0.18);border:1px solid rgba(251, 113, 133, 0.18);color:#fecdd3`;
    case "idle":
    case "ready":
    default:
      return `${base};background:rgba(14, 165, 233, 0.12);border:1px solid rgba(125, 211, 252, 0.16);color:#bae6fd`;
  }
}

export function renderApp() {
  const config = readTimelineConfig();
  const initialFeed = loadInitialFeed(config);
  const [notes, setNotes] = createSignal<NostrEvent[]>(initialFeed.notes);
  const [status, setStatus] = createSignal<StatusState>({
    kind: "idle",
    message: initialStatusMessage(initialFeed.source, initialFeed.notes.length),
  });

  onMount(() => {
    if (config.syncOnStart) {
      void refreshTimeline("startup");
    }
  });

  async function refreshTimeline(source: "startup" | "manual") {
    setStatus({
      kind: "syncing",
      message: source === "startup"
        ? "Refreshing timeline from relays..."
        : "Talking to relays for new notes...",
    });
    invalidateRuntimeApp();

    try {
      const receipt = await syncNostr({
        kinds: [1],
        limit: config.limit,
        relayUrls: config.relayUrls,
      }) as NostrSyncReceipt;
      const nextNotes = loadCachedNotes(config.limit);
      if (nextNotes.length > 0) {
        setNotes(nextNotes);
        setStatus({
          kind: "ready",
          message: `Fetched ${receipt.fetchedCount} note${
            receipt.fetchedCount === 1 ? "" : "s"
          }, imported ${receipt.importedCount}.`,
        });
      } else {
        setNotes([]);
        setStatus({
          kind: "ready",
          message: "No relay notes yet. The shared cache is still empty.",
        });
      }
    } catch (error) {
      const message = formatError(error);
      const count = notes().length;
      setStatus(
        count > 0
          ? {
            kind: "ready",
            message: `Relay refresh failed; showing ${count} cached note${
              count === 1 ? "" : "s"
            }.`,
          }
          : {
            kind: "error",
            message,
          },
      );
    } finally {
      invalidateRuntimeApp();
    }
  }

  return (
    <main class="timeline-shell" style={SHELL_STYLE}>
      <section class="timeline-hero" style={HERO_STYLE}>
        <p class="timeline-eyebrow" style={EYEBROW_STYLE}>Shadow Nostr</p>
        <h1 class="timeline-title" style={TITLE_STYLE}>Timeline</h1>
        <p class="timeline-subtitle" style={SUBTITLE_STYLE}>
          OS-owned feed read path below the app. Read the shared cache. Refresh
          from relays.
        </p>
        <div class="timeline-toolbar" style={TOOLBAR_STYLE}>
          <button
            class="timeline-button timeline-button-primary"
            data-shadow-id="refresh"
            style={buttonStyle("primary")}
            onClick={() => void refreshTimeline("manual")}
          >
            Refresh feed
          </button>
        </div>
        <p
          class={`timeline-status timeline-status-${status().kind}`}
          style={statusStyle(status().kind)}
        >
          {status().message}
        </p>
      </section>

      <p class="timeline-session-note" style={INFO_NOTE_STYLE}>
        Cached notes stay visible across restart. Publish comes later through
        the system signer.
      </p>

      <section class="timeline-feed" style={FEED_STYLE}>
        <Show
          when={notes().length > 0}
          fallback={
            <p class="timeline-feed-empty" style={FEED_EMPTY_STYLE}>
              No notes yet.
            </p>
          }
        >
          <For each={notes()}>
            {(event) => (
              <article class="timeline-note" style={NOTE_STYLE}>
                <div class="timeline-note-meta" style={NOTE_META_STYLE}>
                  <span class="timeline-note-author" style={NOTE_AUTHOR_STYLE}>
                    {shortPubkey(event.pubkey)}
                  </span>
                  <span>{formatTimestamp(event.created_at)}</span>
                </div>
                <p class="timeline-note-content" style={NOTE_CONTENT_STYLE}>
                  {event.content}
                </p>
              </article>
            )}
          </For>
        </Show>
      </section>
    </main>
  );
}

function loadCachedNotes(limit: number): NostrEvent[] {
  return queryNostr({ kinds: [1], limit }) as NostrEvent[];
}

function loadInitialFeed(config: Required<TimelineConfig>): {
  notes: NostrEvent[];
  source: FeedSource;
} {
  const cachedNotes = loadCachedNotes(config.limit);
  if (cachedNotes.length > 0) {
    return { notes: cachedNotes, source: "cached" };
  }

  return { notes: [], source: "empty" };
}

function readTimelineConfig(): Required<TimelineConfig> {
  const value = (
    globalThis as typeof globalThis & {
      SHADOW_RUNTIME_APP_CONFIG?: TimelineConfig;
    }
  ).SHADOW_RUNTIME_APP_CONFIG;
  const relayUrls =
    Array.isArray(value?.relayUrls) && value.relayUrls.length > 0
      ? value.relayUrls.map(String)
      : DEFAULT_RELAY_URLS;
  const limit = typeof value?.limit === "number" && value.limit > 0
    ? Math.floor(value.limit)
    : DEFAULT_LIMIT;
  const syncOnStart = value?.syncOnStart !== false;
  return { limit, relayUrls, syncOnStart };
}

function initialStatusMessage(source: FeedSource, count: number): string {
  switch (source) {
    case "cached":
      return `Warm cache ready with ${count} note${count === 1 ? "" : "s"}.`;
    case "empty":
    default:
      return "No cached notes yet. Refresh from relays.";
  }
}

function shortPubkey(pubkey: string): string {
  if (pubkey.length <= 18) {
    return pubkey;
  }
  return `${pubkey.slice(0, 10)}…${pubkey.slice(-6)}`;
}

function formatTimestamp(createdAt: number): string {
  return new Date(createdAt * 1000).toISOString().replace("T", " ").slice(
    0,
    16,
  );
}

function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
