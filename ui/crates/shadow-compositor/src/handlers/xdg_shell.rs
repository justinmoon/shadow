#![cfg(target_os = "linux")]

use shadow_ui_core::app;
use smithay::{
    delegate_xdg_shell,
    desktop::{find_popup_root_surface, get_popup_toplevel_coords, PopupKind, Window},
    reexports::{
        wayland_protocols::xdg::shell::server::xdg_toplevel,
        wayland_server::protocol::{wl_seat, wl_surface::WlSurface},
    },
    utils::Serial,
    wayland::{
        compositor::with_states,
        shell::xdg::{
            PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
            XdgToplevelSurfaceData,
        },
    },
};

use crate::state::ShadowCompositor;

impl XdgShellHandler for ShadowCompositor {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell_state
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let wl_surface = surface.wl_surface().clone();
        let window = Window::new_wayland_window(surface);
        let raw_app_id = with_states(&wl_surface, |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .and_then(|data| data.lock().ok().and_then(|attrs| attrs.app_id.clone()))
        });
        tracing::info!(
            raw_app_id = raw_app_id.as_deref(),
            "shadow-compositor: new toplevel"
        );
        self.space.map_element(
            window.clone(),
            self.window_location_for_surface(&wl_surface),
            false,
        );
        self.refresh_toplevel_app_id(&wl_surface);
        self.focus_window(Some(window), self.next_serial());
    }

    fn new_popup(&mut self, surface: PopupSurface, _positioner: PositionerState) {
        self.unconstrain_popup(&surface);
        let _ = self.popups.track_popup(PopupKind::Xdg(surface));
    }

    fn reposition_request(
        &mut self,
        surface: PopupSurface,
        positioner: PositionerState,
        token: u32,
    ) {
        surface.with_pending_state(|state| {
            state.geometry = positioner.get_geometry();
            state.positioner = positioner;
        });
        self.unconstrain_popup(&surface);
        surface.send_repositioned(token);
    }

    fn grab(&mut self, _surface: PopupSurface, _seat: wl_seat::WlSeat, _serial: Serial) {}

    fn app_id_changed(&mut self, surface: ToplevelSurface) {
        tracing::info!("shadow-compositor: app id changed");
        self.refresh_toplevel_app_id(surface.wl_surface());
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        let wl_surface = surface.wl_surface().clone();
        if let Some(window) = self.window_for_surface(&wl_surface) {
            self.space.unmap_elem(&window);
        }
        if let Some(app_id) = self.forget_surface(&wl_surface) {
            self.shelved_windows.remove(&app_id);
            self.shell.set_app_running(app_id, false);
            if self.shell.foreground_app() == Some(app_id) {
                self.shell.set_foreground_app(None);
            }
        }
        self.focus_top_window(self.next_serial());
    }
}

delegate_xdg_shell!(ShadowCompositor);

pub fn handle_commit(state: &mut ShadowCompositor, surface: &WlSurface) {
    if let Some(window) = state
        .space
        .elements()
        .find(|window| window.toplevel().unwrap().wl_surface() == surface)
        .cloned()
    {
        let initial_configure_sent = with_states(surface, |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .unwrap()
                .lock()
                .unwrap()
                .initial_configure_sent
        });

        if !initial_configure_sent {
            let geometry = state.app_window_geometry();
            let toplevel = window.toplevel().unwrap();
            toplevel.with_pending_state(|state| {
                state.bounds = Some(geometry.size);
                state.size = Some(geometry.size);
                state.states.set(xdg_toplevel::State::Maximized);
            });
            toplevel.send_configure();
        }
    }

    state.popups.commit(surface);
    if let Some(popup) = state.popups.find_popup(surface) {
        match popup {
            PopupKind::Xdg(surface) => {
                if !surface.is_initial_configure_sent() {
                    surface.send_configure().expect("initial popup configure");
                }
            }
            PopupKind::InputMethod(_) => {}
        }
    }
}

impl ShadowCompositor {
    fn refresh_toplevel_app_id(&mut self, surface: &WlSurface) {
        let app_id = with_states(surface, |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .and_then(|data| data.lock().ok().and_then(|attrs| attrs.app_id.clone()))
        });
        let Some(app_id) = app_id.as_deref() else {
            tracing::info!("shadow-compositor: toplevel still has no app id");
            return;
        };
        tracing::info!(app_id, "shadow-compositor: refreshing toplevel app id");

        if app_id == app::DESKTOP_WAYLAND_APP_ID {
            if let Some(window) = self.window_for_surface(surface) {
                self.space.unmap_elem(&window);
                self.space
                    .map_element(window, self.home_window_location(), false);
            }
            return;
        }

        let Some(app_id) = app::app_id_from_wayland_app_id(app_id) else {
            return;
        };

        if let Some(current_app_id) = self.shell.foreground_app() {
            if current_app_id != app_id {
                if let Some(current_window) = self.mapped_window_for_app(current_app_id) {
                    self.space.unmap_elem(&current_window);
                    self.shelved_windows.insert(current_app_id, current_window);
                }
            }
        }

        self.remember_surface_app(surface, app_id);
        self.shell.set_foreground_app(Some(app_id));
        if let Some(window) = self.window_for_surface(surface) {
            let geometry = self.app_window_geometry();
            let toplevel = window.toplevel().unwrap();
            toplevel.with_pending_state(|state| {
                state.bounds = Some(geometry.size);
                state.size = Some(geometry.size);
                state.states.set(xdg_toplevel::State::Maximized);
            });
            toplevel.send_pending_configure();
        }
    }

    fn window_location_for_surface(&self, surface: &WlSurface) -> (i32, i32) {
        let app_id = with_states(surface, |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .and_then(|data| data.lock().ok().and_then(|attrs| attrs.app_id.clone()))
        });

        if app_id.as_deref() == Some(app::DESKTOP_WAYLAND_APP_ID) {
            self.home_window_location()
        } else {
            self.app_window_location()
        }
    }

    pub(crate) fn home_window_location(&self) -> (i32, i32) {
        (0, 0)
    }

    fn unconstrain_popup(&self, popup: &PopupSurface) {
        let Ok(root) = find_popup_root_surface(&PopupKind::Xdg(popup.clone())) else {
            return;
        };
        let Some(window) = self
            .space
            .elements()
            .find(|candidate| candidate.toplevel().unwrap().wl_surface() == &root)
        else {
            return;
        };

        let Some(output) = self.space.outputs().next() else {
            return;
        };
        let Some(output_geometry) = self.space.output_geometry(output) else {
            return;
        };
        let Some(window_geometry) = self.space.element_geometry(window) else {
            return;
        };

        let mut target = output_geometry;
        target.loc -= get_popup_toplevel_coords(&PopupKind::Xdg(popup.clone()));
        target.loc -= window_geometry.loc;

        popup.with_pending_state(|state| {
            state.geometry = state.positioner.get_unconstrained_geometry(target);
        });
    }
}
