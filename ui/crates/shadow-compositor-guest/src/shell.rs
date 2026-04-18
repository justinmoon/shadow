use shadow_ui_core::scene::{
    RoundedRect, Scene, TextBlock, APP_VIEWPORT_HEIGHT, APP_VIEWPORT_WIDTH, APP_VIEWPORT_X,
    APP_VIEWPORT_Y, HEIGHT, WIDTH,
};
use shadow_ui_software::SoftwareRenderer;
use smithay::reexports::wayland_server::protocol::wl_shm;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::time::Duration;

pub struct GuestShellSurface {
    width: u32,
    height: u32,
    renderer: SoftwareRenderer,
    base_pixels: Vec<u8>,
    pixels: Vec<u8>,
    last_scene_key: Option<u64>,
    last_frame_had_app: bool,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ShellRenderStats {
    pub scene_cache_hit: bool,
    pub scene_render: Duration,
    pub base_copy: Duration,
    pub app_composite: Duration,
}

#[derive(Clone, Copy, Debug)]
pub struct AppFrame<'a> {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: wl_shm::Format,
    pub pixels: &'a [u8],
}

impl GuestShellSurface {
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            renderer: SoftwareRenderer::new(width, height),
            base_pixels: vec![0; (width * height * 4) as usize],
            pixels: vec![0; (width * height * 4) as usize],
            last_scene_key: None,
            last_frame_had_app: false,
        }
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        if self.width == width && self.height == height {
            return;
        }

        self.width = width;
        self.height = height;
        self.renderer.resize(width, height);
        self.base_pixels
            .resize((width as usize) * (height as usize) * 4, 0);
        self.pixels
            .resize((width as usize) * (height as usize) * 4, 0);
        self.last_scene_key = None;
        self.last_frame_had_app = false;
    }

    #[cfg(test)]
    pub fn render_scene(&mut self, scene: &Scene) -> &[u8] {
        self.render_scene_with_app_frame(scene, None);
        &self.pixels
    }

    pub fn take_pixels(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.pixels)
    }

    pub fn restore_pixels(&mut self, mut pixels: Vec<u8>) {
        if pixels.len() != (self.width as usize) * (self.height as usize) * 4 {
            pixels.resize((self.width as usize) * (self.height as usize) * 4, 0);
        }
        self.pixels = pixels;
    }

    pub fn render_scene_with_app_frame(
        &mut self,
        scene: &Scene,
        app_frame: Option<AppFrame<'_>>,
    ) -> ShellRenderStats {
        let mut stats = ShellRenderStats::default();
        let scene_key = scene_cache_key(scene, self.width, self.height);
        let scene_changed = self.last_scene_key != Some(scene_key);
        if scene_changed {
            let scene_render_start = std::time::Instant::now();
            self.renderer.resize(self.width, self.height);
            let scaled_scene = scale_scene(scene, self.width, self.height);
            let scene_pixels = self.renderer.render(&scaled_scene);
            self.base_pixels.copy_from_slice(scene_pixels);
            stats.scene_render = scene_render_start.elapsed();
            self.last_scene_key = Some(scene_key);
        } else {
            stats.scene_cache_hit = true;
        }

        let has_app = app_frame.is_some();
        let base_copy_start = std::time::Instant::now();
        if scene_changed {
            self.pixels.copy_from_slice(&self.base_pixels);
        } else if has_app || self.last_frame_had_app {
            restore_viewport_from_base(
                &mut self.pixels,
                &self.base_pixels,
                self.width,
                self.height,
            );
        }
        stats.base_copy = base_copy_start.elapsed();

        if let Some(app_frame) = app_frame {
            let app_composite_start = std::time::Instant::now();
            composite_app_frame(&mut self.pixels, self.width, self.height, app_frame);
            stats.app_composite = app_composite_start.elapsed();
        }

        self.last_frame_had_app = has_app;

        stats
    }
}

