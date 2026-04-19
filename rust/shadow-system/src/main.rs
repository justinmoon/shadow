use std::env;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::rc::Rc;

mod runtime_extensions;
mod services;

use deno_core::anyhow::{anyhow, Context, Result};
use deno_core::url::Url;
use deno_core::v8;
use deno_core::{FsModuleLoader, JsRuntime, PollEventLoopOptions, RuntimeOptions};
use shadow_runtime_protocol::{RuntimeDocumentPayload, SessionRequest, SessionResponse};
use shadow_sdk::app::app_window_metrics_from_env;

const APP_LIFECYCLE_STATE_ENV: &str = shadow_sdk::app::APP_LIFECYCLE_STATE_ENV;
const RENDER_EXPR: &str = "globalThis.SHADOW_SYSTEM.render()";
const RENDER_IF_DIRTY_EXPR: &str = "globalThis.SHADOW_SYSTEM.renderIfDirty()";
const SESSION_USAGE: &str = "usage: shadow-system --session <bundle-path>";

fn main() -> Result<()> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("build tokio runtime")?;
    runtime.block_on(run())
}

async fn run() -> Result<()> {
    let session_module_path = parse_session_module_path()?;
    configure_runtime_bundle_dir(&session_module_path)?;
    let main_module = resolve_main_module(session_module_path)?;
    let mut runtime = load_runtime(&main_module).await?;
    run_session(&mut runtime).await
}

fn configure_runtime_bundle_dir(session_module_path: &str) -> Result<()> {
    if env::var_os("SHADOW_RUNTIME_BUNDLE_DIR").is_some() {
        return Ok(());
    }

    let cwd = env::current_dir().context("get current working directory")?;
    let bundle_path = if PathBuf::from(session_module_path).is_absolute() {
        PathBuf::from(session_module_path)
    } else {
        cwd.join(session_module_path)
    };
    let bundle_dir = bundle_path
        .parent()
        .ok_or_else(|| anyhow!("runtime session bundle path has no parent directory"))?;
    env::set_var("SHADOW_RUNTIME_BUNDLE_DIR", bundle_dir);
    Ok(())
}

async fn load_runtime(main_module: &Url) -> Result<JsRuntime> {
    let mut runtime = JsRuntime::new(RuntimeOptions {
        module_loader: Some(Rc::new(FsModuleLoader)),
        extensions: runtime_extensions::runtime_extensions(),
        ..Default::default()
    });
    seed_initial_lifecycle_state(&mut runtime)?;
    seed_initial_window_metrics(&mut runtime)?;

    let module_id = runtime
        .load_main_es_module(main_module)
        .await
        .with_context(|| format!("load module {main_module}"))?;
    let evaluation = runtime.mod_evaluate(module_id);
    runtime
        .run_event_loop(PollEventLoopOptions::default())
        .await
        .context("run deno_core event loop")?;
    evaluation.await.context("evaluate module")?;
    Ok(runtime)
}

fn seed_initial_lifecycle_state(runtime: &mut JsRuntime) -> Result<()> {
    let Some(script) = initial_lifecycle_bootstrap_script()? else {
        return Ok(());
    };

    runtime
        .execute_script("<lifecycle-bootstrap>".to_owned(), script)
        .context("seed initial lifecycle state")?;
    Ok(())
}

fn seed_initial_window_metrics(runtime: &mut JsRuntime) -> Result<()> {
    let Some(script) = initial_window_metrics_bootstrap_script()? else {
        return Ok(());
    };

    runtime
        .execute_script("<window-metrics-bootstrap>".to_owned(), script)
        .context("seed initial window metrics")?;
    Ok(())
}

fn initial_lifecycle_bootstrap_script() -> Result<Option<String>> {
    let Some(state) = env::var(APP_LIFECYCLE_STATE_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };

    let encoded = serde_json::to_string(&state).context("encode initial lifecycle state")?;
    Ok(Some(format!(
        "globalThis.Shadow = {{ ...(globalThis.Shadow ?? {{}}), __initialLifecycleState: {encoded} }};"
    )))
}

fn initial_window_metrics_bootstrap_script() -> Result<Option<String>> {
    let Some(metrics) = app_window_metrics_from_env() else {
        return Ok(None);
    };

    let encoded = serde_json::json!({
        "surfaceWidth": metrics.surface_width,
        "surfaceHeight": metrics.surface_height,
        "safeAreaInsets": {
            "left": metrics.safe_area_insets.left,
            "top": metrics.safe_area_insets.top,
            "right": metrics.safe_area_insets.right,
            "bottom": metrics.safe_area_insets.bottom,
        },
    });
    let encoded = serde_json::to_string(&encoded).context("encode initial window metrics")?;
    Ok(Some(format!(
        "globalThis.Shadow = {{ ...(globalThis.Shadow ?? {{}}), __initialWindowMetrics: {encoded} }};"
    )))
}

