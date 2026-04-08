import {
  For,
  Show,
  createSignal,
  invalidateRuntimeApp,
  onMount,
} from "@shadow/app-runtime-solid";
import {
  addCashuMint,
  checkCashuMintQuote,
  createCashuMintQuote,
  listCashuWallets,
  payCashuInvoice,
  receiveCashuToken,
  sendCashuToken,
  settleCashuMintQuote,
} from "@shadow/app-runtime-os";

type WalletSummary = {
  balanceSats: number;
  mintUrl: string;
  unit: string;
};

type MintQuoteReceipt = {
  amountSats: number | null;
  expiry: number;
  mintUrl: string;
  paymentRequest: string;
  qrRows: string[];
  quoteId: string;
  state: string;
};

type SettledMintQuoteReceipt = {
  balanceSats: number;
  mintUrl: string;
  mintedAmountSats: number;
  quoteId: string;
  state: string;
};

type SendTokenReceipt = {
  amountSats: number;
  balanceSats: number;
  feeSats: number;
  mintUrl: string;
  token: string;
};

type ReceiveTokenReceipt = {
  balanceSats: number;
  mintUrl: string;
  receivedAmountSats: number;
};

type PayInvoiceReceipt = {
  amountSats: number;
  balanceSats: number;
  feePaidSats: number;
  feeReserveSats: number;
  mintUrl: string;
  paymentProof: string | null;
  quoteId: string;
  state: string;
};

type WalletAppConfig = {
  defaultMintUrl?: string;
  defaultFundAmountSats?: number;
};

type StatusState =
  | { kind: "idle"; message: string }
  | { kind: "working"; message: string }
  | { kind: "success"; message: string }
  | { kind: "error"; message: string };

const DEFAULT_FUND_AMOUNT_SATS = 100;
const DEFAULT_SEND_AMOUNT_SATS = 21;
const DEFAULT_STATUS: StatusState = {
  kind: "idle",
  message:
    "Trust one mint, then fund via Lightning, send and receive Cashu tokens, or pay a BOLT11 invoice.",
};

