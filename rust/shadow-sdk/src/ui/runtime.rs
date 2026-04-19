use masonry_winit::app::{self, MasonryUserEvent, NewWindow};
use xilem::masonry::theme::default_property_set;
use xilem::winit::dpi::LogicalSize;
use xilem::winit::error::EventLoopError;
#[cfg(target_os = "linux")]
use xilem::winit::platform::wayland::WindowAttributesExtWayland;
use xilem::{EventLoop, WidgetView, WindowOptions, Xilem};

use crate::app::{AppWindowDefaults, AppWindowEnvironment};

use super::Theme;

pub const PHONE_SURFACE_WIDTH: u32 = 540;
pub const PHONE_SURFACE_HEIGHT: u32 = 1042;

pub const fn phone_window_defaults(title: &'static str) -> AppWindowDefaults<'static> {
    AppWindowDefaults::new(title, PHONE_SURFACE_WIDTH, PHONE_SURFACE_HEIGHT).with_undecorated(true)
}

pub fn run<State, View>(
    state: State,
    logic: impl FnMut(&mut State) -> View + 'static,
    defaults: AppWindowDefaults<'static>,
) -> Result<(), EventLoopError>
where
    State: 'static,
    View: WidgetView<State>,
{
    run_with_env(state, logic, AppWindowEnvironment::from_env(defaults))
}

pub fn run_with_env<State, View>(
    state: State,
    logic: impl FnMut(&mut State) -> View + 'static,
    window_env: AppWindowEnvironment,
) -> Result<(), EventLoopError>
where
    State: 'static,
    View: WidgetView<State>,
{
    let app = Xilem::new_simple(state, logic, window_options(&window_env));
    let event_loop = EventLoop::with_user_event().build()?;
    let proxy = event_loop.create_proxy();
    let (driver, mut windows) = app.into_driver_and_windows(move |event: MasonryUserEvent| {
        proxy.send_event(event).map_err(|error| error.0)
    });
    let background = Theme::shadow_dark().background;

    for window in &mut windows {
        apply_window_env(window, &window_env);
        window.base_color = background;
    }

    app::run_with(event_loop, windows, driver, default_property_set())
}

fn window_options<State>(window_env: &AppWindowEnvironment) -> WindowOptions<State> {
    WindowOptions::new(window_env.title.clone())
        .with_initial_inner_size(LogicalSize::new(
            f64::from(window_env.surface_width),
            f64::from(window_env.surface_height),
        ))
        .with_resizable(false)
        .with_decorations(!window_env.undecorated)
}

#[cfg(target_os = "linux")]
fn apply_window_env(window: &mut NewWindow, window_env: &AppWindowEnvironment) {
    let app_id = window_env
        .wayland_app_id
        .as_deref()
        .unwrap_or("dev.shadow.app");
    let instance = window_env
        .wayland_instance_name
        .as_deref()
        .unwrap_or("shadow-app");
    let attrs = std::mem::take(&mut window.attributes);
    window.attributes = attrs.with_name(app_id, instance);
}

#[cfg(not(target_os = "linux"))]
fn apply_window_env(_window: &mut NewWindow, _window_env: &AppWindowEnvironment) {}

#[cfg(test)]
mod tests {
    use super::{phone_window_defaults, PHONE_SURFACE_HEIGHT, PHONE_SURFACE_WIDTH};

    #[test]
    fn phone_window_defaults_are_undecorated() {
        let defaults = phone_window_defaults("Phone");
        assert_eq!(defaults.surface_width, PHONE_SURFACE_WIDTH);
        assert_eq!(defaults.surface_height, PHONE_SURFACE_HEIGHT);
        assert!(defaults.undecorated);
    }
}
