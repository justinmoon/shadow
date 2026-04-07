#[cfg(all(feature = "gpu", any(feature = "cpu", feature = "hybrid")))]
compile_error!("shadow-blitz-demo renderer features are mutually exclusive");
#[cfg(all(feature = "hybrid", feature = "cpu"))]
compile_error!("shadow-blitz-demo renderer features are mutually exclusive");
#[cfg(not(any(feature = "cpu", feature = "gpu", feature = "hybrid")))]
compile_error!("enable one shadow-blitz-demo renderer feature");

#[cfg(feature = "gpu")]
use anyrender_vello::VelloWindowRenderer as WindowRenderer;
#[cfg(all(not(feature = "gpu"), not(feature = "hybrid"), feature = "cpu"))]
use anyrender_vello_cpu::VelloCpuWindowRenderer as WindowRenderer;
#[cfg(all(not(feature = "gpu"), feature = "hybrid"))]
use anyrender_vello_hybrid::VelloHybridWindowRenderer as WindowRenderer;
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

use crate::log::runtime_log;
use crate::runtime_document::RuntimeDocument;

#[cfg(target_os = "linux")]
use winit::platform::wayland::WindowAttributesWayland;

#[cfg(target_os = "linux")]
const DEFAULT_WAYLAND_APP_ID: &str = "dev.shadow.counter";
const DEFAULT_APP_TITLE: &str = "Shadow Counter";
const DEFAULT_SURFACE_WIDTH: u32 = 384;
const DEFAULT_SURFACE_HEIGHT: u32 = 720;

pub fn run() {
    let event_loop = create_default_event_loop();
    let (proxy, receiver) = BlitzShellProxy::new(event_loop.create_proxy());
    let window = WindowConfig::with_attributes(
        Box::new(RuntimeDocument::from_env()),
        WindowRenderer::new(),
        window_attributes(),
    );
    let application = BlitzApplication::new(proxy, receiver, window);
    event_loop.run_app(application).expect("run blitz app");
}

struct BlitzApplication {
    proxy: BlitzShellProxy,
    event_queue: Receiver<BlitzShellEvent>,
    pending_window: Option<WindowConfig<WindowRenderer>>,
    window: Option<View<WindowRenderer>>,
    runtime_resume_pending: bool,
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
            let window = View::init(config, event_loop, &self.proxy);
            let window_id = window.window_id();
            runtime_log(format!("view-init-done window={window_id:?}"));
            self.runtime_resume_pending = true;
            runtime_log(format!("window-resume-deferred window={window_id:?}"));
            self.window = Some(window);
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
    fn ensure_runtime_poll_thread(&mut self, window_id: WindowId) {
        if self.runtime_poll_thread_started {
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
        if self.runtime_touch_signal_thread_started {
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
        if !self.runtime_resume_pending {
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

#[derive(Clone, Copy, Debug)]
enum RuntimeEmbedderEvent {
    TouchSignalTick,
}

fn window_attributes() -> WindowAttributes {
    let (surface_width, surface_height) = surface_size_from_env();
    let attributes = WindowAttributes::default()
        .with_title(app_title())
        .with_resizable(false)
        .with_surface_size(LogicalSize::new(
            surface_width as f64,
            surface_height as f64,
        ));

    #[cfg(target_os = "linux")]
    {
        let wayland_attributes =
            WindowAttributesWayland::default().with_name(wayland_app_id(), "shadow-blitz-demo");
        return attributes.with_platform_attributes(Box::new(wayland_attributes));
    }

    #[allow(unreachable_code)]
    attributes
}

fn app_title() -> String {
    env::var("SHADOW_BLITZ_APP_TITLE").unwrap_or_else(|_| String::from(DEFAULT_APP_TITLE))
}

#[cfg(target_os = "linux")]
fn wayland_app_id() -> String {
    env::var("SHADOW_BLITZ_WAYLAND_APP_ID").unwrap_or_else(|_| String::from(DEFAULT_WAYLAND_APP_ID))
}

fn surface_size_from_env() -> (u32, u32) {
    (
        surface_dimension_from_env("SHADOW_BLITZ_SURFACE_WIDTH", DEFAULT_SURFACE_WIDTH),
        surface_dimension_from_env("SHADOW_BLITZ_SURFACE_HEIGHT", DEFAULT_SURFACE_HEIGHT),
    )
}

fn surface_dimension_from_env(key: &str, default: u32) -> u32 {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
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
