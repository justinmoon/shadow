use shadow_ui_core::shell::{NavAction, PointerButtonState, ShellAction, ShellEvent};
use smithay::{
    backend::input::{
        AbsolutePositionEvent, Axis, AxisSource, ButtonState, Event, InputBackend, InputEvent,
        KeyState, KeyboardKeyEvent, PointerAxisEvent, PointerButtonEvent,
    },
    input::{
        keyboard::{keysyms, FilterResult},
        pointer::{AxisFrame, ButtonEvent, MotionEvent},
    },
    utils::SERIAL_COUNTER,
};

use crate::state::ShadowCompositor;

#[derive(Clone, Copy, Debug)]
enum KeyboardIntent {
    None,
    Shell(NavAction),
    Home,
}

impl ShadowCompositor {
    pub fn process_input_event<I: InputBackend>(&mut self, event: InputEvent<I>) {
        match event {
            InputEvent::Keyboard { event, .. } => {
                let serial = SERIAL_COUNTER.next_serial();
                let time = Event::time_msec(&event);
                let allow_shell_nav = self.shell.foreground_app().is_none();
                let has_foreground_app = self.shell.foreground_app().is_some();
                let keyboard = self.seat.get_keyboard().unwrap();

                let intent = keyboard
                    .input(
                        self,
                        event.key_code(),
                        event.state(),
                        serial,
                        time,
                        |_, _, handle| {
                            let keysym = handle.modified_sym().raw();

                            match event.state() {
                                KeyState::Pressed => {
                                    if matches!(keysym, keysyms::KEY_Home | keysyms::KEY_Escape)
                                        && has_foreground_app
                                    {
                                        return FilterResult::Intercept(KeyboardIntent::Home);
                                    }

                                    if allow_shell_nav {
                                        let navigation = match keysym {
                                            keysyms::KEY_Left => Some(NavAction::Left),
                                            keysyms::KEY_Right => Some(NavAction::Right),
                                            keysyms::KEY_Up => Some(NavAction::Up),
                                            keysyms::KEY_Down => Some(NavAction::Down),
                                            keysyms::KEY_Return
                                            | keysyms::KEY_KP_Enter
                                            | keysyms::KEY_space => Some(NavAction::Activate),
                                            keysyms::KEY_Tab => Some(NavAction::Next),
                                            keysyms::KEY_ISO_Left_Tab => Some(NavAction::Previous),
                                            keysyms::KEY_Home => Some(NavAction::Home),
                                            _ => None,
                                        };

                                        if let Some(action) = navigation {
                                            return FilterResult::Intercept(KeyboardIntent::Shell(
                                                action,
                                            ));
                                        }
                                    }

                                    FilterResult::Forward
                                }
                                KeyState::Released => {
                                    if matches!(
                                        keysym,
                                        keysyms::KEY_Left
                                            | keysyms::KEY_Right
                                            | keysyms::KEY_Up
                                            | keysyms::KEY_Down
                                            | keysyms::KEY_Return
                                            | keysyms::KEY_KP_Enter
                                            | keysyms::KEY_space
                                            | keysyms::KEY_Tab
                                            | keysyms::KEY_ISO_Left_Tab
                                            | keysyms::KEY_Escape
                                            | keysyms::KEY_Home
                                    ) {
                                        FilterResult::Intercept(KeyboardIntent::None)
                                    } else {
                                        FilterResult::Forward
                                    }
                                }
                            }
                        },
                    )
                    .unwrap_or(KeyboardIntent::None);

                match intent {
                    KeyboardIntent::None => {}
                    KeyboardIntent::Shell(action) => {
                        self.handle_shell_event(ShellEvent::Navigate(action));
                    }
                    KeyboardIntent::Home => {
                        self.handle_shell_action(ShellAction::Home);
                    }
                }
            }
            InputEvent::PointerMotionAbsolute { event, .. } => {
                let output = self.space.outputs().next().expect("output");
                let output_geometry = self.space.output_geometry(output).expect("output geometry");
                let position =
                    event.position_transformed(output_geometry.size) + output_geometry.loc.to_f64();
                let serial = SERIAL_COUNTER.next_serial();
                let under = self.surface_under(position);
                let shell_point = self.shell_local_point(position);
                let shell_captures = shell_point
                    .map(|(x, y)| self.shell.captures_point(x, y))
                    .unwrap_or(false);
                let pointer = self.seat.get_pointer().unwrap();

                pointer.motion(
                    self,
                    under.clone(),
                    &MotionEvent {
                        location: position,
                        serial,
                        time: event.time_msec(),
                    },
                );
                pointer.frame(self);

                match (shell_captures, shell_point, under) {
                    (true, Some((x, y)), _) => {
                        self.handle_shell_event(ShellEvent::PointerMoved { x, y })
                    }
                    (_, _, Some(_)) => self.handle_shell_event(ShellEvent::PointerLeft),
                    _ => self.handle_shell_event(ShellEvent::PointerLeft),
                }
            }
            InputEvent::PointerButton { event, .. } => {
                let serial = SERIAL_COUNTER.next_serial();
                let pointer = self.seat.get_pointer().unwrap();
                let shell_point = self.shell_local_point(pointer.current_location());
                let shell_captures = shell_point
                    .map(|(x, y)| self.shell.captures_point(x, y))
                    .unwrap_or(false);
                let under = self
                    .space
                    .element_under(pointer.current_location())
                    .map(|(window, location)| (window.clone(), location));

                if shell_captures {
                    self.handle_shell_event(ShellEvent::PointerButton(match event.state() {
                        ButtonState::Pressed => PointerButtonState::Pressed,
                        ButtonState::Released => PointerButtonState::Released,
                    }));
                    return;
                }

                if event.state() == ButtonState::Pressed && !pointer.is_grabbed() {
                    if let Some((window, _)) = under.clone() {
                        self.focus_window(Some(window), serial);
                    } else if self.shell.foreground_app().is_none() {
                        self.focus_window(None, serial);
                    }
                }

                pointer.button(
                    self,
                    &ButtonEvent {
                        button: event.button_code(),
                        state: event.state(),
                        serial,
                        time: event.time_msec(),
                    },
                );
                pointer.frame(self);
            }
            InputEvent::PointerAxis { event, .. } => {
                let pointer = self.seat.get_pointer().unwrap();
                if self
                    .space
                    .element_under(pointer.current_location())
                    .is_none()
                {
                    return;
                }

                let horizontal = event.amount(Axis::Horizontal).unwrap_or_else(|| {
                    event.amount_v120(Axis::Horizontal).unwrap_or(0.0) * 15.0 / 120.0
                });
                let vertical = event.amount(Axis::Vertical).unwrap_or_else(|| {
                    event.amount_v120(Axis::Vertical).unwrap_or(0.0) * 15.0 / 120.0
                });
                let mut frame = AxisFrame::new(event.time_msec()).source(event.source());

                if horizontal != 0.0 {
                    frame = frame.value(Axis::Horizontal, horizontal);
                    if let Some(discrete) = event.amount_v120(Axis::Horizontal) {
                        frame = frame.v120(Axis::Horizontal, discrete as i32);
                    }
                }

                if vertical != 0.0 {
                    frame = frame.value(Axis::Vertical, vertical);
                    if let Some(discrete) = event.amount_v120(Axis::Vertical) {
                        frame = frame.v120(Axis::Vertical, discrete as i32);
                    }
                }

                if event.source() == AxisSource::Finger {
                    if event.amount(Axis::Horizontal) == Some(0.0) {
                        frame = frame.stop(Axis::Horizontal);
                    }
                    if event.amount(Axis::Vertical) == Some(0.0) {
                        frame = frame.stop(Axis::Vertical);
                    }
                }

                pointer.axis(self, frame);
                pointer.frame(self);
            }
            _ => {}
        }
    }
}
