mod compositor;
mod dmabuf;
mod xdg_shell;

use smithay::{
    delegate_presentation, delegate_seat,
    input::{Seat, SeatHandler, SeatState},
    reexports::{
        calloop::LoopSignal,
        wayland_server::{
            backend::{ClientData, ClientId, DisconnectReason},
            protocol::wl_surface::WlSurface,
        },
    },
    wayland::compositor::CompositorClientState,
};

use super::ShadowGuestCompositor;

pub(super) struct ClientState {
    compositor_state: CompositorClientState,
    disconnect_signal: Option<LoopSignal>,
}

impl ClientState {
    pub(super) fn new(disconnect_signal: Option<LoopSignal>) -> Self {
        Self {
            compositor_state: CompositorClientState::default(),
            disconnect_signal,
        }
    }
}

impl ClientData for ClientState {
    fn initialized(&self, _client_id: ClientId) {}

    fn disconnected(&self, _client_id: ClientId, reason: DisconnectReason) {
        if let Some(loop_signal) = &self.disconnect_signal {
            tracing::info!("[shadow-guest-compositor] client-disconnected reason={reason:?}");
            loop_signal.stop();
        }
    }
}

impl SeatHandler for ShadowGuestCompositor {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }

    fn cursor_image(
        &mut self,
        _seat: &Seat<Self>,
        _image: smithay::input::pointer::CursorImageStatus,
    ) {
    }
}

delegate_presentation!(ShadowGuestCompositor);
delegate_seat!(ShadowGuestCompositor);