async fn run_session(runtime: &mut JsRuntime) -> Result<()> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut stdout = stdout.lock();

    for line in stdin.lock().lines() {
        let line = line.context("read session request")?;
        if line.trim().is_empty() {
            continue;
        }

        let response = match serde_json::from_str::<SessionRequest>(&line) {
            Ok(request) => match handle_session_request(runtime, request).await {
                Ok(Some(payload)) => SessionResponse::Ok { payload },
                Ok(None) => SessionResponse::NoUpdate,
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
    runtime: &mut JsRuntime,
    request: SessionRequest,
) -> Result<Option<RuntimeDocumentPayload>> {
    if matches!(request, SessionRequest::RenderIfDirty) {
        runtime
            .run_event_loop(PollEventLoopOptions::default())
            .await
            .context("run deno_core event loop for dirty render")?;
    }

    let expr = match &request {
        SessionRequest::Render => String::from(RENDER_EXPR),
        SessionRequest::RenderIfDirty => String::from(RENDER_IF_DIRTY_EXPR),
        SessionRequest::Dispatch { event } => {
            let event_json =
                serde_json::to_string(&event).context("encode runtime dispatch event")?;
            format!("globalThis.SHADOW_SYSTEM.dispatch({event_json})")
        }
        SessionRequest::PlatformAudioControl { action } => {
            let action_json =
                serde_json::to_string(&action).context("encode runtime audio control action")?;
            format!("globalThis.SHADOW_SYSTEM.platformAudioControl({action_json})")
        }
        SessionRequest::PlatformLifecycleChange { state } => {
            let state_json =
                serde_json::to_string(&state).context("encode runtime lifecycle state")?;
            format!("globalThis.SHADOW_SYSTEM.platformLifecycleChange({state_json})")
        }
    };

    let payload_json = execute_string_expr(runtime, &expr, "<session>").await?;
    match request {
        SessionRequest::RenderIfDirty => {
            serde_json::from_str(&payload_json).context("decode maybe runtime document payload")
        }
        SessionRequest::Render | SessionRequest::Dispatch { .. } => {
            serde_json::from_str::<RuntimeDocumentPayload>(&payload_json)
                .map(Some)
                .context("decode runtime document payload")
        }
        SessionRequest::PlatformAudioControl { .. }
        | SessionRequest::PlatformLifecycleChange { .. } => serde_json::from_str(&payload_json)
            .context("decode maybe runtime document payload for platform event"),
    }
}

async fn execute_string_expr(
    runtime: &mut JsRuntime,
    expr: &str,
    script_name: &str,
) -> Result<String> {
    let value = runtime
        .execute_script(script_name.to_owned(), expr.to_owned())
        .with_context(|| format!("execute script {script_name}"))?;
    #[allow(deprecated)]
    let value = runtime
        .resolve_value(value)
        .await
        .with_context(|| format!("resolve script {script_name}"))?;
    v8_value_to_string(runtime, value)
}

fn v8_value_to_string(runtime: &mut JsRuntime, value: v8::Global<v8::Value>) -> Result<String> {
    deno_core::scope!(scope, runtime);
    let local = v8::Local::new(scope, value);
    local
        .to_string(scope)
        .ok_or_else(|| anyhow!("runtime expression did not evaluate to a string"))
        .map(|value| value.to_rust_string_lossy(scope))
}

fn parse_session_module_path() -> Result<String> {
    let mut args = env::args().skip(1);

    let Some(mode) = args.next() else {
        return Err(anyhow!(SESSION_USAGE));
    };
    if mode != "--session" {
        return Err(anyhow!(SESSION_USAGE));
    }

    let Some(module_path) = args.next() else {
        return Err(anyhow!(SESSION_USAGE));
    };
    if args.next().is_some() {
        return Err(anyhow!(SESSION_USAGE));
    }

    Ok(module_path)
}

fn resolve_main_module(path: String) -> Result<Url> {
    let cwd = env::current_dir().context("get current working directory")?;
    deno_core::resolve_path(&path, &cwd)
        .with_context(|| format!("resolve module path {path} from {}", cwd.display()))
}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, OnceLock};

    use super::{
        initial_lifecycle_bootstrap_script, initial_window_metrics_bootstrap_script,
        RuntimeDocumentPayload, APP_LIFECYCLE_STATE_ENV,
    };
    use shadow_sdk::app::{
        SAFE_AREA_BOTTOM_ENV, SAFE_AREA_LEFT_ENV, SAFE_AREA_RIGHT_ENV, SAFE_AREA_TOP_ENV,
        SURFACE_HEIGHT_ENV, SURFACE_WIDTH_ENV,
    };

    const LEGACY_SURFACE_WIDTH_ENV: &str = "SHADOW_BLITZ_SURFACE_WIDTH";
    const LEGACY_SURFACE_HEIGHT_ENV: &str = "SHADOW_BLITZ_SURFACE_HEIGHT";
    const LEGACY_SAFE_AREA_LEFT_ENV: &str = "SHADOW_BLITZ_SAFE_AREA_LEFT";
    const LEGACY_SAFE_AREA_TOP_ENV: &str = "SHADOW_BLITZ_SAFE_AREA_TOP";
    const LEGACY_SAFE_AREA_RIGHT_ENV: &str = "SHADOW_BLITZ_SAFE_AREA_RIGHT";
    const LEGACY_SAFE_AREA_BOTTOM_ENV: &str = "SHADOW_BLITZ_SAFE_AREA_BOTTOM";

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn clear_window_metric_env() {
        for key in [
            SURFACE_WIDTH_ENV,
            SURFACE_HEIGHT_ENV,
            SAFE_AREA_LEFT_ENV,
            SAFE_AREA_TOP_ENV,
            SAFE_AREA_RIGHT_ENV,
            SAFE_AREA_BOTTOM_ENV,
            LEGACY_SURFACE_WIDTH_ENV,
            LEGACY_SURFACE_HEIGHT_ENV,
            LEGACY_SAFE_AREA_LEFT_ENV,
            LEGACY_SAFE_AREA_TOP_ENV,
            LEGACY_SAFE_AREA_RIGHT_ENV,
            LEGACY_SAFE_AREA_BOTTOM_ENV,
        ] {
            std::env::remove_var(key);
        }
    }

    #[test]
    fn runtime_document_payload_preserves_text_input() {
        let payload = serde_json::from_str::<RuntimeDocumentPayload>(
            r#"{
                "html":"<input data-shadow-id=\"draft\" />",
                "css":null,
                "textInput":{
                    "targetId":"draft",
                    "value":"gm",
                    "selection":{"start":2,"end":2,"direction":"none"},
                    "inputMode":"text",
                    "multiline":false
                }
            }"#,
        )
        .expect("decode payload");

        let text_input = payload.text_input.expect("text input payload");
        assert_eq!(text_input.target_id, "draft");
        assert_eq!(text_input.value, "gm");
        assert_eq!(text_input.input_mode.as_deref(), Some("text"));
        assert!(!text_input.multiline);
    }

    #[test]
    fn lifecycle_bootstrap_script_is_absent_without_env() {
        let _guard = env_lock().lock().expect("env lock");
        std::env::remove_var(APP_LIFECYCLE_STATE_ENV);

        assert_eq!(
            initial_lifecycle_bootstrap_script().expect("bootstrap script"),
            None
        );
    }

    #[test]
    fn lifecycle_bootstrap_script_uses_trimmed_env_state() {
        let _guard = env_lock().lock().expect("env lock");
        std::env::set_var(APP_LIFECYCLE_STATE_ENV, " background ");

        let script = initial_lifecycle_bootstrap_script()
            .expect("bootstrap script")
            .expect("bootstrap value");
        assert!(script.contains("__initialLifecycleState: \"background\""));

        std::env::remove_var(APP_LIFECYCLE_STATE_ENV);
    }

    #[test]
    fn window_metrics_bootstrap_script_is_absent_without_surface_env() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_metric_env();

        assert_eq!(
            initial_window_metrics_bootstrap_script().expect("bootstrap script"),
            None
        );
    }

    #[test]
    fn window_metrics_bootstrap_script_uses_seeded_surface_and_safe_area() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_metric_env();
        std::env::set_var(SURFACE_WIDTH_ENV, "540");
        std::env::set_var(SURFACE_HEIGHT_ENV, "1042");
        std::env::set_var(SAFE_AREA_LEFT_ENV, "8");
        std::env::set_var(SAFE_AREA_TOP_ENV, "12");
        std::env::set_var(SAFE_AREA_RIGHT_ENV, "6");
        std::env::set_var(SAFE_AREA_BOTTOM_ENV, "4");

        let script = initial_window_metrics_bootstrap_script()
            .expect("bootstrap script")
            .expect("bootstrap value");
        assert!(script.contains("__initialWindowMetrics"));
        assert!(script.contains("\"surfaceWidth\":540"));
        assert!(script.contains("\"surfaceHeight\":1042"));
        assert!(script.contains("\"left\":8"));
        assert!(script.contains("\"top\":12"));
        assert!(script.contains("\"right\":6"));
        assert!(script.contains("\"bottom\":4"));

        clear_window_metric_env();
    }
}
