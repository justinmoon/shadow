#[cfg(any(
    all(feature = "cpu", feature = "gpu"),
    all(feature = "cpu", feature = "gpu_softbuffer"),
    all(feature = "cpu", feature = "hybrid"),
    all(feature = "gpu", feature = "gpu_softbuffer"),
    all(feature = "gpu", feature = "hybrid"),
    all(feature = "gpu_softbuffer", feature = "hybrid"),
))]
compile_error!("shadow-blitz-demo renderer features are mutually exclusive");
#[cfg(not(any(
    feature = "cpu",
    feature = "gpu",
    feature = "gpu_softbuffer",
    feature = "hybrid"
)))]
compile_error!("enable one shadow-blitz-demo renderer feature");

#[cfg(feature = "gpu")]
use anyrender_vello::VelloWindowRenderer as WindowRenderer;
#[cfg(feature = "gpu_softbuffer")]
type WindowRenderer = softbuffer_window_renderer::SoftbufferWindowRenderer<
    anyrender_vello_cpu::VelloCpuImageRenderer,
>;
use crate::log::{runtime_log, runtime_log_json, runtime_wall_ms};
use crate::runtime_document::RuntimeDocument;
#[cfg(all(not(feature = "gpu"), not(feature = "hybrid"), feature = "cpu"))]
use anyrender_vello_cpu::VelloCpuWindowRenderer as WindowRenderer;
#[cfg(all(
    not(feature = "gpu"),
    not(feature = "gpu_softbuffer"),
    feature = "hybrid"
))]
use anyrender_vello_hybrid::VelloHybridWindowRenderer as WindowRenderer;
use blitz_shell::{
    create_default_event_loop, BlitzShellEvent, BlitzShellProxy, View, WindowConfig,
};
use serde::Serialize;
use shadow_ui_core::scene::{APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX};
use std::sync::mpsc::Receiver;
use std::sync::Arc;
use std::{env, path::PathBuf, thread, time::Duration};

#[cfg(target_os = "linux")]
use std::{ffi::CString, io, os::unix::ffi::OsStrExt, path::Path};
use winit::{
    application::ApplicationHandler,
    dpi::LogicalSize,
    event::{ButtonSource, ElementState, MouseButton, WindowEvent},
    event_loop::ActiveEventLoop,
    window::{WindowAttributes, WindowId},
};

#[cfg(target_os = "linux")]
use winit::platform::wayland::WindowAttributesWayland;

#[cfg(target_os = "linux")]
const RUNTIME_DEMO_WAYLAND_APP_ID: &str = "dev.shadow.counter";
const BLITZ_APP_TITLE_ENV: &str = "SHADOW_BLITZ_APP_TITLE";
#[cfg(target_os = "linux")]
const BLITZ_WAYLAND_APP_ID_ENV: &str = "SHADOW_BLITZ_WAYLAND_APP_ID";
#[cfg(target_os = "linux")]
const BLITZ_WAYLAND_INSTANCE_NAME_ENV: &str = "SHADOW_BLITZ_WAYLAND_INSTANCE_NAME";

pub fn run() {
    init_gpu_logging();
    install_panic_hook();
    runtime_log("startup-stage=run-begin");
    log_runtime_summary_start();
    runtime_log("startup-stage=summary-start-done");
    log_display_env();
    runtime_log("startup-stage=display-env-done");
    if renderer_summary_probe_enabled() {
        runtime_log("startup-stage=renderer-summary-probe-begin");
        log_renderer_summary_probe();
        runtime_log("startup-stage=renderer-summary-probe-end");
    } else {
        runtime_log("startup-stage=cpu-summary-begin");
        log_cpu_renderer_summary();
        runtime_log("startup-stage=cpu-summary-end");
    }
    if env::var_os("SHADOW_BLITZ_GPU_PROBE").is_some() {
        runtime_log("startup-stage=wgpu-probe-begin");
        log_wgpu_probe();
        runtime_log("startup-stage=wgpu-probe-end");
    } else {
        runtime_log("wgpu-probe-skipped");
    }
    runtime_log("startup-stage=create-event-loop-begin");
    let event_loop = create_default_event_loop();
    runtime_log("startup-stage=create-event-loop-done");
    let (proxy, receiver) = BlitzShellProxy::new(event_loop.create_proxy());
    runtime_log("startup-stage=proxy-ready");
    let window = WindowConfig::with_attributes(
        Box::new(RuntimeDocument::from_env()),
        WindowRenderer::new(),
        window_attributes(),
    );
    runtime_log("startup-stage=window-config-ready");
    let application = BlitzApplication::new(proxy, receiver, window);
    runtime_log("startup-stage=run-app-begin");
    if let Err(error) = event_loop.run_app(application) {
        runtime_log(format!("run-app-error: {error:?}"));
        eprintln!("[shadow-blitz-demo] run-app-error: {error:?}");
    }
}

