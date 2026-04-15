use std::collections::BTreeMap;
use std::env;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use deno_core::extension;
use deno_core::op2;
use deno_core::Extension;
use deno_core::OpState;
use deno_error::JsErrorBox;
use serde::{Deserialize, Serialize};

const AUDIO_BACKEND_ENV: &str = "SHADOW_RUNTIME_AUDIO_BACKEND";
const AUDIO_BUNDLE_DIR_ENV: &str = "SHADOW_RUNTIME_BUNDLE_DIR";
const AUDIO_SPIKE_BINARY_ENV: &str = "SHADOW_RUNTIME_AUDIO_SPIKE_BINARY";
const AUDIO_SPIKE_GAIN_ENV: &str = "SHADOW_RUNTIME_AUDIO_SPIKE_GAIN";
const AUDIO_SPIKE_STAGE_LIBRARY_PATH_ENV: &str = "SHADOW_RUNTIME_AUDIO_SPIKE_STAGE_LIBRARY_PATH";
const AUDIO_SPIKE_STAGE_LOADER_PATH_ENV: &str = "SHADOW_RUNTIME_AUDIO_SPIKE_STAGE_LOADER_PATH";
const DEFAULT_DURATION_MS: u32 = 2_400;
const DEFAULT_FREQUENCY_HZ: u32 = 440;

#[derive(Debug)]
struct AudioHostState {
    service: Result<AudioHostService, String>,
}

impl AudioHostState {
    fn from_env() -> Self {
        Self {
            service: AudioHostService::from_env(),
        }
    }

    fn service_mut(&mut self) -> Result<&mut AudioHostService, JsErrorBox> {
        self.service
            .as_mut()
            .map_err(|error| JsErrorBox::generic(error.clone()))
    }
}

#[derive(Debug)]
struct AudioHostService {
    backend: AudioBackend,
    next_id: u32,
    players: BTreeMap<u32, AudioPlayer>,
}

impl AudioHostService {
    fn from_env() -> Result<Self, String> {
        Ok(Self {
            backend: AudioBackend::from_env()?,
            next_id: 1,
            players: BTreeMap::new(),
        })
    }

    fn create_player(
        &mut self,
        request: CreatePlayerRequest,
    ) -> Result<AudioPlayerStatus, JsErrorBox> {
        let source = AudioSource::try_from(request.source)?;
        let id = self.next_id;
        self.next_id = self
            .next_id
            .checked_add(1)
            .ok_or_else(|| JsErrorBox::generic("audio.createPlayer exhausted player ids"))?;
        let player = AudioPlayer::new(id, source, &self.backend);
        self.players.insert(id, player);
        self.status_for(id)
    }

    fn play(&mut self, request: PlayerHandleRequest) -> Result<AudioPlayerStatus, JsErrorBox> {
        let backend = self.backend.clone();
        let player = self.player_mut(request.id)?;
        player.play(&backend)?;
        Ok(player.status(&backend))
    }

    fn pause(&mut self, request: PlayerHandleRequest) -> Result<AudioPlayerStatus, JsErrorBox> {
        let backend = self.backend.clone();
        let player = self.player_mut(request.id)?;
        player.pause()?;
        Ok(player.status(&backend))
    }

    fn stop(&mut self, request: PlayerHandleRequest) -> Result<AudioPlayerStatus, JsErrorBox> {
        let backend = self.backend.clone();
        let player = self.player_mut(request.id)?;
        player.stop()?;
        Ok(player.status(&backend))
    }

    fn release(&mut self, request: PlayerHandleRequest) -> Result<AudioPlayerStatus, JsErrorBox> {
        let backend = self.backend.clone();
        let mut player = self
            .players
            .remove(&request.id)
            .ok_or_else(|| unknown_player_error(request.id))?;
        player.release()?;
        Ok(player.status(&backend))
    }

    fn status_for(&mut self, id: u32) -> Result<AudioPlayerStatus, JsErrorBox> {
        let backend = self.backend.clone();
        let player = self.player_mut(id)?;
        Ok(player.status(&backend))
    }

