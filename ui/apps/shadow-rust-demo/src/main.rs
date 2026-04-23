use std::{error::Error, num::NonZeroU32};

use font8x8::{UnicodeFonts, BASIC_FONTS};
use shadow_sdk::{
    app::{
        current_lifecycle_state, spawn_lifecycle_listener, AppWindowDefaults, AppWindowEnvironment,
        LifecycleState,
    },
    services::camera::{capture_still, list_cameras, CameraError, CaptureRequest},
};
use shadow_ui_core::scene::{APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX};
use softbuffer::{Context, Surface};
use winit::{
    application::ApplicationHandler,
    dpi::{LogicalSize, PhysicalSize},
    event::WindowEvent,
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    window::{Window, WindowAttributes, WindowId},
};

#[cfg(target_os = "linux")]
use winit::platform::wayland::WindowAttributesWayland;

const DEFAULT_TITLE: &str = "Shadow Rust Demo";
const DEFAULT_WAYLAND_APP_ID: &str = "dev.shadow.rust-demo";
const DEFAULT_WAYLAND_INSTANCE_NAME: &str = "rust-demo";
const WINDOW_DEFAULTS: AppWindowDefaults<'static> =
    AppWindowDefaults::new(DEFAULT_TITLE, APP_VIEWPORT_WIDTH_PX, APP_VIEWPORT_HEIGHT_PX)
        .with_wayland_app_id(DEFAULT_WAYLAND_APP_ID)
        .with_wayland_instance_name(DEFAULT_WAYLAND_INSTANCE_NAME);

const BACKGROUND_SUCCESS: u32 = 0x17362C;
const BACKGROUND_ERROR: u32 = 0x4A2022;
const TEXT_COLOR: u32 = 0xF7FAFC;
const ACCENT_SUCCESS: u32 = 0x74D3AE;
const ACCENT_ERROR: u32 = 0xF2A17F;
const PANEL_PADDING_PX: usize = 24;
const ACCENT_BAR_HEIGHT_PX: usize = 10;
const FONT_SCALE: usize = 2;
const FONT_WIDTH_PX: usize = 8 * FONT_SCALE;
const FONT_HEIGHT_PX: usize = 8 * FONT_SCALE;
const LINE_SPACING_PX: usize = 8;

