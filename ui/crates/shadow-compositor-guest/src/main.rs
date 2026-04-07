mod kms;
mod touch;

use std::{
    ffi::OsString,
    fs,
    os::{fd::AsRawFd, unix::net::UnixStream},
    path::PathBuf,
    process::Child,
    sync::Arc,
    time::{Duration, Instant},
};

use smithay::{
    backend::allocator::{dmabuf::Dmabuf, Buffer as AllocatorBuffer, Format, Fourcc, Modifier},
    backend::input::ButtonState,
    backend::renderer::{
        buffer_dimensions,
        utils::{on_commit_buffer_handler, with_renderer_surface_state},
        BufferType,
    },
    delegate_compositor, delegate_dmabuf, delegate_presentation, delegate_seat, delegate_shm,
    delegate_xdg_shell,
    desktop::{Space, Window, WindowSurfaceType},
    input::{
        pointer::{ButtonEvent, MotionEvent},
        Seat, SeatHandler, SeatState,
    },
    reexports::{
        calloop::{channel, generic::Generic, EventLoop, Interest, LoopSignal, Mode, PostAction},
        wayland_server::{
            backend::{ClientData, ClientId, DisconnectReason},
            protocol::{wl_buffer, wl_seat, wl_surface::WlSurface},
            BindError, Client, Display, DisplayHandle,
        },
    },
    utils::{Logical, Point, Serial, SERIAL_COUNTER},
    wayland::{
        compositor::{
            get_parent, is_sync_subsurface, with_states, with_surface_tree_downward,
            CompositorClientState, CompositorHandler, CompositorState, SurfaceAttributes,
            TraversalAction,
        },
        dmabuf::{get_dmabuf, DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier},
        presentation::PresentationState,
        shell::xdg::{ToplevelSurface, XdgShellHandler, XdgShellState, XdgToplevelSurfaceData},
        shm::{with_buffer_contents, ShmHandler, ShmState},
        socket::ListeningSocketSource,
    },
};

const BTN_LEFT: u32 = 0x110;
const GUEST_RUNTIME_CLIENT_BIN: &str = "/data/local/tmp/shadow-blitz-demo";
const DEFAULT_TOPLEVEL_WIDTH: i32 = 384;
const DEFAULT_TOPLEVEL_HEIGHT: i32 = 720;

fn default_guest_client_path() -> String {
    GUEST_RUNTIME_CLIENT_BIN.into()
}

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
    start_time: Instant,
    transport: WaylandTransport,
    display_handle: DisplayHandle,
    space: Space<Window>,
    loop_signal: LoopSignal,
    compositor_state: CompositorState,
    xdg_shell_state: XdgShellState,
    shm_state: ShmState,
    dmabuf_state: DmabufState,
    _dmabuf_global: DmabufGlobal,
    _presentation_state: PresentationState,
    seat_state: SeatState<Self>,
    seat: Seat<Self>,
    launched_clients: Vec<Child>,
    exit_on_first_window: bool,
    exit_on_first_frame: bool,
    exit_on_client_disconnect: bool,
    exit_on_first_dma_buffer: bool,
    selftest_drm: bool,
    boot_splash_drm: bool,
    kms_display: Option<kms::KmsDisplay>,
    last_frame_size: Option<(u32, u32)>,
    last_buffer_signature: Option<String>,
    touch_signal_counter: u64,
    touch_signal_path: Option<PathBuf>,
}

