#![warn(clippy::all, clippy::pedantic)]

use anyhow::{anyhow, Context, Result};
use drm::buffer::{Buffer, DrmFourcc};
use drm::control::dumbbuffer::DumbBuffer;
use drm::control::{connector, Device as ControlDevice};
use drm::Device as BasicDevice;
use drm::DriverCapability;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::io::{AsFd, BorrowedFd};
use std::path::Path;
use std::time::Duration;

const SHADOW_INIT_CONFIG_PATH: &str = "/shadow-init.cfg";
const DEFAULT_SOLID_COLOR: (u8, u8, u8) = (0x2a, 0xd0, 0xc9);
const ORANGE_SOLID_COLOR: (u8, u8, u8) = (0xff, 0x7a, 0x00);
const SUCCESS_SOLID_COLOR: (u8, u8, u8) = (0x00, 0xb8, 0x5c);
const ACCENT_DARK_COLOR: (u8, u8, u8) = (0x08, 0x08, 0x08);

#[derive(Clone, Copy)]
enum DisplayVisual {
    Solid((u8, u8, u8)),
    HorizontalBand {
        primary: (u8, u8, u8),
        accent: (u8, u8, u8),
    },
    VerticalBand {
        primary: (u8, u8, u8),
        accent: (u8, u8, u8),
    },
    Checker {
        primary: (u8, u8, u8),
        accent: (u8, u8, u8),
        cell_px: usize,
    },
    Frame {
        primary: (u8, u8, u8),
        accent: (u8, u8, u8),
        thickness_px: usize,
    },
    StageCode {
        primary: (u8, u8, u8),
        accent: (u8, u8, u8),
        code: usize,
    },
}

pub fn fill_display(color: (u8, u8, u8), duration: Duration) -> Result<()> {
    fill_display_visual_with_pattern(DisplayVisual::Solid(color), duration)
}

pub fn fill_display_visual(visual_name: &str, duration: Duration) -> Result<()> {
    let visual = parse_display_visual(visual_name)?;
    fill_display_visual_with_pattern(visual, duration)
}

fn parse_display_visual(visual_name: &str) -> Result<DisplayVisual> {
    match visual_name {
        "default-solid" => Ok(DisplayVisual::Solid(DEFAULT_SOLID_COLOR)),
        "orange-solid" | "solid-orange" => Ok(DisplayVisual::Solid(ORANGE_SOLID_COLOR)),
        "success-solid" => Ok(DisplayVisual::Solid(SUCCESS_SOLID_COLOR)),
        "orange-horizontal-band" | "bands-orange" => Ok(DisplayVisual::HorizontalBand {
            primary: ORANGE_SOLID_COLOR,
            accent: ACCENT_DARK_COLOR,
        }),
        "orange-vertical-band" => Ok(DisplayVisual::VerticalBand {
            primary: ORANGE_SOLID_COLOR,
            accent: ACCENT_DARK_COLOR,
        }),
        "orange-checker" | "checker-orange" => Ok(DisplayVisual::Checker {
            primary: ORANGE_SOLID_COLOR,
            accent: ACCENT_DARK_COLOR,
            cell_px: 96,
        }),
        "frame-orange" => Ok(DisplayVisual::Frame {
            primary: ORANGE_SOLID_COLOR,
            accent: ACCENT_DARK_COLOR,
            thickness_px: 120,
        }),
        other if other.starts_with("code-orange-") => {
            let code = other
                .trim_start_matches("code-orange-")
                .parse::<usize>()
                .context("invalid code-orange visual")?;
            Ok(DisplayVisual::StageCode {
                primary: ORANGE_SOLID_COLOR,
                accent: ACCENT_DARK_COLOR,
                code,
            })
        }
        other => Err(anyhow!("unsupported display visual: {other}")),
    }
}

