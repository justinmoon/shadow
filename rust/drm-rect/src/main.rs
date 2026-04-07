use std::{env, time::Duration};

fn main() -> anyhow::Result<()> {
    if env::var("SHADOW_DRM_RECT_MODE").as_deref() == Ok("probe") {
        let paths = env::var("SHADOW_DRM_PROBE_PATHS")
            .unwrap_or_else(|_| "/dev/dri/card0:/dev/dri/renderD128".to_string());
        let paths = paths
            .split(':')
            .filter(|path| !path.is_empty())
            .collect::<Vec<_>>();
        return drm_rect::probe_nodes(&paths);
    }

    let hold_secs = env::var("SHADOW_DRM_RECT_HOLD_SECS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(3);
    drm_rect::fill_display((0x2a, 0xd0, 0xc9), Duration::from_secs(hold_secs))
}
