#![allow(dead_code)]

use shadow_ui_core::scene::{APP_VIEWPORT_HEIGHT, APP_VIEWPORT_WIDTH};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CounterTarget {
    Tap,
}

#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Frame {
    pub fn contains(self, x: f32, y: f32) -> bool {
        x >= self.x && x <= self.x + self.w && y >= self.y && y <= self.y + self.h
    }
}

pub const WINDOW_WIDTH: u32 = APP_VIEWPORT_WIDTH as u32;
pub const WINDOW_HEIGHT: u32 = APP_VIEWPORT_HEIGHT as u32;

pub fn hero_card_frame(width: f32) -> Frame {
    Frame {
        x: 24.0,
        y: 24.0,
        w: width - 48.0,
        h: 210.0,
    }
}

pub fn count_card_frame(width: f32, height: f32) -> Frame {
    Frame {
        x: 24.0,
        y: 254.0,
        w: width - 48.0,
        h: (height - 420.0).max(240.0),
    }
}

pub fn accent_card_frame(width: f32) -> Frame {
    Frame {
        x: 52.0,
        y: 300.0,
        w: width - 104.0,
        h: 228.0,
    }
}

pub fn tap_button_frame(width: f32, height: f32) -> Frame {
    let button_width = (width - 136.0).clamp(260.0, 364.0);
    Frame {
        x: (width - button_width) * 0.5,
        y: height - 112.0,
        w: button_width,
        h: 72.0,
    }
}

pub fn hit_target(width: f32, height: f32, x: f32, y: f32) -> Option<CounterTarget> {
    tap_button_frame(width, height)
        .contains(x, y)
        .then_some(CounterTarget::Tap)
}
