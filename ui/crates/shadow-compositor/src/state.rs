use std::{ffi::OsString, process::Child, sync::Arc};

use shadow_ui_core::app::COUNTER_APP;
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
    utils::{Logical, Point, Serial, SERIAL_COUNTER},
    wayland::{
        compositor::{CompositorClientState, CompositorState},
        output::OutputManagerState,
        selection::data_device::DataDeviceState,
        shell::xdg::XdgShellState,
        shm::ShmState,
        socket::ListeningSocketSource,
    },
};

use crate::launch;

pub struct ShadowCompositor {
    pub start_time: std::time::Instant,
    pub socket_name: OsString,
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
    launched_clients: Vec<Child>,
    next_window_offset: i32,
    pub mapped_windows: usize,
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
        let mut seat: Seat<Self> = seat_state.new_wl_seat(&display_handle, "shadow");
        seat.add_keyboard(Default::default(), 200, 25).unwrap();
        seat.add_pointer();

        let socket_name = Self::init_wayland_listener(display, event_loop);
        let loop_signal = event_loop.get_signal();

        Self {
            start_time,
            socket_name,
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
            launched_clients: Vec::new(),
            next_window_offset: 0,
            mapped_windows: 0,
            exit_on_first_window: std::env::var_os("SHADOW_COMPOSITOR_EXIT_ON_FIRST_WINDOW")
                .is_some(),
        }
    }

    pub fn next_window_location(&mut self) -> (i32, i32) {
        let offset = self.next_window_offset;
        self.next_window_offset = (self.next_window_offset + 36) % 180;
        (72 + offset, 132 + offset / 2)
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
        keyboard.set_focus(self, Option::<WlSurface>::None, serial);
    }

    pub fn spawn_demo_client(&mut self) -> std::io::Result<()> {
        self.reap_children();
        let child = launch::launch_app(COUNTER_APP.id, &self.socket_name)?;
        self.launched_clients.push(child);
        tracing::info!("[shadow-compositor] launched-demo-client");
        Ok(())
    }

    pub fn next_serial(&self) -> Serial {
        SERIAL_COUNTER.next_serial()
    }

    pub fn handle_window_mapped(&mut self, window: Window) {
        let location = self.next_window_location();
        self.space.map_element(window.clone(), location, false);
        self.mapped_windows += 1;
        self.focus_window(Some(window), self.next_serial());
        tracing::info!("[shadow-compositor] mapped-window");

        if self.exit_on_first_window {
            self.loop_signal.stop();
        }
    }

    fn reap_children(&mut self) {
        self.launched_clients
            .retain_mut(|child| match child.try_wait() {
                Ok(None) => true,
                Ok(Some(_)) => false,
                Err(_) => false,
            });
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
            .expect("insert display");

        socket_name
    }
}

#[derive(Default)]
pub struct ClientState {
    pub compositor_state: CompositorClientState,
}

impl ClientData for ClientState {
    fn initialized(&self, _client_id: ClientId) {}

    fn disconnected(&self, _client_id: ClientId, _reason: DisconnectReason) {}
}

impl Drop for ShadowCompositor {
    fn drop(&mut self) {
        for child in &mut self.launched_clients {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
