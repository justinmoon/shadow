use std::{path::Path, thread};

use shadow_compositor_common::app_control::{
    dispatch_media_action_to_app, notify_lifecycle_state_to_app,
};
use shadow_compositor_common::state_report::{render_control_state, sorted_unique_app_ids_csv};
use shadow_runtime_protocol::AppLifecycleState;
use shadow_ui_core::{
    app::{self, AppId},
    control::{ControlRequest, MediaAction},
};
use smithay::{
    desktop::Window, reexports::wayland_server::protocol::wl_surface::WlSurface,
    utils::SERIAL_COUNTER,
};

use crate::{hosted, launch};

use super::{ShadowGuestCompositor, WaylandTransport};

impl ShadowGuestCompositor {
    pub(crate) fn control_runtime_dir(&self) -> &Path {
        self.control_socket_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
    }

    pub(crate) fn window_for_surface(&self, surface: &WlSurface) -> Option<Window> {
        self.space
            .elements()
            .find(|candidate| candidate.toplevel().unwrap().wl_surface() == surface)
            .cloned()
    }

    pub(crate) fn mapped_window_for_app(&self, app_id: AppId) -> Option<Window> {
        self.surface_apps
            .iter()
            .find_map(|(surface, mapped_app_id)| {
                (*mapped_app_id == app_id)
                    .then(|| self.window_for_surface(surface))
                    .flatten()
            })
    }

    pub(crate) fn remember_surface_app(&mut self, surface: &WlSurface, app_id: AppId) {
        self.surface_apps.insert(surface.clone(), app_id);
        self.shell.set_app_running(app_id, true);
        if self
            .space
            .elements()
            .last()
            .and_then(|window| window.toplevel())
            .map(|toplevel| toplevel.wl_surface() == surface)
            .unwrap_or(false)
        {
            self.focused_app = Some(app_id);
            self.shell.set_foreground_app(Some(app_id));
            self.note_app_foregrounded(app_id);
            self.enforce_background_app_residency();
        }
        tracing::info!(
            "[shadow-guest-compositor] surface-app-tracked app={} surface={surface:?}",
            app_id.as_str()
        );
    }

    pub(crate) fn forget_surface(&mut self, surface: &WlSurface) -> Option<AppId> {
        let removed = self.surface_apps.remove(surface);
        if removed == self.focused_app {
            self.focused_app = None;
            self.shell.set_foreground_app(None);
        }
        if let Some(app_id) = removed {
            self.shell.set_app_running(app_id, false);
            self.app_frames.remove(&app_id);
            self.forget_background_app(app_id);
        }
        removed
    }

    pub(crate) fn focus_window(&mut self, window: Option<Window>) {
        let serial = SERIAL_COUNTER.next_serial();

        if let Some(window) = window {
            self.space.raise_element(&window, true);
            let focused_surface = window.toplevel().unwrap().wl_surface().clone();
            self.focused_app = self.surface_apps.get(&focused_surface).copied();
            self.shell.set_foreground_app(self.focused_app);
            if let Some(app_id) = self.focused_app {
                self.note_app_foregrounded(app_id);
            }
            self.space.elements().for_each(|candidate| {
                let is_active = candidate.toplevel().unwrap().wl_surface() == &focused_surface;
                candidate.set_activated(is_active);
                candidate.toplevel().unwrap().send_pending_configure();
            });
            if let Some(keyboard) = self.seat.get_keyboard() {
                keyboard.set_focus(self, Some(focused_surface), serial);
            }
            return;
        }

        self.space.elements().for_each(|candidate| {
            candidate.set_activated(false);
            candidate.toplevel().unwrap().send_pending_configure();
        });
        self.focused_app = None;
        self.shell.set_foreground_app(None);
        if let Some(keyboard) = self.seat.get_keyboard() {
            keyboard.set_focus(self, Option::<WlSurface>::None, serial);
        }
    }

