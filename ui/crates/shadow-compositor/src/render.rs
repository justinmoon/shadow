use smithay::{
    backend::renderer::{
        damage::{Error as OutputDamageTrackerError, OutputDamageTracker, RenderOutputResult},
        element::memory::MemoryRenderBufferRenderElement,
        gles::GlesRenderer,
        RendererSuper,
    },
    desktop::{space, Space, Window},
    output::Output,
};

use crate::shell::{ShellRenderPlan, ShellSurface};

pub fn render_output<'a, 'd>(
    output: &'a Output,
    space: &'a Space<Window>,
    shell: Option<(&ShellRenderPlan, &mut ShellSurface, &mut [ShellSurface])>,
    renderer: &'a mut GlesRenderer,
    framebuffer: &'a mut <GlesRenderer as RendererSuper>::Framebuffer<'_>,
    damage_tracker: &'d mut OutputDamageTracker,
    age: usize,
    clear_color: [f32; 4],
) -> Result<RenderOutputResult<'d>, OutputDamageTrackerError<<GlesRenderer as RendererSuper>::Error>>
{
    let mut shell_elements: Vec<MemoryRenderBufferRenderElement<GlesRenderer>> = Vec::new();
    if let Some((plan, base_surface, overlay_surfaces)) = shell {
        shell_elements.push(
            base_surface
                .render_element(renderer, &plan.base_scene, plan.base_view)
                .map_err(OutputDamageTrackerError::Rendering)?,
        );

        debug_assert!(overlay_surfaces.len() >= plan.overlays.len());
        for (overlay, overlay_surface) in plan.overlays.iter().zip(overlay_surfaces.iter_mut()) {
            overlay_surface.resize(overlay.size.0, overlay.size.1);
            shell_elements.push(
                overlay_surface
                    .render_element(renderer, &overlay.scene, overlay.view)
                    .map_err(OutputDamageTrackerError::Rendering)?,
            );
        }
    }

    space::render_output(
        output,
        renderer,
        framebuffer,
        1.0,
        age,
        [space],
        shell_elements.as_slice(),
        damage_tracker,
        clear_color,
    )
}
