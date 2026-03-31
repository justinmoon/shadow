use anyhow::{anyhow, Context, Result};
use drm::buffer::{Buffer as DrmBuffer, DrmFourcc};
use drm::control::Device as ControlDevice;
use drm::control::{connector, crtc, dumbbuffer::DumbBuffer, framebuffer};
use drm::Device as BasicDevice;
use smithay::reexports::wayland_server::protocol::wl_shm;
use smithay::wayland::shm::BufferData;
use std::fs;
use std::fs::OpenOptions;
use std::os::fd::{AsFd, BorrowedFd};
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

const DRM_DEVICE_PATH: &str = "/dev/dri/card0";
const BYTES_PER_PIXEL: usize = 4;
const BACKGROUND_PIXEL: [u8; 4] = [0x18, 0x12, 0x10, 0xFF];
const SELFTEST_BORDER_PX: u32 = 24;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapturedFrame {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: wl_shm::Format,
    pub pixels: Vec<u8>,
}

pub fn capture_shm_frame(ptr: *const u8, len: usize, data: BufferData) -> Result<CapturedFrame> {
    let width = u32::try_from(data.width).context("negative shm width")?;
    let height = u32::try_from(data.height).context("negative shm height")?;
    let stride = u32::try_from(data.stride).context("negative shm stride")?;
    let offset = usize::try_from(data.offset).context("negative shm offset")?;
    let frame_len = usize::try_from(u64::from(stride) * u64::from(height))
        .context("frame size overflowed usize")?;

    if !matches!(
        data.format,
        wl_shm::Format::Argb8888 | wl_shm::Format::Xrgb8888
    ) {
        return Err(anyhow!("unsupported shm format: {:?}", data.format));
    }

    if offset > len || frame_len > len - offset {
        return Err(anyhow!(
            "buffer range out of bounds: offset={offset} frame_len={frame_len} len={len}"
        ));
    }

    let mut pixels = vec![0_u8; frame_len];
    // Copy out of shared memory immediately; do not retain references into client-owned memory.
    unsafe {
        std::ptr::copy_nonoverlapping(ptr.add(offset), pixels.as_mut_ptr(), frame_len);
    }

    Ok(CapturedFrame {
        width,
        height,
        stride,
        format: data.format,
        pixels,
    })
}

