use std::{
    collections::BTreeSet,
    env,
    ffi::CString,
    fmt, fs,
    num::NonZeroUsize,
    os::fd::{AsFd, BorrowedFd},
    path::{Path, PathBuf},
    process::ExitCode,
    thread,
    time::Duration,
};

use ash::vk;
use drm::buffer::{Buffer, DrmFourcc};
use drm::control::dumbbuffer::DumbBuffer;
use drm::control::{connector, Device as ControlDevice};
use drm::Device as BasicDevice;
use kurbo::{Affine, Rect};
use serde::Serialize;
use vello::{
    peniko::{Color, Fill},
    AaConfig, AaSupport, RenderParams, Renderer as VelloRenderer, RendererOptions, Scene,
};
use wgpu::{AdapterInfo, Backend, DeviceType, TextureUsages};
use wgpu_context::{BufferRenderer, BufferRendererConfig, DeviceHandle, WGPUContext};

#[cfg(target_os = "macos")]
const DEFAULT_THREADS: Option<NonZeroUsize> = NonZeroUsize::new(1);
#[cfg(not(target_os = "macos"))]
const DEFAULT_THREADS: Option<NonZeroUsize> = None;

const DEFAULT_WIDTH: u32 = 128;
const DEFAULT_HEIGHT: u32 = 128;
const MAX_DISTINCT_COLOR_SAMPLES: usize = 8;
const MAX_HOLD_SECS: u32 = 30;
const FLAT_ORANGE_RGB: (u8, u8, u8) = (0xFF, 0x7A, 0x00);

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
    let summary = build_summary(&config)?;
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

fn build_summary(config: &Config) -> Result<SmokeSummary, String> {
    if matches!(config.scene, RenderScene::BundleSmoke) {
        if config.hold_secs > 0 {
            thread::sleep(Duration::from_secs(u64::from(config.hold_secs)));
        }

        return Ok(SmokeSummary::Bundle(BundleSmokeSummary {
            mode: "bundle-smoke",
            scene: config.scene.as_str(),
            hold_secs: config.hold_secs,
            slept: config.hold_secs > 0,
            summary_path: config.summary_path.as_ref().map(path_display_string),
            env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
            env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
            env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
            env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
            env_tu_debug: env::var("TU_DEBUG").ok(),
        }));
    }

    if matches!(config.scene, RenderScene::InstanceSmoke) {
        return Ok(SmokeSummary::Instance(build_instance_smoke_summary(config)));
    }

    if matches!(config.scene, RenderScene::RawVulkanInstanceSmoke) {
        return Ok(SmokeSummary::RawVulkanInstance(
            build_raw_vulkan_instance_smoke_summary(config)?,
        ));
    }

    if matches!(config.scene, RenderScene::EnumerateAdaptersCountSmoke) {
        return Ok(SmokeSummary::EnumerateAdaptersCount(
            build_enumerate_adapters_count_smoke_summary(config),
        ));
    }

    if matches!(config.scene, RenderScene::EnumerateAdaptersSmoke) {
        return Ok(SmokeSummary::EnumerateAdapters(
            build_enumerate_adapters_smoke_summary(config),
        ));
    }

    if matches!(config.scene, RenderScene::AdapterSmoke) {
        return Ok(SmokeSummary::Adapter(build_adapter_smoke_summary(config)?));
    }

    if matches!(config.scene, RenderScene::DeviceRequestSmoke) {
        return Ok(SmokeSummary::DeviceRequest(
            build_device_request_smoke_summary(config)?,
        ));
    }

    if matches!(config.scene, RenderScene::DeviceSmoke) {
        return Ok(SmokeSummary::Device(build_device_smoke_summary(config)?));
    }

    Ok(SmokeSummary::Gpu(render_gpu_summary(config)?))
}

fn build_instance_smoke_summary(config: &Config) -> InstanceSmokeSummary {
    let context = WGPUContext::new();
    eprintln!("[shadow-gpu-smoke] instance-smoke: context-new-ok");

    InstanceSmokeSummary {
        mode: "instance-smoke",
        scene: config.scene.as_str(),
        width: config.width,
        height: config.height,
        instance_created: true,
        adapter_selected: false,
        device_requested: false,
        buffer_renderer_created: false,
        device_pool_len: context.device_pool.len(),
        summary_path: config.summary_path.as_ref().map(path_display_string),
        env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
        env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
        env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
        env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
        env_tu_debug: env::var("TU_DEBUG").ok(),
    }
}

