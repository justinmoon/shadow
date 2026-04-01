#![allow(dead_code)]

use crate::layout::{self, CounterTarget};

#[derive(Clone, Copy, Debug)]
pub enum CounterAction {
    Close,
}

#[derive(Clone, Copy, Debug)]
pub enum CounterButtonState {
    Pressed,
    Released,
}

#[derive(Default)]
pub struct CounterModel {
    count: u64,
    cursor: Option<(f32, f32)>,
    hovered: Option<CounterTarget>,
    pressed: Option<CounterTarget>,
}

impl CounterModel {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn count(&self) -> u64 {
        self.count
    }

    pub fn hovered_target(&self) -> Option<CounterTarget> {
        self.hovered
    }

    pub fn pressed_target(&self) -> Option<CounterTarget> {
        self.pressed
    }

    pub fn tap_pressed(&self) -> bool {
        self.pressed == Some(CounterTarget::Tap)
    }

    pub fn pointer_moved(&mut self, x: f32, y: f32, width: f32, height: f32) {
        self.cursor = Some((x, y));
        self.hovered = layout::hit_target(width, height, x, y);
    }

    pub fn pointer_left(&mut self) {
        self.cursor = None;
        self.hovered = None;
        self.pressed = None;
    }

    pub fn pointer_button(
        &mut self,
        state: CounterButtonState,
        width: f32,
        height: f32,
    ) -> Option<CounterAction> {
        match state {
            CounterButtonState::Pressed => {
                self.pressed = self
                    .cursor
                    .and_then(|(x, y)| layout::hit_target(width, height, x, y));
                None
            }
            CounterButtonState::Released => {
                let hovered = self
                    .cursor
                    .and_then(|(x, y)| layout::hit_target(width, height, x, y));
                let pressed = self.pressed.take();
                self.hovered = hovered;

                match (pressed, hovered) {
                    (Some(CounterTarget::Tap), Some(CounterTarget::Tap)) => {
                        self.count = self.count.saturating_add(1);
                        None
                    }
                    _ => None,
                }
            }
        }
    }

    pub fn activate_pressed(&mut self) {
        self.pressed = Some(CounterTarget::Tap);
    }

    pub fn activate_released(&mut self) {
        if self.pressed == Some(CounterTarget::Tap) {
            self.count = self.count.saturating_add(1);
        }
        self.pressed = None;
    }

    pub fn close_action(&mut self) -> CounterAction {
        self.cancel_press();
        CounterAction::Close
    }

    pub fn cancel_press(&mut self) {
        self.pressed = None;
    }
}