    pub(crate) fn focus_top_window(&mut self) {
        let window = self.space.elements().last().cloned();
        self.focus_window(window);
    }

    pub(crate) fn go_home(&mut self) {
        let Some(app_id) = self.focused_app else {
            self.focus_window(None);
            self.publish_visible_shell_frame("shell-home-frame");
            return;
        };

        if let Some(window) = self.mapped_window_for_app(app_id) {
            self.space.unmap_elem(&window);
            self.shelved_windows.insert(app_id, window);
        }

        self.focus_window(None);
        if let Some(hosted_app) = self.hosted_apps.get_mut(&app_id) {
            let update = hosted_app.handle_platform_lifecycle_change(AppLifecycleState::Background);
            let _ = self.apply_hosted_app_update(app_id, update);
        } else {
            notify_lifecycle_state_to_app(
                self.control_runtime_dir(),
                app_id,
                AppLifecycleState::Background,
            );
        }
        self.note_app_backgrounded(app_id);
        self.enforce_background_app_residency();
        self.publish_visible_shell_frame("shell-home-frame");
    }

    pub(crate) fn terminate_app(&mut self, app_id: AppId) {
        if let Some(window) = self.mapped_window_for_app(app_id) {
            self.space.unmap_elem(&window);
        }
        self.shelved_windows.remove(&app_id);

        let surfaces: Vec<_> = self
            .surface_apps
            .iter()
            .filter_map(|(surface, mapped_app_id)| {
                (*mapped_app_id == app_id).then_some(surface.clone())
            })
            .collect();
        for surface in surfaces {
            let _ = self.surface_apps.remove(&surface);
        }

        if self.focused_app == Some(app_id) {
            self.focused_app = None;
            self.shell.set_foreground_app(None);
        }
        self.shell.set_app_running(app_id, false);
        self.app_frames.remove(&app_id);
        self.hosted_apps.remove(&app_id);
        self.forget_background_app(app_id);

        if let Some(mut child) = self.launched_apps.remove(&app_id) {
            let pid = child.id();
            if let Err(error) = child.kill() {
                tracing::warn!(
                    "[shadow-guest-compositor] launched-app-kill-error app={} pid={} error={error}",
                    app_id.as_str(),
                    pid
                );
            }
            if let Err(error) = child.wait() {
                tracing::warn!(
                    "[shadow-guest-compositor] launched-app-wait-error app={} pid={} error={error}",
                    app_id.as_str(),
                    pid
                );
            } else {
                tracing::info!(
                    "[shadow-guest-compositor] launched-app-terminated app={} pid={}",
                    app_id.as_str(),
                    pid
                );
            }
        }
    }

    fn background_app_resident_limit(&self) -> usize {
        self.background_app_resident_limit
    }

    fn note_app_backgrounded(&mut self, app_id: AppId) {
        self.forget_background_app(app_id);
        self.background_app_order.push_back(app_id);
    }

    fn note_app_foregrounded(&mut self, app_id: AppId) {
        self.forget_background_app(app_id);
    }

    fn forget_background_app(&mut self, app_id: AppId) {
        self.background_app_order
            .retain(|candidate| *candidate != app_id);
    }

    fn is_background_resident(&self, app_id: AppId) -> bool {
        Some(app_id) != self.focused_app
            && (self.launched_apps.contains_key(&app_id)
                || self.hosted_apps.contains_key(&app_id)
                || self.shelved_windows.contains_key(&app_id)
                || self
                    .surface_apps
                    .values()
                    .any(|candidate| *candidate == app_id))
    }

    fn background_resident_app_ids(&self) -> Vec<AppId> {
        let mut app_ids = Vec::new();
        for app_id in self.background_app_order.iter().copied() {
            if self.is_background_resident(app_id) && !app_ids.contains(&app_id) {
                app_ids.push(app_id);
            }
        }

        let mut remainder: Vec<_> = self
            .launched_apps
            .keys()
            .chain(self.hosted_apps.keys())
            .chain(self.shelved_windows.keys())
            .chain(self.surface_apps.values())
            .copied()
            .filter(|app_id| self.is_background_resident(*app_id) && !app_ids.contains(app_id))
            .collect();
        remainder.sort_unstable_by_key(|app_id| app_id.as_str());
        remainder.dedup();
        app_ids.extend(remainder);
        app_ids
    }