fn build_raw_vulkan_instance_smoke_summary(
    config: &Config,
) -> Result<RawVulkanInstanceSmokeSummary, String> {
    eprintln!("[shadow-gpu-smoke] raw-vulkan-instance-smoke: load-entry");
    let entry =
        unsafe { ash::Entry::load() }.map_err(|error| format!("load vulkan entry: {error}"))?;
    eprintln!("[shadow-gpu-smoke] raw-vulkan-instance-smoke: load-entry-ok");

    let application_name =
        CString::new("shadow-gpu-smoke").map_err(|error| format!("app name cstring: {error}"))?;
    let engine_name =
        CString::new("shadow-gpu-smoke").map_err(|error| format!("engine name cstring: {error}"))?;
    let app_info = vk::ApplicationInfo::default()
        .application_name(application_name.as_c_str())
        .application_version(0)
        .engine_name(engine_name.as_c_str())
        .engine_version(0)
        .api_version(vk::make_api_version(0, 1, 0, 0));
    let create_info = vk::InstanceCreateInfo::default().application_info(&app_info);

    eprintln!("[shadow-gpu-smoke] raw-vulkan-instance-smoke: vkCreateInstance");
    let instance = unsafe { entry.create_instance(&create_info, None) }
        .map_err(|error| format!("vkCreateInstance: {error:?}"))?;
    eprintln!("[shadow-gpu-smoke] raw-vulkan-instance-smoke: vkCreateInstance-ok");
    unsafe {
        instance.destroy_instance(None);
    }
    eprintln!("[shadow-gpu-smoke] raw-vulkan-instance-smoke: destroy-instance-ok");

    Ok(RawVulkanInstanceSmokeSummary {
        mode: "raw-vulkan-instance-smoke",
        scene: config.scene.as_str(),
        width: config.width,
        height: config.height,
        vulkan_loader_loaded: true,
        instance_created: true,
        instance_destroyed: true,
        physical_devices_enumerated: false,
        wgpu_adapter_enumeration_attempted: false,
        adapter_selection_attempted: false,
        device_requested: false,
        summary_path: config.summary_path.as_ref().map(path_display_string),
        env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
        env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
        env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
        env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
        env_tu_debug: env::var("TU_DEBUG").ok(),
    })
}

fn build_enumerate_adapters_count_smoke_summary(
    config: &Config,
) -> EnumerateAdaptersCountSmokeSummary {
    let context = WGPUContext::new();
    let backends = wgpu::Backends::from_env().unwrap_or_default();
    let device_pool_len = context.device_pool.len();
    eprintln!(
        "[shadow-gpu-smoke] enumerate-adapters-count-smoke: enumerate-adapters backends={backends:?}"
    );
    let adapters = pollster::block_on(context.instance.enumerate_adapters(backends));
    eprintln!(
        "[shadow-gpu-smoke] enumerate-adapters-count-smoke: enumerate-adapters-ok count={}",
        adapters.len()
    );

    EnumerateAdaptersCountSmokeSummary {
        mode: "enumerate-adapters-count-smoke",
        scene: config.scene.as_str(),
        width: config.width,
        height: config.height,
        instance_created: true,
        adapters_enumerated: true,
        enumerated_adapter_count: adapters.len(),
        adapter_info_extracted: false,
        adapter_selection_attempted: false,
        adapter_selected: false,
        device_requested: false,
        buffer_renderer_created: false,
        device_pool_len,
        summary_path: config.summary_path.as_ref().map(path_display_string),
        env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
        env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
        env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
        env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
        env_tu_debug: env::var("TU_DEBUG").ok(),
    }
}