fn install_panic_hook() {
    static PANIC_HOOK_INSTALLED: std::sync::OnceLock<()> = std::sync::OnceLock::new();

    PANIC_HOOK_INSTALLED.get_or_init(|| {
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |panic_info| {
            runtime_log(format!("panic-hook {panic_info}"));
            default_hook(panic_info);
        }));
    });
}

fn log_display_env() {
    runtime_log(format!(
        "display-env wayland_display={:?} wayland_socket={:?} display={:?} xdg_runtime_dir={:?} home={:?} xdg_cache_home={:?} xdg_config_home={:?} mesa_shader_cache_dir={:?} wgpu_backend_env={:?} vk_icd_filenames={:?} shadow_linux_ld_preload={:?}",
        env::var("WAYLAND_DISPLAY").ok(),
        env::var("WAYLAND_SOCKET").ok(),
        env::var("DISPLAY").ok(),
        env::var("XDG_RUNTIME_DIR").ok(),
        env::var("HOME").ok(),
        env::var("XDG_CACHE_HOME").ok(),
        env::var("XDG_CONFIG_HOME").ok(),
        env::var("MESA_SHADER_CACHE_DIR").ok(),
        env::var("WGPU_BACKEND").ok(),
        env::var("VK_ICD_FILENAMES").ok(),
        env::var("SHADOW_LINUX_LD_PRELOAD").ok(),
    ));
}

fn env_override(key: &str) -> Option<String> {
    env::var(key).ok().filter(|value| !value.is_empty())
}

fn resolved_title() -> String {
    env_override(BLITZ_APP_TITLE_ENV).unwrap_or_else(|| String::from("Shadow Counter"))
}

#[cfg(target_os = "linux")]
fn resolved_wayland_app_id() -> String {
    env_override(BLITZ_WAYLAND_APP_ID_ENV)
        .unwrap_or_else(|| String::from(RUNTIME_DEMO_WAYLAND_APP_ID))
}

#[cfg(target_os = "linux")]
fn resolved_wayland_instance_name() -> String {
    env_override(BLITZ_WAYLAND_INSTANCE_NAME_ENV)
        .or_else(|| {
            env::var(BLITZ_WAYLAND_APP_ID_ENV).ok().map(|app_id| {
                app_id
                    .rsplit('.')
                    .next()
                    .filter(|segment| !segment.is_empty())
                    .unwrap_or("shadow-counter")
                    .to_string()
            })
        })
        .unwrap_or_else(|| String::from("shadow-counter"))
}

struct BlitzApplication {
    proxy: BlitzShellProxy,
    event_queue: Receiver<BlitzShellEvent>,
    pending_window: Option<WindowConfig<WindowRenderer>>,
    window: Option<View<WindowRenderer>>,
    resume_pending: bool,
    runtime_poll_thread_started: bool,
    runtime_touch_signal_thread_started: bool,
}

impl BlitzApplication {
    fn new(
        proxy: BlitzShellProxy,
        event_queue: Receiver<BlitzShellEvent>,
        window: WindowConfig<WindowRenderer>,
    ) -> Self {
        Self {
            proxy,
            event_queue,
            pending_window: Some(window),
            window: None,
            resume_pending: false,
            runtime_poll_thread_started: false,
            runtime_touch_signal_thread_started: false,
        }
    }

    fn handle_blitz_shell_event(
        &mut self,
        event_loop: &dyn ActiveEventLoop,
        event: BlitzShellEvent,
    ) {
        let Some(window) = self.window.as_mut() else {
            return;
        };

        match event {
            BlitzShellEvent::Poll { window_id } if window.window_id() == window_id => {
                if window.poll() {
                    runtime_log(format!("poll-changed window={window_id:?}"));
                    redraw_window(window, "poll");
                }
            }
            BlitzShellEvent::RequestRedraw { doc_id } if window.doc.id() == doc_id => {
                redraw_window(window, "doc");
            }
            BlitzShellEvent::Embedder(data) => {
                if handle_runtime_embedder_event(window, data) {
                    redraw_window(window, "embedder");
                }
            }
            _ => {}
        }

        if document_should_exit(window) {
            self.window.take();
            event_loop.exit();
        }
    }
}

