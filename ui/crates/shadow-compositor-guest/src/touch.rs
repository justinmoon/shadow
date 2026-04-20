use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::{Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{anyhow, Context, Result};
use evdev::{AbsoluteAxisCode, Device, PropType};
use smithay::reexports::calloop::channel::Sender;

#[derive(Clone, Debug)]
pub struct TouchDeviceInfo {
    pub path: PathBuf,
    pub name: String,
    pub x_min: i32,
    pub x_max: i32,
    pub y_min: i32,
    pub y_max: i32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TouchPhase {
    Down,
    Move,
    Up,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TouchInputEvent {
    pub sequence: u64,
    pub phase: TouchPhase,
    pub normalized_x: f64,
    pub normalized_y: f64,
    pub time_msec: u32,
    pub captured_at: Instant,
    pub wall_msec: u128,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct ContactSnapshot {
    tracking_id: Option<i32>,
    x: i32,
    y: i32,
}

impl ContactSnapshot {
    fn is_active(self) -> bool {
        self.tracking_id.is_some()
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct TouchFrameState {
    current_slot: usize,
    slots: [ContactSnapshot; MAX_TOUCH_SLOTS],
    committed_slot: Option<usize>,
    committed: ContactSnapshot,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RawTouchEvent {
    event_type: u16,
    code: u16,
    value: i32,
    time_msec: u32,
}

impl TouchFrameState {
    fn handle_event(
        &mut self,
        event: RawTouchEvent,
        device: &TouchDeviceInfo,
    ) -> Option<TouchInputEvent> {
        match (event.event_type, event.code) {
            (EV_ABS, ABS_MT_SLOT) => {
                if let Ok(slot) = usize::try_from(event.value) {
                    self.current_slot = slot.min(MAX_TOUCH_SLOTS - 1);
                }
                None
            }
            (EV_ABS, code) => {
                let slot = &mut self.slots[self.current_slot];
                match code {
                    ABS_MT_TRACKING_ID => {
                        slot.tracking_id = (event.value >= 0).then_some(event.value);
                    }
                    ABS_MT_POSITION_X => {
                        slot.x = event.value;
                    }
                    ABS_MT_POSITION_Y => {
                        slot.y = event.value;
                    }
                    _ => {}
                }
                None
            }
            (EV_SYN, SYN_REPORT) => self.flush(device, event.time_msec),
            (EV_SYN, SYN_DROPPED) => {
                if let Some(slot) = self.committed_slot {
                    self.slots[slot] = self.committed;
                }
                None
            }
            _ => None,
        }
    }

    fn flush(&mut self, device: &TouchDeviceInfo, time_msec: u32) -> Option<TouchInputEvent> {
        let previous = self.committed;
        let current = self.active_contact();
        let (phase, x, y) = match (previous.is_active(), current) {
            (false, Some((_, current))) => (TouchPhase::Down, current.x, current.y),
            (true, Some((slot, current)))
                if self.committed_slot != Some(slot)
                    || previous.x != current.x
                    || previous.y != current.y =>
            {
                (TouchPhase::Move, current.x, current.y)
            }
            (true, None) => (TouchPhase::Up, previous.x, previous.y),
            _ => {
                self.committed_slot = current.map(|(slot, _)| slot);
                self.committed = current.map(|(_, contact)| contact).unwrap_or_default();
                return None;
            }
        };

        self.committed_slot = current.map(|(slot, _)| slot);
        self.committed = current.map(|(_, contact)| contact).unwrap_or_default();
        Some(TouchInputEvent {
            sequence: next_touch_sequence(),
            phase,
            normalized_x: normalize_axis(x, device.x_min, device.x_max),
            normalized_y: normalize_axis(y, device.y_min, device.y_max),
            time_msec,
            captured_at: Instant::now(),
            wall_msec: wall_millis(),
        })
    }

    fn active_contact(&self) -> Option<(usize, ContactSnapshot)> {
        if let Some(slot) = self.committed_slot {
            let contact = self.slots[slot];
            if contact.is_active() {
                return Some((slot, contact));
            }
        }

        self.slots
            .iter()
            .copied()
            .enumerate()
            .find(|(_, contact)| contact.is_active())
    }
}

pub fn detect_touch_device() -> Result<TouchDeviceInfo> {
    let mut candidates = Vec::new();
    for entry in fs::read_dir("/dev/input").context("read /dev/input")? {
        let entry = entry.context("read /dev/input entry")?;
        let path = entry.path();
        if !is_event_path(&path) {
            continue;
        }
        candidates.push(path);
    }
    candidates.sort();

    for path in candidates {
        if let Ok(device) = Device::open(&path) {
            if let Some(info) = touch_device_info(&path, &device) {
                return Ok(info);
            }
        }
    }

    Err(anyhow!(
        "no direct-touch evdev node with multitouch X/Y axes was found under /dev/input"
    ))
}

pub fn spawn_touch_reader(info: TouchDeviceInfo, sender: Sender<TouchInputEvent>) {
    let thread_info = info.clone();
    thread::Builder::new()
        .name(String::from("shadow-guest-touch"))
        .spawn(move || {
            if let Err(error) = run_touch_reader(thread_info, sender) {
                tracing::warn!("[shadow-guest-compositor] touch-reader failed: {error}");
            }
        })
        .expect("spawn touch reader");
}

pub fn map_normalized_touch_to_frame(
    normalized_x: f64,
    normalized_y: f64,
    panel_width: u32,
    panel_height: u32,
    frame_width: u32,
    frame_height: u32,
) -> Option<(f64, f64)> {
    let FrameMapping {
        copy_height,
        copy_width,
        dst_x,
        dst_y,
        src_x,
        src_y,
    } = frame_mapping(panel_width, panel_height, frame_width, frame_height)?;

    let panel_x = normalized_x.clamp(0.0, 1.0) * f64::from(panel_width.saturating_sub(1));
    let panel_y = normalized_y.clamp(0.0, 1.0) * f64::from(panel_height.saturating_sub(1));
    let copy_width_f = f64::from(copy_width);
    let copy_height_f = f64::from(copy_height);
    let dst_x_f = f64::from(dst_x);
    let dst_y_f = f64::from(dst_y);

    if panel_x < dst_x_f
        || panel_x >= dst_x_f + copy_width_f
        || panel_y < dst_y_f
        || panel_y >= dst_y_f + copy_height_f
    {
        return None;
    }

    Some((
        f64::from(src_x) + (panel_x - dst_x_f) * f64::from(frame_width) / copy_width_f,
        f64::from(src_y) + (panel_y - dst_y_f) * f64::from(frame_height) / copy_height_f,
    ))
}

pub fn frame_content_rect(
    panel_width: u32,
    panel_height: u32,
    frame_width: u32,
    frame_height: u32,
) -> Option<(u32, u32, u32, u32)> {
    let mapping = frame_mapping(panel_width, panel_height, frame_width, frame_height)?;
    Some((
        mapping.dst_x,
        mapping.dst_y,
        mapping.copy_width,
        mapping.copy_height,
    ))
}

struct FrameMapping {
    copy_width: u32,
    copy_height: u32,
    dst_x: u32,
    dst_y: u32,
    src_x: u32,
    src_y: u32,
}

fn frame_mapping(
    panel_width: u32,
    panel_height: u32,
    frame_width: u32,
    frame_height: u32,
) -> Option<FrameMapping> {
    if panel_width == 0 || panel_height == 0 || frame_width == 0 || frame_height == 0 {
        return None;
    }

    if panel_width == frame_width.saturating_mul(2)
        && panel_height == frame_height.saturating_mul(2)
    {
        return Some(FrameMapping {
            copy_width: panel_width,
            copy_height: panel_height,
            dst_x: 0,
            dst_y: 0,
            src_x: 0,
            src_y: 0,
        });
    }

    let copy_width = frame_width.min(panel_width);
    let copy_height = frame_height.min(panel_height);
    let dst_x = if panel_width > copy_width {
        (panel_width - copy_width) / 2
    } else {
        0
    };
    let dst_y = if panel_height > copy_height {
        (panel_height - copy_height) / 2
    } else {
        0
    };
    let src_x = if frame_width > panel_width {
        (frame_width - copy_width) / 2
    } else {
        0
    };
    let src_y = if frame_height > panel_height {
        (frame_height - copy_height) / 2
    } else {
        0
    };

    Some(FrameMapping {
        copy_width,
        copy_height,
        dst_x,
        dst_y,
        src_x,
        src_y,
    })
}

fn run_touch_reader(info: TouchDeviceInfo, sender: Sender<TouchInputEvent>) -> Result<()> {
    let mut reader = touch_reader_stream(&info)?;
    let mut frame_state = TouchFrameState::default();
    let mut event_bytes = [0_u8; INPUT_EVENT_SIZE];

    loop {
        reader
            .read_exact(&mut event_bytes)
            .with_context(|| format!("read touch events from {}", info.path.display()))?;
        let event = parse_raw_touch_event(&event_bytes)?;
        if let Some(pointer_event) = frame_state.handle_event(event, &info) {
            tracing::info!(
                "[shadow-guest-compositor] touch-reader-event phase={:?} normalized={:.3},{:.3}",
                pointer_event.phase,
                pointer_event.normalized_x,
                pointer_event.normalized_y
            );
            if sender.send(pointer_event).is_err() {
                return Ok(());
            }
        }
    }
}

const INPUT_EVENT_SIZE: usize = 24;
const MAX_TOUCH_SLOTS: usize = 10;
const EV_SYN: u16 = 0x00;
const EV_ABS: u16 = 0x03;
const SYN_REPORT: u16 = 0x00;
const SYN_DROPPED: u16 = 0x03;
const ABS_MT_SLOT: u16 = 0x2f;
const ABS_MT_POSITION_X: u16 = 0x35;
const ABS_MT_POSITION_Y: u16 = 0x36;
const ABS_MT_TRACKING_ID: u16 = 0x39;
static TOUCH_EVENT_SEQUENCE: AtomicU64 = AtomicU64::new(1);

fn parse_raw_touch_event(bytes: &[u8; INPUT_EVENT_SIZE]) -> Result<RawTouchEvent> {
    let seconds = i64::from_ne_bytes(bytes[0..8].try_into().expect("time seconds"));
    let micros = i64::from_ne_bytes(bytes[8..16].try_into().expect("time micros"));
    let event_type = u16::from_ne_bytes(bytes[16..18].try_into().expect("event type"));
    let code = u16::from_ne_bytes(bytes[18..20].try_into().expect("event code"));
    let value = i32::from_ne_bytes(bytes[20..24].try_into().expect("event value"));
    let time_msec = seconds
        .saturating_mul(1_000)
        .saturating_add(micros.div_euclid(1_000))
        .clamp(0, i64::from(u32::MAX)) as u32;

    Ok(RawTouchEvent {
        event_type,
        code,
        value,
        time_msec,
    })
}

fn touch_reader_stream(info: &TouchDeviceInfo) -> Result<Box<dyn Read + Send>> {
    let touch_path = info.path.to_string_lossy().to_string();
    let dd_command = format!("dd if={touch_path} bs={INPUT_EVENT_SIZE} status=none");
    for helper in ["/debug_ramdisk/su", "su"] {
        match Command::new(helper)
            .arg("0")
            .arg("sh")
            .arg("-c")
            .arg(&dd_command)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(mut child) => {
                let stdout = child
                    .stdout
                    .take()
                    .context("capture dd touch reader stdout")?;
                tracing::info!(
                    "[shadow-guest-compositor] touch-reader-helper helper={} pid={}",
                    helper,
                    child.id()
                );
                return Ok(Box::new(ChildReader { child, stdout }));
            }
            Err(error) => {
                tracing::warn!(
                    "[shadow-guest-compositor] touch-reader-helper-failed helper={} error={}",
                    helper,
                    error
                );
            }
        }
    }

    tracing::info!(
        "[shadow-guest-compositor] touch-reader-direct device={}",
        info.path.display()
    );
    Ok(Box::new(fs::File::open(&info.path).with_context(|| {
        format!("open touch device {}", info.path.display())
    })?))
}

struct ChildReader {
    child: std::process::Child,
    stdout: std::process::ChildStdout,
}

impl Read for ChildReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.stdout.read(buf)
    }
}

impl Drop for ChildReader {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn touch_device_info(path: &Path, device: &Device) -> Option<TouchDeviceInfo> {
    let properties = device.properties();
    if !properties.contains(PropType::DIRECT) {
        return None;
    }

    let mut x_range = None;
    let mut y_range = None;
    let absinfo = device.get_absinfo().ok()?;
    for (axis, info) in absinfo {
        match axis {
            AbsoluteAxisCode::ABS_MT_POSITION_X => {
                x_range = Some((info.minimum(), info.maximum()));
            }
            AbsoluteAxisCode::ABS_MT_POSITION_Y => {
                y_range = Some((info.minimum(), info.maximum()));
            }
            _ => {}
        }
    }

    let ((x_min, x_max), (y_min, y_max)) = (x_range?, y_range?);
    Some(TouchDeviceInfo {
        path: path.to_path_buf(),
        name: device.name().unwrap_or("unknown").to_string(),
        x_min,
        x_max,
        y_min,
        y_max,
    })
}

fn is_event_path(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.starts_with("event"))
        .unwrap_or(false)
}

fn normalize_axis(value: i32, min: i32, max: i32) -> f64 {
    if max <= min {
        return 0.0;
    }

    ((value - min) as f64 / (max - min) as f64).clamp(0.0, 1.0)
}

#[allow(dead_code)]
fn time_msec(timestamp: SystemTime) -> u32 {
    timestamp
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u32
}

fn wall_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn next_touch_sequence() -> u64 {
    TOUCH_EVENT_SEQUENCE.fetch_add(1, Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::{
        map_normalized_touch_to_frame, parse_raw_touch_event, ContactSnapshot, TouchDeviceInfo,
        TouchFrameState, TouchPhase,
    };

    fn test_device() -> TouchDeviceInfo {
        TouchDeviceInfo {
            path: "/dev/input/event-test".into(),
            name: String::from("test-touch"),
            x_min: 0,
            x_max: 1079,
            y_min: 0,
            y_max: 2339,
        }
    }

    #[test]
    fn touch_state_emits_down_move_up_for_slot_zero() {
        let device = test_device();
        let mut state = TouchFrameState::default();

        state.slots[0] = ContactSnapshot {
            tracking_id: Some(1),
            x: 540,
            y: 1200,
        };
        let down = state.flush(&device, 10).expect("down event");
        assert_eq!(down.phase, TouchPhase::Down);

        state.slots[0].x = 600;
        let moved = state.flush(&device, 20).expect("move event");
        assert_eq!(moved.phase, TouchPhase::Move);

        state.slots[0].tracking_id = None;
        let up = state.flush(&device, 30).expect("up event");
        assert_eq!(up.phase, TouchPhase::Up);

        assert!(state.flush(&device, 40).is_none());
    }

    #[test]
    fn touch_state_tracks_nonzero_active_slot() {
        let device = test_device();
        let mut state = TouchFrameState::default();
        state.current_slot = 3;
        state.handle_event(
            super::RawTouchEvent {
                event_type: super::EV_ABS,
                code: super::ABS_MT_TRACKING_ID,
                value: 7,
                time_msec: 10,
            },
            &device,
        );
        state.handle_event(
            super::RawTouchEvent {
                event_type: super::EV_ABS,
                code: super::ABS_MT_POSITION_X,
                value: 900,
                time_msec: 10,
            },
            &device,
        );
        state.handle_event(
            super::RawTouchEvent {
                event_type: super::EV_ABS,
                code: super::ABS_MT_POSITION_Y,
                value: 2000,
                time_msec: 10,
            },
            &device,
        );
        let down = state.flush(&device, 10).expect("down event");
        assert_eq!(down.phase, TouchPhase::Down);
        assert!(down.normalized_x > 0.8);
        assert!(down.normalized_y > 0.8);
    }

    #[test]
    fn centered_touch_mapping_ignores_letterbox_and_maps_inside_content() {
        assert_eq!(
            map_normalized_touch_to_frame(0.5, 0.5, 1080, 2340, 384, 720),
            Some((191.5, 359.5))
        );
        assert_eq!(
            map_normalized_touch_to_frame(0.0, 0.0, 1080, 2340, 384, 720),
            None
        );
    }

    #[test]
    fn parse_raw_touch_event_parses_axis_and_sync_events() {
        let x = parse_raw_touch_event(&[
            0xbd, 0x91, 0xce, 0x69, 0x00, 0x00, 0x00, 0x00, 0x3e, 0x8d, 0x0b, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x35, 0x00, 0xe8, 0x03, 0x00, 0x00,
        ])
        .expect("parse event");
        assert_eq!(x.event_type, super::EV_ABS);
        assert_eq!(x.code, super::ABS_MT_POSITION_X);
        assert_eq!(x.value, 1000);

        let sync = parse_raw_touch_event(&[
            0xbd, 0x91, 0xce, 0x69, 0x00, 0x00, 0x00, 0x00, 0x3e, 0x8d, 0x0b, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        .expect("parse event");
        assert_eq!(sync.event_type, super::EV_SYN);
        assert_eq!(sync.code, super::SYN_REPORT);
        assert_eq!(sync.value, 0);
    }
}
