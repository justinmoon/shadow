use std::{error::Error, num::NonZeroU32};

use shadow_sdk::app::{AppWindowDefaults, AppWindowEnvironment};
use shadow_ui_core::scene::{APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX};
use softbuffer::{Context, Surface};
use winit::{
    application::ApplicationHandler,
    dpi::LogicalSize,
    event::WindowEvent,
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    window::{Window, WindowAttributes, WindowId},
};

#[cfg(target_os = "linux")]
use winit::platform::wayland::WindowAttributesWayland;

const DEFAULT_TITLE: &str = "Shadow Rust Demo";
const DEFAULT_WAYLAND_APP_ID: &str = "dev.shadow.rust-demo";
const DEFAULT_WAYLAND_INSTANCE_NAME: &str = "rust-demo";
const CLEAR_COLOR: u32 = 0x1B6E7A;
const WINDOW_DEFAULTS: AppWindowDefaults<'static> =
    AppWindowDefaults::new(DEFAULT_TITLE, APP_VIEWPORT_WIDTH_PX, APP_VIEWPORT_HEIGHT_PX)
        .with_wayland_app_id(DEFAULT_WAYLAND_APP_ID)
        .with_wayland_instance_name(DEFAULT_WAYLAND_INSTANCE_NAME);

struct WindowState {
    window: &'static dyn Window,
    _context: Context<&'static dyn Window>,
    surface: Surface<&'static dyn Window, &'static dyn Window>,
}

#[derive(Default)]
struct App {
    window: Option<WindowState>,
}

impl ApplicationHandler for App {
    fn can_create_surfaces(&mut self, event_loop: &dyn ActiveEventLoop) {
        let window = match event_loop.create_window(window_attributes()) {
            Ok(window) => window,
            Err(error) => {
                eprintln!("shadow-rust-demo: failed to create window: {error}");
                event_loop.exit();
                return;
            }
        };
        // The demo owns exactly one process-lifetime window, so leaking it avoids a self-referential
        // softbuffer setup while keeping the app logic small.
        let window: &'static dyn Window = Box::leak(window);
        let context = match Context::new(window) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("shadow-rust-demo: failed to create softbuffer context: {error}");
                event_loop.exit();
                return;
            }
        };
        let mut surface = match Surface::new(&context, window) {
            Ok(surface) => surface,
            Err(error) => {
                eprintln!("shadow-rust-demo: failed to create softbuffer surface: {error}");
                event_loop.exit();
                return;
            }
        };
        if let Err(error) = resize_surface(&mut surface, window.surface_size()) {
            eprintln!("shadow-rust-demo: failed to size softbuffer surface: {error}");
            event_loop.exit();
            return;
        }
        window.request_redraw();
        self.window = Some(WindowState {
            window,
            _context: context,
            surface,
        });
    }

    fn window_event(
        &mut self,
        event_loop: &dyn ActiveEventLoop,
        window_id: WindowId,
        event: WindowEvent,
    ) {
        let Some(state) = self.window.as_mut() else {
            return;
        };
        if state.window.id() != window_id {
            return;
        }

        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::SurfaceResized(size) => {
                if let Err(error) = resize_surface(&mut state.surface, size) {
                    eprintln!("shadow-rust-demo: failed to resize surface: {error}");
                    event_loop.exit();
                    return;
                }
                state.window.request_redraw();
            }
            WindowEvent::RedrawRequested => {
                state.window.pre_present_notify();
                if let Err(error) = fill_surface(&mut state.surface) {
                    eprintln!("shadow-rust-demo: failed to draw frame: {error}");
                    event_loop.exit();
                }
            }
            _ => {}
        }
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    let event_loop = EventLoop::new()?;
    event_loop.set_control_flow(ControlFlow::Wait);
    event_loop.run_app(App::default())?;
    Ok(())
}

fn window_attributes() -> WindowAttributes {
    let window_env = window_environment();
    let attributes = WindowAttributes::default()
        .with_title(window_env.title)
        .with_resizable(false)
        .with_decorations(!window_env.undecorated)
        .with_surface_size(LogicalSize::new(
            f64::from(window_env.surface_width),
            f64::from(window_env.surface_height),
        ));

    #[cfg(target_os = "linux")]
    {
        let wayland_attributes = WindowAttributesWayland::default().with_name(
            window_env
                .wayland_app_id
                .expect("shadow-rust-demo defaults require a Wayland app id"),
            window_env
                .wayland_instance_name
                .expect("shadow-rust-demo defaults require a Wayland instance name"),
        );
        return attributes.with_platform_attributes(Box::new(wayland_attributes));
    }

    #[allow(unreachable_code)]
    attributes
}

fn window_environment() -> AppWindowEnvironment {
    AppWindowEnvironment::from_env(WINDOW_DEFAULTS)
}

fn resize_surface(
    surface: &mut Surface<&'static dyn Window, &'static dyn Window>,
    size: winit::dpi::PhysicalSize<u32>,
) -> Result<(), Box<dyn Error>> {
    let width = NonZeroU32::new(size.width.max(1)).expect("width should be non-zero");
    let height = NonZeroU32::new(size.height.max(1)).expect("height should be non-zero");
    surface.resize(width, height)?;
    Ok(())
}

fn fill_surface(
    surface: &mut Surface<&'static dyn Window, &'static dyn Window>,
) -> Result<(), Box<dyn Error>> {
    let mut buffer = surface.buffer_mut()?;
    buffer.fill(CLEAR_COLOR);
    buffer.present()?;
    Ok(())
}
