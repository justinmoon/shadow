use std::{
    ffi::OsStr,
    io,
    path::Path,
    process::{Child, Command},
};

use shadow_compositor_common::launch::{app_launch_env_value, first_env_value};
use shadow_ui_core::{
    app::{launch_spec, AppId, AppLaunchSpec},
    control,
    scene::{APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX},
};

use crate::{config::GuestClientConfig, ShadowGuestCompositor};

pub fn launch_app(state: &mut ShadowGuestCompositor, app_id: AppId) -> io::Result<Child> {
    let Some(app) = launch_spec(app_id) else {
        return Err(io::Error::new(io::ErrorKind::NotFound, "unknown demo app"));
    };
    let runtime_bundle_path = runtime_bundle_path_for_app(app, &state.client_config)?;

    let client_path = client_path_for_app(state, app);
    let mut command = Command::new(&client_path);
    for (key, value) in app.launch_env {
        command.env(key, app_launch_env_value(key, value));
    }
    configure_guest_client_command(
        &mut command,
        &state.client_config,
        state.control_socket_path.as_os_str(),
    )?;
    command
        .env(
            control::APP_PLATFORM_CONTROL_ENV,
            control::platform_control_socket_path(
                state
                    .control_socket_path
                    .parent()
                    .unwrap_or_else(|| Path::new(".")),
                app_id,
            ),
        )
        .env(
            control::LEGACY_APP_PLATFORM_CONTROL_ENV,
            control::platform_control_socket_path(
                state
                    .control_socket_path
                    .parent()
                    .unwrap_or_else(|| Path::new(".")),
                app_id,
            ),
        );
    apply_app_window_env(&mut command, app);
    if let Some(runtime_bundle_path) = runtime_bundle_path {
        command.env("SHADOW_RUNTIME_APP_BUNDLE_PATH", runtime_bundle_path);
    }
    apply_software_keyboard_policy(&mut command, state.software_keyboard_enabled);

    state.spawn_wayland_command(command, &client_path)
}

fn runtime_bundle_path_for_app(
    app: AppLaunchSpec,
    client_config: &GuestClientConfig,
) -> io::Result<Option<String>> {
    app.typescript_runtime()
        .map(|runtime| {
            std::env::var(runtime.bundle_env)
                .ok()
                .or_else(|| client_config_env_value(client_config, runtime.bundle_env))
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::NotFound,
                        format!("missing runtime bundle env {}", runtime.bundle_env),
                    )
                })
        })
        .transpose()
}

fn client_path_for_app(state: &ShadowGuestCompositor, app: AppLaunchSpec) -> String {
    let per_app_key = app_client_env_key(app.id);
    first_env_value(&[per_app_key.as_str(), "SHADOW_APP_CLIENT"])
        .or_else(|| client_config_env_value(&state.client_config, &per_app_key))
        .or_else(|| client_config_env_value(&state.client_config, "SHADOW_APP_CLIENT"))
        .unwrap_or_else(|| state.client_config.app_client_path.clone())
}

fn client_config_env_value(client_config: &GuestClientConfig, key: &str) -> Option<String> {
    client_config
        .env_assignments
        .iter()
        .rev()
        .find_map(|(candidate, value)| (candidate == key).then(|| value.clone()))
        .filter(|value| !value.is_empty())
}

fn app_client_env_key(app_id: AppId) -> String {
    let suffix = app_id
        .as_str()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect::<String>();
    format!("SHADOW_APP_CLIENT_{suffix}")
}

pub fn spawn_client(state: &mut ShadowGuestCompositor) -> io::Result<Child> {
    let client_path = state.client_config.app_client_path.clone();
    let mut command = Command::new(&client_path);
    configure_guest_client_command(
        &mut command,
        &state.client_config,
        state.control_socket_path.as_os_str(),
    )?;
    state.spawn_wayland_command(command, &client_path)
}

fn apply_software_keyboard_policy(command: &mut Command, enabled: bool) {
    command.env("SHADOW_GUEST_KEYBOARD_SEAT", "0").env(
        "SHADOW_BLITZ_SOFTWARE_KEYBOARD",
        if enabled { "1" } else { "0" },
    );
}

fn apply_app_window_env(command: &mut Command, app: AppLaunchSpec) {
    let surface_width = runtime_surface_width().to_string();
    let surface_height = runtime_surface_height().to_string();
    command
        .env("SHADOW_APP_TITLE", app.window_title)
        .env("SHADOW_APP_WAYLAND_APP_ID", app.wayland_app_id)
        .env("SHADOW_APP_WAYLAND_INSTANCE_NAME", app.id.as_str())
        .env("SHADOW_APP_SURFACE_WIDTH", &surface_width)
        .env("SHADOW_APP_SURFACE_HEIGHT", &surface_height)
        .env("SHADOW_BLITZ_SURFACE_WIDTH", surface_width)
        .env("SHADOW_BLITZ_SURFACE_HEIGHT", surface_height)
        .env("SHADOW_BLITZ_UNDECORATED", "1")
        .env("SHADOW_BLITZ_ANDROID_FONTS", "curated")
        .env("SHADOW_APP_SAFE_AREA_LEFT", "0")
        .env("SHADOW_APP_SAFE_AREA_TOP", "0")
        .env("SHADOW_APP_SAFE_AREA_RIGHT", "0")
        .env("SHADOW_APP_SAFE_AREA_BOTTOM", "0")
        .env("SHADOW_APP_LIFECYCLE_STATE", "foreground");
}

