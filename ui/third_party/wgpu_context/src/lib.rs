// Copyright 2022 the Vello Authors
// SPDX-License-Identifier: Apache-2.0 OR MIT

//! Simple helpers for managing wgpu state and surfaces.

use std::{env, ffi::CStr};

use wgpu::{
    Adapter, Device, Features, Instance, Limits, MemoryHints, Queue, Surface, SurfaceTarget,
};

mod buffer_renderer;
mod error;
mod surface_renderer;
mod util;

pub use buffer_renderer::{BufferRenderer, BufferRendererConfig};
pub use error::WgpuContextError;
pub use surface_renderer::{SurfaceRenderer, SurfaceRendererConfiguration, TextureConfiguration};
pub use util::block_on_wgpu;

/// A wgpu `Device`, it's associated `Queue`, and the `Adapter` and `Instance` used to create them
#[derive(Clone, Debug)]
pub struct DeviceHandle {
    pub instance: Instance,
    pub adapter: Adapter,
    pub device: Device,
    pub queue: Queue,
}

/// Simple render context that maintains wgpu state for rendering the pipeline.
pub struct WGPUContext {
    /// A WGPU `Instance`. This only needs to be created once per application.
    pub instance: Instance,
    /// A pool of already-created devices so that we can avoid recreating devices
    /// when we already have a suitable one available
    pub device_pool: Vec<DeviceHandle>,

    // Config
    extra_features: Option<Features>,
    override_limits: Option<Limits>,
    extra_vulkan_device_extensions: Vec<&'static CStr>,
}

const SHADOW_WGPU_MEMORY_HINT_ENV: &str = "SHADOW_WGPU_MEMORY_HINT";

impl Default for WGPUContext {
    fn default() -> Self {
        Self::new()
    }
}

impl WGPUContext {
    pub fn new() -> Self {
        Self::with_features_and_limits(None, None)
    }

    pub fn with_features_and_limits(
        extra_features: Option<Features>,
        override_limits: Option<Limits>,
    ) -> Self {
        Self::with_features_limits_and_vulkan_extensions(
            extra_features,
            override_limits,
            Vec::new(),
        )
    }

    pub fn with_features_limits_and_vulkan_extensions(
        extra_features: Option<Features>,
        override_limits: Option<Limits>,
        extra_vulkan_device_extensions: Vec<&'static CStr>,
    ) -> Self {
        Self {
            instance: Instance::new(&wgpu::InstanceDescriptor {
                backends: wgpu::Backends::from_env().unwrap_or_default(),
                flags: wgpu::InstanceFlags::from_build_config().with_env(),
                backend_options: wgpu::BackendOptions::from_env_or_default(),
                memory_budget_thresholds: wgpu::MemoryBudgetThresholds::default(),
            }),
            device_pool: Vec::new(),
            extra_features,
            override_limits,
            extra_vulkan_device_extensions,
        }
    }

