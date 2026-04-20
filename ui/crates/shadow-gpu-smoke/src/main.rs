use std::{
    collections::BTreeSet,
    env, fmt, fs,
    num::NonZeroUsize,
    path::{Path, PathBuf},
    process::ExitCode,
};

use kurbo::{Affine, Rect};
use serde::Serialize;
use vello::{
    peniko::{Color, Fill},
    AaConfig, AaSupport, RenderParams, Renderer as VelloRenderer, RendererOptions, Scene,
};
use wgpu::{AdapterInfo, Backend, DeviceType, TextureUsages};
use wgpu_context::{BufferRendererConfig, WGPUContext};

#[cfg(target_os = "macos")]
const DEFAULT_THREADS: Option<NonZeroUsize> = NonZeroUsize::new(1);
#[cfg(not(target_os = "macos"))]
const DEFAULT_THREADS: Option<NonZeroUsize> = None;

const DEFAULT_WIDTH: u32 = 128;
const DEFAULT_HEIGHT: u32 = 128;
const MAX_DISTINCT_COLOR_SAMPLES: usize = 8;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("shadow-gpu-smoke: {error}");
            ExitCode::from(1)
        }
    }
}

fn run() -> Result<(), String> {
    let config = Config::parse(env::args().skip(1))?;
    let summary = render_summary(&config)?;
    let json = serde_json::to_string_pretty(&summary)
        .map_err(|error| format!("encode summary json: {error}"))?;

    if let Some(path) = &config.summary_path {
        ensure_parent_dir(path)?;
        fs::write(path, format!("{json}\n"))
            .map_err(|error| format!("write summary to {}: {error}", path.display()))?;
    }
    println!("{json}");
    Ok(())
}

fn render_summary(config: &Config) -> Result<GpuSmokeSummary, String> {
    let mut context = WGPUContext::new();
    let buffer_renderer =
        pollster::block_on(context.create_buffer_renderer(BufferRendererConfig {
            width: config.width,
            height: config.height,
            usage: TextureUsages::STORAGE_BINDING,
        }))
        .map_err(|error| format!("create offscreen buffer renderer: {error:?}"))?;

    let adapter_info = buffer_renderer.device_handle.adapter.get_info();
    if !config.allow_non_vulkan && adapter_info.backend != Backend::Vulkan {
        return Err(format!(
            "expected Vulkan backend, got {:?}; rerun with --allow-non-vulkan only for host-side debugging",
            adapter_info.backend
        ));
    }
    if !config.allow_software && adapter_is_software(&adapter_info) {
        return Err(format!(
            "selected software adapter {}; rerun with --allow-software only for explicit fallback debugging",
            adapter_info.name
        ));
    }
    let mut renderer = VelloRenderer::new(
        buffer_renderer.device(),
        RendererOptions {
            use_cpu: false,
            num_init_threads: DEFAULT_THREADS,
            antialiasing_support: AaSupport::area_only(),
            pipeline_cache: None,
        },
    )
    .map_err(|error| format!("create vello renderer: {error:?}"))?;

    let mut scene = Scene::new();
    build_scene(&mut scene, config.width, config.height);

    renderer
        .render_to_texture(
            buffer_renderer.device(),
            buffer_renderer.queue(),
            &scene,
            &buffer_renderer.target_texture_view(),
            &RenderParams {
                base_color: Color::TRANSPARENT,
                width: config.width,
                height: config.height,
                antialiasing_method: AaConfig::Area,
            },
        )
        .map_err(|error| format!("render scene to texture: {error:?}"))?;

    let mut pixels = vec![0_u8; (config.width as usize) * (config.height as usize) * 4];
    buffer_renderer.copy_texture_to_buffer(&mut pixels);

    if let Some(path) = &config.ppm_path {
        write_ppm(path, config.width, config.height, &pixels)?;
    }

    let pixel_stats = analyze_pixels(&pixels);
    Ok(GpuSmokeSummary {
        width: config.width,
        height: config.height,
        byte_len: pixels.len(),
        checksum_fnv1a64: format!("{:016x}", fnv1a64(&pixels)),
        distinct_color_count: pixel_stats.distinct_color_count,
        distinct_color_samples_rgba8: pixel_stats.distinct_color_samples_rgba8,
        opaque_pixel_count: pixel_stats.opaque_pixel_count,
        nonzero_alpha_pixel_count: pixel_stats.nonzero_alpha_pixel_count,
        adapter: AdapterSummary::from_info(&adapter_info),
        software_backed: adapter_is_software(&adapter_info),
        require_vulkan: !config.allow_non_vulkan,
        allow_software: config.allow_software,
        env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
        env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
        env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
        env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
        env_tu_debug: env::var("TU_DEBUG").ok(),
        ppm_path: config.ppm_path.as_ref().map(path_display_string),
    })
}