pub fn frame_checksum(frame: &CapturedFrame) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in &frame.pixels {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

pub fn write_frame_ppm(frame: &CapturedFrame, path: impl AsRef<Path>) -> Result<()> {
    let path = path.as_ref();
    let width = usize::try_from(frame.width).context("frame width overflowed usize")?;
    let height = usize::try_from(frame.height).context("frame height overflowed usize")?;
    let stride = usize::try_from(frame.stride).context("frame stride overflowed usize")?;
    let mut ppm = Vec::with_capacity(width * height * 3 + 64);
    ppm.extend_from_slice(format!("P6\n{} {}\n255\n", frame.width, frame.height).as_bytes());

    for row in 0..height {
        let row_start = row
            .checked_mul(stride)
            .context("row offset overflowed for ppm export")?;
        let row_end = row_start
            .checked_add(width * BYTES_PER_PIXEL)
            .context("row end overflowed for ppm export")?;
        let row_pixels = frame
            .pixels
            .get(row_start..row_end)
            .ok_or_else(|| anyhow!("row slice out of bounds during ppm export"))?;
        for pixel in row_pixels.chunks_exact(BYTES_PER_PIXEL) {
            ppm.push(pixel[2]);
            ppm.push(pixel[1]);
            ppm.push(pixel[0]);
        }
    }

    fs::write(path, ppm)
        .with_context(|| format!("failed to write ppm artifact to {}", path.display()))
}

pub fn build_selftest_frame(width: u32, height: u32) -> CapturedFrame {
    let stride = width * BYTES_PER_PIXEL as u32;
    let mut pixels = vec![0_u8; usize::try_from(u64::from(stride) * u64::from(height)).unwrap()];

    for y in 0..height {
        for x in 0..width {
            let border = x < SELFTEST_BORDER_PX
                || y < SELFTEST_BORDER_PX
                || x >= width.saturating_sub(SELFTEST_BORDER_PX)
                || y >= height.saturating_sub(SELFTEST_BORDER_PX);

            let (r, g, b) = if border {
                (0xFF, 0xFF, 0xFF)
            } else if y < height / 3 {
                (0xFF, 0x8A, 0x1A)
            } else if y < (height * 2) / 3 {
                (0x08, 0xE8, 0xFF)
            } else {
                (0xFF, 0x2D, 0x55)
            };

            let offset = (usize::try_from(y).unwrap() * usize::try_from(stride).unwrap())
                + (usize::try_from(x).unwrap() * BYTES_PER_PIXEL);
            pixels[offset] = b;
            pixels[offset + 1] = g;
            pixels[offset + 2] = r;
            pixels[offset + 3] = 0xFF;
        }
    }

    CapturedFrame {
        width,
        height,
        stride,
        format: wl_shm::Format::Xrgb8888,
        pixels,
    }
}

pub struct KmsDisplay {
    card: Card,
    master_locked: bool,
    connector_handle: connector::Handle,
    crtc_handle: crtc::Handle,
    mode: drm::control::Mode,
    dumb: Option<DumbBuffer>,
    fb_handle: Option<framebuffer::Handle>,
    width: u32,
    height: u32,
}

impl KmsDisplay {
    pub fn open_default() -> Result<Self> {
        let card = open_card(DRM_DEVICE_PATH)?;
        let master_locked = acquire_master_lock_if_supported(&card)?;
        let res_handles = card
            .resource_handles()
            .context("failed to fetch DRM resource handles")?;

        let connector_info = find_connected_connector(&card, &res_handles)?;
        let connector_handle = connector_info.handle();
        let mode =
            connector_info.modes().first().copied().ok_or_else(|| {
                anyhow!("connected connector {connector_handle:?} reported no modes")
            })?;

        let encoder_handle = connector_info
            .current_encoder()
            .or_else(|| connector_info.encoders().first().copied())
            .ok_or_else(|| anyhow!("connector {connector_handle:?} reported no encoder"))?;
        let encoder = card
            .get_encoder(encoder_handle)
            .with_context(|| format!("failed to query encoder {encoder_handle:?}"))?;
        let crtc_handle =
            select_crtc_handle(&encoder, &res_handles, connector_handle, encoder_handle)?;

        let (width, height) = mode.size();
        let width = u32::from(width);
        let height = u32::from(height);
        let dumb = card
            .create_dumb_buffer((width, height), DrmFourcc::Xrgb8888, 32)
            .context("failed to allocate dumb buffer")?;
        let fb_handle = card
            .add_framebuffer(&dumb, 24, 32)
            .context("failed to create framebuffer")?;

        let mut display = Self {
            card,
            master_locked,
            connector_handle,
            crtc_handle,
            mode,
            dumb: Some(dumb),
            fb_handle: Some(fb_handle),
            width,
            height,
        };

        display.clear()?;
        display.program_crtc()?;

        Ok(display)
    }

    pub fn open_when_ready(timeout: Duration) -> Result<Self> {
        let deadline = Instant::now() + timeout;
        let mut last_error;

        loop {
            match Self::open_default() {
                Ok(display) => return Ok(display),
                Err(error) => last_error = error,
            }

            if Instant::now() >= deadline {
                return Err(last_error);
            }

            thread::sleep(Duration::from_millis(200));
        }
    }

    pub fn mode_summary(&self) -> String {
        format!("{}x{}@{}", self.width, self.height, self.mode.vrefresh())
    }

    pub fn dimensions(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    pub fn present_frame(&mut self, frame: &CapturedFrame) -> Result<()> {
        let dumb = self
            .dumb
            .as_mut()
            .ok_or_else(|| anyhow!("dumb buffer missing"))?;
        let pitch = usize::try_from(dumb.pitch()).context("invalid dumb buffer pitch")?;
        let mut mapping = self
            .card
            .map_dumb_buffer(dumb)
            .context("failed to map dumb buffer")?;

        clear_framebuffer(mapping.as_mut());
        blit_frame_centered(mapping.as_mut(), self.width, self.height, pitch, frame)?;
        drop(mapping);
        self.program_crtc()?;
        Ok(())
    }

    fn clear(&mut self) -> Result<()> {
        let dumb = self
            .dumb
            .as_mut()
            .ok_or_else(|| anyhow!("dumb buffer missing"))?;
        let mut mapping = self
            .card
            .map_dumb_buffer(dumb)
            .context("failed to map dumb buffer")?;
        clear_framebuffer(mapping.as_mut());
        Ok(())
    }

    fn program_crtc(&mut self) -> Result<()> {
        let fb_handle = self
            .fb_handle
            .ok_or_else(|| anyhow!("framebuffer handle missing after initialization"))?;
        self.card
            .set_crtc(
                self.crtc_handle,
                Some(fb_handle),
                (0, 0),
                &[self.connector_handle],
                Some(self.mode),
            )
            .context("failed to set CRTC configuration")
    }
}

impl Drop for KmsDisplay {
    fn drop(&mut self) {
        if self.master_locked {
            let _ = self.card.release_master_lock();
        }
        if let Some(fb_handle) = self.fb_handle.take() {
            let _ = self.card.destroy_framebuffer(fb_handle);
        }
        if let Some(dumb) = self.dumb.take() {
            let _ = self.card.destroy_dumb_buffer(dumb);
        }
    }
}

fn clear_framebuffer(framebuffer: &mut [u8]) {
    for pixel in framebuffer.chunks_exact_mut(BYTES_PER_PIXEL) {
        pixel.copy_from_slice(&BACKGROUND_PIXEL);
    }
}

fn select_crtc_handle(
    encoder: &drm::control::encoder::Info,
    res_handles: &drm::control::ResourceHandles,
    connector_handle: connector::Handle,
    encoder_handle: drm::control::encoder::Handle,
) -> Result<crtc::Handle> {
    encoder
        .crtc()
        .or_else(|| {
            res_handles
                .filter_crtcs(encoder.possible_crtcs())
                .into_iter()
                .next()
        })
        .ok_or_else(|| {
            anyhow!(
                "connector {connector_handle:?} encoder {encoder_handle:?} reported no usable CRTC"
            )
        })
}

fn blit_frame_centered(
    framebuffer: &mut [u8],
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_stride: usize,
    frame: &CapturedFrame,
) -> Result<()> {
    if frame.stride < frame.width * BYTES_PER_PIXEL as u32 {
        return Err(anyhow!(
            "frame stride {} too small for width {}",
            frame.stride,
            frame.width
        ));
    }

    let copy_width = frame.width.min(framebuffer_width);
    let copy_height = frame.height.min(framebuffer_height);
    let dst_x = if framebuffer_width > copy_width {
        (framebuffer_width - copy_width) / 2
    } else {
        0
    };
    let dst_y = if framebuffer_height > copy_height {
        (framebuffer_height - copy_height) / 2
    } else {
        0
    };
    let src_x = if frame.width > framebuffer_width {
        (frame.width - copy_width) / 2
    } else {
        0
    };
    let src_y = if frame.height > framebuffer_height {
        (frame.height - copy_height) / 2
    } else {
        0
    };

    let row_bytes = usize::try_from(copy_width)
        .context("copy width overflowed usize")?
        .checked_mul(BYTES_PER_PIXEL)
        .context("copy width overflowed row bytes")?;
    let src_stride = usize::try_from(frame.stride).context("invalid source stride")?;

    for row in 0..usize::try_from(copy_height).context("copy height overflowed usize")? {
        let src_row = usize::try_from(src_y).unwrap() + row;
        let dst_row = usize::try_from(dst_y).unwrap() + row;
        let src_offset = src_row
            .checked_mul(src_stride)
            .and_then(|offset| {
                offset.checked_add(usize::try_from(src_x).unwrap() * BYTES_PER_PIXEL)
            })
            .context("source offset overflowed")?;
        let dst_offset = dst_row
            .checked_mul(framebuffer_stride)
            .and_then(|offset| {
                offset.checked_add(usize::try_from(dst_x).unwrap() * BYTES_PER_PIXEL)
            })
            .context("destination offset overflowed")?;

        let src_end = src_offset
            .checked_add(row_bytes)
            .context("source end overflowed")?;
        let dst_end = dst_offset
            .checked_add(row_bytes)
            .context("destination end overflowed")?;

        if src_end > frame.pixels.len() || dst_end > framebuffer.len() {
            return Err(anyhow!("copy range exceeded source or destination bounds"));
        }

        framebuffer[dst_offset..dst_end].copy_from_slice(&frame.pixels[src_offset..src_end]);
    }

    Ok(())
}

fn open_card(path: &str) -> Result<Card> {
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

fn acquire_master_lock_if_supported(card: &Card) -> Result<bool> {
    match card.acquire_master_lock() {
        Ok(()) => Ok(true),
        Err(error)
            if matches!(
                error.raw_os_error(),
                Some(libc::EINVAL | libc::ENOTTY | libc::EOPNOTSUPP)
            ) =>
        {
            Ok(false)
        }
        Err(error) => Err(error).context("failed to acquire DRM master lock"),
    }
}

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

#[cfg(test)]
mod tests {
    use super::{
        blit_frame_centered, clear_framebuffer, frame_checksum, write_frame_ppm, CapturedFrame,
        BACKGROUND_PIXEL,
    };
    use smithay::reexports::wayland_server::protocol::wl_shm;
    use tempfile::tempdir;

    #[test]
    fn blit_centers_smaller_frame() {
        let mut framebuffer = vec![0_u8; 4 * 4 * 4];
        clear_framebuffer(&mut framebuffer);

        let frame = CapturedFrame {
            width: 2,
            height: 2,
            stride: 8,
            format: wl_shm::Format::Argb8888,
            pixels: vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
        };

        blit_frame_centered(&mut framebuffer, 4, 4, 16, &frame).unwrap();

        let center = |x: usize, y: usize| {
            let start = (y * 16) + (x * 4);
            framebuffer[start..start + 4].to_vec()
        };

        assert_eq!(center(1, 1), vec![1, 2, 3, 4]);
        assert_eq!(center(2, 1), vec![5, 6, 7, 8]);
        assert_eq!(center(1, 2), vec![9, 10, 11, 12]);
        assert_eq!(center(2, 2), vec![13, 14, 15, 16]);
        assert_eq!(center(0, 0), BACKGROUND_PIXEL);
        assert_eq!(center(3, 3), BACKGROUND_PIXEL);
    }

    #[test]
    fn blit_crops_oversized_frame_from_center() {
        let mut framebuffer = vec![0_u8; 2 * 2 * 4];
        clear_framebuffer(&mut framebuffer);

        let frame = CapturedFrame {
            width: 4,
            height: 2,
            stride: 16,
            format: wl_shm::Format::Argb8888,
            pixels: vec![
                1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 0, 6, 0, 0, 0, 7, 0, 0, 0,
                8, 0, 0, 0,
            ],
        };

        blit_frame_centered(&mut framebuffer, 2, 2, 8, &frame).unwrap();

        assert_eq!(&framebuffer[0..4], &[2, 0, 0, 0]);
        assert_eq!(&framebuffer[4..8], &[3, 0, 0, 0]);
        assert_eq!(&framebuffer[8..12], &[6, 0, 0, 0]);
        assert_eq!(&framebuffer[12..16], &[7, 0, 0, 0]);
    }

    #[test]
    fn writes_ppm_artifact_and_stable_checksum() {
        let frame = CapturedFrame {
            width: 2,
            height: 1,
            stride: 8,
            format: wl_shm::Format::Argb8888,
            pixels: vec![0x10, 0x20, 0x30, 0xFF, 0x40, 0x50, 0x60, 0xFF],
        };

        let dir = tempdir().unwrap();
        let path = dir.path().join("frame.ppm");
        write_frame_ppm(&frame, &path).unwrap();

        let bytes = std::fs::read(path).unwrap();
        assert_eq!(&bytes[..11], b"P6\n2 1\n255\n");
        assert_eq!(&bytes[11..], &[0x30, 0x20, 0x10, 0x60, 0x50, 0x40]);
        assert_eq!(frame_checksum(&frame), 0xf571c5344f1ed48d);
    }
}
