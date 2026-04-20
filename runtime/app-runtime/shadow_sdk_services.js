/** @typedef {import("./shadow_sdk_nostr.js").NostrAccountSummary} NostrAccountSummary */
/** @typedef {import("./shadow_sdk_nostr.js").NostrEvent} NostrEvent */
/** @typedef {import("./shadow_sdk_nostr.js").NostrQuery} NostrQuery */
/** @typedef {import("./shadow_sdk_nostr.js").NostrReplaceableQuery} NostrReplaceableQuery */
/** @typedef {import("./shadow_sdk_nostr.js").NostrSyncReceipt} NostrSyncReceipt */
/** @typedef {import("./shadow_sdk_nostr.js").NostrSyncRequest} NostrSyncRequest */
/** @typedef {NostrQuery | NostrQuery[] | null | undefined} NostrQueryInput */

export function ensureShadowRuntimeOs() {
  return requireShadowOs();
}

export function writeClipboardText(text) {
  return getClipboardApi().writeText(String(text));
}

export function listKind1(query = {}) {
  return getNostrApi().listKind1(query);
}

/** @returns {NostrAccountSummary | null} */
export function currentNostrAccount() {
  return getNostrApi().currentAccount();
}

/** @returns {NostrAccountSummary} */
export function generateNostrAccount() {
  return getNostrApi().generateAccount();
}

/**
 * @param {string} nsec
 * @returns {NostrAccountSummary}
 */
export function importNostrAccountNsec(nsec) {
  return getNostrApi().importAccountNsec(String(nsec));
}

/**
 * @param {NostrQueryInput} [query={}]
 * @returns {NostrEvent[]}
 */
export function queryNostr(query = {}) {
  return getNostrApi().query(normalizeNostrQuery(query));
}

/**
 * @param {NostrQueryInput} [query={}]
 * @returns {number}
 */
export function countNostr(query = {}) {
  return getNostrApi().count(normalizeNostrQuery(query));
}

/**
 * @param {string} id
 * @returns {NostrEvent | null}
 */
export function getNostrEvent(id) {
  return getNostrApi().getEvent(id);
}

/**
 * @param {NostrReplaceableQuery | number} queryOrKind
 * @param {string} [pubkey]
 * @param {string | undefined} [identifier]
 * @returns {NostrEvent | null}
 */
export function getNostrReplaceable(queryOrKind, pubkey, identifier) {
  if (typeof queryOrKind === "object" && queryOrKind != null) {
    return getNostrApi().getReplaceable(queryOrKind);
  }
  return getNostrApi().getReplaceable({
    kind: Number(queryOrKind),
    pubkey,
    identifier,
  });
}

export function syncKind1(request = {}) {
  return getNostrApi().syncKind1(request);
}

/**
 * @param {NostrSyncRequest} [request={}]
 * @returns {Promise<NostrSyncReceipt>}
 */
export function syncNostr(request = {}) {
  return getNostrApi().sync(request);
}

export function publishKind1(request) {
  return getNostrApi().publishKind1(request);
}

export function publishEphemeralKind1(request) {
  return getNostrApi().publishEphemeralKind1(request);
}

export function listCameras() {
  return getCameraApi().listCameras();
}

export function captureStill(request = {}) {
  return getCameraApi().captureStill(request);
}

export function capturePreviewFrame(request = {}) {
  return getCameraApi().capturePreviewFrame(request);
}

export function logCamera(message) {
  return getCameraApi().debugLog(message);
}

export function decodeQrCode(request = {}) {
  return getCameraApi().decodeQrCode(request);
}

export function createPlayer(request = {}) {
  return getAudioApi().createPlayer(request);
}

export function play(request) {
  return getAudioApi().play(request);
}

export function pause(request) {
  return getAudioApi().pause(request);
}

export function stop(request) {
  return getAudioApi().stop(request);
}

export function release(request) {
  return getAudioApi().release(request);
}

export function getStatus(request) {
  return getAudioApi().getStatus(request);
}

export function seek(request) {
  return getAudioApi().seek(request);
}

export function setVolume(request) {
  return getAudioApi().setVolume(request);
}

export function setMediaButtonHandler(handler) {
  return getAudioApi().setMediaButtonHandler(handler);
}

export function clearMediaButtonHandler() {
  return getAudioApi().clearMediaButtonHandler();
}

export function getLifecycleState() {
  requireShadowOs();
  return getLifecycleStateStore().state;
}

export function getWindowMetrics() {
  requireShadowOs();
  const metrics = getWindowMetricsStore().metrics;
  if (metrics == null) {
    throw new Error("window metrics are not installed by the runtime host");
  }
  return cloneWindowMetrics(metrics);
}

export function setLifecycleHandler(handler) {
  requireShadowOs();
  if (handler != null && typeof handler !== "function") {
    throw new TypeError("lifecycle handler must be a function");
  }
  getLifecycleStateStore().handler = handler ?? null;
}

export function clearLifecycleHandler() {
  requireShadowOs();
  getLifecycleStateStore().handler = null;
}

