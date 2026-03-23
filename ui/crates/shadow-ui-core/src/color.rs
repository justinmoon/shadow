#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Color {
    rgba: [u8; 4],
}

impl Color {
    pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Self {
        Self { rgba: [r, g, b, a] }
    }

    pub fn with_alpha(self, alpha: f32) -> Self {
        let alpha = alpha.clamp(0.0, 1.0);
        Self::rgba(
            self.rgba[0],
            self.rgba[1],
            self.rgba[2],
            (alpha * 255.0).round() as u8,
        )
    }

    pub fn linear_rgba(self) -> [f32; 4] {
        [
            srgb_to_linear(self.rgba[0]),
            srgb_to_linear(self.rgba[1]),
            srgb_to_linear(self.rgba[2]),
            self.rgba[3] as f32 / 255.0,
        ]
    }

    pub fn rgba8(self) -> [u8; 4] {
        self.rgba
    }
}

fn srgb_to_linear(channel: u8) -> f32 {
    let srgb = channel as f32 / 255.0;
    if srgb <= 0.04045 {
        srgb / 12.92
    } else {
        ((srgb + 0.055) / 1.055).powf(2.4)
    }
}

pub const BACKGROUND: Color = Color::rgba(0x1a, 0x1a, 0x1a, 0xff);
pub const SURFACE: Color = Color::rgba(0x22, 0x22, 0x24, 0xff);
pub const SURFACE_RAISED: Color = Color::rgba(0x2b, 0x2b, 0x2f, 0xff);
pub const SURFACE_GLASS: Color = Color::rgba(0x16, 0x16, 0x18, 0xd8);
pub const SURFACE_ACCENT: Color = Color::rgba(0x30, 0x30, 0x34, 0xff);
pub const TEXT_PRIMARY: Color = Color::rgba(0xf5, 0xf5, 0xf7, 0xff);
pub const TEXT_MUTED: Color = Color::rgba(0xa6, 0xa6, 0xad, 0xff);
pub const ICON_BLUE: Color = Color::rgba(0x68, 0x91, 0xff, 0xff);
pub const ICON_GREEN: Color = Color::rgba(0x4b, 0xd6, 0x8d, 0xff);
pub const ICON_ORANGE: Color = Color::rgba(0xff, 0xa3, 0x45, 0xff);
pub const ICON_RED: Color = Color::rgba(0xff, 0x6a, 0x6a, 0xff);
pub const ICON_PINK: Color = Color::rgba(0xff, 0x7f, 0xc8, 0xff);
pub const ICON_CYAN: Color = Color::rgba(0x5c, 0xd8, 0xf5, 0xff);
pub const ICON_YELLOW: Color = Color::rgba(0xff, 0xd8, 0x66, 0xff);
pub const ICON_PURPLE: Color = Color::rgba(0xbb, 0x8f, 0xff, 0xff);
