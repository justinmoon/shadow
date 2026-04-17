use std::collections::{BTreeSet, HashMap};
use std::env;
use std::error::Error;
use std::f32::consts::TAU;
use std::fs::{self, File};
use std::io::{Cursor, ErrorKind};
use std::path::Path;
use std::time::{Duration, Instant};

use alsa::ctl::{ElemId, ElemIface, ElemType};
use alsa::hctl::HCtl;
use alsa::pcm::{Access, Format, HwParams, PCM};
use alsa::{Direction, ValueOr};
use serde::Serialize;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSource, MediaSourceStream};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

const DEFAULT_DEVICE_CANDIDATES: [&str; 2] = ["default", "sysdefault"];
const URL_FETCH_CONNECT_TIMEOUT_SECS: u64 = 10;
const URL_FETCH_TOTAL_TIMEOUT_SECS: u64 = 600;

fn main() {
    if let Err(error) = run() {
        eprintln!("audio-spike-fatal error={error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let started = Instant::now();
    let validate_only = read_env_flag("SHADOW_AUDIO_SPIKE_VALIDATE_ONLY");
    let requested_duration_ms = read_env_u32("SHADOW_AUDIO_SPIKE_DURATION_MS", 1500);
    let requested_frequency_hz = read_env_u32("SHADOW_AUDIO_SPIKE_FREQUENCY_HZ", 440);
    let requested_rate_hz = read_env_u32("SHADOW_AUDIO_SPIKE_RATE", 48_000);
    let requested_channels = read_env_u32("SHADOW_AUDIO_SPIKE_CHANNELS", 2);
    let requested_gain = read_env_f32("SHADOW_AUDIO_SPIKE_GAIN", 1.0).max(0.0);
    let source_kind =
        read_env_string("SHADOW_AUDIO_SPIKE_SOURCE_KIND").unwrap_or_else(|| String::from("tone"));
    let requested_file_path = read_env_string("SHADOW_AUDIO_SPIKE_FILE_PATH");
    let requested_url = read_env_string("SHADOW_AUDIO_SPIKE_URL");
    let summary_path = env::var("SHADOW_AUDIO_SPIKE_SUMMARY_PATH").ok();
    let cwd = env::current_dir()
        .ok()
        .map(|path| path.display().to_string());
    let prepared_playback = prepare_playback(
        &source_kind,
        requested_duration_ms,
        requested_frequency_hz,
        requested_rate_hz,
        requested_channels,
        requested_gain,
        requested_file_path.as_deref(),
        requested_url.as_deref(),
    )?;

    let mut device_candidates = Vec::new();
    if let Ok(device) = env::var("SHADOW_AUDIO_SPIKE_DEVICE") {
        let trimmed = device.trim();
        if !trimmed.is_empty() {
            device_candidates.push(trimmed.to_owned());
        }
    }
    let dev_snd_entries = list_tree_entries("/dev/snd");
    let proc_asound_entries = list_tree_entries("/proc/asound");
    let proc_asound_cards = read_optional_text("/proc/asound/cards");
    let proc_asound_devices = read_optional_text("/proc/asound/devices");
    let proc_asound_pcm = read_optional_text("/proc/asound/pcm");
    let playback_devices = parse_playback_devices(proc_asound_pcm.as_deref());
    let playback_device_names = playback_devices
        .iter()
        .map(|device| (device.number, device.name.clone()))
        .collect::<HashMap<_, _>>();

    for candidate in DEFAULT_DEVICE_CANDIDATES {
        if !device_candidates.iter().any(|value| value == candidate) {
            device_candidates.push(String::from(candidate));
        }
    }
    for device_number in preferred_playback_order(&playback_devices) {
        let plughw = format!("plughw:0,{device_number}");
        if !device_candidates.iter().any(|value| value == &plughw) {
            device_candidates.push(plughw);
        }
        let hw = format!("hw:0,{device_number}");
        if !device_candidates.iter().any(|value| value == &hw) {
            device_candidates.push(hw);
        }
    }

    println!(
        "audio-spike-start source_kind={} source_path={} duration_ms={} frequency_hz={} rate_hz={} channels={} gain={} device_candidates={}",
        prepared_playback.source_kind,
        sanitize_log_field(prepared_playback.source_path.as_deref().unwrap_or("none")),
        prepared_playback.duration_ms,
        prepared_playback.frequency_hz.unwrap_or(0),
        prepared_playback.rate_hz,
        prepared_playback.channels,
        requested_gain,
        device_candidates.join(",")
    );

    println!("audio-spike-dev-snd entries={}", dev_snd_entries.len());
    println!(
        "audio-spike-proc-asound entries={}",
        proc_asound_entries.len()
    );

    let mut attempts = Vec::new();
    let mut playback = None;
    if validate_only {
        println!(
            "audio-spike-validate-ok source_kind={} source_path={} rate_hz={} channels={} duration_ms={}",
            prepared_playback.source_kind,
            sanitize_log_field(prepared_playback.source_path.as_deref().unwrap_or("none")),
            prepared_playback.rate_hz,
            prepared_playback.channels,
            prepared_playback.duration_ms,
        );
    } else {
        for device in &device_candidates {
            println!("audio-spike-attempt device={device}");
            let attempt_started = Instant::now();
            let route_name = route_plan_for_device(device)
                .map(|plan| plan.name)
                .map(str::to_owned);
            let attempt_result = match route_plan_for_device(device) {
                Some(route_plan) => with_route_plan(route_plan, || {
                    play_prepared_samples(device, &prepared_playback)
                }),
                None => play_prepared_samples(device, &prepared_playback),
            };
            match attempt_result {
                Ok(result) => {
                    let proxy_like = is_non_audible_candidate(device, &playback_device_names);
                    println!(
                        "audio-spike-playback-ok device={} elapsed_ms={} frames={} rate_hz={} channels={} buffer_frames={} period_frames={} proxy_like={} route={}",
                        device,
                        attempt_started.elapsed().as_millis(),
                        result.frames_requested,
                        result.actual_rate_hz,
                        result.actual_channels,
                        result.buffer_frames,
                        result.period_frames,
                        proxy_like,
                        route_name.as_deref().unwrap_or("none")
                    );
                    attempts.push(PcmAttempt {
                        device: device.clone(),
                        elapsed_ms: attempt_started.elapsed().as_millis(),
                        error: None,
                        frames_requested: result.frames_requested,
                        proxy_like,
                        route: route_name.clone(),
                        success: !proxy_like,
                    });
                    if proxy_like {
                        println!(
                            "audio-spike-playback-ignored device={} reason=proxy-or-hostless",
                            device
                        );
                    } else {
                        playback = Some(result.with_device(device.clone()));
                        break;
                    }
                }
                Err(error) => {
                    let message = error.to_string();
                    println!(
                        "audio-spike-playback-error device={} elapsed_ms={} error={}",
                        device,
                        attempt_started.elapsed().as_millis(),
                        sanitize_log_field(&message)
                    );
                    attempts.push(PcmAttempt {
                        device: device.clone(),
                        elapsed_ms: attempt_started.elapsed().as_millis(),
                        error: Some(message),
                        frames_requested: 0,
                        proxy_like: false,
                        route: route_name,
                        success: false,
                    });
                }
            }
        }
    }

    let success = validate_only || playback.is_some();
    let summary = AudioSpikeSummary {
        attempts,
        cwd,
        dev_snd_entries,
        elapsed_ms: started.elapsed().as_millis(),
        playback,
        proc_asound_cards,
        proc_asound_devices,
        proc_asound_entries,
        proc_asound_pcm,
        requested_channels: prepared_playback.channels,
        requested_duration_ms: prepared_playback.duration_ms,
        requested_frequency_hz: prepared_playback.frequency_hz.unwrap_or(0),
        requested_gain,
        requested_rate_hz: prepared_playback.rate_hz,
        source_kind: prepared_playback.source_kind.clone(),
        source_path: prepared_playback.source_path.clone(),
        success,
        summary_path: summary_path.clone(),
        validate_only,
    };
    let encoded = serde_json::to_string(&summary)?;
    println!("audio-spike-summary={encoded}");

    if let Some(path) = summary_path {
        if let Some(parent) = Path::new(&path).parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, serde_json::to_string_pretty(&summary)?)?;
    }

    if summary.success {
        Ok(())
    } else {
        Err("audio-spike playback failed for every PCM device candidate".into())
    }
}

fn prepare_playback(
    source_kind: &str,
    duration_ms: u32,
    frequency_hz: u32,
    rate_hz: u32,
    channels: u32,
    gain: f32,
    file_path: Option<&str>,
    url: Option<&str>,
) -> Result<PreparedPlayback, Box<dyn Error>> {
    match source_kind {
        "tone" => Ok(build_tone_playback(
            duration_ms,
            frequency_hz as f32,
            rate_hz,
            channels,
            gain,
        )),
        "file" => decode_audio_file(
            file_path.ok_or_else(|| {
                "SHADOW_AUDIO_SPIKE_FILE_PATH is required when SHADOW_AUDIO_SPIKE_SOURCE_KIND=file"
            })?,
            gain,
        ),
        "url" => decode_audio_url(
            url.ok_or_else(|| {
                "SHADOW_AUDIO_SPIKE_URL is required when SHADOW_AUDIO_SPIKE_SOURCE_KIND=url"
            })?,
            gain,
        ),
        _ => Err(format!("unsupported SHADOW_AUDIO_SPIKE_SOURCE_KIND '{source_kind}'").into()),
    }
}

fn build_tone_playback(
    duration_ms: u32,
    frequency_hz: f32,
    rate_hz: u32,
    channels: u32,
    gain: f32,
) -> PreparedPlayback {
    let frames_requested = ((u64::from(rate_hz) * u64::from(duration_ms)) / 1000) as usize;
    PreparedPlayback {
        channels,
        duration_ms,
        frequency_hz: Some(frequency_hz.round() as u32),
        rate_hz,
        samples: render_tone_chunk(0, frames_requested, rate_hz, channels, frequency_hz, gain),
        source_kind: String::from("tone"),
        source_path: None,
    }
}

fn decode_audio_file(path: &str, gain: f32) -> Result<PreparedPlayback, Box<dyn Error>> {
    let file = File::open(path)?;
    let mut hint = Hint::new();
    if let Some(extension) = source_extension_hint(path) {
        hint.with_extension(&extension);
    }
    decode_audio_media(Box::new(file), hint, gain, "file", Some(path.to_owned()))
}

fn decode_audio_url(url: &str, gain: f32) -> Result<PreparedPlayback, Box<dyn Error>> {
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(URL_FETCH_CONNECT_TIMEOUT_SECS))
        .timeout(Duration::from_secs(URL_FETCH_TOTAL_TIMEOUT_SECS))
        .build()?;
    let response = client.get(url).send()?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("audio-spike url fetch failed status={status} url={url}").into());
    }
    let bytes = response.bytes()?;
    let mut hint = Hint::new();
    if let Some(extension) = source_extension_hint(url) {
        hint.with_extension(&extension);
    }
    decode_audio_media(
        Box::new(Cursor::new(bytes.to_vec())),
        hint,
        gain,
        "url",
        Some(url.to_owned()),
    )
}

