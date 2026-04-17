export function ensureShadowRuntimeOs() {
  return requireShadowOs();
}

export function listKind1(query = {}) {
  return getNostrApi().listKind1(query);
}

export function syncKind1(request = {}) {
  return getNostrApi().syncKind1(request);
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

function requireShadowOs() {
  const os = globalThis.Shadow?.os;
  if (!os) {
    throw new Error("Shadow.os is not installed by the runtime host");
  }
  if (os.audio) {
    installAudioMediaHandlerApi(os.audio);
  }
  return os;
}

function getCameraApi() {
  const camera = requireShadowOs().camera;
  if (!camera) {
    throw new Error("Shadow.os.camera is not installed by the runtime host");
  }
  return camera;
}

function getNostrApi() {
  const nostr = requireShadowOs().nostr;
  if (!nostr) {
    throw new Error("Shadow.os.nostr is not installed by the runtime host");
  }
  return nostr;
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
const AUDIO_MEDIA_ACTIONS = new Set([
  "next",
  "pause",
  "play",
  "play_pause",
  "previous",
  "volume_down",
  "volume_up",
]);

function installAudioMediaHandlerApi(audio) {
  if (audio.__dispatchMediaButton) {
    return audio;
  }
  audio.setMediaButtonHandler = setAudioMediaButtonHandler;
  audio.clearMediaButtonHandler = clearAudioMediaButtonHandler;
  audio.__dispatchMediaButton = dispatchAudioMediaButton;
  return audio;
}

function getAudioMediaHandlerState() {
  if (!globalThis[AUDIO_MEDIA_HANDLER_STATE_KEY]) {
    globalThis[AUDIO_MEDIA_HANDLER_STATE_KEY] = {
      handler: null,
    };
  }
  return globalThis[AUDIO_MEDIA_HANDLER_STATE_KEY];
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