impl ShadowGuestCompositor {
    fn new(event_loop: &mut EventLoop<Self>, display: Display<Self>) -> Self {
        let display_handle = display.handle();
        let loop_signal = event_loop.get_signal();
        let exit_on_client_disconnect =
            std::env::var_os("SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT").is_some();
        let dmabuf_formats = Self::supported_dmabuf_formats();
        let mut dmabuf_state = DmabufState::new();
        let dmabuf_global =
            dmabuf_state.create_global::<Self>(&display_handle, dmabuf_formats.clone());
        let presentation_state =
            PresentationState::new::<Self>(&display_handle, libc::CLOCK_MONOTONIC as u32);
        let transport = Self::init_wayland_transport(
            display,
            event_loop,
            exit_on_client_disconnect.then_some(loop_signal.clone()),
        );
        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(&display_handle, "shadow-guest");
        seat.add_pointer();

        let mut state = Self {
            start_time: Instant::now(),
            transport,
            display_handle: display_handle.clone(),
            space: Space::default(),
            loop_signal,
            compositor_state: CompositorState::new::<Self>(&display_handle),
            xdg_shell_state: XdgShellState::new::<Self>(&display_handle),
            shm_state: ShmState::new::<Self>(&display_handle, vec![]),
            dmabuf_state,
            _dmabuf_global: dmabuf_global,
            _presentation_state: presentation_state,
            seat_state,
            seat,
            launched_clients: Vec::new(),
            exit_on_first_window: std::env::var_os("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_WINDOW")
                .is_some(),
            exit_on_first_frame: std::env::var_os("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME")
                .is_some(),
            exit_on_client_disconnect,
            exit_on_first_dma_buffer: std::env::var_os(
                "SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_DMA_BUFFER",
            )
            .is_some(),
            selftest_drm: std::env::var_os("SHADOW_GUEST_COMPOSITOR_SELFTEST_DRM").is_some(),
            boot_splash_drm: std::env::var_os("SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM").is_some(),
            kms_display: None,
            last_frame_size: None,
            last_buffer_signature: None,
            touch_signal_counter: 0,
            touch_signal_path: std::env::var_os("SHADOW_GUEST_TOUCH_SIGNAL_PATH")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from),
        };
        tracing::info!(
            "[shadow-guest-compositor] dmabuf-global-ready formats={}",
            dmabuf_formats.len()
        );
        tracing::info!("[shadow-guest-compositor] presentation-global-ready");
        if let Some(path) = state.touch_signal_path.as_ref() {
            tracing::info!(
                "[shadow-guest-compositor] touch-signal-ready path={}",
                path.display()
            );
        }
        state.insert_touch_source(event_loop);
        state
    }

    fn supported_dmabuf_formats() -> Vec<Format> {
        vec![
            Format {
                code: Fourcc::Argb8888,
                modifier: Modifier::Invalid,
            },
            Format {
                code: Fourcc::Xrgb8888,
                modifier: Modifier::Invalid,
            },
            Format {
                code: Fourcc::Argb8888,
                modifier: Modifier::Linear,
            },
            Format {
                code: Fourcc::Xrgb8888,
                modifier: Modifier::Linear,
            },
        ]
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
                    state.reap_exited_clients();
                    Ok(PostAction::Continue)
                },
            )
            .expect("insert wayland display");
    }

    fn reap_exited_clients(&mut self) {
        self.launched_clients
            .retain_mut(|child| match child.try_wait() {
                Ok(Some(status)) => {
                    tracing::info!(
                        "[shadow-guest-compositor] launched-client-exited pid={} status={status}",
                        child.id()
                    );
                    false
                }
                Ok(None) => true,
                Err(error) => {
                    tracing::warn!(
                        "[shadow-guest-compositor] launched-client-wait-error pid={} error={error}",
                        child.id()
                    );
                    false
                }
            });
    }

    fn spawn_client(&mut self) -> std::io::Result<()> {
        let client_path =
            std::env::var("SHADOW_GUEST_CLIENT").unwrap_or_else(|_| default_guest_client_path());
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
        if let Some(value) = std::env::var_os("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE") {
            command.env("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE", value);
        }
        if let Some(value) = std::env::var_os("SHADOW_GUEST_CLIENT_LINGER_MS") {
            command.env("SHADOW_GUEST_CLIENT_LINGER_MS", value);
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
        self.log_window_state("mapped-window");
        if self.exit_on_first_window {
            self.loop_signal.stop();
        }
    }

    fn insert_touch_source(&mut self, event_loop: &mut EventLoop<Self>) {
        let touch_device = match touch::detect_touch_device() {
            Ok(device) => device,
            Err(error) => {
                tracing::warn!("[shadow-guest-compositor] touch-unavailable: {error}");
                return;
            }
        };

        tracing::info!(
            "[shadow-guest-compositor] touch-ready device={} name={} range={}..={}x{}..={}",
            touch_device.path.display(),
            touch_device.name,
            touch_device.x_min,
            touch_device.x_max,
            touch_device.y_min,
            touch_device.y_max
        );

        let (sender, receiver) = channel::channel();
        event_loop
            .handle()
            .insert_source(receiver, |event, _, state| match event {
                channel::Event::Msg(event) => state.handle_touch_input(event),
                channel::Event::Closed => {
                    tracing::warn!("[shadow-guest-compositor] touch-source closed")
                }
            })
            .expect("insert touch source");
        touch::spawn_touch_reader(touch_device, sender);
    }

    fn handle_touch_input(&mut self, event: touch::TouchInputEvent) {
        self.signal_touch_event(&event);
        let pointer = self.seat.get_pointer().expect("guest seat pointer");
        let serial = SERIAL_COUNTER.next_serial();

        match event.phase {
            touch::TouchPhase::Down | touch::TouchPhase::Move => {
                tracing::info!(
                    "[shadow-guest-compositor] touch-input phase={:?} normalized={:.3},{:.3}",
                    event.phase,
                    event.normalized_x,
                    event.normalized_y
                );
                let Some(position) = self.touch_position(event.normalized_x, event.normalized_y)
                else {
                    self.log_touch_mapping(event.normalized_x, event.normalized_y);
                    tracing::info!(
                        "[shadow-guest-compositor] touch-outside-content normalized={:.3},{:.3}",
                        event.normalized_x,
                        event.normalized_y
                    );
                    return;
                };
                let under = self.surface_under(position);
                tracing::info!(
                    "[shadow-guest-compositor] touch-pointer phase={:?} x={:.1} y={:.1} surface={}",
                    event.phase,
                    position.x,
                    position.y,
                    under.is_some()
                );
                if under.is_none() && matches!(event.phase, touch::TouchPhase::Down) {
                    self.log_window_state("touch-miss");
                }
                if matches!(event.phase, touch::TouchPhase::Down) {
                    self.raise_window_for_pointer_focus(under.as_ref().map(|(surface, _)| surface));
                }
                pointer.motion(
                    self,
                    under,
                    &MotionEvent {
                        location: position,
                        serial,
                        time: event.time_msec,
                    },
                );
                if matches!(event.phase, touch::TouchPhase::Down) {
                    pointer.button(
                        self,
                        &ButtonEvent {
                            button: BTN_LEFT,
                            state: ButtonState::Pressed,
                            serial,
                            time: event.time_msec,
                        },
                    );
                }
                pointer.frame(self);
                self.flush_wayland_clients();
            }
            touch::TouchPhase::Up => {
                tracing::info!("[shadow-guest-compositor] touch-input phase=Up");
                pointer.button(
                    self,
                    &ButtonEvent {
                        button: BTN_LEFT,
                        state: ButtonState::Released,
                        serial,
                        time: event.time_msec,
                    },
                );
                pointer.frame(self);
                self.flush_wayland_clients();
            }
        }
    }

    fn touch_position(
        &mut self,
        normalized_x: f64,
        normalized_y: f64,
    ) -> Option<Point<f64, Logical>> {
        let (frame_width, frame_height) = self.last_frame_size?;
        let (panel_width, panel_height) = self.ensure_kms_display()?.dimensions();
        let (x, y) = touch::map_normalized_touch_to_frame(
            normalized_x,
            normalized_y,
            panel_width,
            panel_height,
            frame_width,
            frame_height,
        )?;
        Some((x, y).into())
    }

    fn signal_touch_event(&mut self, event: &touch::TouchInputEvent) {
        if !matches!(event.phase, touch::TouchPhase::Down) {
            return;
        }
        let Some(path) = self.touch_signal_path.as_ref() else {
            return;
        };

        self.touch_signal_counter = self.touch_signal_counter.saturating_add(1);
        let token = self.touch_signal_counter.to_string();
        match fs::write(path, &token) {
            Ok(()) => tracing::info!(
                "[shadow-guest-compositor] touch-signal-write counter={} path={} normalized={:.3},{:.3}",
                token,
                path.display(),
                event.normalized_x,
                event.normalized_y
            ),
            Err(error) => tracing::warn!(
                "[shadow-guest-compositor] touch-signal-write-failed path={} error={error}",
                path.display()
            ),
        }
    }

    fn log_touch_mapping(&mut self, normalized_x: f64, normalized_y: f64) {
        if std::env::var_os("SHADOW_GUEST_LOG_TOUCH_GEOMETRY").is_none() {
            return;
        }
        let Some((frame_width, frame_height)) = self.last_frame_size else {
            return;
        };
        let Some(display) = self.ensure_kms_display() else {
            return;
        };
        let (panel_width, panel_height) = display.dimensions();
        let Some((dst_x, dst_y, copy_width, copy_height)) =
            touch::frame_content_rect(panel_width, panel_height, frame_width, frame_height)
        else {
            return;
        };
        let panel_x = normalized_x.clamp(0.0, 1.0) * f64::from(panel_width.saturating_sub(1));
        let panel_y = normalized_y.clamp(0.0, 1.0) * f64::from(panel_height.saturating_sub(1));
        tracing::info!(
            "[shadow-guest-compositor] touch-content-rect panel={}x{} frame={}x{} rect={}x{}+{},{} panel_xy={:.1},{:.1}",
            panel_width,
            panel_height,
            frame_width,
            frame_height,
            copy_width,
            copy_height,
            dst_x,
            dst_y,
            panel_x,
            panel_y
        );
    }

    fn surface_under(
        &self,
        position: Point<f64, Logical>,
    ) -> Option<(WlSurface, Point<f64, Logical>)> {
        self.space
            .element_under(position)
            .and_then(|(window, location)| {
                window
                    .surface_under(position - location.to_f64(), WindowSurfaceType::ALL)
                    .map(|(surface, point)| (surface, (point + location).to_f64()))
            })
    }

    fn raise_window_for_pointer_focus(&mut self, surface: Option<&WlSurface>) {
        let Some(surface) = surface else {
            return;
        };
        let root_surface = self.root_surface(surface);
        let Some(window) = self
            .space
            .elements()
            .find(|candidate| candidate.toplevel().unwrap().wl_surface() == &root_surface)
            .cloned()
        else {
            return;
        };

        self.space.raise_element(&window, true);
        self.space.elements().for_each(|candidate| {
            let is_active = candidate.toplevel().unwrap().wl_surface() == &root_surface;
            candidate.set_activated(is_active);
            candidate.toplevel().unwrap().send_pending_configure();
        });
    }

    fn root_surface(&self, surface: &WlSurface) -> WlSurface {
        let mut root_surface = surface.clone();
        while let Some(parent) = get_parent(&root_surface) {
            root_surface = parent;
        }
        root_surface
    }

    fn flush_wayland_clients(&mut self) {
        if let Err(error) = self.display_handle.flush_clients() {
            tracing::warn!("[shadow-guest-compositor] flush-clients failed: {error}");
        }
    }

    fn configured_toplevel_size(&self) -> smithay::utils::Size<i32, Logical> {
        let width = std::env::var("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH")
            .ok()
            .and_then(|value| value.parse::<i32>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(DEFAULT_TOPLEVEL_WIDTH);
        let height = std::env::var("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT")
            .ok()
            .and_then(|value| value.parse::<i32>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(DEFAULT_TOPLEVEL_HEIGHT);
        (width, height).into()
    }

    fn configure_toplevel(&self, surface: &ToplevelSurface) {
        let size = self.configured_toplevel_size();
        surface.with_pending_state(|state| {
            state.size = Some(size);
            state.bounds = Some(size);
        });
        tracing::info!(
            "[shadow-guest-compositor] configure-toplevel size={}x{}",
            size.w,
            size.h
        );
    }

    fn log_window_state(&self, reason: &str) {
        for (index, window) in self.space.elements().enumerate() {
            let location = self.space.element_location(window);
            let bbox = self.space.element_bbox(window);
            let geometry = self.space.element_geometry(window);
            tracing::info!(
                "[shadow-guest-compositor] window-state reason={} index={} location={:?} bbox={:?} geometry={:?}",
                reason,
                index,
                location,
                bbox,
                geometry
            );
        }
    }

    fn publish_frame(&mut self, frame: &kms::CapturedFrame, frame_marker: &str) {
        self.last_frame_size = Some((frame.width, frame.height));
        let checksum = kms::frame_checksum(frame);
        tracing::info!(
            "[shadow-guest-compositor] {frame_marker} checksum={checksum:016x} size={}x{}",
            frame.width,
            frame.height
        );
        if let Some(display) = self.ensure_kms_display() {
            let (panel_width, panel_height) = display.dimensions();
            if let Some((dst_x, dst_y, copy_width, copy_height)) =
                touch::frame_content_rect(panel_width, panel_height, frame.width, frame.height)
            {
                tracing::info!(
                    "[shadow-guest-compositor] frame-content-rect panel={}x{} frame={}x{} rect={}x{}+{},{}",
                    panel_width,
                    panel_height,
                    frame.width,
                    frame.height,
                    copy_width,
                    copy_height,
                    dst_x,
                    dst_y
                );
            }
        }

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

    fn run_boot_splash(&mut self) {
        let Some(display) = self.ensure_kms_display() else {
            return;
        };
        let (panel_width, panel_height) = display.dimensions();
        let frame = kms::build_boot_splash_frame(panel_width, panel_height);
        self.publish_frame(&frame, "boot-splash-frame-generated");
    }

    fn take_surface_buffer(
        &self,
        surface: &WlSurface,
    ) -> Option<smithay::backend::renderer::utils::Buffer> {
        with_renderer_surface_state(surface, |state| state.buffer().cloned()).flatten()
    }

    fn observe_surface_buffer(
        &mut self,
        buffer: &smithay::backend::renderer::utils::Buffer,
    ) -> Option<BufferType> {
        let buffer_type = smithay::backend::renderer::buffer_type(buffer);
        let signature = match buffer_type {
            Some(BufferType::Dma) => {
                let dmabuf = get_dmabuf(buffer).expect("dmabuf-managed buffer");
                let size = dmabuf.size();
                let format = dmabuf.format();
                format!(
                    "type=dma size={}x{} fourcc={:?} modifier={:?} planes={} y_inverted={}",
                    size.w,
                    size.h,
                    format.code,
                    format.modifier,
                    dmabuf.num_planes(),
                    dmabuf.y_inverted()
                )
            }
            Some(BufferType::Shm) => {
                let size = buffer_dimensions(buffer)
                    .map(|size| format!("{}x{}", size.w, size.h))
                    .unwrap_or_else(|| "unknown".into());
                format!("type=shm size={size}")
            }
            Some(BufferType::SinglePixel) => "type=single-pixel size=1x1".into(),
            Some(_) => "type=other".into(),
            None => "type=unknown".into(),
        };

        if self.last_buffer_signature.as_ref() != Some(&signature) {
            tracing::info!("[shadow-guest-compositor] buffer-observed {signature}");
            self.last_buffer_signature = Some(signature);
        }

        if matches!(buffer_type, Some(BufferType::Dma)) && self.exit_on_first_dma_buffer {
            tracing::info!("[shadow-guest-compositor] exit-on-first-dma-buffer");
            self.loop_signal.stop();
        }

        buffer_type
    }

    fn present_surface(&mut self, surface: &WlSurface) {
        let Some(buffer) = self.take_surface_buffer(surface) else {
            self.send_frame_callbacks(surface);
            return;
        };
        let observed_type = self.observe_surface_buffer(&buffer);
        if !matches!(observed_type, Some(BufferType::Shm)) {
            if matches!(observed_type, Some(BufferType::Dma)) {
                tracing::warn!("[shadow-guest-compositor] dmabuf-frame-capture-not-supported-yet");
            } else {
                tracing::warn!(
                    "[shadow-guest-compositor] unsupported-frame-buffer type={:?}",
                    observed_type
                );
            }
            buffer.release();
            self.send_frame_callbacks(surface);
            return;
        }
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
        self.send_frame_callbacks(surface);
    }

    fn send_frame_callbacks(&mut self, surface: &WlSurface) {
        let elapsed = self.start_time.elapsed();
        with_surface_tree_downward(
            surface,
            (),
            |_, _, &()| TraversalAction::DoChildren(()),
            |_surface, states, &()| {
                for callback in states
                    .cached_state
                    .get::<SurfaceAttributes>()
                    .current()
                    .frame_callbacks
                    .drain(..)
                {
                    callback.done(elapsed.as_millis() as u32);
                }
            },
            |_, _, &()| true,
        );
        self.space.refresh();
        self.flush_wayland_clients();
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

    fn disconnected(&self, _client_id: ClientId, reason: DisconnectReason) {
        if let Some(loop_signal) = &self.disconnect_signal {
            tracing::info!("[shadow-guest-compositor] client-disconnected reason={reason:?}");
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
                self.configure_toplevel(window.toplevel().unwrap());
                let _ = window.toplevel().unwrap().send_pending_configure();
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

impl DmabufHandler for ShadowGuestCompositor {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self.dmabuf_state
    }

    fn dmabuf_imported(
        &mut self,
        _global: &DmabufGlobal,
        dmabuf: Dmabuf,
        notifier: ImportNotifier,
    ) {
        let size = dmabuf.size();
        let format = dmabuf.format();
        tracing::info!(
            "[shadow-guest-compositor] dmabuf-imported size={}x{} fourcc={:?} modifier={:?} planes={} y_inverted={}",
            size.w,
            size.h,
            format.code,
            format.modifier,
            dmabuf.num_planes(),
            dmabuf.y_inverted()
        );
        let _ = notifier.successful::<Self>();
    }
}

impl XdgShellHandler for ShadowGuestCompositor {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell_state
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        self.configure_toplevel(&surface);
        let _ = surface.send_pending_configure();
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
delegate_dmabuf!(ShadowGuestCompositor);
delegate_presentation!(ShadowGuestCompositor);
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
        if state.boot_splash_drm {
            tracing::info!("[shadow-guest-compositor] boot-splash-drm enabled");
            state.run_boot_splash();
        }
        state.spawn_client()?;
    }
    event_loop.run(None, &mut state, |_| {})?;
    Ok(())
}