impl ApplicationHandler for BlitzApplication {
    fn can_create_surfaces(&mut self, event_loop: &dyn ActiveEventLoop) {
        runtime_log("can-create-surfaces");
        if let Some(window) = self.window.as_mut() {
            runtime_log(format!(
                "resume-existing-window window={:?}",
                window.window_id()
            ));
            window.resume();
            log_renderer_backend(window, "resume-existing-window");
            let window_id = window.window_id();
            self.ensure_runtime_poll_thread(window_id);
            self.ensure_runtime_touch_signal_thread();
            self.proxy.send_event(BlitzShellEvent::Poll { window_id });
            runtime_log(format!(
                "request-poll source=can-create-existing window={window_id:?}"
            ));
        }

        if let Some(config) = self.pending_window.take() {
            runtime_log("init-pending-window");
            runtime_log("view-init-start");
            let mut window = View::init(config, event_loop, &self.proxy);
            runtime_log(format!("view-init-done window={:?}", window.window_id()));
            let window_id = window.window_id();
            if self.should_defer_initial_resume() {
                self.resume_pending = true;
                runtime_log(format!("window-resume-deferred window={window_id:?}"));
                self.window = Some(window);
            } else {
                runtime_log(format!("window-resume-start window={window_id:?}"));
                window.resume();
                log_renderer_backend(&window, "resume-new-window");
                runtime_log(format!("window-resume-done window={window_id:?}"));
                self.window = Some(window);
                self.ensure_runtime_poll_thread(window_id);
                self.ensure_runtime_touch_signal_thread();
                self.proxy.send_event(BlitzShellEvent::Poll { window_id });
                runtime_log(format!(
                    "request-poll source=can-create-new window={window_id:?}"
                ));
                runtime_log(format!("window-ready window={window_id:?}"));
            }
        }
    }

    fn destroy_surfaces(&mut self, _event_loop: &dyn ActiveEventLoop) {
        if let Some(window) = self.window.as_mut() {
            window.suspend();
        }
    }

    fn resumed(&mut self, _event_loop: &dyn ActiveEventLoop) {}

    fn suspended(&mut self, _event_loop: &dyn ActiveEventLoop) {}

    fn window_event(
        &mut self,
        event_loop: &dyn ActiveEventLoop,
        window_id: WindowId,
        event: WindowEvent,
    ) {
        self.maybe_resume_deferred_window(window_id, &event);
        log_pointer_window_event(&event);
        let runtime_pointer_button = self
            .window
            .as_ref()
            .and_then(|window| runtime_pointer_button_event(window, &event));

        if matches!(event, WindowEvent::CloseRequested) {
            self.window.take();
            event_loop.exit();
            return;
        }

        if let Some(window) = self.window.as_mut() {
            update_runtime_surface_size(window, &event);
            window.handle_winit_event(event);
            handle_runtime_pointer_button(window, runtime_pointer_button);
            request_runtime_redraw(window);
        }

        self.proxy.send_event(BlitzShellEvent::Poll { window_id });
    }

    fn proxy_wake_up(&mut self, event_loop: &dyn ActiveEventLoop) {
        while let Ok(event) = self.event_queue.try_recv() {
            self.handle_blitz_shell_event(event_loop, event);
        }
    }
}

impl BlitzApplication {
    fn should_defer_initial_resume(&self) -> bool {
        true
    }

