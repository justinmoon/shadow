mod config;
mod control;
mod kms;
mod launch;
mod shell;
mod touch;

use std::{
    collections::HashMap,
    ffi::OsString,
    fs,
    os::{fd::AsRawFd, unix::net::UnixStream},
    path::PathBuf,
    process::Child,
    sync::Arc,
    time::{Duration, Instant},
};

use chrono::Local;
use config::{GuestClientConfig, GuestStartupConfig, StartupAction, TransportRequest};
use shadow_ui_core::{
    app::{self, AppId},
    control::ControlRequest,
    scene::{
        APP_VIEWPORT_HEIGHT, APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH, APP_VIEWPORT_WIDTH_PX,
        APP_VIEWPORT_X, APP_VIEWPORT_Y, HEIGHT, WIDTH,
    },
    shell::{ShellAction, ShellEvent, ShellModel, ShellStatus},
};
use shell::{AppFrame, GuestShellSurface};
use smithay::{
    backend::allocator::{dmabuf::Dmabuf, Buffer as AllocatorBuffer, Format, Fourcc, Modifier},
    backend::input::{Axis, AxisSource, ButtonState},
    backend::renderer::{
        buffer_dimensions,
        utils::{on_commit_buffer_handler, with_renderer_surface_state},
        BufferType,
    },
    delegate_compositor, delegate_dmabuf, delegate_presentation, delegate_seat, delegate_shm,
    delegate_xdg_shell,
    desktop::{Space, Window, WindowSurfaceType},
    input::{
        pointer::{AxisFrame, ButtonEvent, MotionEvent},
        Seat, SeatHandler, SeatState,
    },
    reexports::{
        calloop::{channel, generic::Generic, EventLoop, Interest, LoopSignal, Mode, PostAction},
        wayland_server::{
            backend::{ClientData, ClientId, DisconnectReason},
            protocol::{wl_buffer, wl_seat, wl_shm, wl_surface::WlSurface},
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
const DEFAULT_TOPLEVEL_WIDTH: i32 = APP_VIEWPORT_WIDTH_PX as i32;
const DEFAULT_TOPLEVEL_HEIGHT: i32 = APP_VIEWPORT_HEIGHT_PX as i32;
const APP_TOUCH_SCROLL_THRESHOLD: f64 = 18.0;

pub(crate) fn default_guest_client_path() -> String {
    GUEST_RUNTIME_CLIENT_BIN.into()
}

#[derive(Clone, Debug)]
enum WaylandTransport {
    NamedSocket(OsString),
    DirectClientFd,
}

#[derive(Clone, Copy, Debug)]
struct AppTouchGesture {
    start: Point<f64, Logical>,
    last: Point<f64, Logical>,
    scrolling: bool,
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
    launched_apps: HashMap<AppId, Child>,
    app_frames: HashMap<AppId, kms::CapturedFrame>,
    surface_apps: HashMap<WlSurface, AppId>,
    shelved_windows: HashMap<AppId, Window>,
    focused_app: Option<AppId>,
    shell_enabled: bool,
    client_config: GuestClientConfig,
    shell: ShellModel,
    shell_surface: GuestShellSurface,
    shell_touch_active: bool,
    app_touch_gesture: Option<AppTouchGesture>,
    pub(crate) control_socket_path: PathBuf,
    exit_on_first_window: bool,
    exit_on_first_frame: bool,
    exit_on_client_disconnect: bool,
    exit_on_first_dma_buffer: bool,
    selftest_drm: bool,
    boot_splash_drm: bool,
    kms_display: Option<kms::KmsDisplay>,
    last_frame_size: Option<(u32, u32)>,
    last_buffer_signature: Option<String>,
    toplevel_size: smithay::utils::Size<i32, Logical>,
    frame_artifact_path: PathBuf,
    drm_enabled: bool,
    log_touch_geometry: bool,
    touch_signal_counter: u64,
    touch_signal_path: Option<PathBuf>,
}

impl ShadowGuestCompositor {
    fn new(
        config: &GuestStartupConfig,
        event_loop: &mut EventLoop<Self>,
        display: Display<Self>,
    ) -> Self {
        let display_handle = display.handle();
        let loop_signal = event_loop.get_signal();
        let shell_enabled = config.startup_action.shell_enabled();
        let exit_on_client_disconnect = config.exit_on_client_disconnect;
        let dmabuf_formats = Self::supported_dmabuf_formats();
        let mut dmabuf_state = DmabufState::new();
        let dmabuf_global =
            dmabuf_state.create_global::<Self>(&display_handle, dmabuf_formats.clone());
        let presentation_state =
            PresentationState::new::<Self>(&display_handle, libc::CLOCK_MONOTONIC as u32);
        let transport = Self::init_wayland_transport(
            config.transport,
            display,
            event_loop,
            exit_on_client_disconnect.then_some(loop_signal.clone()),
        );
        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(&display_handle, "shadow-guest");
        if config.keyboard_seat_enabled {
            seat.add_keyboard(Default::default(), 200, 25).unwrap();
        }
        seat.add_pointer();
        let control_socket_path =
            control::init_listener(event_loop).expect("create guest compositor control socket");

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
            launched_apps: HashMap::new(),
            app_frames: HashMap::new(),
            surface_apps: HashMap::new(),
            shelved_windows: HashMap::new(),
            focused_app: None,
            shell_enabled,
            client_config: config.client.clone(),
            shell: ShellModel::new(),
            shell_surface: GuestShellSurface::new(WIDTH as u32, HEIGHT as u32),
            shell_touch_active: false,
            app_touch_gesture: None,
            control_socket_path,
            exit_on_first_window: config.exit_on_first_window,
            exit_on_first_frame: config.exit_on_first_frame,
            exit_on_client_disconnect,
            exit_on_first_dma_buffer: config.exit_on_first_dma_buffer,
            selftest_drm: config.selftest_drm,
            boot_splash_drm: config.boot_splash_drm,
            kms_display: None,
            last_frame_size: None,
            last_buffer_signature: None,
            toplevel_size: (config.toplevel_width, config.toplevel_height).into(),
            frame_artifact_path: config.frame_artifact_path.clone(),
            drm_enabled: config.drm_enabled,
            log_touch_geometry: config.log_touch_geometry,
            touch_signal_counter: 0,
            touch_signal_path: config.touch_signal_path.clone(),
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
        requested: TransportRequest,
        display: Display<Self>,
        event_loop: &mut EventLoop<Self>,
        disconnect_signal: Option<LoopSignal>,
    ) -> WaylandTransport {
        Self::insert_display_source(display, event_loop);

        match requested {
            TransportRequest::Socket => WaylandTransport::NamedSocket(
                Self::insert_wayland_listener(event_loop, disconnect_signal),
            ),
            TransportRequest::Direct => {
                tracing::info!("[shadow-guest-compositor] transport=direct-client-fd");
                WaylandTransport::DirectClientFd
            }
            TransportRequest::Auto => {
                match Self::try_insert_wayland_listener(event_loop, disconnect_signal) {
                    Ok(socket_name) => WaylandTransport::NamedSocket(socket_name),
                    Err(BindError::PermissionDenied) => {
                        tracing::warn!(
                        "[shadow-guest-compositor] socket transport denied; falling back to direct client fd"
                    );
                        WaylandTransport::DirectClientFd
                    }
                    Err(error) => panic!("create wayland socket: {error}"),
                }
            }
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
        self.launched_apps
            .retain(|app_id, child| match child.try_wait() {
                Ok(Some(status)) => {
                    tracing::info!(
                        "[shadow-guest-compositor] launched-app-exited app={} pid={} status={status}",
                        app_id.as_str(),
                        child.id()
                    );
                    false
                }
                Ok(None) => true,
                Err(error) => {
                    tracing::warn!(
                        "[shadow-guest-compositor] launched-app-wait-error app={} pid={} error={error}",
                        app_id.as_str(),
                        child.id()
                    );
                    false
                }
            });
    }

    pub(crate) fn spawn_wayland_command(
        &mut self,
        mut command: std::process::Command,
        label: &str,
    ) -> std::io::Result<Child> {
        match &self.transport {
            WaylandTransport::NamedSocket(socket_name) => {
                command.env("WAYLAND_DISPLAY", socket_name);
                let child = command.spawn()?;
                tracing::info!(
                    "[shadow-guest-compositor] launched-client={label} transport=named-socket"
                );
                Ok(child)
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
                tracing::info!(
                    "[shadow-guest-compositor] launched-client={label} transport=direct-client-fd fd={raw_fd}"
                );
                Ok(child)
            }
        }
    }

    fn spawn_client(&mut self) -> std::io::Result<()> {
        let child = launch::spawn_client(self)?;
        self.launched_clients.push(child);
        Ok(())
    }

    fn handle_window_mapped(&mut self, window: Window) {
        self.space
            .map_element(window.clone(), self.app_window_location(), false);
        self.focus_window(Some(window));
        tracing::info!("[shadow-guest-compositor] mapped-window");
        self.log_window_state("mapped-window");
        if self.exit_on_first_window {
            self.loop_signal.stop();
        }
    }

    fn app_window_location(&self) -> (i32, i32) {
        if self.shell_enabled {
            (APP_VIEWPORT_X.round() as i32, APP_VIEWPORT_Y.round() as i32)
        } else {
            (0, 0)
        }
    }

    fn app_window_size(&self) -> smithay::utils::Size<i32, Logical> {
        if self.shell_enabled {
            (
                APP_VIEWPORT_WIDTH.round() as i32,
                APP_VIEWPORT_HEIGHT.round() as i32,
            )
                .into()
        } else {
            self.configured_toplevel_size()
        }
    }

    fn shell_render_size(&mut self) -> (u32, u32) {
        self.ensure_kms_display()
            .map(|display| display.dimensions())
            .unwrap_or((WIDTH.round() as u32, HEIGHT.round() as u32))
    }

    fn shell_local_point(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        ((0.0..=WIDTH as f64).contains(&position.x) && (0.0..=HEIGHT as f64).contains(&position.y))
            .then_some((position.x as f32, position.y as f32))
    }

    fn shell_captures_point(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        if !self.shell_enabled {
            return None;
        }

        let (x, y) = self.shell_local_point(position)?;
        self.shell.captures_point(x, y).then_some((x, y))
    }

    fn handle_shell_event(&mut self, event: ShellEvent) {
        if !self.shell_enabled {
            return;
        }
        if let Some(action) = self.shell.handle(event) {
            self.handle_shell_action(action);
        }
    }

    fn handle_shell_action(&mut self, action: ShellAction) {
        match action {
            ShellAction::Launch { app_id } => {
                if let Err(error) = self.launch_or_focus_app(app_id) {
                    tracing::warn!(
                        "[shadow-guest-compositor] failed to launch/focus {}: {error}",
                        app_id.as_str()
                    );
                }
            }
            ShellAction::Home => self.go_home(),
        }
    }

    fn publish_visible_shell_frame(&mut self, frame_marker: &str) {
        if !self.shell_enabled {
            return;
        }

        let status = ShellStatus::demo(Local::now());
        let scene = self.shell.scene(&status);
        let (render_width, render_height) = self.shell_render_size();
        self.shell_surface.resize(render_width, render_height);
        let app_frame = self.focused_app.and_then(|app_id| {
            self.app_frames.get(&app_id).map(|frame| AppFrame {
                width: frame.width,
                height: frame.height,
                stride: frame.stride,
                format: frame.format,
                pixels: &frame.pixels,
            })
        });
        let pixels = self
            .shell_surface
            .render_scene_with_app_frame(&scene, app_frame)
            .to_vec();
        let frame = kms::captured_frame_from_pixels(
            render_width,
            render_height,
            pixels,
            wl_shm::Format::Xrgb8888,
        )
        .expect("shell scene pixels match frame dimensions");
        self.publish_frame(&frame, frame_marker);
    }

    fn window_for_surface(&self, surface: &WlSurface) -> Option<Window> {
        self.space
            .elements()
            .find(|candidate| candidate.toplevel().unwrap().wl_surface() == surface)
            .cloned()
    }

    fn mapped_window_for_app(&self, app_id: AppId) -> Option<Window> {
        self.surface_apps
            .iter()
            .find_map(|(surface, mapped_app_id)| {
                (*mapped_app_id == app_id)
                    .then(|| self.window_for_surface(surface))
                    .flatten()
            })
    }

    fn remember_surface_app(&mut self, surface: &WlSurface, app_id: AppId) {
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
        tracing::info!(
            "[shadow-guest-compositor] surface-app-tracked app={} surface={surface:?}",
            app_id.as_str()
        );
    }

    fn forget_surface(&mut self, surface: &WlSurface) -> Option<AppId> {
        let removed = self.surface_apps.remove(surface);
        if removed == self.focused_app {
            self.focused_app = None;
            self.shell.set_foreground_app(None);
        }
        if let Some(app_id) = removed {
            self.shell.set_app_running(app_id, false);
            self.app_frames.remove(&app_id);
        }
        removed
    }

    fn focus_window(&mut self, window: Option<Window>) {
        let serial = SERIAL_COUNTER.next_serial();

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

    fn focus_top_window(&mut self) {
        let window = self.space.elements().last().cloned();
        self.focus_window(window);
    }

    fn go_home(&mut self) {
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
        self.publish_visible_shell_frame("shell-home-frame");
    }

    fn terminate_app(&mut self, app_id: AppId) {
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

    fn terminate_other_apps(&mut self, keep_app: AppId) {
        let mut to_terminate: Vec<_> = self
            .launched_apps
            .keys()
            .chain(self.shelved_windows.keys())
            .chain(self.surface_apps.values())
            .copied()
            .filter(|app_id| *app_id != keep_app)
            .collect();
        to_terminate.sort_by_key(|app_id| app_id.as_str().to_string());
        to_terminate.dedup();

        for app_id in to_terminate {
            self.terminate_app(app_id);
        }
    }

    fn launch_or_focus_app(&mut self, app_id: AppId) -> std::io::Result<()> {
        self.reap_exited_clients();

        if self.focused_app.is_some_and(|current| current != app_id) {
            self.go_home();
        }

        self.terminate_other_apps(app_id);

        if let Some(window) = self.mapped_window_for_app(app_id) {
            self.focus_window(Some(window));
            self.publish_visible_shell_frame("shell-app-focus-frame");
            return Ok(());
        }

        if let Some(window) = self.shelved_windows.remove(&app_id) {
            self.space
                .map_element(window.clone(), self.app_window_location(), false);
            self.focus_window(Some(window));
            self.publish_visible_shell_frame("shell-app-resume-frame");
            return Ok(());
        }

        if self.launched_apps.contains_key(&app_id) {
            return Ok(());
        }

        let child = launch::launch_app(self, app_id)?;
        self.launched_apps.insert(app_id, child);
        Ok(())
    }

    fn handle_control_request(&mut self, request: ControlRequest) -> std::io::Result<String> {
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
            ControlRequest::State => Ok(self.control_state_response()),
        }
    }

    fn handle_control_tap(&mut self, x: i32, y: i32) -> std::io::Result<String> {
        let position = Point::<f64, Logical>::from((f64::from(x), f64::from(y)));
        let time = self.start_time.elapsed().as_millis() as u32;

        if let Some((shell_x, shell_y)) = self
            .shell_captures_point(position)
            .and_then(|_| self.shell_local_point(position))
        {
            tracing::info!(
                "[shadow-guest-compositor] control-tap-shell x={} y={} local_x={:.1} local_y={:.1}",
                x,
                y,
                shell_x,
                shell_y
            );
            self.handle_shell_event(ShellEvent::PointerMoved {
                x: shell_x,
                y: shell_y,
            });
            self.handle_shell_event(ShellEvent::TouchTap {
                x: shell_x,
                y: shell_y,
            });
            self.publish_visible_shell_frame("control-tap-shell-frame");
            return Ok("ok\n".to_string());
        }

        let Some(under) = self.surface_under(position) else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("tap target {x},{y} is outside the current content"),
            ));
        };

        tracing::info!(
            "[shadow-guest-compositor] control-tap-app x={} y={} surface=true",
            x,
            y
        );
        let serial = SERIAL_COUNTER.next_serial();
        let pointer = self.seat.get_pointer().expect("guest seat pointer");
        self.raise_window_for_pointer_focus(Some(&under.0));
        pointer.motion(
            self,
            Some(under.clone()),
            &MotionEvent {
                location: position,
                serial,
                time,
            },
        );
        pointer.button(
            self,
            &ButtonEvent {
                button: BTN_LEFT,
                state: ButtonState::Pressed,
                serial,
                time,
            },
        );
        pointer.button(
            self,
            &ButtonEvent {
                button: BTN_LEFT,
                state: ButtonState::Released,
                serial,
                time,
            },
        );
        pointer.frame(self);
        self.flush_wayland_clients();
        Ok("ok\n".to_string())
    }

    fn control_state_response(&mut self) -> String {
        self.reap_exited_clients();

        let focused = self.focused_app.map(AppId::as_str).unwrap_or("");
        let mapped = self.mapped_app_ids();
        let launched = self.launched_app_ids();
        let shelved = self.shelved_app_ids();
        let transport = match &self.transport {
            WaylandTransport::NamedSocket(socket_name) => {
                socket_name.to_string_lossy().into_owned()
            }
            WaylandTransport::DirectClientFd => "direct-client-fd".to_string(),
        };
        format!(
            "focused={focused}\nmapped={mapped}\nlaunched={launched}\nshelved={shelved}\nwindows={}\ntransport={transport}\ncontrol_socket={}\n",
            self.space.elements().count(),
            self.control_socket_path.display(),
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

    fn shelved_app_ids(&self) -> String {
        let mut app_ids: Vec<_> = self
            .shelved_windows
            .keys()
            .copied()
            .map(AppId::as_str)
            .collect();
        app_ids.sort_unstable();
        app_ids.join(",")
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
                    if self.shell_touch_active {
                        self.handle_shell_event(ShellEvent::PointerLeft);
                        self.shell_touch_active = false;
                        self.publish_visible_shell_frame("shell-touch-frame");
                    }
                    if let Some(gesture) = self.app_touch_gesture.take() {
                        if gesture.scrolling {
                            pointer.axis(
                                self,
                                AxisFrame::new(event.time_msec)
                                    .source(AxisSource::Finger)
                                    .stop(Axis::Horizontal)
                                    .stop(Axis::Vertical),
                            );
                            pointer.frame(self);
                            self.flush_wayland_clients();
                        }
                    }
                    self.log_touch_mapping(event.normalized_x, event.normalized_y);
                    tracing::info!(
                        "[shadow-guest-compositor] touch-outside-content normalized={:.3},{:.3}",
                        event.normalized_x,
                        event.normalized_y
                    );
                    return;
                };
                let shell_point = self.shell_captures_point(position);
                let shell_handles_touch = match event.phase {
                    touch::TouchPhase::Down => shell_point.is_some(),
                    touch::TouchPhase::Move => self.shell_touch_active,
                    touch::TouchPhase::Up => false,
                };
                if shell_handles_touch {
                    if let Some(gesture) = self.app_touch_gesture.take() {
                        if gesture.scrolling {
                            pointer.axis(
                                self,
                                AxisFrame::new(event.time_msec)
                                    .source(AxisSource::Finger)
                                    .stop(Axis::Horizontal)
                                    .stop(Axis::Vertical),
                            );
                            pointer.frame(self);
                            self.flush_wayland_clients();
                        }
                    }
                    let (x, y) = self
                        .shell_local_point(position)
                        .unwrap_or((position.x as f32, position.y as f32));
                    tracing::info!(
                        "[shadow-guest-compositor] touch-shell phase={:?} x={:.1} y={:.1}",
                        event.phase,
                        x,
                        y
                    );
                    self.handle_shell_event(ShellEvent::PointerMoved { x, y });
                    if matches!(event.phase, touch::TouchPhase::Down) {
                        self.shell_touch_active = true;
                    }
                    self.publish_visible_shell_frame("shell-touch-frame");
                    return;
                }
                self.shell_touch_active = false;
                self.handle_shell_event(ShellEvent::PointerLeft);
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
                match event.phase {
                    touch::TouchPhase::Down => {
                        if under.is_none() {
                            return;
                        }
                        self.raise_window_for_pointer_focus(
                            under.as_ref().map(|(surface, _)| surface),
                        );
                        pointer.motion(
                            self,
                            under,
                            &MotionEvent {
                                location: position,
                                serial,
                                time: event.time_msec,
                            },
                        );
                        self.app_touch_gesture = Some(AppTouchGesture {
                            start: position,
                            last: position,
                            scrolling: false,
                        });
                        pointer.frame(self);
                        self.flush_wayland_clients();
                    }
                    touch::TouchPhase::Move => {
                        let Some(mut gesture) = self.app_touch_gesture.take() else {
                            return;
                        };

                        pointer.motion(
                            self,
                            under,
                            &MotionEvent {
                                location: position,
                                serial,
                                time: event.time_msec,
                            },
                        );

                        let total_dx = position.x - gesture.start.x;
                        let total_dy = position.y - gesture.start.y;
                        if !gesture.scrolling
                            && (total_dx.abs() >= APP_TOUCH_SCROLL_THRESHOLD
                                || total_dy.abs() >= APP_TOUCH_SCROLL_THRESHOLD)
                        {
                            gesture.scrolling = true;
                        }

                        if gesture.scrolling {
                            // Touch scrolling should move content with the finger:
                            // dragging up scrolls the page up, dragging down scrolls it down.
                            let delta_x = gesture.last.x - position.x;
                            let delta_y = gesture.last.y - position.y;
                            let mut axis =
                                AxisFrame::new(event.time_msec).source(AxisSource::Finger);
                            if delta_x.abs() > f64::EPSILON {
                                axis = axis.value(Axis::Horizontal, delta_x);
                            }
                            if delta_y.abs() > f64::EPSILON {
                                axis = axis.value(Axis::Vertical, delta_y);
                            }
                            pointer.axis(self, axis);
                        }

                        gesture.last = position;
                        self.app_touch_gesture = Some(gesture);
                        pointer.frame(self);
                        self.flush_wayland_clients();
                    }
                    touch::TouchPhase::Up => unreachable!(),
                }
            }
            touch::TouchPhase::Up => {
                if self.shell_touch_active {
                    if let Some(position) =
                        self.touch_position(event.normalized_x, event.normalized_y)
                    {
                        if let Some((x, y)) = self.shell_local_point(position) {
                            tracing::info!(
                                "[shadow-guest-compositor] touch-shell phase=Up x={:.1} y={:.1}",
                                x,
                                y
                            );
                            self.handle_shell_event(ShellEvent::TouchTap { x, y });
                        } else {
                            self.handle_shell_event(ShellEvent::PointerLeft);
                        }
                    } else {
                        self.handle_shell_event(ShellEvent::PointerLeft);
                    }
                    self.shell_touch_active = false;
                    self.publish_visible_shell_frame("shell-touch-frame");
                    return;
                } else {
                    self.handle_shell_event(ShellEvent::PointerLeft);
                }
                tracing::info!("[shadow-guest-compositor] touch-input phase=Up");
                if let Some(gesture) = self.app_touch_gesture.take() {
                    if let Some(position) =
                        self.touch_position(event.normalized_x, event.normalized_y)
                    {
                        let under = self.surface_under(position);
                        pointer.motion(
                            self,
                            under.clone(),
                            &MotionEvent {
                                location: position,
                                serial,
                                time: event.time_msec,
                            },
                        );
                        if gesture.scrolling {
                            pointer.axis(
                                self,
                                AxisFrame::new(event.time_msec)
                                    .source(AxisSource::Finger)
                                    .stop(Axis::Horizontal)
                                    .stop(Axis::Vertical),
                            );
                        } else if under.is_some() {
                            pointer.button(
                                self,
                                &ButtonEvent {
                                    button: BTN_LEFT,
                                    state: ButtonState::Pressed,
                                    serial,
                                    time: event.time_msec,
                                },
                            );
                            pointer.button(
                                self,
                                &ButtonEvent {
                                    button: BTN_LEFT,
                                    state: ButtonState::Released,
                                    serial,
                                    time: event.time_msec,
                                },
                            );
                        }
                    } else if gesture.scrolling {
                        pointer.axis(
                            self,
                            AxisFrame::new(event.time_msec)
                                .source(AxisSource::Finger)
                                .stop(Axis::Horizontal)
                                .stop(Axis::Vertical),
                        );
                    }
                }
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
        if self.shell_enabled {
            Some(
                (
                    x * f64::from(WIDTH) / f64::from(frame_width),
                    y * f64::from(HEIGHT) / f64::from(frame_height),
                )
                    .into(),
            )
        } else {
            Some((x, y).into())
        }
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
        if !self.log_touch_geometry {
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

        self.focus_window(Some(window));
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
        self.toplevel_size
    }

    fn configure_toplevel(&self, surface: &ToplevelSurface) {
        let size = self.app_window_size();
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

    fn refresh_toplevel_app_id(&mut self, surface: &WlSurface) {
        let app_id = with_states(surface, |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .and_then(|data| data.lock().ok().and_then(|attrs| attrs.app_id.clone()))
        });
        let Some(app_id) = app_id.as_deref().and_then(app::app_id_from_wayland_app_id) else {
            return;
        };

        self.remember_surface_app(surface, app_id);
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

        match kms::write_frame_ppm(frame, &self.frame_artifact_path) {
            Ok(()) => {
                tracing::info!(
                    "[shadow-guest-compositor] wrote-frame-artifact path={} checksum={checksum:016x} size={}x{}",
                    self.frame_artifact_path.display(),
                    frame.width,
                    frame.height
                );
            }
            Err(error) => {
                tracing::warn!("[shadow-guest-compositor] capture-write failed: {error}");
            }
        }

        if self.drm_enabled {
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
                if self.shell_enabled {
                    let app_id = self.surface_apps.get(surface).copied();
                    if let Some(app_id) = app_id {
                        self.app_frames.insert(app_id, frame);
                    }
                    self.publish_visible_shell_frame("captured-frame");
                } else {
                    self.publish_frame(&frame, "captured-frame");
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
        let wl_surface = surface.wl_surface().clone();
        let window = Window::new_wayland_window(surface);
        self.handle_window_mapped(window);
        self.refresh_toplevel_app_id(&wl_surface);
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

    fn app_id_changed(&mut self, surface: ToplevelSurface) {
        self.refresh_toplevel_app_id(surface.wl_surface());
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        let wl_surface = surface.wl_surface().clone();
        if let Some(window) = self.window_for_surface(&wl_surface) {
            self.space.unmap_elem(&window);
        }
        if let Some(app_id) = self.forget_surface(&wl_surface) {
            self.shelved_windows.remove(&app_id);
        }
        self.focus_top_window();
        if self.shell_enabled {
            self.publish_visible_shell_frame("shell-toplevel-destroyed-frame");
        }
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
        for child in self.launched_apps.values_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    init_logging();
    let config = GuestStartupConfig::from_env()?;
    let mut event_loop: EventLoop<ShadowGuestCompositor> = EventLoop::try_new()?;
    let display: Display<ShadowGuestCompositor> = Display::new()?;
    let mut state = ShadowGuestCompositor::new(&config, &mut event_loop, display);

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
        match config.startup_action {
            StartupAction::Shell { start_app_id } => {
                tracing::info!("[shadow-guest-compositor] shell-mode enabled");
                state.publish_visible_shell_frame("shell-home-frame");
                if let Some(app_id) = start_app_id {
                    tracing::info!(
                        "[shadow-guest-compositor] shell-start-app-id={}",
                        app_id.as_str()
                    );
                    state.launch_or_focus_app(app_id)?;
                }
            }
            StartupAction::App { app_id } => {
                tracing::info!(
                    "[shadow-guest-compositor] start-app-id={} control_socket={}",
                    app_id.as_str(),
                    state.control_socket_path.display()
                );
                state.launch_or_focus_app(app_id)?;
            }
            StartupAction::Client => state.spawn_client()?,
        }
    }
    event_loop.run(None, &mut state, |_| {})?;
    Ok(())
}
