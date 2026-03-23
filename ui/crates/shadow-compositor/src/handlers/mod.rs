mod compositor;
mod xdg_shell;

use smithay::{
    delegate_data_device, delegate_output, delegate_seat,
    input::{Seat, SeatHandler, SeatState},
    reexports::wayland_server::{protocol::wl_surface::WlSurface, Resource},
    wayland::{
        output::OutputHandler,
        selection::{
            data_device::{
                set_data_device_focus, ClientDndGrabHandler, DataDeviceHandler, DataDeviceState,
                ServerDndGrabHandler,
            },
            SelectionHandler,
        },
    },
};

use crate::state::ShadowCompositor;

impl SeatHandler for ShadowCompositor {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<ShadowCompositor> {
        &mut self.seat_state
    }

    fn cursor_image(
        &mut self,
        _seat: &Seat<Self>,
        _image: smithay::input::pointer::CursorImageStatus,
    ) {
    }

    fn focus_changed(&mut self, seat: &Seat<Self>, focused: Option<&WlSurface>) {
        let client = focused.and_then(|surface| self.display_handle.get_client(surface.id()).ok());
        set_data_device_focus(&self.display_handle, seat, client);
    }
}

delegate_seat!(ShadowCompositor);

impl SelectionHandler for ShadowCompositor {
    type SelectionUserData = ();
}

impl DataDeviceHandler for ShadowCompositor {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device_state
    }
}

impl ClientDndGrabHandler for ShadowCompositor {}
impl ServerDndGrabHandler for ShadowCompositor {}

delegate_data_device!(ShadowCompositor);

impl OutputHandler for ShadowCompositor {}
delegate_output!(ShadowCompositor);
