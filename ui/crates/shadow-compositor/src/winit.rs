#![cfg(target_os = "linux")]

use std::time::Duration;

use shadow_ui_core::{
    color::BACKGROUND,
    scene::{HEIGHT, WIDTH},
    shell::ShellStatus,
};
use smithay::{
    backend::{
        renderer::damage::OutputDamageTracker,
        winit::{self, WinitEvent},
    },
    output::{Mode, Output, PhysicalProperties, Subpixel},
    reexports::{
        calloop::EventLoop,
        winit::{dpi::LogicalSize, window::Window as WinitWindow},
    },
    utils::{Rectangle, Transform},
};

use crate::{render, state::ShadowCompositor};

pub fn init_winit(
    event_loop: &mut EventLoop<ShadowCompositor>,
    state: &mut ShadowCompositor,
) -> Result<(), Box<dyn std::error::Error>> {
    tracing::info!("shadow-compositor: creating winit backend window");
    let attributes = WinitWindow::default_attributes()
        .with_title("Shadow")
        .with_resizable(false)
        .with_inner_size(LogicalSize::new(WIDTH as f64, HEIGHT as f64))
        .with_visible(true);
    let (mut backend, winit) = winit::init_from_attributes(attributes)?;
    tracing::info!(mode = ?backend.window_size(), "shadow-compositor: winit backend ready");

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
            serial_number: "Unknown".into(),
        },
    );
    let _global = output.create_global::<ShadowCompositor>(&state.display_handle);
    output.change_current_state(
        Some(mode),
        Some(Transform::Normal),
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
                    None,
                    None,
                    None,
                );
                state.shell_surface.resize(size.w as u32, size.h as u32);
                state.sync_window_positions();
            }
            WinitEvent::Input(event) => state.process_input_event(event),
            WinitEvent::Redraw => {
                let size = backend.window_size();
                let damage = Rectangle::from_size(size);
                let scene = state.shell.scene(&ShellStatus::demo(chrono::Local::now()));

                {
                    let (renderer, mut framebuffer) = backend.bind().expect("bind backend");
                    let render_shell = !state.has_mapped_app_window();
                    render::render_output(
                        &output,
                        &state.space,
                        &scene,
                        &mut state.shell_surface,
                        renderer,
                        &mut framebuffer,
                        &mut damage_tracker,
                        0,
                        BACKGROUND.linear_rgba(),
                        render_shell,
                    )
                    .expect("render output");
                }

                backend.submit(Some(&[damage])).expect("submit frame");
                state.space.elements().for_each(|window| {
                    window.send_frame(
                        &output,
                        state.start_time.elapsed(),
                        Some(Duration::ZERO),
                        |_, _| Some(output.clone()),
                    )
                });
                state.space.refresh();
                state.popups.cleanup();
                let _ = state.display_handle.flush_clients();
                backend.window().request_redraw();
            }
            WinitEvent::CloseRequested => {
                tracing::warn!("shadow-compositor: received close request");
                state.loop_signal.stop();
            }
            _ => {}
        })?;

    Ok(())
}
