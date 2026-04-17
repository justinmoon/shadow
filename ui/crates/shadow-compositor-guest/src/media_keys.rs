use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
};

use anyhow::{Context, Result};
use evdev::Device;
use shadow_ui_core::control::MediaAction;
use smithay::reexports::calloop::channel::Sender;

#[derive(Clone, Debug)]
pub struct MediaKeyDeviceInfo {
    pub path: PathBuf,
    pub name: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MediaKeyEvent {
    pub action: MediaAction,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RawInputEvent {
    event_type: u16,
    code: u16,
    value: i32,
}

pub fn detect_media_key_devices() -> Result<Vec<MediaKeyDeviceInfo>> {
    let mut devices = Vec::new();
    for entry in fs::read_dir("/dev/input").context("read /dev/input")? {
        let entry = entry.context("read /dev/input entry")?;
        let path = entry.path();
        if !is_event_path(&path) {
            continue;
        }
        let name = Device::open(&path)
            .ok()
            .and_then(|device| device.name().map(str::to_owned))
            .unwrap_or_else(|| String::from("unknown"));
        devices.push(MediaKeyDeviceInfo { path, name });
    }
    devices.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(devices)
}

pub fn spawn_media_key_readers(devices: Vec<MediaKeyDeviceInfo>, sender: Sender<MediaKeyEvent>) {
    for info in devices {
        let thread_sender = sender.clone();
        thread::Builder::new()
            .name(format!(
                "shadow-guest-media-{}",
                info.path
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or("event")
            ))
            .spawn(move || {
                if let Err(error) = run_media_key_reader(info.clone(), thread_sender) {
                    tracing::debug!(
                        "[shadow-guest-compositor] media-key-reader-failed device={} error={error}",
                        info.path.display()
                    );
                }
            })
            .expect("spawn media key reader");
    }
}

fn run_media_key_reader(info: MediaKeyDeviceInfo, sender: Sender<MediaKeyEvent>) -> Result<()> {
    let mut reader = input_reader_stream(&info.path)?;
    let mut event_bytes = [0_u8; INPUT_EVENT_SIZE];
    loop {
        reader
            .read_exact(&mut event_bytes)
            .with_context(|| format!("read input events from {}", info.path.display()))?;
        let event = parse_raw_input_event(&event_bytes);
        let Some(action) = media_action_from_raw(event) else {
            continue;
        };
        tracing::info!(
            "[shadow-guest-compositor] media-key-event device={} name={} action={}",
            info.path.display(),
            info.name,
            action.as_token()
        );
        if sender.send(MediaKeyEvent { action }).is_err() {
            return Ok(());
        }
    }
}

const INPUT_EVENT_SIZE: usize = 24;
const EV_KEY: u16 = 0x01;
const KEY_VOLUMEDOWN: u16 = 114;
const KEY_VOLUMEUP: u16 = 115;
const KEY_PAUSE: u16 = 119;
const KEY_NEXTSONG: u16 = 163;
const KEY_PLAYPAUSE: u16 = 164;
const KEY_PREVIOUSSONG: u16 = 165;
const KEY_PLAY: u16 = 207;

fn parse_raw_input_event(bytes: &[u8; INPUT_EVENT_SIZE]) -> RawInputEvent {
    let event_type = u16::from_ne_bytes(bytes[16..18].try_into().expect("event type"));
    let code = u16::from_ne_bytes(bytes[18..20].try_into().expect("event code"));
    let value = i32::from_ne_bytes(bytes[20..24].try_into().expect("event value"));
    RawInputEvent {
        event_type,
        code,
        value,
    }
}

fn media_action_from_raw(event: RawInputEvent) -> Option<MediaAction> {
    if event.event_type != EV_KEY || event.value != 1 {
        return None;
    }
    match event.code {
        KEY_PLAYPAUSE => Some(MediaAction::PlayPause),
        KEY_PLAY => Some(MediaAction::Play),
        KEY_PAUSE => Some(MediaAction::Pause),
        KEY_NEXTSONG => Some(MediaAction::Next),
        KEY_PREVIOUSSONG => Some(MediaAction::Previous),
        KEY_VOLUMEUP => Some(MediaAction::VolumeUp),
        KEY_VOLUMEDOWN => Some(MediaAction::VolumeDown),
        _ => None,
    }
}

fn input_reader_stream(path: &Path) -> Result<Box<dyn Read + Send>> {
    let input_path = path.to_string_lossy().to_string();
    let dd_command = format!("dd if={input_path} bs={INPUT_EVENT_SIZE} status=none");
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
                    .context("capture media key reader stdout")?;
                tracing::info!(
                    "[shadow-guest-compositor] media-key-reader-helper helper={} device={} pid={}",
                    helper,
                    path.display(),
                    child.id()
                );
                return Ok(Box::new(ChildReader { child, stdout }));
            }
            Err(error) => {
                tracing::debug!(
                    "[shadow-guest-compositor] media-key-reader-helper-failed helper={} device={} error={}",
                    helper,
                    path.display(),
                    error
                );
            }
        }
    }

    tracing::info!(
        "[shadow-guest-compositor] media-key-reader-direct device={}",
        path.display()
    );
    Ok(Box::new(fs::File::open(path).with_context(|| {
        format!("open input device {}", path.display())
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

fn is_event_path(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.starts_with("event"))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::{
        media_action_from_raw, RawInputEvent, EV_KEY, KEY_NEXTSONG, KEY_PLAYPAUSE,
        KEY_PREVIOUSSONG, KEY_VOLUMEDOWN, KEY_VOLUMEUP,
    };
    use shadow_ui_core::control::MediaAction;

    #[test]
    fn maps_pressed_key_events_to_media_actions() {
        assert_eq!(
            media_action_from_raw(RawInputEvent {
                event_type: EV_KEY,
                code: KEY_PLAYPAUSE,
                value: 1,
            }),
            Some(MediaAction::PlayPause)
        );
        assert_eq!(
            media_action_from_raw(RawInputEvent {
                event_type: EV_KEY,
                code: KEY_NEXTSONG,
                value: 1,
            }),
            Some(MediaAction::Next)
        );
        assert_eq!(
            media_action_from_raw(RawInputEvent {
                event_type: EV_KEY,
                code: KEY_PREVIOUSSONG,
                value: 1,
            }),
            Some(MediaAction::Previous)
        );
        assert_eq!(
            media_action_from_raw(RawInputEvent {
                event_type: EV_KEY,
                code: KEY_VOLUMEUP,
                value: 1,
            }),
            Some(MediaAction::VolumeUp)
        );
        assert_eq!(
            media_action_from_raw(RawInputEvent {
                event_type: EV_KEY,
                code: KEY_VOLUMEDOWN,
                value: 1,
            }),
            Some(MediaAction::VolumeDown)
        );
    }

    #[test]
    fn ignores_key_release_and_repeat_events() {
        assert_eq!(
            media_action_from_raw(RawInputEvent {
                event_type: EV_KEY,
                code: KEY_PLAYPAUSE,
                value: 0,
            }),
            None
        );
        assert_eq!(
            media_action_from_raw(RawInputEvent {
                event_type: EV_KEY,
                code: KEY_PLAYPAUSE,
                value: 2,
            }),
            None
        );
    }
}
