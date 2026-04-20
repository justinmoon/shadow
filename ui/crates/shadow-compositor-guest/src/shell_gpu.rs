use anyhow::{anyhow, Context, Result};
use anyrender::{ImageRenderer, Paint, PaintScene};
use anyrender_vello::VelloImageRenderer;
use ash::ext;
use font8x8::{UnicodeFonts, BASIC_FONTS};
use kurbo::{Affine, Rect, RoundedRect};
use peniko::Fill;
use shadow_blitz_demo::hosted_runtime::HostedRuntimeApp;
use shadow_ui_core::{
    color::Color,
    scene::{Scene, TextAlign, TextBlock, TextWeight},
};
use smithay::backend::allocator::dmabuf::Dmabuf;
use std::sync::Once;

use crate::{gpu_scanout::VulkanScanoutChain, kms::ScanoutFormatCandidate};

pub struct GpuShellRenderer {
    width: u32,
    height: u32,
    strict_gpu_resident: bool,
    renderer: VelloImageRenderer,
    pixels: Vec<u8>,
    scanout: Option<VulkanScanoutChain>,
}

impl GpuShellRenderer {
    pub fn new(width: u32, height: u32, strict_gpu_resident: bool) -> Self {
        Self {
            width,
            height,
            strict_gpu_resident,
            renderer: VelloImageRenderer::new_with_vulkan_device_extensions(
                width,
                height,
                vec![ext::image_drm_format_modifier::NAME],
            ),
            pixels: Vec::new(),
            scanout: None,
        }
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        if self.width == width && self.height == height {
            return;
        }
        self.width = width;
        self.height = height;
        self.renderer.resize(width, height);
        self.scanout = None;
    }

    pub fn configure_scanout(&mut self, candidates: &[ScanoutFormatCandidate]) -> Result<()> {
        if let Some(scanout) = self.scanout.as_ref() {
            if scanout.width() == self.width && scanout.height() == self.height {
                return Ok(());
            }
        }
        if candidates.is_empty() {
            self.scanout = None;
            return Err(anyhow!(
                "no KMS scanout candidates for gpu shell {}x{}",
                self.width,
                self.height
            ));
        }

        let scanout = VulkanScanoutChain::new(&self.renderer, self.width, self.height, candidates)
            .with_context(|| {
                format!("gpu scanout unavailable for {}x{}", self.width, self.height)
            })?;
        self.scanout = Some(scanout);
        Ok(())
    }

    pub fn has_scanout(&self) -> bool {
        self.scanout.is_some()
    }

    pub fn render_scene_to_dmabuf(&mut self, scene: &Scene) -> Result<Dmabuf> {
        let width = self.width;
        let height = self.height;
        let scanout = self
            .scanout
            .as_mut()
            .ok_or_else(|| anyhow!("gpu scanout not configured for shell scene render"))?;
        scanout
            .render(&mut self.renderer, |painter| {
                paint_scene(painter, scene, width, height);
            })
            .context("failed to render shell scene into GPU scanout")
    }

    pub fn render(&mut self, scene: &Scene) -> &[u8] {
        let width = self.width;
        let height = self.height;
        note_gpu_shell_readback(self.strict_gpu_resident);
        self.renderer.render_to_vec(
            |painter| paint_scene(painter, scene, width, height),
            &mut self.pixels,
        );
        swizzle_rgba_to_xrgb(&mut self.pixels);
        &self.pixels
    }

    pub fn render_with_hosted_app(
        &mut self,
        scene: &Scene,
        hosted_app: &mut HostedRuntimeApp,
        viewport_x: u32,
        viewport_y: u32,
        viewport_width: u32,
        viewport_height: u32,
    ) -> Result<Dmabuf> {
        let width = self.width;
        let height = self.height;
        let scanout = self
            .scanout
            .as_mut()
            .ok_or_else(|| anyhow!("gpu scanout not configured for hosted shell render"))?;
        scanout
            .render(&mut self.renderer, |painter| {
                paint_scene(painter, scene, width, height);
                hosted_app.paint_into(
                    painter,
                    viewport_width,
                    viewport_height,
                    viewport_x,
                    viewport_y,
                );
            })
            .context("failed to render hosted shell frame into GPU scanout")
    }
}

fn note_gpu_shell_readback(strict_gpu_resident: bool) {
    static WARNED: Once = Once::new();
    WARNED.call_once(|| {
        tracing::warn!(
            "[shadow-guest-compositor] cpu-crossing gpu-shell-render path=VelloImageRenderer::render_to_vec"
        );
    });
    assert!(
        !strict_gpu_resident,
        "strict gpu resident mode rejected GPU shell render_to_vec readback"
    );
}

pub(crate) fn paint_scene(painter: &mut impl PaintScene, scene: &Scene, width: u32, height: u32) {
    painter.reset();
    fill_rect(
        painter,
        Rect::new(0.0, 0.0, width as f64, height as f64),
        scene.clear_color,
    );

    for rect in &scene.rects {
        let shape = RoundedRect::from_rect(
            Rect::new(
                rect.x as f64,
                rect.y as f64,
                (rect.x + rect.width) as f64,
                (rect.y + rect.height) as f64,
            ),
            rect.radius as f64,
        );
        painter.fill(
            Fill::NonZero,
            Affine::IDENTITY,
            Paint::Solid(color_to_peniko(rect.color)),
            None,
            &shape,
        );
    }

    for text in &scene.texts {
        draw_text_block(painter, text);
    }
}

fn fill_rect(painter: &mut impl PaintScene, rect: Rect, color: Color) {
    painter.fill(
        Fill::NonZero,
        Affine::IDENTITY,
        Paint::Solid(color_to_peniko(color)),
        None,
        &rect,
    );
}

fn draw_text_block(painter: &mut impl PaintScene, block: &TextBlock) {
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
            painter,
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
    painter: &mut impl PaintScene,
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
                painter,
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
                    painter,
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
    painter: &mut impl PaintScene,
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
            let left = cell_x.max(clip_left);
            let top = cell_y.max(clip_top);
            let right = (cell_x + scale).min(clip_right);
            let bottom = (cell_y + scale).min(clip_bottom);
            if right <= left || bottom <= top {
                continue;
            }
            fill_rect(
                painter,
                Rect::new(left as f64, top as f64, right as f64, bottom as f64),
                color,
            );
        }
    }
}

fn color_to_peniko(color: Color) -> peniko::Color {
    let [r, g, b, a] = color.rgba8();
    peniko::Color::from_rgba8(r, g, b, a)
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

fn measure_text_width(text: &str, scale: f32) -> f32 {
    text.chars().count() as f32 * glyph_advance(scale)
}

fn glyph_advance(scale: f32) -> f32 {
    scale * 8.6
}

fn swizzle_rgba_to_xrgb(buffer: &mut [u8]) {
    for pixel in buffer.chunks_exact_mut(4) {
        pixel.swap(0, 2);
        pixel[3] = 0xFF;
    }
}
