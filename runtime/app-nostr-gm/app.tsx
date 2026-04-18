import {
  createSignal,
  For,
  invalidateRuntimeApp,
  publishEphemeralKind1,
  Show,
} from "@shadow/sdk";

const GM_CONTENT = "GM";
const DEFAULT_RELAY_URLS = ["wss://relay.primal.net/", "wss://relay.damus.io/"];
const DEFAULT_TIMEOUT_MS = 20_000;

type PublishedRelayFailure = {
  error: string;
  relayUrl: string;
};

type PublishReceipt = {
  createdAt: number;
  failedRelays: PublishedRelayFailure[];
  id: string;
  noteId: string;
  npub: string;
  primalUrl: string;
  publishedRelays: string[];
  qrRows: string[];
  relayUrls: string[];
};

type AppState =
  | { kind: "idle" }
  | { kind: "publishing" }
  | { kind: "error"; message: string }
  | { kind: "success"; receipt: PublishReceipt };

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
  background: linear-gradient(180deg, #03111c 0%, #08314c 48%, #0f766e 100%);
  color: #f8fafc;
  font: 500 16px/1.45 "Google Sans", "Roboto", "Droid Sans", "Noto Sans", "DejaVu Sans", sans-serif;
}

#shadow-blitz-root {
  min-height: 100vh;
}

.gm-shell {
  min-height: 100vh;
  width: 100%;
  display: flex;
  align-items: stretch;
  justify-content: stretch;
  padding: 28px;
}

.gm-card {
  flex: 1;
  min-height: 100%;
  display: flex;
  flex-direction: column;
  gap: 20px;
  padding: 36px 30px;
  border-radius: 36px;
  box-shadow: 0 28px 90px rgba(0, 0, 0, 0.32);
}

.gm-card-idle,
.gm-card-publishing {
  background: rgba(2, 6, 23, 0.78);
  border: 1px solid rgba(125, 211, 252, 0.22);
}

.gm-card-success {
  background: #f8fafc;
  border: 2px solid #082f49;
  color: #0f172a;
}

.gm-card-error {
  background: #fef2f2;
  border: 2px solid #fecdd3;
  color: #7f1d1d;
}

.gm-eyebrow {
  margin: 0;
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
}

.gm-eyebrow-idle,
.gm-eyebrow-publishing {
  color: #7dd3fc;
}

.gm-eyebrow-success {
  color: #0369a1;
}

.gm-eyebrow-error {
  color: #b91c1c;
}

.gm-headline {
  margin: 0;
  font-size: 64px;
  line-height: 0.94;
  letter-spacing: -0.05em;
}

.gm-headline-idle,
.gm-headline-publishing {
  color: #f8fafc;
}

.gm-headline-success {
  color: #020617;
}

.gm-headline-error {
  color: #7f1d1d;
}

.gm-body {
  margin: 0;
  font-size: 28px;
  line-height: 1.34;
}

.gm-body-idle,
.gm-body-publishing {
  color: #dbeafe;
}

.gm-body-success {
  color: #334155;
}

.gm-body-error {
  color: #7f1d1d;
}

.gm-spacer {
  flex: 1;
}

.gm-progress {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 20px 22px;
  border-radius: 26px;
  background: rgba(14, 165, 233, 0.12);
  border: 1px solid rgba(125, 211, 252, 0.2);
}