fn restore_viewport_from_base(
    target: &mut [u8],
    base: &[u8],
    target_width: u32,
    target_height: u32,
) {
    let Some((viewport_x, viewport_y, viewport_width, viewport_height)) =
        viewport_bounds(target_width, target_height)
    else {
        target.copy_from_slice(base);
        return;
    };

    let stride = target_width as usize * 4;
    let row_bytes = viewport_width as usize * 4;
    let start_x = viewport_x as usize * 4;

    for row in 0..viewport_height as usize {
        let row_start = (viewport_y as usize + row) * stride + start_x;
        let row_end = row_start + row_bytes;
        target[row_start..row_end].copy_from_slice(&base[row_start..row_end]);
    }
}

pub fn composite_app_frame(
    target: &mut [u8],
    target_width: u32,
    target_height: u32,
    app_frame: AppFrame<'_>,
) {
    let Some((viewport_x, viewport_y, viewport_width, viewport_height)) =
        viewport_bounds(target_width, target_height)
    else {
        return;
    };

    let copy_width = viewport_width.max(1);
    let copy_height = viewport_height.max(1);
    let source_stride = app_frame.stride as usize;
    let target_stride = target_width as usize * 4;
    let source = app_frame.pixels;
    let opaque_xrgb = matches!(app_frame.format, wl_shm::Format::Xrgb8888);

    if opaque_xrgb && app_frame.width == copy_width {
        let row_bytes = copy_width as usize * 4;
        for row in 0..copy_height as usize {
            let target_row = viewport_y as usize + row;
            let source_row = row * app_frame.height as usize / copy_height as usize;
            let target_index = target_row * target_stride + viewport_x as usize * 4;
            let source_index = source_row * source_stride;
            target[target_index..target_index + row_bytes]
                .copy_from_slice(&source[source_index..source_index + row_bytes]);
        }
        return;
    }

    let source_cols = if opaque_xrgb {
        Some(
            (0..copy_width as usize)
                .map(|col| col * app_frame.width as usize / copy_width as usize)
                .collect::<Vec<_>>(),
        )
    } else {
        None
    };

    for row in 0..copy_height as usize {
        let target_row = viewport_y as usize + row;
        let source_row = row * app_frame.height as usize / copy_height as usize;
        let source_row_start = source_row * source_stride;
        for col in 0..copy_width as usize {
            let target_x = viewport_x as usize + col;
            let target_index = target_row * target_stride + target_x * 4;
            let source_x = source_cols
                .as_ref()
                .map(|cols| cols[col])
                .unwrap_or_else(|| col * app_frame.width as usize / copy_width as usize);
            let source_index = source_row_start + source_x * 4;
            let source_pixel = &source[source_index..source_index + 4];
            if opaque_xrgb {
                target[target_index..target_index + 4].copy_from_slice(source_pixel);
            } else {
                blend_bgra_pixel(
                    &mut target[target_index..target_index + 4],
                    source_pixel,
                    app_frame.format,
                );
            }
        }
    }
}

fn viewport_bounds(target_width: u32, target_height: u32) -> Option<(u32, u32, u32, u32)> {
    let scale_x = target_width as f32 / WIDTH;
    let scale_y = target_height as f32 / HEIGHT;
    let x = (APP_VIEWPORT_X * scale_x).max(0.0).round() as u32;
    let y = (APP_VIEWPORT_Y * scale_y).max(0.0).round() as u32;
    let width = (APP_VIEWPORT_WIDTH * scale_x).max(0.0).round() as u32;
    let height = (APP_VIEWPORT_HEIGHT * scale_y).max(0.0).round() as u32;

    if x >= target_width || y >= target_height {
        return None;
    }

    let max_width = target_width.saturating_sub(x);
    let max_height = target_height.saturating_sub(y);
    Some((x, y, width.min(max_width), height.min(max_height)))
}

