import { core } from "ext:core/mod.js";

function installShadowSystemOs() {
  const shadow = globalThis.Shadow ?? {};
  const os = shadow.os ?? {};
  const camera = {
    async listCameras() {
      return await core.ops.op_runtime_camera_list_cameras();
    },
    async captureStill(request = {}) {
      return await core.ops.op_runtime_camera_capture_still(request);
    },
    async capturePreviewFrame(request = {}) {
      return await core.ops.op_runtime_camera_capture_preview_frame(request);
    },
    debugLog(message) {
      core.ops.op_runtime_camera_debug_log(String(message));
    },
    async decodeQrCode(request = {}) {
      return await core.ops.op_runtime_camera_decode_qr_code(request);
    },
  };
  const audio = {
    async createPlayer(request = {}) {
      return core.ops.op_runtime_audio_create_player(request);
    },
    async play(request = {}) {
      return core.ops.op_runtime_audio_play(request);
    },
    async pause(request = {}) {
      return core.ops.op_runtime_audio_pause(request);
    },
    async stop(request = {}) {
      return core.ops.op_runtime_audio_stop(request);
    },
    async release(request = {}) {
      return core.ops.op_runtime_audio_release(request);
    },
    async getStatus(request = {}) {
      return core.ops.op_runtime_audio_get_status(request);
    },
    async seek(request = {}) {
      return core.ops.op_runtime_audio_seek(request);
    },
    async setVolume(request = {}) {
      return core.ops.op_runtime_audio_set_volume(request);
    },
  };
  const cashu = {
    async listWallets(request = {}) {
      return await core.ops.op_runtime_cashu_list_wallets(request);
    },
    async addMint(request = {}) {
      return await core.ops.op_runtime_cashu_add_mint(request);
    },
    async createMintQuote(request = {}) {
      return await core.ops.op_runtime_cashu_create_mint_quote(request);
    },
    async checkMintQuote(request = {}) {
      return await core.ops.op_runtime_cashu_check_mint_quote(request);
    },
    async settleMintQuote(request = {}) {
      return await core.ops.op_runtime_cashu_settle_mint_quote(request);
    },
    async receiveToken(request = {}) {
      return await core.ops.op_runtime_cashu_receive_token(request);
    },
    async sendToken(request = {}) {
      return await core.ops.op_runtime_cashu_send_token(request);
    },
    async payInvoice(request = {}) {
      return await core.ops.op_runtime_cashu_pay_invoice(request);
    },
  };
  const nostr = {
    currentAccount() {
      return core.ops.op_runtime_nostr_current_account();
    },
    generateAccount() {
      return core.ops.op_runtime_nostr_generate_account();
    },
    importAccountNsec(nsec) {
      return core.ops.op_runtime_nostr_import_account_nsec(String(nsec));
    },
    query(query = {}) {
      return core.ops.op_runtime_nostr_query(normalizeQuery(query));
    },
    count(query = {}) {
      return core.ops.op_runtime_nostr_count(normalizeQuery(query));
    },
    getEvent(id) {
      return core.ops.op_runtime_nostr_get_event(String(id));
    },
    getReplaceable(query = {}) {
      return core.ops.op_runtime_nostr_get_replaceable(query);
    },
    listKind1(query = {}) {
      return core.ops.op_runtime_nostr_list_kind1(query);
    },
    sync(request = {}) {
      return core.ops.op_runtime_nostr_sync({
        ...normalizeQuery(request),
        relayUrls: request?.relayUrls,
        timeoutMs: request?.timeoutMs,
      });
    },
    syncKind1(request = {}) {
      return core.ops.op_runtime_nostr_sync_kind1(request);
    },
    publishKind1(request = {}) {
      return core.ops.op_runtime_nostr_publish_kind1(request);
    },
    async publishEphemeralKind1(request = {}) {
      return await core.ops.op_runtime_nostr_publish_ephemeral_kind1(request);
    },
  };

  globalThis.Shadow = {
    ...shadow,
    os: {
      ...os,
      audio,
      camera,
      cashu,
      nostr,
    },
  };
}

function normalizeQuery(query) {
  if (Array.isArray(query)) {
    if (query.length === 0) {
      return {};
    }
    if (query.length === 1) {
      return query[0];
    }
    throw new TypeError(
      "Shadow.os.nostr.query currently accepts a single filter object",
    );
  }
  if (query == null) {
    return {};
  }
  return query;
}

installShadowSystemOs();
