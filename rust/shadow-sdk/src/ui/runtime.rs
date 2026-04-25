use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use masonry_winit::app::{self, MasonryUserEvent, NewWindow};
use xilem::masonry::theme::default_property_set;
use xilem::winit::dpi::LogicalSize;
use xilem::winit::error::EventLoopError;
#[cfg(target_os = "linux")]
use xilem::winit::platform::wayland::WindowAttributesExtWayland;
use xilem::{EventLoop, WidgetView, WindowOptions, Xilem};

use crate::app::{AppWindowDefaults, AppWindowEnvironment};

use super::theme::Theme;

pub const PHONE_SURFACE_WIDTH: u32 = 540;
pub const PHONE_SURFACE_HEIGHT: u32 = 1042;

const RUST_UI_FONT_DIR_ENV: &str = "SHADOW_RUST_UI_FONT_DIR";
const BLITZ_FONT_DIR_ENV: &str = "SHADOW_BLITZ_FONT_DIR";
const BOOT_CURATED_FONT_DIR: &str = "/orange-gpu/system/fonts";
const ANDROID_SYSTEM_FONT_DIR: &str = "/system/fonts";
const CURATED_ANDROID_FONT_NAMES: &[&str] = &[
    "DroidSans.ttf",
    "DroidSans-Bold.ttf",
    "DroidSansMono.ttf",
    "NotoColorEmoji.ttf",
];

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
    let mut app = Xilem::new_simple(state, logic, window_options(&window_env));
    let curated_fonts = load_curated_android_fonts();
    if !curated_fonts.is_empty() {
        eprintln!(
            "shadow-rust-ui: registered-curated-android-fonts count={}",
            curated_fonts.len()
        );
    }
    for font in curated_fonts {
        app = app.with_font(font);
    }
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

fn load_curated_android_fonts() -> Vec<Vec<u8>> {
    let Some(font_files) = curated_android_font_files() else {
        return Vec::new();
    };

    font_files
        .into_iter()
        .filter_map(|path| match fs::read(&path) {
            Ok(bytes) => Some(bytes),
            Err(error) => {
                eprintln!(
                    "shadow-rust-ui: curated-font-read-failed path={} error={error}",
                    path.display()
                );
                None
            }
        })
        .collect()
}

fn curated_android_font_files() -> Option<Vec<PathBuf>> {
    curated_android_font_dirs()
        .into_iter()
        .find_map(|dir| curated_font_files_in_dir(&dir))
}

fn curated_android_font_dirs() -> Vec<PathBuf> {
    curated_android_font_dirs_from_env(
        env::var_os(RUST_UI_FONT_DIR_ENV),
        env::var_os(BLITZ_FONT_DIR_ENV),
    )
}

fn curated_android_font_dirs_from_env(
    rust_font_dir: Option<std::ffi::OsString>,
    blitz_font_dir: Option<std::ffi::OsString>,
) -> Vec<PathBuf> {
    let mut dirs = Vec::new();

    push_env_dirs(&mut dirs, rust_font_dir);
    push_env_dirs(&mut dirs, blitz_font_dir);
    push_unique_dir(&mut dirs, PathBuf::from(BOOT_CURATED_FONT_DIR));
    push_unique_dir(&mut dirs, PathBuf::from(ANDROID_SYSTEM_FONT_DIR));

    dirs
}

fn push_env_dirs(dirs: &mut Vec<PathBuf>, value: Option<std::ffi::OsString>) {
    let Some(value) = value else {
        return;
    };

    for dir in env::split_paths(&value) {
        push_unique_dir(dirs, dir);
    }
}

fn push_unique_dir(dirs: &mut Vec<PathBuf>, dir: PathBuf) {
    if dir.as_os_str().is_empty() || dirs.iter().any(|existing| existing == &dir) {
        return;
    }
    dirs.push(dir);
}

fn curated_font_files_in_dir(dir: &Path) -> Option<Vec<PathBuf>> {
    let files = CURATED_ANDROID_FONT_NAMES
        .iter()
        .map(|name| dir.join(name))
        .collect::<Vec<_>>();
    files.iter().all(|path| path.is_file()).then_some(files)
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::path::PathBuf;

    use super::{
        curated_android_font_dirs_from_env, phone_window_defaults, ANDROID_SYSTEM_FONT_DIR,
        BLITZ_FONT_DIR_ENV, BOOT_CURATED_FONT_DIR, PHONE_SURFACE_HEIGHT, PHONE_SURFACE_WIDTH,
        RUST_UI_FONT_DIR_ENV,
    };

    #[test]
    fn phone_window_defaults_are_undecorated() {
        let defaults = phone_window_defaults("Phone");
        assert_eq!(defaults.surface_width, PHONE_SURFACE_WIDTH);
        assert_eq!(defaults.surface_height, PHONE_SURFACE_HEIGHT);
        assert!(defaults.undecorated);
    }

    #[test]
    fn curated_font_dirs_prefer_rust_specific_env_then_blitz_env() {
        let dirs = curated_android_font_dirs_from_env(
            Some(OsString::from("/tmp/rust-fonts")),
            Some(OsString::from("/tmp/blitz-fonts")),
        );

        assert_eq!(
            dirs,
            vec![
                PathBuf::from("/tmp/rust-fonts"),
                PathBuf::from("/tmp/blitz-fonts"),
                PathBuf::from(BOOT_CURATED_FONT_DIR),
                PathBuf::from(ANDROID_SYSTEM_FONT_DIR),
            ]
        );
    }

    #[test]
    fn curated_font_dirs_deduplicate_env_and_fallbacks() {
        let dirs = curated_android_font_dirs_from_env(
            Some(OsString::from(BOOT_CURATED_FONT_DIR)),
            Some(OsString::from(ANDROID_SYSTEM_FONT_DIR)),
        );

        assert_eq!(
            dirs,
            vec![
                PathBuf::from(BOOT_CURATED_FONT_DIR),
                PathBuf::from(ANDROID_SYSTEM_FONT_DIR),
            ]
        );
    }

    #[test]
    fn rust_and_blitz_font_dir_env_names_are_stable() {
        assert_eq!(RUST_UI_FONT_DIR_ENV, "SHADOW_RUST_UI_FONT_DIR");
        assert_eq!(BLITZ_FONT_DIR_ENV, "SHADOW_BLITZ_FONT_DIR");
    }
}