fn fill_display_visual_with_pattern(visual: DisplayVisual, duration: Duration) -> Result<()> {
    let visual_label = describe_display_visual(visual);
    log_line(&format!(
        "trace stage=fill-start visual={} hold_secs={}",
        visual_label,
        duration.as_secs()
    ));
    log_mount_state("/dev");
    log_mount_state("/sys");
    log_mount_state("/metadata");
    log_path_state("/dev/dri");
    log_path_state("/dev/dri/card0");
    log_path_state("/dev/dri/renderD128");
    log_path_state("/sys/class/drm/card0/device");

    let mut card = open_card("/dev/dri/card0")?;
    let master_locked = acquire_master_lock_if_supported(&card)?;
    let res_handles = card
        .resource_handles()
        .context("failed to fetch DRM resource handles")?;
    log_line(&format!(
        "trace stage=resource-handles crtcs={} connectors={} encoders={}",
        res_handles.crtcs().len(),
        res_handles.connectors().len(),
        res_handles.encoders().len()
    ));

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
    let crtc_handle = select_crtc_handle(&encoder, &res_handles, connector_handle, encoder_handle)?;

    let (width, height) = mode.size();
    let width = u32::from(width);
    let height = u32::from(height);
    log_line(&format!(
        "trace stage=dumb-buffer-create width={width} height={height}"
    ));
    let mut dumb = card
        .create_dumb_buffer((width, height), DrmFourcc::Xrgb8888, 32)
        .context("failed to allocate dumb buffer")?;

    let fb_handle = card
        .add_framebuffer(&dumb, 24, 32)
        .context("failed to create framebuffer")?;

    fill_buffer_with_visual(&mut card, &mut dumb, visual)
        .context("failed to fill dumb buffer")?;

    card.set_crtc(
        crtc_handle,
        Some(fb_handle),
        (0, 0),
        &[connector_handle],
        Some(mode),
    )
    .context("failed to set CRTC configuration")?;
    log_line("trace stage=crtc-set success=true");
    log_line("success");

    std::thread::sleep(duration);
    log_line("trace stage=hold-complete");

    if let Err(error) = card.set_crtc(crtc_handle, None, (0, 0), &[], None) {
        log_line(&format!("failed to clear crtc: {error}"));
    } else {
        log_line("trace stage=crtc-clear success=true");
    }

    if master_locked {
        if let Err(error) = card.release_master_lock() {
            log_line(&format!("failed to release DRM master lock: {error}"));
        }
    }

    card.destroy_framebuffer(fb_handle)
        .context("failed to destroy framebuffer")?;
    card.destroy_dumb_buffer(dumb)
        .context("failed to destroy dumb buffer")?;

    Ok(())
}

fn describe_display_visual(visual: DisplayVisual) -> &'static str {
    match visual {
        DisplayVisual::Solid(DEFAULT_SOLID_COLOR) => "default-solid",
        DisplayVisual::Solid(ORANGE_SOLID_COLOR) => "solid-orange",
        DisplayVisual::Solid(SUCCESS_SOLID_COLOR) => "success-solid",
        DisplayVisual::Solid(_) => "solid-custom",
        DisplayVisual::HorizontalBand { .. } => "bands-orange",
        DisplayVisual::VerticalBand { .. } => "orange-vertical-band",
        DisplayVisual::Checker { .. } => "checker-orange",
        DisplayVisual::Frame { .. } => "frame-orange",
        DisplayVisual::StageCode { .. } => "code-orange",
    }
}

pub fn probe_nodes(paths: &[&str]) -> Result<()> {
    let card0_requested = paths.contains(&"/dev/dri/card0");
    let mut card0_succeeded = false;
    let mut success_count = 0usize;
    let mut failures = Vec::new();

    for path in paths {
        match probe_node(path) {
            Ok(()) => {
                success_count += 1;
                if *path == "/dev/dri/card0" {
                    card0_succeeded = true;
                }
            }
            Err(error) => {
                log_line(&format!("probe-node path={path} error={error:#}"));
                failures.push(format!("{path}: {error:#}"));
            }
        }
    }

    if card0_requested && !card0_succeeded {
        return Err(anyhow!(
            "required KMS node /dev/dri/card0 failed: {}",
            failures.join("; ")
        ));
    }

    if success_count > 0 {
        Ok(())
    } else {
        Err(anyhow!(
            "failed to probe any DRM nodes: {}",
            failures.join("; ")
        ))
    }
}

