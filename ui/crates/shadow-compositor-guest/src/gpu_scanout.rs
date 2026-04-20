#[cfg(any(target_os = "linux", target_os = "android"))]
mod imp {
    use anyhow::{anyhow, bail, Context, Result};
    use anyrender_vello::VelloImageRenderer;
    use ash::{ext, khr, vk};
    use drm::buffer::{DrmFourcc, DrmModifier};
    use smithay::backend::allocator::{
        dmabuf::{Dmabuf, DmabufFlags},
        Fourcc, Modifier,
    };
    use std::os::fd::{FromRawFd, OwnedFd};
    use wgpu::hal::vulkan::Api as Vulkan;

    use crate::kms::ScanoutFormatCandidate;
    use std::time::Instant;

    const SCANOUT_BUFFER_COUNT: usize = 2;

    pub struct VulkanScanoutChain {
        width: u32,
        height: u32,
        slots: Vec<ScanoutSlot>,
        next_slot: usize,
    }

    struct ScanoutSlot {
        _texture: wgpu::Texture,
        view: wgpu::TextureView,
        dmabuf: Dmabuf,
    }

    impl VulkanScanoutChain {
        pub fn new(
            renderer: &VelloImageRenderer,
            width: u32,
            height: u32,
            candidates: &[ScanoutFormatCandidate],
        ) -> Result<Self> {
            for candidate in candidates {
                let Some(texture_format) = scanout_texture_format(candidate.fourcc) else {
                    continue;
                };
                let supported_modifiers = supported_modifiers(
                    renderer,
                    candidate.fourcc,
                    texture_format,
                    &candidate.modifiers,
                )
                .with_context(|| {
                    format!(
                        "failed to query supported modifiers for {:?}",
                        candidate.fourcc
                    )
                })?;
                let Some(&modifier) = supported_modifiers.first() else {
                    continue;
                };

                let mut slots = Vec::with_capacity(SCANOUT_BUFFER_COUNT);
                for _ in 0..SCANOUT_BUFFER_COUNT {
                    slots.push(
                        create_scanout_slot(renderer, width, height, candidate.fourcc, modifier)
                            .with_context(|| {
                                format!(
                                    "failed to create scanout slot fourcc={:?} modifier={modifier:?}",
                                    candidate.fourcc
                                )
                            })?,
                    );
                }

                tracing::info!(
                    "[shadow-guest-compositor] gpu-scanout-enabled size={}x{} fourcc={:?} modifier={modifier:?} buffers={}",
                    width,
                    height,
                    candidate.fourcc,
                    SCANOUT_BUFFER_COUNT
                );
                return Ok(Self {
                    width,
                    height,
                    slots,
                    next_slot: 0,
                });
            }

            Err(anyhow!(
                "no Vulkan/KMS scanout path for {}x{} from candidates {:?}",
                width,
                height,
                candidates
            ))
        }

        pub fn width(&self) -> u32 {
            self.width
        }

        pub fn height(&self) -> u32 {
            self.height
        }

        pub fn render<F>(&mut self, renderer: &mut VelloImageRenderer, draw_fn: F) -> Result<Dmabuf>
        where
            F: FnOnce(&mut anyrender_vello::VelloScenePainter<'_, '_>),
        {
            let slot_index = self.next_slot;
            self.next_slot = (self.next_slot + 1) % self.slots.len();
            let slot = &mut self.slots[slot_index];
            let render_started = Instant::now();
            renderer.render_to_existing_texture_view(&slot.view, self.width, self.height, draw_fn);
            let render_elapsed = render_started.elapsed();
            let wait_started = Instant::now();
            renderer
                .device_handle()
                .device
                .poll(wgpu::PollType::wait_indefinitely())
                .context("failed to wait for GPU shell scanout render")?;
            let wait_elapsed = wait_started.elapsed();
            if gpu_profile_enabled() {
                tracing::info!(
                    "[shadow-guest-compositor] gpu-profile-scanout render_call_ms={} gpu_wait_ms={} render={}x{}",
                    render_elapsed.as_millis(),
                    wait_elapsed.as_millis(),
                    self.width,
                    self.height
                );
            }
            Ok(slot.dmabuf.clone())
        }
    }

