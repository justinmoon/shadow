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