fn decode_audio_media(
    media_source: Box<dyn MediaSource>,
    hint: Hint,
    gain: f32,
    source_kind: &str,
    source_path: Option<String>,
) -> Result<PreparedPlayback, Box<dyn Error>> {
    let media_source = MediaSourceStream::new(media_source, Default::default());

    let probed = symphonia::default::get_probe().format(
        &hint,
        media_source,
        &FormatOptions::default(),
        &MetadataOptions::default(),
    )?;
    let mut format = probed.format;
    let track = format
        .default_track()
        .ok_or_else(|| format!("audio-spike {source_kind} decode needs a default track"))?;
    let track_id = track.id;
    let codec_params = &track.codec_params;
    let sample_rate_hz = codec_params
        .sample_rate
        .ok_or_else(|| format!("audio-spike {source_kind} decode needs a sample rate"))?;
    let channels = codec_params
        .channels
        .ok_or_else(|| format!("audio-spike {source_kind} decode needs channel metadata"))?
        .count() as u32;
    let mut decoder =
        symphonia::default::get_codecs().make(codec_params, &DecoderOptions::default())?;
    let mut samples = Vec::new();

    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(SymphoniaError::IoError(error)) if error.kind() == ErrorKind::UnexpectedEof => {
                break;
            }
            Err(error) => return Err(Box::new(error)),
        };
        if packet.track_id() != track_id {
            continue;
        }

        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(SymphoniaError::IoError(error)) if error.kind() == ErrorKind::UnexpectedEof => {
                break;
            }
            Err(SymphoniaError::DecodeError(error)) => {
                return Err(format!("audio-spike {source_kind} decode error: {error}").into());
            }
            Err(error) => return Err(Box::new(error)),
        };
        let mut buffer = SampleBuffer::<i16>::new(decoded.capacity() as u64, *decoded.spec());
        buffer.copy_interleaved_ref(decoded);
        samples.extend_from_slice(buffer.samples());
    }

    if samples.is_empty() {
        return Err(format!("audio-spike decoded {source_kind} source produced no audio samples").into());
    }
    apply_gain(&mut samples, gain);

    let frames_requested = samples.len() / channels as usize;
    Ok(PreparedPlayback {
        channels,
        duration_ms: ((frames_requested as u64) * 1000 / u64::from(sample_rate_hz)) as u32,
        frequency_hz: None,
        rate_hz: sample_rate_hz,
        samples,
        source_kind: String::from(source_kind),
        source_path,
    })
}

