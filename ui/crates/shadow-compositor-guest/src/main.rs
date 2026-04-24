mod config;
mod control;
mod gpu_scanout;
mod handlers;
mod hosted;
mod input;
mod kms;
mod launch;
mod media_keys;
mod prompt;
mod render;
mod session;
mod shell;
mod shell_gpu;
mod touch;

use std::{
    collections::{HashMap, VecDeque},
    ffi::OsString,
    fs,
    io::Write,
    os::{
        fd::AsRawFd,
        unix::{fs::MetadataExt, net::UnixStream},
    },
    path::PathBuf,
    process::Child,
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use config::{
    DmabufFormatProfile, GuestClientConfig, GuestStartupConfig, GuestSyntheticTapConfig,
    StartupAction, TransportRequest,
};
use shadow_runtime_protocol::{
    SystemPromptRequest, SystemPromptResponse, SystemPromptSocketResponse,
};
use shadow_ui_core::{
    app::AppId,
    scene::{
        APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX, APP_VIEWPORT_X, APP_VIEWPORT_Y, HEIGHT,
        WIDTH,
    },
    shell::{ShellAction, ShellEvent, ShellModel},
};
use shell::GuestShellSurface;
use smithay::{
    backend::allocator::{Format, Fourcc, Modifier},
    desktop::{Space, Window, WindowSurfaceType},
    input::{Seat, SeatState},
    reexports::{
        calloop::{channel, generic::Generic, EventLoop, Interest, LoopSignal, Mode, PostAction},
        wayland_server::{protocol::wl_surface::WlSurface, BindError, Display, DisplayHandle},
    },
    utils::{Logical, Point},
    wayland::{
        compositor::{get_parent, CompositorState},
        dmabuf::{DmabufFeedbackBuilder, DmabufGlobal, DmabufState},
        presentation::PresentationState,
        shell::xdg::XdgShellState,
        shm::ShmState,
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

struct PendingSystemPrompt {
    stream: UnixStream,
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
    exit_requested: bool,
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
    pending_system_prompt: Option<PendingSystemPrompt>,
    exit_on_first_frame: bool,
    first_frame_exit_app_id: Option<AppId>,
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
    software_keyboard_enabled: bool,
    background_app_resident_limit: usize,
    touch_signal_counter: u64,
    touch_signal_path: Option<PathBuf>,
    touch_latency_trace: bool,
    synthetic_tap: Option<GuestSyntheticTapConfig>,
    synthetic_tap_sender: Option<channel::Sender<touch::TouchInputEvent>>,
    synthetic_tap_scheduled: bool,
    exit_after_touch_present: bool,
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
        let first_frame_exit_app_id = match config.startup_action {
            StartupAction::Shell {
                start_app_id: Some(app_id),
            } => Some(app_id),
            _ => None,
        };
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
        let control_socket_path = if config.startup_action.needs_control_socket() {
            let control_socket_path =
                control::init_listener(event_loop, config.client.runtime_dir.clone())
                    .expect("create guest compositor control socket");
            prompt::init_listener(event_loop, &control_socket_path)
                .expect("create guest compositor system prompt socket");
            control_socket_path
        } else {
            tracing::info!(
                "[shadow-guest-compositor] control sockets skipped for shell-only startup"
            );
            shadow_compositor_common::control::control_socket_path(
                config.client.runtime_dir.clone(),
            )
        };

        let mut state = Self {
            start_time: Instant::now(),
            transport,
            display_handle: display_handle.clone(),
            space: Space::default(),
            loop_signal,
            exit_requested: false,
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
            pending_system_prompt: None,
            exit_on_first_frame: config.exit_on_first_frame,
            first_frame_exit_app_id,
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
            software_keyboard_enabled: config.software_keyboard_enabled,
            background_app_resident_limit: config.background_app_resident_limit,
            touch_signal_counter: 0,
            touch_signal_path: config.touch_signal_path.clone(),
            touch_latency_trace: config.touch_latency_trace,
            synthetic_tap: config.synthetic_tap,
            synthetic_tap_sender: None,
            synthetic_tap_scheduled: false,
            exit_after_touch_present: config.exit_after_touch_present,
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
        state.insert_synthetic_touch_source(event_loop);
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
        if self.exit_after_touch_present {
            tracing::info!(
                "[shadow-guest-compositor] touch-present-exit route={} seq={}",
                trace.route,
                trace.sequence
            );
            self.request_exit();
        }
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

    pub(crate) fn request_exit(&mut self) {
        self.exit_requested = true;
        self.loop_signal.stop();
    }

    pub(crate) fn should_exit_after_presented_frame(
        &self,
        app_frame_app_id: Option<AppId>,
    ) -> bool {
        self.exit_on_first_frame
            && self
                .first_frame_exit_app_id
                .map(|required_app_id| app_frame_app_id == Some(required_app_id))
                .unwrap_or(true)
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
                        Arc::new(handlers::ClientState::new(disconnect_signal.clone())),
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
                        Arc::new(handlers::ClientState::new(
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

    fn shell_overlay_visible(&self) -> bool {
        self.shell_enabled
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
            ShellAction::SystemPromptResponse { action_id } => {
                if let Err(error) = self.resolve_system_prompt(action_id) {
                    tracing::warn!(
                        "[shadow-guest-compositor] failed to resolve system prompt: {error}"
                    );
                }
            }
        }
    }

    fn handle_system_prompt_request(
        &mut self,
        request: SystemPromptRequest,
        stream: &mut UnixStream,
    ) -> std::io::Result<shadow_compositor_common::control::SystemPromptRequestDisposition> {
        if self.pending_system_prompt.is_some() {
            write_system_prompt_error(stream, String::from("system prompt is already active"))?;
            return Ok(
                shadow_compositor_common::control::SystemPromptRequestDisposition::Responded,
            );
        }

        self.pending_system_prompt = Some(PendingSystemPrompt {
            stream: stream.try_clone()?,
        });
        self.shell.set_system_prompt(Some(request));
        self.publish_visible_shell_frame("system-prompt-open");
        Ok(shadow_compositor_common::control::SystemPromptRequestDisposition::Deferred)
    }

    fn resolve_system_prompt(&mut self, action_id: String) -> std::io::Result<()> {
        let Some(pending) = self.pending_system_prompt.take() else {
            return Ok(());
        };
        let mut stream = pending.stream;
        self.shell.set_system_prompt(None);
        let result = write_system_prompt_ok(&mut stream, SystemPromptResponse { action_id });
        self.publish_visible_shell_frame("system-prompt-resolve");
        result
    }

    pub(crate) fn resolve_system_prompt_via_control(
        &mut self,
        action_id: String,
    ) -> std::io::Result<String> {
        if self.pending_system_prompt.is_none() {
            return Ok(String::from(
                "ok\nhandled=0\nreason=no-active-system-prompt\naction_id=\n",
            ));
        }

        self.resolve_system_prompt(action_id.clone())?;
        Ok(format!("ok\nhandled=1\naction_id={action_id}\n"))
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
        let prompt_socket_path = shadow_runtime_protocol::system_prompt_socket_path(
            self.control_socket_path
                .parent()
                .unwrap_or_else(|| std::path::Path::new(".")),
        );
        let _ = std::fs::remove_file(prompt_socket_path);
    }
}

fn write_system_prompt_ok(
    stream: &mut UnixStream,
    response: SystemPromptResponse,
) -> std::io::Result<()> {
    let encoded = serde_json::to_string(&SystemPromptSocketResponse::Ok { payload: response })
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    stream.write_all(encoded.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()
}

fn write_system_prompt_error(stream: &mut UnixStream, message: String) -> std::io::Result<()> {
    let encoded = serde_json::to_string(&SystemPromptSocketResponse::Error { message })
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    stream.write_all(encoded.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()
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
    if state.exit_requested {
        tracing::info!("[shadow-guest-compositor] startup-exit-requested");
        state.drain_client_exit_statuses(Duration::from_millis(500));
        return Ok(());
    }

    event_loop.run(None, &mut state, |_| {})?;
    state.drain_client_exit_statuses(Duration::from_millis(500));
    Ok(())
}