    fn player_mut(&mut self, id: u32) -> Result<&mut AudioPlayer, JsErrorBox> {
        self.players
            .get_mut(&id)
            .ok_or_else(|| unknown_player_error(id))
    }
}

#[derive(Clone, Debug)]
enum AudioBackend {
    Memory,
    LinuxSpike { binary_path: String },
}

impl AudioBackend {
    fn from_env() -> Result<Self, String> {
        let value = std::env::var(AUDIO_BACKEND_ENV)
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| String::from("memory"));

        match value.as_str() {
            "memory" => Ok(Self::Memory),
            "linux_spike" => {
                let binary_path = std::env::var(AUDIO_SPIKE_BINARY_ENV)
                    .ok()
                    .map(|value| value.trim().to_owned())
                    .filter(|value| !value.is_empty())
                    .ok_or_else(|| {
                        format!(
                            "runtime audio host: {AUDIO_SPIKE_BINARY_ENV} is required for linux_spike backend"
                        )
                    })?;
                Ok(Self::LinuxSpike { binary_path })
            }
            _ => Err(format!(
                "runtime audio host: unsupported backend '{value}', expected memory or linux_spike"
            )),
        }
    }

    fn name(&self) -> &'static str {
        match self {
            Self::Memory => "memory",
            Self::LinuxSpike { .. } => "linux_spike",
        }
    }
}

#[derive(Debug)]
struct AudioPlayer {
    id: u32,
    last_error: Option<String>,
    runtime: PlayerRuntime,
    source: AudioSource,
}

impl AudioPlayer {
    fn new(id: u32, source: AudioSource, backend: &AudioBackend) -> Self {
        let runtime = match backend {
            AudioBackend::Memory => PlayerRuntime::Memory(MemoryPlayerRuntime::default()),
            AudioBackend::LinuxSpike { .. } => {
                PlayerRuntime::LinuxSpike(LinuxSpikePlayerRuntime::default())
            }
        };
        Self {
            id,
            last_error: None,
            runtime,
            source,
        }
    }

    fn play(&mut self, backend: &AudioBackend) -> Result<(), JsErrorBox> {
        self.runtime.reconcile(&self.source, &mut self.last_error);
        self.runtime
            .play(&self.source, backend, &mut self.last_error)
    }

    fn pause(&mut self) -> Result<(), JsErrorBox> {
        self.runtime.reconcile(&self.source, &mut self.last_error);
        self.runtime.pause(&mut self.last_error)
    }

    fn stop(&mut self) -> Result<(), JsErrorBox> {
        self.runtime.stop(&mut self.last_error)
    }

    fn release(&mut self) -> Result<(), JsErrorBox> {
        self.runtime.release(&mut self.last_error)
    }

    fn status(&mut self, backend: &AudioBackend) -> AudioPlayerStatus {
        self.runtime.reconcile(&self.source, &mut self.last_error);
        AudioPlayerStatus {
            backend: String::from(backend.name()),
            duration_ms: self.source.duration_ms(),
            error: self.last_error.clone(),
            frequency_hz: self.source.frequency_hz(),
            id: self.id,
            path: self.source.path().map(str::to_owned),
            source_kind: String::from(self.source.kind()),
            state: String::from(self.runtime.state().as_str()),
        }
    }
}

#[derive(Debug)]
enum PlayerRuntime {
    Memory(MemoryPlayerRuntime),
    LinuxSpike(LinuxSpikePlayerRuntime),
}

impl PlayerRuntime {
    fn play(
        &mut self,
        source: &AudioSource,
        backend: &AudioBackend,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        match self {
            Self::Memory(runtime) => runtime.play(source, last_error),
            Self::LinuxSpike(runtime) => runtime.play(source, backend, last_error),
        }
    }

    fn pause(&mut self, last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        match self {
            Self::Memory(runtime) => runtime.pause(last_error),
            Self::LinuxSpike(runtime) => runtime.pause(last_error),
        }
    }

    fn stop(&mut self, last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        match self {
            Self::Memory(runtime) => runtime.stop(last_error),
            Self::LinuxSpike(runtime) => runtime.stop(last_error),
        }
    }

