mod config;
mod control;
mod gpu_scanout;
mod hosted;
mod kms;
mod launch;
mod media_keys;
mod session;
mod shell;
mod shell_gpu;
mod touch;

use std::{
    collections::{HashMap, VecDeque},
    ffi::OsString,
    fs,
    os::{
        fd::AsRawFd,
        unix::{fs::MetadataExt, net::UnixStream},
    },
    path::PathBuf,
    process::Child,
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use chrono::Local;
use config::{
    DmabufFormatProfile, GuestClientConfig, GuestStartupConfig, StartupAction, TransportRequest,
};
use shadow_ui_core::{
    app::{self, AppId},
    scene::{
        APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX, APP_VIEWPORT_X, APP_VIEWPORT_Y, HEIGHT,
        WIDTH,
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
        dmabuf::{
            get_dmabuf, DmabufFeedbackBuilder, DmabufGlobal, DmabufHandler, DmabufState,
            ImportNotifier,
        },
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

#[derive(Clone, Copy, Debug)]
struct PendingTouchTrace {
    sequence: u64,
    phase: touch::TouchPhase,
    route: &'static str,
    input_captured_at: Instant,
    input_wall_msec: u128,
    dispatch_started_at: Instant,
    dispatch_wall_msec: u128,
    commit_at: Option<Instant>,
}

#[derive(Clone, Copy, Debug)]
struct ScrollBenchmarkSample {
    sequence: u64,
    phase: touch::TouchPhase,
    route: &'static str,
    generation: u64,
    input_captured_at: Instant,
    input_wall_msec: u128,
    dispatch_started_at: Instant,
}

#[derive(Clone, Copy, Debug)]
struct PendingScrollFrameTrace {
    sample: ScrollBenchmarkSample,
    render_started_at: Instant,
    coalesced_moves: u64,
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

fn wall_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
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
    _dmabuf_global: Option<DmabufGlobal>,
    _presentation_state: PresentationState,
    seat_state: SeatState<Self>,
    seat: Seat<Self>,
    launched_clients: Vec<Child>,
    launched_apps: HashMap<AppId, Child>,
    hosted_apps: HashMap<AppId, hosted::HostedAppState>,
    shell_frame_retry_sender: Option<channel::Sender<()>>,
    shell_frame_retry_pending: bool,
    hosted_touch_move_frame_sender: Option<channel::Sender<()>>,
    hosted_touch_move_frame_pending: bool,
    app_frames: HashMap<AppId, kms::CapturedFrame>,
    surface_apps: HashMap<WlSurface, AppId>,
    shelved_windows: HashMap<AppId, Window>,
    background_app_order: VecDeque<AppId>,
    focused_app: Option<AppId>,
    shell_enabled: bool,
    gpu_shell: bool,
    client_config: GuestClientConfig,
    shell: ShellModel,
    shell_surface: GuestShellSurface,
    shell_touch_active: bool,
    app_touch_gesture: Option<AppTouchGesture>,
    pub(crate) control_socket_path: PathBuf,
    exit_on_first_frame: bool,
    exit_on_client_disconnect: bool,
    exit_on_first_dma_buffer: bool,
    boot_splash_drm: bool,
    kms_display: Option<kms::KmsDisplay>,
    strict_gpu_resident: bool,
    last_frame_size: Option<(u32, u32)>,
    last_published_frame: Option<kms::CapturedFrame>,
    last_buffer_signature: Option<String>,
    toplevel_size: smithay::utils::Size<i32, Logical>,
    frame_artifact_path: PathBuf,
    frame_artifacts_enabled: bool,
    frame_artifact_every_frame: bool,
    frame_artifact_written: bool,
    frame_snapshot_cache_enabled: bool,
    frame_checksum_enabled: bool,
    drm_enabled: bool,
    background_app_resident_limit: usize,
    touch_signal_counter: u64,
    touch_signal_path: Option<PathBuf>,
    touch_latency_trace: bool,
    pending_touch_trace: Option<PendingTouchTrace>,
    latest_scroll_benchmark_sample: Option<ScrollBenchmarkSample>,
    pending_scroll_frame_trace: Option<PendingScrollFrameTrace>,
    scroll_benchmark_generation: u64,
    last_presented_scroll_generation: Option<u64>,
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
        let dmabuf_formats = Self::supported_dmabuf_formats(config.dmabuf_format_profile);
        let mut dmabuf_state = DmabufState::new();
        let dmabuf_global = if config.dmabuf_global_enabled {
            if config.dmabuf_feedback_enabled {
                match Self::build_default_dmabuf_feedback(&dmabuf_formats) {
                    Some(default_feedback) => {
                        Some(dmabuf_state.create_global_with_default_feedback::<Self>(
                            &display_handle,
                            &default_feedback,
                        ))
                    }
                    None => {
                        tracing::warn!(
                            "[shadow-guest-compositor] dmabuf-feedback-build-failed; falling back to legacy global"
                        );
                        Some(
                            dmabuf_state
                                .create_global::<Self>(&display_handle, dmabuf_formats.clone()),
                        )
                    }
                }
            } else {
                Some(dmabuf_state.create_global::<Self>(&display_handle, dmabuf_formats.clone()))
            }
        } else {
            None
        };
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
            hosted_apps: HashMap::new(),
            shell_frame_retry_sender: None,
            shell_frame_retry_pending: false,
            hosted_touch_move_frame_sender: None,
            hosted_touch_move_frame_pending: false,
            app_frames: HashMap::new(),
            surface_apps: HashMap::new(),
            shelved_windows: HashMap::new(),
            background_app_order: VecDeque::new(),
            focused_app: None,
            shell_enabled,
            gpu_shell: config.gpu_shell,
            client_config: config.client.clone(),
            shell: ShellModel::new(),
            shell_surface: GuestShellSurface::new(
                WIDTH as u32,
                HEIGHT as u32,
                config.gpu_shell,
                config.strict_gpu_resident,
            ),
            shell_touch_active: false,
            app_touch_gesture: None,
            control_socket_path,
            exit_on_first_frame: config.exit_on_first_frame,
            exit_on_client_disconnect,
            exit_on_first_dma_buffer: config.exit_on_first_dma_buffer,
            boot_splash_drm: config.boot_splash_drm,
            kms_display: None,
            strict_gpu_resident: config.strict_gpu_resident,
            last_frame_size: None,
            last_published_frame: None,
            last_buffer_signature: None,
            toplevel_size: (config.toplevel_width, config.toplevel_height).into(),
            frame_artifact_path: config.frame_artifact_path.clone(),
            frame_artifacts_enabled: config.frame_artifacts_enabled,
            frame_artifact_every_frame: config.frame_artifact_every_frame,
            frame_artifact_written: false,
            frame_snapshot_cache_enabled: config.frame_snapshot_cache_enabled,
            frame_checksum_enabled: config.frame_checksum_enabled,
            drm_enabled: config.drm_enabled,
            background_app_resident_limit: config.background_app_resident_limit,
            touch_signal_counter: 0,
            touch_signal_path: config.touch_signal_path.clone(),
            touch_latency_trace: config.touch_latency_trace,
            pending_touch_trace: None,
            latest_scroll_benchmark_sample: None,
            pending_scroll_frame_trace: None,
            scroll_benchmark_generation: 0,
            last_presented_scroll_generation: None,
        };
        if config.dmabuf_global_enabled {
            let feedback_mode = if config.dmabuf_feedback_enabled {
                "default-feedback"
            } else {
                "legacy-v3"
            };
            tracing::info!(
                "[shadow-guest-compositor] dmabuf-global-ready formats={} mode={feedback_mode} profile={:?}",
                dmabuf_formats.len(),
                config.dmabuf_format_profile
            );
        } else {
            tracing::info!("[shadow-guest-compositor] dmabuf-global-disabled");
        }
        tracing::info!("[shadow-guest-compositor] presentation-global-ready");
        tracing::info!(
            "[shadow-guest-compositor] shell-config shell_enabled={} gpu_shell={} strict_gpu_resident={} toplevel={}x{}",
            state.shell_enabled,
            state.gpu_shell,
            state.strict_gpu_resident,
            state.toplevel_size.w,
            state.toplevel_size.h
        );
        if let Some(path) = state.touch_signal_path.as_ref() {
            tracing::info!(
                "[shadow-guest-compositor] touch-signal-ready path={}",
                path.display()
            );
        }
        if state.touch_latency_trace {
            tracing::info!("[shadow-guest-compositor] touch-latency-trace enabled");
        }
        if state.frame_artifacts_enabled {
            tracing::info!(
                "[shadow-guest-compositor] frame-artifacts-enabled path={}",
                state.frame_artifact_path.display()
            );
        }
        state.insert_touch_source(event_loop);
        state.insert_media_key_source(event_loop);
        state.insert_hosted_app_poll_source(event_loop);
        state.insert_shell_frame_retry_source(event_loop);
        state.insert_hosted_touch_move_frame_source(event_loop);
        state
    }

    fn supported_dmabuf_formats(profile: DmabufFormatProfile) -> Vec<Format> {
        match profile {
            DmabufFormatProfile::Default => vec![
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
            ],
            DmabufFormatProfile::LinearOnly => vec![
                Format {
                    code: Fourcc::Argb8888,
                    modifier: Modifier::Linear,
                },
                Format {
                    code: Fourcc::Xrgb8888,
                    modifier: Modifier::Linear,
                },
            ],
            DmabufFormatProfile::ImplicitOnly => vec![
                Format {
                    code: Fourcc::Argb8888,
                    modifier: Modifier::Invalid,
                },
                Format {
                    code: Fourcc::Xrgb8888,
                    modifier: Modifier::Invalid,
                },
            ],
        }
    }

    fn build_default_dmabuf_feedback(
        formats: &[Format],
    ) -> Option<smithay::wayland::dmabuf::DmabufFeedback> {
        let main_device: libc::dev_t = fs::metadata("/dev/dri/card0")
            .ok()?
            .rdev()
            .try_into()
            .ok()?;
        DmabufFeedbackBuilder::new(main_device, formats.iter().copied())
            .build()
            .ok()
    }

    fn log_touch_handle_latency(&self, event: &touch::TouchInputEvent) {
        if !self.touch_latency_trace {
            return;
        }

        tracing::info!(
            "[shadow-guest-compositor] touch-latency-handle seq={} phase={:?} queue_us={} wall_ms={} normalized={:.3},{:.3}",
            event.sequence,
            event.phase,
            event.captured_at.elapsed().as_micros(),
            wall_millis(),
            event.normalized_x,
            event.normalized_y
        );
    }

    fn finish_touch_dispatch(
        &mut self,
        event: &touch::TouchInputEvent,
        route: &'static str,
        dispatch_started_at: Instant,
    ) {
        if !self.touch_latency_trace {
            return;
        }

        let dispatch_wall_msec = wall_millis();
        let pending = PendingTouchTrace {
            sequence: event.sequence,
            phase: event.phase,
            route,
            input_captured_at: event.captured_at,
            input_wall_msec: event.wall_msec,
            dispatch_started_at,
            dispatch_wall_msec,
            commit_at: None,
        };
        if let Some(previous) = self.pending_touch_trace.replace(pending) {
            tracing::info!(
                "[shadow-guest-compositor] touch-latency-replaced prev_seq={} prev_route={} seq={} route={}",
                previous.sequence,
                previous.route,
                event.sequence,
                route
            );
        }
        tracing::info!(
            "[shadow-guest-compositor] touch-latency-dispatch seq={} route={} phase={:?} handle_to_flush_us={} input_wall_ms={} dispatch_wall_ms={}",
            event.sequence,
            route,
            event.phase,
            dispatch_started_at.elapsed().as_micros(),
            event.wall_msec,
            dispatch_wall_msec
        );
    }

    fn record_touch_commit(&mut self) {
        let Some(trace) = self.pending_touch_trace.as_mut() else {
            return;
        };
        if trace.commit_at.is_some() {
            return;
        }

        let commit_at = Instant::now();
        tracing::info!(
            "[shadow-guest-compositor] touch-latency-commit seq={} route={} phase={:?} input_to_commit_us={} dispatch_to_commit_us={}",
            trace.sequence,
            trace.route,
            trace.phase,
            commit_at.duration_since(trace.input_captured_at).as_micros(),
            commit_at.duration_since(trace.dispatch_started_at).as_micros()
        );
        trace.commit_at = Some(commit_at);
    }

    fn record_touch_present(&mut self, frame_marker: &str) {
        let Some(trace) = self.pending_touch_trace.take() else {
            return;
        };

        let present_at = Instant::now();
        let input_to_present_us = present_at
            .duration_since(trace.input_captured_at)
            .as_micros();
        let dispatch_to_present_us = present_at
            .duration_since(trace.dispatch_started_at)
            .as_micros();
        if let Some(commit_at) = trace.commit_at {
            tracing::info!(
                "[shadow-guest-compositor] touch-latency-present seq={} route={} phase={:?} frame_marker={} input_wall_ms={} dispatch_wall_ms={} input_to_present_us={} dispatch_to_present_us={} commit_to_present_us={}",
                trace.sequence,
                trace.route,
                trace.phase,
                frame_marker,
                trace.input_wall_msec,
                trace.dispatch_wall_msec,
                input_to_present_us,
                dispatch_to_present_us,
                present_at.duration_since(commit_at).as_micros()
            );
        } else {
            tracing::info!(
                "[shadow-guest-compositor] touch-latency-present seq={} route={} phase={:?} frame_marker={} input_wall_ms={} dispatch_wall_ms={} input_to_present_us={} dispatch_to_present_us={}",
                trace.sequence,
                trace.route,
                trace.phase,
                frame_marker,
                trace.input_wall_msec,
                trace.dispatch_wall_msec,
                input_to_present_us,
                dispatch_to_present_us
            );
        }
    }

    fn note_scroll_benchmark_sample(
        &mut self,
        event: &touch::TouchInputEvent,
        route: &'static str,
        dispatch_started_at: Instant,
    ) {
        if !self.touch_latency_trace || route != "app-scroll" {
            return;
        }

        self.scroll_benchmark_generation = self.scroll_benchmark_generation.saturating_add(1);
        self.latest_scroll_benchmark_sample = Some(ScrollBenchmarkSample {
            sequence: event.sequence,
            phase: event.phase,
            route,
            generation: self.scroll_benchmark_generation,
            input_captured_at: event.captured_at,
            input_wall_msec: event.wall_msec,
            dispatch_started_at,
        });
    }

    fn begin_scroll_frame_trace(&mut self, frame_marker: &str) {
        if !self.touch_latency_trace {
            return;
        }
        let Some(sample) = self.latest_scroll_benchmark_sample else {
            return;
        };

        let render_started_at = Instant::now();
        let coalesced_moves = self
            .last_presented_scroll_generation
            .map(|generation| {
                sample
                    .generation
                    .saturating_sub(generation)
                    .saturating_sub(1)
            })
            .unwrap_or(0);
        tracing::info!(
            "[shadow-guest-compositor] scroll-frame-build seq={} route={} phase={:?} frame_marker={} input_age_us={} dispatch_age_us={} coalesced_moves={}",
            sample.sequence,
            sample.route,
            sample.phase,
            frame_marker,
            render_started_at.duration_since(sample.input_captured_at).as_micros(),
            render_started_at.duration_since(sample.dispatch_started_at).as_micros(),
            coalesced_moves
        );
        self.pending_scroll_frame_trace = Some(PendingScrollFrameTrace {
            sample,
            render_started_at,
            coalesced_moves,
        });
    }

    fn record_scroll_frame_present(&mut self, frame_marker: &str) {
        let Some(trace) = self.pending_scroll_frame_trace.take() else {
            return;
        };

        let present_at = Instant::now();
        tracing::info!(
            "[shadow-guest-compositor] scroll-frame-present seq={} route={} phase={:?} frame_marker={} input_wall_ms={} input_age_us={} render_to_present_us={} input_to_present_us={} coalesced_moves={}",
            trace.sample.sequence,
            trace.sample.route,
            trace.sample.phase,
            frame_marker,
            trace.sample.input_wall_msec,
            present_at.duration_since(trace.sample.input_captured_at).as_micros(),
            present_at.duration_since(trace.render_started_at).as_micros(),
            present_at.duration_since(trace.sample.input_captured_at).as_micros(),
            trace.coalesced_moves
        );
        self.last_presented_scroll_generation = Some(trace.sample.generation);
    }

    fn ensure_kms_display(&mut self) -> Option<&mut kms::KmsDisplay> {
        self.ensure_kms_display_with_timeout(Duration::from_secs(18))
    }

    fn ensure_kms_display_with_timeout(
        &mut self,
        timeout: Duration,
    ) -> Option<&mut kms::KmsDisplay> {
        if self.kms_display.is_none() {
            match kms::KmsDisplay::open_when_ready(timeout, self.strict_gpu_resident) {
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

    fn insert_hosted_app_poll_source(&mut self, event_loop: &mut EventLoop<Self>) {
        let (sender, receiver) = channel::channel();
        std::thread::spawn(move || loop {
            std::thread::sleep(hosted::HOSTED_IDLE_POLL_INTERVAL);
            if sender.send(()).is_err() {
                break;
            }
        });
        event_loop
            .handle()
            .insert_source(receiver, |event, _, state| match event {
                channel::Event::Msg(()) => state.poll_hosted_apps(),
                channel::Event::Closed => {
                    tracing::warn!("[shadow-guest-compositor] hosted-app-poll-source closed")
                }
            })
            .expect("insert hosted app poll source");
    }

    fn insert_shell_frame_retry_source(&mut self, event_loop: &mut EventLoop<Self>) {
        let (sender, receiver) = channel::channel();
        self.shell_frame_retry_sender = Some(sender);
        event_loop
            .handle()
            .insert_source(receiver, |event, _, state| match event {
                channel::Event::Msg(()) => {
                    state.shell_frame_retry_pending = false;
                    if state.shell_overlay_visible() {
                        state.publish_visible_shell_frame("shell-home-frame-retry");
                    }
                }
                channel::Event::Closed => {
                    tracing::warn!("[shadow-guest-compositor] shell-frame-retry-source closed")
                }
            })
            .expect("insert shell frame retry source");
    }

    fn insert_hosted_touch_move_frame_source(&mut self, event_loop: &mut EventLoop<Self>) {
        let (sender, receiver) = channel::channel();
        self.hosted_touch_move_frame_sender = Some(sender);
        event_loop
            .handle()
            .insert_source(receiver, |event, _, state| match event {
                channel::Event::Msg(()) => {
                    if !state.hosted_touch_move_frame_pending {
                        return;
                    }
                    state.hosted_touch_move_frame_pending = false;
                    if state.shell_overlay_visible() {
                        state.publish_visible_shell_frame("hosted-touch-move-frame");
                    }
                }
                channel::Event::Closed => {
                    tracing::warn!(
                        "[shadow-guest-compositor] hosted-touch-move-frame-source closed"
                    )
                }
            })
            .expect("insert hosted touch move frame source");
    }

    fn schedule_shell_frame_retry(&mut self) {
        if self.shell_frame_retry_pending || !self.shell_overlay_visible() {
            return;
        }
        let Some(sender) = self.shell_frame_retry_sender.clone() else {
            return;
        };
        self.shell_frame_retry_pending = true;
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(250));
            let _ = sender.send(());
        });
    }

    fn schedule_hosted_touch_move_frame(&mut self) {
        if !self.shell_overlay_visible() {
            return;
        }
        let Some(sender) = self.hosted_touch_move_frame_sender.clone() else {
            self.publish_visible_shell_frame("hosted-touch-move-frame");
            return;
        };
        if self.hosted_touch_move_frame_pending {
            return;
        }

        self.hosted_touch_move_frame_pending = true;
        if sender.send(()).is_err() {
            self.hosted_touch_move_frame_pending = false;
            tracing::warn!("[shadow-guest-compositor] hosted-touch-move-frame-send failed");
            self.publish_visible_shell_frame("hosted-touch-move-frame");
        }
    }

    fn poll_hosted_apps(&mut self) {
        if self.hosted_apps.is_empty() {
            return;
        }

        let focused_app = self.focused_app;
        let app_ids: Vec<_> = self.hosted_apps.keys().copied().collect();
        let mut focused_changed = false;

        for app_id in app_ids {
            let result = self
                .hosted_apps
                .get_mut(&app_id)
                .expect("hosted app present")
                .poll();
            if self.apply_hosted_app_update(app_id, result) {
                focused_changed |= focused_app == Some(app_id);
            }
        }

        if focused_changed {
            self.publish_visible_shell_frame("hosted-app-poll-frame");
        }
    }

    fn drain_client_exit_statuses(&mut self, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        loop {
            self.reap_exited_clients();
            if self.launched_clients.is_empty() && self.launched_apps.is_empty() {
                return;
            }
            if Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }

        if !self.launched_clients.is_empty() {
            let pids = self
                .launched_clients
                .iter()
                .map(|child| child.id().to_string())
                .collect::<Vec<_>>()
                .join(",");
            tracing::info!("[shadow-guest-compositor] launched-clients-still-running pids={pids}");
        }
        if !self.launched_apps.is_empty() {
            let apps = self
                .launched_apps
                .iter()
                .map(|(app_id, child)| format!("{}:{}", app_id.as_str(), child.id()))
                .collect::<Vec<_>>()
                .join(",");
            tracing::info!("[shadow-guest-compositor] launched-apps-still-running entries={apps}");
        }
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
    }

    fn app_window_location(&self) -> (i32, i32) {
        if self.shell_enabled {
            (APP_VIEWPORT_X.round() as i32, APP_VIEWPORT_Y.round() as i32)
        } else {
            (0, 0)
        }
    }

    fn app_window_size(&self) -> smithay::utils::Size<i32, Logical> {
        self.configured_toplevel_size()
    }

    fn hosted_app_local_point(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        self.hosted_app_local_point_with_clamp(position, false)
    }

    fn hosted_app_local_point_clamped(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        self.hosted_app_local_point_with_clamp(position, true)
    }

    fn hosted_app_local_point_with_clamp(
        &self,
        position: Point<f64, Logical>,
        clamp: bool,
    ) -> Option<(f32, f32)> {
        let (origin_x, origin_y) = if self.shell_enabled {
            (APP_VIEWPORT_X.round() as i32, APP_VIEWPORT_Y.round() as i32)
        } else {
            (0, 0)
        };
        let size = self.app_window_size();
        let width = f64::from(size.w.max(0));
        let height = f64::from(size.h.max(0));
        if width <= 0.0 || height <= 0.0 {
            return None;
        }

        let mut local_x = position.x - f64::from(origin_x);
        let mut local_y = position.y - f64::from(origin_y);
        if clamp {
            local_x = local_x.clamp(0.0, (width - 1.0).max(0.0));
            local_y = local_y.clamp(0.0, (height - 1.0).max(0.0));
        } else if !(0.0..=width).contains(&local_x) || !(0.0..=height).contains(&local_y) {
            return None;
        }

        Some((local_x as f32, local_y as f32))
    }

    fn focused_hosted_app(&self) -> Option<AppId> {
        self.focused_app
            .filter(|app_id| self.hosted_apps.contains_key(app_id))
    }

    fn shell_overlay_visible(&self) -> bool {
        self.shell_enabled
    }

    fn apply_hosted_app_update(&mut self, app_id: AppId, result: std::io::Result<bool>) -> bool {
        match result {
            Ok(changed) => changed,
            Err(error) => {
                tracing::warn!(
                    "[shadow-guest-compositor] hosted-app-refresh-error app={} error={error}",
                    app_id.as_str()
                );
                self.terminate_app(app_id);
                false
            }
        }
    }

    fn shell_render_size(&self) -> (u32, u32) {
        if self.drm_enabled && self.gpu_shell {
            return (WIDTH.round() as u32, HEIGHT.round() as u32);
        }
        if let Some(display) = self.kms_display.as_ref() {
            return display.dimensions();
        }

        let width = u32::try_from(self.toplevel_size.w.max(1)).unwrap_or(WIDTH.round() as u32);
        let height = u32::try_from(self.toplevel_size.h.max(1)).unwrap_or(HEIGHT.round() as u32);
        (width, height)
    }

    fn shell_local_point(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        ((0.0..=WIDTH as f64).contains(&position.x) && (0.0..=HEIGHT as f64).contains(&position.y))
            .then_some((position.x as f32, position.y as f32))
    }

    fn shell_captures_point(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        if !self.shell_overlay_visible() {
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
        if !self.shell_overlay_visible() {
            return;
        }
        if frame_marker != "hosted-touch-move-frame" {
            self.hosted_touch_move_frame_pending = false;
        }
        if frame_marker == "hosted-touch-move-frame" {
            self.begin_scroll_frame_trace(frame_marker);
        }

        let status = ShellStatus::demo(Local::now());
        let scene = self.shell.scene(&status);
        let (render_width, render_height) = self.shell_render_size();
        let focused_hosted_app = self.gpu_shell.then(|| self.focused_hosted_app()).flatten();
        self.shell_surface.resize(render_width, render_height);
        if self.drm_enabled && self.gpu_shell {
            let scanout_candidates = self
                .ensure_kms_display()
                .map(|display| display.scanout_candidates().to_vec())
                .unwrap_or_default();
            if let Err(error) = self
                .shell_surface
                .configure_gpu_scanout(&scanout_candidates)
            {
                if self.strict_gpu_resident {
                    panic!(
                        "strict gpu resident mode rejected shell GPU scanout configuration: {error:#}"
                    );
                }
                tracing::warn!(
                    "[shadow-guest-compositor] gpu-scanout-unavailable size={}x{} error={error:#}",
                    render_width,
                    render_height
                );
            }
        }
        let app_frame = focused_hosted_app
            .is_none()
            .then(|| {
                self.focused_app.and_then(|app_id| {
                    self.app_frames.get(&app_id).map(|frame| AppFrame {
                        width: frame.width,
                        height: frame.height,
                        stride: frame.stride,
                        format: frame.format,
                        pixels: &frame.pixels,
                    })
                })
            })
            .flatten();
        let shell_stats = if let Some(app_id) = focused_hosted_app {
            let (shell_surface, hosted_apps) = (&mut self.shell_surface, &mut self.hosted_apps);
            let hosted_app = hosted_apps
                .get_mut(&app_id)
                .expect("focused hosted app present")
                .app_mut();
            shell_surface.render_scene_with_hosted_app(&scene, hosted_app)
        } else {
            self.shell_surface
                .render_scene_with_app_frame(&scene, app_frame)
        };
        let shell_stats = match shell_stats {
            Ok(stats) => stats,
            Err(error) => {
                if self.strict_gpu_resident {
                    panic!(
                        "strict gpu resident mode rejected visible shell frame render: {error:#}"
                    );
                }
                tracing::warn!(
                    "[shadow-guest-compositor] shell-frame-render-failed frame_marker={frame_marker} error={error:#}"
                );
                return;
            }
        };
        let shell_total =
            shell_stats.scene_render + shell_stats.base_copy + shell_stats.app_composite;
        if shell_total.as_millis() >= 8 {
            tracing::info!(
                "[shadow-guest-compositor] shell-frame-stats cache_hit={} scene_render_ms={} base_copy_ms={} app_composite_ms={} total_ms={}",
                shell_stats.scene_cache_hit,
                shell_stats.scene_render.as_millis(),
                shell_stats.base_copy.as_millis(),
                shell_stats.app_composite.as_millis(),
                shell_total.as_millis()
            );
        }
        if let Some(dmabuf) = self.shell_surface.take_presentable_dmabuf() {
            let debug_cpu_frame_requested = self.frame_artifacts_enabled
                || self.frame_snapshot_cache_enabled
                || self.frame_checksum_enabled;
            let mut presented = false;
            if debug_cpu_frame_requested {
                match kms::capture_dmabuf_frame(&dmabuf) {
                    Ok(frame) => {
                        self.record_frame_view(frame.view(), frame_marker);
                        if self.frame_snapshot_cache_enabled {
                            self.last_published_frame = Some(frame);
                        }
                    }
                    Err(error) => {
                        tracing::warn!(
                            "[shadow-guest-compositor] shell-dmabuf-capture failed: {error}"
                        );
                    }
                }
            } else {
                let size = dmabuf.size();
                self.last_frame_size = Some((size.w.max(0) as u32, size.h.max(0) as u32));
            }

            if self.drm_enabled {
                if let Some(display) = self.ensure_kms_display_with_timeout(Duration::from_secs(2))
                {
                    match display.present_dmabuf(&dmabuf) {
                        Ok(()) => {
                            presented = true;
                            tracing::info!(
                                "[shadow-guest-compositor] presented-shell-dmabuf size={}x{} fourcc={:?} modifier={:?}",
                                dmabuf.size().w,
                                dmabuf.size().h,
                                dmabuf.format().code,
                                dmabuf.format().modifier
                            );
                            tracing::info!("[shadow-guest-compositor] presented-frame");
                        }
                        Err(error) => {
                            tracing::warn!(
                                "[shadow-guest-compositor] present-shell-dmabuf failed: {error}"
                            );
                        }
                    }
                }
            }

            self.record_touch_present(frame_marker);
            self.record_scroll_frame_present(frame_marker);
            if self.exit_on_first_frame {
                self.loop_signal.stop();
            }
            if self.drm_enabled && !presented {
                self.schedule_shell_frame_retry();
            }
            return;
        }
        let pixels = self.shell_surface.take_pixels();
        let frame = kms::CapturedFrameView {
            width: render_width,
            height: render_height,
            stride: render_width * 4,
            pixels: &pixels,
        };
        let presented =
            self.publish_frame_view_with_timeout(frame, frame_marker, Duration::from_secs(2));
        self.shell_surface.restore_pixels(pixels);
        if self.drm_enabled && !presented {
            self.schedule_shell_frame_retry();
        }
    }

    fn prewarm_visible_shell_frame(&mut self) {
        if !self.shell_overlay_visible() {
            return;
        }

        let status = ShellStatus::demo(Local::now());
        let scene = self.shell.scene(&status);
        let (render_width, render_height) = self.shell_render_size();
        self.shell_surface.resize(render_width, render_height);
        if self.drm_enabled && self.gpu_shell {
            let scanout_candidates = self
                .ensure_kms_display()
                .map(|display| display.scanout_candidates().to_vec())
                .unwrap_or_default();
            if let Err(error) = self
                .shell_surface
                .configure_gpu_scanout(&scanout_candidates)
            {
                if self.strict_gpu_resident {
                    panic!(
                        "strict gpu resident mode rejected shell prewarm scanout configuration: {error:#}"
                    );
                }
                tracing::warn!(
                    "[shadow-guest-compositor] shell-prewarm-scanout-unavailable size={}x{} error={error:#}",
                    render_width,
                    render_height
                );
            }
        }
        let shell_stats = self.shell_surface.render_scene_with_app_frame(&scene, None);
        let shell_stats = match shell_stats {
            Ok(stats) => stats,
            Err(error) => {
                if self.strict_gpu_resident {
                    panic!("strict gpu resident mode rejected shell prewarm render: {error:#}");
                }
                tracing::warn!(
                    "[shadow-guest-compositor] shell-prewarm-render-failed error={error:#}"
                );
                return;
            }
        };
        let _ = self.shell_surface.take_presentable_dmabuf();
        let shell_total =
            shell_stats.scene_render + shell_stats.base_copy + shell_stats.app_composite;
        if shell_total.as_millis() >= 8 {
            tracing::info!(
                "[shadow-guest-compositor] shell-prewarm-stats cache_hit={} scene_render_ms={} base_copy_ms={} app_composite_ms={} total_ms={}",
                shell_stats.scene_cache_hit,
                shell_stats.scene_render.as_millis(),
                shell_stats.base_copy.as_millis(),
                shell_stats.app_composite.as_millis(),
                shell_total.as_millis()
            );
        }
    }

    fn write_frame_snapshot(&self, path: Option<String>) -> std::io::Result<String> {
        let frame = self.last_published_frame.as_ref().ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "no published frame available for snapshot",
            )
        })?;
        let path = path
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| self.frame_artifact_path.clone());
        let checksum = kms::frame_checksum(frame);
        kms::write_frame_ppm(frame, &path)
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        tracing::info!(
            "[shadow-guest-compositor] wrote-frame-snapshot path={} checksum={checksum:016x} size={}x{}",
            path.display(),
            frame.width,
            frame.height
        );
        Ok(format!(
            "ok\npath={}\nchecksum={checksum:016x}\nsize={}x{}\n",
            path.display(),
            frame.width,
            frame.height
        ))
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

        if let Some(app_id) = self.focused_hosted_app() {
            let Some((local_x, local_y)) = self.hosted_app_local_point(position) else {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    format!("tap target {x},{y} is outside the current content"),
                ));
            };
            tracing::info!(
                "[shadow-guest-compositor] control-tap-app x={} y={} hosted=1 app={} local_x={:.1} local_y={:.1}",
                x,
                y,
                app_id.as_str(),
                local_x,
                local_y
            );
            let down = self
                .hosted_apps
                .get_mut(&app_id)
                .expect("hosted app present")
                .handle_pointer_down(local_x, local_y);
            let _ = self.apply_hosted_app_update(app_id, down);
            let up = self
                .hosted_apps
                .get_mut(&app_id)
                .expect("hosted app present")
                .handle_pointer_up(local_x, local_y);
            let _ = self.apply_hosted_app_update(app_id, up);
            self.publish_visible_shell_frame("control-tap-hosted-frame");
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

    fn insert_media_key_source(&mut self, event_loop: &mut EventLoop<Self>) {
        let devices = match media_keys::detect_media_key_devices() {
            Ok(devices) => devices,
            Err(error) => {
                tracing::warn!("[shadow-guest-compositor] media-keys-unavailable: {error}");
                return;
            }
        };
        if devices.is_empty() {
            tracing::warn!("[shadow-guest-compositor] media-keys-unavailable: no event devices");
            return;
        }

        tracing::info!(
            "[shadow-guest-compositor] media-keys-ready devices={}",
            devices.len()
        );
        let (sender, receiver) = channel::channel();
        event_loop
            .handle()
            .insert_source(receiver, |event, _, state| match event {
                channel::Event::Msg(event) => state.handle_media_key_input(event),
                channel::Event::Closed => {
                    tracing::warn!("[shadow-guest-compositor] media-key-source closed")
                }
            })
            .expect("insert media key source");
        media_keys::spawn_media_key_readers(devices, sender);
    }

    fn handle_media_key_input(&mut self, event: media_keys::MediaKeyEvent) {
        self.dispatch_control_media_async(event.action);
    }

    fn handle_touch_input(&mut self, event: touch::TouchInputEvent) {
        self.signal_touch_event(&event);
        self.log_touch_handle_latency(&event);
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
                        let dispatch_started_at = Instant::now();
                        self.handle_shell_event(ShellEvent::PointerLeft);
                        self.shell_touch_active = false;
                        self.finish_touch_dispatch(&event, "shell-pointer", dispatch_started_at);
                        self.publish_visible_shell_frame("shell-touch-frame");
                    }
                    if let Some(gesture) = self.app_touch_gesture.take() {
                        if gesture.scrolling {
                            let dispatch_started_at = Instant::now();
                            pointer.axis(
                                self,
                                AxisFrame::new(event.time_msec)
                                    .source(AxisSource::Finger)
                                    .stop(Axis::Horizontal)
                                    .stop(Axis::Vertical),
                            );
                            pointer.frame(self);
                            self.flush_wayland_clients();
                            self.finish_touch_dispatch(
                                &event,
                                "app-scroll-stop",
                                dispatch_started_at,
                            );
                        }
                    }
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
                            let dispatch_started_at = Instant::now();
                            pointer.axis(
                                self,
                                AxisFrame::new(event.time_msec)
                                    .source(AxisSource::Finger)
                                    .stop(Axis::Horizontal)
                                    .stop(Axis::Vertical),
                            );
                            pointer.frame(self);
                            self.flush_wayland_clients();
                            self.finish_touch_dispatch(
                                &event,
                                "app-scroll-stop",
                                dispatch_started_at,
                            );
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
                    let dispatch_started_at = Instant::now();
                    self.handle_shell_event(ShellEvent::PointerMoved { x, y });
                    if matches!(event.phase, touch::TouchPhase::Down) {
                        self.shell_touch_active = true;
                    }
                    self.finish_touch_dispatch(&event, "shell-pointer", dispatch_started_at);
                    self.publish_visible_shell_frame("shell-touch-frame");
                    return;
                }
                self.shell_touch_active = false;
                self.handle_shell_event(ShellEvent::PointerLeft);
                if let Some(app_id) = self.focused_hosted_app() {
                    if self.handle_hosted_touch_input(app_id, &event, position) {
                        return;
                    }
                }
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
                        let dispatch_started_at = Instant::now();

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
                        let route = if gesture.scrolling {
                            Some("app-scroll")
                        } else {
                            None
                        };
                        if let Some(route) = route {
                            self.note_scroll_benchmark_sample(&event, route, dispatch_started_at);
                        }
                        self.app_touch_gesture = Some(gesture);
                        pointer.frame(self);
                        self.flush_wayland_clients();
                        if let Some(route) = route {
                            self.finish_touch_dispatch(&event, route, dispatch_started_at);
                        }
                    }
                    touch::TouchPhase::Up => unreachable!(),
                }
            }
            touch::TouchPhase::Up => {
                if self.shell_touch_active {
                    let dispatch_started_at = Instant::now();
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
                            self.finish_touch_dispatch(&event, "shell-tap", dispatch_started_at);
                        } else {
                            self.handle_shell_event(ShellEvent::PointerLeft);
                            self.finish_touch_dispatch(
                                &event,
                                "shell-pointer",
                                dispatch_started_at,
                            );
                        }
                    } else {
                        self.handle_shell_event(ShellEvent::PointerLeft);
                        self.finish_touch_dispatch(&event, "shell-pointer", dispatch_started_at);
                    }
                    self.shell_touch_active = false;
                    self.publish_visible_shell_frame("shell-touch-frame");
                    return;
                } else {
                    self.handle_shell_event(ShellEvent::PointerLeft);
                }
                tracing::info!("[shadow-guest-compositor] touch-input phase=Up");
                if let Some(app_id) = self.focused_hosted_app() {
                    if let Some(position) =
                        self.touch_position(event.normalized_x, event.normalized_y)
                    {
                        if self.handle_hosted_touch_input(app_id, &event, position) {
                            return;
                        }
                    }
                }
                let mut route = None;
                let dispatch_started_at = Instant::now();
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
                            route = Some("app-scroll-stop");
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
                            route = Some("app-tap");
                        }
                    } else if gesture.scrolling {
                        pointer.axis(
                            self,
                            AxisFrame::new(event.time_msec)
                                .source(AxisSource::Finger)
                                .stop(Axis::Horizontal)
                                .stop(Axis::Vertical),
                        );
                        route = Some("app-scroll-stop");
                    }
                }
                pointer.frame(self);
                self.flush_wayland_clients();
                if let Some(route) = route {
                    self.finish_touch_dispatch(&event, route, dispatch_started_at);
                }
            }
        }
    }

    fn handle_hosted_touch_input(
        &mut self,
        app_id: AppId,
        event: &touch::TouchInputEvent,
        position: Point<f64, Logical>,
    ) -> bool {
        match event.phase {
            touch::TouchPhase::Down => {
                let Some((local_x, local_y)) = self.hosted_app_local_point(position) else {
                    return false;
                };
                tracing::info!(
                    "[shadow-guest-compositor] touch-hosted phase=Down app={} x={:.1} y={:.1}",
                    app_id.as_str(),
                    local_x,
                    local_y
                );
                self.app_touch_gesture = Some(AppTouchGesture {
                    start: position,
                    last: position,
                    scrolling: false,
                });
                let frame = self
                    .hosted_apps
                    .get_mut(&app_id)
                    .expect("hosted app present")
                    .handle_pointer_down(local_x, local_y);
                if self.apply_hosted_app_update(app_id, frame) {
                    self.publish_visible_shell_frame("hosted-touch-down-frame");
                }
                true
            }
            touch::TouchPhase::Move => {
                let Some(mut gesture) = self.app_touch_gesture.take() else {
                    return false;
                };
                let Some((local_x, local_y)) = self.hosted_app_local_point_clamped(position) else {
                    self.app_touch_gesture = Some(gesture);
                    return false;
                };
                let dispatch_started_at = Instant::now();
                let frame = self
                    .hosted_apps
                    .get_mut(&app_id)
                    .expect("hosted app present")
                    .handle_pointer_move(local_x, local_y);
                let frame_changed = self.apply_hosted_app_update(app_id, frame);

                let total_dx = position.x - gesture.start.x;
                let total_dy = position.y - gesture.start.y;
                if !gesture.scrolling
                    && (total_dx.abs() >= APP_TOUCH_SCROLL_THRESHOLD
                        || total_dy.abs() >= APP_TOUCH_SCROLL_THRESHOLD)
                {
                    gesture.scrolling = true;
                }

                let route = gesture.scrolling.then_some("app-scroll");
                gesture.last = position;
                self.app_touch_gesture = Some(gesture);

                if let Some(route) = route {
                    self.note_scroll_benchmark_sample(event, route, dispatch_started_at);
                }
                if let Some(route) = route {
                    self.finish_touch_dispatch(event, route, dispatch_started_at);
                }
                if frame_changed {
                    self.schedule_hosted_touch_move_frame();
                }
                true
            }
            touch::TouchPhase::Up => {
                let Some(gesture) = self.app_touch_gesture.take() else {
                    return false;
                };
                let local = self
                    .hosted_app_local_point(position)
                    .or_else(|| self.hosted_app_local_point_clamped(gesture.last));
                let Some((local_x, local_y)) = local else {
                    return false;
                };
                let dispatch_started_at = Instant::now();
                let frame = self
                    .hosted_apps
                    .get_mut(&app_id)
                    .expect("hosted app present")
                    .handle_pointer_up(local_x, local_y);
                let frame_changed = self.apply_hosted_app_update(app_id, frame);
                let route = if gesture.scrolling {
                    Some("app-scroll-stop")
                } else {
                    Some("app-tap")
                };
                if frame_changed {
                    self.publish_visible_shell_frame("hosted-touch-up-frame");
                }
                if let Some(route) = route {
                    self.finish_touch_dispatch(event, route, dispatch_started_at);
                }
                true
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
                "[shadow-guest-compositor] touch-signal-write counter={} seq={} wall_ms={} path={} normalized={:.3},{:.3}",
                token,
                event.sequence,
                wall_millis(),
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
        self.publish_frame_view(frame.view(), frame_marker);
        if self.frame_snapshot_cache_enabled {
            self.last_published_frame = Some(frame.clone());
        }
    }

    fn publish_frame_view(&mut self, frame: kms::CapturedFrameView<'_>, frame_marker: &str) {
        self.publish_frame_view_with_timeout(frame, frame_marker, Duration::from_secs(18));
    }

    fn publish_frame_view_with_timeout(
        &mut self,
        frame: kms::CapturedFrameView<'_>,
        frame_marker: &str,
        kms_timeout: Duration,
    ) -> bool {
        self.record_frame_view(frame, frame_marker);
        if self.frame_snapshot_cache_enabled {
            self.last_published_frame = Some(kms::copy_frame_view(frame, wl_shm::Format::Xrgb8888));
        }

        let mut presented = false;
        if self.drm_enabled {
            if let Some(display) = self.ensure_kms_display_with_timeout(kms_timeout) {
                match display.present_frame_view(frame) {
                    Ok(()) => {
                        presented = true;
                        tracing::info!("[shadow-guest-compositor] presented-frame");
                    }
                    Err(error) => {
                        tracing::warn!("[shadow-guest-compositor] present-frame failed: {error}")
                    }
                }
            }
        }

        self.record_touch_present(frame_marker);
        self.record_scroll_frame_present(frame_marker);

        if self.exit_on_first_frame {
            self.loop_signal.stop();
        }

        presented
    }

    fn record_frame_view(&mut self, frame: kms::CapturedFrameView<'_>, frame_marker: &str) {
        self.last_frame_size = Some((frame.width, frame.height));
        let checksum = (self.frame_checksum_enabled || self.frame_artifacts_enabled)
            .then(|| kms::frame_view_checksum(frame));
        if let Some(checksum) = checksum {
            tracing::info!(
                "[shadow-guest-compositor] {frame_marker} checksum={checksum:016x} size={}x{}",
                frame.width,
                frame.height
            );
        }
        if let Some(display) = self.kms_display.as_ref() {
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

        if self.frame_artifacts_enabled
            && (!self.frame_artifact_written || self.frame_artifact_every_frame)
        {
            match kms::write_frame_view_ppm(frame, &self.frame_artifact_path) {
                Ok(()) => {
                    self.frame_artifact_written = true;
                    let checksum = checksum.unwrap_or_else(|| kms::frame_view_checksum(frame));
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
        }
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
        let debug_cpu_frame_requested = self.frame_artifacts_enabled
            || self.frame_snapshot_cache_enabled
            || self.frame_checksum_enabled;
        if matches!(observed_type, Some(BufferType::Dma)) {
            let dmabuf = get_dmabuf(&buffer).expect("dmabuf-managed buffer");
            let mut directly_presented = false;

            if self.drm_enabled && !self.shell_enabled {
                if let Some(display) = self.ensure_kms_display() {
                    match display.present_dmabuf(&dmabuf) {
                        Ok(()) => {
                            directly_presented = true;
                            tracing::info!(
                                "[shadow-guest-compositor] presented-dmabuf-direct size={}x{}",
                                dmabuf.size().w,
                                dmabuf.size().h
                            );
                        }
                        Err(error) => {
                            tracing::warn!(
                                "[shadow-guest-compositor] present-dmabuf failed: {error}"
                            );
                        }
                    }
                }
            }

            let direct_present_needs_cpu_frame =
                self.shell_enabled || !directly_presented || debug_cpu_frame_requested;
            if directly_presented && !direct_present_needs_cpu_frame {
                let size = dmabuf.size();
                self.last_frame_size = Some((size.w.max(0) as u32, size.h.max(0) as u32));
                tracing::info!("[shadow-guest-compositor] presented-frame");
                self.record_touch_present("presented-dmabuf-direct");
                if self.exit_on_first_frame {
                    self.loop_signal.stop();
                }
                buffer.release();
                self.send_frame_callbacks(surface);
                return;
            }

            let capture_started = Instant::now();
            match kms::capture_dmabuf_frame(&dmabuf) {
                Ok(frame) => {
                    let capture_elapsed = capture_started.elapsed();
                    if capture_elapsed.as_millis() >= 8 {
                        tracing::info!(
                            "[shadow-guest-compositor] capture-dmabuf-frame ms={} size={}x{} shell_enabled={} direct_presented={}",
                            capture_elapsed.as_millis(),
                            frame.width,
                            frame.height,
                            self.shell_enabled,
                            directly_presented
                        );
                    }
                    if self.shell_enabled {
                        let app_id = self.surface_apps.get(surface).copied();
                        if let Some(app_id) = app_id {
                            self.app_frames.insert(app_id, frame);
                        }
                        self.publish_visible_shell_frame("captured-dmabuf-frame");
                    } else if directly_presented {
                        self.record_frame_view(frame.view(), "captured-dmabuf-frame");
                        if self.frame_snapshot_cache_enabled {
                            self.last_published_frame = Some(frame.clone());
                        }
                        tracing::info!("[shadow-guest-compositor] presented-frame");
                        self.record_touch_present("captured-dmabuf-frame");
                        if self.exit_on_first_frame {
                            self.loop_signal.stop();
                        }
                    } else {
                        self.publish_frame(&frame, "captured-dmabuf-frame");
                    }
                }
                Err(error) => {
                    let capture_elapsed = capture_started.elapsed();
                    tracing::warn!("[shadow-guest-compositor] capture-dmabuf failed: {error}");
                    if capture_elapsed.as_millis() >= 8 {
                        tracing::info!(
                            "[shadow-guest-compositor] capture-dmabuf-failed-latency ms={} shell_enabled={} direct_presented={}",
                            capture_elapsed.as_millis(),
                            self.shell_enabled,
                            directly_presented
                        );
                    }
                }
            }

            buffer.release();
            self.send_frame_callbacks(surface);
            return;
        }
        if !matches!(observed_type, Some(BufferType::Shm)) {
            tracing::warn!(
                "[shadow-guest-compositor] unsupported-frame-buffer type={:?}",
                observed_type
            );
            buffer.release();
            self.send_frame_callbacks(surface);
            return;
        }
        let capture_result = with_buffer_contents(&buffer, |ptr, len, data| {
            kms::capture_shm_frame(ptr, len, data)
        });

        match capture_result {
            Ok(Ok(frame)) => {
                self.record_touch_commit();
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
    let shell_mode = matches!(config.startup_action, StartupAction::Shell { .. });

    match &state.transport {
        WaylandTransport::NamedSocket(socket_name) => tracing::info!(
            "[shadow-guest-compositor] transport=named-socket socket={}",
            socket_name.to_string_lossy()
        ),
        WaylandTransport::DirectClientFd => {
            tracing::info!("[shadow-guest-compositor] transport=direct-client-fd")
        }
    }
    if state.boot_splash_drm && !shell_mode {
        tracing::info!("[shadow-guest-compositor] boot-splash-drm enabled");
        state.run_boot_splash();
    } else if state.boot_splash_drm && shell_mode {
        tracing::info!("[shadow-guest-compositor] boot-splash-drm skipped shell-mode");
    }
    match config.startup_action {
        StartupAction::Shell { start_app_id } => {
            tracing::info!("[shadow-guest-compositor] shell-mode enabled");
            if let Some(app_id) = start_app_id {
                tracing::info!("[shadow-guest-compositor] shell-startup-prewarm-begin");
                state.prewarm_visible_shell_frame();
                tracing::info!("[shadow-guest-compositor] shell-startup-prewarm-done");
                tracing::info!("[shadow-guest-compositor] shell-startup-home-frame-begin");
                state.publish_visible_shell_frame("shell-home-frame");
                tracing::info!("[shadow-guest-compositor] shell-startup-home-frame-done");
                tracing::info!(
                    "[shadow-guest-compositor] shell-start-app-id={}",
                    app_id.as_str()
                );
                state.launch_or_focus_app(app_id)?;
            } else {
                tracing::info!("[shadow-guest-compositor] shell-startup-prewarm-begin");
                state.prewarm_visible_shell_frame();
                tracing::info!("[shadow-guest-compositor] shell-startup-prewarm-done");
                tracing::info!("[shadow-guest-compositor] shell-startup-home-frame-begin");
                state.publish_visible_shell_frame("shell-home-frame");
                tracing::info!("[shadow-guest-compositor] shell-startup-home-frame-done");
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
    event_loop.run(None, &mut state, |_| {})?;
    state.drain_client_exit_statuses(Duration::from_millis(500));
    Ok(())
}
