use std::{
    cell::RefCell, collections::HashMap, fs, path::PathBuf, rc::Rc, str::FromStr, sync::Arc,
    time::Duration,
};

use bip39::Mnemonic;
use cdk::{
    amount::SplitTarget,
    cdk_database,
    mint_url::MintUrl,
    nuts::{
        nut00::KnownMethod, nut00::ProofsMethods, CurrencyUnit, MeltOptions, PaymentMethod, Token,
    },
    wallet::{ReceiveOptions, SendOptions, Wallet, WalletRepository, WalletRepositoryBuilder},
    Amount,
};
use cdk_redb::WalletRedbDatabase;
use deno_core::{extension, op2, Extension, OpState};
use deno_error::JsErrorBox;
use getrandom::getrandom;
use qrcodegen::{QrCode, QrCodeEcc};
use serde::{Deserialize, Serialize};

const CASHU_DATA_DIR_ENV: &str = "SHADOW_RUNTIME_CASHU_DATA_DIR";
const DEFAULT_CASHU_DATA_DIR: &str = "build/runtime/cashu-dev";
const CASHU_DB_NAME: &str = "wallet.redb";
const CASHU_MNEMONIC_NAME: &str = "mnemonic.txt";
const DEFAULT_SETTLE_TIMEOUT_MS: u64 = 1_000;
const SATS_PER_BTC_MSAT: u64 = 1_000;
type CashuLocalstore = Arc<dyn cdk_database::WalletDatabase<cdk_database::Error> + Send + Sync>;

#[derive(Debug, Clone)]
struct CashuPaths {
    db_path: PathBuf,
    mnemonic_path: PathBuf,
}

#[derive(Clone)]
struct CashuRuntimeService {
    localstore: CashuLocalstore,
    repository: WalletRepository,
}

impl std::fmt::Debug for CashuRuntimeService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CashuRuntimeService")
            .finish_non_exhaustive()
    }
}

#[derive(Debug)]
struct CashuHostState {
    paths: Result<CashuPaths, String>,
    service: Option<CashuRuntimeService>,
    service_error: Option<String>,
}

impl CashuHostState {
    fn from_env() -> Self {
        Self {
            paths: CashuPaths::from_env(),
            service: None,
            service_error: None,
        }
    }
}

impl CashuPaths {
    fn from_env() -> Result<Self, String> {
        let data_dir = std::env::var(CASHU_DATA_DIR_ENV)
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(DEFAULT_CASHU_DATA_DIR));
        fs::create_dir_all(&data_dir).map_err(|error| {
            format!(
                "cashu runtime host: create data dir {}: {error}",
                data_dir.display()
            )
        })?;
        Ok(Self {
            db_path: data_dir.join(CASHU_DB_NAME),
            mnemonic_path: data_dir.join(CASHU_MNEMONIC_NAME),
        })
    }

    fn load_or_create_seed(&self) -> Result<[u8; 64], String> {
        if self.mnemonic_path.is_file() {
            let contents = fs::read_to_string(&self.mnemonic_path).map_err(|error| {
                format!(
                    "cashu runtime host: read mnemonic {}: {error}",
                    self.mnemonic_path.display()
                )
            })?;
            let mnemonic = Mnemonic::from_str(contents.trim()).map_err(|error| {
                format!(
                    "cashu runtime host: parse mnemonic {}: {error}",
                    self.mnemonic_path.display()
                )
            })?;
            return Ok(mnemonic.to_seed_normalized(""));
        }

        let mut entropy = [0_u8; 16];
        getrandom(&mut entropy)
            .map_err(|error| format!("cashu runtime host: generate mnemonic entropy: {error}"))?;
        let mnemonic = Mnemonic::from_entropy(&entropy)
            .map_err(|error| format!("cashu runtime host: create mnemonic: {error}"))?;
        fs::write(&self.mnemonic_path, format!("{mnemonic}\n")).map_err(|error| {
            format!(
                "cashu runtime host: write mnemonic {}: {error}",
                self.mnemonic_path.display()
            )
        })?;
        Ok(mnemonic.to_seed_normalized(""))
    }

    fn open_localstore(&self) -> Result<CashuLocalstore, String> {
        Ok(Arc::new(WalletRedbDatabase::new(&self.db_path).map_err(
            |error| {
                format!(
                    "cashu runtime host: open wallet db {}: {error}",
                    self.db_path.display()
                )
            },
        )?))
    }

    async fn load_service(&self) -> Result<CashuRuntimeService, String> {
        let localstore = self.open_localstore()?;
        let seed = self.load_or_create_seed()?;
        let repository = WalletRepositoryBuilder::new()
            .localstore(localstore.clone())
            .seed(seed)
            .build()
            .await
            .map_err(|error| format!("cashu runtime host: build wallet repository: {error}"))?;

        for wallet in repository.get_wallets().await {
            wallet.recover_incomplete_sagas().await.map_err(|error| {
                format!("cashu runtime host: recover incomplete sagas: {error}")
            })?;
        }

        Ok(CashuRuntimeService {
            localstore,
            repository,
        })
    }
}

