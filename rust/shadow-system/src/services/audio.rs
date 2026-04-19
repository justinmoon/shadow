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
const DEFAULT_PLAYER_VOLUME: f32 = 1.0;

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
        let status = {
            let player = self.player_mut(request.id)?;
            player.release()?;
            player.status(&backend)
        };
        self.players.remove(&request.id);
        Ok(status)
    }

    fn seek(&mut self, request: SeekRequest) -> Result<AudioPlayerStatus, JsErrorBox> {
        let backend = self.backend.clone();
        let player = self.player_mut(request.id)?;
        player.seek(request.position_ms, &backend)?;
        Ok(player.status(&backend))
    }

    fn set_volume(&mut self, request: SetVolumeRequest) -> Result<AudioPlayerStatus, JsErrorBox> {
        let backend = self.backend.clone();
        let player = self.player_mut(request.id)?;
        player.set_volume(request.volume, &backend)?;
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
                            "shadow-system audio: {AUDIO_SPIKE_BINARY_ENV} is required for linux_spike backend"
                        )
                    })?;
                Ok(Self::LinuxSpike { binary_path })
            }
            _ => Err(format!(
                "shadow-system audio: unsupported backend '{value}', expected memory or linux_spike"
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
    volume: f32,
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
            volume: DEFAULT_PLAYER_VOLUME,
        }
    }

    fn play(&mut self, backend: &AudioBackend) -> Result<(), JsErrorBox> {
        self.runtime.reconcile(&self.source, &mut self.last_error);
        self.runtime
            .play(&self.source, backend, self.volume, &mut self.last_error)
    }

    fn pause(&mut self) -> Result<(), JsErrorBox> {
        self.runtime.reconcile(&self.source, &mut self.last_error);
        self.runtime.pause(&self.source, &mut self.last_error)
    }

    fn stop(&mut self) -> Result<(), JsErrorBox> {
        self.runtime.reconcile(&self.source, &mut self.last_error);
        self.runtime.stop(&mut self.last_error)
    }

    fn release(&mut self) -> Result<(), JsErrorBox> {
        self.runtime.reconcile(&self.source, &mut self.last_error);
        self.runtime.release(&mut self.last_error)
    }

    fn seek(&mut self, position_ms: u32, backend: &AudioBackend) -> Result<(), JsErrorBox> {
        let requested = Duration::from_millis(u64::from(position_ms));
        if requested > self.source.duration() {
            return Err(JsErrorBox::type_error(format!(
                "audio.seek requires positionMs <= durationMs ({}), got {position_ms}",
                self.source.duration_ms()
            )));
        }
        self.runtime.reconcile(&self.source, &mut self.last_error);
        self.runtime.seek(
            &self.source,
            backend,
            requested,
            self.volume,
            &mut self.last_error,
        )
    }

    fn set_volume(&mut self, volume: f32, backend: &AudioBackend) -> Result<(), JsErrorBox> {
        if !volume.is_finite() || !(0.0..=1.0).contains(&volume) {
            return Err(JsErrorBox::type_error(format!(
                "audio.setVolume requires 0.0 <= volume <= 1.0, got {volume}"
            )));
        }
        self.runtime.reconcile(&self.source, &mut self.last_error);
        self.runtime
            .set_volume(&self.source, backend, volume, &mut self.last_error)?;
        self.volume = volume;
        Ok(())
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
            position_ms: duration_to_millis_u32(self.runtime.position(&self.source)),
            url: self.source.url().map(str::to_owned),
            source_kind: String::from(self.source.kind()),
            state: String::from(self.runtime.state().as_str()),
            volume: self.volume,
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
        volume: f32,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        match self {
            Self::Memory(runtime) => runtime.play(source, last_error),
            Self::LinuxSpike(runtime) => runtime.play(source, backend, volume, last_error),
        }
    }

    fn pause(
        &mut self,
        source: &AudioSource,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        match self {
            Self::Memory(runtime) => runtime.pause(source, last_error),
            Self::LinuxSpike(runtime) => runtime.pause(source, last_error),
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
            Self::LinuxSpike(runtime) => runtime.reconcile(source, last_error),
        }
    }

    fn state(&self) -> PlayerState {
        match self {
            Self::Memory(runtime) => runtime.state,
            Self::LinuxSpike(runtime) => runtime.state,
        }
    }

    fn position(&self, source: &AudioSource) -> Duration {
        match self {
            Self::Memory(runtime) => runtime.position(source),
            Self::LinuxSpike(runtime) => runtime.position(source),
        }
    }

    fn seek(
        &mut self,
        source: &AudioSource,
        backend: &AudioBackend,
        position: Duration,
        volume: f32,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        match self {
            Self::Memory(runtime) => runtime.seek(source, position, last_error),
            Self::LinuxSpike(runtime) => {
                runtime.seek(source, backend, position, volume, last_error)
            }
        }
    }

    fn set_volume(
        &mut self,
        source: &AudioSource,
        backend: &AudioBackend,
        volume: f32,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        match self {
            Self::Memory(_) => {
                *last_error = None;
                Ok(())
            }
            Self::LinuxSpike(runtime) => runtime.set_volume(source, backend, volume, last_error),
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

    fn pause(
        &mut self,
        source: &AudioSource,
        _last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        if self.state == PlayerState::Released {
            return Err(JsErrorBox::generic(
                "audio.pause cannot target a released player",
            ));
        }

        if self.state == PlayerState::Playing {
            self.elapsed_before_pause = self.position(source);
            self.started_at = None;
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
        let elapsed = self.position(source);
        if elapsed >= source.duration() {
            self.elapsed_before_pause = source.duration();
            self.started_at = None;
            self.state = PlayerState::Completed;
        }
    }

    fn position(&self, source: &AudioSource) -> Duration {
        let started_elapsed = self
            .started_at
            .map(|started_at| started_at.elapsed())
            .unwrap_or_default();
        (self.elapsed_before_pause + started_elapsed).min(source.duration())
    }

    fn seek(
        &mut self,
        source: &AudioSource,
        position: Duration,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        if self.state == PlayerState::Released {
            return Err(JsErrorBox::generic(
                "audio.seek cannot target a released player",
            ));
        }

        let clamped = position.min(source.duration());
        self.elapsed_before_pause = clamped;
        if clamped >= source.duration() {
            self.started_at = None;
            self.state = PlayerState::Completed;
        } else if self.state == PlayerState::Playing {
            self.started_at = Some(Instant::now());
        } else {
            self.started_at = None;
            self.state = PlayerState::Paused;
        }
        *last_error = None;
        Ok(())
    }
}

#[derive(Debug)]
struct LinuxSpikePlayerRuntime {
    child: Option<Child>,
    elapsed_before_pause: Duration,
    started_at: Option<Instant>,
    state: PlayerState,
}

impl Default for LinuxSpikePlayerRuntime {
    fn default() -> Self {
        Self {
            child: None,
            elapsed_before_pause: Duration::from_millis(0),
            started_at: None,
            state: PlayerState::Idle,
        }
    }
}

impl LinuxSpikePlayerRuntime {
    fn play(
        &mut self,
        source: &AudioSource,
        backend: &AudioBackend,
        volume: f32,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        match self.state {
            PlayerState::Released => {
                return Err(JsErrorBox::generic(
                    "audio.play cannot resume a released player",
                ))
            }
            PlayerState::Playing => {
                *last_error = None;
                return Ok(());
            }
            PlayerState::Paused => {
                if let Some(child) = self.child.as_ref() {
                    send_signal(child, libc::SIGCONT)?;
                    self.started_at = Some(Instant::now());
                    self.state = PlayerState::Playing;
                    *last_error = None;
                    return Ok(());
                }
            }
            _ => {}
        }

        if self.state == PlayerState::Completed && self.elapsed_before_pause >= source.duration() {
            self.elapsed_before_pause = Duration::from_millis(0);
        }
        self.kill_child("audio.play")?;
        self.child = Some(self.spawn_helper(source, backend, self.elapsed_before_pause, volume)?);
        self.started_at = Some(Instant::now());
        self.state = PlayerState::Playing;
        *last_error = None;
        Ok(())
    }

    fn pause(
        &mut self,
        source: &AudioSource,
        _last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        if self.state == PlayerState::Released {
            return Err(JsErrorBox::generic(
                "audio.pause cannot target a released player",
            ));
        }

        if self.state == PlayerState::Playing {
            let position = self.position(source);
            if let Some(child) = self.child.as_ref() {
                send_signal(child, libc::SIGSTOP)?;
                self.elapsed_before_pause = position;
                self.started_at = None;
                self.state = PlayerState::Paused;
            }
        }
        Ok(())
    }

    fn stop(&mut self, last_error: &mut Option<String>) -> Result<(), JsErrorBox> {
        self.kill_child("audio.stop")?;
        self.elapsed_before_pause = Duration::from_millis(0);
        self.started_at = None;
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

    fn reconcile(&mut self, source: &AudioSource, last_error: &mut Option<String>) {
        let Some(child) = self.child.as_mut() else {
            return;
        };

        match child.try_wait() {
            Ok(None) => {}
            Ok(Some(status)) => {
                self.child = None;
                self.started_at = None;
                eprintln!(
                    "shadow-system-audio linux-spike-exit success={} status={}",
                    status.success(),
                    status
                );
                if status.success() {
                    self.elapsed_before_pause = source.duration();
                    self.state = PlayerState::Completed;
                    *last_error = None;
                } else {
                    self.state = PlayerState::Error;
                    *last_error = Some(format!("linux spike helper exited with status {status}"));
                }
            }
            Err(error) => {
                self.child = None;
                self.started_at = None;
                self.state = PlayerState::Error;
                *last_error = Some(format!("audio.getStatus wait linux spike helper: {error}"));
            }
        }
    }

    fn position(&self, source: &AudioSource) -> Duration {
        let started_elapsed = self
            .started_at
            .map(|started_at| started_at.elapsed())
            .unwrap_or_default();
        (self.elapsed_before_pause + started_elapsed).min(source.duration())
    }

    fn seek(
        &mut self,
        source: &AudioSource,
        backend: &AudioBackend,
        position: Duration,
        volume: f32,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        if self.state == PlayerState::Released {
            return Err(JsErrorBox::generic(
                "audio.seek cannot target a released player",
            ));
        }

        let was_playing = self.state == PlayerState::Playing;
        self.kill_child("audio.seek")?;
        self.elapsed_before_pause = position.min(source.duration());
        self.started_at = None;
        if self.elapsed_before_pause >= source.duration() {
            self.state = PlayerState::Completed;
            *last_error = None;
            return Ok(());
        }
        if was_playing {
            let child = match self.spawn_helper(source, backend, self.elapsed_before_pause, volume)
            {
                Ok(child) => child,
                Err(error) => {
                    self.child = None;
                    self.started_at = None;
                    self.state = PlayerState::Error;
                    *last_error = Some(error.to_string());
                    return Err(error);
                }
            };
            self.child = Some(child);
            self.started_at = Some(Instant::now());
            self.state = PlayerState::Playing;
        } else {
            self.state = PlayerState::Paused;
        }
        *last_error = None;
        Ok(())
    }

    fn set_volume(
        &mut self,
        source: &AudioSource,
        backend: &AudioBackend,
        volume: f32,
        last_error: &mut Option<String>,
    ) -> Result<(), JsErrorBox> {
        if self.state == PlayerState::Released {
            return Err(JsErrorBox::generic(
                "audio.setVolume cannot target a released player",
            ));
        }

        match self.state {
            PlayerState::Playing => {
                self.elapsed_before_pause = self.position(source);
                self.kill_child("audio.setVolume")?;
                if self.elapsed_before_pause >= source.duration() {
                    self.started_at = None;
                    self.state = PlayerState::Completed;
                } else {
                    let child =
                        match self.spawn_helper(source, backend, self.elapsed_before_pause, volume)
                        {
                            Ok(child) => child,
                            Err(error) => {
                                self.child = None;
                                self.started_at = None;
                                self.state = PlayerState::Error;
                                *last_error = Some(error.to_string());
                                return Err(error);
                            }
                        };
                    self.child = Some(child);
                    self.started_at = Some(Instant::now());
                    self.state = PlayerState::Playing;
                }
            }
            PlayerState::Paused => {
                self.kill_child("audio.setVolume")?;
                self.started_at = None;
                self.state = PlayerState::Paused;
            }
            _ => {}
        }
        *last_error = None;
        Ok(())
    }

    fn spawn_helper(
        &self,
        source: &AudioSource,
        backend: &AudioBackend,
        start_position: Duration,
        volume: f32,
    ) -> Result<Child, JsErrorBox> {
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
        let configured_gain = env::var(AUDIO_SPIKE_GAIN_ENV)
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
            .and_then(|value| value.parse::<f32>().ok())
            .unwrap_or(1.0);
        let resolved_gain = (configured_gain * volume).max(0.0);
        let start_ms = duration_to_millis_u32(start_position);
        eprintln!(
            "shadow-system-audio linux-spike-config binary={} loader={} library_path={} base_gain={} player_volume={} resolved_gain={} start_ms={}",
            binary_path,
            stage_loader_path.as_deref().unwrap_or("none"),
            stage_library_path.as_deref().unwrap_or("none"),
            configured_gain,
            volume,
            resolved_gain,
            start_ms,
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
            .env("SHADOW_AUDIO_SPIKE_GAIN", resolved_gain.to_string())
            .env("SHADOW_AUDIO_SPIKE_SOURCE_KIND", source.kind())
            .env("SHADOW_AUDIO_SPIKE_START_MS", start_ms.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
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
            AudioSource::Url(source) => {
                command.env("SHADOW_AUDIO_SPIKE_URL", &source.url);
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
                    "shadow-system-audio linux-spike-spawn binary={} kind=tone duration_ms={} frequency_hz={} start_ms={} volume={} pid={}",
                    binary_path,
                    source.duration_ms,
                    source.frequency_hz,
                    start_ms,
                    volume,
                    child.id()
                );
            }
            AudioSource::File(source) => {
                eprintln!(
                    "shadow-system-audio linux-spike-spawn binary={} kind=file duration_ms={} path={} start_ms={} volume={} pid={}",
                    binary_path,
                    source.duration_ms,
                    source.path,
                    start_ms,
                    volume,
                    child.id()
                );
            }
            AudioSource::Url(source) => {
                eprintln!(
                    "shadow-system-audio linux-spike-spawn binary={} kind=url duration_ms={} url={} start_ms={} volume={} pid={}",
                    binary_path,
                    source.duration_ms,
                    source.url,
                    start_ms,
                    volume,
                    child.id()
                );
            }
        }
        Ok(child)
    }

    fn kill_child(&mut self, context: &str) -> Result<(), JsErrorBox> {
        let Some(mut child) = self.child.take() else {
            self.started_at = None;
            return Ok(());
        };
        match child.try_wait() {
            Ok(Some(_)) => {}
            Ok(None) => {
                child.kill().map_err(|error| {
                    JsErrorBox::generic(format!("{context} kill linux spike helper: {error}"))
                })?;
            }
            Err(error) => {
                return Err(JsErrorBox::generic(format!(
                    "{context} poll linux spike helper: {error}"
                )));
            }
        }
        child.wait().map_err(|error| {
            JsErrorBox::generic(format!("{context} wait linux spike helper: {error}"))
        })?;
        self.started_at = None;
        Ok(())
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
    Url(UrlSource),
}

impl AudioSource {
    fn duration(&self) -> Duration {
        Duration::from_millis(u64::from(self.duration_ms()))
    }

    fn duration_ms(&self) -> u32 {
        match self {
            Self::Tone(source) => source.duration_ms,
            Self::File(source) => source.duration_ms,
            Self::Url(source) => source.duration_ms,
        }
    }

    fn frequency_hz(&self) -> Option<u32> {
        match self {
            Self::Tone(source) => Some(source.frequency_hz),
            Self::File(_) => None,
            Self::Url(_) => None,
        }
    }

    fn kind(&self) -> &'static str {
        match self {
            Self::Tone(_) => "tone",
            Self::File(_) => "file",
            Self::Url(_) => "url",
        }
    }

    fn path(&self) -> Option<&str> {
        match self {
            Self::Tone(_) => None,
            Self::File(source) => Some(source.path.as_str()),
            Self::Url(_) => None,
        }
    }

    fn url(&self) -> Option<&str> {
        match self {
            Self::Tone(_) => None,
            Self::File(_) => None,
            Self::Url(source) => Some(source.url.as_str()),
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

#[derive(Clone, Debug)]
struct UrlSource {
    duration_ms: u32,
    url: String,
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SeekRequest {
    id: u32,
    position_ms: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SetVolumeRequest {
    id: u32,
    volume: f32,
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
    url: Option<String>,
}

impl Default for AudioSourceRequest {
    fn default() -> Self {
        Self {
            kind: default_audio_source_kind(),
            duration_ms: default_duration_ms(),
            frequency_hz: default_frequency_hz(),
            path: None,
            url: None,
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
            "url" => {
                let url = request
                    .url
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .ok_or_else(|| {
                        JsErrorBox::type_error("audio.createPlayer requires source.url")
                    })?
                    .to_owned();
                Ok(Self::Url(UrlSource {
                    duration_ms: request.duration_ms,
                    url,
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
    position_ms: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
    source_kind: String,
    state: String,
    volume: f32,
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

#[op2]
#[serde]
fn op_runtime_audio_seek(
    state: &mut OpState,
    #[serde] request: SeekRequest,
) -> Result<AudioPlayerStatus, JsErrorBox> {
    state
        .borrow_mut::<AudioHostState>()
        .service_mut()?
        .seek(request)
}

#[op2]
#[serde]
fn op_runtime_audio_set_volume(
    state: &mut OpState,
    #[serde] request: SetVolumeRequest,
) -> Result<AudioPlayerStatus, JsErrorBox> {
    state
        .borrow_mut::<AudioHostState>()
        .service_mut()?
        .set_volume(request)
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

fn duration_to_millis_u32(duration: Duration) -> u32 {
    u32::try_from(duration.as_millis()).unwrap_or(u32::MAX)
}

extension!(
    runtime_audio_host_extension,
    ops = [
        op_runtime_audio_create_player,
        op_runtime_audio_play,
        op_runtime_audio_pause,
        op_runtime_audio_stop,
        op_runtime_audio_release,
        op_runtime_audio_get_status,
        op_runtime_audio_seek,
        op_runtime_audio_set_volume
    ],
    state = |state| {
        state.put(AudioHostState::from_env());
    },
);

pub fn init_extension() -> Extension {
    runtime_audio_host_extension::init()
}