    fn gpu_profile_enabled() -> bool {
        std::env::var_os("SHADOW_GUEST_COMPOSITOR_GPU_PROFILE_TRACE").is_some()
    }

    fn supported_modifiers(
        renderer: &VelloImageRenderer,
        fourcc: DrmFourcc,
        texture_format: wgpu::TextureFormat,
        candidates: &[DrmModifier],
    ) -> Result<Vec<DrmModifier>> {
        with_vulkan_hal(renderer, |_, hal_device, _| {
            ensure_modifier_extension(hal_device)?;
            let vk_format = vk_format_for_scanout(fourcc, texture_format)?;
            let usage = vk::ImageUsageFlags::STORAGE;
            let raw_instance = hal_device.shared_instance().raw_instance();
            let raw_physical_device = hal_device.raw_physical_device();
            let mut supported = Vec::new();

            for modifier in candidates {
                if modifier_supported(
                    raw_instance,
                    raw_physical_device,
                    vk_format,
                    usage,
                    *modifier,
                )? {
                    supported.push(*modifier);
                }
            }

            Ok(supported)
        })
    }

    fn modifier_supported(
        raw_instance: &ash::Instance,
        raw_physical_device: vk::PhysicalDevice,
        format: vk::Format,
        usage: vk::ImageUsageFlags,
        modifier: DrmModifier,
    ) -> Result<bool> {
        let mut drm_format_info = vk::PhysicalDeviceImageDrmFormatModifierInfoEXT::default()
            .drm_format_modifier(modifier.into())
            .sharing_mode(vk::SharingMode::EXCLUSIVE);
        let format_info = vk::PhysicalDeviceImageFormatInfo2::default()
            .format(format)
            .ty(vk::ImageType::TYPE_2D)
            .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
            .usage(usage)
            .flags(vk::ImageCreateFlags::empty())
            .push_next(&mut drm_format_info);
        let mut properties = vk::ImageFormatProperties2::default();

        let result = unsafe {
            raw_instance.get_physical_device_image_format_properties2(
                raw_physical_device,
                &format_info,
                &mut properties,
            )
        };

        match result {
            Ok(()) => Ok(true),
            Err(vk::Result::ERROR_FORMAT_NOT_SUPPORTED) => Ok(false),
            Err(error) => Err(anyhow!(error)),
        }
    }