fn build_enumerate_adapters_smoke_summary(
    config: &Config,
) -> EnumerateAdaptersSmokeSummary {
    let context = WGPUContext::new();
    let backends = wgpu::Backends::from_env().unwrap_or_default();
    let device_pool_len = context.device_pool.len();
    eprintln!(
        "[shadow-gpu-smoke] enumerate-adapters-smoke: enumerate-adapters backends={backends:?}"
    );
    let adapters = pollster::block_on(context.instance.enumerate_adapters(backends));
    eprintln!(
        "[shadow-gpu-smoke] enumerate-adapters-smoke: enumerate-adapters-ok count={}",
        adapters.len()
    );
    let adapters = adapters
        .into_iter()
        .map(|adapter| AdapterSummary::from_info(&adapter.get_info()))
        .collect::<Vec<_>>();

    EnumerateAdaptersSmokeSummary {
        mode: "enumerate-adapters-smoke",
        scene: config.scene.as_str(),
        width: config.width,
        height: config.height,
        instance_created: true,
        adapters_enumerated: true,
        enumerated_adapter_count: adapters.len(),
        adapter_info_extracted: true,
        adapter_selection_attempted: false,
        adapter_selected: false,
        device_requested: false,
        buffer_renderer_created: false,
        adapters,
        device_pool_len,
        summary_path: config.summary_path.as_ref().map(path_display_string),
        env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
        env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
        env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
        env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
        env_tu_debug: env::var("TU_DEBUG").ok(),
    }
}

fn build_adapter_smoke_summary(config: &Config) -> Result<AdapterSmokeSummary, String> {
    let adapter_info = select_adapter_info(config)?;

    Ok(AdapterSmokeSummary {
        mode: "adapter-smoke",
        scene: config.scene.as_str(),
        width: config.width,
        height: config.height,
        adapter: AdapterSummary::from_info(&adapter_info),
        software_backed: adapter_is_software(&adapter_info),
        require_vulkan: !config.allow_non_vulkan,
        allow_software: config.allow_software,
        summary_path: config.summary_path.as_ref().map(path_display_string),
        env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
        env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
        env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
        env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
        env_tu_debug: env::var("TU_DEBUG").ok(),
    })
}

fn build_device_request_smoke_summary(config: &Config) -> Result<DeviceRequestSmokeSummary, String> {
    let requested_device = request_device_handle(config)?;

    Ok(DeviceRequestSmokeSummary {
        mode: "device-request-smoke",
        scene: config.scene.as_str(),
        width: config.width,
        height: config.height,
        adapter: AdapterSummary::from_info(&requested_device.adapter_info),
        software_backed: adapter_is_software(&requested_device.adapter_info),
        require_vulkan: !config.allow_non_vulkan,
        allow_software: config.allow_software,
        summary_path: config.summary_path.as_ref().map(path_display_string),
        env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
        env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
        env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
        env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
        env_tu_debug: env::var("TU_DEBUG").ok(),
    })
}

fn build_device_smoke_summary(config: &Config) -> Result<DeviceSmokeSummary, String> {
    let requested_device = request_device_handle(config)?;
    eprintln!(
        "[shadow-gpu-smoke] device-smoke: create-buffer-renderer width={} height={}",
        config.width, config.height
    );
    let _buffer_renderer = BufferRenderer::new(
        BufferRendererConfig {
            width: config.width,
            height: config.height,
            usage: TextureUsages::STORAGE_BINDING,
        },
        requested_device.device_handle,
        0,
    );
    eprintln!("[shadow-gpu-smoke] device-smoke: create-buffer-renderer-ok");

    Ok(DeviceSmokeSummary {
        mode: "device-smoke",
        scene: config.scene.as_str(),
        width: config.width,
        height: config.height,
        adapter: AdapterSummary::from_info(&requested_device.adapter_info),
        software_backed: adapter_is_software(&requested_device.adapter_info),
        require_vulkan: !config.allow_non_vulkan,
        allow_software: config.allow_software,
        hold_secs: config.hold_secs,
        summary_path: config.summary_path.as_ref().map(path_display_string),
        env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
        env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
        env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
        env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
        env_tu_debug: env::var("TU_DEBUG").ok(),
    })
}

struct RequestedDevice {
    device_handle: DeviceHandle,
    adapter_info: AdapterInfo,
}

