use shadow_ui_core::scene::Scene;
use smithay::{
    backend::renderer::{
        damage::{Error as OutputDamageTrackerError, OutputDamageTracker, RenderOutputResult},
        gles::GlesRenderer,
        RendererSuper,
    },
    desktop::{space, Space, Window},
    output::Output,
};

use crate::shell::ShellSurface;

pub fn render_output<'a, 'd>(
    output: &'a Output,
    space: &'a Space<Window>,
    scene: &Scene,
    shell: &mut ShellSurface,
    shell_location: (i32, i32),
    renderer: &'a mut GlesRenderer,
    framebuffer: &'a mut <GlesRenderer as RendererSuper>::Framebuffer<'_>,
    damage_tracker: &'d mut OutputDamageTracker,
    age: usize,
    clear_color: [f32; 4],
    render_shell: bool,
) -> Result<RenderOutputResult<'d>, OutputDamageTrackerError<<GlesRenderer as RendererSuper>::Error>>
{
    let shell_elements = if render_shell {
        Some(
            shell
                .render_element(renderer, scene, shell_location)
                .map_err(OutputDamageTrackerError::Rendering)?,
        )
    } else {
        None
    };

    space::render_output(
        output,
        renderer,
        framebuffer,
        1.0,
        age,
        [space],
        shell_elements
            .as_ref()
            .map(std::slice::from_ref)
            .unwrap_or(&[]),
        damage_tracker,
        clear_color,
    )
}