fn source_extension_hint(source: &str) -> Option<String> {
    let without_fragment = source.split('#').next().unwrap_or(source);
    let without_query = without_fragment.split('?').next().unwrap_or(without_fragment);
    Path::new(without_query)
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_owned)
}

fn play_prepared_samples(
    device: &str,
    playback: &PreparedPlayback,
) -> Result<PlaybackResult, Box<dyn Error>> {
    let pcm = PCM::new(device, Direction::Playback, false)?;
    let hwp = HwParams::any(&pcm)?;
    hwp.set_channels(playback.channels)?;
    hwp.set_rate(playback.rate_hz, ValueOr::Nearest)?;
    hwp.set_format(Format::s16())?;
    hwp.set_access(Access::RWInterleaved)?;
    pcm.hw_params(&hwp)?;

    let current = pcm.hw_params_current()?;
    let actual_rate_hz = current.get_rate()?;
    let actual_channels = current.get_channels()?;
    let buffer_frames = current.get_buffer_size()?;
    let period_frames = current.get_period_size()?;
    if actual_channels != playback.channels {
        return Err(format!(
            "audio-spike device {device} negotiated {actual_channels} channels for {}-channel input",
            playback.channels
        )
        .into());
    }
    let frames_per_chunk = usize::try_from(period_frames.max(1)).unwrap_or(256);

    let io = pcm.io_i16()?;
    pcm.prepare()?;

    let mut sample_offset = 0usize;
    while sample_offset < playback.samples.len() {
        let remaining_frames =
            (playback.samples.len() - sample_offset) / playback.channels as usize;
        let frames_this_chunk = frames_per_chunk.min(remaining_frames);
        let chunk_end = sample_offset + (frames_this_chunk * playback.channels as usize);
        let chunk = &playback.samples[sample_offset..chunk_end];
        let mut chunk_offset = 0usize;
        while chunk_offset < chunk.len() {
            match io.writei(&chunk[chunk_offset..]) {
                Ok(written_frames) => {
                    chunk_offset += written_frames * actual_channels as usize;
                }
                Err(error) if error.errno() == libc::EPIPE => {
                    pcm.prepare()?;
                }
                Err(error) => return Err(Box::new(error)),
            }
        }
        sample_offset = chunk_end;
    }

    pcm.drain()?;

    Ok(PlaybackResult {
        actual_channels,
        actual_rate_hz,
        buffer_frames,
        device: None,
        frames_requested: playback.samples.len() / playback.channels as usize,
        period_frames,
    })
}