    fn enforce_background_app_residency(&mut self) {
        let limit = self.background_app_resident_limit();
        let background_apps = self.background_resident_app_ids();
        if background_apps.len() <= limit {
            return;
        }

        let evict_count = background_apps.len() - limit;
        for app_id in background_apps.into_iter().take(evict_count) {
            tracing::info!(
                "[shadow-guest-compositor] background-app-evicted app={} limit={limit}",
                app_id.as_str()
            );
            self.terminate_app(app_id);
        }
    }

    fn should_host_app(&self, app_id: AppId) -> bool {
        self.shell_enabled
            && app::launch_spec(app_id)
                .and_then(|spec| spec.typescript_runtime())
                .is_some()
    }

    fn focus_hosted_app(&mut self, app_id: AppId, frame_marker: &str) {
        self.focus_window(None);
        self.focused_app = Some(app_id);
        self.shell.set_foreground_app(Some(app_id));
        self.note_app_foregrounded(app_id);
        tracing::info!(
            "[shadow-guest-compositor] mapped-window app={} hosted=1",
            app_id.as_str()
        );
        tracing::info!(
            "[shadow-guest-compositor] surface-app-tracked app={} transport=hosted",
            app_id.as_str()
        );
        self.publish_visible_shell_frame(frame_marker);
    }

    pub(crate) fn launch_or_focus_app(&mut self, app_id: AppId) -> std::io::Result<()> {
        self.reap_exited_clients();

        if self.focused_app == Some(app_id) {
            return Ok(());
        }

        if self.focused_app.is_some_and(|current| current != app_id) {
            self.go_home();
        }

        if let Some(window) = self.mapped_window_for_app(app_id) {
            self.focus_window(Some(window));
            notify_lifecycle_state_to_app(
                self.control_runtime_dir(),
                app_id,
                AppLifecycleState::Foreground,
            );
            self.enforce_background_app_residency();
            self.publish_visible_shell_frame("shell-app-focus-frame");
            return Ok(());
        }

        if let Some(window) = self.shelved_windows.remove(&app_id) {
            self.space
                .map_element(window.clone(), self.app_window_location(), false);
            self.focus_window(Some(window));
            notify_lifecycle_state_to_app(
                self.control_runtime_dir(),
                app_id,
                AppLifecycleState::Foreground,
            );
            self.enforce_background_app_residency();
            self.publish_visible_shell_frame("shell-app-resume-frame");
            return Ok(());
        }

        if self.launched_apps.contains_key(&app_id) {
            return Ok(());
        }

        tracing::info!(
            "[shadow-guest-compositor] app-launch-mode app={} hosted={}",
            app_id.as_str(),
            self.should_host_app(app_id)
        );

        if self.should_host_app(app_id) {
            if self.hosted_apps.contains_key(&app_id) {
                let update = self
                    .hosted_apps
                    .get_mut(&app_id)
                    .expect("hosted app present")
                    .handle_platform_lifecycle_change(AppLifecycleState::Foreground);
                let _ = self.apply_hosted_app_update(app_id, update);
                self.focus_hosted_app(app_id, "shell-app-focus-frame");
                self.enforce_background_app_residency();
                return Ok(());
            }

            let size = self.app_window_size();
            let hosted_app = hosted::HostedAppState::launch(
                app_id,
                &self.client_config,
                size.w.max(1) as u32,
                size.h.max(1) as u32,
            )?;
            self.hosted_apps.insert(app_id, hosted_app);
            self.app_frames.remove(&app_id);
            self.shell.set_app_running(app_id, true);
            self.focus_hosted_app(app_id, "shell-app-launch-frame");
            self.enforce_background_app_residency();
            return Ok(());
        }

        let child = launch::launch_app(self, app_id)?;
        self.launched_apps.insert(app_id, child);
        Ok(())
    }

