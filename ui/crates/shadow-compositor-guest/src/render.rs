use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

use chrono::Local;
use shadow_ui_core::{
    scene::{HEIGHT, WIDTH},
    shell::ShellStatus,
};
use smithay::{
    backend::allocator::Buffer as AllocatorBuffer,
    backend::renderer::{buffer_dimensions, utils::Buffer, BufferType},
    reexports::wayland_server::protocol::{wl_shm, wl_surface::WlSurface},
    wayland::{
        compositor::{with_surface_tree_downward, SurfaceAttributes, TraversalAction},
        dmabuf::get_dmabuf,
        shm::with_buffer_contents,
    },
};

use crate::{kms, shell::AppFrame, touch};

use super::ShadowGuestCompositor;

impl ShadowGuestCompositor {
    fn shell_render_size(&self) -> (u32, u32) {
        if self.drm_enabled && self.gpu_shell {
            return (WIDTH.round() as u32, HEIGHT.round() as u32);
        }
        if let Some(display) = self.kms_display.as_ref() {
            return display.dimensions();
        }

        let width = u32::try_from(self.toplevel_size.w.max(1)).unwrap_or(WIDTH.round() as u32);
        let height = u32::try_from(self.toplevel_size.h.max(1)).unwrap_or(HEIGHT.round() as u32);
        (width, height)
    }

