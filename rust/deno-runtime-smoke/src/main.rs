use std::env;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use deno_core::FsModuleLoader;
use deno_core::anyhow::{Context, Result, anyhow};
use deno_resolver::npm::ByonmNpmResolver;
use deno_resolver::npm::DenoInNpmPackageChecker;
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

fn main() -> Result<()> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("build tokio runtime")?;
    runtime.block_on(run())
}

async fn run() -> Result<()> {
    let main_module = resolve_main_module()?;
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
    let options = WorkerOptions {
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
    >(&main_module, services, options);

    worker
        .execute_main_module(&main_module)
        .await
        .with_context(|| format!("execute main module {main_module}"))?;
    worker
        .run_event_loop(false)
        .await
        .context("drain runtime event loop after main module")?;

    let value = worker
        .execute_script(
            "<result>",
            String::from("globalThis.RUNTIME_SMOKE_RESULT").into(),
        )
        .context("read runtime smoke result")?;

    deno_core::scope!(scope, &mut worker.js_runtime);
    let local = deno_core::v8::Local::new(scope, value);
    let value = local
        .to_string(scope)
        .ok_or_else(|| anyhow!("runtime smoke result was not a string"))?
        .to_rust_string_lossy(scope);

    println!(
        "deno_runtime ok: target={} module={} result={value}",
        std::env::consts::ARCH,
        main_module
    );
    Ok(())
}

fn resolve_main_module() -> Result<deno_core::url::Url> {
    if let Some(arg) = env::args().nth(1) {
        return resolve_from_cwd(arg);
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