fn select_adapter_info(config: &Config) -> Result<AdapterInfo, String> {
    let context = WGPUContext::new();
    eprintln!("[shadow-gpu-smoke] adapter-smoke: request-adapter-info");
    let adapter_info = pollster::block_on(context.create_headless_adapter_info())
        .map_err(|error| format!("request adapter info: {error:#}"))?;
    validate_adapter(config, &adapter_info)?;
    eprintln!("[shadow-gpu-smoke] adapter-smoke: request-adapter-info-ok");
    Ok(adapter_info)
}

fn request_device_handle(config: &Config) -> Result<RequestedDevice, String> {
    let mut context = WGPUContext::new();
    eprintln!("[shadow-gpu-smoke] device-request: request-device-handle");
    let device_handle = pollster::block_on(context.create_headless_device_handle())
        .map_err(|error| format!("request device handle: {error:#}"))?;
    let adapter_info = device_handle.adapter.get_info();
    validate_adapter(config, &adapter_info)?;
    eprintln!("[shadow-gpu-smoke] device-request: request-device-handle-ok");

    Ok(RequestedDevice {
        device_handle,
        adapter_info,
    })
}

fn render_gpu_summary(config: &Config) -> Result<GpuSmokeSummary, String> {
    let mut context = WGPUContext::new();
    let buffer_renderer =
        pollster::block_on(context.create_buffer_renderer(BufferRendererConfig {
            width: config.width,
            height: config.height,
            usage: TextureUsages::STORAGE_BINDING,
        }))
        .map_err(|error| format!("create offscreen buffer renderer: {error:?}"))?;

    let adapter_info = buffer_renderer.device_handle.adapter.get_info();
    validate_adapter(config, &adapter_info)?;

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
    build_scene(&mut scene, config.width, config.height, config.scene);

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
    let kms_present = if config.present_kms {
        Some(present_pixels_via_kms(
            &pixels,
            config.width,
            config.height,
            Duration::from_secs(u64::from(config.hold_secs)),
        )?)
    } else {
        None
    };
    Ok(GpuSmokeSummary {
        scene: config.scene.as_str(),
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
        present_kms: config.present_kms,
        hold_secs: config.hold_secs,
        env_wgpu_backend: env::var("WGPU_BACKEND").ok(),
        env_wgpu_adapter_name: env::var("WGPU_ADAPTER_NAME").ok(),
        env_vk_icd_filenames: env::var("VK_ICD_FILENAMES").ok(),
        env_mesa_loader_driver_override: env::var("MESA_LOADER_DRIVER_OVERRIDE").ok(),
        env_tu_debug: env::var("TU_DEBUG").ok(),
        ppm_path: config.ppm_path.as_ref().map(path_display_string),
        kms_present,
    })
}

fn validate_adapter(config: &Config, adapter_info: &AdapterInfo) -> Result<(), String> {
    if !config.allow_non_vulkan && adapter_info.backend != Backend::Vulkan {
        return Err(format!(
            "expected Vulkan backend, got {:?}; rerun with --allow-non-vulkan only for host-side debugging",
            adapter_info.backend
        ));
    }
    if !config.allow_software && adapter_is_software(adapter_info) {
        return Err(format!(
            "selected software adapter {}; rerun with --allow-software only for explicit fallback debugging",
            adapter_info.name
        ));
    }

    Ok(())
}