    fn release(&mut self, last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        match self {
            Self::Memory(runtime) => runtime.release(last_error),
            Self::LinuxSpike(runtime) => runtime.release(last_error),
        }
    }

    fn reconcile(&mut self, source: &AudioSource, last_error: &mut Option<String>) {
        match self {
            Self::Memory(runtime) => runtime.reconcile(source),
            Self::LinuxSpike(runtime) => runtime.reconcile(last_error),
        }
    }

    fn state(&self) -> PlayerState {
        match self {
            Self::Memory(runtime) => runtime.state,
            Self::LinuxSpike(runtime) => runtime.state,
        }
    }
}

#[derive(Debug)]
struct MemoryPlayerRuntime {
    elapsed_before_pause: Duration,
    started_at: Option<Instant>,
    state: PlayerState,
}

impl Default for MemoryPlayerRuntime {
    fn default() -> Self {
        Self {
            elapsed_before_pause: Duration::from_millis(0),
            started_at: None,
            state: PlayerState::Idle,
        }
    }
}

impl MemoryPlayerRuntime {
    fn play(
        &mut self,
        _source: &AudioSource,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        if self.state == PlayerState::Released {
            return Err(JsErrorBox::generic(
                "audio.play cannot resume a released player",
            ));
        }

        if self.state == PlayerState::Paused {
            self.started_at = Some(Instant::now());
        } else if self.state != PlayerState::Playing {
            self.elapsed_before_pause = Duration::from_millis(0);
            self.started_at = Some(Instant::now());
        }
        self.state = PlayerState::Playing;
        *last_error = None;
        Ok(())
    }

    fn pause(&mut self, _last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        if self.state == PlayerState::Released {
            return Err(JsErrorBox::generic(
                "audio.pause cannot target a released player",
            ));
        }

        if self.state == PlayerState::Playing {
            if let Some(started_at) = self.started_at.take() {
                self.elapsed_before_pause += started_at.elapsed();
            }
            self.state = PlayerState::Paused;
        }
        Ok(())
    }

    fn stop(&mut self, last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        if self.state == PlayerState::Released {
            return Err(JsErrorBox::generic(
                "audio.stop cannot target a released player",
            ));
        }

        self.elapsed_before_pause = Duration::from_millis(0);
        self.started_at = None;
        self.state = PlayerState::Stopped;
        *last_error = None;
        Ok(())
    }

    fn release(&mut self, last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        self.stop(last_error)?;
        self.state = PlayerState::Released;
        Ok(())
    }

    fn reconcile(&mut self, source: &AudioSource) {
        if self.state != PlayerState::Playing {
            return;
        }
        let Some(started_at) = self.started_at else {
            return;
        };
        let elapsed = self.elapsed_before_pause + started_at.elapsed();
        if elapsed >= source.duration() {
            self.elapsed_before_pause = source.duration();
            self.started_at = None;
            self.state = PlayerState::Completed;
        }
    }
}

#[derive(Debug)]
struct LinuxSpikePlayerRuntime {
    child: Option<Child>,
    state: PlayerState,
}

impl Default for LinuxSpikePlayerRuntime {
    fn default() -> Self {
        Self {
            child: None,
            state: PlayerState::Idle,
        }
    }
}