export const runtimeDocumentCss = `
:root {
  color-scheme: light;
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
    radial-gradient(circle at top left, rgba(22, 163, 74, 0.16), transparent 34%),
    radial-gradient(circle at bottom right, rgba(245, 158, 11, 0.16), transparent 28%),
    linear-gradient(180deg, #f7f5ef 0%, #efe9dc 100%);
  color: #1f2937;
  font: 500 16px/1.45 "Google Sans", "Roboto", "Droid Sans", "Noto Sans", "DejaVu Sans", sans-serif;
}

#shadow-blitz-root {
  width: 100%;
  height: 100%;
}

.wallet-shell {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  overflow-y: auto;
  gap: 20px;
  padding: 24px;
}

.wallet-hero {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 6px 4px 2px;
}

.wallet-kicker {
  margin: 0;
  color: #15803d;
  font-size: 13px;
  font-weight: 800;
  letter-spacing: 0.14em;
  text-transform: uppercase;
}

.wallet-title {
  margin: 0;
  color: #111827;
  font-size: 58px;
  line-height: 0.92;
  letter-spacing: -0.05em;
}

.wallet-subtitle {
  margin: 0;
  color: #4b5563;
  font-size: 22px;
  line-height: 1.32;
}

.wallet-status {
  margin: 0;
  padding: 16px 18px;
  border-radius: 24px;
  font-size: 20px;
  line-height: 1.32;
}

.wallet-status-idle {
  background: rgba(17, 24, 39, 0.06);
  border: 1px solid rgba(17, 24, 39, 0.08);
  color: #374151;
}

.wallet-status-working {
  background: rgba(20, 184, 166, 0.12);
  border: 1px solid rgba(13, 148, 136, 0.18);
  color: #115e59;
}

.wallet-status-success {
  background: rgba(22, 163, 74, 0.12);
  border: 1px solid rgba(22, 163, 74, 0.18);
  color: #166534;
}

.wallet-status-error {
  background: rgba(220, 38, 38, 0.1);
  border: 1px solid rgba(220, 38, 38, 0.18);
  color: #991b1b;
}

.wallet-mints {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
}

.wallet-mint-chip {
  min-height: 70px;
  min-width: 140px;
  display: flex;
  flex-direction: column;
  gap: 4px;
  justify-content: center;
  padding: 14px 18px;
  border: none;
  border-radius: 22px;
  text-align: left;
  font: inherit;
}

.wallet-mint-chip-active {
  background: linear-gradient(135deg, #166534 0%, #16a34a 100%);
  color: #f0fdf4;
}

.wallet-mint-chip-idle {
  background: rgba(255, 255, 255, 0.72);
  border: 1px solid rgba(22, 101, 52, 0.12);
  color: #14532d;
}

.wallet-mint-title {
  font-size: 16px;
  font-weight: 800;
}

.wallet-mint-balance {
  font-size: 14px;
  opacity: 0.82;
}

.wallet-grid {
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.wallet-card {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 24px;
  border-radius: 30px;
  background: rgba(255, 255, 255, 0.76);
  border: 1px solid rgba(17, 24, 39, 0.08);
  box-shadow: 0 22px 60px rgba(15, 23, 42, 0.08);
}

.wallet-card-balance {
  background:
    radial-gradient(circle at top left, rgba(22, 163, 74, 0.16), transparent 32%),
    linear-gradient(135deg, #14532d 0%, #166534 48%, #22c55e 100%);
  color: #f0fdf4;
}

.wallet-section-kicker {
  margin: 0;
  font-size: 13px;
  font-weight: 800;
  letter-spacing: 0.12em;
  text-transform: uppercase;
}

.wallet-card .wallet-section-kicker {
  color: #15803d;
}

.wallet-card-balance .wallet-section-kicker {
  color: rgba(240, 253, 244, 0.82);
}

.wallet-balance-row {
  display: flex;
  align-items: baseline;
  gap: 10px;
}

.wallet-balance-value {
  margin: 0;
  font-size: 60px;
  line-height: 0.94;
  letter-spacing: -0.06em;
}

.wallet-balance-unit {
  margin: 0;
  font-size: 24px;
  letter-spacing: 0.03em;
}

.wallet-balance-detail {
  margin: 0;
  color: inherit;
  opacity: 0.82;
  font-size: 18px;
  line-height: 1.3;
}

.wallet-label {
  margin: 0;
  color: #374151;
  font-size: 15px;
  font-weight: 700;
}

.wallet-input {
  width: 100%;
  min-height: 68px;
  border-radius: 22px;
  border: 1px solid rgba(17, 24, 39, 0.12);
  background: rgba(255, 255, 255, 0.92);
  color: #111827;
  padding: 18px 20px;
  font: inherit;
  font-size: 20px;
}

.wallet-mono {
  font-family: "Iosevka", "SF Mono", "Menlo", "DejaVu Sans Mono", monospace;
  letter-spacing: -0.02em;
}

.wallet-toolbar {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
}

.wallet-button {
  min-height: 72px;
  border: none;
  border-radius: 999px;
  padding: 16px 24px;
  font: inherit;
  font-size: 24px;
  font-weight: 800;
  letter-spacing: -0.03em;
}

.wallet-button-primary {
  background: linear-gradient(135deg, #166534 0%, #22c55e 100%);
  color: #f0fdf4;
}

.wallet-button-secondary {
  background: linear-gradient(135deg, #f59e0b 0%, #fbbf24 100%);
  color: #451a03;
}

.wallet-button-ghost {
  background: rgba(17, 24, 39, 0.06);
  border: 1px solid rgba(17, 24, 39, 0.08);
  color: #1f2937;
}

.wallet-button[disabled] {
  opacity: 0.68;
}

.wallet-payload {
  margin: 0;
  padding: 16px 18px;
  border-radius: 24px;
  background: rgba(17, 24, 39, 0.04);
  color: #111827;
  font-size: 14px;
  line-height: 1.45;
  overflow-wrap: anywhere;
}

.wallet-qr {
  align-self: center;
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 14px;
  border-radius: 24px;
  background: #fffef8;
  border: 1px solid rgba(17, 24, 39, 0.08);
}

.wallet-qr-row {
  display: flex;
  gap: 2px;
}

.wallet-qr-cell {
  width: 8px;
  height: 8px;
  border-radius: 1px;
}

.wallet-qr-cell-on {
  background: #111827;
}

.wallet-qr-cell-off {
  background: #f8fafc;
}
`;

