use std::{env, ffi::OsStr, path::Path, time::Duration};

const DEFAULT_COLOR: (u8, u8, u8) = (0x2a, 0xd0, 0xc9);
const ORANGE_INIT_COLOR: (u8, u8, u8) = (0xff, 0x7a, 0x00);
const ORANGE_INIT_ROLE_SENTINEL: &str = "shadow-owned-init-role:orange-init";
const ORANGE_INIT_IMPL_SENTINEL: &str = "shadow-owned-init-impl:drm-rect-device";
const ORANGE_INIT_PATH_SENTINEL: &str = "shadow-owned-init-path:/orange-init";
const ORANGE_PREFLIGHT_PATHS: [&str; 4] = [
    "/dev/dri",
    "/dev/dri/card0",
    "/dev/dri/renderD128",
    "/sys/class/drm/card0/device",
];

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

    let color = if env::var("SHADOW_DRM_RECT_MODE").as_deref() == Ok("orange-init")
        || invoked_as_orange_init()
    {
        drm_rect::log_line(ORANGE_INIT_ROLE_SENTINEL);
        drm_rect::log_line(ORANGE_INIT_IMPL_SENTINEL);
        drm_rect::log_line(ORANGE_INIT_PATH_SENTINEL);
        ORANGE_INIT_COLOR
    } else {
        DEFAULT_COLOR
    };

    drm_rect::log_line(&format!(
        "trace stage=main-start mode={} hold_secs={} color=#{:02x}{:02x}{:02x}",
        if color == ORANGE_INIT_COLOR {
            "orange-init"
        } else {
            "default"
        },
        hold_secs,
        color.0,
        color.1,
        color.2
    ));
    let result = drm_rect::fill_display(color, Duration::from_secs(hold_secs));
    if let Err(error) = &result {
        drm_rect::log_line(&format!("fatal fill error: {error:#}"));
        let _ = drm_rect::probe_nodes(&["/dev/dri/card0", "/dev/dri/renderD128"]);
    }
    result
}
