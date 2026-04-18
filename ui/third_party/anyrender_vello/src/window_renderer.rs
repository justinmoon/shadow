use anyrender::{WindowHandle, WindowRenderer};
use debug_timer::debug_timer;
use peniko::Color;
use raw_window_handle::{RawDisplayHandle, RawWindowHandle};
use rustc_hash::FxHashMap;
use std::{
    env,
    sync::{
        Arc,
        atomic::{self, AtomicU64},
    },
    time::Instant,
};
use vello::{
    AaConfig, AaSupport, RenderParams, Renderer as VelloRenderer, RendererOptions,
    Scene as VelloScene,
};
use wgpu::{
    CompositeAlphaMode, Features, Limits, PresentMode, SurfaceError, TextureFormat, TextureUsages,
};
use wgpu_context::{
    DeviceHandle, SurfaceRenderer, SurfaceRendererConfiguration, TextureConfiguration, WGPUContext,
};

use crate::{CustomPaintSource, DEFAULT_THREADS, VelloScenePainter};

static PAINT_SOURCE_ID: AtomicU64 = AtomicU64::new(0);

const SHADOW_WGPU_PRESENT_MODE_ENV: &str = "SHADOW_WGPU_PRESENT_MODE";
const SHADOW_WGPU_SURFACE_FORMAT_ENV: &str = "SHADOW_WGPU_SURFACE_FORMAT";
const SHADOW_WGPU_ALPHA_MODE_ENV: &str = "SHADOW_WGPU_ALPHA_MODE";
const SHADOW_WGPU_MAX_FRAME_LATENCY_ENV: &str = "SHADOW_WGPU_MAX_FRAME_LATENCY";
const SHADOW_WGPU_FEATURE_PROFILE_ENV: &str = "SHADOW_WGPU_FEATURE_PROFILE";
const SHADOW_WGPU_ANTIALIASING_ENV: &str = "SHADOW_WGPU_ANTIALIASING";
const SHADOW_WGPU_FRAME_TRACE_ENV: &str = "SHADOW_WGPU_FRAME_TRACE";
const SHADOW_WGPU_WAIT_FOR_IDLE_ENV: &str = "SHADOW_WGPU_WAIT_FOR_IDLE";

fn configured_env_value(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
}

fn configured_env_flag(name: &str) -> bool {
    env::var(name)
        .ok()
        .map(|value| {
            let trimmed = value.trim().to_ascii_lowercase();
            !matches!(trimmed.as_str(), "" | "0" | "false" | "off" | "no")
        })
        .unwrap_or_else(|| env::var_os(name).is_some())
}

fn configured_present_mode() -> PresentMode {
    let Some(raw_value) = configured_env_value(SHADOW_WGPU_PRESENT_MODE_ENV) else {
        return PresentMode::AutoVsync;
    };

    match raw_value.as_str() {
        "auto" | "auto-vsync" | "autovsync" => PresentMode::AutoVsync,
        "auto-no-vsync" | "autonovsync" => PresentMode::AutoNoVsync,
        "fifo" => PresentMode::Fifo,
        "fifo-relaxed" | "fiforelaxed" => PresentMode::FifoRelaxed,
        "immediate" => PresentMode::Immediate,
        "mailbox" => PresentMode::Mailbox,
        other => {
            eprintln!(
                "[shadow-anyrender-vello] invalid-present-mode env={} raw_value={other:?} fallback=AutoVsync",
                SHADOW_WGPU_PRESENT_MODE_ENV
            );
            PresentMode::AutoVsync
        }
    }
}

fn configured_surface_formats() -> Vec<TextureFormat> {
    let Some(raw_value) = configured_env_value(SHADOW_WGPU_SURFACE_FORMAT_ENV) else {
        return vec![TextureFormat::Rgba8Unorm, TextureFormat::Bgra8Unorm];
    };

    let configured_format = match raw_value.as_str() {
        "rgba8unorm" | "rgba8-unorm" => TextureFormat::Rgba8Unorm,
        "rgba8unormsrgb" | "rgba8-unorm-srgb" => TextureFormat::Rgba8UnormSrgb,
        "bgra8unorm" | "bgra8-unorm" => TextureFormat::Bgra8Unorm,
        "bgra8unormsrgb" | "bgra8-unorm-srgb" => TextureFormat::Bgra8UnormSrgb,
        other => {
            eprintln!(
                "[shadow-anyrender-vello] invalid-surface-format env={} raw_value={other:?} fallback=default",
                SHADOW_WGPU_SURFACE_FORMAT_ENV
            );
            return vec![TextureFormat::Rgba8Unorm, TextureFormat::Bgra8Unorm];
        }
    };

    vec![configured_format]
}