    pub(crate) fn handle_control_request(
        &mut self,
        request: ControlRequest,
    ) -> std::io::Result<String> {
        match request {
            ControlRequest::Launch { app_id } => {
                self.launch_or_focus_app(app_id)?;
                Ok("ok\n".to_string())
            }
            ControlRequest::Tap { x, y } => self.handle_control_tap(x, y),
            ControlRequest::Home => {
                self.go_home();
                Ok("ok\n".to_string())
            }
            ControlRequest::Switcher => Ok("ok\n".to_string()),
            ControlRequest::Prompt { action_id } => {
                self.resolve_system_prompt_via_control(action_id)
            }
            ControlRequest::Media { action } => Ok(self.handle_control_media(action)),
            ControlRequest::Snapshot { path } => self.write_frame_snapshot(path),
            ControlRequest::State => Ok(self.control_state_response()),
        }
    }

    pub(crate) fn handle_control_media(&mut self, action: MediaAction) -> String {
        let Some(app_id) = self.focused_app else {
            return "ok\nhandled=0\nreason=no-focused-app\n".to_string();
        };
        if let Some(hosted_app) = self.hosted_apps.get_mut(&app_id) {
            let update = hosted_app.handle_platform_audio_control(action.into());
            let _ = self.apply_hosted_app_update(app_id, update);
            if self.focused_app == Some(app_id) {
                self.publish_visible_shell_frame("control-media-hosted-frame");
            }
            return "ok\nhandled=1\nsource=hosted\n".to_string();
        }
        dispatch_media_action_to_app(self.control_runtime_dir(), app_id, action)
    }

    pub(crate) fn dispatch_control_media_async(&mut self, action: MediaAction) {
        let Some(app_id) = self.focused_app else {
            return;
        };
        if let Some(hosted_app) = self.hosted_apps.get_mut(&app_id) {
            let update = hosted_app.handle_platform_audio_control(action.into());
            let _ = self.apply_hosted_app_update(app_id, update);
            if self.focused_app == Some(app_id) {
                self.publish_visible_shell_frame("media-key-hosted-frame");
            }
            tracing::info!(
                "[shadow-guest-compositor] media-key-dispatch action={} response=ok handled=1 source=hosted",
                action.as_token(),
            );
            return;
        }
        let runtime_dir = self.control_runtime_dir().to_path_buf();
        thread::spawn(move || {
            let response = dispatch_media_action_to_app(runtime_dir, app_id, action);
            tracing::info!(
                "[shadow-guest-compositor] media-key-dispatch action={} response={}",
                action.as_token(),
                response.trim()
            );
        });
    }

    pub(crate) fn control_state_response(&mut self) -> String {
        self.reap_exited_clients();

        let mapped = self.mapped_app_ids();
        let launched = self.launched_app_ids();
        let shelved = self.shelved_app_ids();
        let transport = match &self.transport {
            WaylandTransport::NamedSocket(socket_name) => {
                socket_name.to_string_lossy().into_owned()
            }
            WaylandTransport::DirectClientFd => "direct-client-fd".to_string(),
        };
        let prompt_request = self.shell.system_prompt_request();
        let extra_fields = vec![
            ("transport", transport),
            (
                "control_socket",
                self.control_socket_path.display().to_string(),
            ),
            (
                "prompt_active",
                usize::from(prompt_request.is_some()).to_string(),
            ),
            (
                "prompt_source_app_id",
                prompt_request
                    .map(|request| request.source_app_id.as_str().to_string())
                    .unwrap_or_default(),
            ),
            (
                "prompt_actions",
                prompt_request
                    .map(|request| {
                        request
                            .actions
                            .iter()
                            .map(|action| action.id.as_str())
                            .collect::<Vec<_>>()
                            .join(",")
                    })
                    .unwrap_or_default(),
            ),
        ];
        render_control_state(
            self.focused_app,
            &mapped,
            &launched,
            &shelved,
            self.space.elements().count() + usize::from(self.focused_hosted_app().is_some()),
            &extra_fields,
        )
    }

