#![warn(clippy::all, clippy::pedantic)]

use anyhow::{Context, Result, anyhow};
use drm::Device as BasicDevice;
use drm::buffer::DrmFourcc;
use drm::control::dumbbuffer::DumbBuffer;
use drm::control::{Device as ControlDevice, connector};
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::io::{AsFd, BorrowedFd};
use std::time::Duration;

pub fn fill_display(color: (u8, u8, u8), duration: Duration) -> Result<()> {
    log_line("starting");

    let mut card = open_card("/dev/dri/card0")?;
    card.acquire_master_lock()
        .context("failed to acquire DRM master lock")?;
    let res_handles = card
        .resource_handles()
        .context("failed to fetch DRM resource handles")?;

    let connector_info = find_connected_connector(&card, &res_handles)?;
    let connector_handle = connector_info.handle();
    let mode = connector_info
        .modes()
        .first()
        .copied()
        .ok_or_else(|| anyhow!("connected connector {connector_handle:?} reported no modes"))?;
    log_line(&format!(
        "using connector {connector_handle:?} mode={}x{}@{}",
        mode.size().0,
        mode.size().1,
        mode.vrefresh()
    ));

    let encoder_handle = connector_info
        .current_encoder()
        .or_else(|| connector_info.encoders().first().copied())
        .ok_or_else(|| anyhow!("connector {connector_handle:?} reported no encoder"))?;
    let encoder = card
        .get_encoder(encoder_handle)
        .with_context(|| format!("failed to query encoder {encoder_handle:?}"))?;
    let crtc_handle = encoder
        .crtc()
        .ok_or_else(|| anyhow!("encoder {encoder_handle:?} reported no CRTC"))?;

    let (width, height) = mode.size();
    let width = u32::from(width);
    let height = u32::from(height);
    let mut dumb = card
        .create_dumb_buffer((width, height), DrmFourcc::Xrgb8888, 32)
        .context("failed to allocate dumb buffer")?;

    let fb_handle = card
        .add_framebuffer(&dumb, 24, 32)
        .context("failed to create framebuffer")?;

    fill_buffer_with_color(&mut card, &mut dumb, color).context("failed to fill dumb buffer")?;

    card.set_crtc(
        crtc_handle,
        Some(fb_handle),
        (0, 0),
        &[connector_handle],
        Some(mode),
    )
    .context("failed to set CRTC configuration")?;
    log_line("success");

    std::thread::sleep(duration);

    if let Err(error) = card.set_crtc(crtc_handle, None, (0, 0), &[], None) {
        log_line(&format!("failed to clear crtc: {error}"));
    }

    if let Err(error) = card.release_master_lock() {
        log_line(&format!("failed to release DRM master lock: {error}"));
    }

    card.destroy_framebuffer(fb_handle)
        .context("failed to destroy framebuffer")?;
    card.destroy_dumb_buffer(dumb)
        .context("failed to destroy dumb buffer")?;

    Ok(())
}

fn log_line(message: &str) {
    let line = format!("[shadow-drm] {message}\n");
    let _ = std::io::stdout().write_all(line.as_bytes());
    let _ = std::io::stderr().write_all(line.as_bytes());

    if let Ok(mut file) = OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = file.write_all(format!("<6>[shadow-drm] {message}\n").as_bytes());
        let _ = file.flush();
    }
}

fn open_card(path: &str) -> Result<Card> {
    log_line(&format!("opening {path}"));
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .with_context(|| format!("failed to open {path}"))?;
    Ok(Card(file))
}

struct Card(std::fs::File);

impl AsFd for Card {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }
}

impl BasicDevice for Card {}
impl ControlDevice for Card {}

fn find_connected_connector(
    card: &Card,
    res_handles: &drm::control::ResourceHandles,
) -> Result<drm::control::connector::Info> {
    for handle in res_handles.connectors() {
        let info = card
            .get_connector(*handle, true)
            .with_context(|| format!("failed to query connector {handle:?}"))?;
        if info.state() == connector::State::Connected && !info.modes().is_empty() {
            return Ok(info);
        }
    }

    Err(anyhow!(
        "no connected connector with available modes was found"
    ))
}

fn fill_buffer_with_color(card: &mut Card, dumb: &mut DumbBuffer, rgb: (u8, u8, u8)) -> Result<()> {
    let (r, g, b) = rgb;
    let mut mapping = card
        .map_dumb_buffer(dumb)
        .context("failed to map dumb buffer")?;

    for pixel in mapping.as_mut().chunks_exact_mut(4) {
        pixel[0] = b;
        pixel[1] = g;
        pixel[2] = r;
        pixel[3] = 0xFF;
    }

    Ok(())
}
