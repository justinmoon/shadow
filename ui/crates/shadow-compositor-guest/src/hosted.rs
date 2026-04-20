use std::{io, time::Duration};

use shadow_blitz_demo::hosted_runtime::HostedRuntimeApp;
use shadow_runtime_protocol::{AppLifecycleState, RuntimeAudioControlAction};
use shadow_ui_core::app::{self, AppId};

use crate::config::GuestClientConfig;

pub const HOSTED_IDLE_POLL_INTERVAL: Duration = Duration::from_millis(16);

pub struct HostedAppState {
    app: HostedRuntimeApp,
}

impl HostedAppState {
    pub fn launch(
        app_id: AppId,
        client_config: &GuestClientConfig,
        width: u32,
        height: u32,
    ) -> io::Result<Self> {
        let launch_spec = app::launch_spec(app_id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "unknown demo app"))?;
        let runtime = launch_spec.typescript_runtime().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "app {} does not expose a hosted TypeScript runtime",
                    app_id.as_str()
                ),
            )
        })?;
        let bundle_path = std::env::var(runtime.bundle_env).map_err(|_| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("missing runtime bundle env {}", runtime.bundle_env),
            )
        })?;
        let host_binary_path = client_config
            .runtime_host_binary_path
            .as_ref()
            .map(|path| path.to_string_lossy().into_owned())
            .or_else(|| std::env::var("SHADOW_RUNTIME_HOST_BINARY_PATH").ok())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "missing SHADOW_RUNTIME_HOST_BINARY_PATH for hosted runtime app",
                )
            })?;

        let app = HostedRuntimeApp::new(host_binary_path, bundle_path, width, height)
            .map_err(io::Error::other)?;
        Ok(Self { app })
    }

    pub fn app_mut(&mut self) -> &mut HostedRuntimeApp {
        &mut self.app
    }

    pub fn handle_pointer_down(&mut self, x: f32, y: f32) -> io::Result<bool> {
        self.app.handle_pointer_down(x, y).map_err(io::Error::other)
    }

    pub fn handle_pointer_move(&mut self, x: f32, y: f32) -> io::Result<bool> {
        self.app.handle_pointer_move(x, y).map_err(io::Error::other)
    }

    pub fn handle_pointer_up(&mut self, x: f32, y: f32) -> io::Result<bool> {
        self.app.handle_pointer_up(x, y).map_err(io::Error::other)
    }

    pub fn handle_platform_audio_control(
        &mut self,
        action: RuntimeAudioControlAction,
    ) -> io::Result<bool> {
        self.app
            .handle_platform_audio_control(action)
            .map_err(io::Error::other)
    }

    pub fn handle_platform_lifecycle_change(
        &mut self,
        state: AppLifecycleState,
    ) -> io::Result<bool> {
        self.app
            .handle_platform_lifecycle_change(state)
            .map_err(io::Error::other)
    }

    pub fn poll(&mut self) -> io::Result<bool> {
        self.app.poll().map_err(io::Error::other)
    }
}
