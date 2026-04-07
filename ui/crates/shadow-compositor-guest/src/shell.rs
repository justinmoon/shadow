use shadow_ui_core::scene::{
    Scene, APP_VIEWPORT_HEIGHT, APP_VIEWPORT_WIDTH, APP_VIEWPORT_X, APP_VIEWPORT_Y,
};
use shadow_ui_software::SoftwareRenderer;

pub struct GuestShellSurface {
    width: u32,
    height: u32,
    renderer: SoftwareRenderer,
    pixels: Vec<u8>,
}

#[derive(Clone, Copy, Debug)]
pub struct AppFrame<'a> {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub pixels: &'a [u8],
}

impl GuestShellSurface {
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            renderer: SoftwareRenderer::new(width, height),
            pixels: vec![0; (width * height * 4) as usize],
        }
    }

    #[cfg(test)]
    pub fn render_scene(&mut self, scene: &Scene) -> &[u8] {
        self.render_scene_with_app_frame(scene, None)
    }

    pub fn render_scene_with_app_frame(
        &mut self,
        scene: &Scene,
        app_frame: Option<AppFrame<'_>>,
    ) -> &[u8] {
        let scene_pixels = self.renderer.render(scene);
        self.pixels.copy_from_slice(scene_pixels);

        if let Some(app_frame) = app_frame {
            composite_app_frame(&mut self.pixels, self.width, self.height, app_frame);
        }

        &self.pixels
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

    let copy_width = viewport_width.min(app_frame.width);
    let copy_height = viewport_height.min(app_frame.height);
    let source_stride = app_frame.stride as usize;
    let target_stride = target_width as usize * 4;
    let source = app_frame.pixels;

    for row in 0..copy_height as usize {
        let target_row = viewport_y as usize + row;
        let source_row = row;
        for col in 0..copy_width as usize {
            let target_x = viewport_x as usize + col;
            let source_x = col;
            let target_index = target_row * target_stride + target_x * 4;
            let source_index = source_row * source_stride + source_x * 4;
            blend_bgra_pixel(
                &mut target[target_index..target_index + 4],
                &source[source_index..source_index + 4],
            );
        }
    }
}

fn viewport_bounds(target_width: u32, target_height: u32) -> Option<(u32, u32, u32, u32)> {
    let x = APP_VIEWPORT_X.max(0.0).round() as u32;
    let y = APP_VIEWPORT_Y.max(0.0).round() as u32;
    let width = APP_VIEWPORT_WIDTH.max(0.0).round() as u32;
    let height = APP_VIEWPORT_HEIGHT.max(0.0).round() as u32;

    if x >= target_width || y >= target_height {
        return None;
    }

    let max_width = target_width.saturating_sub(x);
    let max_height = target_height.saturating_sub(y);
    Some((x, y, width.min(max_width), height.min(max_height)))
}

fn blend_bgra_pixel(target: &mut [u8], source: &[u8]) {
    let src_b = source[0] as f32 / 255.0;
    let src_g = source[1] as f32 / 255.0;
    let src_r = source[2] as f32 / 255.0;
    let src_a = source[3] as f32 / 255.0;

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
            pixels: &[
                0, 255, 0, 255, 0, 0, 255, 255, //
                0, 0, 255, 255, 255, 255, 255, 255,
            ],
        };

        composite_app_frame(&mut target, 4, 70, app_frame);

        let viewport_origin = ((APP_VIEWPORT_Y as usize) * 4 * 4) + (APP_VIEWPORT_X as usize * 4);
        assert_eq!(
            &target[viewport_origin..viewport_origin + 4],
            &[0, 255, 0, 255]
        );
        assert_eq!(
            &target[viewport_origin + 4..viewport_origin + 8],
            &[0, 0, 255, 255]
        );
    }
}