fn runtime_surface_width() -> u32 {
    APP_VIEWPORT_WIDTH_PX
}

fn runtime_surface_height() -> u32 {
    APP_VIEWPORT_HEIGHT_PX
}

fn configure_guest_client_command(
    command: &mut Command,
    client_config: &crate::config::GuestClientConfig,
    control_socket_path: &OsStr,
) -> io::Result<()> {
    command
        .env("XDG_RUNTIME_DIR", &client_config.runtime_dir)
        .env(control::COMPOSITOR_CONTROL_ENV, control_socket_path);

    if let Some(value) = &client_config.system_binary_path {
        command.env("SHADOW_SYSTEM_BINARY_PATH", value);
    }
    for (key, value) in &client_config.env_assignments {
        command.env(key, value);
    }
    if client_config.exit_on_configure {
        command.env("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE", "1");
    }
    if let Some(value) = client_config.linger_ms {
        command.env("SHADOW_GUEST_CLIENT_LINGER_MS", value.to_string());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        app_client_env_key, apply_app_window_env, apply_software_keyboard_policy,
        configure_guest_client_command, runtime_bundle_path_for_app, runtime_surface_height,
        runtime_surface_width,
    };
    use crate::config::GuestClientConfig;
    use shadow_ui_core::{
        app::{self, AppId, AppLaunchModel, AppLaunchSpec},
        control,
        scene::{APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX},
    };
    use std::{
        ffi::{OsStr, OsString},
        path::PathBuf,
        process::Command,
        sync::{Mutex, OnceLock},
    };

    fn env_value(command: &Command, key: &str) -> Option<OsString> {
        command.get_envs().find_map(|(env_key, value)| {
            if env_key == OsStr::new(key) {
                value.map(|value| value.to_os_string())
            } else {
                None
            }
        })
    }

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn with_env<T>(key: &str, value: Option<&str>, check: impl FnOnce() -> T) -> T {
        let _guard = env_lock().lock().unwrap_or_else(|error| error.into_inner());
        let previous = std::env::var_os(key);
        match value {
            Some(value) => unsafe {
                std::env::set_var(key, value);
            },
            None => unsafe {
                std::env::remove_var(key);
            },
        }

        let result = check();

        match previous {
            Some(value) => unsafe {
                std::env::set_var(key, value);
            },
            None => unsafe {
                std::env::remove_var(key);
            },
        }
        result
    }

    fn client_config(env_assignments: Vec<(String, String)>) -> GuestClientConfig {
        GuestClientConfig {
            app_client_path: "/tmp/shadow-client".into(),
            runtime_dir: PathBuf::from("/tmp/shadow-runtime"),
            system_binary_path: None,
            env_assignments,
            exit_on_configure: false,
            linger_ms: None,
        }
    }

    #[test]
    fn configure_guest_client_command_sets_configured_runtime_env() {
        let mut client_config =
            client_config(vec![("A".into(), "1".into()), ("B".into(), "two".into())]);
        client_config.system_binary_path = Some("/tmp/shadow-system".into());
        client_config.exit_on_configure = true;
        client_config.linger_ms = Some(25);
        let mut command = Command::new("env");

        configure_guest_client_command(&mut command, &client_config, OsStr::new("/tmp/control"))
            .expect("guest client command");

        assert_eq!(
            env_value(&command, "XDG_RUNTIME_DIR"),
            Some(OsString::from("/tmp/shadow-runtime"))
        );
        assert_eq!(
            env_value(&command, control::COMPOSITOR_CONTROL_ENV),
            Some(OsString::from("/tmp/control"))
        );
        assert_eq!(
            env_value(&command, "SHADOW_SYSTEM_BINARY_PATH"),
            Some(OsString::from("/tmp/shadow-system"))
        );
        assert_eq!(env_value(&command, "A"), Some(OsString::from("1")));
        assert_eq!(env_value(&command, "B"), Some(OsString::from("two")));
        assert_eq!(
            env_value(&command, "SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE"),
            Some(OsString::from("1"))
        );
        assert_eq!(
            env_value(&command, "SHADOW_GUEST_CLIENT_LINGER_MS"),
            Some(OsString::from("25"))
        );
    }

    #[test]
    fn runtime_bundle_path_for_typescript_app_reads_client_config_env_assignment() {
        let app = app::launch_spec(app::COUNTER_APP_ID).expect("counter app");
        let runtime = app.typescript_runtime().expect("typescript runtime");
        let client_config = client_config(vec![(
            runtime.bundle_env.to_string(),
            "/runtime/counter-bundle.js".to_string(),
        )]);

        with_env(runtime.bundle_env, None, || {
            assert_eq!(
                runtime_bundle_path_for_app(app, &client_config).expect("runtime bundle path"),
                Some("/runtime/counter-bundle.js".to_string())
            );
        });
    }

    #[test]
    fn runtime_bundle_path_for_typescript_app_prefers_process_env() {
        let app = app::launch_spec(app::COUNTER_APP_ID).expect("counter app");
        let runtime = app.typescript_runtime().expect("typescript runtime");
        let client_config = client_config(vec![(
            runtime.bundle_env.to_string(),
            "/runtime/config-bundle.js".to_string(),
        )]);

        with_env(
            runtime.bundle_env,
            Some("/runtime/process-bundle.js"),
            || {
                assert_eq!(
                    runtime_bundle_path_for_app(app, &client_config).expect("runtime bundle path"),
                    Some("/runtime/process-bundle.js".to_string())
                );
            },
        );
    }

    #[test]
    fn runtime_bundle_path_for_rust_app_is_not_required() {
        let app = app::launch_spec(app::RUST_DEMO_APP_ID).expect("rust demo app");
        let client_config = client_config(Vec::new());

        assert_eq!(
            runtime_bundle_path_for_app(app, &client_config).expect("runtime bundle path"),
            None
        );
    }

    #[test]
    fn apply_software_keyboard_policy_sets_explicit_guest_defaults() {
        let mut command = Command::new("env");
        apply_software_keyboard_policy(&mut command, true);

        assert_eq!(
            env_value(&command, "SHADOW_GUEST_KEYBOARD_SEAT"),
            Some(OsString::from("0"))
        );
        assert_eq!(
            env_value(&command, "SHADOW_BLITZ_SOFTWARE_KEYBOARD"),
            Some(OsString::from("1"))
        );
    }

    #[test]
    fn apply_software_keyboard_policy_can_disable_software_keyboard() {
        let mut command = Command::new("env");
        apply_software_keyboard_policy(&mut command, false);

        assert_eq!(
            env_value(&command, "SHADOW_BLITZ_SOFTWARE_KEYBOARD"),
            Some(OsString::from("0"))
        );
    }

    #[test]
    fn apply_app_window_env_seeds_runtime_window_metrics() {
        let mut command = Command::new("env");
        let app = AppLaunchSpec {
            id: AppId::new("counter"),
            binary_name: "shadow-blitz-demo",
            wayland_app_id: "dev.shadow.counter",
            window_title: "Shadow Counter",
            model: AppLaunchModel::Rust,
            launch_env: &[],
        };

        apply_app_window_env(&mut command, app);

        assert_eq!(
            env_value(&command, "SHADOW_APP_TITLE"),
            Some(OsString::from("Shadow Counter"))
        );
        assert_eq!(
            env_value(&command, "SHADOW_APP_WAYLAND_APP_ID"),
            Some(OsString::from("dev.shadow.counter"))
        );
        assert_eq!(
            env_value(&command, "SHADOW_APP_SURFACE_WIDTH"),
            Some(OsString::from(APP_VIEWPORT_WIDTH_PX.to_string()))
        );
        assert_eq!(
            env_value(&command, "SHADOW_APP_SURFACE_HEIGHT"),
            Some(OsString::from(APP_VIEWPORT_HEIGHT_PX.to_string()))
        );
        assert_eq!(
            env_value(&command, "SHADOW_BLITZ_SURFACE_WIDTH"),
            Some(OsString::from(APP_VIEWPORT_WIDTH_PX.to_string()))
        );
        assert_eq!(
            env_value(&command, "SHADOW_BLITZ_SURFACE_HEIGHT"),
            Some(OsString::from(APP_VIEWPORT_HEIGHT_PX.to_string()))
        );
        assert_eq!(
            env_value(&command, "SHADOW_BLITZ_UNDECORATED"),
            Some(OsString::from("1"))
        );
        assert_eq!(
            env_value(&command, "SHADOW_BLITZ_ANDROID_FONTS"),
            Some(OsString::from("curated"))
        );
        assert_eq!(
            env_value(&command, "SHADOW_APP_SAFE_AREA_TOP"),
            Some(OsString::from("0"))
        );
        assert_eq!(
            env_value(&command, "SHADOW_APP_LIFECYCLE_STATE"),
            Some(OsString::from("foreground"))
        );
    }

    #[test]
    fn runtime_surface_dimensions_match_shell_viewport() {
        assert_eq!(runtime_surface_width(), APP_VIEWPORT_WIDTH_PX);
        assert_eq!(runtime_surface_height(), APP_VIEWPORT_HEIGHT_PX);
    }

    #[test]
    fn app_client_env_key_is_stable_for_hyphenated_ids() {
        assert_eq!(
            app_client_env_key(AppId::new("rust-demo")),
            "SHADOW_APP_CLIENT_RUST_DEMO"
        );
    }
}
