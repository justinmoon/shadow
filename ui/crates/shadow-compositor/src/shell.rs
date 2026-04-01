use shadow_ui_core::scene::Scene;
use shadow_ui_software::SoftwareRenderer;
use smithay::{
    backend::{
        allocator::Fourcc,
        renderer::{
            element::memory::{MemoryRenderBuffer, MemoryRenderBufferRenderElement},
            gles::GlesRenderer,
            RendererSuper,
        },
    },
    utils::{Point, Rectangle, Transform},
};

pub struct ShellSurface {
    width: u32,
    height: u32,
    buffer: MemoryRenderBuffer,
    renderer: SoftwareRenderer,
}

impl ShellSurface {
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            buffer: MemoryRenderBuffer::new(
                Fourcc::Argb8888,
                (width as i32, height as i32),
                1,
                Transform::Flipped180,
                None,
            ),
            renderer: SoftwareRenderer::new(width, height),
        }
    }

    #[allow(dead_code)]
    pub fn resize(&mut self, width: u32, height: u32) {
        if self.width == width && self.height == height {
            return;
        }

        self.width = width;
        self.height = height;
        self.buffer = MemoryRenderBuffer::new(
            Fourcc::Argb8888,
            (width as i32, height as i32),
            1,
            Transform::Flipped180,
            None,
        );
        self.renderer.resize(width, height);
    }

    pub fn render_element(
        &mut self,
        renderer: &mut GlesRenderer,
        scene: &Scene,
        location: (i32, i32),
    ) -> Result<MemoryRenderBufferRenderElement<GlesRenderer>, <GlesRenderer as RendererSuper>::Error>
    {
        let pixels = self.renderer.render(scene);
        let size = Rectangle::from_size((self.width as i32, self.height as i32).into());

        {
            let mut context = self.buffer.render();
            context.resize((self.width as i32, self.height as i32));
            context
                .draw(|memory| {
                    memory.copy_from_slice(pixels);
                    Ok::<_, ()>(vec![size])
                })
                .expect("render shell scene into memory buffer");
        }

        MemoryRenderBufferRenderElement::from_buffer(
            renderer,
            Point::from((location.0 as f64, location.1 as f64)),
            &self.buffer,
            None,
            None,
            None,
            smithay::backend::renderer::element::Kind::Unspecified,
        )
    }
}