    fn ensure_runtime_poll_thread(&mut self, window_id: WindowId) {
        if self.runtime_poll_thread_started {
            return;
        }

        let Some(interval) = env::var("SHADOW_BLITZ_RUNTIME_POLL_INTERVAL_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|value| *value > 0)
        else {
            runtime_log("runtime-poll-thread-disabled");
            return;
        };

        self.runtime_poll_thread_started = true;
        let proxy = self.proxy.clone();
        thread::spawn(move || loop {
            thread::sleep(Duration::from_millis(interval));
            proxy.send_event(BlitzShellEvent::Poll { window_id });
        });
    }

    fn ensure_runtime_touch_signal_thread(&mut self) {
        if self.runtime_touch_signal_thread_started {
            return;
        }
        let Some(path) = env::var_os("SHADOW_BLITZ_TOUCH_SIGNAL_PATH")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
        else {
            return;
        };

        self.runtime_touch_signal_thread_started = true;
        let proxy = self.proxy.clone();
        let interval = env::var("SHADOW_BLITZ_TOUCH_SIGNAL_POLL_INTERVAL_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(40);
        let watch_mode = touch_signal_watch_mode();
        eprintln!(
            "[shadow-runtime-demo] touch-signal-thread-start mode={watch_mode:?} interval_ms={interval} path={}",
            path.display()
        );
        runtime_log(format!(
            "touch-signal-thread-start mode={watch_mode:?} interval_ms={interval} path={}",
            path.display()
        ));

        thread::spawn(move || run_touch_signal_thread(proxy, path, interval, watch_mode));
    }

    fn maybe_resume_deferred_window(&mut self, window_id: WindowId, event: &WindowEvent) {
        if !self.resume_pending {
            return;
        }
        let Some(window) = self.window.as_ref() else {
            return;
        };
        if window.window_id() != window_id {
            return;
        }

        runtime_log(format!(
            "window-resume-trigger window={window_id:?} event={}",
            window_event_name(event)
        ));
        self.resume_pending = false;
        self.ensure_runtime_poll_thread(window_id);
        self.ensure_runtime_touch_signal_thread();

        let window = self.window.as_mut().expect("window before deferred resume");
        runtime_log(format!("window-resume-start window={window_id:?}"));
        window.resume();
        log_renderer_backend(window, "resume-deferred-window");
        runtime_log(format!("window-resume-done window={window_id:?}"));
        let changed = window.poll();
        runtime_log(format!(
            "post-resume-poll window={window_id:?} changed={changed}"
        ));
        if changed {
            redraw_window(window, "post-resume-poll");
        }
        self.proxy.send_event(BlitzShellEvent::Poll { window_id });
        runtime_log(format!(
            "request-poll source=deferred-resume window={window_id:?}"
        ));
        runtime_log(format!("window-ready window={window_id:?}"));
    }
}

fn window_event_name(event: &WindowEvent) -> &'static str {
    match event {
        WindowEvent::RedrawRequested => "RedrawRequested",
        WindowEvent::SurfaceResized(_) => "SurfaceResized",
        WindowEvent::ScaleFactorChanged { .. } => "ScaleFactorChanged",
        WindowEvent::Occluded(_) => "Occluded",
        WindowEvent::ThemeChanged(_) => "ThemeChanged",
        WindowEvent::PointerEntered { .. } => "PointerEntered",
        WindowEvent::PointerMoved { .. } => "PointerMoved",
        WindowEvent::PointerButton { .. } => "PointerButton",
        WindowEvent::PointerLeft { .. } => "PointerLeft",
        WindowEvent::ModifiersChanged(_) => "ModifiersChanged",
        WindowEvent::Focused(_) => "Focused",
        WindowEvent::ActivationTokenDone { .. } => "ActivationTokenDone",
        WindowEvent::Moved(_) => "Moved",
        WindowEvent::CloseRequested => "CloseRequested",
        WindowEvent::Destroyed => "Destroyed",
        WindowEvent::Ime(_) => "Ime",
        WindowEvent::KeyboardInput { .. } => "KeyboardInput",
        WindowEvent::MouseWheel { .. } => "MouseWheel",
        WindowEvent::TouchpadPressure { .. } => "TouchpadPressure",
        WindowEvent::PinchGesture { .. } => "PinchGesture",
        WindowEvent::PanGesture { .. } => "PanGesture",
        WindowEvent::DoubleTapGesture { .. } => "DoubleTapGesture",
        WindowEvent::RotationGesture { .. } => "RotationGesture",
        WindowEvent::DragEntered { .. } => "DragEntered",
        WindowEvent::DragMoved { .. } => "DragMoved",
        WindowEvent::DragDropped { .. } => "DragDropped",
        WindowEvent::DragLeft { .. } => "DragLeft",
    }
}

#[cfg(any(feature = "gpu", feature = "hybrid"))]
fn log_renderer_backend(window: &View<WindowRenderer>, source: &str) {
    let Some(device_handle) = window.renderer.current_device_handle() else {
        runtime_log(format!("renderer-backend source={source} state=suspended"));
        return;
    };

    let info = device_handle.adapter.get_info();
    runtime_log(format!(
        "renderer-backend source={source} backend={backend:?} device_type={device_type:?} name={name:?} driver={driver:?} driver_info={driver_info:?} vendor=0x{vendor:04x} device=0x{device:04x} env_backend={env_backend:?} env_adapter={env_adapter:?}",
        backend = info.backend,
        device_type = info.device_type,
        name = info.name,
        driver = info.driver,
        driver_info = info.driver_info,
        vendor = info.vendor,
        device = info.device,
        env_backend = env::var("WGPU_BACKEND").ok(),
        env_adapter = env::var("WGPU_ADAPTER_NAME").ok(),
    ));
    log_adapter_summary(renderer_name(), &info, "live");
}

#[cfg(all(not(feature = "gpu"), not(feature = "hybrid")))]
fn log_renderer_backend(_window: &View<WindowRenderer>, _source: &str) {}

#[cfg(any(feature = "gpu", feature = "gpu_softbuffer", feature = "hybrid"))]
fn init_gpu_logging() {
    let mut builder =
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    builder.format_timestamp_millis();
    let _ = builder.try_init();
}

#[cfg(not(any(feature = "gpu", feature = "gpu_softbuffer", feature = "hybrid")))]
fn init_gpu_logging() {}

#[derive(Serialize)]
struct RuntimeSummaryStart<'a> {
    renderer: &'a str,
    mode: &'a str,
    wall_ms: u128,
}

