use anyrender_vello_cpu::VelloCpuWindowRenderer;
use blitz_shell::{
    create_default_event_loop, BlitzShellEvent, BlitzShellProxy, View, WindowConfig,
};
use std::env;
use std::sync::mpsc::Receiver;
use winit::{
    application::ApplicationHandler,
    dpi::LogicalSize,
    event::WindowEvent,
    event_loop::ActiveEventLoop,
    window::{WindowAttributes, WindowId},
};

use crate::document::StaticDocument;
use crate::runtime_document::RuntimeDocument;

#[cfg(target_os = "linux")]
use winit::platform::wayland::WindowAttributesWayland;

#[cfg(target_os = "linux")]
const BLITZ_DEMO_WAYLAND_APP_ID: &str = "dev.shadow.blitz";
#[cfg(target_os = "linux")]
const RUNTIME_DEMO_WAYLAND_APP_ID: &str = "dev.shadow.runtime";

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
            Self::Runtime => Box::new(RuntimeDocument::new(RuntimeDocument::sample_payload())),
        }
    }

    fn title(self) -> &'static str {
        match self {
            Self::Static => "Shadow Blitz Demo",
            Self::Runtime => "Shadow Runtime Demo",
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
            Self::Runtime => "shadow-runtime-demo",
        }
    }
}

struct BlitzApplication {
    demo_mode: DemoMode,
    proxy: BlitzShellProxy,
    event_queue: Receiver<BlitzShellEvent>,
    pending_window: Option<WindowConfig<VelloCpuWindowRenderer>>,
    window: Option<View<VelloCpuWindowRenderer>>,
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
                let _ = window.poll();
            }
            BlitzShellEvent::RequestRedraw { doc_id } if window.doc.id() == doc_id => {
                window.request_redraw();
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
        if let Some(window) = self.window.as_mut() {
            window.resume();
            let _ = window.poll();
        }

        if let Some(config) = self.pending_window.take() {
            let mut window = View::init(config, event_loop, &self.proxy);
            window.resume();
            let _ = window.poll();
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
        if matches!(event, WindowEvent::CloseRequested) {
            self.window.take();
            event_loop.exit();
            return;
        }

        if let Some(window) = self.window.as_mut() {
            window.handle_winit_event(event);
        }

        self.proxy.send_event(BlitzShellEvent::Poll { window_id });
    }

    fn proxy_wake_up(&mut self, event_loop: &dyn ActiveEventLoop) {
        while let Ok(event) = self.event_queue.try_recv() {
            self.handle_blitz_shell_event(event_loop, event);
        }
    }
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