fn build_scene(scene: &mut Scene, width: u32, height: u32, render_scene: RenderScene) {
    let width = width as f64;
    let height = height as f64;

    if matches!(render_scene, RenderScene::FlatOrange) {
        scene.fill(
            Fill::NonZero,
            Affine::IDENTITY,
            Color::from_rgb8(FLAT_ORANGE_RGB.0, FLAT_ORANGE_RGB.1, FLAT_ORANGE_RGB.2),
            None,
            &Rect::new(0.0, 0.0, width, height),
        );
        return;
    }

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

fn present_pixels_via_kms(
    pixels: &[u8],
    src_width: u32,
    src_height: u32,
    hold_duration: Duration,
) -> Result<KmsPresentSummary, String> {
    let mut card = open_card("/dev/dri/card0")?;
    let master_locked = acquire_master_lock_if_supported(&card)?;
    let res_handles = card
        .resource_handles()
        .map_err(|error| format!("fetch DRM resource handles: {error}"))?;

    let connector_info = find_connected_connector(&card, &res_handles)?;
    let connector_handle = connector_info.handle();
    let mode = connector_info
        .modes()
        .first()
        .copied()
        .ok_or_else(|| format!("connector {connector_handle:?} reported no modes"))?;
    let encoder_handle = connector_info
        .current_encoder()
        .or_else(|| connector_info.encoders().first().copied())
        .ok_or_else(|| format!("connector {connector_handle:?} reported no encoder"))?;
    let encoder = card
        .get_encoder(encoder_handle)
        .map_err(|error| format!("query encoder {encoder_handle:?}: {error}"))?;
    let crtc_handle = select_crtc_handle(&encoder, &res_handles, connector_handle, encoder_handle)?;

    let (mode_width, mode_height) = mode.size();
    let width = u32::from(mode_width);
    let height = u32::from(mode_height);
    let mut dumb = card
        .create_dumb_buffer((width, height), DrmFourcc::Xrgb8888, 32)
        .map_err(|error| format!("allocate dumb buffer: {error}"))?;
    let fb_handle = card
        .add_framebuffer(&dumb, 24, 32)
        .map_err(|error| format!("create framebuffer: {error}"))?;

    fill_buffer_with_scaled_pixels(&mut card, &mut dumb, pixels, src_width, src_height)?;

    card.set_crtc(
        crtc_handle,
        Some(fb_handle),
        (0, 0),
        &[connector_handle],
        Some(mode),
    )
    .map_err(|error| format!("set CRTC configuration: {error}"))?;

    thread::sleep(hold_duration);

    if let Err(error) = card.set_crtc(crtc_handle, None, (0, 0), &[], None) {
        eprintln!("[shadow-gpu-smoke] clear CRTC failed: {error}");
    }

    if master_locked {
        if let Err(error) = card.release_master_lock() {
            eprintln!("[shadow-gpu-smoke] release DRM master lock failed: {error}");
        }
    }

    card.destroy_framebuffer(fb_handle)
        .map_err(|error| format!("destroy framebuffer: {error}"))?;
    card.destroy_dumb_buffer(dumb)
        .map_err(|error| format!("destroy dumb buffer: {error}"))?;

    Ok(KmsPresentSummary {
        connector: format!("{connector_handle:?}"),
        crtc: format!("{crtc_handle:?}"),
        mode_width: width,
        mode_height: height,
        hold_secs: hold_duration.as_secs(),
        source_width: src_width,
        source_height: src_height,
    })
}

fn fill_buffer_with_scaled_pixels(
    card: &mut Card,
    dumb: &mut DumbBuffer,
    src_pixels: &[u8],
    src_width: u32,
    src_height: u32,
) -> Result<(), String> {
    let (dst_width, dst_height) = dumb.size();
    let dst_pitch = usize::try_from(dumb.pitch())
        .map_err(|error| format!("dumb buffer pitch usize: {error}"))?;
    let mut mapping = card
        .map_dumb_buffer(dumb)
        .map_err(|error| format!("map dumb buffer: {error}"))?;

    for dst_y in 0..dst_height {
        let src_y =
            usize::try_from((u64::from(dst_y) * u64::from(src_height)) / u64::from(dst_height))
                .map_err(|error| format!("scale y coordinate: {error}"))?;
        for dst_x in 0..dst_width {
            let src_x =
                usize::try_from((u64::from(dst_x) * u64::from(src_width)) / u64::from(dst_width))
                    .map_err(|error| format!("scale x coordinate: {error}"))?;
            let src_index = (src_y
                * usize::try_from(src_width)
                    .map_err(|error| format!("src width usize: {error}"))?
                + src_x)
                * 4;
            let dst_index = usize::try_from(dst_y)
                .map_err(|error| format!("dst y usize: {error}"))?
                * dst_pitch
                + usize::try_from(dst_x).map_err(|error| format!("dst x usize: {error}"))? * 4;

            let rgba = &src_pixels[src_index..src_index + 4];
            let pixel = &mut mapping.as_mut()[dst_index..dst_index + 4];
            pixel[0] = rgba[2];
            pixel[1] = rgba[1];
            pixel[2] = rgba[0];
            pixel[3] = 0xFF;
        }
    }

    Ok(())
}

fn open_card(path: &str) -> Result<Card, String> {
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|error| format!("open {path}: {error}"))?;
    Ok(Card(file))
}