function readWalletConfig(): WalletAppConfig {
  const candidate = globalThis.SHADOW_RUNTIME_APP_CONFIG;
  if (!candidate || typeof candidate !== "object") {
    return {};
  }

  const config = candidate as Record<string, unknown>;
  return {
    defaultFundAmountSats: typeof config.defaultFundAmountSats === "number"
      ? config.defaultFundAmountSats
      : undefined,
    defaultMintUrl: typeof config.defaultMintUrl === "string"
      ? config.defaultMintUrl
      : undefined,
  };
}

function parsePositiveInt(value: string): number | null {
  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }
  const parsed = Number(trimmed);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return null;
  }
  return Math.floor(parsed);
}

function shortMintLabel(mintUrl: string): string {
  try {
    const url = new URL(mintUrl);
    return url.host || mintUrl;
  } catch {
    return mintUrl;
  }
}

function quoteStatusMessage(quote: MintQuoteReceipt): string {
  const amountLabel = quote.amountSats == null ? "unknown" : `${quote.amountSats} sats`;
  switch (quote.state) {
    case "unpaid":
      return `Invoice ready for ${amountLabel}. Pay it externally, then check or mint it.`;
    case "paid":
      return `Invoice paid for ${amountLabel}. Mint it into the wallet when you're ready.`;
    case "issued":
      return `Quote ${quote.quoteId} has already been minted.`;
    default:
      return `Quote ${quote.quoteId} is ${quote.state}.`;
  }
}

function QrCode(props: { rows: string[] }) {
  return (
    <Show when={props.rows.length > 0}>
      <div class="wallet-qr">
        <For each={props.rows}>
          {(row) => (
            <div class="wallet-qr-row">
              <For each={row.split("")}>
                {(cell) => (
                  <span
                    class={`wallet-qr-cell ${
                      cell === "1" ? "wallet-qr-cell-on" : "wallet-qr-cell-off"
                    }`}
                  />
                )}
              </For>
            </div>
          )}
        </For>
      </div>
    </Show>
  );
}

