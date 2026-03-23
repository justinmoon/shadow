use std::time::Duration;

fn main() -> anyhow::Result<()> {
    drm_rect::fill_display((0x2a, 0xd0, 0xc9), Duration::from_secs(3))
}
