use std::time::Duration;

use shadow_ui_core::{color::BACKGROUND, shell::ShellStatus};
use smithay::{
    backend::{
        renderer::damage::OutputDamageTracker,
        winit::{self, WinitEvent},
    },
    output::{Mode, Output, PhysicalProperties, Subpixel},
    reexports::calloop::EventLoop,
    utils::{Rectangle, Transform},
};

use crate::{render, state::ShadowCompositor};

const NESTED_OUTPUT_TRANSFORM: Transform = Transform::Normal;

pub fn init_winit(
    event_loop: &mut EventLoop<ShadowCompositor>,
    state: &mut ShadowCompositor,
) -> Result<(), Box<dyn std::error::Error>> {
    let (mut backend, winit) = winit::init()?;
    let mode = Mode {
        size: backend.window_size(),
        refresh: 60_000,
    };

    let output = Output::new(
        "shadow".to_string(),
        PhysicalProperties {
            size: (0, 0).into(),
            subpixel: Subpixel::Unknown,
            make: "Shadow".into(),
            model: "Nested".into(),
        },
    );
    let _global = output.create_global::<ShadowCompositor>(&state.display_handle);
    output.change_current_state(
        Some(mode),
        Some(NESTED_OUTPUT_TRANSFORM),
        None,
        Some((0, 0).into()),
    );
    output.set_preferred(mode);
    state.space.map_output(&output, (0, 0));

    let mut damage_tracker = OutputDamageTracker::from_output(&output);
    backend.window().request_redraw();

    event_loop
        .handle()
        .insert_source(winit, move |event, _, state| match event {
            WinitEvent::Resized { size, .. } => {
                output.change_current_state(
                    Some(Mode {
                        size,
                        refresh: 60_000,
                    }),
                    Some(NESTED_OUTPUT_TRANSFORM),
                    None,
                    None,
                );
            }
            WinitEvent::Input(event) => state.process_input_event(event),
            WinitEvent::Redraw => {
                let size = backend.window_size();
                let damage = Rectangle::from_size(size);
                let scene = state.shell.scene(&ShellStatus::demo(chrono::Local::now()));
                let shell_location = state.shell_location();

                {
                    let (renderer, mut framebuffer) = backend.bind().unwrap();
                    render::render_output(
                        &output,
                        &state.space,
                        &scene,
                        &mut state.shell_surface,
                        shell_location,
                        renderer,
                        &mut framebuffer,
                        &mut damage_tracker,
                        0,
                        BACKGROUND.linear_rgba(),
                        true,
                    )
                    .unwrap();
                }

                backend.submit(Some(&[damage])).unwrap();
                state.space.elements().for_each(|window| {
                    window.send_frame(
                        &output,
                        state.start_time.elapsed(),
                        Some(Duration::ZERO),
                        |_, _| Some(output.clone()),
                    );
                });
                state.space.refresh();
                state.popups.cleanup();
                let _ = state.display_handle.flush_clients();
                backend.window().request_redraw();
            }
            WinitEvent::CloseRequested => state.loop_signal.stop(),
            _ => {}
        })?;

    Ok(())
}
