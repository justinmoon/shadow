use font8x8::{UnicodeFonts, BASIC_FONTS};
use shadow_ui_core::{
    color::Color,
    scene::{RoundedRect, Scene, TextAlign, TextBlock, TextWeight},
};

pub struct SoftwareRenderer {
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

impl SoftwareRenderer {
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            pixels: vec![0; (width * height * 4) as usize],
        }
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        if self.width == width && self.height == height {
            return;
        }

        self.width = width;
        self.height = height;
        self.pixels.resize((width * height * 4) as usize, 0);
    }

    pub fn render(&mut self, scene: &Scene) -> &[u8] {
        clear(&mut self.pixels, scene.clear_color);

        for rect in &scene.rects {
            draw_rounded_rect(&mut self.pixels, self.width, self.height, rect);
        }

        for text in &scene.texts {
            draw_text_block(&mut self.pixels, self.width, self.height, text);
        }

        &self.pixels
    }
}

fn clear(pixels: &mut [u8], color: Color) {
    let [r, g, b, a] = color.rgba8();
    for chunk in pixels.chunks_exact_mut(4) {
        chunk.copy_from_slice(&[b, g, r, a]);
    }
}

fn draw_rounded_rect(pixels: &mut [u8], width: u32, height: u32, rect: &RoundedRect) {
    let left = rect.x.floor().max(0.0) as i32;
    let top = rect.y.floor().max(0.0) as i32;
    let right = (rect.x + rect.width).ceil().min(width as f32) as i32;
    let bottom = (rect.y + rect.height).ceil().min(height as f32) as i32;
    let radius = rect
        .radius
        .max(0.0)
        .min(rect.width * 0.5)
        .min(rect.height * 0.5);

    for y in top..bottom {
        for x in left..right {
            let coverage = rounded_rect_coverage(x as f32 + 0.5, y as f32 + 0.5, rect, radius);
            if coverage <= 0.0 {
                continue;
            }

            blend_rgba(
                pixels,
                width,
                height,
                x,
                y,
                rect.color
                    .with_alpha(coverage * rect.color.rgba8()[3] as f32 / 255.0),
            );
        }
    }
}

fn rounded_rect_coverage(px: f32, py: f32, rect: &RoundedRect, radius: f32) -> f32 {
    if radius <= 0.0 {
        return 1.0;
    }

    let inner_left = rect.x + radius;
    let inner_right = rect.x + rect.width - radius;
    let inner_top = rect.y + radius;
    let inner_bottom = rect.y + rect.height - radius;

    if (inner_left..=inner_right).contains(&px) || (inner_top..=inner_bottom).contains(&py) {
        return 1.0;
    }

    let cx = px.clamp(inner_left, inner_right);
    let cy = py.clamp(inner_top, inner_bottom);
    let dx = px - cx;
    let dy = py - cy;
    let distance = (dx * dx + dy * dy).sqrt();

    (radius + 0.75 - distance).clamp(0.0, 1.0)
}