struct WindowState {
    window: &'static dyn Window,
    _context: Context<&'static dyn Window>,
    surface: Surface<&'static dyn Window, &'static dyn Window>,
    surface_size: PhysicalSize<u32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct CameraProbeReport {
    camera_count: usize,
    selected_camera_id: String,
    selected_camera_label: String,
    selected_lens_facing: String,
    capture_bytes: usize,
    capture_mime_type: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct CameraPanelState {
    background_color: u32,
    accent_color: u32,
    lines: Vec<String>,
}

impl CameraPanelState {
    fn success(
        report: CameraProbeReport,
        lifecycle_state: LifecycleState,
        window_env: &AppWindowEnvironment,
    ) -> Self {
        Self {
            background_color: BACKGROUND_SUCCESS,
            accent_color: ACCENT_SUCCESS,
            lines: vec![
                String::from("shadow_sdk::services::camera ok"),
                format!("lifecycle: {}", lifecycle_state.as_str()),
                format!(
                    "surface: {}x{}",
                    window_env.surface_width, window_env.surface_height
                ),
                format!("safe area: {}", format_safe_area(window_env)),
                format!("cameras discovered: {}", report.camera_count),
                format!(
                    "selected: {} [{}]",
                    report.selected_camera_label, report.selected_camera_id
                ),
                format!("lens: {}", report.selected_lens_facing),
                format!(
                    "capture: {} bytes {}",
                    report.capture_bytes, report.capture_mime_type
                ),
            ],
        }
    }

    fn error(
        error: &str,
        lifecycle_state: LifecycleState,
        window_env: &AppWindowEnvironment,
    ) -> Self {
        Self {
            background_color: BACKGROUND_ERROR,
            accent_color: ACCENT_ERROR,
            lines: vec![
                String::from("shadow_sdk::services::camera error"),
                format!("lifecycle: {}", lifecycle_state.as_str()),
                format!(
                    "surface: {}x{}",
                    window_env.surface_width, window_env.surface_height
                ),
                format!("safe area: {}", format_safe_area(window_env)),
                error.trim().to_owned(),
            ],
        }
    }
}

struct App {
    camera_panel: CameraPanelState,
    window_env: AppWindowEnvironment,
    window: Option<WindowState>,
}

impl App {
    fn new(camera_panel: CameraPanelState, window_env: AppWindowEnvironment) -> Self {
        Self {
            camera_panel,
            window_env,
            window: None,
        }
    }
}

impl ApplicationHandler for App {
    fn can_create_surfaces(&mut self, event_loop: &dyn ActiveEventLoop) {
        let window = match event_loop.create_window(window_attributes(&self.window_env)) {
            Ok(window) => window,
            Err(error) => {
                eprintln!("shadow-rust-demo: failed to create window: {error}");
                event_loop.exit();
                return;
            }
        };
        let surface_size = window.surface_size();
        // The demo owns exactly one process-lifetime window, so leaking it avoids a self-referential
        // softbuffer setup while keeping the app logic small.
        let window: &'static dyn Window = Box::leak(window);
        let context = match Context::new(window) {
            Ok(context) => context,
            Err(error) => {
                eprintln!("shadow-rust-demo: failed to create softbuffer context: {error}");
                event_loop.exit();
                return;
            }
        };
        let mut surface = match Surface::new(&context, window) {
            Ok(surface) => surface,
            Err(error) => {
                eprintln!("shadow-rust-demo: failed to create softbuffer surface: {error}");
                event_loop.exit();
                return;
            }
        };
        if let Err(error) = resize_surface(&mut surface, surface_size) {
            eprintln!("shadow-rust-demo: failed to size softbuffer surface: {error}");
            event_loop.exit();
            return;
        }
        window.request_redraw();
        self.window = Some(WindowState {
            window,
            _context: context,
            surface,
            surface_size,
        });
    }

    fn window_event(
        &mut self,
        event_loop: &dyn ActiveEventLoop,
        window_id: WindowId,
        event: WindowEvent,
    ) {
        let Some(state) = self.window.as_mut() else {
            return;
        };
        if state.window.id() != window_id {
            return;
        }

        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::SurfaceResized(size) => {
                if let Err(error) = resize_surface(&mut state.surface, size) {
                    eprintln!("shadow-rust-demo: failed to resize surface: {error}");
                    event_loop.exit();
                    return;
                }
                state.surface_size = size;
                state.window.request_redraw();
            }
            WindowEvent::RedrawRequested => {
                state.window.pre_present_notify();
                if let Err(error) =
                    fill_surface(&mut state.surface, state.surface_size, &self.camera_panel)
                {
                    eprintln!("shadow-rust-demo: failed to draw frame: {error}");
                    event_loop.exit();
                }
            }
            _ => {}
        }
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    let window_env = window_environment();
    log_window_metrics(&window_env);
    let _lifecycle_listener = spawn_lifecycle_listener(|state| {
        eprintln!("shadow-rust-demo: lifecycle_state={}", state.as_str());
    })
    .ok();
    let camera_panel = load_camera_panel(&window_env);
    let event_loop = EventLoop::new()?;
    event_loop.set_control_flow(ControlFlow::Wait);
    event_loop.run_app(App::new(camera_panel, window_env))?;
    Ok(())
}

fn load_camera_panel(window_env: &AppWindowEnvironment) -> CameraPanelState {
    let lifecycle_state = current_lifecycle_state();
    match probe_camera_report() {
        Ok(report) => {
            eprintln!(
                "shadow-rust-demo: camera_probe=ok camera_count={} camera_id={} lens={} mime={}",
                report.camera_count,
                report.selected_camera_id,
                report.selected_lens_facing,
                report.capture_mime_type,
            );
            CameraPanelState::success(report, lifecycle_state, window_env)
        }
        Err(error) => {
            eprintln!(
                "shadow-rust-demo: camera_probe=error kind={:?} message={:?}",
                error.kind(),
                error.to_string(),
            );
            CameraPanelState::error(&error.to_string(), lifecycle_state, window_env)
        }
    }
}

fn probe_camera_report() -> Result<CameraProbeReport, CameraError> {
    let cameras = list_cameras()?;
    let selected_camera = cameras
        .first()
        .ok_or_else(|| CameraError::from(String::from("camera list returned no devices")))?;
    let capture =
        capture_still(CaptureRequest::default().with_camera_id(selected_camera.id.clone()))?;

    Ok(CameraProbeReport {
        camera_count: cameras.len(),
        selected_camera_id: capture.camera_id,
        selected_camera_label: selected_camera.label.clone(),
        selected_lens_facing: selected_camera.lens_facing.to_string(),
        capture_bytes: capture.bytes,
        capture_mime_type: capture.mime_type,
    })
}

fn window_attributes(window_env: &AppWindowEnvironment) -> WindowAttributes {
    let attributes = WindowAttributes::default()
        .with_title(window_env.title.clone())
        .with_resizable(false)
        .with_decorations(!window_env.undecorated)
        .with_surface_size(LogicalSize::new(
            f64::from(window_env.surface_width),
            f64::from(window_env.surface_height),
        ));

    #[cfg(target_os = "linux")]
    {
        let wayland_attributes = WindowAttributesWayland::default().with_name(
            window_env
                .wayland_app_id
                .clone()
                .expect("shadow-rust-demo defaults require a Wayland app id"),
            window_env
                .wayland_instance_name
                .clone()
                .expect("shadow-rust-demo defaults require a Wayland instance name"),
        );
        return attributes.with_platform_attributes(Box::new(wayland_attributes));
    }

    #[allow(unreachable_code)]
    attributes
}

fn window_environment() -> AppWindowEnvironment {
    AppWindowEnvironment::from_env(WINDOW_DEFAULTS)
}

fn format_safe_area(window_env: &AppWindowEnvironment) -> String {
    format!(
        "l{} t{} r{} b{}",
        window_env.safe_area_insets.left,
        window_env.safe_area_insets.top,
        window_env.safe_area_insets.right,
        window_env.safe_area_insets.bottom
    )
}

fn log_window_metrics(window_env: &AppWindowEnvironment) {
    eprintln!(
        "shadow-rust-demo: window_metrics surface={}x{} safe_area={}",
        window_env.surface_width,
        window_env.surface_height,
        format_safe_area(window_env)
    );
}

fn resize_surface(
    surface: &mut Surface<&'static dyn Window, &'static dyn Window>,
    size: PhysicalSize<u32>,
) -> Result<(), Box<dyn Error>> {
    let width = NonZeroU32::new(size.width.max(1)).expect("width should be non-zero");
    let height = NonZeroU32::new(size.height.max(1)).expect("height should be non-zero");
    surface.resize(width, height)?;
    Ok(())
}

fn fill_surface(
    surface: &mut Surface<&'static dyn Window, &'static dyn Window>,
    size: PhysicalSize<u32>,
    panel: &CameraPanelState,
) -> Result<(), Box<dyn Error>> {
    let mut buffer = surface.buffer_mut()?;
    let pixels = buffer.as_mut();
    let width = size.width.max(1) as usize;
    let height = size.height.max(1) as usize;

    pixels.fill(panel.background_color);
    draw_rect(
        pixels,
        width,
        height,
        0,
        0,
        width,
        ACCENT_BAR_HEIGHT_PX.min(height),
        panel.accent_color,
    );

    let max_chars = max_characters_per_line(width);
    let mut y = PANEL_PADDING_PX;
    for line in &panel.lines {
        for wrapped_line in wrap_text(line, max_chars) {
            if y + FONT_HEIGHT_PX > height {
                break;
            }
            draw_text(
                pixels,
                width,
                height,
                PANEL_PADDING_PX,
                y,
                &wrapped_line,
                TEXT_COLOR,
            );
            y += FONT_HEIGHT_PX + LINE_SPACING_PX;
        }
        y += LINE_SPACING_PX / 2;
    }

    buffer.present()?;
    Ok(())
}

fn max_characters_per_line(width: usize) -> usize {
    let available_width = width
        .saturating_sub(PANEL_PADDING_PX * 2)
        .max(FONT_WIDTH_PX);
    (available_width / FONT_WIDTH_PX).max(1)
}

fn wrap_text(text: &str, max_chars: usize) -> Vec<String> {
    if max_chars == 0 {
        return vec![text.trim().to_owned()];
    }

    let mut lines = Vec::new();
    for paragraph in text.lines() {
        let trimmed = paragraph.trim();
        if trimmed.is_empty() {
            lines.push(String::new());
            continue;
        }

        let mut current = String::new();
        for word in trimmed.split_whitespace() {
            if word.len() > max_chars {
                if !current.is_empty() {
                    lines.push(current);
                    current = String::new();
                }
                for chunk in word.as_bytes().chunks(max_chars) {
                    lines.push(String::from_utf8_lossy(chunk).into_owned());
                }
                continue;
            }

            let next_len = if current.is_empty() {
                word.len()
            } else {
                current.len() + 1 + word.len()
            };
            if next_len > max_chars && !current.is_empty() {
                lines.push(current);
                current = String::from(word);
            } else if current.is_empty() {
                current = String::from(word);
            } else {
                current.push(' ');
                current.push_str(word);
            }
        }

        if !current.is_empty() {
            lines.push(current);
        }
    }

    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

fn draw_rect(
    pixels: &mut [u32],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    rect_width: usize,
    rect_height: usize,
    color: u32,
) {
    let end_x = x.saturating_add(rect_width).min(width);
    let end_y = y.saturating_add(rect_height).min(height);
    for row in y.min(height)..end_y {
        let row_start = row * width;
        for column in x.min(width)..end_x {
            pixels[row_start + column] = color;
        }
    }
}

fn draw_text(
    pixels: &mut [u32],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    text: &str,
    color: u32,
) {
    for (index, character) in text.chars().enumerate() {
        let glyph_x = x + index * FONT_WIDTH_PX;
        draw_glyph(pixels, width, height, glyph_x, y, character, color);
    }
}

fn draw_glyph(
    pixels: &mut [u32],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    character: char,
    color: u32,
) {
    let Some(glyph) = BASIC_FONTS.get(character) else {
        return;
    };

    for (row, bits) in glyph.iter().enumerate() {
        for column in 0..8 {
            if (*bits & (1_u8 << column)) == 0 {
                continue;
            }
            for dy in 0..FONT_SCALE {
                for dx in 0..FONT_SCALE {
                    let pixel_x = x + column * FONT_SCALE + dx;
                    let pixel_y = y + row * FONT_SCALE + dy;
                    if pixel_x >= width || pixel_y >= height {
                        continue;
                    }
                    pixels[pixel_y * width + pixel_x] = color;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::probe_camera_report;
    use shadow_sdk::services::camera_backend::{
        clear_test_camera_env, test_camera_env_lock, CAMERA_ALLOW_MOCK_ENV, CAMERA_ENDPOINT_ENV,
    };

    #[test]
    fn probe_uses_the_shared_mock_camera_path() {
        let _guard = test_camera_env_lock().lock().expect("env lock");
        clear_test_camera_env();
        std::env::set_var(CAMERA_ALLOW_MOCK_ENV, "1");

        let report = probe_camera_report().expect("mock probe");
        assert_eq!(report.camera_count, 1);
        assert_eq!(report.selected_camera_id, "mock/rear/0");
        assert_eq!(report.selected_camera_label, "Mock Rear Camera");
        assert_eq!(report.selected_lens_facing, "rear");
        assert!(report.capture_bytes > 0);
        assert_eq!(report.capture_mime_type, "image/svg+xml");
    }

    #[test]
    fn probe_surfaces_backend_configuration_errors() {
        let _guard = test_camera_env_lock().lock().expect("env lock");
        clear_test_camera_env();

        let error = probe_camera_report().unwrap_err();
        assert!(error.to_string().contains(CAMERA_ENDPOINT_ENV));
        assert!(error.to_string().contains(CAMERA_ALLOW_MOCK_ENV));
    }
}