impl LinuxSpikePlayerRuntime {
    fn play(
        &mut self,
        source: &AudioSource,
        backend: &AudioBackend,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        match self.state {
            PlayerState::Released => {
                return Err(JsErrorBox::generic(
                    "audio.play cannot resume a released player",
                ))
            }
            PlayerState::Paused => {
                if let Some(child) = self.child.as_ref() {
                    send_signal(child, libc::SIGCONT)?;
                    self.state = PlayerState::Playing;
                    *last_error = None;
                    return Ok(());
                }
            }
            _ => {}
        }

        self.stop(last_error)?;
        let binary_path = match backend {
            AudioBackend::LinuxSpike { binary_path } => binary_path.as_str(),
            AudioBackend::Memory => {
                return Err(JsErrorBox::generic(
                    "audio.play requested linux spike playback on memory backend",
                ))
            }
        };

        let stage_loader_path = env::var(AUDIO_SPIKE_STAGE_LOADER_PATH_ENV)
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        let stage_library_path = env::var(AUDIO_SPIKE_STAGE_LIBRARY_PATH_ENV)
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        let spike_gain = env::var(AUDIO_SPIKE_GAIN_ENV)
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        eprintln!(
            "runtime-audio-host linux-spike-config binary={} loader={} library_path={} gain={}",
            binary_path,
            stage_loader_path.as_deref().unwrap_or("none"),
            stage_library_path.as_deref().unwrap_or("none"),
            spike_gain.as_deref().unwrap_or("default"),
        );
        let mut command = match stage_loader_path.as_deref() {
            Some(loader_path) => {
                let mut command = Command::new(loader_path);
                if let Some(library_path) = stage_library_path.as_deref() {
                    command.arg("--library-path").arg(library_path);
                }
                command.arg(binary_path);
                command
            }
            None => Command::new(binary_path),
        };
        command
            .env(
                "SHADOW_AUDIO_SPIKE_DURATION_MS",
                source.duration_ms().to_string(),
            )
            .env("SHADOW_AUDIO_SPIKE_SOURCE_KIND", source.kind())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        if let Some(gain) = spike_gain.as_deref() {
            command.env("SHADOW_AUDIO_SPIKE_GAIN", gain);
        }
        match source {
            AudioSource::Tone(source) => {
                command.env(
                    "SHADOW_AUDIO_SPIKE_FREQUENCY_HZ",
                    source.frequency_hz.to_string(),
                );
            }
            AudioSource::File(source) => {
                command.env("SHADOW_AUDIO_SPIKE_FILE_PATH", &source.resolved_path);
            }
        }
        let child = command.spawn().map_err(|error| {
            JsErrorBox::generic(format!(
                "audio.play spawn linux spike helper binary={} loader={} library_path={}: {error}",
                binary_path,
                stage_loader_path.as_deref().unwrap_or("none"),
                stage_library_path.as_deref().unwrap_or("none"),
            ))
        })?;
        match source {
            AudioSource::Tone(source) => {
                eprintln!(
                    "runtime-audio-host linux-spike-spawn binary={} kind=tone duration_ms={} frequency_hz={} pid={}",
                    binary_path,
                    source.duration_ms,
                    source.frequency_hz,
                    child.id()
                );
            }
            AudioSource::File(source) => {
                eprintln!(
                    "runtime-audio-host linux-spike-spawn binary={} kind=file duration_ms={} path={} pid={}",
                    binary_path,
                    source.duration_ms,
                    source.path,
                    child.id()
                );
            }
        }
        self.child = Some(child);
        self.state = PlayerState::Playing;
        *last_error = None;
        Ok(())
    }

    fn pause(&mut self, _last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        if self.state == PlayerState::Released {
            return Err(JsErrorBox::generic(
                "audio.pause cannot target a released player",
            ));
        }

        if self.state == PlayerState::Playing {
            if let Some(child) = self.child.as_ref() {
                send_signal(child, libc::SIGSTOP)?;
                self.state = PlayerState::Paused;
            }
        }
        Ok(())
    }

    fn stop(&mut self, last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        if let Some(mut child) = self.child.take() {
            child
                .kill()
                .map_err(|error| JsErrorBox::generic(format!("audio.stop kill player: {error}")))?;
            child
                .wait()
                .map_err(|error| JsErrorBox::generic(format!("audio.stop wait player: {error}")))?;
        }

        if self.state != PlayerState::Released {
            self.state = PlayerState::Stopped;
        }
        *last_error = None;
        Ok(())
    }

    fn release(&mut self, last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        self.stop(last_error)?;
        self.state = PlayerState::Released;
        Ok(())
    }