    /// Creates a new surface for the specified window and dimensions.
    pub async fn create_surface<'w>(
        &mut self,
        window: impl Into<SurfaceTarget<'w>>,
        surface_config: SurfaceRendererConfiguration,
        intermediate_texture_config: Option<TextureConfiguration>,
    ) -> Result<SurfaceRenderer<'w>, WgpuContextError> {
        // Create a surface from the window handle
        let surface = match self.instance.create_surface(window.into()) {
            Ok(surface) => surface,
            Err(error) => {
                eprintln!("[shadow-wgpu-context] create-surface-target-error error={error:#}");
                eprintln!("[shadow-wgpu-context] create-surface-target-error-debug={error:?}");
                return Err(error.into());
            }
        };
        log_surface_diagnostics(&self.instance, &surface, "create-surface");

        // Find or create a suitable device for rendering to the surface
        let dev_id = match self.find_or_create_device(Some(&surface)).await {
            Ok(dev_id) => dev_id,
            Err(error) => {
                eprintln!("[shadow-wgpu-context] create-surface-find-device-error error={error:#}");
                log_surface_diagnostics(&self.instance, &surface, "surface-no-compatible-device");
                return Err(error);
            }
        };
        let device_handle = self.device_pool[dev_id].clone();

        SurfaceRenderer::new(
            surface,
            surface_config,
            intermediate_texture_config,
            device_handle,
            dev_id,
        )
        .await
    }

    /// Creates a new `BufferRenderer` for the specified dimensions.
    pub async fn create_buffer_renderer(
        &mut self,
        config: BufferRendererConfig,
    ) -> Result<BufferRenderer, WgpuContextError> {
        // Find or create a suitable device for rendering to the surface
        let dev_id = self.find_or_create_device(None).await?;
        let device_handle = self.device_pool[dev_id].clone();

        Ok(BufferRenderer::new(config, device_handle, dev_id))
    }

    /// Creates or reuses a headless device handle with the same adapter/device path used by
    /// `create_buffer_renderer`, but preserves the underlying adapter/device error surface.
    pub async fn create_headless_device_handle(&mut self) -> Result<DeviceHandle, WgpuContextError> {
        let dev_id = self.find_or_create_device(None).await?;
        Ok(self.device_pool[dev_id].clone())
    }

    /// Finds or creates a compatible device handle id.
    pub async fn find_or_create_device(
        &mut self,
        compatible_surface: Option<&Surface<'_>>,
    ) -> Result<usize, WgpuContextError> {
        match self.find_existing_device(compatible_surface) {
            Some(device_id) => Ok(device_id),
            None => self.create_device(compatible_surface).await,
        }
    }

    /// Finds or creates a compatible device handle id.
    fn find_existing_device(&self, compatible_surface: Option<&Surface<'_>>) -> Option<usize> {
        match compatible_surface {
            Some(s) => self
                .device_pool
                .iter()
                .enumerate()
                .find(|(_, d)| d.adapter.is_surface_supported(s))
                .map(|(i, _)| i),
            None => (!self.device_pool.is_empty()).then_some(0),
        }
    }

    /// Creates a compatible device handle id.
    async fn create_device(
        &mut self,
        compatible_surface: Option<&Surface<'_>>,
    ) -> Result<usize, WgpuContextError> {
        let instance = self.instance.clone();
        let adapter =
            match wgpu::util::initialize_adapter_from_env_or_default(&instance, compatible_surface)
                .await
            {
                Ok(adapter) => adapter,
                Err(error) => {
                    eprintln!("[shadow-wgpu-context] request-adapter-error error={error:#}");
                    if let Some(surface) = compatible_surface {
                        log_surface_diagnostics(&instance, surface, "request-adapter-error");
                    }
                    return Err(error.into());
                }
            };
        let info = adapter.get_info();
        eprintln!(
            "[shadow-wgpu-context] selected-adapter backend={:?} device_type={:?} name={:?} driver={:?} driver_info={:?}",
            info.backend,
            info.device_type,
            info.name,
            info.driver,
            info.driver_info
        );
        if let Some(surface) = compatible_surface {
            let caps = surface.get_capabilities(&adapter);
            eprintln!(
                "[shadow-wgpu-context] selected-adapter-surface supported={} formats={:?} present_modes={:?} alpha_modes={:?}",
                adapter.is_surface_supported(surface),
                caps.formats,
                caps.present_modes,
                caps.alpha_modes
            );
        }

        // Determine features to request
        // The user may request additional features
        let requested_features = self.extra_features.unwrap_or(Features::empty());
        let available_features = adapter.features();
        let required_features = requested_features & available_features;
        eprintln!(
            "[shadow-wgpu-context] request-device-features requested={requested_features:?} available={available_features:?} required={required_features:?}"
        );

        // Determine limits to request
        // The user may override the limits
        let required_limits = self.override_limits.clone().unwrap_or_default();
        let memory_hints = configured_memory_hints();
        eprintln!(
            "[shadow-wgpu-context] request-device-config limits={required_limits:?} memory_hints={memory_hints:?}"
        );

        // Create the device and the queue
        let descripter = wgpu::DeviceDescriptor {
            label: None,
            required_features,
            required_limits,
            memory_hints: memory_hints.clone(),
            trace: wgpu::Trace::default(),
            experimental_features: wgpu::ExperimentalFeatures::default(),
        };
        #[cfg(any(target_os = "linux", target_os = "android"))]
        let use_custom_vulkan_device = !self.extra_vulkan_device_extensions.is_empty()
            && matches!(info.backend, wgpu::Backend::Vulkan);
        #[cfg(not(any(target_os = "linux", target_os = "android")))]
        let use_custom_vulkan_device = false;

        let (device, queue) = if use_custom_vulkan_device {
            #[cfg(any(target_os = "linux", target_os = "android"))]
            {
            let extra_vulkan_device_extensions = self.extra_vulkan_device_extensions.clone();
            unsafe {
                let Some(hal_adapter) = adapter.as_hal::<wgpu::hal::vulkan::Api>() else {
                    return Err(WgpuContextError::NoCompatibleDevice);
                };
                let unsupported_extensions = extra_vulkan_device_extensions
                    .iter()
                    .copied()
                    .filter(|extension| {
                        !hal_adapter
                            .physical_device_capabilities()
                            .supports_extension(extension)
                    })
                    .collect::<Vec<_>>();
                if !unsupported_extensions.is_empty() {
                    eprintln!(
                        "[shadow-wgpu-context] unsupported-vulkan-device-extensions backend={:?} extensions={unsupported_extensions:?}",
                        info.backend
                    );
                    return Err(WgpuContextError::NoCompatibleDevice);
                }
                let open_device = hal_adapter.open_with_callback(
                    required_features,
                    &memory_hints,
                    Some(Box::new(move |mut args| {
                        for extension in extra_vulkan_device_extensions {
                            if !args.extensions.contains(&extension) {
                                args.extensions.push(extension);
                            }
                        }
                    })),
                )
                .map_err(|error| {
                    eprintln!(
                        "[shadow-wgpu-context] open-vulkan-device-error error={error:#}"
                    );
                    WgpuContextError::NoCompatibleDevice
                })?;
                adapter.create_device_from_hal::<wgpu::hal::vulkan::Api>(
                    open_device,
                    &descripter,
                )?
            }
            }
            #[cfg(not(any(target_os = "linux", target_os = "android")))]
            {
                unreachable!("custom Vulkan device path is only compiled on Linux/Android");
            }
        } else {
            adapter.request_device(&descripter).await?
        };

        // Create the device handle and store in the pool
        let device_handle = DeviceHandle {
            instance,
            adapter,
            device,
            queue,
        };
        self.device_pool.push(device_handle);

        // Return the ID
        Ok(self.device_pool.len() - 1)
    }
}