fn acquire_master_lock_if_supported(card: &Card) -> Result<bool, String> {
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
        Err(error) => Err(format!("acquire DRM master lock: {error}")),
    }
}

fn find_connected_connector(
    card: &Card,
    res_handles: &drm::control::ResourceHandles,
) -> Result<drm::control::connector::Info, String> {
    for handle in res_handles.connectors() {
        let info = card
            .get_connector(*handle, true)
            .map_err(|error| format!("query connector {handle:?}: {error}"))?;
        if info.state() == connector::State::Connected && !info.modes().is_empty() {
            return Ok(info);
        }
    }

    Err(String::from(
        "no connected connector with available modes was found",
    ))
}

fn select_crtc_handle(
    encoder: &drm::control::encoder::Info,
    res_handles: &drm::control::ResourceHandles,
    connector_handle: connector::Handle,
    encoder_handle: drm::control::encoder::Handle,
) -> Result<drm::control::crtc::Handle, String> {
    encoder
        .crtc()
        .or_else(|| {
            res_handles
                .filter_crtcs(encoder.possible_crtcs())
                .into_iter()
                .next()
        })
        .ok_or_else(|| {
            format!(
                "connector {connector_handle:?} encoder {encoder_handle:?} reported no usable CRTC"
            )
        })
}

struct Card(std::fs::File);

impl AsFd for Card {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }
}

impl BasicDevice for Card {}
impl ControlDevice for Card {}

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
    scene: RenderScene,
    width: u32,
    height: u32,
    allow_non_vulkan: bool,
    allow_software: bool,
    present_kms: bool,
    hold_secs: u32,
    summary_path: Option<PathBuf>,
    ppm_path: Option<PathBuf>,
}

impl Config {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, String> {
        let mut scene = RenderScene::Smoke;
        let mut width = DEFAULT_WIDTH;
        let mut height = DEFAULT_HEIGHT;
        let mut allow_non_vulkan = false;
        let mut allow_software = false;
        let mut present_kms = false;
        let mut hold_secs = 3;
        let mut hold_secs_specified = false;
        let mut summary_path = None;
        let mut ppm_path = None;
        let mut args = args.peekable();

        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--scene" => {
                    scene = RenderScene::parse(require_value("--scene", args.next())?)?;
                }
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
                "--present-kms" => {
                    present_kms = true;
                }
                "--hold-secs" => {
                    hold_secs = parse_u32_flag("--hold-secs", args.next())?;
                    hold_secs_specified = true;
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
        if hold_secs_specified && !present_kms {
            if matches!(scene, RenderScene::BundleSmoke) {
                // bundle-smoke is the only headless scene that intentionally uses --hold-secs
            } else if matches!(
                scene,
                RenderScene::InstanceSmoke
                    | RenderScene::RawVulkanInstanceSmoke
                    | RenderScene::EnumerateAdaptersCountSmoke
                    | RenderScene::EnumerateAdaptersSmoke
                    | RenderScene::AdapterSmoke
                    | RenderScene::DeviceRequestSmoke
                    | RenderScene::DeviceSmoke
            ) {
                return Err(format!(
                    "--scene instance-smoke, raw-vulkan-instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs\n\n{}",
                    Self::usage()
                ));
            } else {
                return Err(format!(
                    "--hold-secs requires --present-kms unless --scene bundle-smoke is selected\n\n{}",
                    Self::usage()
                ));
            }
        }
        if hold_secs > MAX_HOLD_SECS {
            return Err(format!(
                "--hold-secs must be <= {MAX_HOLD_SECS}\n\n{}",
                Self::usage()
            ));
        }
        if matches!(
            scene,
            RenderScene::BundleSmoke
                | RenderScene::InstanceSmoke
                | RenderScene::RawVulkanInstanceSmoke
                | RenderScene::EnumerateAdaptersCountSmoke
                | RenderScene::EnumerateAdaptersSmoke
                | RenderScene::AdapterSmoke
                | RenderScene::DeviceRequestSmoke
                | RenderScene::DeviceSmoke
        ) && present_kms
        {
            return Err(format!(
                "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms\n\n{}",
                Self::usage()
            ));
        }
        if matches!(
            scene,
            RenderScene::BundleSmoke
                | RenderScene::InstanceSmoke
                | RenderScene::RawVulkanInstanceSmoke
                | RenderScene::EnumerateAdaptersCountSmoke
                | RenderScene::EnumerateAdaptersSmoke
                | RenderScene::AdapterSmoke
                | RenderScene::DeviceRequestSmoke
                | RenderScene::DeviceSmoke
        ) && ppm_path.is_some()
        {
            return Err(format!(
                "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path\n\n{}",
                Self::usage()
            ));
        }
        if matches!(scene, RenderScene::BundleSmoke | RenderScene::DeviceSmoke) && !hold_secs_specified
        {
            hold_secs = 0;
        }

        Ok(Self {
            scene,
            width,
            height,
            allow_non_vulkan,
            allow_software,
            present_kms,
            hold_secs,
            summary_path,
            ppm_path,
        })
    }

