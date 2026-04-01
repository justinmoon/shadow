use std::{collections::HashMap, ffi::OsString, path::PathBuf, process::Child, sync::Arc};

use shadow_ui_core::{
    app::AppId,
    control::ControlRequest,
    scene::{
        APP_VIEWPORT_HEIGHT, APP_VIEWPORT_WIDTH, APP_VIEWPORT_X, APP_VIEWPORT_Y, HEIGHT, WIDTH,
    },
    shell::{ShellAction, ShellEvent, ShellModel},
};
use smithay::{
    desktop::{PopupManager, Space, Window, WindowSurfaceType},
    input::{Seat, SeatState},
    reexports::{
        calloop::{generic::Generic, EventLoop, Interest, LoopSignal, Mode, PostAction},
        wayland_server::{
            backend::{ClientData, ClientId, DisconnectReason},
            protocol::wl_surface::WlSurface,
            Display, DisplayHandle,
        },
    },
    utils::{Logical, Point, Serial, Size, SERIAL_COUNTER},
    wayland::{
        compositor::{CompositorClientState, CompositorState},
        output::OutputManagerState,
        selection::data_device::DataDeviceState,
        shell::xdg::XdgShellState,
        shm::ShmState,
        socket::ListeningSocketSource,
    },
};

use crate::{launch, shell::ShellSurface};

pub struct ShadowCompositor {
    pub start_time: std::time::Instant,
    pub socket_name: OsString,
    pub control_socket_path: PathBuf,
    pub display_handle: DisplayHandle,
    pub space: Space<Window>,
    pub loop_signal: LoopSignal,
    pub compositor_state: CompositorState,
    pub xdg_shell_state: XdgShellState,
    pub shm_state: ShmState,
    pub _output_manager_state: OutputManagerState,
    pub seat_state: SeatState<ShadowCompositor>,
    pub data_device_state: DataDeviceState,
    pub popups: PopupManager,
    pub seat: Seat<Self>,
    pub shell: ShellModel,
    pub shell_surface: ShellSurface,
    launched_apps: HashMap<AppId, Child>,
    surface_apps: HashMap<WlSurface, AppId>,
    pub(crate) shelved_windows: HashMap<AppId, Window>,
    focused_app: Option<AppId>,
    exit_on_first_window: bool,
}

impl ShadowCompositor {
    pub fn new(event_loop: &mut EventLoop<Self>, display: Display<Self>) -> Self {
        let start_time = std::time::Instant::now();
        let display_handle = display.handle();

        let compositor_state = CompositorState::new::<Self>(&display_handle);
        let xdg_shell_state = XdgShellState::new::<Self>(&display_handle);
        let shm_state = ShmState::new::<Self>(&display_handle, vec![]);
        let output_manager_state = OutputManagerState::new_with_xdg_output::<Self>(&display_handle);
        let data_device_state = DataDeviceState::new::<Self>(&display_handle);
        let popups = PopupManager::default();

        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(&display_handle, "shadow");
        seat.add_keyboard(Default::default(), 200, 25).unwrap();
        seat.add_pointer();

        let control_socket_path =
            crate::control::init_listener(event_loop).expect("create compositor control socket");
        let socket_name = Self::init_wayland_listener(display, event_loop);
        let loop_signal = event_loop.get_signal();

        Self {
            start_time,
            socket_name,
            control_socket_path,
            display_handle,
            space: Space::default(),
            loop_signal,
            compositor_state,
            xdg_shell_state,
            shm_state,
            _output_manager_state: output_manager_state,
            seat_state,
            data_device_state,
            popups,
            seat,
            shell: ShellModel::new(),
            shell_surface: ShellSurface::new(WIDTH as u32, HEIGHT as u32),
            launched_apps: HashMap::new(),
            surface_apps: HashMap::new(),
            shelved_windows: HashMap::new(),
            focused_app: None,
            exit_on_first_window: std::env::var_os("SHADOW_COMPOSITOR_EXIT_ON_FIRST_WINDOW")
                .is_some(),
        }
    }

    pub fn app_window_location(&self) -> (i32, i32) {
        let (shell_x, shell_y) = self.shell_location();
        (
            shell_x + APP_VIEWPORT_X.round() as i32,
            shell_y + APP_VIEWPORT_Y.round() as i32,
        )
    }

    pub fn app_window_size(&self) -> Size<i32, Logical> {
        (
            APP_VIEWPORT_WIDTH.round() as i32,
            APP_VIEWPORT_HEIGHT.round() as i32,
        )
            .into()
    }

    pub fn shell_location(&self) -> (i32, i32) {
        self.centered_location((WIDTH as i32, HEIGHT as i32).into())
    }

