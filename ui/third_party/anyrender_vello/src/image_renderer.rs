use anyrender::ImageRenderer;
use rustc_hash::FxHashMap;
use std::ffi::CStr;
use std::time::Instant;
use vello::{Renderer as VelloRenderer, RendererOptions, Scene as VelloScene};
use wgpu::TextureUsages;
use wgpu_context::{BufferRenderer, BufferRendererConfig, DeviceHandle, WGPUContext};

use crate::{VelloScenePainter, DEFAULT_THREADS};

pub struct VelloImageRenderer {
    buffer_renderer: BufferRenderer,
    vello_renderer: VelloRenderer,
    scene: VelloScene,
}

impl VelloImageRenderer {
    pub fn new_with_vulkan_device_extensions(
        width: u32,
        height: u32,
        extra_vulkan_device_extensions: Vec<&'static CStr>,
    ) -> Self {
        let mut context = WGPUContext::with_features_limits_and_vulkan_extensions(
            None,
            None,
            extra_vulkan_device_extensions,
        );

        let buffer_renderer =
            pollster::block_on(context.create_buffer_renderer(BufferRendererConfig {
                width,
                height,
                usage: TextureUsages::STORAGE_BINDING,
            }))
            .expect("No compatible device found");

        let vello_renderer = VelloRenderer::new(
            buffer_renderer.device(),
            RendererOptions {
                use_cpu: false,
                num_init_threads: DEFAULT_THREADS,
                antialiasing_support: vello::AaSupport::area_only(),
                pipeline_cache: None,
            },
        )
        .expect("Got non-Send/Sync error from creating renderer");

        Self {
            buffer_renderer,
            vello_renderer,
            scene: VelloScene::new(),
        }
    }

    pub fn device_handle(&self) -> &DeviceHandle {
        &self.buffer_renderer.device_handle
    }

    pub fn render_to_texture_view(
        &mut self,
        draw_fn: impl FnOnce(&mut VelloScenePainter<'_, '_>),
    ) -> wgpu::TextureView {
        draw_fn(&mut VelloScenePainter {
            inner: &mut self.scene,
            renderer: Some(&mut self.vello_renderer),
            custom_paint_sources: Some(&mut FxHashMap::default()),
        });

        self.render_scene_to_texture_view()
    }

    fn render_scene_to_texture_view(&mut self) -> wgpu::TextureView {
        let size = self.buffer_renderer.size();
        let texture_view = self.buffer_renderer.target_texture_view();
        self.vello_renderer
            .render_to_texture(
                self.buffer_renderer.device(),
                self.buffer_renderer.queue(),
                &self.scene,
                &texture_view,
                &vello::RenderParams {
                    base_color: vello::peniko::Color::TRANSPARENT,
                    width: size.width,
                    height: size.height,
                    antialiasing_method: vello::AaConfig::Area,
                },
            )
            .expect("Got non-Send/Sync error from rendering");

        self.scene.reset();
        texture_view
    }

    pub fn render_to_existing_texture_view(
        &mut self,
        texture_view: &wgpu::TextureView,
        width: u32,
        height: u32,
        draw_fn: impl FnOnce(&mut VelloScenePainter<'_, '_>),
    ) {
        let build_started = Instant::now();
        draw_fn(&mut VelloScenePainter {
            inner: &mut self.scene,
            renderer: Some(&mut self.vello_renderer),
            custom_paint_sources: Some(&mut FxHashMap::default()),
        });
        let build_elapsed = build_started.elapsed();

        let render_started = Instant::now();
        self.vello_renderer
            .render_to_texture(
                self.buffer_renderer.device(),
                self.buffer_renderer.queue(),
                &self.scene,
                texture_view,
                &vello::RenderParams {
                    base_color: vello::peniko::Color::TRANSPARENT,
                    width,
                    height,
                    antialiasing_method: vello::AaConfig::Area,
                },
            )
            .expect("Got non-Send/Sync error from rendering");
        let render_elapsed = render_started.elapsed();

        if gpu_profile_enabled() {
            eprintln!(
                "[shadow-anyrender-vello] gpu-profile scene_build_ms={} render_submit_ms={} render={}x{}",
                build_elapsed.as_millis(),
                render_elapsed.as_millis(),
                width,
                height
            );
        }

        self.scene.reset();
    }
}

fn gpu_profile_enabled() -> bool {
    std::env::var_os("SHADOW_GUEST_COMPOSITOR_GPU_PROFILE_TRACE").is_some()
}

impl ImageRenderer for VelloImageRenderer {
    type ScenePainter<'a>
        = VelloScenePainter<'a, 'a>
    where
        Self: 'a;

    fn new(width: u32, height: u32) -> Self {
        Self::new_with_vulkan_device_extensions(width, height, Vec::new())
    }

    fn resize(&mut self, width: u32, height: u32) {
        self.buffer_renderer.resize(width, height);
    }

    fn reset(&mut self) {
        self.scene.reset();
    }

    fn render_to_vec<F: FnOnce(&mut Self::ScenePainter<'_>)>(
        &mut self,
        draw_fn: F,
        cpu_buffer: &mut Vec<u8>,
    ) {
        let size = self.buffer_renderer.size();
        cpu_buffer.resize((size.width * size.height * 4) as usize, 0);
        self.render(draw_fn, cpu_buffer);
    }

    fn render<F: FnOnce(&mut Self::ScenePainter<'_>)>(
        &mut self,
        draw_fn: F,
        cpu_buffer: &mut [u8],
    ) {
        draw_fn(&mut VelloScenePainter {
            inner: &mut self.scene,
            renderer: Some(&mut self.vello_renderer),
            custom_paint_sources: Some(&mut FxHashMap::default()),
        });

        let _texture_view = self.render_scene_to_texture_view();
        self.buffer_renderer.copy_texture_to_buffer(cpu_buffer);
    }
}
