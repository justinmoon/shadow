import {
  For,
  Show,
  createSignal,
  invalidateRuntimeApp,
  onMount,
} from "@shadow/app-runtime-solid";
import { listKind1, publishKind1, syncKind1 } from "@shadow/app-runtime-os";

type Kind1Event = {
  content: string;
  created_at: number;
  id: string;
  kind: number;
  pubkey: string;
};

type SyncReceipt = {
  fetchedCount: number;
  importedCount: number;
  relayUrls: string[];
};

type TimelineConfig = {
  limit?: number;
  relayUrls?: string[];
  syncOnStart?: boolean;
};

type StatusState =
  | { kind: "idle"; message: string }
  | { kind: "syncing"; message: string }
  | { kind: "posting"; message: string }
  | { kind: "ready"; message: string }
  | { kind: "error"; message: string };

const DEFAULT_RELAY_URLS = ["wss://relay.primal.net/", "wss://relay.damus.io/"];
const DEFAULT_LIMIT = 12;

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
  font: 500 16px/1.45 "Google Sans", "Roboto", "Droid Sans", "Noto Sans", sans-serif;
}

#shadow-blitz-root {
  min-height: 100vh;
}

.timeline-shell {
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  padding: 24px;
  gap: 20px;
}

.timeline-hero {
  display: flex;
  flex-direction: column;
  gap: 18px;
  padding: 28px 26px;
  border-radius: 34px;
  background: rgba(2, 6, 23, 0.74);
  border: 1px solid rgba(56, 189, 248, 0.18);
  box-shadow: 0 28px 80px rgba(0, 0, 0, 0.3);
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

.timeline-status-syncing,
.timeline-status-posting {
  background: rgba(34, 211, 238, 0.12);
  border: 1px solid rgba(103, 232, 249, 0.18);
  color: #ccfbf1;
}

.timeline-status-error {
  background: rgba(127, 29, 29, 0.18);
  border: 1px solid rgba(251, 113, 133, 0.18);
  color: #fecdd3;
}

.timeline-compose {
  display: flex;
  flex-direction: column;
  gap: 16px;
  padding: 24px;
  border-radius: 30px;
  background: rgba(2, 6, 23, 0.72);
  border: 1px solid rgba(56, 189, 248, 0.16);
}

.timeline-compose-label {
  margin: 0;
  color: #93c5fd;
  font-size: 18px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}

.timeline-compose-input {
  width: 100%;
  min-height: 88px;
  border-radius: 24px;
  border: 1px solid rgba(148, 163, 184, 0.25);
  background: rgba(15, 23, 42, 0.9);
  color: #f8fafc;
  padding: 22px 24px;
  font: inherit;
  font-size: 28px;
}

.timeline-compose-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 16px;
  color: #94a3b8;
  font-size: 18px;
}