    pub fn shell_local_point(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        let (origin_x, origin_y) = self.shell_location();
        let local_x = position.x - origin_x as f64;
        let local_y = position.y - origin_y as f64;

        ((0.0..=WIDTH as f64).contains(&local_x) && (0.0..=HEIGHT as f64).contains(&local_y))
            .then_some((local_x as f32, local_y as f32))
    }

    pub fn surface_under(
        &self,
        pos: Point<f64, Logical>,
    ) -> Option<(WlSurface, Point<f64, Logical>)> {
        self.space
            .element_under(pos)
            .and_then(|(window, location)| {
                window
                    .surface_under(pos - location.to_f64(), WindowSurfaceType::ALL)
                    .map(|(surface, point)| (surface, (point + location).to_f64()))
            })
    }

    pub fn focus_window(&mut self, window: Option<Window>, serial: Serial) {
        let keyboard = self.seat.get_keyboard().expect("seat keyboard");

        if let Some(window) = window {
            self.space.raise_element(&window, true);
            let focused_surface = window.toplevel().unwrap().wl_surface().clone();
            self.focused_app = self.surface_apps.get(&focused_surface).copied();
            self.shell.set_foreground_app(self.focused_app);

            self.space.elements().for_each(|candidate| {
                let is_active = candidate.toplevel().unwrap().wl_surface() == &focused_surface;
                candidate.set_activated(is_active);
                candidate.toplevel().unwrap().send_pending_configure();
            });

            keyboard.set_focus(self, Some(focused_surface), serial);
            return;
        }

        self.space.elements().for_each(|candidate| {
            candidate.set_activated(false);
            candidate.toplevel().unwrap().send_pending_configure();
        });
        self.focused_app = None;
        self.shell.set_foreground_app(None);
        keyboard.set_focus(self, Option::<WlSurface>::None, serial);
    }

    pub fn focus_top_window(&mut self, serial: Serial) {
        let window = self.space.elements().last().cloned();
        self.focus_window(window, serial);
    }

    pub fn window_for_surface(&self, surface: &WlSurface) -> Option<Window> {
        self.space
            .elements()
            .find(|candidate| candidate.toplevel().unwrap().wl_surface() == surface)
            .cloned()
    }

    pub fn mapped_window_for_app(&self, app_id: AppId) -> Option<Window> {
        self.surface_apps
            .iter()
            .find_map(|(surface, mapped_app_id)| {
                (*mapped_app_id == app_id)
                    .then(|| self.window_for_surface(surface))
                    .flatten()
            })
    }

