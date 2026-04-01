mod renderer;
mod text;

use std::sync::Arc;

use renderer::Renderer;
use shadow_ui_core::{
    control::{self, ControlRequest},
    scene::{HEIGHT, WIDTH},
    shell::{NavAction, PointerButtonState, ShellAction, ShellEvent, ShellModel, ShellStatus},
};
use text::TextSystem;
use winit::{
    application::ApplicationHandler,
    dpi::LogicalSize,
    event::{ElementState, MouseButton, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    keyboard::PhysicalKey,
    window::{Window, WindowAttributes, WindowId},
};

#[cfg(target_os = "linux")]
use shadow_ui_core::app::{SHELL_APP_ID, SHELL_WAYLAND_APP_ID};
#[cfg(target_os = "linux")]
use winit::platform::wayland::WindowAttributesExtWayland;

struct AppState {
    renderer: Renderer,
    text_system: TextSystem,
    shell: ShellModel,
    window: Arc<Window>,
}

fn handle_shell_action(action: ShellAction) {
    let request = match action {
        ShellAction::Launch { app_id } => ControlRequest::Launch { app_id },
        ShellAction::Home => ControlRequest::Home,
    };

    if let Err(error) = control::request(request) {
        eprintln!("[shadow-ui-desktop] failed to send control request: {error}");
    }
}

#[derive(Default)]
struct App {
    state: Option<AppState>,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.state.is_some() {
            eprintln!("[shadow-ui-desktop] resumed with existing state");
            return;
        }

        eprintln!("[shadow-ui-desktop] resumed; creating window");

        let attributes = WindowAttributes::default()
            .with_title("Shadow")
            .with_resizable(false)
            .with_inner_size(LogicalSize::new(WIDTH as f64, HEIGHT as f64));
        #[cfg(target_os = "linux")]
        let attributes = attributes.with_name(SHELL_APP_ID.as_str(), SHELL_WAYLAND_APP_ID);
        let window = Arc::new(event_loop.create_window(attributes).expect("create window"));

        eprintln!("[shadow-ui-desktop] window created");

        let renderer = pollster::block_on(Renderer::new(window.clone()));
        eprintln!("[shadow-ui-desktop] renderer created");
        let text_system = TextSystem::new(
            renderer.device(),
            renderer.queue(),
            renderer.surface_format(),
        );
        eprintln!("[shadow-ui-desktop] text system created");

        self.state = Some(AppState {
            renderer,
            text_system,
            shell: ShellModel::new(),
            window: window.clone(),
        });

        window.request_redraw();
        eprintln!("[shadow-ui-desktop] initial redraw requested");
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        event: WindowEvent,
    ) {
        let Some(state) = &mut self.state else {
            return;
        };

        match event {
            WindowEvent::CloseRequested => {
                eprintln!("[shadow-ui-desktop] close requested");
                event_loop.exit();
            }
            WindowEvent::Resized(size) => {
                eprintln!(
                    "[shadow-ui-desktop] resized to {}x{}",
                    size.width, size.height
                );
                state.renderer.resize(size);
                state.window.request_redraw();
            }
            WindowEvent::ScaleFactorChanged { .. } => {
                eprintln!("[shadow-ui-desktop] scale factor changed");
                state.renderer.resize(state.window.inner_size());
                state.window.request_redraw();
            }
            WindowEvent::CursorMoved { position, .. } => {
                let logical = position.to_logical::<f32>(state.window.scale_factor());
                let _ = state.shell.handle(ShellEvent::PointerMoved {
                    x: logical.x,
                    y: logical.y,
                });
                state.window.request_redraw();
            }
            WindowEvent::CursorLeft { .. } => {
                let _ = state.shell.handle(ShellEvent::PointerLeft);
                state.window.request_redraw();
            }
            WindowEvent::MouseInput {
                button: MouseButton::Left,
                state: button_state,
                ..
            } => {
                let state_change = match button_state {
                    ElementState::Pressed => PointerButtonState::Pressed,
                    ElementState::Released => PointerButtonState::Released,
                };
                if let Some(action) = state.shell.handle(ShellEvent::PointerButton(state_change)) {
                    handle_shell_action(action);
                }
                state.window.request_redraw();
            }
            WindowEvent::KeyboardInput { event, .. } => {
                if event.state == ElementState::Pressed && !event.repeat {
                    if let PhysicalKey::Code(code) = event.physical_key {
                        let action = match code {
                            winit::keyboard::KeyCode::ArrowLeft => Some(NavAction::Left),
                            winit::keyboard::KeyCode::ArrowRight => Some(NavAction::Right),
                            winit::keyboard::KeyCode::ArrowUp => Some(NavAction::Up),
                            winit::keyboard::KeyCode::ArrowDown => Some(NavAction::Down),
                            winit::keyboard::KeyCode::Enter | winit::keyboard::KeyCode::Space => {
                                Some(NavAction::Activate)
                            }
                            winit::keyboard::KeyCode::Tab => Some(NavAction::Next),
                            winit::keyboard::KeyCode::Home => Some(NavAction::Home),
                            _ => None,
                        };
                        if let Some(action) = action {
                            if let Some(shell_action) =
                                state.shell.handle(ShellEvent::Navigate(action))
                            {
                                handle_shell_action(shell_action);
                            }
                            state.window.request_redraw();
                        }
                    }
                }
            }
            WindowEvent::RedrawRequested => {
                let scene = state.shell.scene(&ShellStatus::demo(chrono::Local::now()));
                match state.renderer.render(
                    &scene,
                    &mut state.text_system,
                    state.window.scale_factor() as f32,
                ) {
                    Ok(()) => {}
                    Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                        state.renderer.reconfigure();
                    }
                    Err(wgpu::SurfaceError::OutOfMemory) => event_loop.exit(),
                    Err(wgpu::SurfaceError::Timeout) => {}
                    Err(wgpu::SurfaceError::Other) => {}
                }
                state.window.request_redraw();
            }
            _ => {}
        }
    }

    fn suspended(&mut self, _event_loop: &ActiveEventLoop) {
        eprintln!("[shadow-ui-desktop] suspended");
    }

    fn exiting(&mut self, _event_loop: &ActiveEventLoop) {
        eprintln!("[shadow-ui-desktop] exiting");
    }
}

fn main() {
    eprintln!("[shadow-ui-desktop] starting");
    let event_loop = EventLoop::new().expect("create event loop");
    event_loop.set_control_flow(ControlFlow::Poll);

    let mut app = App::default();
    event_loop.run_app(&mut app).expect("run app");
    eprintln!("[shadow-ui-desktop] run_app returned");
}
