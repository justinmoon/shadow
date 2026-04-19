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
    utils::{Logical, Point, Rectangle, Size, Transform},
};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShellSurfaceView {
    pub location: (i32, i32),
    pub src: Option<Rectangle<f64, Logical>>,
    pub size: Option<Size<i32, Logical>>,
}

impl ShellSurfaceView {
    pub fn full(location: (i32, i32)) -> Self {
        Self {
            location,
            src: None,
            size: None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ShellOverlayPlan {
    pub scene: Scene,
    pub view: ShellSurfaceView,
    pub size: (u32, u32),
}

#[derive(Clone, Debug)]
pub struct ShellRenderPlan {
    pub base_scene: Scene,
    pub base_view: ShellSurfaceView,
    pub overlays: Vec<ShellOverlayPlan>,
}

impl ShellRenderPlan {
    pub fn single(scene: Scene, location: (i32, i32)) -> Self {
        Self {
            base_scene: scene,
            base_view: ShellSurfaceView::full(location),
            overlays: Vec::new(),
        }
    }

    pub fn push_overlay(&mut self, scene: Scene, location: (i32, i32), size: (u32, u32)) {
        self.overlays.push(ShellOverlayPlan {
            scene,
            view: ShellSurfaceView::full(location),
            size,
        });
    }
}

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
                Transform::Normal,
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
            Transform::Normal,
            None,
        );
        self.renderer.resize(width, height);
    }

    pub fn render_element(
        &mut self,
        renderer: &mut GlesRenderer,
        scene: &Scene,
        view: ShellSurfaceView,
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
            Point::from((view.location.0 as f64, view.location.1 as f64)),
            &self.buffer,
            None,
            view.src,
            view.size,
            smithay::backend::renderer::element::Kind::Unspecified,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{ShellOverlayPlan, ShellRenderPlan, ShellSurfaceView};
    use shadow_ui_core::{color::BACKGROUND, scene::Scene};

    fn empty_scene() -> Scene {
        Scene {
            clear_color: BACKGROUND,
            rects: Vec::new(),
            texts: Vec::new(),
        }
    }

    #[test]
    fn push_overlay_keeps_independent_base_and_overlay_locations() {
        let mut plan = ShellRenderPlan::single(empty_scene(), (12, 24));
        plan.push_overlay(empty_scene(), (28, 40), (64, 32));

        assert_eq!(plan.base_view, ShellSurfaceView::full((12, 24)));
        assert_eq!(plan.overlays.len(), 1);
        assert_eq!(plan.overlays[0].view, ShellSurfaceView::full((28, 40)));
        assert_eq!(plan.overlays[0].size, (64, 32));
    }

    #[test]
    fn push_overlay_preserves_multiple_overlay_order_and_sizes() {
        let mut plan = ShellRenderPlan::single(empty_scene(), (12, 24));
        plan.push_overlay(empty_scene(), (28, 40), (64, 32));
        plan.push_overlay(empty_scene(), (44, 52), (96, 14));

        assert_eq!(plan.overlays.len(), 2);
        assert_eq!(plan.overlays[0].view, ShellSurfaceView::full((28, 40)));
        assert_eq!(plan.overlays[0].size, (64, 32));
        assert_eq!(plan.overlays[1].view, ShellSurfaceView::full((44, 52)));
        assert_eq!(plan.overlays[1].size, (96, 14));
    }

    #[test]
    fn single_plan_has_no_overlay() {
        let plan = ShellRenderPlan::single(empty_scene(), (12, 24));

        assert!(plan.overlays.is_empty());
        assert_eq!(plan.base_view, ShellSurfaceView::full((12, 24)));
    }
}