fn parse_playback_devices(proc_asound_pcm: Option<&str>) -> Vec<PlaybackDevice> {
    let mut devices = BTreeSet::new();
    let Some(proc_asound_pcm) = proc_asound_pcm else {
        return Vec::new();
    };

    for line in proc_asound_pcm.lines() {
        if !line.contains("playback") {
            continue;
        }

        let Some((prefix, remainder)) = line.split_once(':') else {
            continue;
        };
        let Some((_, device)) = prefix.split_once('-') else {
            continue;
        };
        let Ok(device) = device.trim().parse::<u32>() else {
            continue;
        };
        let name = remainder
            .split(':')
            .next()
            .unwrap_or_default()
            .trim()
            .to_owned();
        devices.insert(PlaybackDevice {
            number: device,
            name,
        });
    }

    devices.into_iter().collect()
}

fn preferred_playback_order(playback_devices: &[PlaybackDevice]) -> Vec<u32> {
    let mut ordered = playback_devices.to_vec();
    ordered.sort_by_key(|device| {
        (
            playback_device_rank(device.number),
            is_non_audible_name(&device.name),
            device.number,
        )
    });
    ordered.into_iter().map(|device| device.number).collect()
}

fn playback_device_rank(device_number: u32) -> u8 {
    match device_number {
        0 => 0,
        13 => 1,
        17 => 2,
        6 => 250,
        _ => 100,
    }
}

