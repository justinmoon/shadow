mod renderer;
mod text;

use std::sync::Arc;

use renderer::Renderer;
use shadow_ui_core::{
    scene::{HEIGHT, WIDTH},
    shell::{NavAction, PointerButtonState, ShellModel},
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

struct AppState {
    renderer: Renderer,
    text_system: TextSystem,
    shell: ShellModel,
    window: Arc<Window>,
}

#[derive(Default)]
struct App {
    state: Option<AppState>,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.state.is_some() {
            return;
        }

        let attributes = WindowAttributes::default()
            .with_title("Shadow")
            .with_resizable(false)
            .with_inner_size(LogicalSize::new(WIDTH as f64, HEIGHT as f64));
        let window = Arc::new(event_loop.create_window(attributes).expect("create window"));

        let renderer = pollster::block_on(Renderer::new(window.clone()));
        let text_system = TextSystem::new(
            renderer.device(),
            renderer.queue(),
            renderer.surface_format(),
        );

        self.state = Some(AppState {
            renderer,
            text_system,
            shell: ShellModel::new(),
            window: window.clone(),
        });

        window.request_redraw();
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
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::Resized(size) => {
                state.renderer.resize(size);
                state.window.request_redraw();
            }
            WindowEvent::ScaleFactorChanged { .. } => {
                state.renderer.resize(state.window.inner_size());
                state.window.request_redraw();
            }
            WindowEvent::CursorMoved { position, .. } => {
                let logical = position.to_logical::<f32>(state.window.scale_factor());
                state.shell.pointer_moved(logical.x, logical.y);
                state.window.request_redraw();
            }
            WindowEvent::CursorLeft { .. } => {
                state.shell.pointer_left();
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
                state.shell.pointer_button(state_change);
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
                            _ => None,
                        };
                        if let Some(action) = action {
                            state.shell.navigate(action);
                            state.window.request_redraw();
                        }
                    }
                }
            }
            WindowEvent::RedrawRequested => {
                let scene = state.shell.scene(chrono::Local::now());
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
}

fn main() {
    let event_loop = EventLoop::new().expect("create event loop");
    event_loop.set_control_flow(ControlFlow::Poll);

    let mut app = App::default();
    event_loop.run_app(&mut app).expect("run app");
}
