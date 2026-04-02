use std::env;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use deno_core::FsModuleLoader;
use deno_core::anyhow::{Context, Result, anyhow};
use deno_resolver::npm::ByonmNpmResolver;
use deno_resolver::npm::DenoInNpmPackageChecker;
use serde::{Deserialize, Serialize};
use deno_runtime::BootstrapOptions;
use deno_runtime::FeatureChecker;
use deno_runtime::WorkerExecutionMode;
use deno_runtime::deno_fs::RealFs;
use deno_runtime::deno_permissions::PermissionsContainer;
use deno_runtime::permissions::RuntimePermissionDescriptorParser;
use deno_runtime::worker::MainWorker;
use deno_runtime::worker::WorkerOptions;
use deno_runtime::worker::WorkerServiceOptions;
use sys_traits::impls::RealSys;

static RUNTIME_SNAPSHOT: &[u8] =
    include_bytes!(concat!(env!("OUT_DIR"), "/RUNTIME_SNAPSHOT.bin"));
const DEFAULT_RESULT_EXPR: &str = "globalThis.RUNTIME_SMOKE_RESULT";
const RENDER_EXPR: &str = "globalThis.SHADOW_RUNTIME_HOST.render()";

fn main() -> Result<()> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("build tokio runtime")?;
    runtime.block_on(run())
}

async fn run() -> Result<()> {
    let cli_options = parse_options()?;
    let main_module = resolve_main_module(cli_options.module_path)?;
    let descriptor_parser = Arc::new(RuntimePermissionDescriptorParser::new(
        RealSys::default(),
    ));
    let services = WorkerServiceOptions {
        deno_rt_native_addon_loader: None,
        module_loader: Rc::new(FsModuleLoader),
        permissions: PermissionsContainer::allow_all(descriptor_parser),
        blob_store: Default::default(),
        broadcast_channel: Default::default(),
        feature_checker: Arc::new(FeatureChecker::default()),
        fs: Arc::new(RealFs),
        node_services: None,
        npm_process_state_provider: None,
        root_cert_store_provider: None,
        fetch_dns_resolver: Default::default(),
        shared_array_buffer_store: Default::default(),
        compiled_wasm_module_store: Default::default(),
        v8_code_cache: Default::default(),
        bundle_provider: None,
    };
    let worker_options = WorkerOptions {
        bootstrap: BootstrapOptions {
            mode: WorkerExecutionMode::Run,
            ..Default::default()
        },
        startup_snapshot: Some(RUNTIME_SNAPSHOT),
        ..Default::default()
    };

    let mut worker = MainWorker::bootstrap_from_options::<
        DenoInNpmPackageChecker,
        ByonmNpmResolver<RealSys>,
        RealSys,
    >(&main_module, services, worker_options);

    worker
        .execute_main_module(&main_module)
        .await
        .with_context(|| format!("execute main module {main_module}"))?;
    worker
        .run_event_loop(false)
        .await
        .context("drain runtime event loop after main module")?;

    if cli_options.session {
        return run_session(&mut worker).await;
    }

    let value = execute_string_expr(&mut worker, &cli_options.result_expr, "<result>").await?;

    println!(
        "deno_runtime ok: target={} module={} result={value}",
        std::env::consts::ARCH,
        main_module
    );
    Ok(())
}

async fn run_session(
    worker: &mut MainWorker,
) -> Result<()> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut stdout = stdout.lock();

    for line in stdin.lock().lines() {
        let line = line.context("read session request")?;
        if line.trim().is_empty() {
            continue;
        }

        let response = match serde_json::from_str::<SessionRequest>(&line) {
            Ok(request) => match handle_session_request(worker, request).await {
                Ok(payload) => SessionResponse::Ok { payload },
                Err(error) => SessionResponse::Error {
                    message: error.to_string(),
                },
            },
            Err(error) => SessionResponse::Error {
                message: format!("parse session request: {error}"),
            },
        };

        let encoded =
            serde_json::to_string(&response).context("encode runtime session response")?;
        writeln!(stdout, "{encoded}").context("write runtime session response")?;
        stdout.flush().context("flush runtime session response")?;
    }

    Ok(())
}

