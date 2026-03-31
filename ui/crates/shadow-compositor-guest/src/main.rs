mod kms;

use std::time::Duration;
use std::{
    ffi::OsString,
    os::{fd::AsRawFd, unix::net::UnixStream},
    process::Child,
    sync::Arc,
};

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
            BindError, Client, Display, DisplayHandle,
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

#[derive(Clone, Debug)]
enum WaylandTransport {
    NamedSocket(OsString),
    DirectClientFd,
}

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
    transport: WaylandTransport,
    display_handle: DisplayHandle,
    space: Space<Window>,
    loop_signal: LoopSignal,
    compositor_state: CompositorState,
    xdg_shell_state: XdgShellState,
    shm_state: ShmState,
    seat_state: SeatState<Self>,
    launched_clients: Vec<Child>,
    exit_on_first_window: bool,
    exit_on_first_frame: bool,
    exit_on_client_disconnect: bool,
    selftest_drm: bool,
    kms_display: Option<kms::KmsDisplay>,
}

impl ShadowGuestCompositor {
    fn new(event_loop: &mut EventLoop<Self>, display: Display<Self>) -> Self {
        let display_handle = display.handle();
        let loop_signal = event_loop.get_signal();
        let exit_on_client_disconnect =
            std::env::var_os("SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT").is_some();
        let transport = Self::init_wayland_transport(
            display,
            event_loop,
            exit_on_client_disconnect.then_some(loop_signal.clone()),
        );

        Self {
            transport,
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
            exit_on_first_frame: std::env::var_os("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME")
                .is_some(),
            exit_on_client_disconnect,
            selftest_drm: std::env::var_os("SHADOW_GUEST_COMPOSITOR_SELFTEST_DRM").is_some(),
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

    fn init_wayland_transport(
        display: Display<Self>,
        event_loop: &mut EventLoop<Self>,
        disconnect_signal: Option<LoopSignal>,
    ) -> WaylandTransport {
        Self::insert_display_source(display, event_loop);

        let requested =
            std::env::var("SHADOW_GUEST_COMPOSITOR_TRANSPORT").unwrap_or_else(|_| "auto".into());
        match requested.as_str() {
            "socket" => WaylandTransport::NamedSocket(Self::insert_wayland_listener(
                event_loop,
                disconnect_signal,
            )),
            "direct" => {
                tracing::info!("[shadow-guest-compositor] transport=direct-client-fd");
                WaylandTransport::DirectClientFd
            }
            "auto" => match Self::try_insert_wayland_listener(event_loop, disconnect_signal) {
                Ok(socket_name) => WaylandTransport::NamedSocket(socket_name),
                Err(BindError::PermissionDenied) => {
                    tracing::warn!(
                        "[shadow-guest-compositor] socket transport denied; falling back to direct client fd"
                    );
                    WaylandTransport::DirectClientFd
                }
                Err(error) => panic!("create wayland socket: {error}"),
            },
            other => panic!("unknown SHADOW_GUEST_COMPOSITOR_TRANSPORT={other}"),
        }
    }

    fn insert_wayland_listener(
        event_loop: &mut EventLoop<Self>,
        disconnect_signal: Option<LoopSignal>,
    ) -> OsString {
        Self::try_insert_wayland_listener(event_loop, disconnect_signal)
            .expect("create wayland socket")
    }

    fn try_insert_wayland_listener(
        event_loop: &mut EventLoop<Self>,
        disconnect_signal: Option<LoopSignal>,
    ) -> Result<OsString, BindError> {
        let listener = ListeningSocketSource::new_auto()?;
        let socket_name = listener.socket_name().to_os_string();
        let handle = event_loop.handle();

        handle
            .insert_source(listener, move |client_stream, _, state| {
                state
                    .display_handle
                    .insert_client(
                        client_stream,
                        Arc::new(ClientState::new(disconnect_signal.clone())),
                    )
                    .expect("insert wayland client");
            })
            .expect("insert wayland socket");

        tracing::info!(
            "[shadow-guest-compositor] transport=named-socket socket={}",
            socket_name.to_string_lossy()
        );

        Ok(socket_name)
    }

    fn insert_display_source(display: Display<Self>, event_loop: &mut EventLoop<Self>) {
        let handle = event_loop.handle();
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
    }

    fn spawn_client(&mut self) -> std::io::Result<()> {
        let client_path = std::env::var("SHADOW_GUEST_CLIENT")
            .unwrap_or_else(|_| "/data/local/tmp/shadow-counter-guest".into());
        let runtime_dir = std::env::var("XDG_RUNTIME_DIR")
            .unwrap_or_else(|_| "/data/local/tmp/shadow-runtime".into());

        let mut command = std::process::Command::new(&client_path);
        command.env("XDG_RUNTIME_DIR", runtime_dir);
        if let Some(value) = std::env::var("SHADOW_GUEST_CLIENT_ENV").ok() {
            for assignment in value.split_whitespace() {
                if let Some((key, env_value)) = assignment.split_once('=') {
                    if !key.is_empty() {
                        command.env(key, env_value);
                    }
                }
            }
        }

        match &self.transport {
            WaylandTransport::NamedSocket(socket_name) => {
                command.env("WAYLAND_DISPLAY", socket_name);
            }
            WaylandTransport::DirectClientFd => {
                let (server_stream, client_stream) = UnixStream::pair()?;
                clear_cloexec(&client_stream)?;
                let raw_fd = client_stream.as_raw_fd();
                command
                    .env_remove("WAYLAND_DISPLAY")
                    .env("WAYLAND_SOCKET", raw_fd.to_string());
                self.display_handle
                    .insert_client(
                        server_stream,
                        Arc::new(ClientState::new(
                            self.exit_on_client_disconnect
                                .then_some(self.loop_signal.clone()),
                        )),
                    )
                    .expect("insert wayland client");
                let child = command.spawn()?;
                drop(client_stream);
                self.launched_clients.push(child);
                tracing::info!(
                    "[shadow-guest-compositor] launched-client={} transport=direct-client-fd fd={raw_fd}",
                    client_path
                );
                return Ok(());
            }
        }

        if let Some(value) = std::env::var_os("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE") {
            command.env("SHADOW_GUEST_COUNTER_EXIT_ON_CONFIGURE", value);
        }
        if let Some(value) = std::env::var_os("SHADOW_GUEST_COUNTER_LINGER_MS") {
            command.env("SHADOW_GUEST_COUNTER_LINGER_MS", value);
        }

        let child = command.spawn()?;
        self.launched_clients.push(child);
        tracing::info!(
            "[shadow-guest-compositor] launched-client={client_path} transport=named-socket"
        );
        Ok(())
    }

    fn handle_window_mapped(&mut self, window: Window) {
        self.space.map_element(window, (0, 0), false);
        tracing::info!("[shadow-guest-compositor] mapped-window");
        if self.exit_on_first_window {
            self.loop_signal.stop();
        }
    }

    fn publish_frame(&mut self, frame: &kms::CapturedFrame, frame_marker: &str) {
        let checksum = kms::frame_checksum(frame);
        tracing::info!(
            "[shadow-guest-compositor] {frame_marker} checksum={checksum:016x} size={}x{}",
            frame.width,
            frame.height
        );

        let artifact_path =
            std::env::var("SHADOW_GUEST_FRAME_PATH").unwrap_or_else(|_| "/shadow-frame.ppm".into());
        match kms::write_frame_ppm(frame, &artifact_path) {
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
                match display.present_frame(frame) {
                    Ok(()) => tracing::info!("[shadow-guest-compositor] presented-frame"),
                    Err(error) => {
                        tracing::warn!("[shadow-guest-compositor] present-frame failed: {error}")
                    }
                }
            }
        }

        if self.exit_on_first_frame {
            self.loop_signal.stop();
        }
    }

    fn run_drm_selftest(&mut self) {
        let Some(display) = self.ensure_kms_display() else {
            return;
        };
        let (width, height) = display.dimensions();
        let frame = kms::build_selftest_frame(width, height);
        self.publish_frame(&frame, "selftest-frame-generated");
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
                self.publish_frame(&frame, "captured-frame");
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

fn clear_cloexec(stream: &UnixStream) -> std::io::Result<()> {
    let fd = stream.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let updated = flags & !libc::FD_CLOEXEC;
    let result = unsafe { libc::fcntl(fd, libc::F_SETFD, updated) };
    if result < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

struct ClientState {
    compositor_state: CompositorClientState,
    disconnect_signal: Option<LoopSignal>,
}

impl ClientState {
    fn new(disconnect_signal: Option<LoopSignal>) -> Self {
        Self {
            compositor_state: CompositorClientState::default(),
            disconnect_signal,
        }
    }
}

impl ClientData for ClientState {
    fn initialized(&self, _client_id: ClientId) {}

    fn disconnected(&self, _client_id: ClientId, _reason: DisconnectReason) {
        if let Some(loop_signal) = &self.disconnect_signal {
            tracing::info!("[shadow-guest-compositor] client-disconnected");
            loop_signal.stop();
        }
    }
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

    match &state.transport {
        WaylandTransport::NamedSocket(socket_name) => tracing::info!(
            "[shadow-guest-compositor] transport=named-socket socket={}",
            socket_name.to_string_lossy()
        ),
        WaylandTransport::DirectClientFd => {
            tracing::info!("[shadow-guest-compositor] transport=direct-client-fd")
        }
    }
    if state.selftest_drm {
        tracing::info!("[shadow-guest-compositor] selftest-drm enabled");
        state.run_drm_selftest();
        if state.exit_on_first_frame {
            return Ok(());
        }
    } else {
        state.spawn_client()?;
    }
    event_loop.run(None, &mut state, |_| {})?;
    Ok(())
}
