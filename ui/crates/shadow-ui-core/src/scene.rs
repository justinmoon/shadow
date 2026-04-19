use crate::color::Color;

pub const SHELL_WIDTH_PX: u32 = 540;
pub const SHELL_HEIGHT_PX: u32 = 1170;
pub const APP_VIEWPORT_X_PX: u32 = 0;
pub const APP_VIEWPORT_Y_PX: u32 = 64;
pub const APP_VIEWPORT_BOTTOM_INSET_PX: u32 = 64;
pub const APP_VIEWPORT_WIDTH_PX: u32 = SHELL_WIDTH_PX;
pub const APP_VIEWPORT_HEIGHT_PX: u32 =
    SHELL_HEIGHT_PX - APP_VIEWPORT_Y_PX - APP_VIEWPORT_BOTTOM_INSET_PX;
pub const APP_VIEWPORT_BOTTOM_PX: u32 = APP_VIEWPORT_Y_PX + APP_VIEWPORT_HEIGHT_PX;

pub const WIDTH: f32 = SHELL_WIDTH_PX as f32;
pub const HEIGHT: f32 = SHELL_HEIGHT_PX as f32;
pub const APP_VIEWPORT_X: f32 = APP_VIEWPORT_X_PX as f32;
pub const APP_VIEWPORT_Y: f32 = APP_VIEWPORT_Y_PX as f32;
pub const APP_VIEWPORT_WIDTH: f32 = APP_VIEWPORT_WIDTH_PX as f32;
pub const APP_VIEWPORT_HEIGHT: f32 = APP_VIEWPORT_HEIGHT_PX as f32;

pub fn fitted_app_viewport_size(max_width: u32, max_height: u32) -> Option<(u32, u32)> {
    if max_width == 0 || max_height == 0 {
        return None;
    }

    let viewport_width = u64::from(APP_VIEWPORT_WIDTH_PX);
    let viewport_height = u64::from(APP_VIEWPORT_HEIGHT_PX);
    let max_width = u64::from(max_width);
    let max_height = u64::from(max_height);

    let (fit_width, fit_height) = if max_width * viewport_height <= max_height * viewport_width {
        let fit_height = (max_width * viewport_height) / viewport_width;
        (max_width, fit_height)
    } else {
        let fit_width = (max_height * viewport_width) / viewport_height;
        (fit_width, max_height)
    };

    let fit_width = u32::try_from(fit_width).ok()?;
    let fit_height = u32::try_from(fit_height).ok()?;
    if fit_width == 0 || fit_height == 0 {
        return None;
    }

    Some((fit_width, fit_height))
}

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

#[cfg(test)]
mod tests {
    use super::{
        fitted_app_viewport_size, APP_VIEWPORT_BOTTOM_INSET_PX, APP_VIEWPORT_HEIGHT_PX,
        APP_VIEWPORT_WIDTH_PX, SHELL_HEIGHT_PX, SHELL_WIDTH_PX,
    };

    #[test]
    fn pixel_contract_matches_shell_geometry() {
        assert_eq!(SHELL_WIDTH_PX, 540);
        assert_eq!(SHELL_HEIGHT_PX, 1170);
        assert_eq!(APP_VIEWPORT_WIDTH_PX, 540);
        assert_eq!(APP_VIEWPORT_HEIGHT_PX, 1042);
        assert_eq!(APP_VIEWPORT_BOTTOM_INSET_PX, 64);
    }

    #[test]
    fn fitted_viewport_uses_full_width_on_pixel_4a_panel() {
        assert_eq!(fitted_app_viewport_size(1080, 2340), Some((1080, 2084)));
    }

    #[test]
    fn fitted_viewport_uses_full_height_when_target_is_wider() {
        assert_eq!(fitted_app_viewport_size(384, 720), Some((373, 720)));
    }
}
