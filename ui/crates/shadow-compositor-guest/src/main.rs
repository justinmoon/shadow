mod kms;

use std::time::Duration;
use std::{ffi::OsString, process::Child, sync::Arc};

use smithay::{
    backend::renderer::utils::{on_commit_buffer_handler, with_renderer_surface_state},
    delegate_compositor, delegate_seat, delegate_shm, delegate_xdg_shell,
    desktop::{Space, Window},
    input::{Seat, SeatHandler, SeatState},
    reexports::{
        calloop::{generic::Generic, EventLoop, Interest, LoopSignal, Mode, PostAction},
        wayland_server::{
            backend::{ClientData, ClientId, DisconnectReason},
            protocol::{wl_buffer, wl_seat, wl_surface::WlSurface},
            Client, Display, DisplayHandle,
        },
    },
    utils::Serial,
    wayland::{
        compositor::{
            get_parent, is_sync_subsurface, with_states, CompositorClientState, CompositorHandler,
            CompositorState,
        },
        shell::xdg::{ToplevelSurface, XdgShellHandler, XdgShellState, XdgToplevelSurfaceData},
        shm::{with_buffer_contents, ShmHandler, ShmState},
        socket::ListeningSocketSource,
    },
};

fn init_logging() {
    if let Ok(filter) = tracing_subscriber::EnvFilter::try_from_default_env() {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    } else {
        tracing_subscriber::fmt()
            .with_env_filter("shadow_compositor_guest=info,smithay=warn")
            .init();
    }
}

struct ShadowGuestCompositor {
    socket_name: OsString,
    display_handle: DisplayHandle,
    space: Space<Window>,
    loop_signal: LoopSignal,
    compositor_state: CompositorState,
    xdg_shell_state: XdgShellState,
    shm_state: ShmState,
    seat_state: SeatState<Self>,
    launched_clients: Vec<Child>,
    exit_on_first_window: bool,
    kms_display: Option<kms::KmsDisplay>,
}

impl ShadowGuestCompositor {
    fn new(event_loop: &mut EventLoop<Self>, display: Display<Self>) -> Self {
        let display_handle = display.handle();
        let socket_name = Self::init_wayland_listener(display, event_loop);
        let loop_signal = event_loop.get_signal();

        Self {
            socket_name,
            display_handle: display_handle.clone(),
            space: Space::default(),
            loop_signal,
            compositor_state: CompositorState::new::<Self>(&display_handle),
            xdg_shell_state: XdgShellState::new::<Self>(&display_handle),
            shm_state: ShmState::new::<Self>(&display_handle, vec![]),
            seat_state: SeatState::new(),
            launched_clients: Vec::new(),
            exit_on_first_window: std::env::var_os("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_WINDOW")
                .is_some(),
            kms_display: None,
        }
    }

    fn ensure_kms_display(&mut self) -> Option<&mut kms::KmsDisplay> {
        if self.kms_display.is_none() {
            match kms::KmsDisplay::open_when_ready(Duration::from_secs(15)) {
                Ok(kms_display) => {
                    let mode = kms_display.mode_summary();
                    tracing::info!("[shadow-guest-compositor] drm-ready mode={mode}");
                    self.kms_display = Some(kms_display);
                }
                Err(error) => {
                    tracing::warn!("[shadow-guest-compositor] drm-unavailable: {error}");
                    return None;
                }
            }
        }

        self.kms_display.as_mut()
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
            .expect("insert wayland socket");

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

    fn spawn_client(&mut self) -> std::io::Result<()> {
        let client_path = std::env::var("SHADOW_GUEST_CLIENT")
            .unwrap_or_else(|_| "/data/local/tmp/shadow-counter-guest".into());
        let runtime_dir = std::env::var("XDG_RUNTIME_DIR")
            .unwrap_or_else(|_| "/data/local/tmp/shadow-runtime".into());

        let mut command = std::process::Command::new(&client_path);
        command
            .env("WAYLAND_DISPLAY", &self.socket_name)
            .env("XDG_RUNTIME_DIR", runtime_dir)
            .env("SHADOW_GUEST_COUNTER_EXIT_ON_CONFIGURE", "1");

        let child = command.spawn()?;
        self.launched_clients.push(child);
        tracing::info!("[shadow-guest-compositor] launched-client={client_path}");
        Ok(())
    }

    fn handle_window_mapped(&mut self, window: Window) {
        self.space.map_element(window, (0, 0), false);
        tracing::info!("[shadow-guest-compositor] mapped-window");
        if self.exit_on_first_window {
            self.loop_signal.stop();
        }
    }

    fn take_surface_buffer(
        &self,
        surface: &WlSurface,
    ) -> Option<smithay::backend::renderer::utils::Buffer> {
        with_renderer_surface_state(surface, |state| state.buffer().cloned()).flatten()
    }

    fn present_surface(&mut self, surface: &WlSurface) {
        let Some(buffer) = self.take_surface_buffer(surface) else {
            return;
        };
        let capture_result = with_buffer_contents(&buffer, |ptr, len, data| {
            kms::capture_shm_frame(ptr, len, data)
        });

        match capture_result {
            Ok(Ok(frame)) => {
                let checksum = kms::frame_checksum(&frame);
                tracing::info!(
                    "[shadow-guest-compositor] captured-frame checksum={checksum:016x} size={}x{}",
                    frame.width,
                    frame.height
                );

                let artifact_path = std::env::var("SHADOW_GUEST_FRAME_PATH")
                    .unwrap_or_else(|_| "/shadow-frame.ppm".into());
                match kms::write_frame_ppm(&frame, &artifact_path) {
                    Ok(()) => {
                        tracing::info!(
                            "[shadow-guest-compositor] wrote-frame-artifact path={} checksum={checksum:016x} size={}x{}",
                            artifact_path,
                            frame.width,
                            frame.height
                        );
                    }
                    Err(error) => {
                        tracing::warn!("[shadow-guest-compositor] capture-write failed: {error}");
                    }
                }

                if std::env::var_os("SHADOW_GUEST_COMPOSITOR_ENABLE_DRM").is_some() {
                    if let Some(display) = self.ensure_kms_display() {
                        match display.present_frame(&frame) {
                            Ok(()) => tracing::info!("[shadow-guest-compositor] presented-frame"),
                            Err(error) => {
                                tracing::warn!(
                                    "[shadow-guest-compositor] present-frame failed: {error}"
                                )
                            }
                        }
                    }
                }
            }
            Ok(Err(error)) => {
                tracing::warn!("[shadow-guest-compositor] capture-frame failed: {error}");
            }
            Err(error) => {
                tracing::warn!("[shadow-guest-compositor] shm buffer access failed: {error}");
            }
        }

        buffer.release();
    }
}

#[derive(Default)]
struct ClientState {
    compositor_state: CompositorClientState,
}

impl ClientData for ClientState {
    fn initialized(&self, _client_id: ClientId) {}