    pub(crate) fn publish_visible_shell_frame(&mut self, frame_marker: &str) {
        if !self.shell_overlay_visible() {
            return;
        }
        if frame_marker != "hosted-touch-move-frame" {
            self.hosted_touch_move_frame_pending = false;
        }
        if frame_marker == "hosted-touch-move-frame" {
            self.begin_scroll_frame_trace(frame_marker);
        }

        let status = ShellStatus::demo(Local::now());
        let scene = self.shell.scene(&status);
        let (render_width, render_height) = self.shell_render_size();
        let focused_hosted_app = self.gpu_shell.then(|| self.focused_hosted_app()).flatten();
        self.shell_surface.resize(render_width, render_height);
        if self.drm_enabled && self.gpu_shell {
            let Some(scanout_candidates) = self
                .ensure_kms_display_with_timeout(Duration::from_millis(0))
                .map(|display| display.scanout_candidates().to_vec())
            else {
                tracing::warn!(
                    "[shadow-guest-compositor] gpu-scanout-kms-not-ready frame_marker={frame_marker} size={}x{}",
                    render_width,
                    render_height
                );
                self.schedule_shell_frame_retry();
                return;
            };
            if let Err(error) = self
                .shell_surface
                .configure_gpu_scanout(&scanout_candidates)
            {
                if self.strict_gpu_resident {
                    panic!(
                        "strict gpu resident mode rejected shell GPU scanout configuration: {error:#}"
                    );
                }
                tracing::warn!(
                    "[shadow-guest-compositor] gpu-scanout-unavailable size={}x{} error={error:#}",
                    render_width,
                    render_height
                );
            }
        }
        let app_frame = focused_hosted_app
            .is_none()
            .then(|| {
                self.focused_app.and_then(|app_id| {
                    self.app_frames.get(&app_id).map(|frame| AppFrame {
                        width: frame.width,
                        height: frame.height,
                        stride: frame.stride,
                        format: frame.format,
                        pixels: &frame.pixels,
                    })
                })
            })
            .flatten();
        let shell_stats = if let Some(app_id) = focused_hosted_app {
            let (shell_surface, hosted_apps) = (&mut self.shell_surface, &mut self.hosted_apps);
            let hosted_app = hosted_apps
                .get_mut(&app_id)
                .expect("focused hosted app present")
                .app_mut();
            shell_surface.render_scene_with_hosted_app(&scene, hosted_app)
        } else {
            self.shell_surface
                .render_scene_with_app_frame(&scene, app_frame)
        };
        let shell_stats = match shell_stats {
            Ok(stats) => stats,
            Err(error) => {
                if self.strict_gpu_resident {
                    panic!(
                        "strict gpu resident mode rejected visible shell frame render: {error:#}"
                    );
                }
                tracing::warn!(
                    "[shadow-guest-compositor] shell-frame-render-failed frame_marker={frame_marker} error={error:#}"
                );
                return;
            }
        };
        let shell_total =
            shell_stats.scene_render + shell_stats.base_copy + shell_stats.app_composite;
        if shell_total.as_millis() >= 8 {
            tracing::info!(
                "[shadow-guest-compositor] shell-frame-stats cache_hit={} scene_render_ms={} base_copy_ms={} app_composite_ms={} total_ms={}",
                shell_stats.scene_cache_hit,
                shell_stats.scene_render.as_millis(),
                shell_stats.base_copy.as_millis(),
                shell_stats.app_composite.as_millis(),
                shell_total.as_millis()
            );
        }
        if let Some(dmabuf) = self.shell_surface.take_presentable_dmabuf() {
            let debug_cpu_frame_requested = self.frame_artifacts_enabled
                || self.frame_snapshot_cache_enabled
                || self.frame_checksum_enabled;
            let mut presented = false;
            if debug_cpu_frame_requested {
                match kms::capture_dmabuf_frame(&dmabuf) {
                    Ok(frame) => {
                        self.record_frame_view(frame.view(), frame_marker);
                        if self.frame_snapshot_cache_enabled {
                            self.last_published_frame = Some(frame);
                        }
                    }
                    Err(error) => {
                        tracing::warn!(
                            "[shadow-guest-compositor] shell-dmabuf-capture failed: {error}"
                        );
                    }
                }
            } else {
                let size = dmabuf.size();
                self.last_frame_size = Some((size.w.max(0) as u32, size.h.max(0) as u32));
            }

            if self.drm_enabled {
                if let Some(display) = self.ensure_kms_display_with_timeout(Duration::from_secs(2))
                {
                    match display.present_dmabuf(&dmabuf) {
                        Ok(()) => {
                            presented = true;
                            tracing::info!(
                                "[shadow-guest-compositor] presented-shell-dmabuf size={}x{} fourcc={:?} modifier={:?}",
                                dmabuf.size().w,
                                dmabuf.size().h,
                                dmabuf.format().code,
                                dmabuf.format().modifier
                            );
                            tracing::info!("[shadow-guest-compositor] presented-frame");
                        }
                        Err(error) => {
                            tracing::warn!(
                                "[shadow-guest-compositor] present-shell-dmabuf failed: {error}"
                            );
                        }
                    }
                }
            }

            self.record_touch_present(frame_marker);
            self.record_scroll_frame_present(frame_marker);
            if self.exit_on_first_frame {
                self.request_exit();
            }
            if self.drm_enabled && !presented {
                self.schedule_shell_frame_retry();
            }
            return;
        }
        let pixels = self.shell_surface.take_pixels();
        let frame = kms::CapturedFrameView {
            width: render_width,
            height: render_height,
            stride: render_width * 4,
            pixels: &pixels,
        };
        let presented =
            self.publish_frame_view_with_timeout(frame, frame_marker, Duration::from_secs(2));
        self.shell_surface.restore_pixels(pixels);
        if self.drm_enabled && !presented {
            self.schedule_shell_frame_retry();
        }
    }

    pub(crate) fn prewarm_visible_shell_frame(&mut self) {
        if !self.shell_overlay_visible() {
            return;
        }

        let status = ShellStatus::demo(Local::now());
        let scene = self.shell.scene(&status);
        let (render_width, render_height) = self.shell_render_size();
        self.shell_surface.resize(render_width, render_height);
        if self.drm_enabled && self.gpu_shell {
            let Some(scanout_candidates) = self
                .ensure_kms_display_with_timeout(Duration::from_millis(0))
                .map(|display| display.scanout_candidates().to_vec())
            else {
                tracing::warn!(
                    "[shadow-guest-compositor] shell-prewarm-kms-not-ready size={}x{}",
                    render_width,
                    render_height
                );
                return;
            };
            if let Err(error) = self
                .shell_surface
                .configure_gpu_scanout(&scanout_candidates)
            {
                if self.strict_gpu_resident {
                    panic!(
                        "strict gpu resident mode rejected shell prewarm scanout configuration: {error:#}"
                    );
                }
                tracing::warn!(
                    "[shadow-guest-compositor] shell-prewarm-scanout-unavailable size={}x{} error={error:#}",
                    render_width,
                    render_height
                );
            }
        }
        let shell_stats = self.shell_surface.render_scene_with_app_frame(&scene, None);
        let shell_stats = match shell_stats {
            Ok(stats) => stats,
            Err(error) => {
                if self.strict_gpu_resident {
                    panic!("strict gpu resident mode rejected shell prewarm render: {error:#}");
                }
                tracing::warn!(
                    "[shadow-guest-compositor] shell-prewarm-render-failed error={error:#}"
                );
                return;
            }
        };
        let _ = self.shell_surface.take_presentable_dmabuf();
        let shell_total =
            shell_stats.scene_render + shell_stats.base_copy + shell_stats.app_composite;
        if shell_total.as_millis() >= 8 {
            tracing::info!(
                "[shadow-guest-compositor] shell-prewarm-stats cache_hit={} scene_render_ms={} base_copy_ms={} app_composite_ms={} total_ms={}",
                shell_stats.scene_cache_hit,
                shell_stats.scene_render.as_millis(),
                shell_stats.base_copy.as_millis(),
                shell_stats.app_composite.as_millis(),
                shell_total.as_millis()
            );
        }
    }