fn route_plan_for_device(candidate: &str) -> Option<&'static RoutePlan> {
    match extract_device_number(candidate) {
        Some(0) => Some(&ROUTE_PLAN_MM1_SPEAKER),
        Some(13) => Some(&ROUTE_PLAN_MM5_SPEAKER),
        Some(17) => Some(&ROUTE_PLAN_MM8_SPEAKER),
        _ => None,
    }
}

fn extract_device_number(candidate: &str) -> Option<u32> {
    let (_, suffix) = candidate.rsplit_once(':')?;
    let (_, device) = suffix.split_once(',')?;
    device.trim().parse::<u32>().ok()
}

fn is_non_audible_candidate(candidate: &str, playback_device_names: &HashMap<u32, String>) -> bool {
    let Some(device_number) = extract_device_number(candidate) else {
        return false;
    };
    let Some(name) = playback_device_names.get(&device_number) else {
        return false;
    };
    is_non_audible_name(name)
}

fn is_non_audible_name(name: &str) -> bool {
    let normalized = name.to_ascii_lowercase();
    normalized.contains("proxy") || normalized.contains("stub") || normalized.contains("hostless")
}

fn with_route_plan<F>(
    route_plan: &RoutePlan,
    operation: F,
) -> Result<PlaybackResult, Box<dyn Error>>
where
    F: FnOnce() -> Result<PlaybackResult, Box<dyn Error>>,
{
    let hctl = HCtl::new("hw:0", false)?;
    hctl.load()?;
    let restores = apply_route_controls(&hctl, route_plan.controls)?;
    let operation_result = operation();
    restore_route_controls(&hctl, restores)?;
    operation_result
}