export function renderApp() {
  const config = readWalletConfig();
  const [wallets, setWallets] = createSignal<WalletSummary[]>([]);
  const [selectedMintUrl, setSelectedMintUrl] = createSignal(config.defaultMintUrl ?? "");
  const [mintDraft, setMintDraft] = createSignal(config.defaultMintUrl ?? "");
  const [fundAmountDraft, setFundAmountDraft] = createSignal(
    String(config.defaultFundAmountSats ?? DEFAULT_FUND_AMOUNT_SATS),
  );
  const [sendAmountDraft, setSendAmountDraft] = createSignal(
    String(DEFAULT_SEND_AMOUNT_SATS),
  );
  const [tokenDraft, setTokenDraft] = createSignal("");
  const [invoiceDraft, setInvoiceDraft] = createSignal("");
  const [fundQuote, setFundQuote] = createSignal<MintQuoteReceipt | null>(null);
  const [latestToken, setLatestToken] = createSignal<SendTokenReceipt | null>(null);
  const [latestReceive, setLatestReceive] = createSignal<ReceiveTokenReceipt | null>(null);
  const [latestPayment, setLatestPayment] = createSignal<PayInvoiceReceipt | null>(null);
  const [status, setStatus] = createSignal<StatusState>(DEFAULT_STATUS);
  const [busy, setBusy] = createSignal(false);

  const activeWallet = () =>
    wallets().find((wallet) => wallet.mintUrl === selectedMintUrl()) ?? null;
  const totalBalanceSats = () =>
    wallets().reduce((sum, wallet) => sum + wallet.balanceSats, 0);

  async function refreshWallets(reason: string) {
    const nextWallets = await listCashuWallets() as WalletSummary[];
    setWallets(nextWallets);

    const selectedMint = selectedMintUrl();
    if (
      nextWallets.length > 0 &&
      (!selectedMint || !nextWallets.some((wallet) => wallet.mintUrl === selectedMint))
    ) {
      setSelectedMintUrl(nextWallets[0].mintUrl);
    }

    if (reason === "startup" && nextWallets.length > 0) {
      setStatus({
        kind: "idle",
        message: `Trusted ${nextWallets.length} mint${nextWallets.length === 1 ? "" : "s"} already loaded.`,
      });
    }
  }

  async function withBusyState(
    workingMessage: string,
    successMessage: string,
    action: () => Promise<void>,
  ) {
    setBusy(true);
    setStatus({ kind: "working", message: workingMessage });
    invalidateRuntimeApp();

    try {
      await action();
      setStatus({ kind: "success", message: successMessage });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setStatus({ kind: "error", message });
    } finally {
      setBusy(false);
      invalidateRuntimeApp();
    }
  }

  async function addMint() {
    const mintUrl = mintDraft().trim();
    await withBusyState(
      "Trusting mint and warming wallet metadata...",
      `Trusted ${shortMintLabel(mintUrl)} for sats.`,
      async () => {
        const wallet = await addCashuMint({ mintUrl }) as WalletSummary;
        await refreshWallets("add-mint");
        setSelectedMintUrl(wallet.mintUrl);
      },
    );
  }

  async function createFundingQuote() {
    const mintUrl = selectedMintUrl().trim() || mintDraft().trim();
    const amountSats = parsePositiveInt(fundAmountDraft());
    if (!amountSats) {
      setStatus({
        kind: "error",
        message: "Funding amount must be a positive number of sats.",
      });
      return;
    }

    await withBusyState(
      "Requesting a Lightning funding invoice from the mint...",
      `Funding invoice ready from ${shortMintLabel(mintUrl)}.`,
      async () => {
        const quote = await createCashuMintQuote({
          amountSats,
          mintUrl,
        }) as MintQuoteReceipt;
        setFundQuote(quote);
      },
    );
  }

  async function checkFundingQuote() {
    const quote = fundQuote();
    if (!quote) {
      return;
    }

    await withBusyState(
      "Checking whether the mint has seen the Lightning payment...",
      `Quote ${quote.quoteId} is ${quote.state}.`,
      async () => {
        const refreshed = await checkCashuMintQuote({
          mintUrl: quote.mintUrl,
          quoteId: quote.quoteId,
        }) as MintQuoteReceipt;
        setFundQuote(refreshed);
        setStatus({
          kind: "success",
          message: quoteStatusMessage(refreshed),
        });
      },
    );
  }

  async function settleFundingQuote() {
    const quote = fundQuote();
    if (!quote) {
      return;
    }

    await withBusyState(
      "Minting the paid quote into spendable Cashu proofs...",
      "Funding quote minted into wallet balance.",
      async () => {
        const receipt = await settleCashuMintQuote({
          mintUrl: quote.mintUrl,
          quoteId: quote.quoteId,
          timeoutMs: 15_000,
        }) as SettledMintQuoteReceipt;
        await refreshWallets("settle-quote");
        const refreshed = await checkCashuMintQuote({
          mintUrl: quote.mintUrl,
          quoteId: quote.quoteId,
        }) as MintQuoteReceipt;
        setFundQuote(refreshed);
        setStatus({
          kind: "success",
          message:
            `Minted ${receipt.mintedAmountSats} sats. Balance is now ${receipt.balanceSats} sats.`,
        });
      },
    );
  }

  async function createSendToken() {
    const amountSats = parsePositiveInt(sendAmountDraft());
    if (!amountSats) {
      setStatus({
        kind: "error",
        message: "Send amount must be a positive number of sats.",
      });
      return;
    }

    await withBusyState(
      "Selecting proofs and creating a sendable Cashu token...",
      "Cashu token created.",
      async () => {
        const receipt = await sendCashuToken({
          amountSats,
          mintUrl: selectedMintUrl(),
        }) as SendTokenReceipt;
        setLatestToken(receipt);
        setTokenDraft(receipt.token);
        await refreshWallets("send-token");
        setStatus({
          kind: "success",
          message:
            `Created a ${receipt.amountSats} sat token with ${receipt.feeSats} sat fee.`,
        });
      },
    );
  }

  async function receiveToken() {
    const token = tokenDraft().trim();
    if (!token) {
      setStatus({
        kind: "error",
        message: "Paste a Cashu token before trying to receive it.",
      });
      return;
    }

    await withBusyState(
      "Redeeming the pasted Cashu token with its mint...",
      "Cashu token redeemed into the wallet.",
      async () => {
        const receipt = await receiveCashuToken({ token }) as ReceiveTokenReceipt;
        setLatestReceive(receipt);
        await refreshWallets("receive-token");
        setStatus({
          kind: "success",
          message:
            `Received ${receipt.receivedAmountSats} sats from ${shortMintLabel(receipt.mintUrl)}.`,
        });
      },
    );
  }

  async function payInvoice() {
    const invoice = invoiceDraft().trim();
    if (!invoice) {
      setStatus({
        kind: "error",
        message: "Paste a BOLT11 invoice before trying to pay it.",
      });
      return;
    }

    await withBusyState(
      "Getting a melt quote and paying the Lightning invoice...",
      "Lightning invoice paid from the Cashu wallet.",
      async () => {
        const receipt = await payCashuInvoice({
          invoice,
          mintUrl: selectedMintUrl(),
        }) as PayInvoiceReceipt;
        setLatestPayment(receipt);
        await refreshWallets("pay-invoice");
        setStatus({
          kind: "success",
          message:
            `Paid ${receipt.amountSats} sats with ${receipt.feePaidSats} sats of final fee.`,
        });
      },
    );
  }

  onMount(() => {
    void refreshWallets("startup").then(() => invalidateRuntimeApp());
  });

  return (
    <main
      class="wallet-shell"
      data-shadow-active-mint={selectedMintUrl()}
      data-shadow-wallet-count={String(wallets().length)}
      data-shadow-status-kind={status().kind}
      data-shadow-latest-invoice={fundQuote()?.paymentRequest ?? ""}
      data-shadow-fund-quote-state={fundQuote()?.state ?? ""}
      data-shadow-fund-quote-amount={String(fundQuote()?.amountSats ?? "")}
      data-shadow-latest-token={latestToken()?.token ?? ""}
      data-shadow-latest-receive-amount={String(latestReceive()?.receivedAmountSats ?? "")}
      data-shadow-latest-payment-amount={String(latestPayment()?.amountSats ?? "")}
      data-shadow-latest-payment-state={latestPayment()?.state ?? ""}
      data-shadow-total-balance={String(totalBalanceSats())}
    >
      <section class="wallet-hero">
        <p class="wallet-kicker">Shadow Cashu</p>
        <h1 class="wallet-title">Wallet</h1>
        <p class="wallet-subtitle">
          Mint trust, Lightning funding, token send/receive, and invoice pay in
          one runtime app.
        </p>
        <p class={`wallet-status wallet-status-${status().kind}`}>{status().message}</p>
      </section>

      <Show when={wallets().length > 0}>
        <div class="wallet-mints">
          <For each={wallets()}>
            {(wallet) => (
              <button
                class={`wallet-mint-chip ${
                  wallet.mintUrl === selectedMintUrl()
                    ? "wallet-mint-chip-active"
                    : "wallet-mint-chip-idle"
                }`}
                data-shadow-id={`mint-${wallet.mintUrl}`}
                onClick={() => setSelectedMintUrl(wallet.mintUrl)}
              >
                <span class="wallet-mint-title">{shortMintLabel(wallet.mintUrl)}</span>
                <span class="wallet-mint-balance">{wallet.balanceSats} sats</span>
              </button>
            )}
          </For>
        </div>
      </Show>

      <section class="wallet-grid">
        <div class="wallet-card wallet-card-balance">
          <p class="wallet-section-kicker">Wallet Total</p>
          <div class="wallet-balance-row">
            <h2 class="wallet-balance-value">{String(totalBalanceSats())}</h2>
            <p class="wallet-balance-unit">sats</p>
          </div>
          <p class="wallet-balance-detail">
            <Show
              when={activeWallet()}
              fallback={
                wallets().length === 0
                  ? "Trust a mint to start using the wallet."
                  : "Choose which trusted mint to spend from."
              }
            >
              {activeWallet()?.mintUrl}
            </Show>
          </p>
        </div>

        <div class="wallet-card">
          <p class="wallet-section-kicker">Trust Mint</p>
          <p class="wallet-label">Mint URL</p>
          <input
            class="wallet-input wallet-mono"
            data-shadow-id="cashu-mint-url"
            placeholder="https://mint.example"
            value={mintDraft()}
            onInput={(event) => setMintDraft(event.currentTarget.value)}
          />
          <div class="wallet-toolbar">
            <button
              class="wallet-button wallet-button-primary"
              data-shadow-id="cashu-add-mint"
              disabled={busy()}
              onClick={() => void addMint()}
            >
              Trust Mint
            </button>
          </div>
        </div>

        <div class="wallet-card">
          <p class="wallet-section-kicker">Lightning In</p>
          <p class="wallet-label">Amount to fund in sats</p>
          <input
            class="wallet-input"
            data-shadow-id="cashu-fund-amount"
            inputMode="numeric"
            placeholder="100"
            value={fundAmountDraft()}
            onInput={(event) => setFundAmountDraft(event.currentTarget.value)}
          />
          <div class="wallet-toolbar">
            <button
              class="wallet-button wallet-button-primary"
              data-shadow-id="cashu-create-quote"
              disabled={busy()}
              onClick={() => void createFundingQuote()}
            >
              Create Invoice
            </button>
            <button
              class="wallet-button wallet-button-ghost"
              data-shadow-id="cashu-check-quote"
              disabled={busy() || fundQuote() == null}
              onClick={() => void checkFundingQuote()}
            >
              Check Quote
            </button>
            <button
              class="wallet-button wallet-button-secondary"
              data-shadow-id="cashu-mint-quote"
              disabled={busy() || fundQuote() == null}
              onClick={() => void settleFundingQuote()}
            >
              Mint Paid Quote
            </button>
          </div>
          <Show when={fundQuote()}>
            {(quote) => (
              <>
                <QrCode rows={quote().qrRows} />
                <p class="wallet-payload wallet-mono">{quote().paymentRequest}</p>
                <p class="wallet-balance-detail">{quoteStatusMessage(quote())}</p>
              </>
            )}
          </Show>
        </div>

        <div class="wallet-card">
          <p class="wallet-section-kicker">Cashu Out</p>
          <p class="wallet-label">Amount to send in sats</p>
          <input
            class="wallet-input"
            data-shadow-id="cashu-send-amount"
            inputMode="numeric"
            placeholder="21"
            value={sendAmountDraft()}
            onInput={(event) => setSendAmountDraft(event.currentTarget.value)}
          />
          <div class="wallet-toolbar">
            <button
              class="wallet-button wallet-button-primary"
              data-shadow-id="cashu-send-token"
              disabled={busy()}
              onClick={() => void createSendToken()}
            >
              Create Token
            </button>
          </div>
          <Show when={latestToken()}>
            {(receipt) => (
              <>
                <p class="wallet-payload wallet-mono">{receipt().token}</p>
                <p class="wallet-balance-detail">
                  Sent {receipt().amountSats} sats with {receipt().feeSats} sat fee.
                </p>
              </>
            )}
          </Show>
        </div>

        <div class="wallet-card">
          <p class="wallet-section-kicker">Cashu In</p>
          <p class="wallet-label">Paste a token string</p>
          <input
            class="wallet-input wallet-mono"
            data-shadow-id="cashu-receive-token"
            placeholder="cashuA..."
            value={tokenDraft()}
            onInput={(event) => setTokenDraft(event.currentTarget.value)}
          />
          <div class="wallet-toolbar">
            <button
              class="wallet-button wallet-button-primary"
              data-shadow-id="cashu-receive-submit"
              disabled={busy()}
              onClick={() => void receiveToken()}
            >
              Receive Token
            </button>
          </div>
          <Show when={latestReceive()}>
            {(receipt) => (
              <p class="wallet-balance-detail">
                Received {receipt().receivedAmountSats} sats from{" "}
                {shortMintLabel(receipt().mintUrl)}.
              </p>
            )}
          </Show>
        </div>

        <div class="wallet-card">
          <p class="wallet-section-kicker">Lightning Out</p>
          <p class="wallet-label">Paste a BOLT11 invoice</p>
          <input
            class="wallet-input wallet-mono"
            data-shadow-id="cashu-pay-invoice"
            placeholder="lnbc..."
            value={invoiceDraft()}
            onInput={(event) => setInvoiceDraft(event.currentTarget.value)}
          />
          <div class="wallet-toolbar">
            <button
              class="wallet-button wallet-button-secondary"
              data-shadow-id="cashu-pay-submit"
              disabled={busy()}
              onClick={() => void payInvoice()}
            >
              Pay Invoice
            </button>
          </div>
          <Show when={latestPayment()}>
            {(receipt) => (
              <p class="wallet-balance-detail">
                Paid {receipt().amountSats} sats. Fee paid: {receipt().feePaidSats} sats.
              </p>
            )}
          </Show>
        </div>
      </section>
    </main>
  );
}
