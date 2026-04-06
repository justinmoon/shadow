use anyrender_vello_cpu::VelloCpuWindowRenderer;
use blitz_shell::{
    create_default_event_loop, BlitzShellEvent, BlitzShellProxy, View, WindowConfig,
};
use std::sync::mpsc::Receiver;
use std::sync::Arc;
use std::{env, thread, time::Duration};
use winit::{
    application::ApplicationHandler,
    dpi::LogicalSize,
    event::{ButtonSource, ElementState, MouseButton, WindowEvent},
    event_loop::ActiveEventLoop,
    window::{WindowAttributes, WindowId},
};

use crate::document::StaticDocument;
use crate::log::runtime_log;
use crate::runtime_document::RuntimeDocument;

#[cfg(target_os = "linux")]
use winit::platform::wayland::WindowAttributesWayland;

#[cfg(target_os = "linux")]
const BLITZ_DEMO_WAYLAND_APP_ID: &str = "dev.shadow.blitz";
#[cfg(target_os = "linux")]
const RUNTIME_DEMO_WAYLAND_APP_ID: &str = "dev.shadow.counter";

pub fn run() {
    let demo_mode = DemoMode::from_env();
    let event_loop = create_default_event_loop();
    let (proxy, receiver) = BlitzShellProxy::new(event_loop.create_proxy());
    let window = WindowConfig::with_attributes(
        demo_mode.document(),
        VelloCpuWindowRenderer::new(),
        window_attributes(demo_mode),
    );
    let application = BlitzApplication::new(proxy, receiver, window, demo_mode);
    event_loop.run_app(application).expect("run blitz app");
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DemoMode {
    Static,
    Runtime,
}

impl DemoMode {
    fn from_env() -> Self {
        match env::var("SHADOW_BLITZ_DEMO_MODE").ok().as_deref() {
            Some("runtime") => Self::Runtime,
            _ => Self::Static,
        }
    }

    fn document(self) -> Box<dyn blitz_dom::Document> {
        match self {
            Self::Static => Box::new(StaticDocument::new()),
            Self::Runtime => Box::new(RuntimeDocument::from_env_or_sample()),
        }
    }

    fn title(self) -> &'static str {
        match self {
            Self::Static => "Shadow Blitz Demo",
            Self::Runtime => "Shadow Counter",
        }
    }

    #[cfg(target_os = "linux")]
    fn wayland_app_id(self) -> &'static str {
        match self {
            Self::Static => BLITZ_DEMO_WAYLAND_APP_ID,
            Self::Runtime => RUNTIME_DEMO_WAYLAND_APP_ID,
        }
    }

    #[cfg(target_os = "linux")]
    fn wayland_instance_name(self) -> &'static str {
        match self {
            Self::Static => "shadow-blitz-demo",
            Self::Runtime => "shadow-counter",
        }
    }
}

struct BlitzApplication {
    demo_mode: DemoMode,
    proxy: BlitzShellProxy,
    event_queue: Receiver<BlitzShellEvent>,
    pending_window: Option<WindowConfig<VelloCpuWindowRenderer>>,
    window: Option<View<VelloCpuWindowRenderer>>,
    runtime_resume_pending: bool,
    runtime_poll_thread_started: bool,
    runtime_touch_signal_thread_started: bool,
}