fn apply_route_controls(
    hctl: &HCtl,
    controls: &'static [RouteControl],
) -> Result<Vec<ControlRestore>, Box<dyn Error>> {
    let mut restores = Vec::with_capacity(controls.len());
    for control in controls {
        let elem = find_hctl_elem(hctl, control.name)?;
        let mut value = elem.read()?;
        let info = elem.info()?;
        let count = info.get_count();
        let restore = match control.value {
            RouteValue::Bool(new_value) => {
                let mut old_values = Vec::with_capacity(count as usize);
                for index in 0..count {
                    old_values.push(value.get_boolean(index).ok_or_else(|| {
                        format!("missing boolean value for control '{}'", control.name)
                    })?);
                    value.set_boolean(index, new_value).ok_or_else(|| {
                        format!("failed to set boolean control '{}'", control.name)
                    })?;
                }
                ControlRestore {
                    name: control.name,
                    values: RestoreValues::Bool(old_values),
                }
            }
            RouteValue::Int(new_value) => {
                let mut old_values = Vec::with_capacity(count as usize);
                for index in 0..count {
                    old_values.push(value.get_integer(index).ok_or_else(|| {
                        format!("missing integer value for control '{}'", control.name)
                    })?);
                    value.set_integer(index, new_value).ok_or_else(|| {
                        format!("failed to set integer control '{}'", control.name)
                    })?;
                }
                ControlRestore {
                    name: control.name,
                    values: RestoreValues::Int(old_values),
                }
            }
        };
        elem.write(&value)?;
        restores.push(restore);
    }
    Ok(restores)
}

fn restore_route_controls(
    hctl: &HCtl,
    restores: Vec<ControlRestore>,
) -> Result<(), Box<dyn Error>> {
    for restore in restores.into_iter().rev() {
        let elem = find_hctl_elem(hctl, restore.name)?;
        let mut value = elem.read()?;
        match restore.values {
            RestoreValues::Bool(previous_values) => {
                for (index, previous_value) in previous_values.into_iter().enumerate() {
                    value
                        .set_boolean(index as u32, previous_value)
                        .ok_or_else(|| {
                            format!("failed to restore boolean control '{}'", restore.name)
                        })?;
                }
            }
            RestoreValues::Int(previous_values) => {
                for (index, previous_value) in previous_values.into_iter().enumerate() {
                    value
                        .set_integer(index as u32, previous_value)
                        .ok_or_else(|| {
                            format!("failed to restore integer control '{}'", restore.name)
                        })?;
                }
            }
        }
        elem.write(&value)?;
    }
    Ok(())
}

fn find_hctl_elem<'a>(hctl: &'a HCtl, name: &str) -> Result<alsa::hctl::Elem<'a>, Box<dyn Error>> {
    let mut id = ElemId::new(ElemIface::Mixer);
    id.set_name(&std::ffi::CString::new(name)?);
    hctl.find_elem(&id)
        .ok_or_else(|| format!("missing mixer control '{name}'").into())
}

fn render_tone_chunk(
    frame_start: usize,
    frame_count: usize,
    rate_hz: u32,
    channels: u32,
    frequency_hz: f32,
    gain: f32,
) -> Vec<i16> {
    let amplitude = i16::MAX as f32 * 0.20 * gain;
    let mut output = Vec::with_capacity(frame_count * channels as usize);
    for frame_index in frame_start..frame_start + frame_count {
        let phase = (frame_index as f32 * frequency_hz * TAU) / rate_hz as f32;
        let sample = (phase.sin() * amplitude) as i16;
        for _ in 0..channels {
            output.push(sample);
        }
    }
    output
}

fn apply_gain(samples: &mut [i16], gain: f32) {
    if (gain - 1.0).abs() < f32::EPSILON {
        return;
    }

    for sample in samples {
        let scaled = (*sample as f32 * gain)
            .round()
            .clamp(i16::MIN as f32, i16::MAX as f32);
        *sample = scaled as i16;
    }
}

fn read_env_u32(name: &str, default: u32) -> u32 {
    env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .unwrap_or(default)
}

fn read_env_f32(name: &str, default: f32) -> f32 {
    env::var(name)
        .ok()
        .and_then(|value| value.trim().parse::<f32>().ok())
        .unwrap_or(default)
}

fn read_env_string(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn read_env_flag(name: &str) -> bool {
    matches!(
        env::var(name).ok().as_deref(),
        Some("1") | Some("true") | Some("TRUE") | Some("yes") | Some("YES")
    )
}

fn list_tree_entries(path: &str) -> Vec<String> {
    let root = Path::new(path);
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };

    let mut names = entries
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    names.sort();
    names
}