    fn usage() -> String {
        String::from(
            "Usage: shadow-gpu-smoke [--scene smoke|flat-orange|bundle-smoke|instance-smoke|raw-vulkan-instance-smoke|enumerate-adapters-count-smoke|enumerate-adapters-smoke|adapter-smoke|device-request-smoke|device-smoke] [--width N] [--height N] [--allow-non-vulkan] [--allow-software] [--present-kms] [--hold-secs N] [--summary-path PATH] [--ppm-path PATH]",
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
#[serde(untagged)]
enum SmokeSummary {
    Gpu(GpuSmokeSummary),
    Bundle(BundleSmokeSummary),
    Instance(InstanceSmokeSummary),
    RawVulkanInstance(RawVulkanInstanceSmokeSummary),
    EnumerateAdaptersCount(EnumerateAdaptersCountSmokeSummary),
    EnumerateAdapters(EnumerateAdaptersSmokeSummary),
    Adapter(AdapterSmokeSummary),
    DeviceRequest(DeviceRequestSmokeSummary),
    Device(DeviceSmokeSummary),
}

#[derive(Serialize)]
struct BundleSmokeSummary {
    mode: &'static str,
    scene: &'static str,
    hold_secs: u32,
    slept: bool,
    summary_path: Option<String>,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
}

#[derive(Serialize)]
struct InstanceSmokeSummary {
    mode: &'static str,
    scene: &'static str,
    width: u32,
    height: u32,
    instance_created: bool,
    adapter_selected: bool,
    device_requested: bool,
    buffer_renderer_created: bool,
    device_pool_len: usize,
    summary_path: Option<String>,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
}

#[derive(Serialize)]
struct RawVulkanInstanceSmokeSummary {
    mode: &'static str,
    scene: &'static str,
    width: u32,
    height: u32,
    vulkan_loader_loaded: bool,
    instance_created: bool,
    instance_destroyed: bool,
    physical_devices_enumerated: bool,
    wgpu_adapter_enumeration_attempted: bool,
    adapter_selection_attempted: bool,
    device_requested: bool,
    summary_path: Option<String>,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
}

#[derive(Serialize)]
struct EnumerateAdaptersCountSmokeSummary {
    mode: &'static str,
    scene: &'static str,
    width: u32,
    height: u32,
    instance_created: bool,
    adapters_enumerated: bool,
    enumerated_adapter_count: usize,
    adapter_info_extracted: bool,
    adapter_selection_attempted: bool,
    adapter_selected: bool,
    device_requested: bool,
    buffer_renderer_created: bool,
    device_pool_len: usize,
    summary_path: Option<String>,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
}

#[derive(Serialize)]
struct EnumerateAdaptersSmokeSummary {
    mode: &'static str,
    scene: &'static str,
    width: u32,
    height: u32,
    instance_created: bool,
    adapters_enumerated: bool,
    enumerated_adapter_count: usize,
    adapter_info_extracted: bool,
    adapter_selection_attempted: bool,
    adapter_selected: bool,
    device_requested: bool,
    buffer_renderer_created: bool,
    adapters: Vec<AdapterSummary>,
    device_pool_len: usize,
    summary_path: Option<String>,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
}

#[derive(Serialize)]
struct AdapterSmokeSummary {
    mode: &'static str,
    scene: &'static str,
    width: u32,
    height: u32,
    adapter: AdapterSummary,
    software_backed: bool,
    require_vulkan: bool,
    allow_software: bool,
    summary_path: Option<String>,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
}

#[derive(Serialize)]
struct DeviceRequestSmokeSummary {
    mode: &'static str,
    scene: &'static str,
    width: u32,
    height: u32,
    adapter: AdapterSummary,
    software_backed: bool,
    require_vulkan: bool,
    allow_software: bool,
    summary_path: Option<String>,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
}

#[derive(Serialize)]
struct DeviceSmokeSummary {
    mode: &'static str,
    scene: &'static str,
    width: u32,
    height: u32,
    adapter: AdapterSummary,
    software_backed: bool,
    require_vulkan: bool,
    allow_software: bool,
    hold_secs: u32,
    summary_path: Option<String>,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
}

#[derive(Serialize)]
struct GpuSmokeSummary {
    scene: &'static str,
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
    present_kms: bool,
    hold_secs: u32,
    env_wgpu_backend: Option<String>,
    env_wgpu_adapter_name: Option<String>,
    env_vk_icd_filenames: Option<String>,
    env_mesa_loader_driver_override: Option<String>,
    env_tu_debug: Option<String>,
    ppm_path: Option<String>,
    kms_present: Option<KmsPresentSummary>,
}

#[derive(Serialize)]
struct KmsPresentSummary {
    connector: String,
    crtc: String,
    mode_width: u32,
    mode_height: u32,
    hold_secs: u64,
    source_width: u32,
    source_height: u32,
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

#[derive(Clone, Copy)]
enum RenderScene {
    Smoke,
    FlatOrange,
    BundleSmoke,
    InstanceSmoke,
    RawVulkanInstanceSmoke,
    EnumerateAdaptersCountSmoke,
    EnumerateAdaptersSmoke,
    AdapterSmoke,
    DeviceRequestSmoke,
    DeviceSmoke,
}

impl RenderScene {
    fn parse(raw: String) -> Result<Self, String> {
        match raw.as_str() {
            "smoke" => Ok(Self::Smoke),
            "flat-orange" => Ok(Self::FlatOrange),
            "bundle-smoke" => Ok(Self::BundleSmoke),
            "instance-smoke" => Ok(Self::InstanceSmoke),
            "raw-vulkan-instance-smoke" => Ok(Self::RawVulkanInstanceSmoke),
            "enumerate-adapters-count-smoke" => Ok(Self::EnumerateAdaptersCountSmoke),
            "enumerate-adapters-smoke" => Ok(Self::EnumerateAdaptersSmoke),
            "adapter-smoke" => Ok(Self::AdapterSmoke),
            "device-request-smoke" => Ok(Self::DeviceRequestSmoke),
            "device-smoke" => Ok(Self::DeviceSmoke),
            _ => Err(format!(
                "invalid value for --scene: {raw}; expected smoke, flat-orange, bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, or device-smoke\n\n{}",
                Config::usage()
            )),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Smoke => "smoke",
            Self::FlatOrange => "flat-orange",
            Self::BundleSmoke => "bundle-smoke",
            Self::InstanceSmoke => "instance-smoke",
            Self::RawVulkanInstanceSmoke => "raw-vulkan-instance-smoke",
            Self::EnumerateAdaptersCountSmoke => "enumerate-adapters-count-smoke",
            Self::EnumerateAdaptersSmoke => "enumerate-adapters-smoke",
            Self::AdapterSmoke => "adapter-smoke",
            Self::DeviceRequestSmoke => "device-request-smoke",
            Self::DeviceSmoke => "device-smoke",
        }
    }
}
