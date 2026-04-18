use std::{env, error::Error, num::NonZeroU32};

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
#[cfg(target_os = "linux")]
const DEFAULT_WAYLAND_APP_ID: &str = "dev.shadow.rust-demo";
#[cfg(target_os = "linux")]
const DEFAULT_WAYLAND_INSTANCE_NAME: &str = "rust-demo";
const CLEAR_COLOR: u32 = 0x1B6E7A;
const APP_TITLE_ENV: &str = "SHADOW_BLITZ_APP_TITLE";
const SURFACE_HEIGHT_ENV: &str = "SHADOW_BLITZ_SURFACE_HEIGHT";
const SURFACE_WIDTH_ENV: &str = "SHADOW_BLITZ_SURFACE_WIDTH";
const UNDECORATED_ENV: &str = "SHADOW_BLITZ_UNDECORATED";
#[cfg(target_os = "linux")]
const WAYLAND_APP_ID_ENV: &str = "SHADOW_BLITZ_WAYLAND_APP_ID";
#[cfg(target_os = "linux")]
const WAYLAND_INSTANCE_NAME_ENV: &str = "SHADOW_BLITZ_WAYLAND_INSTANCE_NAME";

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
    let (surface_width, surface_height) = runtime_surface_size_from_env();
    let attributes = WindowAttributes::default()
        .with_title(resolved_title())
        .with_resizable(false)
        .with_decorations(!env_flag(UNDECORATED_ENV))
        .with_surface_size(LogicalSize::new(
            f64::from(surface_width),
            f64::from(surface_height),
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

fn resolved_title() -> String {
    env_override(APP_TITLE_ENV).unwrap_or_else(|| String::from(DEFAULT_TITLE))
}

#[cfg(target_os = "linux")]
fn resolved_wayland_app_id() -> String {
    env_override(WAYLAND_APP_ID_ENV).unwrap_or_else(|| String::from(DEFAULT_WAYLAND_APP_ID))
}

#[cfg(target_os = "linux")]
fn resolved_wayland_instance_name() -> String {
    env_override(WAYLAND_INSTANCE_NAME_ENV)
        .or_else(|| {
            env_override(WAYLAND_APP_ID_ENV).map(|app_id| {
                app_id
                    .rsplit_once('.')
                    .map(|(_, suffix)| String::from(suffix))
                    .unwrap_or(app_id)
            })
        })
        .unwrap_or_else(|| String::from(DEFAULT_WAYLAND_INSTANCE_NAME))
}

fn env_override(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn env_flag(key: &str) -> bool {
    env::var_os(key).is_some()
}

fn runtime_surface_size_from_env() -> (u32, u32) {
    (
        runtime_surface_dimension(SURFACE_WIDTH_ENV, APP_VIEWPORT_WIDTH_PX),
        runtime_surface_dimension(SURFACE_HEIGHT_ENV, APP_VIEWPORT_HEIGHT_PX),
    )
}

fn runtime_surface_dimension(key: &str, default: u32) -> u32 {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
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
