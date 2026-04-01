use crate::color::Color;

pub const WIDTH: f32 = 540.0;
pub const HEIGHT: f32 = 1170.0;
pub const APP_VIEWPORT_X: f32 = 24.0;
pub const APP_VIEWPORT_Y: f32 = 156.0;
pub const APP_VIEWPORT_WIDTH: f32 = WIDTH - APP_VIEWPORT_X * 2.0;
pub const APP_VIEWPORT_HEIGHT: f32 = HEIGHT - APP_VIEWPORT_Y - 104.0;

#[derive(Clone, Copy, Debug)]
pub struct RoundedRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub radius: f32,
    pub color: Color,
}

impl RoundedRect {
    pub fn new(x: f32, y: f32, width: f32, height: f32, radius: f32, color: Color) -> Self {
        Self {
            x,
            y,
            width,
            height,
            radius,
            color,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum TextAlign {
    Left,
    Center,
}

#[derive(Clone, Copy, Debug)]
pub enum TextWeight {
    Normal,
    Semibold,
    Bold,
}

#[derive(Clone, Debug)]
pub struct TextBlock {
    pub content: String,
    pub left: f32,
    pub top: f32,
    pub width: f32,
    pub height: f32,
    pub size: f32,
    pub line_height: f32,
    pub align: TextAlign,
    pub weight: TextWeight,
    pub color: Color,
}

#[derive(Clone, Debug)]
pub struct Scene {
    pub clear_color: Color,
    pub rects: Vec<RoundedRect>,
    pub texts: Vec<TextBlock>,
}