    pub(crate) fn mapped_app_ids(&self) -> String {
        sorted_unique_app_ids_csv(
            self.space
                .elements()
                .filter_map(|window| {
                    let surface = window.toplevel()?.wl_surface().clone();
                    self.surface_apps.get(&surface).copied()
                })
                .chain(self.focused_hosted_app()),
        )
    }

    pub(crate) fn launched_app_ids(&self) -> String {
        sorted_unique_app_ids_csv(
            self.launched_apps
                .keys()
                .chain(self.hosted_apps.keys())
                .copied(),
        )
    }

    pub(crate) fn shelved_app_ids(&self) -> String {
        sorted_unique_app_ids_csv(
            self.shelved_windows.keys().copied().chain(
                self.hosted_apps
                    .keys()
                    .copied()
                    .filter(|app_id| Some(*app_id) != self.focused_app),
            ),
        )
    }
}

#[cfg(test)]
mod tests {
    use std::{
        ffi::OsString,
        fs,
        os::unix::fs::PermissionsExt,
        path::PathBuf,
        sync::{Mutex, MutexGuard, OnceLock},
    };

    use smithay::reexports::{calloop::EventLoop, wayland_server::Display};
    use tempfile::TempDir;

    use super::*;
    use crate::config::{
        DmabufFormatProfile, GuestClientConfig, GuestStartupConfig, StartupAction, TransportRequest,
    };
    use shadow_ui_core::app;

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    struct GuestSessionHarness {
        state: ShadowGuestCompositor,
        _event_loop: EventLoop<'static, ShadowGuestCompositor>,
        _runtime_dir: TempDir,
        previous_xdg_runtime_dir: Option<OsString>,
        _env_guard: MutexGuard<'static, ()>,
    }

    impl GuestSessionHarness {
        fn new() -> Self {
            Self::with_background_limit(3)
        }

        fn with_background_limit(background_app_resident_limit: usize) -> Self {
            let env_guard = env_lock().lock().unwrap_or_else(|error| error.into_inner());
            let runtime_dir = TempDir::new().expect("temp runtime dir");
            let client_runtime_dir = runtime_dir.path().join("client-runtime");
            fs::create_dir_all(&client_runtime_dir).expect("client runtime dir");

            let previous_xdg_runtime_dir = std::env::var_os("XDG_RUNTIME_DIR");
            unsafe {
                std::env::set_var("XDG_RUNTIME_DIR", runtime_dir.path());
            }

            let client_path = write_stub_client(runtime_dir.path());
            let config = GuestStartupConfig {
                startup_action: StartupAction::App {
                    app_id: app::RUST_DEMO_APP_ID,
                },
                client: GuestClientConfig {
                    app_client_path: client_path.to_string_lossy().into_owned(),
                    runtime_dir: client_runtime_dir,
                    system_binary_path: None,
                    env_assignments: Vec::new(),
                    exit_on_configure: false,
                    linger_ms: None,
                },
                transport: TransportRequest::Direct,
                exit_on_client_disconnect: false,
                exit_on_first_frame: false,
                exit_on_first_dma_buffer: false,
                boot_splash_drm: false,
                drm_enabled: false,
                gpu_shell: false,
                strict_gpu_resident: false,
                dmabuf_global_enabled: false,
                dmabuf_feedback_enabled: false,
                dmabuf_format_profile: DmabufFormatProfile::Default,
                touch_signal_path: None,
                touch_latency_trace: false,
                synthetic_tap: None,
                exit_after_touch_present: false,
                frame_snapshot_cache_enabled: false,
                frame_checksum_enabled: false,
                frame_artifact_path: runtime_dir.path().join("frame.ppm"),
                frame_artifacts_enabled: false,
                frame_artifact_every_frame: false,
                toplevel_width: crate::DEFAULT_TOPLEVEL_WIDTH,
                toplevel_height: crate::DEFAULT_TOPLEVEL_HEIGHT,
                keyboard_seat_enabled: false,
                software_keyboard_enabled: true,
                background_app_resident_limit,
            };

            let mut event_loop: EventLoop<ShadowGuestCompositor> =
                EventLoop::try_new().expect("event loop");
            let display: Display<ShadowGuestCompositor> = Display::new().expect("display");
            let state = ShadowGuestCompositor::new(&config, &mut event_loop, display);

            Self {
                state,
                _event_loop: event_loop,
                _runtime_dir: runtime_dir,
                previous_xdg_runtime_dir,
                _env_guard: env_guard,
            }
        }