fn configured_alpha_mode() -> CompositeAlphaMode {
    let Some(raw_value) = configured_env_value(SHADOW_WGPU_ALPHA_MODE_ENV) else {
        return CompositeAlphaMode::Auto;
    };

    match raw_value.as_str() {
        "auto" => CompositeAlphaMode::Auto,
        "opaque" => CompositeAlphaMode::Opaque,
        "premultiplied" | "pre-multiplied" => CompositeAlphaMode::PreMultiplied,
        "postmultiplied" | "post-multiplied" => CompositeAlphaMode::PostMultiplied,
        "inherit" => CompositeAlphaMode::Inherit,
        other => {
            eprintln!(
                "[shadow-anyrender-vello] invalid-alpha-mode env={} raw_value={other:?} fallback=Auto",
                SHADOW_WGPU_ALPHA_MODE_ENV
            );
            CompositeAlphaMode::Auto
        }
    }
}

fn configured_maximum_frame_latency() -> u32 {
    let Some(raw_value) = configured_env_value(SHADOW_WGPU_MAX_FRAME_LATENCY_ENV) else {
        return 2;
    };

    match raw_value.parse::<u32>() {
        Ok(value) if value > 0 => value,
        _ => {
            eprintln!(
                "[shadow-anyrender-vello] invalid-frame-latency env={} raw_value={raw_value:?} fallback=2",
                SHADOW_WGPU_MAX_FRAME_LATENCY_ENV
            );
            2
        }
    }
}

fn configured_optional_features() -> Features {
    let Some(raw_value) = configured_env_value(SHADOW_WGPU_FEATURE_PROFILE_ENV) else {
        return Features::CLEAR_TEXTURE | Features::PIPELINE_CACHE;
    };

    match raw_value.as_str() {
        "default" => Features::CLEAR_TEXTURE | Features::PIPELINE_CACHE,
        "minimal" | "none" => Features::empty(),
        "clear-texture" => Features::CLEAR_TEXTURE,
        "pipeline-cache" => Features::PIPELINE_CACHE,
        other => {
            eprintln!(
                "[shadow-anyrender-vello] invalid-feature-profile env={} raw_value={other:?} fallback=default",
                SHADOW_WGPU_FEATURE_PROFILE_ENV
            );
            Features::CLEAR_TEXTURE | Features::PIPELINE_CACHE
        }
    }
}

fn configured_antialiasing_method() -> Option<AaConfig> {
    let raw_value = configured_env_value(SHADOW_WGPU_ANTIALIASING_ENV)?;
    match raw_value.as_str() {
        "area" => Some(AaConfig::Area),
        "msaa8" | "msaa-8" => Some(AaConfig::Msaa8),
        "msaa16" | "msaa-16" => Some(AaConfig::Msaa16),
        other => {
            eprintln!(
                "[shadow-anyrender-vello] invalid-antialiasing env={} raw_value={other:?} fallback=default",
                SHADOW_WGPU_ANTIALIASING_ENV
            );
            None
        }
    }
}

fn antialiasing_support_for(method: AaConfig) -> AaSupport {
    match method {
        AaConfig::Area => AaSupport {
            area: true,
            msaa8: false,
            msaa16: false,
        },
        AaConfig::Msaa8 => AaSupport {
            area: false,
            msaa8: true,
            msaa16: false,
        },
        AaConfig::Msaa16 => AaSupport {
            area: false,
            msaa8: false,
            msaa16: true,
        },
    }
}

fn frame_trace_enabled() -> bool {
    configured_env_flag(SHADOW_WGPU_FRAME_TRACE_ENV)
}

fn wait_for_idle_enabled() -> bool {
    configured_env_flag(SHADOW_WGPU_WAIT_FOR_IDLE_ENV)
}

