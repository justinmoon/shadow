use anyhow::{anyhow, Context, Result};
use drm::buffer::{Buffer as DrmBuffer, DrmFourcc, Handle as DrmBufferHandle, PlanarBuffer};
use drm::control::Device as ControlDevice;
use drm::control::{connector, crtc, dumbbuffer::DumbBuffer, framebuffer, FbCmd2Flags};
use drm::Device as BasicDevice;
use smithay::backend::allocator::dmabuf::{Dmabuf, DmabufMappingMode, DmabufSyncFlags};
use smithay::backend::allocator::Buffer as SmithayBuffer;
use smithay::backend::allocator::Fourcc;
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
const BOOT_SPLASH_WIDTH: u32 = 384;
const BOOT_SPLASH_HEIGHT: u32 = 720;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapturedFrame {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: wl_shm::Format,
    pub pixels: Vec<u8>,
}

#[derive(Clone, Copy, Debug)]
pub struct CapturedFrameView<'a> {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub pixels: &'a [u8],
}

impl CapturedFrame {
    pub fn view(&self) -> CapturedFrameView<'_> {
        CapturedFrameView {
            width: self.width,
            height: self.height,
            stride: self.stride,
            pixels: &self.pixels,
        }
    }
}

pub fn copy_frame_view(frame: CapturedFrameView<'_>, format: wl_shm::Format) -> CapturedFrame {
    CapturedFrame {
        width: frame.width,
        height: frame.height,
        stride: frame.stride,
        format,
        pixels: frame.pixels.to_vec(),
    }
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
    frame_view_checksum(frame.view())
}