async fn load_cashu_service(
    state: Rc<RefCell<OpState>>,
) -> Result<CashuRuntimeService, JsErrorBox> {
    let paths = {
        let mut state_ref = state.borrow_mut();
        let host_state = state_ref.borrow_mut::<CashuHostState>();
        if let Some(service) = host_state.service.clone() {
            return Ok(service);
        }
        if let Some(error) = host_state.service_error.clone() {
            return Err(JsErrorBox::generic(error));
        }
        host_state.paths.clone().map_err(JsErrorBox::generic)?
    };

    match paths.load_service().await {
        Ok(service) => {
            let mut state_ref = state.borrow_mut();
            state_ref.borrow_mut::<CashuHostState>().service = Some(service.clone());
            Ok(service)
        }
        Err(error) => {
            let mut state_ref = state.borrow_mut();
            state_ref.borrow_mut::<CashuHostState>().service_error = Some(error.clone());
            Err(JsErrorBox::generic(error))
        }
    }
}

#[derive(Debug, Default, Deserialize)]
struct ListWalletsRequest {}

#[derive(Debug, Deserialize)]
struct AddMintRequest {
    #[serde(rename = "mintUrl")]
    mint_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateMintQuoteRequest {
    #[serde(rename = "mintUrl")]
    mint_url: Option<String>,
    #[serde(rename = "amountSats")]
    amount_sats: Option<u64>,
    description: Option<String>,
}

#[derive(Debug, Deserialize)]
struct QuoteLookupRequest {
    #[serde(rename = "mintUrl")]
    mint_url: Option<String>,
    #[serde(rename = "quoteId")]
    quote_id: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct SettleMintQuoteRequest {
    #[serde(rename = "mintUrl")]
    mint_url: Option<String>,
    #[serde(rename = "quoteId")]
    quote_id: Option<String>,
    #[serde(rename = "timeoutMs")]
    timeout_ms: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct ReceiveTokenRequest {
    token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SendTokenRequest {
    #[serde(rename = "mintUrl")]
    mint_url: Option<String>,
    #[serde(rename = "amountSats")]
    amount_sats: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
struct PayInvoiceRequest {
    #[serde(rename = "mintUrl")]
    mint_url: Option<String>,
    invoice: Option<String>,
    #[serde(rename = "amountSats")]
    amount_sats: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
struct WalletSummary {
    #[serde(rename = "mintUrl")]
    mint_url: String,
    unit: String,
    #[serde(rename = "balanceSats")]
    balance_sats: u64,
}

#[derive(Debug, Clone, Serialize)]
struct MintQuoteReceipt {
    #[serde(rename = "mintUrl")]
    mint_url: String,
    #[serde(rename = "quoteId")]
    quote_id: String,
    #[serde(rename = "paymentRequest")]
    payment_request: String,
    state: String,
    #[serde(rename = "amountSats")]
    amount_sats: Option<u64>,
    expiry: u64,
    #[serde(rename = "qrRows")]
    qr_rows: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct SettledMintQuoteReceipt {
    #[serde(rename = "mintUrl")]
    mint_url: String,
    #[serde(rename = "quoteId")]
    quote_id: String,
    state: String,
    #[serde(rename = "mintedAmountSats")]
    minted_amount_sats: u64,
    #[serde(rename = "balanceSats")]
    balance_sats: u64,
}

#[derive(Debug, Clone, Serialize)]
struct ReceiveTokenReceipt {
    #[serde(rename = "mintUrl")]
    mint_url: String,
    #[serde(rename = "receivedAmountSats")]
    received_amount_sats: u64,
    #[serde(rename = "balanceSats")]
    balance_sats: u64,
}

#[derive(Debug, Clone, Serialize)]
struct SendTokenReceipt {
    #[serde(rename = "mintUrl")]
    mint_url: String,
    token: String,
    #[serde(rename = "amountSats")]
    amount_sats: u64,
    #[serde(rename = "feeSats")]
    fee_sats: u64,
    #[serde(rename = "balanceSats")]
    balance_sats: u64,
}

#[derive(Debug, Clone, Serialize)]
struct PayInvoiceReceipt {
    #[serde(rename = "mintUrl")]
    mint_url: String,
    #[serde(rename = "quoteId")]
    quote_id: String,
    state: String,
    #[serde(rename = "amountSats")]
    amount_sats: u64,
    #[serde(rename = "feeReserveSats")]
    fee_reserve_sats: u64,
    #[serde(rename = "feePaidSats")]
    fee_paid_sats: u64,
    #[serde(rename = "paymentProof")]
    payment_proof: Option<String>,
    #[serde(rename = "balanceSats")]
    balance_sats: u64,
}

#[op2]
#[serde]
async fn op_runtime_cashu_list_wallets(
    state: Rc<RefCell<OpState>>,
    #[serde] _request: ListWalletsRequest,
) -> Result<Vec<WalletSummary>, JsErrorBox> {
    let service = load_cashu_service(state).await?;
    list_wallets(&service.repository)
        .await
        .map_err(JsErrorBox::generic)
}

#[op2]
#[serde]
async fn op_runtime_cashu_add_mint(
    state: Rc<RefCell<OpState>>,
    #[serde] request: AddMintRequest,
) -> Result<WalletSummary, JsErrorBox> {
    let service = load_cashu_service(state).await?;
    let mint_url = parse_required_mint_url(request.mint_url.as_deref(), "cashu.addMint")?;
    service
        .localstore
        .add_mint(mint_url.clone(), None)
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.addMint persist mint: {error}")))?;
    service
        .repository
        .add_wallet(mint_url.clone())
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.addMint load wallet: {error}")))?;
    let wallet = service
        .repository
        .get_wallet(&mint_url, &CurrencyUnit::Sat)
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.addMint sats wallet: {error}")))?;
    wallet_summary(&wallet).await.map_err(JsErrorBox::generic)
}

#[op2]
#[serde]
async fn op_runtime_cashu_create_mint_quote(
    state: Rc<RefCell<OpState>>,
    #[serde] request: CreateMintQuoteRequest,
) -> Result<MintQuoteReceipt, JsErrorBox> {
    let service = load_cashu_service(state).await?;
    let mint_url = parse_required_mint_url(request.mint_url.as_deref(), "cashu.createMintQuote")?;
    let amount_sats = request
        .amount_sats
        .filter(|amount| *amount > 0)
        .ok_or_else(|| JsErrorBox::type_error("cashu.createMintQuote requires amountSats > 0"))?;
    let wallet = get_or_create_wallet(&service.repository, &mint_url)
        .await
        .map_err(JsErrorBox::generic)?;
    let quote = wallet
        .mint_quote(
            PaymentMethod::Known(KnownMethod::Bolt11),
            Some(Amount::from(amount_sats)),
            request.description,
            None,
        )
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.createMintQuote: {error}")))?;
    mint_quote_receipt(&mint_url, &quote).map_err(JsErrorBox::generic)
}

#[op2]
#[serde]
async fn op_runtime_cashu_check_mint_quote(
    state: Rc<RefCell<OpState>>,
    #[serde] request: QuoteLookupRequest,
) -> Result<MintQuoteReceipt, JsErrorBox> {
    let service = load_cashu_service(state).await?;
    let quote_id = require_non_empty(
        request.quote_id.as_deref(),
        "cashu.checkMintQuote requires quoteId",
    )?;
    let mint_url = resolve_mint_url(&service.repository, request.mint_url.as_deref())
        .await
        .map_err(JsErrorBox::generic)?;
    let wallet = get_or_create_wallet(&service.repository, &mint_url)
        .await
        .map_err(JsErrorBox::generic)?;
    let quote = wallet
        .check_mint_quote_status(&quote_id)
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.checkMintQuote: {error}")))?;
    mint_quote_receipt(&mint_url, &quote).map_err(JsErrorBox::generic)
}

#[op2]
#[serde]
async fn op_runtime_cashu_settle_mint_quote(
    state: Rc<RefCell<OpState>>,
    #[serde] request: SettleMintQuoteRequest,
) -> Result<SettledMintQuoteReceipt, JsErrorBox> {
    let service = load_cashu_service(state).await?;
    let quote_id = require_non_empty(
        request.quote_id.as_deref(),
        "cashu.settleMintQuote requires quoteId",
    )?;
    let timeout_ms = request
        .timeout_ms
        .filter(|timeout| *timeout > 0)
        .unwrap_or(DEFAULT_SETTLE_TIMEOUT_MS);
    let mint_url = resolve_mint_url(&service.repository, request.mint_url.as_deref())
        .await
        .map_err(JsErrorBox::generic)?;
    let wallet = get_or_create_wallet(&service.repository, &mint_url)
        .await
        .map_err(JsErrorBox::generic)?;
    let quote = wallet
        .localstore
        .get_mint_quote(&quote_id)
        .await
        .map_err(|error| {
            JsErrorBox::generic(format!(
                "cashu.settleMintQuote load quote {quote_id}: {error}"
            ))
        })?
        .ok_or_else(|| {
            JsErrorBox::generic(format!("cashu.settleMintQuote unknown quoteId {quote_id}"))
        })?;
    let proofs = wallet
        .wait_and_mint_quote(
            quote,
            SplitTarget::default(),
            None,
            Duration::from_millis(timeout_ms),
        )
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.settleMintQuote: {error}")))?;
    let quote = wallet
        .check_mint_quote_status(&quote_id)
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.settleMintQuote refresh: {error}")))?;
    let balance = wallet
        .total_balance()
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.settleMintQuote balance: {error}")))?;

    Ok(SettledMintQuoteReceipt {
        mint_url: mint_url.to_string(),
        quote_id,
        state: cashu_state_label(&quote.state),
        minted_amount_sats: amount_to_u64(proofs.total_amount().map_err(|error| {
            JsErrorBox::generic(format!("cashu.settleMintQuote total proofs: {error}"))
        })?),
        balance_sats: amount_to_u64(balance),
    })
}

#[op2]
#[serde]
async fn op_runtime_cashu_receive_token(
    state: Rc<RefCell<OpState>>,
    #[serde] request: ReceiveTokenRequest,
) -> Result<ReceiveTokenReceipt, JsErrorBox> {
    let service = load_cashu_service(state).await?;
    let token_str = require_non_empty(
        request.token.as_deref(),
        "cashu.receiveToken requires token",
    )?;
    let token = Token::from_str(&token_str).map_err(|error| {
        JsErrorBox::type_error(format!("cashu.receiveToken invalid token: {error}"))
    })?;
    let mint_url = token.mint_url().map_err(|error| {
        JsErrorBox::type_error(format!("cashu.receiveToken token mint url: {error}"))
    })?;
    if !service.repository.has_mint(&mint_url).await {
        return Err(JsErrorBox::type_error(format!(
            "cashu.receiveToken mint {} is not trusted yet",
            mint_url
        )));
    }
    let wallet = get_or_create_wallet(&service.repository, &mint_url)
        .await
        .map_err(JsErrorBox::generic)?;
    let received = wallet
        .receive(&token_str, ReceiveOptions::default())
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.receiveToken: {error}")))?;
    let balance = wallet
        .total_balance()
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.receiveToken balance: {error}")))?;

    Ok(ReceiveTokenReceipt {
        mint_url: mint_url.to_string(),
        received_amount_sats: amount_to_u64(received),
        balance_sats: amount_to_u64(balance),
    })
}

#[op2]
#[serde]
async fn op_runtime_cashu_send_token(
    state: Rc<RefCell<OpState>>,
    #[serde] request: SendTokenRequest,
) -> Result<SendTokenReceipt, JsErrorBox> {
    let service = load_cashu_service(state).await?;
    let amount_sats = request
        .amount_sats
        .filter(|amount| *amount > 0)
        .ok_or_else(|| JsErrorBox::type_error("cashu.sendToken requires amountSats > 0"))?;
    let mint_url = resolve_mint_url(&service.repository, request.mint_url.as_deref())
        .await
        .map_err(JsErrorBox::generic)?;
    let wallet = get_or_create_wallet(&service.repository, &mint_url)
        .await
        .map_err(JsErrorBox::generic)?;
    let prepared = wallet
        .prepare_send(Amount::from(amount_sats), SendOptions::default())
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.sendToken: {error}")))?;
    let fee_sats = amount_to_u64(prepared.fee());
    let token = prepared
        .confirm(None)
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.sendToken confirm: {error}")))?;
    let balance = wallet
        .total_balance()
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.sendToken balance: {error}")))?;

    Ok(SendTokenReceipt {
        mint_url: mint_url.to_string(),
        token: token.to_string(),
        amount_sats,
        fee_sats,
        balance_sats: amount_to_u64(balance),
    })
}

#[op2]
#[serde]
async fn op_runtime_cashu_pay_invoice(
    state: Rc<RefCell<OpState>>,
    #[serde] request: PayInvoiceRequest,
) -> Result<PayInvoiceReceipt, JsErrorBox> {
    let service = load_cashu_service(state).await?;
    let invoice = require_non_empty(
        request.invoice.as_deref(),
        "cashu.payInvoice requires invoice",
    )?;
    let mint_url = resolve_mint_url(&service.repository, request.mint_url.as_deref())
        .await
        .map_err(JsErrorBox::generic)?;
    let wallet = get_or_create_wallet(&service.repository, &mint_url)
        .await
        .map_err(JsErrorBox::generic)?;
    let options = request
        .amount_sats
        .filter(|amount| *amount > 0)
        .map(|amount_sats| MeltOptions::new_amountless(amount_sats * SATS_PER_BTC_MSAT));
    let quote = wallet
        .melt_quote(
            PaymentMethod::Known(KnownMethod::Bolt11),
            invoice,
            options,
            None,
        )
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.payInvoice quote: {error}")))?;
    let finalized = wallet
        .prepare_melt(&quote.id, HashMap::new())
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.payInvoice prepare: {error}")))?
        .confirm()
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.payInvoice confirm: {error}")))?;
    let balance = wallet
        .total_balance()
        .await
        .map_err(|error| JsErrorBox::generic(format!("cashu.payInvoice balance: {error}")))?;

    Ok(PayInvoiceReceipt {
        mint_url: mint_url.to_string(),
        quote_id: quote.id,
        state: cashu_state_label(&finalized.state()),
        amount_sats: amount_to_u64(finalized.amount()),
        fee_reserve_sats: amount_to_u64(quote.fee_reserve),
        fee_paid_sats: amount_to_u64(finalized.fee_paid()),
        payment_proof: finalized.payment_proof().map(ToOwned::to_owned),
        balance_sats: amount_to_u64(balance),
    })
}

async fn list_wallets(repository: &WalletRepository) -> Result<Vec<WalletSummary>, String> {
    let mut summaries = Vec::new();
    for wallet in repository.get_wallets().await {
        summaries.push(wallet_summary(&wallet).await?);
    }
    summaries.sort_by(|left, right| left.mint_url.cmp(&right.mint_url));
    Ok(summaries)
}

async fn wallet_summary(wallet: &Wallet) -> Result<WalletSummary, String> {
    let balance = wallet
        .total_balance()
        .await
        .map_err(|error| format!("cashu.listWallets balance {}: {error}", wallet.mint_url))?;
    Ok(WalletSummary {
        mint_url: wallet.mint_url.to_string(),
        unit: wallet.unit.to_string(),
        balance_sats: amount_to_u64(balance),
    })
}

async fn get_or_create_wallet(
    repository: &WalletRepository,
    mint_url: &MintUrl,
) -> Result<Wallet, String> {
    match repository.get_wallet(mint_url, &CurrencyUnit::Sat).await {
        Ok(wallet) => Ok(wallet),
        Err(_) => repository
            .create_wallet(mint_url.clone(), CurrencyUnit::Sat, None)
            .await
            .map_err(|error| format!("cashu wallet {}: {error}", mint_url)),
    }
}

async fn resolve_mint_url(
    repository: &WalletRepository,
    requested: Option<&str>,
) -> Result<MintUrl, String> {
    if let Some(requested) = requested {
        return parse_required_mint_url(Some(requested), "cashu request")
            .map_err(|error| error.to_string());
    }

    let wallets = repository.get_wallets().await;
    match wallets.as_slice() {
        [] => Err(String::from(
            "cashu request requires mintUrl because no trusted mint exists yet",
        )),
        [wallet] => Ok(wallet.mint_url.clone()),
        _ => Err(String::from(
            "cashu request requires mintUrl when multiple trusted mints exist",
        )),
    }
}

fn parse_required_mint_url(value: Option<&str>, action: &str) -> Result<MintUrl, JsErrorBox> {
    let value = require_non_empty(value, &format!("{action} requires mintUrl"))?;
    MintUrl::from_str(&value)
        .map_err(|error| JsErrorBox::type_error(format!("{action} invalid mintUrl: {error}")))
}

fn require_non_empty(value: Option<&str>, message: &str) -> Result<String, JsErrorBox> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| JsErrorBox::type_error(message.to_string()))
}

fn mint_quote_receipt(
    mint_url: &MintUrl,
    quote: &cdk::wallet::MintQuote,
) -> Result<MintQuoteReceipt, String> {
    Ok(MintQuoteReceipt {
        mint_url: mint_url.to_string(),
        quote_id: quote.id.clone(),
        payment_request: quote.request.clone(),
        state: cashu_state_label(&quote.state),
        amount_sats: quote.amount.map(amount_to_u64),
        expiry: quote.expiry,
        qr_rows: build_qr_rows(&quote.request)?,
    })
}

fn build_qr_rows(data: &str) -> Result<Vec<String>, String> {
    let qr = QrCode::encode_text(data, QrCodeEcc::Medium)
        .map_err(|error| format!("cashu runtime host: generate QR: {error:?}"))?;
    let size = qr.size();
    let mut rows = Vec::with_capacity(size as usize);
    for y in 0..size {
        let mut row = String::with_capacity(size as usize);
        for x in 0..size {
            row.push(if qr.get_module(x, y) { '1' } else { '0' });
        }
        rows.push(row);
    }
    Ok(rows)
}

fn amount_to_u64(amount: Amount) -> u64 {
    u64::from(amount)
}

fn cashu_state_label<T: std::fmt::Debug>(state: &T) -> String {
    format!("{state:?}").to_ascii_lowercase()
}

extension!(
    runtime_cashu_host_extension,
    ops = [
        op_runtime_cashu_list_wallets,
        op_runtime_cashu_add_mint,
        op_runtime_cashu_create_mint_quote,
        op_runtime_cashu_check_mint_quote,
        op_runtime_cashu_settle_mint_quote,
        op_runtime_cashu_receive_token,
        op_runtime_cashu_send_token,
        op_runtime_cashu_pay_invoice
    ],
    state = |state| {
        state.put(CashuHostState::from_env());
    },
);

pub fn init_extension() -> Extension {
    runtime_cashu_host_extension::init()
}
