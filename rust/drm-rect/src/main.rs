use std::{env, time::Duration};

fn main() -> anyhow::Result<()> {
    let hold_secs = env::var("SHADOW_DRM_RECT_HOLD_SECS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(3);
    drm_rect::fill_display((0x2a, 0xd0, 0xc9), Duration::from_secs(hold_secs))
}