export function listCashuWallets(request = {}) {
  return getCashuApi().listWallets(request);
}

export function addCashuMint(request = {}) {
  return getCashuApi().addMint(request);
}

export function createCashuMintQuote(request = {}) {
  return getCashuApi().createMintQuote(request);
}

export function checkCashuMintQuote(request = {}) {
  return getCashuApi().checkMintQuote(request);
}

export function settleCashuMintQuote(request = {}) {
  return getCashuApi().settleMintQuote(request);
}

export function receiveCashuToken(request = {}) {
  return getCashuApi().receiveToken(request);
}

export function sendCashuToken(request = {}) {
  return getCashuApi().sendToken(request);
}

export function payCashuInvoice(request = {}) {
  return getCashuApi().payInvoice(request);
}

export const clipboard = Object.freeze({
  writeText: writeClipboardText,
});

export const nostr = Object.freeze({
  currentAccount: currentNostrAccount,
  count: countNostr,
  generateAccount: generateNostrAccount,
  getEvent: getNostrEvent,
  getReplaceable: getNostrReplaceable,
  importAccountNsec: importNostrAccountNsec,
  listKind1,
  publishEphemeralKind1,
  publishKind1,
  query: queryNostr,
  sync: syncNostr,
  syncKind1,
});

function requireShadowOs() {
  const os = globalThis.Shadow?.os;
  if (!os) {
    throw new Error("Shadow.os is not installed by the runtime host");
  }
  if (os.audio) {
    installAudioMediaHandlerApi(os.audio);
  }
  installLifecycleApi();
  return os;
}

function getCameraApi() {
  const camera = requireShadowOs().camera;
  if (!camera) {
    throw new Error("Shadow.os.camera is not installed by the runtime host");
  }
  return camera;
}

function getClipboardApi() {
  const clipboard = requireShadowOs().clipboard;
  if (!clipboard) {
    throw new Error("Shadow.os.clipboard is not installed by the runtime host");
  }
  return clipboard;
}

function getNostrApi() {
  const nostr = requireShadowOs().nostr;
  if (!nostr) {
    throw new Error("Shadow.os.nostr is not installed by the runtime host");
  }
  return nostr;
}

/** @param {NostrQueryInput} query */
/** @returns {NostrQuery} */
function normalizeNostrQuery(query) {
  if (Array.isArray(query)) {
    if (query.length === 0) {
      return {};
    }
    if (query.length === 1) {
      return query[0];
    }
    throw new TypeError(
      "nostr.query currently accepts a single filter object, not multiple filters",
    );
  }
  if (query == null) {
    return {};
  }
  return query;
}

function getAudioApi() {
  const audio = requireShadowOs().audio;
  if (!audio) {
    throw new Error("Shadow.os.audio is not installed by the runtime host");
  }
  return audio;
}

function getCashuApi() {
  const cashu = requireShadowOs().cashu;
  if (!cashu) {
    throw new Error("Shadow.os.cashu is not installed by the runtime host");
  }
  return cashu;
}

const AUDIO_MEDIA_HANDLER_STATE_KEY = Symbol.for(
  "shadow.runtime.audio.media_handler_state",
);
const LIFECYCLE_STATE_KEY = Symbol.for("shadow.runtime.lifecycle.state");
const WINDOW_METRICS_STATE_KEY = Symbol.for("shadow.runtime.window_metrics");
const AUDIO_MEDIA_ACTIONS = new Set([
  "next",
  "pause",
  "play",
  "play_pause",
  "previous",
  "volume_down",
  "volume_up",
]);
const LIFECYCLE_STATES = new Set(["foreground", "background"]);

function installAudioMediaHandlerApi(audio) {
  if (audio.__dispatchMediaButton) {
    return audio;
  }
  audio.setMediaButtonHandler = setAudioMediaButtonHandler;
  audio.clearMediaButtonHandler = clearAudioMediaButtonHandler;
  audio.__dispatchMediaButton = dispatchAudioMediaButton;
  return audio;
}

function installLifecycleApi() {
  const shadow = globalThis.Shadow ?? {};
  if (typeof shadow.__dispatchLifecycleStateChange === "function") {
    return shadow;
  }
  const nextShadow = {
    ...shadow,
    __dispatchLifecycleStateChange: dispatchLifecycleStateChange,
  };
  globalThis.Shadow = nextShadow;
  return nextShadow;
}

function getAudioMediaHandlerState() {
  if (!globalThis[AUDIO_MEDIA_HANDLER_STATE_KEY]) {
    globalThis[AUDIO_MEDIA_HANDLER_STATE_KEY] = {
      handler: null,
    };
  }
  return globalThis[AUDIO_MEDIA_HANDLER_STATE_KEY];
}

function getLifecycleStateStore() {
  if (!globalThis[LIFECYCLE_STATE_KEY]) {
    globalThis[LIFECYCLE_STATE_KEY] = {
      handler: null,
      state: readInitialLifecycleState(),
    };
  }
  return globalThis[LIFECYCLE_STATE_KEY];
}