    fn reconcile(&mut self, last_error: &mut Option<String>) {
        let Some(child) = self.child.as_mut() else {
            return;
        };

        match child.try_wait() {
            Ok(None) => {}
            Ok(Some(status)) => {
                self.child = None;
                eprintln!(
                    "runtime-audio-host linux-spike-exit success={} status={}",
                    status.success(),
                    status
                );
                if status.success() {
                    self.state = PlayerState::Completed;
                    *last_error = None;
                } else {
                    self.state = PlayerState::Error;
                    *last_error = Some(format!("linux spike helper exited with status {status}"));
                }
            }
            Err(error) => {
                self.child = None;
                self.state = PlayerState::Error;
                *last_error = Some(format!("audio.getStatus wait linux spike helper: {error}"));
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PlayerState {
    Idle,
    Playing,
    Paused,
    Stopped,
    Completed,
    Released,
    Error,
}

impl PlayerState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Playing => "playing",
            Self::Paused => "paused",
            Self::Stopped => "stopped",
            Self::Completed => "completed",
            Self::Released => "released",
            Self::Error => "error",
        }
    }
}

#[derive(Clone, Debug)]
enum AudioSource {
    Tone(ToneSource),
    File(FileSource),
}

impl AudioSource {
    fn duration(&self) -> Duration {
        Duration::from_millis(u64::from(self.duration_ms()))
    }

    fn duration_ms(&self) -> u32 {
        match self {
            Self::Tone(source) => source.duration_ms,
            Self::File(source) => source.duration_ms,
        }
    }

    fn frequency_hz(&self) -> Option<u32> {
        match self {
            Self::Tone(source) => Some(source.frequency_hz),
            Self::File(_) => None,
        }
    }

    fn kind(&self) -> &'static str {
        match self {
            Self::Tone(_) => "tone",
            Self::File(_) => "file",
        }
    }

    fn path(&self) -> Option<&str> {
        match self {
            Self::Tone(_) => None,
            Self::File(source) => Some(source.path.as_str()),
        }
    }
}

#[derive(Clone, Debug)]
struct ToneSource {
    duration_ms: u32,
    frequency_hz: u32,
}