pub fn probe_node(path: &str) -> Result<()> {
    log_path_state(path);
    let card = open_card(path)?;
    let driver = card
        .get_driver()
        .with_context(|| format!("failed to query DRM driver for {path}"))?;
    let bus_id = card
        .get_bus_id()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_else(|error| format!("<error:{error}>"));
    let authenticated = card
        .authenticated()
        .map(|value| value.to_string())
        .unwrap_or_else(|error| format!("<error:{error}>"));

    log_line(&format!(
        "probe-driver path={path} name={} version={}.{}.{} date={} desc={} bus_id={} authenticated={authenticated}",
        driver.name().to_string_lossy(),
        driver.version.0,
        driver.version.1,
        driver.version.2,
        driver.date().to_string_lossy(),
        driver.description().to_string_lossy(),
        bus_id,
    ));

    for (label, cap) in [
        ("dumb-buffer", DriverCapability::DumbBuffer),
        ("prime", DriverCapability::Prime),
        ("addfb2-modifiers", DriverCapability::AddFB2Modifiers),
        ("syncobj", DriverCapability::SyncObj),
        ("timeline-syncobj", DriverCapability::TimelineSyncObj),
    ] {
        match card.get_driver_capability(cap) {
            Ok(value) => log_line(&format!("probe-cap path={path} cap={label} value={value}")),
            Err(error) => {
                log_line(&format!("probe-cap path={path} cap={label} error={error}"));
            }
        }
    }

    match card.resource_handles() {
        Ok(resources) => {
            log_line(&format!(
                "probe-resources path={path} crtcs={} connectors={} encoders={}",
                resources.crtcs().len(),
                resources.connectors().len(),
                resources.encoders().len(),
            ));
            for connector_handle in resources.connectors() {
                match card.get_connector(*connector_handle, true) {
                    Ok(info) => {
                        log_line(&format!(
                            "probe-connector path={path} handle={connector_handle:?} state={:?} modes={} encoders={} current_encoder={:?}",
                            info.state(),
                            info.modes().len(),
                            info.encoders().len(),
                            info.current_encoder(),
                        ));
                    }
                    Err(error) => {
                        log_line(&format!(
                            "probe-connector path={path} handle={connector_handle:?} error={error}"
                        ));
                    }
                }
            }
        }
        Err(error) => {
            log_line(&format!("probe-resources path={path} error={error}"));
        }
    }

    Ok(())
}

pub fn log_line(message: &str) {
    let line = format!("[shadow-drm] {message}\n");
    let _ = std::io::stdout().write_all(line.as_bytes());
    let _ = std::io::stderr().write_all(line.as_bytes());

    write_device_log("/dev/kmsg", &format!("<6>[shadow-drm] {message}\n"));
    write_device_log("/dev/pmsg0", &line);
}

pub fn emit_runtime_context(paths: &[&str]) {
    let run_token = load_shadow_init_run_token();
    let run_token = run_token.as_deref().unwrap_or("unset");

    log_line(&format!(
        "trace stage=runtime-context config_path={SHADOW_INIT_CONFIG_PATH} run_token={run_token}"
    ));
    if run_token != "unset" {
        log_line(&format!("shadow-owned-init-run-token:{run_token}"));
    }

    log_mount_state("/dev");
    log_mount_state("/sys");
    log_mount_state("/metadata");
    for path in paths {
        log_path_state(path);
    }
}

fn write_device_log(path: &str, message: &str) {
    if let Ok(mut file) = OpenOptions::new().write(true).open(path) {
        let _ = file.write_all(message.as_bytes());
        let _ = file.flush();
    }
}

fn load_shadow_init_run_token() -> Option<String> {
    let raw = fs::read_to_string(SHADOW_INIT_CONFIG_PATH).ok()?;
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let (key, value) = line.split_once('=')?;
        if key == "run_token" {
            let value = value.trim();
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }

    None
}

fn log_mount_state(mountpoint: &str) {
    let mounts = match fs::read_to_string("/proc/mounts") {
        Ok(contents) => contents,
        Err(error) => {
            log_line(&format!(
                "trace stage=mount-state mountpoint={mountpoint} mounted=unknown error={error}"
            ));
            return;
        }
    };

    for line in mounts.lines() {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        if fields.len() < 3 {
            continue;
        }
        if fields[1] == mountpoint {
            log_line(&format!(
                "trace stage=mount-state mountpoint={mountpoint} mounted=true source={} fstype={}",
                fields[0], fields[2]
            ));
            return;
        }
    }

    log_line(&format!(
        "trace stage=mount-state mountpoint={mountpoint} mounted=false"
    ));
}

