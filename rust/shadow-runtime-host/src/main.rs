use std::env;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::rc::Rc;

use deno_core::anyhow::{anyhow, Context, Result};
use deno_core::url::Url;
use deno_core::v8;
use deno_core::{FsModuleLoader, JsRuntime, PollEventLoopOptions, RuntimeOptions};
use shadow_runtime_protocol::{RuntimeDocumentPayload, SessionRequest, SessionResponse};

const RENDER_EXPR: &str = "globalThis.SHADOW_RUNTIME_HOST.render()";
const RENDER_IF_DIRTY_EXPR: &str = "globalThis.SHADOW_RUNTIME_HOST.renderIfDirty()";
const SESSION_USAGE: &str = "usage: shadow-runtime-host --session <bundle-path>";

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
        extensions: vec![
            runtime_camera_host::init_extension(),
            runtime_nostr_host::init_extension(),
            runtime_audio_host::init_extension(),
            runtime_cashu_host::init_extension(),
        ],
        ..Default::default()
    });

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
            format!("globalThis.SHADOW_RUNTIME_HOST.dispatch({event_json})")
        }
        SessionRequest::PlatformAudioControl { action } => {
            let action_json =
                serde_json::to_string(&action).context("encode runtime audio control action")?;
            format!("globalThis.SHADOW_RUNTIME_HOST.platformAudioControl({action_json})")
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
        SessionRequest::PlatformAudioControl { .. } => serde_json::from_str(&payload_json)
            .context("decode maybe runtime document payload for platform audio control"),
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
    use super::RuntimeDocumentPayload;

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
}
