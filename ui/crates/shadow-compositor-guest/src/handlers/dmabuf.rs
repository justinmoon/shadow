use smithay::{
    backend::allocator::{dmabuf::Dmabuf, Buffer as AllocatorBuffer},
    delegate_dmabuf,
    wayland::dmabuf::{DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier},
};

use super::ShadowGuestCompositor;

impl DmabufHandler for ShadowGuestCompositor {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self.dmabuf_state
    }

    fn dmabuf_imported(
        &mut self,
        _global: &DmabufGlobal,
        dmabuf: Dmabuf,
        notifier: ImportNotifier,
    ) {
        let size = dmabuf.size();
        let format = dmabuf.format();
        tracing::info!(
            "[shadow-guest-compositor] dmabuf-imported size={}x{} fourcc={:?} modifier={:?} planes={} y_inverted={}",
            size.w,
            size.h,
            format.code,
            format.modifier,
            dmabuf.num_planes(),
            dmabuf.y_inverted()
        );
        let _ = notifier.successful::<Self>();
    }
}

delegate_dmabuf!(ShadowGuestCompositor);