function getWindowMetricsStore() {
  if (!globalThis[WINDOW_METRICS_STATE_KEY]) {
    const metrics = readInitialWindowMetrics();
    globalThis[WINDOW_METRICS_STATE_KEY] = {
      metrics: metrics == null ? null : freezeWindowMetrics(metrics),
    };
  }
  return globalThis[WINDOW_METRICS_STATE_KEY];
}

function readInitialLifecycleState() {
  const initialState = globalThis.Shadow?.__initialLifecycleState;
  if (typeof initialState !== "string") {
    return "foreground";
  }
  try {
    return normalizeLifecycleState(initialState);
  } catch {
    return "foreground";
  }
}

function readInitialWindowMetrics() {
  const metrics = globalThis.Shadow?.__initialWindowMetrics;
  if (!isPlainObject(metrics)) {
    return null;
  }
  return normalizeWindowMetrics(metrics);
}

function normalizeWindowMetrics(metrics) {
  const safeAreaSource = isPlainObject(metrics.safeAreaInsets)
    ? metrics.safeAreaInsets
    : {};
  return {
    surfaceWidth: normalizeRequiredMetricNumber(
      metrics.surfaceWidth,
      "window metrics surface width",
    ),
    surfaceHeight: normalizeRequiredMetricNumber(
      metrics.surfaceHeight,
      "window metrics surface height",
    ),
    safeAreaInsets: {
      left: normalizeOptionalMetricNumber(safeAreaSource.left),
      top: normalizeOptionalMetricNumber(safeAreaSource.top),
      right: normalizeOptionalMetricNumber(safeAreaSource.right),
      bottom: normalizeOptionalMetricNumber(safeAreaSource.bottom),
    },
  };
}

function normalizeRequiredMetricNumber(value, label) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError(`${label} must be a finite number`);
  }
  const normalized = Math.trunc(value);
  if (normalized <= 0) {
    throw new RangeError(`${label} must be greater than zero`);
  }
  return normalized;
}

function normalizeOptionalMetricNumber(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return 0;
  }
  return Math.max(0, Math.trunc(value));
}

function freezeWindowMetrics(metrics) {
  const safeAreaInsets = Object.freeze({
    left: metrics.safeAreaInsets.left,
    top: metrics.safeAreaInsets.top,
    right: metrics.safeAreaInsets.right,
    bottom: metrics.safeAreaInsets.bottom,
  });
  return Object.freeze({
    surfaceWidth: metrics.surfaceWidth,
    surfaceHeight: metrics.surfaceHeight,
    safeAreaInsets,
  });
}

function cloneWindowMetrics(metrics) {
  return {
    surfaceWidth: metrics.surfaceWidth,
    surfaceHeight: metrics.surfaceHeight,
    safeAreaInsets: {
      left: metrics.safeAreaInsets.left,
      top: metrics.safeAreaInsets.top,
      right: metrics.safeAreaInsets.right,
      bottom: metrics.safeAreaInsets.bottom,
    },
  };
}

function isPlainObject(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

function normalizeAudioMediaAction(action) {
  if (typeof action !== "string") {
    throw new TypeError("audio media action must be a string");
  }
  const normalizedAction = action.trim().toLowerCase().replace(/-/g, "_");
  if (!AUDIO_MEDIA_ACTIONS.has(normalizedAction)) {
    throw new TypeError(
      `unsupported audio media action ${JSON.stringify(action)}`,
    );
  }
  return normalizedAction;
}

function normalizeLifecycleState(state) {
  if (typeof state !== "string") {
    throw new TypeError("lifecycle state must be a string");
  }
  const normalizedState = state.trim().toLowerCase().replace(/-/g, "_");
  if (normalizedState === "running_foreground") {
    return "foreground";
  }
  if (normalizedState === "running_background") {
    return "background";
  }
  if (!LIFECYCLE_STATES.has(normalizedState)) {
    throw new TypeError(
      `unsupported lifecycle state ${JSON.stringify(state)}`,
    );
  }
  return normalizedState;
}

function setAudioMediaButtonHandler(handler) {
  if (handler != null && typeof handler !== "function") {
    throw new TypeError("audio media button handler must be a function");
  }
  getAudioMediaHandlerState().handler = handler ?? null;
}

function clearAudioMediaButtonHandler() {
  getAudioMediaHandlerState().handler = null;
}

async function dispatchAudioMediaButton(action) {
  const handler = getAudioMediaHandlerState().handler;
  if (typeof handler !== "function") {
    return false;
  }
  const handled = await handler({ action: normalizeAudioMediaAction(action) });
  return handled !== false;
}

async function dispatchLifecycleStateChange(state) {
  const normalizedState = normalizeLifecycleState(state);
  const lifecycleState = getLifecycleStateStore();
  lifecycleState.state = normalizedState;
  const handler = lifecycleState.handler;
  if (typeof handler === "function") {
    await handler({ state: normalizedState });
  }
  return true;
}