#[derive(Serialize)]
struct ClientRendererSummary<'a> {
    renderer: &'a str,
    mode: &'a str,
    backend: Option<String>,
    device_type: Option<String>,
    adapter_name: Option<String>,
    driver: Option<String>,
    driver_info: Option<String>,
    software_backed: bool,
    source: &'a str,
    probe_error: Option<String>,
}

fn renderer_name() -> &'static str {
    #[cfg(feature = "gpu")]
    {
        return "gpu";
    }
    #[cfg(feature = "gpu_softbuffer")]
    {
        return "gpu_softbuffer";
    }
    #[cfg(feature = "hybrid")]
    {
        return "hybrid";
    }
    #[cfg(feature = "cpu")]
    {
        return "cpu";
    }
}

fn log_runtime_summary_start() {
    let summary = RuntimeSummaryStart {
        renderer: renderer_name(),
        mode: "runtime",
        wall_ms: runtime_wall_ms(),
    };
    runtime_log_json("gpu-summary-start", &summary);
}

fn log_cpu_renderer_summary() {
    if renderer_name() != "cpu" {
        return;
    }

    let summary = ClientRendererSummary {
        renderer: renderer_name(),
        mode: "runtime",
        backend: None,
        device_type: None,
        adapter_name: None,
        driver: None,
        driver_info: None,
        software_backed: true,
        source: "cpu",
        probe_error: None,
    };
    runtime_log_json("gpu-summary-client", &summary);
}

fn renderer_summary_probe_enabled() -> bool {
    env::var_os("SHADOW_BLITZ_GPU_SUMMARY").is_some()
}

#[cfg(any(feature = "gpu", feature = "gpu_softbuffer", feature = "hybrid"))]
fn log_wgpu_probe() {
    let descriptor = wgpu::InstanceDescriptor {
        backends: wgpu::Backends::from_env().unwrap_or_default(),
        flags: wgpu::InstanceFlags::from_build_config().with_env(),
        backend_options: wgpu::BackendOptions::from_env_or_default(),
        memory_budget_thresholds: wgpu::MemoryBudgetThresholds::default(),
    };
    runtime_log(format!(
        "wgpu-probe-start mode=runtime backends={:?} flags={:?} env_backend={:?} env_adapter={:?} env_vk_icd={:?}",
        descriptor.backends,
        descriptor.flags,
        env::var("WGPU_BACKEND").ok(),
        env::var("WGPU_ADAPTER_NAME").ok(),
        env::var("VK_ICD_FILENAMES").ok(),
    ));

    let instance = wgpu::Instance::new(&descriptor);
    let adapters = pollster::block_on(instance.enumerate_adapters(descriptor.backends));
    runtime_log(format!("wgpu-probe-adapters count={}", adapters.len()));
    for (index, adapter) in adapters.into_iter().enumerate() {
        let info = adapter.get_info();
        runtime_log(format!(
            "wgpu-probe-adapter index={index} backend={backend:?} device_type={device_type:?} name={name:?} driver={driver:?} driver_info={driver_info:?} vendor=0x{vendor:04x} device=0x{device:04x}",
            backend = info.backend,
            device_type = info.device_type,
            name = info.name,
            driver = info.driver,
            driver_info = info.driver_info,
            vendor = info.vendor,
            device = info.device,
        ));
    }

    match pollster::block_on(wgpu::util::initialize_adapter_from_env_or_default(
        &instance, None,
    )) {
        Ok(adapter) => {
            let info = adapter.get_info();
            runtime_log(format!(
                "wgpu-probe-selected backend={backend:?} device_type={device_type:?} name={name:?} driver={driver:?} driver_info={driver_info:?}",
                backend = info.backend,
                device_type = info.device_type,
                name = info.name,
                driver = info.driver,
                driver_info = info.driver_info,
            ));
        }
        Err(error) => {
            runtime_log(format!("wgpu-probe-selected error={error:?}"));
        }
    }
}

#[cfg(not(any(feature = "gpu", feature = "gpu_softbuffer", feature = "hybrid")))]
fn log_wgpu_probe() {}

