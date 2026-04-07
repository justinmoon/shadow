//! An AnyRender WindowRenderer for rendering pixel buffers using the softbuffer crate

#![cfg_attr(docsrs, feature(doc_cfg))]

use anyrender::{ImageRenderer, WindowHandle, WindowRenderer};
use debug_timer::debug_timer;
use softbuffer::{Context, Surface};
use std::{num::NonZero, sync::Arc, time::Instant};

// Simple struct to hold the state of the renderer
pub struct ActiveRenderState {
    _context: Context<Arc<dyn WindowHandle>>,
    surface: Surface<Arc<dyn WindowHandle>, Arc<dyn WindowHandle>>,
}

#[allow(clippy::large_enum_variant)]
pub enum RenderState {
    Active(ActiveRenderState),
    Suspended,
}

pub struct SoftbufferWindowRenderer<Renderer: ImageRenderer> {
    // The fields MUST be in this order, so that the surface is dropped before the window
    // Window is cached even when suspended so that it can be reused when the app is resumed after being suspended
    render_state: RenderState,
    window_handle: Option<Arc<dyn WindowHandle>>,
    renderer: Renderer,
    buffer: Vec<u8>,
}

impl<Renderer: ImageRenderer> SoftbufferWindowRenderer<Renderer> {
    #[allow(clippy::new_without_default)]
    pub fn new() -> Self {
        // Seed GPU-capable renderers with a non-zero surface so they do not
        // allocate a zero-sized texture before the real window size arrives.
        Self::with_renderer(Renderer::new(1, 1))
    }

    pub fn with_renderer<R: ImageRenderer>(renderer: R) -> SoftbufferWindowRenderer<R> {
        SoftbufferWindowRenderer {
            render_state: RenderState::Suspended,
            window_handle: None,
            renderer,
            buffer: Vec::new(),
        }
    }
}

impl<Renderer: ImageRenderer> WindowRenderer for SoftbufferWindowRenderer<Renderer> {
    type ScenePainter<'a>
        = Renderer::ScenePainter<'a>
    where
        Self: 'a;

    fn is_active(&self) -> bool {
        matches!(self.render_state, RenderState::Active(_))
    }

    fn resume(&mut self, window_handle: Arc<dyn WindowHandle>, width: u32, height: u32) {
        let start = Instant::now();
        eprintln!(
            "[shadow-softbuffer +{:>6}ms] resume-start size={}x{}",
            0, width, height
        );
        let context = Context::new(window_handle.clone()).unwrap();
        eprintln!(
            "[shadow-softbuffer +{:>6}ms] context-new",
            start.elapsed().as_millis()
        );
        let surface = Surface::new(&context, window_handle.clone()).unwrap();
        eprintln!(
            "[shadow-softbuffer +{:>6}ms] surface-new",
            start.elapsed().as_millis()
        );
        self.render_state = RenderState::Active(ActiveRenderState {
            _context: context,
            surface,
        });
        self.window_handle = Some(window_handle);

        self.set_size(width, height);
        eprintln!(
            "[shadow-softbuffer +{:>6}ms] resume-done",
            start.elapsed().as_millis()
        );
    }

    fn suspend(&mut self) {
        self.render_state = RenderState::Suspended;
    }

    fn set_size(&mut self, physical_width: u32, physical_height: u32) {
        if let RenderState::Active(state) = &mut self.render_state {
            let start = Instant::now();
            let clamped_width = physical_width.max(1);
            let clamped_height = physical_height.max(1);
            eprintln!(
                "[shadow-softbuffer +{:>6}ms] set-size-start raw={}x{} effective={}x{}",
                0, physical_width, physical_height, clamped_width, clamped_height
            );
            state
                .surface
                .resize(
                    NonZero::new(clamped_width).unwrap(),
                    NonZero::new(clamped_height).unwrap(),
                )
                .unwrap();
            eprintln!(
                "[shadow-softbuffer +{:>6}ms] surface-resize-done",
                start.elapsed().as_millis()
            );
            self.renderer.resize(clamped_width, clamped_height);
            eprintln!(
                "[shadow-softbuffer +{:>6}ms] renderer-resize-done",
                start.elapsed().as_millis()
            );
        };
    }

    fn render<F: FnOnce(&mut Renderer::ScenePainter<'_>)>(&mut self, draw_fn: F) {
        let RenderState::Active(state) = &mut self.render_state else {
            return;
        };
        let start = Instant::now();
        eprintln!("[shadow-softbuffer +{:>6}ms] render-start", 0);

        debug_timer!(timer, feature = "log_frame_times");

        let Ok(mut surface_buffer) = state.surface.buffer_mut() else {
            return;
        };
        eprintln!(
            "[shadow-softbuffer +{:>6}ms] buffer-mut-done",
            start.elapsed().as_millis()
        );
        timer.record_time("buffer_mut");

        // Paint
        self.renderer.render_to_vec(draw_fn, &mut self.buffer);
        eprintln!(
            "[shadow-softbuffer +{:>6}ms] render-to-vec-done",
            start.elapsed().as_millis()
        );
        timer.record_time("render");

        let out = surface_buffer.as_mut();

        let (chunks, remainder) = self.buffer.as_chunks::<4>();
        assert_eq!(chunks.len(), out.len());
        assert_eq!(remainder.len(), 0);

        for (&src, dest) in chunks.iter().zip(out.iter_mut()) {
            let [r, g, b, a] = src;
            if a == 0 {
                *dest = u32::MAX;
            } else {
                *dest = (r as u32) << 16 | (g as u32) << 8 | b as u32;
            }
        }
        eprintln!(
            "[shadow-softbuffer +{:>6}ms] swizzle-done",
            start.elapsed().as_millis()
        );
        timer.record_time("swizel");

        surface_buffer.present().unwrap();
        eprintln!(
            "[shadow-softbuffer +{:>6}ms] present-done",
            start.elapsed().as_millis()
        );
        timer.record_time("present");
        timer.print_times("softbuffer: ");

        // Reset the renderer ready for the next render
        self.renderer.reset();
    }
}
