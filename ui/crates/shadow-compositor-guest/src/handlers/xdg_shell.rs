use shadow_ui_core::app;
use smithay::{
    delegate_xdg_shell,
    desktop::Window,
    reexports::wayland_server::protocol::{wl_seat, wl_surface::WlSurface},
    utils::Serial,
    wayland::{
        compositor::with_states,
        shell::xdg::{
            PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
            XdgToplevelSurfaceData,
        },
    },
};

use super::ShadowGuestCompositor;

impl XdgShellHandler for ShadowGuestCompositor {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell_state
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        self.configure_toplevel(&surface);
        let _ = surface.send_pending_configure();
        let wl_surface = surface.wl_surface().clone();
        let window = Window::new_wayland_window(surface);
        self.handle_window_mapped(window);
        self.refresh_toplevel_app_id(&wl_surface);
    }

    fn new_popup(&mut self, _surface: PopupSurface, _positioner: PositionerState) {}

    fn reposition_request(
        &mut self,
        _surface: PopupSurface,
        _positioner: PositionerState,
        _token: u32,
    ) {
    }

    fn grab(&mut self, _surface: PopupSurface, _seat: wl_seat::WlSeat, _serial: Serial) {}

    fn app_id_changed(&mut self, surface: ToplevelSurface) {
        self.refresh_toplevel_app_id(surface.wl_surface());
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        let wl_surface = surface.wl_surface().clone();
        if let Some(window) = self.window_for_surface(&wl_surface) {
            self.space.unmap_elem(&window);
        }
        if let Some(app_id) = self.forget_surface(&wl_surface) {
            self.shelved_windows.remove(&app_id);
        }
        self.focus_top_window();
        if self.shell_enabled {
            self.publish_visible_shell_frame("shell-toplevel-destroyed-frame");
        }
    }
}

delegate_xdg_shell!(ShadowGuestCompositor);

impl ShadowGuestCompositor {
    pub(super) fn configure_toplevel(&self, surface: &ToplevelSurface) {
        let size = self.app_window_size();
        surface.with_pending_state(|state| {
            state.size = Some(size);
            state.bounds = Some(size);
        });
        tracing::info!(
            "[shadow-guest-compositor] configure-toplevel size={}x{}",
            size.w,
            size.h
        );
    }

    fn refresh_toplevel_app_id(&mut self, surface: &WlSurface) {
        let app_id = with_states(surface, |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .and_then(|data| data.lock().ok().and_then(|attrs| attrs.app_id.clone()))
        });
        let Some(app_id) = app_id.as_deref().and_then(app::app_id_from_wayland_app_id) else {
            return;
        };

        self.remember_surface_app(surface, app_id);
    }
}