.gm-progress-label {
  margin: 0;
  color: #bae6fd;
  font-size: 18px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.gm-progress-track {
  width: 100%;
  height: 20px;
  border-radius: 999px;
  overflow: hidden;
  background: rgba(15, 23, 42, 0.65);
  border: 1px solid rgba(186, 230, 253, 0.18);
}

.gm-progress-fill {
  width: 68%;
  height: 100%;
  border-radius: 999px;
  background: linear-gradient(90deg, #67e8f9 0%, #2dd4bf 100%);
}

.gm-action {
  width: 100%;
  min-height: 112px;
  border: none;
  border-radius: 999px;
  padding: 24px 28px;
  font: inherit;
  font-size: 42px;
  font-weight: 800;
  letter-spacing: -0.04em;
}

.gm-action-primary {
  background: linear-gradient(135deg, #a5f3fc 0%, #67e8f9 30%, #2dd4bf 100%);
  color: #062a30;
}

.gm-action-secondary {
  background: linear-gradient(135deg, #0ea5e9 0%, #14b8a6 100%);
  color: #f8fafc;
}

.gm-action-danger {
  background: linear-gradient(135deg, #fb7185 0%, #ef4444 100%);
  color: #fff1f2;
}

.gm-action[disabled] {
  opacity: 0.72;
}

.gm-success-grid {
  display: flex;
  flex-direction: column;
  gap: 22px;
}

.gm-qr-frame {
  align-self: center;
  padding: 16px;
  border-radius: 28px;
  background: #ecfeff;
  border: 1px solid rgba(8, 47, 73, 0.16);
}

.gm-qr-grid {
  display: grid;
  gap: 0;
  width: min(68vw, 360px);
  height: min(68vw, 360px);
  background: #ffffff;
  padding: 10px;
}

.gm-qr-cell {
  background: #ffffff;
}

.gm-qr-cell-on {
  background: #020617;
}

.gm-meta {
  display: flex;
  flex-direction: column;
  gap: 16px;
  padding: 22px;
  border-radius: 28px;
  background: #f0fdfa;
  border: 1px solid rgba(13, 148, 136, 0.18);
}

.gm-label-group {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.gm-label {
  margin: 0;
  color: #0f766e;
  font-size: 16px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.gm-value {
  margin: 0;
  color: #0f172a;
  font-family: "Droid Sans Mono", "DejaVu Sans Mono", "Cutive Mono", monospace;
  font-size: 19px;
  line-height: 1.42;
  overflow-wrap: anywhere;
}
`;

export function renderApp() {
  const [state, setState] = createSignal<AppState>({ kind: "idle" });

  function sendGm() {
    if (state().kind === "publishing") {
      return;
    }

    setState({ kind: "publishing" });
    void publishGm();
  }

  async function publishGm() {
    try {
      const receipt = await publishEphemeralKind1({
        content: GM_CONTENT,
        relayUrls: DEFAULT_RELAY_URLS,
        timeoutMs: DEFAULT_TIMEOUT_MS,
      }) as PublishReceipt;
      setState({ kind: "success", receipt });
    } catch (error) {
      setState({
        kind: "error",
        message: error instanceof Error ? error.message : String(error),
      });
    } finally {
      invalidateRuntimeApp();
    }
  }

  return (
    <main class="gm-shell">
      <Show
        when={state().kind === "success"}
        fallback={<IdleOrErrorCard state={state()} onSend={sendGm} />}
      >
        <SuccessCard
          receipt={(state() as Extract<AppState, { kind: "success" }>).receipt}
          onSend={sendGm}
        />
      </Show>
    </main>
  );
}

type IdleOrErrorCardProps = {
  onSend: () => void;
  state: AppState;
};

function IdleOrErrorCard(props: IdleOrErrorCardProps) {
  const state = () => props.state;
  const isPublishing = () => state().kind === "publishing";
  const isError = () => state().kind === "error";

  return (
    <section class={`gm-card ${cardVariantClass(state())}`}>
      <p class={`gm-eyebrow ${eyebrowVariantClass(state())}`}>Shadow GM</p>
      <h1 class={`gm-headline ${headlineVariantClass(state())}`}>
        {isError()
          ? "Relay publish failed"
          : isPublishing()
          ? "Publishing GM"
          : "Tap to send GM"}
      </h1>
      <p class={`gm-body ${bodyVariantClass(state())}`}>
        {isError()
          ? (state() as Extract<AppState, { kind: "error" }>).message
          : isPublishing()
          ? "Generating a fresh nsec, signing one kind 1 note, and waiting for relay ack. This can take around 10 seconds."
          : "One tap generates a fresh keypair, posts a kind 1 note with just GM, and turns the result into a scannable Primal link."}
      </p>
      <Show when={isPublishing()}>
        <section class="gm-progress">
          <p class="gm-progress-label">Talking to relays</p>
          <div class="gm-progress-track">
            <div class="gm-progress-fill" />
          </div>
        </section>
      </Show>
      <div class="gm-spacer" />
      <button
        type="button"
        class={`gm-action ${
          isError() ? "gm-action-danger" : "gm-action-primary"
        }`}
        data-shadow-id="gm"
        disabled={isPublishing()}
        onClick={props.onSend}
      >
        {isError() ? "Retry GM" : isPublishing() ? "Publishing…" : "GM"}
      </button>
    </section>
  );
}

type SuccessCardProps = {
  onSend: () => void;
  receipt: PublishReceipt;
};

function SuccessCard(props: SuccessCardProps) {
  return (
    <section class="gm-card gm-card-success">
      <p class="gm-eyebrow gm-eyebrow-success">Shadow GM</p>
      <h1 class="gm-headline gm-headline-success">GM sent</h1>
      <p class="gm-body gm-body-success">
        Fresh key, one note, Primal link ready to scan.
      </p>
      <section class="gm-success-grid">
        <QrCode rows={props.receipt.qrRows} />
        <section class="gm-meta">
          <LabelValue label="Primal" value={props.receipt.primalUrl} />
          <LabelValue label="Note" value={props.receipt.noteId} />
          <LabelValue label="Pubkey" value={props.receipt.npub} />
          <LabelValue
            label="Relays"
            value={`${props.receipt.publishedRelays.length}/${props.receipt.relayUrls.length} ok`}
          />
        </section>
      </section>
      <button
        type="button"
        class="gm-action gm-action-secondary"
        data-shadow-id="gm"
        onClick={props.onSend}
      >
        Post another GM
      </button>
    </section>
  );
}

function QrCode(props: { rows: string[] }) {
  const size = () => props.rows[0]?.length ?? 0;

  return (
    <div class="gm-qr-frame">
      <div
        class="gm-qr-grid"
        style={`grid-template-columns:repeat(${size()},1fr)`}
      >
        <For each={props.rows}>
          {(row) => (
            <For each={Array.from(row)}>
              {(cell) => (
                <span
                  class={`gm-qr-cell${cell === "1" ? " gm-qr-cell-on" : ""}`}
                />
              )}
            </For>
          )}
        </For>
      </div>
    </div>
  );
}

function LabelValue(props: { label: string; value: string }) {
  return (
    <div class="gm-label-group">
      <p class="gm-label">{props.label}</p>
      <p class="gm-value">{props.value}</p>
    </div>
  );
}

function cardVariantClass(state: AppState) {
  switch (state.kind) {
    case "error":
      return "gm-card-error";
    case "publishing":
      return "gm-card-publishing";
    default:
      return "gm-card-idle";
  }
}

function eyebrowVariantClass(state: AppState) {
  switch (state.kind) {
    case "error":
      return "gm-eyebrow-error";
    case "publishing":
      return "gm-eyebrow-publishing";
    default:
      return "gm-eyebrow-idle";
  }
}

function headlineVariantClass(state: AppState) {
  switch (state.kind) {
    case "error":
      return "gm-headline-error";
    case "publishing":
      return "gm-headline-publishing";
    default:
      return "gm-headline-idle";
  }
}

function bodyVariantClass(state: AppState) {
  switch (state.kind) {
    case "error":
      return "gm-body-error";
    case "publishing":
      return "gm-body-publishing";
    default:
      return "gm-body-idle";
  }
}