fn blend_bgra_pixel(target: &mut [u8], source: &[u8], format: wl_shm::Format) {
    let src_b = source[0] as f32 / 255.0;
    let src_g = source[1] as f32 / 255.0;
    let src_r = source[2] as f32 / 255.0;
    let src_a = match format {
        wl_shm::Format::Xrgb8888 => 1.0,
        _ => source[3] as f32 / 255.0,
    };

    if src_a <= 0.0 {
        return;
    }

    if src_a >= 1.0 {
        target.copy_from_slice(source);
        return;
    }

    let dst_b = target[0] as f32 / 255.0;
    let dst_g = target[1] as f32 / 255.0;
    let dst_r = target[2] as f32 / 255.0;
    let dst_a = target[3] as f32 / 255.0;
    let out_a = src_a + dst_a * (1.0 - src_a);

    let blend = |src: f32, dst: f32| -> u8 {
        (((src * src_a) + (dst * dst_a * (1.0 - src_a))) / out_a * 255.0)
            .round()
            .clamp(0.0, 255.0) as u8
    };

    target[0] = blend(src_b, dst_b);
    target[1] = blend(src_g, dst_g);
    target[2] = blend(src_r, dst_r);
    target[3] = (out_a * 255.0).round().clamp(0.0, 255.0) as u8;
}

fn scale_scene(scene: &Scene, target_width: u32, target_height: u32) -> Scene {
    let scale_x = target_width as f32 / WIDTH;
    let scale_y = target_height as f32 / HEIGHT;
    let text_scale = scale_x.min(scale_y);

    Scene {
        clear_color: scene.clear_color,
        rects: scene
            .rects
            .iter()
            .map(|rect| RoundedRect {
                x: rect.x * scale_x,
                y: rect.y * scale_y,
                width: rect.width * scale_x,
                height: rect.height * scale_y,
                radius: rect.radius * text_scale,
                color: rect.color,
            })
            .collect(),
        texts: scene
            .texts
            .iter()
            .map(|text| TextBlock {
                content: text.content.clone(),
                left: text.left * scale_x,
                top: text.top * scale_y,
                width: text.width * scale_x,
                height: text.height * scale_y,
                size: text.size * text_scale,
                line_height: text.line_height * text_scale,
                align: text.align,
                weight: text.weight,
                color: text.color,
            })
            .collect(),
    }
}