fn raw_display_handle_name(handle: RawDisplayHandle) -> &'static str {
    match handle {
        RawDisplayHandle::UiKit(_) => "UiKit",
        RawDisplayHandle::AppKit(_) => "AppKit",
        RawDisplayHandle::Orbital(_) => "Orbital",
        RawDisplayHandle::Xlib(_) => "Xlib",
        RawDisplayHandle::Xcb(_) => "Xcb",
        RawDisplayHandle::Wayland(_) => "Wayland",
        RawDisplayHandle::Drm(_) => "Drm",
        RawDisplayHandle::Gbm(_) => "Gbm",
        RawDisplayHandle::Windows(_) => "Windows",
        RawDisplayHandle::Web(_) => "Web",
        RawDisplayHandle::Android(_) => "Android",
        RawDisplayHandle::Haiku(_) => "Haiku",
        RawDisplayHandle::Ohos(_) => "Ohos",
        _ => "Other",
    }
}

fn raw_window_handle_name(handle: RawWindowHandle) -> &'static str {
    match handle {
        RawWindowHandle::UiKit(_) => "UiKit",
        RawWindowHandle::AppKit(_) => "AppKit",
        RawWindowHandle::Orbital(_) => "Orbital",
        RawWindowHandle::Xlib(_) => "Xlib",
        RawWindowHandle::Xcb(_) => "Xcb",
        RawWindowHandle::Wayland(_) => "Wayland",
        RawWindowHandle::Drm(_) => "Drm",
        RawWindowHandle::Gbm(_) => "Gbm",
        RawWindowHandle::Win32(_) => "Win32",
        RawWindowHandle::WinRt(_) => "WinRt",
        RawWindowHandle::Web(_) => "Web",
        RawWindowHandle::WebCanvas(_) => "WebCanvas",
        RawWindowHandle::WebOffscreenCanvas(_) => "WebOffscreenCanvas",
        RawWindowHandle::AndroidNdk(_) => "AndroidNdk",
        RawWindowHandle::Haiku(_) => "Haiku",
        RawWindowHandle::OhosNdk(_) => "OhosNdk",
        _ => "Other",
    }
}

fn log_raw_handle_diagnostics(window_handle: &dyn WindowHandle) {
    match window_handle.display_handle() {
        Ok(handle) => match handle.as_raw() {
            RawDisplayHandle::Wayland(handle) => eprintln!(
                "[shadow-anyrender-vello] raw-display-handle kind=Wayland display_ptr={:?}",
                handle.display
            ),
            other => eprintln!(
                "[shadow-anyrender-vello] raw-display-handle kind={}",
                raw_display_handle_name(other)
            ),
        },
        Err(error) => eprintln!(
            "[shadow-anyrender-vello] raw-display-handle-error error={error:?}"
        ),
    }

    match window_handle.window_handle() {
        Ok(handle) => match handle.as_raw() {
            RawWindowHandle::Wayland(handle) => eprintln!(
                "[shadow-anyrender-vello] raw-window-handle kind=Wayland surface_ptr={:?}",
                handle.surface
            ),
            other => eprintln!(
                "[shadow-anyrender-vello] raw-window-handle kind={}",
                raw_window_handle_name(other)
            ),
        },
        Err(error) => eprintln!(
            "[shadow-anyrender-vello] raw-window-handle-error error={error:?}"
        ),
    }
}

// Simple struct to hold the state of the renderer
struct ActiveRenderState {
    renderer: VelloRenderer,
    render_surface: SurfaceRenderer<'static>,
}

#[allow(clippy::large_enum_variant)]
enum RenderState {
    Active(ActiveRenderState),
    Suspended,
}

impl RenderState {
    fn current_device_handle(&self) -> Option<&DeviceHandle> {
        let RenderState::Active(state) = self else {
            return None;
        };
        Some(&state.render_surface.device_handle)
    }
}

#[derive(Clone)]
pub struct VelloRendererOptions {
    pub features: Option<Features>,
    pub limits: Option<Limits>,
    pub base_color: Color,
    pub antialiasing_method: AaConfig,
}

impl Default for VelloRendererOptions {
    fn default() -> Self {
        Self {
            features: None,
            limits: None,
            base_color: Color::WHITE,
            antialiasing_method: AaConfig::Msaa16,
        }
    }
}

pub struct VelloWindowRenderer {
    // The fields MUST be in this order, so that the surface is dropped before the window
    // Window is cached even when suspended so that it can be reused when the app is resumed after being suspended
    render_state: RenderState,
    window_handle: Option<Arc<dyn WindowHandle>>,

    // Vello
    wgpu_context: WGPUContext,
    scene: VelloScene,
    config: VelloRendererOptions,