fn read_optional_text(path: &str) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|text| text.trim().to_owned())
        .filter(|text| !text.is_empty())
}

fn sanitize_log_field(value: &str) -> String {
    value.replace('\n', " ").replace('\r', " ")
}

#[derive(Debug, Serialize)]
struct AudioSpikeSummary {
    attempts: Vec<PcmAttempt>,
    cwd: Option<String>,
    dev_snd_entries: Vec<String>,
    elapsed_ms: u128,
    playback: Option<PlaybackResult>,
    proc_asound_cards: Option<String>,
    proc_asound_devices: Option<String>,
    proc_asound_entries: Vec<String>,
    proc_asound_pcm: Option<String>,
    requested_channels: u32,
    requested_duration_ms: u32,
    requested_frequency_hz: u32,
    requested_gain: f32,
    requested_rate_hz: u32,
    source_kind: String,
    source_path: Option<String>,
    success: bool,
    summary_path: Option<String>,
    validate_only: bool,
}

#[derive(Debug)]
struct PreparedPlayback {
    channels: u32,
    duration_ms: u32,
    frequency_hz: Option<u32>,
    rate_hz: u32,
    samples: Vec<i16>,
    source_kind: String,
    source_path: Option<String>,
}

#[derive(Debug, Serialize)]
struct PcmAttempt {
    device: String,
    elapsed_ms: u128,
    error: Option<String>,
    frames_requested: usize,
    proxy_like: bool,
    route: Option<String>,
    success: bool,
}

#[derive(Debug, Serialize)]
struct PlaybackResult {
    actual_channels: u32,
    actual_rate_hz: u32,
    buffer_frames: i64,
    device: Option<String>,
    frames_requested: usize,
    period_frames: i64,
}

impl PlaybackResult {
    fn with_device(mut self, device: String) -> Self {
        self.device = Some(device);
        self
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct PlaybackDevice {
    number: u32,
    name: String,
}

#[derive(Clone, Copy)]
struct RouteControl {
    name: &'static str,
    value: RouteValue,
}

#[derive(Clone, Copy)]
enum RouteValue {
    Bool(bool),
    Int(i32),
}

struct RoutePlan {
    name: &'static str,
    controls: &'static [RouteControl],
}

struct ControlRestore {
    name: &'static str,
    values: RestoreValues,
}

enum RestoreValues {
    Bool(Vec<bool>),
    Int(Vec<i32>),
}

const ROUTE_PLAN_MM1_SPEAKER: RoutePlan = RoutePlan {
    name: "speaker-mm1",
    controls: &[
        RouteControl {
            name: "SEC_TDM_RX_0 Audio Mixer MultiMedia1",
            value: RouteValue::Bool(true),
        },
        RouteControl {
            name: "Main AMP Enable Switch",
            value: RouteValue::Bool(true),
        },
        RouteControl {
            name: "R Main AMP Enable Switch",
            value: RouteValue::Bool(true),
        },
    ],
};

const ROUTE_PLAN_MM5_SPEAKER: RoutePlan = RoutePlan {
    name: "speaker-mm5",
    controls: &[
        RouteControl {
            name: "SEC_TDM_RX_0 Audio Mixer MultiMedia5",
            value: RouteValue::Bool(true),
        },
        RouteControl {
            name: "Main AMP Enable Switch",
            value: RouteValue::Bool(true),
        },
        RouteControl {
            name: "R Main AMP Enable Switch",
            value: RouteValue::Bool(true),
        },
    ],
};

const ROUTE_PLAN_MM8_SPEAKER: RoutePlan = RoutePlan {
    name: "speaker-mm8",
    controls: &[
        RouteControl {
            name: "SEC_TDM_RX_0 Audio Mixer MultiMedia8",
            value: RouteValue::Bool(true),
        },
        RouteControl {
            name: "Main AMP Enable Switch",
            value: RouteValue::Bool(true),
        },
        RouteControl {
            name: "R Main AMP Enable Switch",
            value: RouteValue::Bool(true),
        },
    ],
};
