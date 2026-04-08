import { core } from "ext:core/mod.js";

function installShadowRuntimeOs() {
  const shadow = globalThis.Shadow ?? {};
  const os = shadow.os ?? {};
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

  globalThis.Shadow = {
    ...shadow,
    os: {
      ...os,
      cashu,
    },
  };
}

installShadowRuntimeOs();