    custom_paint_sources: FxHashMap<u64, Box<dyn CustomPaintSource>>,
}
impl VelloWindowRenderer {
    #[allow(clippy::new_without_default)]
    pub fn new() -> Self {
        Self::with_options(VelloRendererOptions::default())
    }

    pub fn with_options(config: VelloRendererOptions) -> Self {
        let mut config = config;
        let features = config.features.unwrap_or_default() | configured_optional_features();
        if let Some(antialiasing_method) = configured_antialiasing_method() {
            config.antialiasing_method = antialiasing_method;
        }
        eprintln!(
            "[shadow-anyrender-vello] requested-features env_profile={} antialiasing={:?} features={features:?}",
            configured_env_value(SHADOW_WGPU_FEATURE_PROFILE_ENV)
                .unwrap_or_else(|| "default".to_string()),
            config.antialiasing_method
        );
        Self {
            wgpu_context: WGPUContext::with_features_and_limits(
                Some(features),
                config.limits.clone(),
            ),
            config,
            render_state: RenderState::Suspended,
            window_handle: None,
            scene: VelloScene::new(),
            custom_paint_sources: FxHashMap::default(),
        }
    }

    pub fn current_device_handle(&self) -> Option<&DeviceHandle> {
        self.render_state.current_device_handle()
    }

    pub fn register_custom_paint_source(&mut self, mut source: Box<dyn CustomPaintSource>) -> u64 {
        if let Some(device_handle) = self.render_state.current_device_handle() {
            source.resume(device_handle);
        }
        let id = PAINT_SOURCE_ID.fetch_add(1, atomic::Ordering::SeqCst);
        self.custom_paint_sources.insert(id, source);

        id
    }

    pub fn unregister_custom_paint_source(&mut self, id: u64) {
        if let Some(mut source) = self.custom_paint_sources.remove(&id) {
            source.suspend();
            drop(source);
        }
    }
}

impl WindowRenderer for VelloWindowRenderer {
    type ScenePainter<'a>
        = VelloScenePainter<'a, 'a>
    where
        Self: 'a;

    fn is_active(&self) -> bool {
        matches!(self.render_state, RenderState::Active(_))
    }

    fn resume(&mut self, window_handle: Arc<dyn WindowHandle>, width: u32, height: u32) {
        let present_mode = configured_present_mode();
        let surface_formats = configured_surface_formats();
        let alpha_mode = configured_alpha_mode();
        let maximum_frame_latency = configured_maximum_frame_latency();
        eprintln!(
            "[shadow-anyrender-vello] resume-start width={} height={} present_mode={present_mode:?} alpha_mode={alpha_mode:?} maximum_frame_latency={} surface_formats={surface_formats:?}",
            width, height, maximum_frame_latency,
        );
        log_raw_handle_diagnostics(window_handle.as_ref());
        // Create wgpu_context::SurfaceRenderer
        let render_surface = pollster::block_on(self.wgpu_context.create_surface(
            window_handle.clone(),
            SurfaceRendererConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                formats: surface_formats,
                width,
                height,
                present_mode,
                desired_maximum_frame_latency: maximum_frame_latency,
                alpha_mode,
                view_formats: vec![],
            },
            Some(TextureConfiguration {
                usage: TextureUsages::STORAGE_BINDING | TextureUsages::TEXTURE_BINDING,
            }),
        ));
        let render_surface = match render_surface {
            Ok(surface) => surface,
            Err(error) => {
                eprintln!(
                    "[shadow-anyrender-vello] create-surface-error width={} height={} error={error:#}",
                    width, height
                );
                eprintln!("[shadow-anyrender-vello] create-surface-error-debug={error:?}");
                panic!("Error creating surface: {error:#}");
            }
        };
        let adapter_info = render_surface.device_handle.adapter.get_info();
        eprintln!(
            "[shadow-anyrender-vello] resume-surface-ready backend={:?} device_type={:?} name={:?} driver={:?} driver_info={:?}",
            adapter_info.backend,
            adapter_info.device_type,
            adapter_info.name,
            adapter_info.driver,
            adapter_info.driver_info
        );

        // Create vello::Renderer
        eprintln!("[shadow-anyrender-vello] renderer-new-begin");
        let renderer = VelloRenderer::new(
            render_surface.device(),
            RendererOptions {
                antialiasing_support: antialiasing_support_for(self.config.antialiasing_method),
                use_cpu: false,
                num_init_threads: DEFAULT_THREADS,
                // TODO: add pipeline cache
                pipeline_cache: None,
            },
        )
        .unwrap();
        eprintln!("[shadow-anyrender-vello] renderer-new-done");