async fn handle_session_request(
    worker: &mut MainWorker,
    request: SessionRequest,
) -> Result<RuntimeDocumentPayload> {
    let expr = match request {
        SessionRequest::Render => String::from(RENDER_EXPR),
        SessionRequest::Dispatch { event } => {
            let event_json =
                serde_json::to_string(&event).context("encode runtime dispatch event")?;
            format!("globalThis.SHADOW_RUNTIME_HOST.dispatch({event_json})")
        }
    };

    let payload_json = execute_string_expr(worker, &expr, "<session>").await?;
    serde_json::from_str(&payload_json).context("decode runtime document payload")
}

async fn execute_string_expr(
    worker: &mut MainWorker,
    expr: &str,
    script_name: &'static str,
) -> Result<String> {
    let value = worker
        .execute_script(script_name, expr.to_owned().into())
        .with_context(|| format!("execute script {script_name}"))?;
    worker
        .run_event_loop(false)
        .await
        .with_context(|| format!("drain runtime event loop after {script_name}"))?;

    deno_core::scope!(scope, &mut worker.js_runtime);
    let local = deno_core::v8::Local::new(scope, value);
    let value = local
        .to_string(scope)
        .ok_or_else(|| anyhow!("runtime expression did not evaluate to a string"))?
        .to_rust_string_lossy(scope);

    Ok(value)
}

struct Options {
    module_path: Option<String>,
    result_expr: String,
    session: bool,
}

fn parse_options() -> Result<Options> {
    let mut args = env::args().skip(1);
    let mut module_path = None;
    let mut result_expr = String::from(DEFAULT_RESULT_EXPR);
    let mut session = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--result-expr" => {
                result_expr = args
                    .next()
                    .ok_or_else(|| anyhow!("missing value for --result-expr"))?;
            }
            "--session" => {
                session = true;
            }
            _ if module_path.is_none() => {
                module_path = Some(arg);
            }
            _ => {
                return Err(anyhow!("unknown argument: {arg}"));
            }
        }
    }

    Ok(Options {
        module_path,
        result_expr,
        session,
    })
}

fn resolve_main_module(module_path: Option<String>) -> Result<deno_core::url::Url> {
    if let Some(path) = module_path {
        return resolve_from_cwd(path);
    }

    for candidate in bundled_module_candidates()? {
        if candidate.is_file() {
            return deno_core::url::Url::from_file_path(&candidate)
                .map_err(|_| anyhow!("resolve bundled module path {}", candidate.display()));
        }
    }

    Err(anyhow!(
        "could not find bundled module; pass a path explicitly or run from the package output"
    ))
}

fn resolve_from_cwd(path: String) -> Result<deno_core::url::Url> {
    let cwd = env::current_dir().context("get current working directory")?;
    deno_core::resolve_path(&path, &cwd)
        .with_context(|| format!("resolve module path {path} from {}", cwd.display()))
}

fn bundled_module_candidates() -> Result<Vec<PathBuf>> {
    let current_exe = env::current_exe().context("resolve current executable")?;
    let bundle_from_exe = current_exe
        .parent()
        .and_then(|bin_dir| bin_dir.parent())
        .map(|prefix| prefix.join("lib/deno-runtime-smoke/modules/main.js"));
    let manifest_bundle = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("modules/main.js");

    Ok(bundle_from_exe
        .into_iter()
        .chain(std::iter::once(manifest_bundle))
        .collect())
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum SessionRequest {
    Render,
    Dispatch { event: RuntimeDispatchEvent },
}

#[derive(Debug, Deserialize, Serialize)]
struct RuntimeDispatchEvent {
    #[serde(rename = "targetId")]
    target_id: String,
    #[serde(rename = "type")]
    event_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pointer: Option<RuntimePointerEvent>,
}

#[derive(Debug, Deserialize, Serialize)]
struct RuntimePointerEvent {
    #[serde(rename = "clientX", skip_serializing_if = "Option::is_none")]
    client_x: Option<f32>,
    #[serde(rename = "clientY", skip_serializing_if = "Option::is_none")]
    client_y: Option<f32>,
    #[serde(rename = "isPrimary", skip_serializing_if = "Option::is_none")]
    is_primary: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize)]
struct RuntimeDocumentPayload {
    html: String,
    css: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum SessionResponse {
    Ok { payload: RuntimeDocumentPayload },
    Error { message: String },
}