#[derive(Clone, Debug)]
struct FileSource {
    duration_ms: u32,
    path: String,
    resolved_path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreatePlayerRequest {
    #[serde(default)]
    source: AudioSourceRequest,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlayerHandleRequest {
    id: u32,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AudioSourceRequest {
    #[serde(default = "default_audio_source_kind")]
    kind: String,
    #[serde(default = "default_duration_ms")]
    duration_ms: u32,
    #[serde(default = "default_frequency_hz")]
    frequency_hz: u32,
    path: Option<String>,
}

impl Default for AudioSourceRequest {
    fn default() -> Self {
        Self {
            kind: default_audio_source_kind(),
            duration_ms: default_duration_ms(),
            frequency_hz: default_frequency_hz(),
            path: None,
        }
    }
}

impl TryFrom<AudioSourceRequest> for AudioSource {
    type Error = JsErrorBox;

    fn try_from(request: AudioSourceRequest) -> Result<Self, Self::Error> {
        if request.duration_ms == 0 {
            return Err(JsErrorBox::type_error(
                "audio.createPlayer requires source.durationMs > 0",
            ));
        }
        match request.kind.as_str() {
            "tone" => {
                if request.frequency_hz == 0 {
                    return Err(JsErrorBox::type_error(
                        "audio.createPlayer requires source.frequencyHz > 0",
                    ));
                }
                Ok(Self::Tone(ToneSource {
                    duration_ms: request.duration_ms,
                    frequency_hz: request.frequency_hz,
                }))
            }
            "file" => {
                let path = request
                    .path
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .ok_or_else(|| {
                        JsErrorBox::type_error("audio.createPlayer requires source.path")
                    })?
                    .to_owned();
                Ok(Self::File(FileSource {
                    duration_ms: request.duration_ms,
                    resolved_path: resolve_source_path(Some(path.clone()))?,
                    path,
                }))
            }
            _ => Err(JsErrorBox::generic(format!(
                "audio.createPlayer does not support source kind '{}'",
                request.kind
            ))),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AudioPlayerStatus {
    backend: String,
    duration_ms: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    frequency_hz: Option<u32>,
    id: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<String>,
    source_kind: String,
    state: String,
}

#[op2]
#[serde]
fn op_runtime_audio_create_player(
    state: &mut OpState,
    #[serde] request: CreatePlayerRequest,
) -> Result<AudioPlayerStatus, JsErrorBox> {
    state
        .borrow_mut::<AudioHostState>()
        .service_mut()?
        .create_player(request)
}

#[op2]
#[serde]
fn op_runtime_audio_play(
    state: &mut OpState,
    #[serde] request: PlayerHandleRequest,
) -> Result<AudioPlayerStatus, JsErrorBox> {
    state
        .borrow_mut::<AudioHostState>()
        .service_mut()?
        .play(request)
}

#[op2]
#[serde]
fn op_runtime_audio_pause(
    state: &mut OpState,
    #[serde] request: PlayerHandleRequest,
) -> Result<AudioPlayerStatus, JsErrorBox> {
    state
        .borrow_mut::<AudioHostState>()
        .service_mut()?
        .pause(request)
}

#[op2]
#[serde]
fn op_runtime_audio_stop(
    state: &mut OpState,
    #[serde] request: PlayerHandleRequest,
) -> Result<AudioPlayerStatus, JsErrorBox> {
    state
        .borrow_mut::<AudioHostState>()
        .service_mut()?
        .stop(request)
}

#[op2]
#[serde]
fn op_runtime_audio_release(
    state: &mut OpState,
    #[serde] request: PlayerHandleRequest,
) -> Result<AudioPlayerStatus, JsErrorBox> {
    state
        .borrow_mut::<AudioHostState>()
        .service_mut()?
        .release(request)
}

#[op2]
#[serde]
fn op_runtime_audio_get_status(
    state: &mut OpState,
    #[serde] request: PlayerHandleRequest,
) -> Result<AudioPlayerStatus, JsErrorBox> {
    state
        .borrow_mut::<AudioHostState>()
        .service_mut()?
        .status_for(request.id)
}

fn default_audio_source_kind() -> String {
    String::from("tone")
}

fn default_duration_ms() -> u32 {
    DEFAULT_DURATION_MS
}

fn default_frequency_hz() -> u32 {
    DEFAULT_FREQUENCY_HZ
}

fn resolve_source_path(path: Option<String>) -> Result<String, JsErrorBox> {
    let trimmed = path
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| JsErrorBox::type_error("audio.createPlayer requires source.path"))?;
    let candidate = PathBuf::from(trimmed);
    if candidate.is_absolute() {
        return Ok(candidate.display().to_string());
    }

    let bundle_dir = env::var(AUDIO_BUNDLE_DIR_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            JsErrorBox::generic(format!(
                "audio.createPlayer requires {AUDIO_BUNDLE_DIR_ENV} for relative source.path values"
            ))
        })?;
    Ok(Path::new(&bundle_dir).join(candidate).display().to_string())
}

fn send_signal(child: &Child, signal: i32) -> Result<(), JsErrorBox> {
    let pid = i32::try_from(child.id())
        .map_err(|_| JsErrorBox::generic("audio backend produced an invalid child pid"))?;
    let result = unsafe { libc::kill(pid, signal) };
    if result == 0 {
        Ok(())
    } else {
        Err(JsErrorBox::generic(format!(
            "audio backend send signal {signal} to pid {pid}: {}",
            std::io::Error::last_os_error()
        )))
    }
}

fn unknown_player_error(id: u32) -> JsErrorBox {
    JsErrorBox::type_error(format!(
        "audio op requires a known positive integer id, got {id}"
    ))
}

extension!(
    runtime_audio_host_extension,
    ops = [
        op_runtime_audio_create_player,
        op_runtime_audio_play,
        op_runtime_audio_pause,
        op_runtime_audio_stop,
        op_runtime_audio_release,
        op_runtime_audio_get_status
    ],
    esm_entry_point = "ext:runtime_audio_host_extension/bootstrap.js",
    esm = [dir "js", "bootstrap.js"],
    state = |state| {
        state.put(AudioHostState::from_env());
    },
);

pub fn init_extension() -> Extension {
    runtime_audio_host_extension::init()
}
