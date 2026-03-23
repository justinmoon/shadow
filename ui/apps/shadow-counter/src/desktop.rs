use winit::{
    application::ApplicationHandler,
    dpi::LogicalSize,
    event::{ElementState, MouseButton, WindowEvent},
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    keyboard::PhysicalKey,
    window::{Window, WindowAttributes, WindowId},
};

use crate::model::CounterModel;

const WINDOW_WIDTH: f64 = 360.0;
const WINDOW_HEIGHT: f64 = 420.0;

pub fn run() {
    let event_loop = EventLoop::new().expect("create event loop");
    event_loop.set_control_flow(ControlFlow::Wait);

    let mut app = CounterDesktopApp {
        window: None,
        model: CounterModel::new(),
    };
    event_loop.run_app(&mut app).expect("run app");
}

struct CounterDesktopApp {
    window: Option<Window>,
    model: CounterModel,
}

impl CounterDesktopApp {
    fn refresh_title(&self) {
        if let Some(window) = &self.window {
            let suffix = if self.model.pressed() {
                " (pressed)"
            } else {
                ""
            };
            window.set_title(&format!("Shadow Counter: {}{}", self.model.count(), suffix));
        }
    }
}

impl ApplicationHandler for CounterDesktopApp {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }

        let attributes = WindowAttributes::default()
            .with_title("Shadow Counter")
            .with_resizable(false)
            .with_inner_size(LogicalSize::new(WINDOW_WIDTH, WINDOW_HEIGHT));
        let window = event_loop.create_window(attributes).expect("create window");

        self.window = Some(window);
        self.refresh_title();
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        event: WindowEvent,
    ) {
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::Focused(false) => {
                self.model.release();
                self.refresh_title();
            }
            WindowEvent::MouseInput {
                button: MouseButton::Left,
                state,
                ..
            } => {
                match state {
                    ElementState::Pressed => self.model.press(),
                    ElementState::Released => self.model.release(),
                }
                self.refresh_title();
            }
            WindowEvent::KeyboardInput { event, .. } => {
                if event.repeat {
                    return;
                }

                match (event.state, event.physical_key) {
                    (
                        ElementState::Pressed,
                        PhysicalKey::Code(winit::keyboard::KeyCode::Escape),
                    ) => event_loop.exit(),
                    (
                        ElementState::Pressed,
                        PhysicalKey::Code(
                            winit::keyboard::KeyCode::Enter | winit::keyboard::KeyCode::Space,
                        ),
                    ) => {
                        self.model.press();
                        self.refresh_title();
                    }
                    (
                        ElementState::Released,
                        PhysicalKey::Code(
                            winit::keyboard::KeyCode::Enter | winit::keyboard::KeyCode::Space,
                        ),
                    ) => {
                        self.model.release();
                        self.refresh_title();
                    }
                    _ => {}
                }
            }
            WindowEvent::RedrawRequested => {
                self.refresh_title();
            }
            _ => {}
        }
    }
}