    pub fn remember_surface_app(&mut self, surface: &WlSurface, app_id: AppId) {
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
        }
    }

    pub fn forget_surface(&mut self, surface: &WlSurface) -> Option<AppId> {
        let removed = self.surface_apps.remove(surface);
        if removed == self.focused_app {
            self.focused_app = None;
            self.shell.set_foreground_app(None);
        }
        removed
    }

    pub fn spawn_demo_client(&mut self) -> std::io::Result<()> {
        let counter = shadow_ui_core::app::COUNTER_APP_ID;
        self.launch_or_focus_app(counter)?;
        tracing::info!("[shadow-compositor] launched-demo-client");
        Ok(())
    }

    pub fn handle_control_request(&mut self, request: ControlRequest) -> std::io::Result<String> {
        match request {
            ControlRequest::Launch { app_id } => {
                self.launch_or_focus_app(app_id)?;
                Ok("ok\n".to_string())
            }
            ControlRequest::Home => {
                self.go_home();
                Ok("ok\n".to_string())
            }
            ControlRequest::Switcher => Ok("ok\n".to_string()),
            ControlRequest::State => Ok(self.control_state_response()),
        }
    }

    pub fn handle_shell_event(&mut self, event: ShellEvent) {
        if let Some(action) = self.shell.handle(event) {
            self.handle_shell_action(action);
        }
    }

    pub fn handle_shell_action(&mut self, action: ShellAction) {
        match action {
            ShellAction::Launch { app_id } => {
                if let Err(error) = self.launch_or_focus_app(app_id) {
                    tracing::warn!("failed to launch/focus {}: {error}", app_id.as_str());
                }
            }
            ShellAction::Home => self.go_home(),
        }
    }

    pub fn go_home(&mut self) {
        let Some(app_id) = self.focused_app else {
            self.focus_window(None, self.next_serial());
            return;
        };

        if let Some(window) = self.mapped_window_for_app(app_id) {
            self.space.unmap_elem(&window);
            self.shelved_windows.insert(app_id, window);
        }

        self.focus_window(None, self.next_serial());
    }

    pub fn launch_or_focus_app(&mut self, app_id: AppId) -> std::io::Result<()> {
        self.reap_children();

        if self
            .shell
            .foreground_app()
            .is_some_and(|current| current != app_id)
        {
            self.go_home();
        }

        if let Some(window) = self.mapped_window_for_app(app_id) {
            self.focus_window(Some(window), self.next_serial());
            return Ok(());
        }

        if let Some(window) = self.shelved_windows.remove(&app_id) {
            self.space
                .map_element(window.clone(), self.app_window_location(), false);
            self.focus_window(Some(window), self.next_serial());
            return Ok(());
        }

        if self.launched_apps.contains_key(&app_id) {
            return Ok(());
        }

        let child = launch::launch_app(
            app_id,
            &self.socket_name,
            self.control_socket_path.as_os_str(),
        )?;
        self.launched_apps.insert(app_id, child);
        Ok(())
    }

    pub fn next_serial(&self) -> Serial {
        SERIAL_COUNTER.next_serial()
    }

    pub fn handle_window_mapped(&mut self, window: Window) {
        self.space
            .map_element(window.clone(), self.app_window_location(), false);
        self.focus_window(Some(window), self.next_serial());
        tracing::info!("[shadow-compositor] mapped-window");

        if self.exit_on_first_window {
            self.loop_signal.stop();
        }
    }

    fn reap_children(&mut self) {
        self.launched_apps
            .retain(|_, child| matches!(child.try_wait(), Ok(None)));
    }

    fn control_state_response(&mut self) -> String {
        self.reap_children();

        let focused = self.focused_app.map(AppId::as_str).unwrap_or("");
        let mapped = self.mapped_app_ids();
        let launched = self.launched_app_ids();
        format!(
            "focused={focused}\nmapped={mapped}\nlaunched={launched}\nwindows={}\nsocket={}\n",
            self.space.elements().count(),
            self.socket_name.to_string_lossy(),
        )
    }

    fn mapped_app_ids(&self) -> String {
        let mut app_ids: Vec<_> = self
            .space
            .elements()
            .filter_map(|window| {
                let surface = window.toplevel()?.wl_surface().clone();
                self.surface_apps.get(&surface).copied().map(AppId::as_str)
            })
            .collect();
        app_ids.sort_unstable();
        app_ids.dedup();
        app_ids.join(",")
    }

    fn launched_app_ids(&self) -> String {
        let mut app_ids: Vec<_> = self
            .launched_apps
            .keys()
            .copied()
            .map(AppId::as_str)
            .collect();
        app_ids.sort_unstable();
        app_ids.join(",")
    }

    fn centered_location(&self, size: Size<i32, Logical>) -> (i32, i32) {
        self.space
            .outputs()
            .next()
            .and_then(|output| self.space.output_geometry(output))
            .map(|geometry| {
                let x = geometry.loc.x + ((geometry.size.w - size.w).max(0) / 2);
                let y = geometry.loc.y + ((geometry.size.h - size.h).max(0) / 2);
                (x, y)
            })
            .unwrap_or((0, 0))
    }

    fn init_wayland_listener(display: Display<Self>, event_loop: &mut EventLoop<Self>) -> OsString {
        let listener = ListeningSocketSource::new_auto().expect("create wayland socket");
        let socket_name = listener.socket_name().to_os_string();
        let handle = event_loop.handle();

        handle
            .insert_source(listener, move |client_stream, _, state| {
                state
                    .display_handle
                    .insert_client(client_stream, Arc::new(ClientState::default()))
                    .expect("insert wayland client");
            })
            .expect("insert listening socket");

        handle
            .insert_source(
                Generic::new(display, Interest::READ, Mode::Level),
                |_, display, state| {
                    unsafe {
                        display.get_mut().dispatch_clients(state).unwrap();
                    }
                    let _ = state.display_handle.flush_clients();
                    Ok(PostAction::Continue)
                },
            )
            .expect("insert wayland display");

        socket_name
    }
}

impl Drop for ShadowCompositor {
    fn drop(&mut self) {
        for child in self.launched_apps.values_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }

        let _ = std::fs::remove_file(&self.control_socket_path);
    }
}

#[derive(Default)]
pub struct ClientState {
    pub compositor_state: CompositorClientState,
}

impl ClientData for ClientState {
    fn initialized(&self, _client_id: ClientId) {}

    fn disconnected(&self, _client_id: ClientId, reason: DisconnectReason) {
        tracing::info!(?reason, "shadow-compositor: client disconnected");
    }
}