    pub(crate) fn write_frame_snapshot(&self, path: Option<String>) -> std::io::Result<String> {
        let frame = self.last_published_frame.as_ref().ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "no published frame available for snapshot",
            )
        })?;
        let path = path
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| self.frame_artifact_path.clone());
        let checksum = kms::frame_checksum(frame);
        kms::write_frame_ppm(frame, &path)
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        tracing::info!(
            "[shadow-guest-compositor] wrote-frame-snapshot path={} checksum={checksum:016x} size={}x{}",
            path.display(),
            frame.width,
            frame.height
        );
        Ok(format!(
            "ok\npath={}\nchecksum={checksum:016x}\nsize={}x{}\n",
            path.display(),
            frame.width,
            frame.height
        ))
    }

    fn publish_frame(&mut self, frame: &kms::CapturedFrame, frame_marker: &str) {
        self.publish_frame_view(frame.view(), frame_marker);
        if self.frame_snapshot_cache_enabled {
            self.last_published_frame = Some(frame.clone());
        }
    }

    fn publish_frame_view(&mut self, frame: kms::CapturedFrameView<'_>, frame_marker: &str) {
        self.publish_frame_view_with_timeout(frame, frame_marker, Duration::from_secs(18));
    }

    fn publish_frame_view_with_timeout(
        &mut self,
        frame: kms::CapturedFrameView<'_>,
        frame_marker: &str,
        kms_timeout: Duration,
    ) -> bool {
        self.record_frame_view(frame, frame_marker);
        if self.frame_snapshot_cache_enabled {
            self.last_published_frame = Some(kms::copy_frame_view(frame, wl_shm::Format::Xrgb8888));
        }

        let mut presented = false;
        if self.drm_enabled {
            if let Some(display) = self.ensure_kms_display_with_timeout(kms_timeout) {
                match display.present_frame_view(frame) {
                    Ok(()) => {
                        presented = true;
                        tracing::info!("[shadow-guest-compositor] presented-frame");
                    }
                    Err(error) => {
                        tracing::warn!("[shadow-guest-compositor] present-frame failed: {error}")
                    }
                }
            }
        }

        self.record_touch_present(frame_marker);
        self.record_scroll_frame_present(frame_marker);

        if self.exit_on_first_frame {
            self.request_exit();
        }

        presented
    }

    fn record_frame_view(&mut self, frame: kms::CapturedFrameView<'_>, frame_marker: &str) {
        self.last_frame_size = Some((frame.width, frame.height));
        let checksum = (self.frame_checksum_enabled || self.frame_artifacts_enabled)
            .then(|| kms::frame_view_checksum(frame));
        if let Some(checksum) = checksum {
            tracing::info!(
                "[shadow-guest-compositor] {frame_marker} checksum={checksum:016x} size={}x{}",
                frame.width,
                frame.height
            );
        }
        if let Some(display) = self.kms_display.as_ref() {
            let (panel_width, panel_height) = display.dimensions();
            if let Some((dst_x, dst_y, copy_width, copy_height)) =
                touch::frame_content_rect(panel_width, panel_height, frame.width, frame.height)
            {
                tracing::info!(
                    "[shadow-guest-compositor] frame-content-rect panel={}x{} frame={}x{} rect={}x{}+{},{}",
                    panel_width,
                    panel_height,
                    frame.width,
                    frame.height,
                    copy_width,
                    copy_height,
                    dst_x,
                    dst_y
                );
            }
        }

        if self.frame_artifacts_enabled
            && (!self.frame_artifact_written || self.frame_artifact_every_frame)
        {
            match kms::write_frame_view_ppm(frame, &self.frame_artifact_path) {
                Ok(()) => {
                    self.frame_artifact_written = true;
                    let checksum = checksum.unwrap_or_else(|| kms::frame_view_checksum(frame));
                    tracing::info!(
                        "[shadow-guest-compositor] wrote-frame-artifact path={} checksum={checksum:016x} size={}x{}",
                        self.frame_artifact_path.display(),
                        frame.width,
                        frame.height
                    );
                }
                Err(error) => {
                    tracing::warn!("[shadow-guest-compositor] capture-write failed: {error}");
                }
            }
        }
    }

    pub(crate) fn run_boot_splash(&mut self) {
        let Some(display) = self.ensure_kms_display() else {
            return;
        };
        let (panel_width, panel_height) = display.dimensions();
        let frame = kms::build_boot_splash_frame(panel_width, panel_height);
        self.publish_frame(&frame, "boot-splash-frame-generated");
    }

    fn take_surface_buffer(&self, surface: &WlSurface) -> Option<Buffer> {
        smithay::backend::renderer::utils::with_renderer_surface_state(surface, |state| {
            state.buffer().cloned()
        })
        .flatten()
    }

    fn observe_surface_buffer(&mut self, buffer: &Buffer) -> Option<BufferType> {
        let buffer_type = smithay::backend::renderer::buffer_type(buffer);
        let signature = match buffer_type {
            Some(BufferType::Dma) => {
                let dmabuf = get_dmabuf(buffer).expect("dmabuf-managed buffer");
                let size = dmabuf.size();
                let format = dmabuf.format();
                format!(
                    "type=dma size={}x{} fourcc={:?} modifier={:?} planes={} y_inverted={}",
                    size.w,
                    size.h,
                    format.code,
                    format.modifier,
                    dmabuf.num_planes(),
                    dmabuf.y_inverted()
                )
            }
            Some(BufferType::Shm) => {
                let size = buffer_dimensions(buffer)
                    .map(|size| format!("{}x{}", size.w, size.h))
                    .unwrap_or_else(|| "unknown".into());
                format!("type=shm size={size}")
            }
            Some(BufferType::SinglePixel) => "type=single-pixel size=1x1".into(),
            Some(_) => "type=other".into(),
            None => "type=unknown".into(),
        };

        if self.last_buffer_signature.as_ref() != Some(&signature) {
            tracing::info!("[shadow-guest-compositor] buffer-observed {signature}");
            self.last_buffer_signature = Some(signature);
        }

        if matches!(buffer_type, Some(BufferType::Dma)) && self.exit_on_first_dma_buffer {
            tracing::info!("[shadow-guest-compositor] exit-on-first-dma-buffer");
            self.request_exit();
        }

        buffer_type
    }

    pub(crate) fn present_surface(&mut self, surface: &WlSurface) {
        let Some(buffer) = self.take_surface_buffer(surface) else {
            self.send_frame_callbacks(surface);
            return;
        };
        let observed_type = self.observe_surface_buffer(&buffer);
        let debug_cpu_frame_requested = self.frame_artifacts_enabled
            || self.frame_snapshot_cache_enabled
            || self.frame_checksum_enabled;
        if matches!(observed_type, Some(BufferType::Dma)) {
            let dmabuf = get_dmabuf(&buffer).expect("dmabuf-managed buffer");
            let mut directly_presented = false;

            if self.drm_enabled && !self.shell_enabled {
                if let Some(display) = self.ensure_kms_display() {
                    match display.present_dmabuf(&dmabuf) {
                        Ok(()) => {
                            directly_presented = true;
                            tracing::info!(
                                "[shadow-guest-compositor] presented-dmabuf-direct size={}x{}",
                                dmabuf.size().w,
                                dmabuf.size().h
                            );
                        }
                        Err(error) => {
                            tracing::warn!(
                                "[shadow-guest-compositor] present-dmabuf failed: {error}"
                            );
                        }
                    }
                }
            }

            let direct_present_needs_cpu_frame =
                self.shell_enabled || !directly_presented || debug_cpu_frame_requested;
            if directly_presented && !direct_present_needs_cpu_frame {
                let size = dmabuf.size();
                self.last_frame_size = Some((size.w.max(0) as u32, size.h.max(0) as u32));
                tracing::info!("[shadow-guest-compositor] presented-frame");
                self.record_touch_present("presented-dmabuf-direct");
                if self.exit_on_first_frame {
                    self.request_exit();
                }
                buffer.release();
                self.send_frame_callbacks(surface);
                return;
            }

            let capture_started = Instant::now();
            match kms::capture_dmabuf_frame(&dmabuf) {
                Ok(frame) => {
                    let capture_elapsed = capture_started.elapsed();
                    if capture_elapsed.as_millis() >= 8 {
                        tracing::info!(
                            "[shadow-guest-compositor] capture-dmabuf-frame ms={} size={}x{} shell_enabled={} direct_presented={}",
                            capture_elapsed.as_millis(),
                            frame.width,
                            frame.height,
                            self.shell_enabled,
                            directly_presented
                        );
                    }
                    if self.shell_enabled {
                        let app_id = self.surface_apps.get(surface).copied();
                        if let Some(app_id) = app_id {
                            self.app_frames.insert(app_id, frame);
                        }
                        self.publish_visible_shell_frame("captured-dmabuf-frame");
                    } else if directly_presented {
                        self.record_frame_view(frame.view(), "captured-dmabuf-frame");
                        if self.frame_snapshot_cache_enabled {
                            self.last_published_frame = Some(frame.clone());
                        }
                        tracing::info!("[shadow-guest-compositor] presented-frame");
                        self.record_touch_present("captured-dmabuf-frame");
                        if self.exit_on_first_frame {
                            self.request_exit();
                        }
                    } else {
                        self.publish_frame(&frame, "captured-dmabuf-frame");
                    }
                }
                Err(error) => {
                    let capture_elapsed = capture_started.elapsed();
                    tracing::warn!("[shadow-guest-compositor] capture-dmabuf failed: {error}");
                    if capture_elapsed.as_millis() >= 8 {
                        tracing::info!(
                            "[shadow-guest-compositor] capture-dmabuf-failed-latency ms={} shell_enabled={} direct_presented={}",
                            capture_elapsed.as_millis(),
                            self.shell_enabled,
                            directly_presented
                        );
                    }
                }
            }

            buffer.release();
            self.send_frame_callbacks(surface);
            return;
        }
        if !matches!(observed_type, Some(BufferType::Shm)) {
            tracing::warn!(
                "[shadow-guest-compositor] unsupported-frame-buffer type={:?}",
                observed_type
            );
            buffer.release();
            self.send_frame_callbacks(surface);
            return;
        }
        let capture_result = with_buffer_contents(&buffer, |ptr, len, data| {
            kms::capture_shm_frame(ptr, len, data)
        });

        match capture_result {
            Ok(Ok(frame)) => {
                self.record_touch_commit();
                if self.shell_enabled {
                    let app_id = self.surface_apps.get(surface).copied();
                    if let Some(app_id) = app_id {
                        self.app_frames.insert(app_id, frame);
                    }
                    self.publish_visible_shell_frame("captured-frame");
                } else {
                    self.publish_frame(&frame, "captured-frame");
                }
            }
            Ok(Err(error)) => {
                tracing::warn!("[shadow-guest-compositor] capture-frame failed: {error}");
            }
            Err(error) => {
                tracing::warn!("[shadow-guest-compositor] shm buffer access failed: {error}");
            }
        }

        buffer.release();
        self.send_frame_callbacks(surface);
    }

    fn send_frame_callbacks(&mut self, surface: &WlSurface) {
        let elapsed = self.start_time.elapsed();
        with_surface_tree_downward(
            surface,
            (),
            |_, _, &()| TraversalAction::DoChildren(()),
            |_surface, states, &()| {
                for callback in states
                    .cached_state
                    .get::<SurfaceAttributes>()
                    .current()
                    .frame_callbacks
                    .drain(..)
                {
                    callback.done(elapsed.as_millis() as u32);
                }
            },
            |_, _, &()| true,
        );
        self.space.refresh();
        self.flush_wayland_clients();
    }
}