fn scene_cache_key(scene: &Scene, target_width: u32, target_height: u32) -> u64 {
    let mut hasher = DefaultHasher::new();
    target_width.hash(&mut hasher);
    target_height.hash(&mut hasher);
    scene.clear_color.rgba8().hash(&mut hasher);
    scene.rects.len().hash(&mut hasher);
    scene.texts.len().hash(&mut hasher);

    for rect in &scene.rects {
        rect.x.to_bits().hash(&mut hasher);
        rect.y.to_bits().hash(&mut hasher);
        rect.width.to_bits().hash(&mut hasher);
        rect.height.to_bits().hash(&mut hasher);
        rect.radius.to_bits().hash(&mut hasher);
        rect.color.rgba8().hash(&mut hasher);
    }

    for text in &scene.texts {
        text.content.hash(&mut hasher);
        text.left.to_bits().hash(&mut hasher);
        text.top.to_bits().hash(&mut hasher);
        text.width.to_bits().hash(&mut hasher);
        text.height.to_bits().hash(&mut hasher);
        text.size.to_bits().hash(&mut hasher);
        text.line_height.to_bits().hash(&mut hasher);
        text.color.rgba8().hash(&mut hasher);
        match text.align {
            shadow_ui_core::scene::TextAlign::Left => 0_u8,
            shadow_ui_core::scene::TextAlign::Center => 1_u8,
        }
        .hash(&mut hasher);
        match text.weight {
            shadow_ui_core::scene::TextWeight::Normal => 0_u8,
            shadow_ui_core::scene::TextWeight::Semibold => 1_u8,
            shadow_ui_core::scene::TextWeight::Bold => 2_u8,
        }
        .hash(&mut hasher);
    }

    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use shadow_ui_core::color::Color;
    use shadow_ui_core::scene::Scene;

    #[test]
    fn render_scene_produces_bgra_pixels() {
        let scene = Scene {
            clear_color: Color::rgba(255, 0, 0, 255),
            rects: Vec::new(),
            texts: Vec::new(),
        };
        let mut surface = GuestShellSurface::new(2, 2);

        let pixels = surface.render_scene(&scene);

        assert_eq!(&pixels[..4], &[0, 0, 255, 255]);
    }

    #[test]
    fn composite_app_frame_clips_into_viewport() {
        let mut target = vec![0u8; (4 * 70 * 4) as usize];
        let app_frame = AppFrame {
            width: 2,
            height: 2,
            stride: 8,
            format: wl_shm::Format::Argb8888,
            pixels: &[
                0, 255, 0, 255, 0, 0, 255, 255, //
                0, 0, 255, 255, 255, 255, 255, 255,
            ],
        };

        composite_app_frame(&mut target, 4, 70, app_frame);

        let (_, viewport_y, _, _) = viewport_bounds(4, 70).expect("scaled viewport");
        let viewport_origin = (viewport_y as usize) * 4 * 4;
        assert_eq!(
            &target[viewport_origin..viewport_origin + 4],
            &[0, 255, 0, 255]
        );
        assert_eq!(
            &target[viewport_origin + 4..viewport_origin + 8],
            &[0, 255, 0, 255]
        );
    }

    #[test]
    fn composite_app_frame_treats_xrgb_as_opaque() {
        let mut target = vec![0u8; 4];
        let app_frame = AppFrame {
            width: 1,
            height: 1,
            stride: 4,
            format: wl_shm::Format::Xrgb8888,
            pixels: &[1, 2, 3, 0],
        };

        composite_app_frame(&mut target, 1, 1, app_frame);

        assert_eq!(target, vec![1, 2, 3, 0]);
    }

    #[test]
    fn composite_app_frame_fast_path_copies_opaque_rows_when_width_matches() {
        let mut target = vec![0u8; (4 * 70 * 4) as usize];
        let app_frame = AppFrame {
            width: 4,
            height: 2,
            stride: 16,
            format: wl_shm::Format::Xrgb8888,
            pixels: &[
                1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0, //
                13, 14, 15, 0, 16, 17, 18, 0, 19, 20, 21, 0, 22, 23, 24, 0,
            ],
        };

        composite_app_frame(&mut target, 4, 70, app_frame);

        let (_, viewport_y, _, _) = viewport_bounds(4, 70).expect("scaled viewport");
        let viewport_origin = (viewport_y as usize) * 4 * 4;
        assert_eq!(
            &target[viewport_origin..viewport_origin + 16],
            &[1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0,]
        );
    }

    #[test]
    fn render_scene_reuses_cached_base_when_scene_is_unchanged() {
        let scene = Scene {
            clear_color: Color::rgba(255, 0, 0, 255),
            rects: Vec::new(),
            texts: Vec::new(),
        };
        let mut surface = GuestShellSurface::new(2, 2);

        let first = surface.render_scene_with_app_frame(&scene, None);
        assert!(!first.scene_cache_hit);

        let second = surface.render_scene_with_app_frame(&scene, None);
        assert!(second.scene_cache_hit);
    }

    #[test]
    fn render_scene_restores_viewport_when_app_frame_is_removed() {
        let scene = Scene {
            clear_color: Color::rgba(255, 0, 0, 255),
            rects: Vec::new(),
            texts: Vec::new(),
        };
        let mut surface = GuestShellSurface::new(4, 70);
        let app_frame = AppFrame {
            width: 2,
            height: 2,
            stride: 8,
            format: wl_shm::Format::Argb8888,
            pixels: &[
                0, 255, 0, 255, 0, 255, 0, 255, //
                0, 255, 0, 255, 0, 255, 0, 255,
            ],
        };

        surface.render_scene_with_app_frame(&scene, Some(app_frame));
        let (_, viewport_y, _, _) = viewport_bounds(4, 70).expect("scaled viewport");
        let viewport_origin = (viewport_y as usize) * 4 * 4;
        assert_eq!(
            &surface.pixels[viewport_origin..viewport_origin + 4],
            &[0, 255, 0, 255]
        );

        surface.render_scene_with_app_frame(&scene, None);
        assert_eq!(
            &surface.pixels[viewport_origin..viewport_origin + 4],
            &[0, 0, 255, 255]
        );
    }
}