fn log_path_state(path: &str) {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) => {
            log_line(&format!(
                "trace stage=path-state path={path} exists=false error={error}"
            ));
            return;
        }
    };

    let file_type = metadata.file_type();
    let kind = if file_type.is_char_device() {
        "char"
    } else if file_type.is_dir() {
        "dir"
    } else if file_type.is_file() {
        "file"
    } else if file_type.is_symlink() {
        "symlink"
    } else {
        "other"
    };

    let symlink_target = if file_type.is_symlink() {
        fs::read_link(path)
            .ok()
            .map(|target| target.display().to_string())
            .unwrap_or_else(|| "<unreadable>".to_string())
    } else {
        "-".to_string()
    };

    let canonical = fs::canonicalize(Path::new(path))
        .ok()
        .map(|target| target.display().to_string())
        .unwrap_or_else(|| "<unresolved>".to_string());

    log_line(&format!(
        "trace stage=path-state path={path} exists=true kind={kind} mode={:o} symlink_target={} canonical={}",
        metadata.permissions().mode() & 0o7777,
        symlink_target,
        canonical,
    ));
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

fn acquire_master_lock_if_supported(card: &Card) -> Result<bool> {
    match card.acquire_master_lock() {
        Ok(()) => {
            log_line("acquired DRM master lock");
            Ok(true)
        }
        Err(error)
            if matches!(
                error.raw_os_error(),
                Some(libc::EINVAL | libc::ENOTTY | libc::EOPNOTSUPP)
            ) =>
        {
            log_line(&format!(
                "continuing without DRM master lock; ioctl unsupported: {error}"
            ));
            Ok(false)
        }
        Err(error) => Err(error).context("failed to acquire DRM master lock"),
    }
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

fn select_crtc_handle(
    encoder: &drm::control::encoder::Info,
    res_handles: &drm::control::ResourceHandles,
    connector_handle: connector::Handle,
    encoder_handle: drm::control::encoder::Handle,
) -> Result<drm::control::crtc::Handle> {
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

fn fill_buffer_with_visual(
    card: &mut Card,
    dumb: &mut DumbBuffer,
    visual: DisplayVisual,
) -> Result<()> {
    let (width, height) = dumb.size();
    let width = usize::try_from(width).context("display width does not fit in usize")?;
    let height = usize::try_from(height).context("display height does not fit in usize")?;
    let pitch = usize::try_from(dumb.pitch()).context("display pitch does not fit in usize")?;
    let mut mapping = card
        .map_dumb_buffer(dumb)
        .context("failed to map dumb buffer")?;

    for y in 0..height {
        let row = &mut mapping.as_mut()[y * pitch..(y + 1) * pitch];
        for x in 0..width {
            let offset = x * 4;
            let (r, g, b) = color_for_visual(visual, x, y, width, height);
            row[offset] = b;
            row[offset + 1] = g;
            row[offset + 2] = r;
            row[offset + 3] = 0xFF;
        }
    }

    Ok(())
}

fn color_for_visual(
    visual: DisplayVisual,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
) -> (u8, u8, u8) {
    match visual {
        DisplayVisual::Solid(color) => color,
        DisplayVisual::HorizontalBand { primary, accent } => {
            let band_start = height / 3;
            let band_end = height - band_start;
            if y >= band_start && y < band_end {
                accent
            } else {
                primary
            }
        }
        DisplayVisual::VerticalBand { primary, accent } => {
            let band_start = width / 3;
            let band_end = width - band_start;
            if x >= band_start && x < band_end {
                accent
            } else {
                primary
            }
        }
        DisplayVisual::Checker {
            primary,
            accent,
            cell_px,
        } => {
            let x_cell = x / cell_px.max(1);
            let y_cell = y / cell_px.max(1);
            if (x_cell + y_cell) % 2 == 0 {
                primary
            } else {
                accent
            }
        }
        DisplayVisual::Frame {
            primary,
            accent,
            thickness_px,
        } => {
            let thickness = thickness_px.max(1);
            if x < thickness || y < thickness || x + thickness >= width || y + thickness >= height {
                primary
            } else {
                accent
            }
        }
        DisplayVisual::StageCode {
            primary,
            accent,
            code,
        } => {
            let border = (width.min(height) / 18).clamp(24, 120);
            let slots = 12usize;
            let inner_width = width.saturating_sub(border * 2);
            let slot_width = (inner_width / slots.max(1)).max(1);
            let filled_slots = code.min(slots);
            let top_or_bottom_band = y < border * 2 || y + border * 2 >= height;
            let left_frame = x < border;
            let right_frame = x + border >= width;
            let slot_end = border + filled_slots * slot_width;
            let slot_band = top_or_bottom_band && x >= border && x < slot_end;

            if left_frame || right_frame || slot_band {
                accent
            } else {
                primary
            }
        }
    }
}