    fn disconnected(&self, _client_id: ClientId, _reason: DisconnectReason) {}
}

impl SeatHandler for ShadowGuestCompositor {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }

    fn cursor_image(
        &mut self,
        _seat: &Seat<Self>,
        _image: smithay::input::pointer::CursorImageStatus,
    ) {
    }
}

impl CompositorHandler for ShadowGuestCompositor {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor_state
    }

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        &client.get_data::<ClientState>().unwrap().compositor_state
    }

    fn commit(&mut self, surface: &WlSurface) {
        on_commit_buffer_handler::<Self>(surface);

        let mut root_surface = surface.clone();
        let mut maybe_window = None;

        if !is_sync_subsurface(surface) {
            while let Some(parent) = get_parent(&root_surface) {
                root_surface = parent;
            }

            maybe_window = self
                .space
                .elements()
                .find(|window| window.toplevel().unwrap().wl_surface() == &root_surface)
                .cloned();

            if let Some(window) = maybe_window.as_ref() {
                window.on_commit();
            }
        }

        if let Some(window) = maybe_window {
            self.present_surface(&root_surface);
            let initial_configure_sent = with_states(&root_surface, |states| {
                states
                    .data_map
                    .get::<XdgToplevelSurfaceData>()
                    .unwrap()
                    .lock()
                    .unwrap()
                    .initial_configure_sent
            });
            if !initial_configure_sent {
                window.toplevel().unwrap().send_configure();
            }
            tracing::info!("[shadow-guest-compositor] committed-window");
        }
    }
}

impl smithay::wayland::buffer::BufferHandler for ShadowGuestCompositor {
    fn buffer_destroyed(&mut self, _buffer: &wl_buffer::WlBuffer) {}
}

impl ShmHandler for ShadowGuestCompositor {
    fn shm_state(&self) -> &ShmState {
        &self.shm_state
    }
}

impl XdgShellHandler for ShadowGuestCompositor {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell_state
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let window = Window::new_wayland_window(surface);
        self.handle_window_mapped(window);
    }

    fn new_popup(
        &mut self,
        _surface: smithay::wayland::shell::xdg::PopupSurface,
        _positioner: smithay::wayland::shell::xdg::PositionerState,
    ) {
    }

    fn reposition_request(
        &mut self,
        _surface: smithay::wayland::shell::xdg::PopupSurface,
        _positioner: smithay::wayland::shell::xdg::PositionerState,
        _token: u32,
    ) {
    }

    fn grab(
        &mut self,
        _surface: smithay::wayland::shell::xdg::PopupSurface,
        _seat: wl_seat::WlSeat,
        _serial: Serial,
    ) {
    }
}

delegate_compositor!(ShadowGuestCompositor);
delegate_seat!(ShadowGuestCompositor);
delegate_shm!(ShadowGuestCompositor);
delegate_xdg_shell!(ShadowGuestCompositor);

impl Drop for ShadowGuestCompositor {
    fn drop(&mut self) {
        for child in &mut self.launched_clients {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    init_logging();
    let mut event_loop: EventLoop<ShadowGuestCompositor> = EventLoop::try_new()?;
    let display: Display<ShadowGuestCompositor> = Display::new()?;
    let mut state = ShadowGuestCompositor::new(&mut event_loop, display);

    tracing::info!(
        "[shadow-guest-compositor] listening-socket={}",
        state.socket_name.to_string_lossy()
    );
    state.spawn_client()?;
    event_loop.run(None, &mut state, |_| {})?;
    Ok(())
}