    fn create_scanout_slot(
        renderer: &VelloImageRenderer,
        width: u32,
        height: u32,
        fourcc: DrmFourcc,
        modifier: DrmModifier,
    ) -> Result<ScanoutSlot> {
        let texture_format = scanout_texture_format(fourcc)
            .ok_or_else(|| anyhow!("unsupported scanout fourcc {:?}", fourcc))?;
        with_vulkan_hal(renderer, |device_handle, hal_device, _| {
            ensure_modifier_extension(hal_device)?;
            let raw_instance = hal_device.shared_instance().raw_instance();
            let raw_device = hal_device.raw_device();
            let raw_physical_device = hal_device.raw_physical_device();
            let vk_format = vk_format_for_scanout(fourcc, texture_format)?;

            let modifier_value: u64 = modifier.into();
            let modifier_values = [modifier_value];
            let mut modifier_list = vk::ImageDrmFormatModifierListCreateInfoEXT::default()
                .drm_format_modifiers(&modifier_values);
            let mut external_memory_info = vk::ExternalMemoryImageCreateInfo::default()
                .handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
            let image_create_info = vk::ImageCreateInfo::default()
                .image_type(vk::ImageType::TYPE_2D)
                .format(vk_format)
                .extent(vk::Extent3D {
                    width,
                    height,
                    depth: 1,
                })
                .mip_levels(1)
                .array_layers(1)
                .samples(vk::SampleCountFlags::TYPE_1)
                .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
                .usage(vk::ImageUsageFlags::STORAGE)
                .initial_layout(vk::ImageLayout::UNDEFINED)
                .push_next(&mut modifier_list)
                .push_next(&mut external_memory_info);
            let raw_image = unsafe { raw_device.create_image(&image_create_info, None) }
                .context("failed to create Vulkan scanout image")?;

            let memory_requirements =
                unsafe { raw_device.get_image_memory_requirements(raw_image) };
            let memory_type_index = find_memory_type_index(
                raw_instance,
                raw_physical_device,
                memory_requirements.memory_type_bits,
                vk::MemoryPropertyFlags::DEVICE_LOCAL,
            )
            .ok_or_else(|| anyhow!("no device-local memory type for scanout image"))?;

            let mut export_memory_info = vk::ExportMemoryAllocateInfo::default()
                .handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
            let allocate_info = vk::MemoryAllocateInfo::default()
                .allocation_size(memory_requirements.size)
                .memory_type_index(memory_type_index as u32)
                .push_next(&mut export_memory_info);
            let memory = unsafe { raw_device.allocate_memory(&allocate_info, None) }
                .context("failed to allocate Vulkan scanout memory")?;
            if let Err(error) = unsafe { raw_device.bind_image_memory(raw_image, memory, 0) } {
                unsafe {
                    raw_device.free_memory(memory, None);
                    raw_device.destroy_image(raw_image, None);
                }
                return Err(anyhow!(error)).context("failed to bind Vulkan scanout memory");
            }

            let hal_desc = wgpu::hal::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: texture_format,
                usage: wgpu::TextureUses::STORAGE_WRITE_ONLY,
                memory_flags: wgpu::hal::MemoryFlags::empty(),
                view_formats: Vec::new(),
            };
            let hal_texture = unsafe {
                hal_device.texture_from_raw(
                    raw_image,
                    &hal_desc,
                    None,
                    wgpu::hal::vulkan::TextureMemory::Dedicated(memory),
                )
            };
            let texture_desc = wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: texture_format,
                usage: wgpu::TextureUsages::STORAGE_BINDING,
                view_formats: &[],
            };
            let texture = unsafe {
                device_handle
                    .device
                    .create_texture_from_hal::<Vulkan>(hal_texture, &texture_desc)
            };
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            let dmabuf = export_dmabuf(
                raw_instance,
                raw_device,
                raw_image,
                memory,
                width,
                height,
                fourcc,
                modifier,
            )
            .context("failed to export scanout dmabuf")?;

            Ok(ScanoutSlot {
                _texture: texture,
                view,
                dmabuf,
            })
        })
    }

    fn export_dmabuf(
        raw_instance: &ash::Instance,
        raw_device: &ash::Device,
        raw_image: vk::Image,
        memory: vk::DeviceMemory,
        width: u32,
        height: u32,
        fourcc: DrmFourcc,
        modifier: DrmModifier,
    ) -> Result<Dmabuf> {
        let external_memory_fd = khr::external_memory_fd::Device::new(raw_instance, raw_device);
        let fd_info = vk::MemoryGetFdInfoKHR::default()
            .handle_type(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT)
            .memory(memory);
        let raw_fd = unsafe { external_memory_fd.get_memory_fd(&fd_info) }
            .context("failed to export Vulkan memory as dma-buf fd")?;
        let fd = unsafe { OwnedFd::from_raw_fd(raw_fd) };
        let subresource =
            vk::ImageSubresource::default().aspect_mask(vk::ImageAspectFlags::MEMORY_PLANE_0_EXT);
        let layout = unsafe { raw_device.get_image_subresource_layout(raw_image, subresource) };
        let mut builder = Dmabuf::builder(
            (width as i32, height as i32),
            smithay_fourcc(fourcc)?,
            Modifier::from(u64::from(modifier)),
            DmabufFlags::empty(),
        );
        builder.add_plane(fd, 0, layout.offset as u32, layout.row_pitch as u32);
        builder
            .build()
            .ok_or_else(|| anyhow!("failed to build dmabuf for exported Vulkan image"))
    }

    fn with_vulkan_hal<R>(
        renderer: &VelloImageRenderer,
        f: impl FnOnce(
            &wgpu_context::DeviceHandle,
            &wgpu::hal::vulkan::Device,
            &wgpu::hal::vulkan::Adapter,
        ) -> Result<R>,
    ) -> Result<R> {
        let device_handle = renderer.device_handle();
        if !matches!(
            device_handle.adapter.get_info().backend,
            wgpu::Backend::Vulkan
        ) {
            bail!("Vulkan scanout requires a Vulkan wgpu backend");
        }

        unsafe {
            let hal_adapter = device_handle
                .adapter
                .as_hal::<Vulkan>()
                .ok_or_else(|| anyhow!("failed to access Vulkan HAL adapter"))?;
            let hal_device = device_handle
                .device
                .as_hal::<Vulkan>()
                .ok_or_else(|| anyhow!("failed to access Vulkan HAL device"))?;
            f(device_handle, &*hal_device, &*hal_adapter)
        }
    }

    fn ensure_modifier_extension(hal_device: &wgpu::hal::vulkan::Device) -> Result<()> {
        hal_device
            .enabled_device_extensions()
            .contains(&ext::image_drm_format_modifier::NAME)
            .then_some(())
            .ok_or_else(|| anyhow!("Vulkan device missing VK_EXT_image_drm_format_modifier"))
    }

    fn scanout_texture_format(fourcc: DrmFourcc) -> Option<wgpu::TextureFormat> {
        match fourcc {
            DrmFourcc::Abgr8888 | DrmFourcc::Xbgr8888 => Some(wgpu::TextureFormat::Rgba8Unorm),
            _ => None,
        }
    }

    fn vk_format_for_scanout(
        fourcc: DrmFourcc,
        texture_format: wgpu::TextureFormat,
    ) -> Result<vk::Format> {
        match (fourcc, texture_format) {
            (DrmFourcc::Abgr8888 | DrmFourcc::Xbgr8888, wgpu::TextureFormat::Rgba8Unorm) => {
                Ok(vk::Format::R8G8B8A8_UNORM)
            }
            other => Err(anyhow!("unsupported scanout format tuple {other:?}")),
        }
    }

    fn smithay_fourcc(fourcc: DrmFourcc) -> Result<Fourcc> {
        match fourcc {
            DrmFourcc::Abgr8888 => Ok(Fourcc::Abgr8888),
            DrmFourcc::Xbgr8888 => Ok(Fourcc::Xbgr8888),
            other => Err(anyhow!("unsupported smithay fourcc {:?}", other)),
        }
    }

    fn find_memory_type_index(
        raw_instance: &ash::Instance,
        raw_physical_device: vk::PhysicalDevice,
        type_bits: u32,
        required_flags: vk::MemoryPropertyFlags,
    ) -> Option<usize> {
        let memory_properties =
            unsafe { raw_instance.get_physical_device_memory_properties(raw_physical_device) };
        memory_properties
            .memory_types_as_slice()
            .iter()
            .enumerate()
            .find_map(|(index, memory_type)| {
                let supported = type_bits & (1 << index) != 0;
                let matches_flags = memory_type.property_flags.contains(required_flags);
                (supported && matches_flags).then_some(index)
            })
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
mod imp {
    use anyhow::{anyhow, Result};
    use anyrender_vello::VelloImageRenderer;
    use smithay::backend::allocator::dmabuf::Dmabuf;

    use crate::kms::ScanoutFormatCandidate;

    pub struct VulkanScanoutChain;

    impl VulkanScanoutChain {
        pub fn new(
            _renderer: &VelloImageRenderer,
            _width: u32,
            _height: u32,
            _candidates: &[ScanoutFormatCandidate],
        ) -> Result<Self> {
            Err(anyhow!("Vulkan scanout is only supported on Linux/Android"))
        }

        pub fn width(&self) -> u32 {
            0
        }

        pub fn height(&self) -> u32 {
            0
        }

        pub fn render<F>(
            &mut self,
            _renderer: &mut VelloImageRenderer,
            _draw_fn: F,
        ) -> Result<Dmabuf>
        where
            F: FnOnce(&mut anyrender_vello::VelloScenePainter<'_, '_>),
        {
            Err(anyhow!("Vulkan scanout is only supported on Linux/Android"))
        }
    }
}

pub use imp::*;