pub fn frame_view_checksum(frame: CapturedFrameView<'_>) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in frame.pixels {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

pub fn write_frame_ppm(frame: &CapturedFrame, path: impl AsRef<Path>) -> Result<()> {
    write_frame_view_ppm(frame.view(), path)
}

pub fn write_frame_view_ppm(frame: CapturedFrameView<'_>, path: impl AsRef<Path>) -> Result<()> {
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

pub fn capture_dmabuf_frame(dmabuf: &Dmabuf) -> Result<CapturedFrame> {
    if dmabuf.num_planes() != 1 {
        return Err(anyhow!(
            "unsupported dmabuf plane count: {}",
            dmabuf.num_planes()
        ));
    }

    let size = dmabuf.size();
    let width = u32::try_from(size.w).context("negative dmabuf width")?;
    let height = u32::try_from(size.h).context("negative dmabuf height")?;
    let stride = dmabuf
        .strides()
        .next()
        .ok_or_else(|| anyhow!("dmabuf missing stride"))?;
    let format = wl_shm_format_from_dmabuf(dmabuf)?;
    let frame_len = usize::try_from(u64::from(stride) * u64::from(height))
        .context("dmabuf frame length overflowed usize")?;

    dmabuf
        .sync_plane(0, DmabufSyncFlags::READ | DmabufSyncFlags::START)
        .context("dmabuf sync start failed")?;
    let mapping = dmabuf
        .map_plane(0, DmabufMappingMode::READ)
        .context("dmabuf map failed")?;
    if frame_len > mapping.length() {
        let _ = dmabuf.sync_plane(0, DmabufSyncFlags::READ | DmabufSyncFlags::END);
        return Err(anyhow!(
            "dmabuf mapping too small: frame_len={} mapping_len={}",
            frame_len,
            mapping.length()
        ));
    }
    let mut pixels = vec![0_u8; frame_len];
    unsafe {
        std::ptr::copy_nonoverlapping(mapping.ptr() as *const u8, pixels.as_mut_ptr(), frame_len);
    }
    dmabuf
        .sync_plane(0, DmabufSyncFlags::READ | DmabufSyncFlags::END)
        .context("dmabuf sync end failed")?;

    Ok(CapturedFrame {
        width,
        height,
        stride,
        format,
        pixels,
    })
}

pub fn build_boot_splash_frame(panel_width: u32, panel_height: u32) -> CapturedFrame {
    let width = BOOT_SPLASH_WIDTH.min(panel_width);
    let height = BOOT_SPLASH_HEIGHT.min(panel_height);
    let stride = width * BYTES_PER_PIXEL as u32;
    let mut pixels = vec![0_u8; usize::try_from(u64::from(stride) * u64::from(height)).unwrap()];

    fill_frame(&mut pixels, [0x18, 0x12, 0x10, 0xFF]);

    let card_width = width.saturating_mul(2) / 3;
    let card_height = height.saturating_mul(3) / 5;
    let card_x = (width.saturating_sub(card_width)) / 2;
    let card_y = (height.saturating_sub(card_height)) / 2;

    fill_rect(
        &mut pixels,
        width,
        height,
        card_x,
        card_y,
        card_width,
        card_height,
        [0x4A, 0x28, 0x16, 0xFF],
    );

    let accent_margin = card_width / 12;
    let accent_x = card_x + accent_margin;
    let accent_width = card_width.saturating_sub(accent_margin * 2);
    let accent_y = card_y + card_height / 9;
    let accent_height = card_height / 7;
    fill_rect(
        &mut pixels,
        width,
        height,
        accent_x,
        accent_y,
        accent_width,
        accent_height,
        [0xFF, 0xD3, 0x45, 0xFF],
    );

    let status_width = card_width / 2;
    let status_height = card_height / 24;
    let status_y = accent_y + accent_height + card_height / 12;
    let status_gap = status_height;
    for index in 0..3 {
        let segment_x = card_x + accent_margin + (index * (status_width / 3 + status_gap));
        fill_rect(
            &mut pixels,
            width,
            height,
            segment_x,
            status_y,
            status_width / 3,
            status_height,
            [0x9A, 0x74, 0x2A, 0xFF],
        );
    }

    let footer_y = card_y + card_height - card_height / 6;
    fill_rect(
        &mut pixels,
        width,
        height,
        accent_x,
        footer_y,
        accent_width,
        card_height / 10,
        [0x66, 0x4A, 0x1F, 0xFF],
    );

    CapturedFrame {
        width,
        height,
        stride,
        format: wl_shm::Format::Xrgb8888,
        pixels,
    }
}

#[cfg(test)]
pub fn captured_frame_from_pixels(
    width: u32,
    height: u32,
    pixels: Vec<u8>,
    format: wl_shm::Format,
) -> Result<CapturedFrame> {
    let stride = width
        .checked_mul(BYTES_PER_PIXEL as u32)
        .ok_or_else(|| anyhow!("frame stride overflowed"))?;
    let expected_len = usize::try_from(u64::from(stride) * u64::from(height))
        .context("frame byte length overflowed")?;
    if pixels.len() != expected_len {
        return Err(anyhow!(
            "pixel buffer length {} did not match expected {} for {}x{}",
            pixels.len(),
            expected_len,
            width,
            height
        ));
    }

    Ok(CapturedFrame {
        width,
        height,
        stride,
        format,
        pixels,
    })
}

pub struct KmsDisplay {
    card: Card,
    master_locked: bool,
    connector_handle: connector::Handle,
    crtc_handle: crtc::Handle,
    mode: drm::control::Mode,
    dumb: Option<DumbBuffer>,
    fb_handle: Option<framebuffer::Handle>,
    imported_fb: Option<ImportedFramebuffer>,
    width: u32,
    height: u32,
}

struct ImportedFramebuffer {
    fb_handle: framebuffer::Handle,
    gem_handles: [Option<DrmBufferHandle>; 4],
}

struct ImportedDmabufFramebuffer {
    size: (u32, u32),
    format: DrmFourcc,
    modifier: Option<drm::buffer::DrmModifier>,
    pitches: [u32; 4],
    offsets: [u32; 4],
    handles: [Option<DrmBufferHandle>; 4],
}

impl PlanarBuffer for ImportedDmabufFramebuffer {
    fn size(&self) -> (u32, u32) {
        self.size
    }

    fn format(&self) -> DrmFourcc {
        self.format
    }

    fn modifier(&self) -> Option<drm::buffer::DrmModifier> {
        self.modifier
    }

    fn pitches(&self) -> [u32; 4] {
        self.pitches
    }

    fn handles(&self) -> [Option<DrmBufferHandle>; 4] {
        self.handles
    }

    fn offsets(&self) -> [u32; 4] {
        self.offsets
    }
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
            imported_fb: None,
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

    pub fn present_frame_view(&mut self, frame: CapturedFrameView<'_>) -> Result<()> {
        self.release_imported_framebuffer()?;
        let present_started = Instant::now();
        let dumb = self
            .dumb
            .as_mut()
            .ok_or_else(|| anyhow!("dumb buffer missing"))?;
        let pitch = usize::try_from(dumb.pitch()).context("invalid dumb buffer pitch")?;
        let mut mapping = self
            .card
            .map_dumb_buffer(dumb)
            .context("failed to map dumb buffer")?;

        let blit_started = Instant::now();
        blit_frame(mapping.as_mut(), self.width, self.height, pitch, frame)?;
        let blit_elapsed = blit_started.elapsed();
        drop(mapping);
        let program_started = Instant::now();
        self.program_crtc()?;
        let program_elapsed = program_started.elapsed();
        let total_elapsed = present_started.elapsed();
        if total_elapsed.as_millis() >= 8 {
            tracing::info!(
                "[shadow-guest-compositor] kms-present-frame-view blit_ms={} program_ms={} total_ms={}",
                blit_elapsed.as_millis(),
                program_elapsed.as_millis(),
                total_elapsed.as_millis()
            );
        }
        Ok(())
    }

    pub fn present_dmabuf(&mut self, dmabuf: &Dmabuf) -> Result<()> {
        let imported = self.import_dmabuf_framebuffer(dmabuf)?;
        self.program_crtc_with_framebuffer(imported.fb_handle)?;
        self.release_imported_framebuffer()?;
        self.imported_fb = Some(imported);
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
        self.program_crtc_with_framebuffer(fb_handle)
    }

    fn program_crtc_with_framebuffer(&mut self, fb_handle: framebuffer::Handle) -> Result<()> {
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

    fn import_dmabuf_framebuffer(&mut self, dmabuf: &Dmabuf) -> Result<ImportedFramebuffer> {
        let size = dmabuf.size();
        let width = u32::try_from(size.w).context("negative dmabuf width")?;
        let height = u32::try_from(size.h).context("negative dmabuf height")?;
        let format = drm_fourcc_from_dmabuf(dmabuf)?;

        let mut gem_handles = [None; 4];
        let mut pitches = [0_u32; 4];
        let mut offsets = [0_u32; 4];

        for (index, fd) in dmabuf.handles().enumerate() {
            if index >= gem_handles.len() {
                break;
            }
            gem_handles[index] = Some(
                self.card
                    .prime_fd_to_buffer(fd)
                    .with_context(|| format!("failed to import dmabuf plane {index}"))?,
            );
        }
        for (index, pitch) in dmabuf.strides().enumerate() {
            if index >= pitches.len() {
                break;
            }
            pitches[index] = pitch;
        }
        for (index, offset) in dmabuf.offsets().enumerate() {
            if index >= offsets.len() {
                break;
            }
            offsets[index] = offset;
        }

        let imported = ImportedDmabufFramebuffer {
            size: (width, height),
            format,
            modifier: dmabuf
                .has_modifier()
                .then(|| drm::buffer::DrmModifier::from(u64::from(dmabuf.format().modifier))),
            pitches,
            offsets,
            handles: gem_handles,
        };
        let flags = if imported.modifier.is_some() {
            FbCmd2Flags::MODIFIERS
        } else {
            FbCmd2Flags::empty()
        };
        let fb_handle = match self.card.add_planar_framebuffer(&imported, flags) {
            Ok(handle) => handle,
            Err(error) => {
                for handle in gem_handles.into_iter().flatten() {
                    let _ = self.card.close_buffer(handle);
                }
                return Err(error).context("failed to create dmabuf framebuffer");
            }
        };

        Ok(ImportedFramebuffer {
            fb_handle,
            gem_handles,
        })
    }

    fn release_imported_framebuffer(&mut self) -> Result<()> {
        if let Some(imported) = self.imported_fb.take() {
            self.card
                .destroy_framebuffer(imported.fb_handle)
                .context("failed to destroy imported framebuffer")?;
            for handle in imported.gem_handles.into_iter().flatten() {
                self.card
                    .close_buffer(handle)
                    .context("failed to close imported GEM buffer")?;
            }
        }

        Ok(())
    }
}

impl Drop for KmsDisplay {
    fn drop(&mut self) {
        if self.master_locked {
            let _ = self.card.release_master_lock();
        }
        let _ = self.release_imported_framebuffer();
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

fn fill_frame(framebuffer: &mut [u8], color: [u8; 4]) {
    for pixel in framebuffer.chunks_exact_mut(BYTES_PER_PIXEL) {
        pixel.copy_from_slice(&color);
    }
}

fn fill_rect(
    framebuffer: &mut [u8],
    framebuffer_width: u32,
    framebuffer_height: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color: [u8; 4],
) {
    let end_x = x.saturating_add(width).min(framebuffer_width);
    let end_y = y.saturating_add(height).min(framebuffer_height);
    let stride = usize::try_from(framebuffer_width).unwrap() * BYTES_PER_PIXEL;

    for row in y..end_y {
        let row_start = usize::try_from(row).unwrap() * stride;
        for col in x..end_x {
            let offset = row_start + (usize::try_from(col).unwrap() * BYTES_PER_PIXEL);
            framebuffer[offset..offset + BYTES_PER_PIXEL].copy_from_slice(&color);
        }
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
    frame: CapturedFrameView<'_>,
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

fn blit_frame(
    framebuffer: &mut [u8],
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_stride: usize,
    frame: CapturedFrameView<'_>,
) -> Result<()> {
    if frame.width == framebuffer_width && frame.height == framebuffer_height {
        return copy_frame_exact(framebuffer, framebuffer_stride, frame);
    }

    clear_framebuffer(framebuffer);
    blit_frame_centered(
        framebuffer,
        framebuffer_width,
        framebuffer_height,
        framebuffer_stride,
        frame,
    )
}

fn copy_frame_exact(
    framebuffer: &mut [u8],
    framebuffer_stride: usize,
    frame: CapturedFrameView<'_>,
) -> Result<()> {
    if frame.stride < frame.width * BYTES_PER_PIXEL as u32 {
        return Err(anyhow!(
            "frame stride {} too small for width {}",
            frame.stride,
            frame.width
        ));
    }

    let row_bytes = usize::try_from(frame.width)
        .context("frame width overflowed usize")?
        .checked_mul(BYTES_PER_PIXEL)
        .context("frame width overflowed row bytes")?;
    let src_stride = usize::try_from(frame.stride).context("invalid source stride")?;

    if src_stride == framebuffer_stride && row_bytes == framebuffer_stride {
        if frame.pixels.len() < framebuffer.len() {
            return Err(anyhow!("source frame smaller than framebuffer"));
        }
        framebuffer.copy_from_slice(&frame.pixels[..framebuffer.len()]);
        return Ok(());
    }

    for row in 0..usize::try_from(frame.height).context("frame height overflowed usize")? {
        let src_offset = row
            .checked_mul(src_stride)
            .context("source offset overflowed")?;
        let dst_offset = row
            .checked_mul(framebuffer_stride)
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

fn drm_fourcc_from_dmabuf(dmabuf: &Dmabuf) -> Result<DrmFourcc> {
    match dmabuf.format().code {
        Fourcc::Argb8888 => Ok(DrmFourcc::Argb8888),
        Fourcc::Xrgb8888 => Ok(DrmFourcc::Xrgb8888),
        other => Err(anyhow!(
            "unsupported dmabuf fourcc for direct scanout: {other:?}"
        )),
    }
}

fn wl_shm_format_from_dmabuf(dmabuf: &Dmabuf) -> Result<wl_shm::Format> {
    match dmabuf.format().code {
        Fourcc::Argb8888 => Ok(wl_shm::Format::Argb8888),
        Fourcc::Xrgb8888 => Ok(wl_shm::Format::Xrgb8888),
        other => Err(anyhow!("unsupported dmabuf fourcc for capture: {other:?}")),
    }
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
        blit_frame, blit_frame_centered, captured_frame_from_pixels, clear_framebuffer,
        frame_checksum, write_frame_ppm, CapturedFrame, BACKGROUND_PIXEL,
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

        blit_frame_centered(&mut framebuffer, 4, 4, 16, frame.view()).unwrap();

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

        blit_frame_centered(&mut framebuffer, 2, 2, 8, frame.view()).unwrap();

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
        assert_eq!(frame_checksum(&frame), 0xed75dab921e996e5);
    }

    #[test]
    fn captured_frame_from_pixels_validates_length() {
        let frame =
            captured_frame_from_pixels(1, 1, vec![220, 120, 20, 128], wl_shm::Format::Argb8888)
                .unwrap();

        assert_eq!(frame.width, 1);
        assert_eq!(frame.height, 1);
        assert_eq!(frame.stride, 4);
        assert_eq!(frame.pixels, vec![220, 120, 20, 128]);
    }

    #[test]
    fn blit_exact_copies_full_frame_without_centering() {
        let frame = CapturedFrame {
            width: 2,
            height: 2,
            stride: 8,
            format: wl_shm::Format::Xrgb8888,
            pixels: vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
        };
        let mut framebuffer = vec![0_u8; frame.pixels.len()];

        blit_frame(&mut framebuffer, 2, 2, 8, frame.view()).unwrap();

        assert_eq!(framebuffer, frame.pixels);
    }
}