#[cfg(any(feature = "gpu", feature = "gpu_softbuffer", feature = "hybrid"))]
fn log_renderer_summary_probe() {
    let descriptor = wgpu::InstanceDescriptor {
        backends: wgpu::Backends::from_env().unwrap_or_default(),
        flags: wgpu::InstanceFlags::from_build_config().with_env(),
        backend_options: wgpu::BackendOptions::from_env_or_default(),
        memory_budget_thresholds: wgpu::MemoryBudgetThresholds::default(),
    };
    let instance = wgpu::Instance::new(&descriptor);

    match pollster::block_on(wgpu::util::initialize_adapter_from_env_or_default(
        &instance, None,
    )) {
        Ok(adapter) => {
            let info = adapter.get_info();
            log_adapter_summary(renderer_name(), &info, "probe");
        }
        Err(error) => {
            let summary = ClientRendererSummary {
                renderer: renderer_name(),
                mode: "runtime",
                backend: None,
                device_type: None,
                adapter_name: None,
                driver: None,
                driver_info: None,
                software_backed: true,
                source: "probe",
                probe_error: Some(format!("{error:?}")),
            };
            runtime_log_json("gpu-summary-client", &summary);
        }
    }
}

#[cfg(not(any(feature = "gpu", feature = "gpu_softbuffer", feature = "hybrid")))]
fn log_renderer_summary_probe() {
    log_cpu_renderer_summary();
}

#[cfg(any(feature = "gpu", feature = "gpu_softbuffer", feature = "hybrid"))]
fn log_adapter_summary(renderer: &str, info: &wgpu::AdapterInfo, source: &str) {
    let summary = ClientRendererSummary {
        renderer,
        mode: "runtime",
        backend: Some(format!("{:?}", info.backend)),
        device_type: Some(format!("{:?}", info.device_type)),
        adapter_name: Some(info.name.clone()),
        driver: Some(info.driver.clone()),
        driver_info: Some(info.driver_info.clone()),
        software_backed: adapter_is_software(info),
        source,
        probe_error: None,
    };
    runtime_log_json("gpu-summary-client", &summary);
}

#[cfg(any(feature = "gpu", feature = "gpu_softbuffer", feature = "hybrid"))]
fn adapter_is_software(info: &wgpu::AdapterInfo) -> bool {
    if matches!(info.device_type, wgpu::DeviceType::Cpu) {
        return true;
    }

    let haystack = format!(
        "{} {} {}",
        info.name.to_ascii_lowercase(),
        info.driver.to_ascii_lowercase(),
        info.driver_info.to_ascii_lowercase()
    );
    ["llvmpipe", "lavapipe", "swrast", "swiftshader", "software"]
        .iter()
        .any(|needle| haystack.contains(needle))
}

#[derive(Clone, Copy, Debug)]
enum RuntimeEmbedderEvent {
    TouchSignalTick,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TouchSignalWatchMode {
    Auto,
    Poll,
}

fn touch_signal_watch_mode() -> TouchSignalWatchMode {
    touch_signal_watch_mode_from_env(env::var("SHADOW_BLITZ_TOUCH_SIGNAL_WATCH").ok().as_deref())
}

fn touch_signal_watch_mode_from_env(value: Option<&str>) -> TouchSignalWatchMode {
    match value {
        Some("0") | Some("false") | Some("off") | Some("poll") => TouchSignalWatchMode::Poll,
        _ => TouchSignalWatchMode::Auto,
    }
}

fn run_touch_signal_thread(
    proxy: BlitzShellProxy,
    path: PathBuf,
    interval_ms: u64,
    watch_mode: TouchSignalWatchMode,
) {
    if matches!(watch_mode, TouchSignalWatchMode::Auto) {
        #[cfg(target_os = "linux")]
        match run_touch_signal_inotify_loop(&proxy, &path) {
            Ok(()) => return,
            Err(error) => runtime_log(format!(
                "touch-signal-watch-fallback reason={} path={}",
                error,
                path.display()
            )),
        }
        #[cfg(not(target_os = "linux"))]
        runtime_log(format!(
            "touch-signal-watch-fallback reason=unsupported-platform path={}",
            path.display()
        ));
    }

    run_touch_signal_poll_loop(proxy, interval_ms);
}

fn run_touch_signal_poll_loop(proxy: BlitzShellProxy, interval_ms: u64) {
    runtime_log(format!(
        "touch-signal-poll-loop-start interval_ms={interval_ms}"
    ));
    loop {
        thread::sleep(Duration::from_millis(interval_ms));
        send_touch_signal_tick(&proxy);
    }
}

fn send_touch_signal_tick(proxy: &BlitzShellProxy) {
    proxy.send_event(BlitzShellEvent::embedder_event(
        RuntimeEmbedderEvent::TouchSignalTick,
    ));
}

#[cfg(target_os = "linux")]
fn run_touch_signal_inotify_loop(proxy: &BlitzShellProxy, path: &Path) -> io::Result<()> {
    let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let _fd_guard = InotifyFd(fd);

    let watch_path = if path.exists() {
        path
    } else {
        path.parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."))
    };
    let watch_path_cstr = CString::new(watch_path.as_os_str().as_bytes()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("inotify path contains NUL: {}", watch_path.display()),
        )
    })?;
    let mask = libc::IN_CLOSE_WRITE
        | libc::IN_MODIFY
        | libc::IN_CREATE
        | libc::IN_MOVED_TO
        | libc::IN_DELETE_SELF
        | libc::IN_MOVE_SELF;
    let watch = unsafe { libc::inotify_add_watch(fd, watch_path_cstr.as_ptr(), mask) };
    if watch < 0 {
        return Err(io::Error::last_os_error());
    }

    runtime_log(format!(
        "touch-signal-watch-start mode=inotify path={} watch_path={}",
        path.display(),
        watch_path.display()
    ));

    let mut buffer = [0_u8; 4096];
    loop {
        let read_count =
            unsafe { libc::read(fd, buffer.as_mut_ptr().cast::<libc::c_void>(), buffer.len()) };
        if read_count < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(error);
        }
        if read_count == 0 {
            continue;
        }
        send_touch_signal_tick(proxy);
    }
}