fn configured_memory_hints() -> MemoryHints {
    let Some(raw_value) = env::var(SHADOW_WGPU_MEMORY_HINT_ENV)
        .ok()
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
    else {
        return MemoryHints::MemoryUsage;
    };

    match raw_value.as_str() {
        "memory-usage" | "memoryusage" => MemoryHints::MemoryUsage,
        "performance" => MemoryHints::Performance,
        other => {
            eprintln!(
                "[shadow-wgpu-context] invalid-memory-hint env={} raw_value={other:?} fallback=MemoryUsage",
                SHADOW_WGPU_MEMORY_HINT_ENV
            );
            MemoryHints::MemoryUsage
        }
    }
}

fn log_surface_diagnostics(instance: &Instance, surface: &Surface<'_>, source: &str) {
    let adapters = pollster::block_on(instance.enumerate_adapters(wgpu::Backends::all()));
    eprintln!(
        "[shadow-wgpu-context] surface-diagnostics source={} adapter_count={}",
        source,
        adapters.len()
    );
    for (index, adapter) in adapters.into_iter().enumerate() {
        let info = adapter.get_info();
        let supported = adapter.is_surface_supported(surface);
        let caps = surface.get_capabilities(&adapter);
        eprintln!(
            "[shadow-wgpu-context] surface-adapter index={} supported={} backend={:?} device_type={:?} name={:?} driver={:?} driver_info={:?} formats={:?} present_modes={:?} alpha_modes={:?}",
            index,
            supported,
            info.backend,
            info.device_type,
            info.name,
            info.driver,
            info.driver_info,
            caps.formats,
            caps.present_modes,
            caps.alpha_modes
        );
    }
}
