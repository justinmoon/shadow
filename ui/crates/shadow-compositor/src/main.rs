#[cfg(target_os = "linux")]
mod control;
#[cfg(target_os = "linux")]
mod handlers;
#[cfg(target_os = "linux")]
mod input;
#[cfg(target_os = "linux")]
mod launch;
#[cfg(target_os = "linux")]
mod render;
#[cfg(target_os = "linux")]
mod shell;
#[cfg(target_os = "linux")]
mod state;
#[cfg(target_os = "linux")]
mod winit_backend;

#[cfg(target_os = "linux")]
use smithay::reexports::{calloop::EventLoop, wayland_server::Display};
#[cfg(target_os = "linux")]
use state::ShadowCompositor;

fn init_logging() {
    if let Ok(filter) = tracing_subscriber::EnvFilter::try_from_default_env() {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    } else {
        tracing_subscriber::fmt()
            .with_env_filter("shadow_compositor=info,smithay=warn")
            .init();
    }
}

#[cfg(target_os = "linux")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    init_logging();
    let headless = std::env::var_os("SHADOW_COMPOSITOR_HEADLESS").is_some();

    let mut event_loop: EventLoop<ShadowCompositor> = EventLoop::try_new()?;
    let display: Display<ShadowCompositor> = Display::new()?;

    let mut state = ShadowCompositor::new(&mut event_loop, display);
    if headless {
        tracing::info!("[shadow-compositor] headless-mode");
    } else {
        winit_backend::init_winit(&mut event_loop, &mut state)?;
    }

    std::env::set_var("WAYLAND_DISPLAY", &state.socket_name);
    tracing::info!(
        "[shadow-compositor] listening-socket={}",
        state.socket_name.to_string_lossy()
    );
    if std::env::var_os("SHADOW_COMPOSITOR_AUTO_LAUNCH").is_some() {
        if let Err(error) = state.spawn_demo_client() {
            tracing::warn!("failed to launch demo client: {error}");
        }
    }

    event_loop.run(None, &mut state, |_| {})?;
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn main() {
    init_logging();
    tracing::warn!(
        "shadow-compositor currently supports Linux only; use shadow-ui-desktop on this host"
    );
}