fn build_scene(scene: &mut Scene, width: u32, height: u32) {
    let width = width as f64;
    let height = height as f64;

    // Keep the geometry pixel-aligned so the readback summary stays stable across backends.
    scene.fill(
        Fill::NonZero,
        Affine::IDENTITY,
        Color::from_rgb8(0xFF, 0x8A, 0x42),
        None,
        &Rect::new(0.0, 0.0, width, height),
    );

    let accent_margin = (width / 8.0).floor();
    let accent_height = (height / 7.0).floor().max(1.0);
    scene.fill(
        Fill::NonZero,
        Affine::IDENTITY,
        Color::from_rgb8(0xFF, 0xE0, 0xA6),
        None,
        &Rect::new(
            accent_margin,
            accent_margin,
            width - accent_margin,
            accent_margin + accent_height,
        ),
    );

    let footer_height = (height / 5.0).floor().max(1.0);
    scene.fill(
        Fill::NonZero,
        Affine::IDENTITY,
        Color::from_rgb8(0x65, 0x1C, 0x00),
        None,
        &Rect::new(0.0, height - footer_height, width, height),
    );
}

fn analyze_pixels(pixels: &[u8]) -> PixelStats {
    let mut distinct_colors = BTreeSet::new();
    let mut opaque_pixel_count = 0_u32;
    let mut nonzero_alpha_pixel_count = 0_u32;

    for rgba in pixels.chunks_exact(4) {
        let color = u32::from_be_bytes([rgba[0], rgba[1], rgba[2], rgba[3]]);
        distinct_colors.insert(color);
        if rgba[3] == 0xFF {
            opaque_pixel_count += 1;
        }
        if rgba[3] != 0 {
            nonzero_alpha_pixel_count += 1;
        }
    }

    PixelStats {
        distinct_color_count: distinct_colors.len() as u32,
        distinct_color_samples_rgba8: distinct_colors
            .iter()
            .take(MAX_DISTINCT_COLOR_SAMPLES)
            .map(|color| format!("{color:08x}"))
            .collect(),
        opaque_pixel_count,
        nonzero_alpha_pixel_count,
    }
}

fn write_ppm(path: &Path, width: u32, height: u32, pixels: &[u8]) -> Result<(), String> {
    ensure_parent_dir(path)?;
    let mut ppm = Vec::with_capacity((width as usize) * (height as usize) * 3 + 32);
    ppm.extend_from_slice(format!("P6\n{width} {height}\n255\n").as_bytes());
    for rgba in pixels.chunks_exact(4) {
        ppm.extend_from_slice(&rgba[..3]);
    }
    fs::write(path, ppm).map_err(|error| format!("write ppm to {}: {error}", path.display()))
}

fn ensure_parent_dir(path: &Path) -> Result<(), String> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent)
            .map_err(|error| format!("create parent dir for {}: {error}", path.display()))?;
    }
    Ok(())
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn adapter_is_software(info: &AdapterInfo) -> bool {
    if matches!(info.device_type, DeviceType::Cpu) {
        return true;
    }

    let haystack = format!(
        "{} {} {}",
        info.name.to_ascii_lowercase(),
        info.driver.to_ascii_lowercase(),
        info.driver_info.to_ascii_lowercase()
    );
    ["llvmpipe", "lavapipe", "swrast", "swiftshader", "software"]
        .iter()
        .any(|needle| haystack.contains(needle))
}