impl BlitzApplication {
    fn new(
        proxy: BlitzShellProxy,
        event_queue: Receiver<BlitzShellEvent>,
        window: WindowConfig<VelloCpuWindowRenderer>,
        demo_mode: DemoMode,
    ) -> Self {
        Self {
            demo_mode,
            proxy,
            event_queue,
            pending_window: Some(window),
            window: None,
            runtime_resume_pending: false,
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
                    redraw_window(self.demo_mode, window, "poll");
                }
            }
            BlitzShellEvent::RequestRedraw { doc_id } if window.doc.id() == doc_id => {
                redraw_window(self.demo_mode, window, "doc");
            }
            BlitzShellEvent::Embedder(data) => {
                if handle_runtime_embedder_event(self.demo_mode, window, data) {
                    redraw_window(self.demo_mode, window, "embedder");
                }
            }
            _ => {}
        }

        if document_should_exit(self.demo_mode, window) {
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
            if self.demo_mode == DemoMode::Runtime {
                self.runtime_resume_pending = true;
                runtime_log(format!("window-resume-deferred window={window_id:?}"));
                self.window = Some(window);
            } else {
                runtime_log(format!("window-resume-start window={window_id:?}"));
                window.resume();
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
        self.maybe_resume_runtime_window(window_id, &event);
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
            window.handle_winit_event(event);
            handle_runtime_pointer_button(self.demo_mode, window, runtime_pointer_button);
            request_runtime_redraw(self.demo_mode, window);
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
    fn ensure_runtime_poll_thread(&mut self, window_id: WindowId) {
        if self.demo_mode != DemoMode::Runtime || self.runtime_poll_thread_started {
            return;
        }

        self.runtime_poll_thread_started = true;
        let proxy = self.proxy.clone();
        let interval = env::var("SHADOW_BLITZ_RUNTIME_POLL_INTERVAL_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(40);

        thread::spawn(move || loop {
            thread::sleep(Duration::from_millis(interval));
            proxy.send_event(BlitzShellEvent::Poll { window_id });
        });
    }

    fn ensure_runtime_touch_signal_thread(&mut self) {
        if self.demo_mode != DemoMode::Runtime || self.runtime_touch_signal_thread_started {
            return;
        }
        if env::var_os("SHADOW_BLITZ_TOUCH_SIGNAL_PATH").is_none() {
            return;
        }

        self.runtime_touch_signal_thread_started = true;
        let proxy = self.proxy.clone();
        let interval = env::var("SHADOW_BLITZ_TOUCH_SIGNAL_POLL_INTERVAL_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|value| *value > 0)
            .unwrap_or(40);
        eprintln!("[shadow-runtime-demo] touch-signal-thread-start interval_ms={interval}");
        runtime_log(format!("touch-signal-thread-start interval_ms={interval}"));

        thread::spawn(move || loop {
            thread::sleep(Duration::from_millis(interval));
            proxy.send_event(BlitzShellEvent::embedder_event(
                RuntimeEmbedderEvent::TouchSignalTick,
            ));
        });
    }

    fn maybe_resume_runtime_window(&mut self, window_id: WindowId, event: &WindowEvent) {
        if self.demo_mode != DemoMode::Runtime || !self.runtime_resume_pending {
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
        self.runtime_resume_pending = false;
        self.ensure_runtime_poll_thread(window_id);
        self.ensure_runtime_touch_signal_thread();

        let window = self.window.as_mut().expect("runtime window before resume");
        runtime_log(format!("window-resume-start window={window_id:?}"));
        window.resume();
        runtime_log(format!("window-resume-done window={window_id:?}"));
        let changed = window.poll();
        runtime_log(format!(
            "post-resume-poll window={window_id:?} changed={changed}"
        ));
        if changed {
            redraw_window(self.demo_mode, window, "post-resume-poll");
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

#[derive(Clone, Copy, Debug)]
enum RuntimeEmbedderEvent {
    TouchSignalTick,
}

fn window_attributes(demo_mode: DemoMode) -> WindowAttributes {
    let attributes = WindowAttributes::default()
        .with_title(demo_mode.title())
        .with_resizable(false)
        .with_surface_size(LogicalSize::new(384.0, 720.0));

    #[cfg(target_os = "linux")]
    {
        let wayland_attributes = WindowAttributesWayland::default().with_name(
            demo_mode.wayland_app_id(),
            demo_mode.wayland_instance_name(),
        );
        return attributes.with_platform_attributes(Box::new(wayland_attributes));
    }

    #[allow(unreachable_code)]
    attributes
}

fn document_should_exit(demo_mode: DemoMode, window: &mut View<VelloCpuWindowRenderer>) -> bool {
    match demo_mode {
        DemoMode::Static => window.downcast_doc_mut::<StaticDocument>().should_exit(),
        DemoMode::Runtime => window.downcast_doc_mut::<RuntimeDocument>().should_exit(),
    }
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

#[derive(Clone, Copy, Debug)]
struct RuntimePointerButtonEvent {
    pressed: bool,
    is_primary: bool,
    client_x: f32,
    client_y: f32,
}

fn runtime_pointer_button_event(
    window: &View<VelloCpuWindowRenderer>,
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
    demo_mode: DemoMode,
    window: &mut View<VelloCpuWindowRenderer>,
    event: Option<RuntimePointerButtonEvent>,
) {
    if demo_mode != DemoMode::Runtime || env::var_os("SHADOW_BLITZ_RAW_POINTER_FALLBACK").is_none()
    {
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

fn request_runtime_redraw(demo_mode: DemoMode, window: &mut View<VelloCpuWindowRenderer>) {
    if demo_mode != DemoMode::Runtime {
        return;
    }

    let redraw_requested = window
        .downcast_doc_mut::<RuntimeDocument>()
        .take_redraw_requested();
    if !redraw_requested {
        return;
    }

    redraw_window(demo_mode, window, "runtime-dispatch");
}

fn redraw_window(demo_mode: DemoMode, window: &mut View<VelloCpuWindowRenderer>, source: &str) {
    if demo_mode == DemoMode::Runtime {
        runtime_log(format!(
            "redraw-now source={} window={:?}",
            source,
            window.window_id()
        ));
        window.redraw();
        return;
    }

    runtime_log(format!(
        "request-redraw source={} window={:?}",
        source,
        window.window_id()
    ));
    window.request_redraw();
}

fn handle_runtime_embedder_event(
    demo_mode: DemoMode,
    window: &mut View<VelloCpuWindowRenderer>,
    data: Arc<dyn std::any::Any + Send + Sync>,
) -> bool {
    if demo_mode != DemoMode::Runtime {
        return false;
    }

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
