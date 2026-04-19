use xilem::Color;

#[derive(Clone, Copy, Debug)]
pub struct Theme {
    pub background: Color,
    pub surface: Color,
    pub surface_raised: Color,
    pub border: Color,
    pub text_primary: Color,
    pub text_muted: Color,
    pub accent: Color,
    pub accent_soft: Color,
    pub success: Color,
    pub danger: Color,
}

impl Theme {
    pub fn shadow_dark() -> Self {
        Self {
            background: Color::from_rgb8(0x12, 0x13, 0x15),
            surface: Color::from_rgb8(0x1b, 0x1d, 0x21),
            surface_raised: Color::from_rgb8(0x24, 0x27, 0x2d),
            border: Color::from_rgb8(0x33, 0x37, 0x3d),
            text_primary: Color::from_rgb8(0xf3, 0xf5, 0xf7),
            text_muted: Color::from_rgb8(0xa2, 0xaa, 0xb3),
            accent: Color::from_rgb8(0x5f, 0xc7, 0xbe),
            accent_soft: Color::from_rgb8(0x2e, 0x6a, 0x65),
            success: Color::from_rgb8(0x6d, 0xd0, 0x8f),
            danger: Color::from_rgb8(0xff, 0x87, 0x6a),
        }
    }
}