.timeline-feed {
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.timeline-feed-empty {
  margin: 0;
  padding: 28px 22px;
  border-radius: 28px;
  background: rgba(2, 6, 23, 0.68);
  color: #bfdbfe;
  font-size: 24px;
}

.timeline-note {
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

export function renderApp() {
  const config = readTimelineConfig();
  const [notes, setNotes] = createSignal<Kind1Event[]>(loadCachedNotes(config.limit));
  const [draft, setDraft] = createSignal("");
  const [focused, setFocused] = createSignal(false);
  const [selection, setSelection] = createSignal("0-0:none");
  const [status, setStatus] = createSignal<StatusState>({
    kind: "idle",
    message: `Cached ${notes().length} note${notes().length === 1 ? "" : "s"}.`,
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
      const receipt = await syncKind1({
        limit: config.limit,
        relayUrls: config.relayUrls,
      }) as SyncReceipt;
          const nextNotes = loadCachedNotes(config.limit);
      setNotes(nextNotes);
      setStatus({
        kind: "ready",
        message:
          `Fetched ${receipt.fetchedCount} note${receipt.fetchedCount === 1 ? "" : "s"}, imported ${receipt.importedCount}.`,
      });
    } catch (error) {
      setStatus({
        kind: "error",
        message: formatError(error),
      });
    } finally {
      invalidateRuntimeApp();
    }
  }

  function publishDraft(contentOverride?: string) {
    const content = (contentOverride ?? draft()).trim();
    if (!content) {
      setStatus({
        kind: "error",
        message: "Type an English note before posting.",
      });
      return;
    }

    setStatus({
      kind: "posting",
      message: "Saving note into the local Shadow timeline...",
    });
    const event = publishKind1({ content }) as Kind1Event;
    setDraft("");
    setSelection("0-0:none");
    const nextNotes = loadCachedNotes(config.limit);
    setNotes(nextNotes);
    setStatus({
      kind: "ready",
      message: `Saved ${event.id.slice(0, 12)}… into the local timeline.`,
    });
  }

  return (
    <main class="timeline-shell">
      <section class="timeline-hero">
        <p class="timeline-eyebrow">Shadow Nostr</p>
        <h1 class="timeline-title">Timeline</h1>
        <p class="timeline-subtitle">
          OS-owned feed read path below the app. Compose locally. Refresh from relays.
        </p>
        <div class="timeline-toolbar">
          <button
            class="timeline-button timeline-button-primary"
            data-shadow-id="refresh"
            onClick={() => void refreshTimeline("manual")}
          >
            Refresh feed
          </button>
          <button
            class="timeline-button timeline-button-secondary"
            data-shadow-id="quick-gm"
            onClick={() => publishDraft("GM")}
          >
            Quick GM
          </button>
        </div>
        <p class={`timeline-status timeline-status-${status().kind}`}>
          {status().message}
        </p>
      </section>

      <section class="timeline-compose">
        <p class="timeline-compose-label">Compose</p>
        <input
          class="timeline-compose-input"
          data-shadow-id="draft"
          placeholder="Type a short English note"
          value={draft()}
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          onInput={(event) => {
            setDraft(event.value || "");
            setSelection(formatSelection(event));
          }}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              publishDraft();
            }
          }}
        />
        <div class="timeline-toolbar">
          <button
            class="timeline-button timeline-button-primary"
            data-shadow-id="post"
            disabled={!draft().trim()}
            onClick={() => publishDraft()}
          >
            Post note
          </button>
        </div>
        <div class="timeline-compose-meta">
          <span>Focus: {focused() ? "focused" : "blurred"}</span>
          <span>Draft: {draft() || "(empty)"}</span>
          <span>Selection: {selection()}</span>
          <span>Notes: {notes().length}</span>
        </div>
      </section>

      <section class="timeline-feed">
        <Show
          when={notes().length > 0}
          fallback={<p class="timeline-feed-empty">No notes yet.</p>}
        >
          <For each={notes()}>
            {(event) => (
              <article class="timeline-note">
                <div class="timeline-note-meta">
                  <span class="timeline-note-author">{shortPubkey(event.pubkey)}</span>
                  <span>{formatTimestamp(event.created_at)}</span>
                </div>
                <p class="timeline-note-content">{event.content}</p>
              </article>
            )}
          </For>
        </Show>
      </section>
    </main>
  );
}

function loadCachedNotes(limit: number): Kind1Event[] {
  return listKind1({ limit }) as Kind1Event[];
}

function readTimelineConfig(): Required<TimelineConfig> {
  const value = (
    globalThis as typeof globalThis & {
      SHADOW_RUNTIME_APP_CONFIG?: TimelineConfig;
    }
  ).SHADOW_RUNTIME_APP_CONFIG;
  const relayUrls = Array.isArray(value?.relayUrls) && value.relayUrls.length > 0
    ? value.relayUrls.map(String)
    : DEFAULT_RELAY_URLS;
  const limit = typeof value?.limit === "number" && value.limit > 0
    ? Math.floor(value.limit)
    : DEFAULT_LIMIT;
  const syncOnStart = value?.syncOnStart !== false;
  return { limit, relayUrls, syncOnStart };
}

function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function shortPubkey(pubkey: string): string {
  if (pubkey.length <= 18) {
    return pubkey;
  }
  return `${pubkey.slice(0, 10)}…${pubkey.slice(-6)}`;
}

function formatTimestamp(createdAt: number): string {
  return new Date(createdAt * 1000).toISOString().replace("T", " ").slice(0, 16);
}

function formatSelection(event: {
  selectionDirection?: string | null;
  selectionEnd?: number | null;
  selectionStart?: number | null;
}): string {
  const start = event.selectionStart ?? 0;
  const end = event.selectionEnd ?? start;
  const direction = event.selectionDirection ?? "none";
  return `${start}-${end}:${direction}`;
}
