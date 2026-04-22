use std::sync::{Arc, Once};
use std::time::Instant;

use anyrender::PaintScene;
use blitz_dom::Document as _;
use blitz_paint::paint_scene;
use blitz_traits::{
    events::{
        BlitzPointerEvent, BlitzPointerId, MouseEventButton, MouseEventButtons, PointerCoords,
        UiEvent,
    },
    shell::{ColorScheme, DummyShellProvider, Viewport},
};
use shadow_runtime_protocol::{AppLifecycleState, RuntimeAudioControlAction};

use crate::{log::runtime_log, runtime_document::RuntimeDocument, runtime_session::RuntimeSession};

#[cfg(not(feature = "hosted_gpu"))]
compile_error!("shadow-blitz-demo hosted runtime requires hosted_gpu");

pub struct HostedRuntimeApp {
    document: RuntimeDocument,
    width: u32,
    height: u32,
}

impl HostedRuntimeApp {
    pub fn new(
        host_binary_path: String,
        bundle_path: String,
        width: u32,
        height: u32,
        client_env_assignments: &[(String, String)],
    ) -> Result<Self, String> {
        let width = width.max(1);
        let height = height.max(1);
        let runtime_session = RuntimeSession::spawn_explicit(host_binary_path, bundle_path)?;
        let mut document = RuntimeDocument::from_runtime_session_with_client_env(
            runtime_session,
            client_env_assignments,
        )?;
        configure_document(&mut document, width, height);
        Ok(Self {
            document,
            width,
            height,
        })
    }

    pub fn set_surface_size(&mut self, width: u32, height: u32) {
        let width = width.max(1);
        let height = height.max(1);
        if self.width == width && self.height == height {
            return;
        }
        self.width = width;
        self.height = height;
        configure_document(&mut self.document, width, height);
    }

    pub fn handle_pointer_down(&mut self, client_x: f32, client_y: f32) -> Result<bool, String> {
        self.document
            .handle_ui_event(UiEvent::PointerDown(pointer_event(
                BlitzPointerId::Finger(1),
                MouseEventButton::Main,
                MouseEventButtons::Primary,
                client_x,
                client_y,
            )));
        Ok(true)
    }

    pub fn handle_pointer_move(&mut self, client_x: f32, client_y: f32) -> Result<bool, String> {
        self.document
            .handle_ui_event(UiEvent::PointerMove(pointer_event(
                BlitzPointerId::Finger(1),
                MouseEventButton::Main,
                MouseEventButtons::Primary,
                client_x,
                client_y,
            )));
        Ok(true)
    }

    pub fn handle_pointer_up(&mut self, client_x: f32, client_y: f32) -> Result<bool, String> {
        self.document
            .handle_ui_event(UiEvent::PointerUp(pointer_event(
                BlitzPointerId::Finger(1),
                MouseEventButton::Main,
                MouseEventButtons::None,
                client_x,
                client_y,
            )));
        Ok(true)
    }

    pub fn handle_platform_audio_control(
        &mut self,
        action: RuntimeAudioControlAction,
    ) -> Result<bool, String> {
        Ok(self.document.handle_platform_audio_control(action))
    }

    pub fn handle_platform_lifecycle_change(
        &mut self,
        state: AppLifecycleState,
    ) -> Result<bool, String> {
        Ok(self.document.handle_platform_lifecycle_change(state))
    }

    pub fn poll(&mut self) -> Result<bool, String> {
        let changed = self.document.poll(None) || self.document.check_touch_signal();
        let redraw_requested = self.document.take_redraw_requested();
        Ok(changed || redraw_requested)
    }

    pub fn paint_into(
        &mut self,
        painter: &mut impl PaintScene,
        render_width: u32,
        render_height: u32,
        x_offset: u32,
        y_offset: u32,
    ) {
        if render_width == 0 || render_height == 0 || self.width == 0 || self.height == 0 {
            return;
        }

        let scale_x = render_width as f64 / self.width as f64;
        let scale_y = render_height as f64 / self.height as f64;
        let scale = scale_x;
        note_non_uniform_hosted_scale(scale_x, scale_y);

        let inner = self.document.inner();
        let paint_started = Instant::now();
        paint_scene(
            painter,
            &inner,
            scale,
            render_width,
            render_height,
            x_offset,
            y_offset,
        );
        if hosted_gpu_profile_enabled() {
            runtime_log(format!(
                "hosted-gpu-profile paint_scene_ms={} render={}x{} viewport_offset={}x{} doc={}x{}",
                paint_started.elapsed().as_millis(),
                render_width,
                render_height,
                x_offset,
                y_offset,
                self.width,
                self.height
            ));
        }
    }
}

fn hosted_gpu_profile_enabled() -> bool {
    std::env::var_os("SHADOW_GUEST_COMPOSITOR_GPU_PROFILE_TRACE").is_some()
}

fn note_non_uniform_hosted_scale(scale_x: f64, scale_y: f64) {
    static WARNED: Once = Once::new();
    if (scale_x - scale_y).abs() <= 0.01 {
        return;
    }
    WARNED.call_once(|| {
        runtime_log(format!(
            "hosted-runtime-scale-mismatch scale_x={scale_x:.3} scale_y={scale_y:.3}"
        ));
    });
}

fn configure_document(document: &mut RuntimeDocument, width: u32, height: u32) {
    document.update_surface_size(width, height);
    let mut inner = document.inner_mut();
    inner.set_viewport(Viewport::new(width, height, 1.0, ColorScheme::Dark));
    inner.set_shell_provider(Arc::new(DummyShellProvider));
    inner.resolve(0.0);
}

fn pointer_coords(client_x: f32, client_y: f32) -> PointerCoords {
    PointerCoords {
        page_x: client_x,
        page_y: client_y,
        screen_x: client_x,
        screen_y: client_y,
        client_x,
        client_y,
    }
}

fn pointer_event(
    id: BlitzPointerId,
    button: MouseEventButton,
    buttons: MouseEventButtons,
    client_x: f32,
    client_y: f32,
) -> BlitzPointerEvent {
    BlitzPointerEvent {
        id,
        is_primary: true,
        coords: pointer_coords(client_x, client_y),
        button,
        buttons,
        mods: Default::default(),
        details: Default::default(),
    }
}