fn draw_text_block(pixels: &mut [u8], width: u32, height: u32, block: &TextBlock) {
    let scale = (block.size / 8.0).max(1.0);
    let line_advance = block.line_height.max(scale * 8.0);
    let lines = wrap_text(&block.content, block.width, scale);

    for (index, line) in lines.iter().enumerate() {
        let line_width = measure_text_width(line, scale);
        let origin_x = match block.align {
            TextAlign::Left => block.left,
            TextAlign::Center => block.left + (block.width - line_width) * 0.5,
        };
        let origin_y = block.top + index as f32 * line_advance;
        draw_text_line(
            pixels,
            width,
            height,
            line,
            origin_x,
            origin_y,
            scale,
            block.color,
            block.weight,
            block.left,
            block.top,
            block.width,
            block.height,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn draw_text_line(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    text: &str,
    x: f32,
    y: f32,
    scale: f32,
    color: Color,
    weight: TextWeight,
    clip_left: f32,
    clip_top: f32,
    clip_width: f32,
    clip_height: f32,
) {
    let mut cursor_x = x;
    let clip_right = clip_left + clip_width;
    let clip_bottom = clip_top + clip_height;

    for character in text.chars() {
        if let Some(glyph) = BASIC_FONTS.get(character) {
            draw_glyph(
                pixels,
                width,
                height,
                &glyph,
                cursor_x,
                y,
                scale,
                color,
                clip_left,
                clip_top,
                clip_right,
                clip_bottom,
            );
            if matches!(weight, TextWeight::Semibold | TextWeight::Bold) {
                draw_glyph(
                    pixels,
                    width,
                    height,
                    &glyph,
                    cursor_x + scale * 0.35,
                    y,
                    scale,
                    color,
                    clip_left,
                    clip_top,
                    clip_right,
                    clip_bottom,
                );
            }
        }
        cursor_x += glyph_advance(scale);
    }
}

#[allow(clippy::too_many_arguments)]
fn draw_glyph(
    pixels: &mut [u8],
    width: u32,
    height: u32,
    glyph: &[u8; 8],
    x: f32,
    y: f32,
    scale: f32,
    color: Color,
    clip_left: f32,
    clip_top: f32,
    clip_right: f32,
    clip_bottom: f32,
) {
    for (row, bits) in glyph.iter().enumerate() {
        for col in 0..8 {
            if bits & (1 << col) == 0 {
                continue;
            }

            let cell_x = x + col as f32 * scale;
            let cell_y = y + row as f32 * scale;
            let left = cell_x.max(clip_left).floor() as i32;
            let top = cell_y.max(clip_top).floor() as i32;
            let right = (cell_x + scale).min(clip_right).ceil() as i32;
            let bottom = (cell_y + scale).min(clip_bottom).ceil() as i32;

            for py in top..bottom {
                for px in left..right {
                    blend_rgba(pixels, width, height, px, py, color);
                }
            }
        }
    }
}

fn measure_text_width(text: &str, scale: f32) -> f32 {
    text.chars().count() as f32 * glyph_advance(scale)
}

fn wrap_text(text: &str, max_width: f32, scale: f32) -> Vec<String> {
    let max_chars = ((max_width / glyph_advance(scale)).floor() as usize).max(1);
    let mut lines = Vec::new();

    for paragraph in text.lines() {
        let mut current = String::new();

        for word in paragraph.split_whitespace() {
            let candidate_len = if current.is_empty() {
                word.chars().count()
            } else {
                current.chars().count() + 1 + word.chars().count()
            };

            if candidate_len > max_chars && !current.is_empty() {
                lines.push(current);
                current = word.to_string();
            } else {
                if !current.is_empty() {
                    current.push(' ');
                }
                current.push_str(word);
            }
        }

        if current.is_empty() {
            lines.push(String::new());
        } else {
            lines.push(current);
        }
    }

    lines
}

fn glyph_advance(scale: f32) -> f32 {
    scale * 8.6
}

fn blend_rgba(pixels: &mut [u8], width: u32, height: u32, x: i32, y: i32, color: Color) {
    if x < 0 || y < 0 || x >= width as i32 || y >= height as i32 {
        return;
    }

    let index = ((y as u32 * width + x as u32) * 4) as usize;
    let [sr, sg, sb, sa] = color.rgba8();
    let src_alpha = sa as f32 / 255.0;
    if src_alpha <= 0.0 {
        return;
    }

    let dst_alpha = pixels[index + 3] as f32 / 255.0;
    let out_alpha = src_alpha + dst_alpha * (1.0 - src_alpha);
    if out_alpha <= 0.0 {
        return;
    }

    let blend_channel = |src: u8, dst: u8| -> u8 {
        let src = src as f32 / 255.0;
        let dst = dst as f32 / 255.0;
        (((src * src_alpha) + (dst * dst_alpha * (1.0 - src_alpha))) / out_alpha * 255.0)
            .round()
            .clamp(0.0, 255.0) as u8
    };

    pixels[index] = blend_channel(sb, pixels[index]);
    pixels[index + 1] = blend_channel(sg, pixels[index + 1]);
    pixels[index + 2] = blend_channel(sr, pixels[index + 2]);
    pixels[index + 3] = (out_alpha * 255.0).round().clamp(0.0, 255.0) as u8;
}