        // Resume custom paint sources
        eprintln!("[shadow-anyrender-vello] custom-paint-resume-begin");
        let device_handle = &render_surface.device_handle;
        for source in self.custom_paint_sources.values_mut() {
            source.resume(device_handle)
        }
        eprintln!("[shadow-anyrender-vello] custom-paint-resume-done");

        // Set state to Active
        self.window_handle = Some(window_handle);
        self.render_state = RenderState::Active(ActiveRenderState {
            renderer,
            render_surface,
        });
        eprintln!("[shadow-anyrender-vello] resume-done");
    }

    fn suspend(&mut self) {
        // Suspend custom paint sources
        for source in self.custom_paint_sources.values_mut() {
            source.suspend()
        }

        // Set state to Suspended
        self.render_state = RenderState::Suspended;
    }

    fn set_size(&mut self, width: u32, height: u32) {
        if let RenderState::Active(state) = &mut self.render_state {
            state.render_surface.resize(width, height);
        };
    }

    fn render<F: FnOnce(&mut Self::ScenePainter<'_>)>(&mut self, draw_fn: F) {
        let RenderState::Active(state) = &mut self.render_state else {
            return;
        };

        let render_surface = &mut state.render_surface;
        let frame_started = Instant::now();
        let trace_enabled = frame_trace_enabled();
        let wait_for_idle = wait_for_idle_enabled();

        debug_timer!(timer, feature = "log_frame_times");

        // Regenerate the vello scene
        let cmd_started = Instant::now();
        draw_fn(&mut VelloScenePainter {
            inner: &mut self.scene,
            renderer: Some(&mut state.renderer),
            custom_paint_sources: Some(&mut self.custom_paint_sources),
        });
        let cmd_elapsed = cmd_started.elapsed();
        timer.record_time("cmd");

        let acquire_started = Instant::now();
        match render_surface.ensure_current_surface_texture() {
            Ok(_) => {}
            Err(SurfaceError::Timeout | SurfaceError::Lost | SurfaceError::Outdated) => {
                render_surface.clear_surface_texture();
                return;
            }
            Err(SurfaceError::OutOfMemory) => panic!("Out of memory"),
            Err(SurfaceError::Other) => panic!("Unknown error getting surface"),
        };
        let acquire_elapsed = acquire_started.elapsed();

        let texture_view = render_surface
            .target_texture_view()
            .expect("handled errorss from ensure_current_surface_texture above");
        let render_started = Instant::now();
        state
            .renderer
            .render_to_texture(
                render_surface.device(),
                render_surface.queue(),
                &self.scene,
                &texture_view,
                &RenderParams {
                    base_color: self.config.base_color,
                    width: render_surface.config.width,
                    height: render_surface.config.height,
                    antialiasing_method: self.config.antialiasing_method,
                },
            )
            .expect("failed to render to texture");
        let render_elapsed = render_started.elapsed();
        timer.record_time("render");

        drop(texture_view);

        let present_started = Instant::now();
        render_surface
            .maybe_blit_and_present()
            .expect("handled errorss from ensure_current_surface_texture above");
        let present_elapsed = present_started.elapsed();
        timer.record_time("present");

        let wait_started = Instant::now();
        if wait_for_idle {
            render_surface
                .device()
                .poll(wgpu::PollType::wait_indefinitely())
                .unwrap();
        }
        let wait_elapsed = wait_started.elapsed();

        timer.record_time("wait");
        timer.print_times("vello: ");

        let total_elapsed = frame_started.elapsed();
        if trace_enabled || total_elapsed.as_millis() >= 8 {
            eprintln!(
                "[shadow-anyrender-vello] frame-stats cmd_ms={} acquire_ms={} render_ms={} present_ms={} wait_ms={} total_ms={} wait_for_idle={}",
                cmd_elapsed.as_millis(),
                acquire_elapsed.as_millis(),
                render_elapsed.as_millis(),
                present_elapsed.as_millis(),
                wait_elapsed.as_millis(),
                total_elapsed.as_millis(),
                wait_for_idle
            );
        }

        // static COUNTER: AtomicU64 = AtomicU64::new(0);
        // println!("FRAME {}", COUNTER.fetch_add(1, atomic::Ordering::Relaxed));

        // Empty the Vello scene (memory optimisation)
        self.scene.reset();
    }
}