#[cfg(target_os = "linux")]
struct InotifyFd(libc::c_int);

#[cfg(target_os = "linux")]
impl Drop for InotifyFd {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.0);
        }
    }
}

fn window_attributes() -> WindowAttributes {
    let attributes = WindowAttributes::default()
        .with_title(resolved_title())
        .with_resizable(false)
        .with_surface_size(LogicalSize::new(
            f64::from(APP_VIEWPORT_WIDTH_PX),
            f64::from(APP_VIEWPORT_HEIGHT_PX),
        ));

    #[cfg(target_os = "linux")]
    {
        let wayland_attributes = WindowAttributesWayland::default()
            .with_name(resolved_wayland_app_id(), resolved_wayland_instance_name());
        return attributes.with_platform_attributes(Box::new(wayland_attributes));
    }

    #[allow(unreachable_code)]
    attributes
}

fn document_should_exit(window: &mut View<WindowRenderer>) -> bool {
    window.downcast_doc_mut::<RuntimeDocument>().should_exit()
}

fn log_pointer_window_event(event: &WindowEvent) {
    if env::var_os("SHADOW_BLITZ_LOG_WINIT_POINTER").is_none() {
        return;
    }

    match event {
        WindowEvent::RedrawRequested => {
            runtime_log("winit-redraw-requested");
        }
        WindowEvent::PointerMoved {
            position,
            source,
            primary,
            ..
        } => {
            eprintln!(
                "[shadow-runtime-demo] winit-pointer-moved x={:.1} y={:.1} primary={} source={:?}",
                position.x, position.y, primary, source
            );
        }
        WindowEvent::PointerButton {
            button,
            state,
            position,
            primary,
            ..
        } => {
            eprintln!(
                "[shadow-runtime-demo] winit-pointer-button state={:?} x={:.1} y={:.1} primary={} button={:?}",
                state,
                position.x,
                position.y,
                primary,
                button
            );
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::{
        resolved_title, touch_signal_watch_mode_from_env, TouchSignalWatchMode, BLITZ_APP_TITLE_ENV,
    };
    use std::{
        env,
        sync::{Mutex, MutexGuard},
    };

    #[cfg(target_os = "linux")]
    const WAYLAND_APP_ID_ENV: &str = "SHADOW_BLITZ_WAYLAND_APP_ID";
    #[cfg(target_os = "linux")]
    const WAYLAND_INSTANCE_NAME_ENV: &str = "SHADOW_BLITZ_WAYLAND_INSTANCE_NAME";

    fn env_guard() -> MutexGuard<'static, ()> {
        static ENV_MUTEX: Mutex<()> = Mutex::new(());
        ENV_MUTEX
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    struct EnvRestore {
        saved: Vec<(&'static str, Option<String>)>,
    }

    impl EnvRestore {
        fn new(keys: &[&'static str]) -> Self {
            let saved = keys
                .iter()
                .map(|key| (*key, env::var(key).ok()))
                .collect::<Vec<_>>();
            for key in keys {
                env::remove_var(key);
            }
            Self { saved }
        }
    }

    impl Drop for EnvRestore {
        fn drop(&mut self) {
            for (key, value) in self.saved.drain(..) {
                if let Some(value) = value {
                    env::set_var(key, value);
                } else {
                    env::remove_var(key);
                }
            }
        }
    }

    #[test]
    fn runtime_launch_honors_overrides() {
        let _guard = env_guard();
        #[cfg_attr(not(target_os = "linux"), allow(unused_mut))]
        let mut restore_keys = vec![BLITZ_APP_TITLE_ENV];
        #[cfg(target_os = "linux")]
        {
            restore_keys.push(WAYLAND_APP_ID_ENV);
            restore_keys.push(WAYLAND_INSTANCE_NAME_ENV);
        }
        let _restore = EnvRestore::new(&restore_keys);

        env::set_var(BLITZ_APP_TITLE_ENV, "Shadow Timeline");
        #[cfg(target_os = "linux")]
        {
            env::set_var(WAYLAND_APP_ID_ENV, "dev.shadow.timeline");
            env::set_var(WAYLAND_INSTANCE_NAME_ENV, "timeline");
        }

        assert_eq!(resolved_title(), "Shadow Timeline");
        #[cfg(target_os = "linux")]
        {
            assert_eq!(super::resolved_wayland_app_id(), "dev.shadow.timeline");
            assert_eq!(super::resolved_wayland_instance_name(), "timeline");
        }
    }

    #[test]
    fn touch_signal_watch_mode_defaults_to_auto() {
        assert_eq!(
            touch_signal_watch_mode_from_env(None),
            TouchSignalWatchMode::Auto
        );
        assert_eq!(
            touch_signal_watch_mode_from_env(Some("inotify")),
            TouchSignalWatchMode::Auto
        );
        assert_eq!(
            touch_signal_watch_mode_from_env(Some("poll")),
            TouchSignalWatchMode::Poll
        );
        assert_eq!(
            touch_signal_watch_mode_from_env(Some("off")),
            TouchSignalWatchMode::Poll
        );
    }
}

#[derive(Clone, Copy, Debug)]
struct RuntimePointerButtonEvent {
    pressed: bool,
    is_primary: bool,
    client_x: f32,
    client_y: f32,
}

fn runtime_pointer_button_event(
    window: &View<WindowRenderer>,
    event: &WindowEvent,
) -> Option<RuntimePointerButtonEvent> {
    let WindowEvent::PointerButton {
        button,
        state,
        primary,
        position,
        ..
    } = event
    else {
        return None;
    };

    let ButtonSource::Mouse(MouseButton::Left) = button else {
        return None;
    };

    let coords = window.pointer_coords(*position);
    Some(RuntimePointerButtonEvent {
        pressed: matches!(state, ElementState::Pressed),
        is_primary: *primary,
        client_x: coords.client_x,
        client_y: coords.client_y,
    })
}

fn handle_runtime_pointer_button(
    window: &mut View<WindowRenderer>,
    event: Option<RuntimePointerButtonEvent>,
) {
    if env::var_os("SHADOW_BLITZ_RAW_POINTER_FALLBACK").is_none() {
        return;
    }
    let Some(event) = event else {
        return;
    };

    window
        .downcast_doc_mut::<RuntimeDocument>()
        .handle_raw_pointer_button(
            event.pressed,
            event.is_primary,
            event.client_x,
            event.client_y,
        );
}

fn update_runtime_surface_size(window: &mut View<WindowRenderer>, event: &WindowEvent) {
    let WindowEvent::SurfaceResized(size) = event else {
        return;
    };
    window
        .downcast_doc_mut::<RuntimeDocument>()
        .update_surface_size(size.width, size.height);
}

fn request_runtime_redraw(window: &mut View<WindowRenderer>) {
    let redraw_requested = window
        .downcast_doc_mut::<RuntimeDocument>()
        .take_redraw_requested();
    if !redraw_requested {
        return;
    }

    redraw_window(window, "runtime-dispatch");
}

fn redraw_window(window: &mut View<WindowRenderer>, source: &str) {
    runtime_log(format!(
        "redraw-now source={} window={:?}",
        source,
        window.window_id()
    ));
    window.redraw();
}

fn handle_runtime_embedder_event(
    window: &mut View<WindowRenderer>,
    data: Arc<dyn std::any::Any + Send + Sync>,
) -> bool {
    let Some(event) = data.downcast_ref::<RuntimeEmbedderEvent>() else {
        return false;
    };

    match event {
        RuntimeEmbedderEvent::TouchSignalTick => {
            let changed = window
                .downcast_doc_mut::<RuntimeDocument>()
                .check_touch_signal();
            if changed {
                runtime_log("touch-signal-redraw-requested");
            }
            changed
        }
    }
}
