use std::mem;

use bytemuck::{Pod, Zeroable};
use shadow_ui_core::{
    color::Color,
    scene::{RoundedRect, Scene},
};
use wgpu::util::DeviceExt;
use winit::{dpi::PhysicalSize, window::Window};

use crate::text::TextSystem;

pub struct Renderer {
    _instance: wgpu::Instance,
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    size: PhysicalSize<u32>,
    screen_uniform: wgpu::Buffer,
    screen_bind_group: wgpu::BindGroup,
    rect_pipeline: wgpu::RenderPipeline,
    quad_buffer: wgpu::Buffer,
    quad_vertex_count: u32,
    instance_buffer: wgpu::Buffer,
    instance_capacity: usize,
}

impl Renderer {
    pub async fn new(window: std::sync::Arc<Window>) -> Self {
        let size = window.inner_size();
        let instance = wgpu::Instance::default();
        let surface = instance.create_surface(window).expect("create surface");

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                compatible_surface: Some(&surface),
                ..Default::default()
            })
            .await
            .expect("request adapter");

        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor::default())
            .await
            .expect("request device");

        let capabilities = surface.get_capabilities(&adapter);
        let format = capabilities
            .formats
            .iter()
            .copied()
            .find(wgpu::TextureFormat::is_srgb)
            .unwrap_or(capabilities.formats[0]);

        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::AutoVsync,
            alpha_mode: wgpu::CompositeAlphaMode::Opaque,
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        let screen_uniform = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("screen uniform"),
            contents: bytemuck::bytes_of(&ScreenUniform {
                size: [config.width as f32, config.height as f32],
                _padding: [0.0; 2],
            }),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("screen bind group layout"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        let screen_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("screen bind group"),
            layout: &bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: screen_uniform.as_entire_binding(),
            }],
        });

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("rect shader"),
            source: wgpu::ShaderSource::Wgsl(RECT_SHADER.into()),
        });

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("rect pipeline layout"),
            bind_group_layouts: &[&bind_group_layout],
            immediate_size: 0,
        });

        let rect_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("rect pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[QuadVertex::layout(), RectInstance::layout()],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let quad_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("quad vertex buffer"),
            contents: bytemuck::cast_slice(&[
                QuadVertex {
                    position: [0.0, 0.0],
                },
                QuadVertex {
                    position: [1.0, 0.0],
                },
                QuadVertex {
                    position: [1.0, 1.0],
                },
                QuadVertex {
                    position: [0.0, 0.0],
                },
                QuadVertex {
                    position: [1.0, 1.0],
                },
                QuadVertex {
                    position: [0.0, 1.0],
                },
            ]),
            usage: wgpu::BufferUsages::VERTEX,
        });

        let instance_capacity = 128;
        let instance_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("rect instance buffer"),
            size: (instance_capacity * mem::size_of::<RectInstance>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Self {
            _instance: instance,
            surface,
            device,
            queue,
            config,
            size,
            screen_uniform,
            screen_bind_group,
            rect_pipeline,
            quad_buffer,
            quad_vertex_count: 6,
            instance_buffer,
            instance_capacity,
        }
    }

    pub fn surface_format(&self) -> wgpu::TextureFormat {
        self.config.format
    }

    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn queue(&self) -> &wgpu::Queue {
        &self.queue
    }

    pub fn resize(&mut self, size: PhysicalSize<u32>) {
        if size.width == 0 || size.height == 0 {
            self.size = size;
            return;
        }

        self.size = size;
        self.config.width = size.width;
        self.config.height = size.height;
        self.surface.configure(&self.device, &self.config);
        self.queue.write_buffer(
            &self.screen_uniform,
            0,
            bytemuck::bytes_of(&ScreenUniform {
                size: [self.config.width as f32, self.config.height as f32],
                _padding: [0.0; 2],
            }),
        );
    }

    pub fn render(
        &mut self,
        scene: &Scene,
        text_system: &mut TextSystem,
        scale_factor: f32,
    ) -> Result<(), wgpu::SurfaceError> {
        if self.config.width == 0 || self.config.height == 0 {
            return Ok(());
        }

        self.ensure_instance_capacity(scene.rects.len().max(1));

        let instances: Vec<RectInstance> = scene
            .rects
            .iter()
            .map(|rect: &RoundedRect| RectInstance {
                origin: [rect.x * scale_factor, rect.y * scale_factor],
                size: [rect.width * scale_factor, rect.height * scale_factor],
                radius: rect.radius * scale_factor,
                softness: scale_factor.max(1.0),
                _padding: [0.0; 2],
                color: rect.color.linear_rgba(),
            })
            .collect();

        self.queue
            .write_buffer(&self.instance_buffer, 0, bytemuck::cast_slice(&instances));

        let surface_texture = self.surface.get_current_texture()?;
        let view = surface_texture
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        text_system
            .prepare(
                &self.device,
                &self.queue,
                self.config.width,
                self.config.height,
                scale_factor,
                &scene.texts,
            )
            .expect("prepare text");

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("main encoder"),
            });

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("rect pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu_color(scene.clear_color)),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&self.rect_pipeline);
            pass.set_bind_group(0, &self.screen_bind_group, &[]);
            pass.set_vertex_buffer(0, self.quad_buffer.slice(..));
            pass.set_vertex_buffer(1, self.instance_buffer.slice(..));
            pass.draw(0..self.quad_vertex_count, 0..instances.len() as u32);
        }

        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("text pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Load,
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            text_system.render(&mut pass).expect("render text");
        }

        self.queue.submit([encoder.finish()]);
        surface_texture.present();
        text_system.trim();
        Ok(())
    }

    pub fn reconfigure(&mut self) {
        if self.config.width > 0 && self.config.height > 0 {
            self.surface.configure(&self.device, &self.config);
        }
    }

    fn ensure_instance_capacity(&mut self, count: usize) {
        if count <= self.instance_capacity {
            return;
        }

        self.instance_capacity = count.next_power_of_two();
        self.instance_buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("rect instance buffer"),
            size: (self.instance_capacity * mem::size_of::<RectInstance>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
    }
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ScreenUniform {
    size: [f32; 2],
    _padding: [f32; 2],
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct QuadVertex {
    position: [f32; 2],
}

impl QuadVertex {
    fn layout() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: mem::size_of::<QuadVertex>() as u64,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[wgpu::VertexAttribute {
                format: wgpu::VertexFormat::Float32x2,
                offset: 0,
                shader_location: 0,
            }],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct RectInstance {
    origin: [f32; 2],
    size: [f32; 2],
    radius: f32,
    softness: f32,
    _padding: [f32; 2],
    color: [f32; 4],
}

impl RectInstance {
    fn layout() -> wgpu::VertexBufferLayout<'static> {
        const ATTRIBUTES: [wgpu::VertexAttribute; 6] = wgpu::vertex_attr_array![
            1 => Float32x2,
            2 => Float32x2,
            3 => Float32,
            4 => Float32,
            5 => Float32x2,
            6 => Float32x4
        ];

        wgpu::VertexBufferLayout {
            array_stride: mem::size_of::<RectInstance>() as u64,
            step_mode: wgpu::VertexStepMode::Instance,
            attributes: &ATTRIBUTES,
        }
    }
}

const RECT_SHADER: &str = r#"
struct Screen {
    size: vec2f,
    _padding: vec2f,
};

@group(0) @binding(0)
var<uniform> screen: Screen;

struct VertexInput {
    @location(0) position: vec2f,
    @location(1) origin: vec2f,
    @location(2) size: vec2f,
    @location(3) radius: f32,
    @location(4) softness: f32,
    @location(5) _padding: vec2f,
    @location(6) color: vec4f,
};

struct VertexOutput {
    @builtin(position) clip_position: vec4f,
    @location(0) local: vec2f,
    @location(1) size: vec2f,
    @location(2) radius: f32,
    @location(3) softness: f32,
    @location(4) color: vec4f,
};

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    let pixel_position = input.origin + input.position * input.size;
    let ndc = vec2f(
        pixel_position.x / screen.size.x * 2.0 - 1.0,
        1.0 - pixel_position.y / screen.size.y * 2.0
    );

    var output: VertexOutput;
    output.clip_position = vec4f(ndc, 0.0, 1.0);
    output.local = input.position * input.size - input.size * 0.5;
    output.size = input.size;
    output.radius = min(input.radius, min(input.size.x, input.size.y) * 0.5);
    output.softness = max(input.softness, 1.0);
    output.color = input.color;
    return output;
}

fn rounded_rect_sdf(local: vec2f, size: vec2f, radius: f32) -> f32 {
    let half_size = size * 0.5;
    let q = abs(local) - half_size + vec2f(radius, radius);
    return length(max(q, vec2f(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
    let distance = rounded_rect_sdf(input.local, input.size, input.radius);
    let alpha = 1.0 - smoothstep(0.0, input.softness, distance);
    return vec4f(input.color.rgb, input.color.a * alpha);
}
"#;

fn wgpu_color(color: Color) -> wgpu::Color {
    let [r, g, b, a] = color.linear_rgba();
    wgpu::Color {
        r: r as f64,
        g: g as f64,
        b: b as f64,
        a: a as f64,
    }
}