        fn set_foreground_app(&mut self, app_id: AppId) {
            self.state.focused_app = Some(app_id);
            self.state.shell.set_foreground_app(Some(app_id));
            self.state.note_app_foregrounded(app_id);
        }
    }

    impl Drop for GuestSessionHarness {
        fn drop(&mut self) {
            let app_ids: Vec<_> = self.state.launched_apps.keys().copied().collect();
            for app_id in app_ids {
                self.state.terminate_app(app_id);
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
        let mut harness = GuestSessionHarness::new();

        harness
            .state
            .launch_or_focus_app(app::RUST_DEMO_APP_ID)
            .expect("launch first app");
        harness.set_foreground_app(app::RUST_DEMO_APP_ID);

        harness
            .state
            .launch_or_focus_app(app::RUST_TIMELINE_APP_ID)
            .expect("launch second app");

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
        assert_eq!(
            harness.state.background_resident_app_ids(),
            vec![app::RUST_DEMO_APP_ID, app::RUST_TIMELINE_APP_ID]
        );

        let response = harness.state.control_state_response();
        assert!(response.contains("focused=\n"));
        assert!(response.contains("launched=rust-demo,rust-timeline\n"));
    }

    #[test]
    fn going_home_keeps_unmapped_process_resident() {
        let mut harness = GuestSessionHarness::new();

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
        assert_eq!(
            harness.state.background_resident_app_ids(),
            vec![app::RUST_DEMO_APP_ID]
        );

        let response = harness.state.control_state_response();
        assert!(response.contains("focused=\n"));
        assert!(response.contains("launched=rust-demo\n"));
    }

    #[test]
    fn switching_apps_evicts_background_process_when_limit_is_zero() {
        let mut harness = GuestSessionHarness::with_background_limit(0);

        harness
            .state
            .launch_or_focus_app(app::RUST_DEMO_APP_ID)
            .expect("launch first app");
        harness.set_foreground_app(app::RUST_DEMO_APP_ID);

        harness
            .state
            .launch_or_focus_app(app::RUST_TIMELINE_APP_ID)
            .expect("launch second app");

        assert!(!harness
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
            .get_mut(&app::RUST_TIMELINE_APP_ID)
            .expect("second app child")
            .try_wait()
            .expect("poll second app")
            .is_none());
        assert_eq!(
            harness.state.background_resident_app_ids(),
            vec![app::RUST_TIMELINE_APP_ID]
        );

        let response = harness.state.control_state_response();
        assert!(response.contains("launched=rust-timeline\n"));
    }

    #[test]
    fn relaunching_existing_unmapped_app_is_idempotent() {
        let mut harness = GuestSessionHarness::new();

        harness
            .state
            .launch_or_focus_app(app::RUST_DEMO_APP_ID)
            .expect("launch app");

        let first_pid = harness
            .state
            .launched_apps
            .get(&app::RUST_DEMO_APP_ID)
            .expect("app child")
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
}
