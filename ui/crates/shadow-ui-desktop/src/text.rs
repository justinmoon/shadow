use glyphon::{
    cosmic_text::Align, Attrs, Buffer, Cache, Family, FontSystem, Metrics, Resolution, Shaping,
    SwashCache, TextArea, TextAtlas, TextBounds, TextRenderer, Viewport, Weight,
};
use shadow_ui_core::{
    color::Color,
    scene::{TextAlign, TextBlock, TextWeight},
};
use wgpu::{Device, MultisampleState, Queue, RenderPass, TextureFormat};

pub struct TextSystem {
    font_system: FontSystem,
    swash_cache: SwashCache,
    viewport: Viewport,
    atlas: TextAtlas,
    renderer: TextRenderer,
    buffers: Vec<Buffer>,
}

impl TextSystem {
    pub fn new(device: &Device, queue: &Queue, format: TextureFormat) -> Self {
        let cache = Cache::new(device);
        let viewport = Viewport::new(device, &cache);
        let mut atlas = TextAtlas::new(device, queue, &cache, format);
        let renderer = TextRenderer::new(&mut atlas, device, MultisampleState::default(), None);

        Self {
            font_system: FontSystem::new(),
            swash_cache: SwashCache::new(),
            viewport,
            atlas,
            renderer,
            buffers: Vec::new(),
        }
    }

    pub fn prepare(
        &mut self,
        device: &Device,
        queue: &Queue,
        surface_width: u32,
        surface_height: u32,
        scale_factor: f32,
        text_blocks: &[TextBlock],
    ) -> Result<(), glyphon::PrepareError> {
        self.viewport.update(
            queue,
            Resolution {
                width: surface_width,
                height: surface_height,
            },
        );

        self.buffers.clear();
        self.buffers.reserve(text_blocks.len());

        for block in text_blocks {
            let mut buffer = Buffer::new(
                &mut self.font_system,
                Metrics::new(block.size, block.line_height),
            );
            buffer.set_size(&mut self.font_system, Some(block.width), Some(block.height));
            buffer.set_text(
                &mut self.font_system,
                &block.content,
                &Attrs::new()
                    .family(Family::SansSerif)
                    .weight(to_glyphon_weight(block.weight)),
                Shaping::Advanced,
                Some(to_glyphon_align(block.align)),
            );
            buffer.shape_until_scroll(&mut self.font_system, false);
            self.buffers.push(buffer);
        }

        let text_areas: Vec<TextArea<'_>> = self
            .buffers
            .iter()
            .zip(text_blocks.iter())
            .map(|(buffer, block)| TextArea {
                buffer,
                left: block.left * scale_factor,
                top: block.top * scale_factor,
                scale: scale_factor,
                bounds: TextBounds {
                    left: (block.left * scale_factor).floor() as i32,
                    top: (block.top * scale_factor).floor() as i32,
                    right: ((block.left + block.width) * scale_factor).ceil() as i32,
                    bottom: ((block.top + block.height) * scale_factor).ceil() as i32,
                },
                default_color: glyphon_color(block.color),
                custom_glyphs: &[],
            })
            .collect();

        self.renderer.prepare(
            device,
            queue,
            &mut self.font_system,
            &mut self.atlas,
            &self.viewport,
            text_areas,
            &mut self.swash_cache,
        )
    }

    pub fn render<'pass>(
        &'pass mut self,
        pass: &mut RenderPass<'pass>,
    ) -> Result<(), glyphon::RenderError> {
        self.renderer.render(&self.atlas, &self.viewport, pass)
    }

    pub fn trim(&mut self) {
        self.atlas.trim();
    }
}

fn glyphon_color(color: Color) -> glyphon::Color {
    let [r, g, b, a] = color.rgba8();
    glyphon::Color::rgba(r, g, b, a)
}

fn to_glyphon_align(align: TextAlign) -> Align {
    match align {
        TextAlign::Left => Align::Left,
        TextAlign::Center => Align::Center,
    }
}

fn to_glyphon_weight(weight: TextWeight) -> Weight {
    match weight {
        TextWeight::Normal => Weight::NORMAL,
        TextWeight::Semibold => Weight::SEMIBOLD,
        TextWeight::Bold => Weight::BOLD,
    }
}
