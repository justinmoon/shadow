use std::{env, ffi::OsStr, path::Path, time::Duration};
const ORANGE_INIT_ROLE_SENTINEL: &str = "shadow-owned-init-role:orange-init";
const ORANGE_INIT_IMPL_SENTINEL: &str = "shadow-owned-init-impl:drm-rect-device";
const ORANGE_INIT_PATH_SENTINEL: &str = "shadow-owned-init-path:/orange-init";
const ORANGE_PREFLIGHT_PATHS: [&str; 4] = [
    "/dev/dri",
    "/dev/dri/card0",
    "/dev/dri/renderD128",
    "/sys/class/drm/card0/device",
];
const DEFAULT_VISUAL: &str = "default-solid";
const ORANGE_INIT_VISUAL: &str = "solid-orange";
const DEFAULT_STAGE: &str = "direct";

fn invoked_as_orange_init() -> bool {
    env::args_os()
        .next()
        .as_deref()
        .and_then(|arg0| Path::new(arg0).file_name())
        == Some(OsStr::new("orange-init"))
}

fn main() -> anyhow::Result<()> {
    drm_rect::emit_runtime_context(&ORANGE_PREFLIGHT_PATHS);

    if env::var("SHADOW_DRM_RECT_MODE").as_deref() == Ok("probe") {
        let paths = env::var("SHADOW_DRM_PROBE_PATHS")
            .unwrap_or_else(|_| "/dev/dri/card0:/dev/dri/renderD128".to_string());
        let paths = paths
            .split(':')
            .filter(|path| !path.is_empty())
            .collect::<Vec<_>>();
        drm_rect::log_line(&format!(
            "trace stage=probe-start paths={}",
            paths.join(":")
        ));
        let result = drm_rect::probe_nodes(&paths);
        if let Err(error) = &result {
            drm_rect::log_line(&format!("fatal probe error: {error:#}"));
        }
        return result;
    }

    let hold_secs = env::var("SHADOW_DRM_RECT_HOLD_SECS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(3);

    let orange_mode = env::var("SHADOW_DRM_RECT_MODE").as_deref() == Ok("orange-init")
        || invoked_as_orange_init();
    let stage = env::var("SHADOW_DRM_RECT_STAGE").unwrap_or_else(|_| DEFAULT_STAGE.to_string());
    let visual = env::var("SHADOW_DRM_RECT_VISUAL").unwrap_or_else(|_| {
        if orange_mode {
            ORANGE_INIT_VISUAL.to_string()
        } else {
            DEFAULT_VISUAL.to_string()
        }
    });

    if orange_mode {
        drm_rect::log_line(ORANGE_INIT_ROLE_SENTINEL);
        drm_rect::log_line(ORANGE_INIT_IMPL_SENTINEL);
        drm_rect::log_line(ORANGE_INIT_PATH_SENTINEL);
    }

    drm_rect::log_line(&format!(
        "trace stage=main-start mode={} stage_label={} hold_secs={} visual={}",
        if orange_mode {
            "orange-init"
        } else {
            "default"
        },
        stage,
        hold_secs,
        visual
    ));
    let result = drm_rect::fill_display_visual(&visual, Duration::from_secs(hold_secs));
    if let Err(error) = &result {
        drm_rect::log_line(&format!("fatal fill error: {error:#}"));
        let _ = drm_rect::probe_nodes(&["/dev/dri/card0", "/dev/dri/renderD128"]);
    }
    result
}
