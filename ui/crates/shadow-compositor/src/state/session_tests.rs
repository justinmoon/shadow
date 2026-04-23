#![cfg(target_os = "linux")]

use std::{
    ffi::OsString,
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    sync::{Mutex, MutexGuard, OnceLock},
};

use shadow_ui_core::control::ControlRequest;
use shadow_ui_core::app::{self, AppId};
use smithay::reexports::{calloop::EventLoop, wayland_server::Display};
use tempfile::TempDir;

use super::ShadowCompositor;

fn env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct HostSessionHarness {
    state: ShadowCompositor,
    _event_loop: EventLoop<'static, ShadowCompositor>,
    _runtime_dir: TempDir,
    previous_xdg_runtime_dir: Option<OsString>,
    previous_shadow_app_client: Option<OsString>,
    _env_guard: MutexGuard<'static, ()>,
}

impl HostSessionHarness {
    fn new() -> Self {
        let env_guard = env_lock().lock().unwrap_or_else(|error| error.into_inner());
        let runtime_dir = TempDir::new().expect("temp runtime dir");
        let previous_xdg_runtime_dir = std::env::var_os("XDG_RUNTIME_DIR");
        let previous_shadow_app_client = std::env::var_os("SHADOW_APP_CLIENT");
        let client_path = write_stub_client(runtime_dir.path());

        unsafe {
            std::env::set_var("XDG_RUNTIME_DIR", runtime_dir.path());
            std::env::set_var("SHADOW_APP_CLIENT", &client_path);
        }

        let mut event_loop: EventLoop<ShadowCompositor> = EventLoop::try_new().expect("event loop");
        let display: Display<ShadowCompositor> = Display::new().expect("display");
        let state = ShadowCompositor::new(&mut event_loop, display);

        Self {
            state,
            _event_loop: event_loop,
            _runtime_dir: runtime_dir,
            previous_xdg_runtime_dir,
            previous_shadow_app_client,
            _env_guard: env_guard,
        }
    }

    fn set_foreground_app(&mut self, app_id: AppId) {
        self.state.focused_app = Some(app_id);
        self.state.shell.set_foreground_app(Some(app_id));
    }
}

impl Drop for HostSessionHarness {
    fn drop(&mut self) {
        match self.previous_shadow_app_client.take() {
            Some(value) => unsafe {
                std::env::set_var("SHADOW_APP_CLIENT", value);
            },
            None => unsafe {
                std::env::remove_var("SHADOW_APP_CLIENT");
            },
        }

        match self.previous_xdg_runtime_dir.take() {
            Some(value) => unsafe {
                std::env::set_var("XDG_RUNTIME_DIR", value);
            },
            None => unsafe {
                std::env::remove_var("XDG_RUNTIME_DIR");
            },
        }
    }
}

fn write_stub_client(runtime_dir: &std::path::Path) -> PathBuf {
    let script_path = runtime_dir.join("stub-client.sh");
    fs::write(&script_path, "#!/bin/sh\nexec sleep 60\n").expect("write stub client");
    let mut permissions = fs::metadata(&script_path)
        .expect("stub client metadata")
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&script_path, permissions).expect("stub client permissions");
    script_path
}

#[test]
fn launching_second_app_keeps_existing_background_process_alive() {
    let mut harness = HostSessionHarness::new();

    harness
        .state
        .launch_or_focus_app(app::RUST_DEMO_APP_ID)
        .expect("launch first app");
    harness.set_foreground_app(app::RUST_DEMO_APP_ID);

    harness
        .state
        .launch_or_focus_app(app::RUST_TIMELINE_APP_ID)
        .expect("launch second app");

    assert_eq!(harness.state.focused_app, None);
    assert_eq!(harness.state.shell.foreground_app(), None);
    assert!(harness
        .state
        .launched_apps
        .contains_key(&app::RUST_DEMO_APP_ID));
    assert!(harness
        .state
        .launched_apps
        .contains_key(&app::RUST_TIMELINE_APP_ID));
    assert!(harness
        .state
        .launched_apps
        .get_mut(&app::RUST_DEMO_APP_ID)
        .expect("first app child")
        .try_wait()
        .expect("poll first app")
        .is_none());
    assert!(harness
        .state
        .launched_apps
        .get_mut(&app::RUST_TIMELINE_APP_ID)
        .expect("second app child")
        .try_wait()
        .expect("poll second app")
        .is_none());

    let response = harness.state.control_state_response();
    assert!(response.contains("focused=\n"));
    assert!(response.contains("launched=rust-demo,rust-timeline\n"));
}

#[test]
fn going_home_keeps_unmapped_process_resident() {
    let mut harness = HostSessionHarness::new();

    harness
        .state
        .launch_or_focus_app(app::RUST_DEMO_APP_ID)
        .expect("launch app");
    harness.set_foreground_app(app::RUST_DEMO_APP_ID);

    harness.state.go_home();

    assert_eq!(harness.state.focused_app, None);
    assert_eq!(harness.state.shell.foreground_app(), None);
    assert!(harness
        .state
        .launched_apps
        .contains_key(&app::RUST_DEMO_APP_ID));
    assert!(harness
        .state
        .launched_apps
        .get_mut(&app::RUST_DEMO_APP_ID)
        .expect("app child")
        .try_wait()
        .expect("poll app")
        .is_none());

    let response = harness.state.control_state_response();
    assert!(response.contains("focused=\n"));
    assert!(response.contains("launched=rust-demo\n"));
}

#[test]
fn relaunching_existing_unmapped_app_is_idempotent() {
    let mut harness = HostSessionHarness::new();

    harness
        .state
        .launch_or_focus_app(app::RUST_DEMO_APP_ID)
        .expect("launch app");

    let first_pid = harness
        .state
        .launched_apps
        .get(&app::RUST_DEMO_APP_ID)
        .expect("first app child")
        .id();

    harness
        .state
        .launch_or_focus_app(app::RUST_DEMO_APP_ID)
        .expect("relaunch app");

    assert_eq!(harness.state.launched_apps.len(), 1);
    assert_eq!(
        harness
            .state
            .launched_apps
            .get(&app::RUST_DEMO_APP_ID)
            .expect("app child after relaunch")
            .id(),
        first_pid
    );
    assert!(harness
        .state
        .launched_apps
        .get_mut(&app::RUST_DEMO_APP_ID)
        .expect("app child after relaunch")
        .try_wait()
        .expect("poll app")
        .is_none());
}

#[test]
fn switcher_control_uses_shell_recents_to_pick_previous_app() {
    let mut harness = HostSessionHarness::new();

    harness.state.shell.set_app_running(app::RUST_DEMO_APP_ID, true);
    harness.set_foreground_app(app::RUST_TIMELINE_APP_ID);

    let response = harness
        .state
        .handle_control_request(ControlRequest::Switcher)
        .expect("switcher control request");

    assert_eq!(response, "ok\n");
    assert_eq!(harness.state.focused_app, None);
    assert_eq!(harness.state.shell.foreground_app(), None);
    assert!(harness
        .state
        .launched_apps
        .contains_key(&app::RUST_DEMO_APP_ID));
    assert_eq!(harness.state.launched_apps.len(), 1);
}
