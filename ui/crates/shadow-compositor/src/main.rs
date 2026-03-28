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
mod winit;

#[cfg(target_os = "linux")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    if let Ok(env_filter) = tracing_subscriber::EnvFilter::try_from_default_env() {
        tracing_subscriber::fmt().with_env_filter(env_filter).init();
    } else {
        tracing_subscriber::fmt().init();
    }

    let mut event_loop: smithay::reexports::calloop::EventLoop<state::ShadowCompositor> =
        smithay::reexports::calloop::EventLoop::try_new()?;
    let display: smithay::reexports::wayland_server::Display<state::ShadowCompositor> =
        smithay::reexports::wayland_server::Display::new()?;
    let mut state = state::ShadowCompositor::new(&mut event_loop, display);
    tracing::info!(
        socket = ?state.socket_name,
        control = %state.control_socket_path.display(),
        "shadow-compositor: initialized state"
    );

    winit::init_winit(&mut event_loop, &mut state)?;
    std::env::set_var("WAYLAND_DISPLAY", &state.socket_name);
    tracing::info!(
        nested_socket = ?state.socket_name,
        "shadow-compositor: entering event loop"
    );

    event_loop.run(None, &mut state, |_| {})?;
    tracing::info!("shadow-compositor: event loop exited");
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("shadow-compositor currently targets Linux only. Use the desktop host on macOS.");
    std::process::exit(1);
}