fn path_display_string(path: &PathBuf) -> String {
    path.display().to_string()
}

struct Config {
    width: u32,
    height: u32,
    allow_non_vulkan: bool,
    allow_software: bool,
    summary_path: Option<PathBuf>,
    ppm_path: Option<PathBuf>,
}

impl Config {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, String> {
        let mut width = DEFAULT_WIDTH;
        let mut height = DEFAULT_HEIGHT;
        let mut allow_non_vulkan = false;
        let mut allow_software = false;
        let mut summary_path = None;
        let mut ppm_path = None;
        let mut args = args.peekable();

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--width" => {
                    width = parse_u32_flag("--width", args.next())?;
                }
                "--height" => {
                    height = parse_u32_flag("--height", args.next())?;
                }
                "--allow-non-vulkan" => {
                    allow_non_vulkan = true;
                }
                "--allow-software" => {
                    allow_software = true;
                }
                "--summary-path" => {
                    summary_path =
                        Some(PathBuf::from(require_value("--summary-path", args.next())?));
                }
                "--ppm-path" => {
                    ppm_path = Some(PathBuf::from(require_value("--ppm-path", args.next())?));
                }
                "--help" | "-h" => {
                    return Err(Self::usage());
                }
                _ => {
                    return Err(format!("unknown argument: {arg}\n\n{}", Self::usage()));
                }
            }
        }

        if width == 0 || height == 0 {
            return Err(format!(
                "width and height must be positive integers\n\n{}",
                Self::usage()
            ));
        }

        Ok(Self {
            width,
            height,
            allow_non_vulkan,
            allow_software,
            summary_path,
            ppm_path,
        })
    }

    fn usage() -> String {
        String::from(
            "Usage: shadow-gpu-smoke [--width N] [--height N] [--allow-non-vulkan] [--allow-software] [--summary-path PATH] [--ppm-path PATH]",
        )
    }
}

fn parse_u32_flag(flag: &str, value: Option<String>) -> Result<u32, String> {
    require_value(flag, value)?
        .parse::<u32>()
        .map_err(|error| format!("invalid value for {flag}: {error}"))
}

fn require_value(flag: &str, value: Option<String>) -> Result<String, String> {
    value.ok_or_else(|| format!("missing value for {flag}\n\n{}", Config::usage()))
}

struct PixelStats {
    distinct_color_count: u32,
    distinct_color_samples_rgba8: Vec<String>,
    opaque_pixel_count: u32,
    nonzero_alpha_pixel_count: u32,
}

#[derive(Serialize)]
struct GpuSmokeSummary {
    width: u32,
    height: u32,
    byte_len: usize,
    checksum_fnv1a64: String,
    distinct_color_count: u32,
    distinct_color_samples_rgba8: Vec<String>,
    opaque_pixel_count: u32,
    nonzero_alpha_pixel_count: u32,
    adapter: AdapterSummary,
    software_backed: bool,
    require_vulkan: bool,
    allow_software: bool,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
    ppm_path: Option<String>,
}

#[derive(Serialize)]
struct AdapterSummary {
    backend: String,
    device_type: String,
    name: String,
    driver: String,
    driver_info: String,
    vendor: u32,
    device: u32,
}

impl AdapterSummary {
    fn from_info(info: &AdapterInfo) -> Self {
        Self {
            backend: format!("{:?}", info.backend),
            device_type: format!("{:?}", info.device_type),
            name: info.name.clone(),
            driver: info.driver.clone(),
            driver_info: info.driver_info.clone(),
            vendor: info.vendor,
            device: info.device,
        }
    }
}

impl fmt::Display for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}x{}", self.width, self.height)
    }
}
