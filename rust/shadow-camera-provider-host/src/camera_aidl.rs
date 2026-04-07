use binder::binder_impl::{
    BorrowedParcel, IBinderInternal, Parcel, Serialize, TransactionCode, FIRST_CALL_TRANSACTION,
};
use binder::declare_binder_enum;
use binder::declare_binder_interface;
use binder::{BinderFeatures, Interface, Status, StatusCode, Strong};

fn read_aidl_reply<T: binder::binder_impl::Deserialize>(
    reply_result: std::result::Result<Parcel, StatusCode>,
) -> binder::Result<T> {
    let reply = reply_result?;
    let status: Status = reply.read()?;
    if !status.is_ok() {
        return Err(status);
    }
    Ok(reply.read()?)
}

fn read_aidl_status(reply_result: std::result::Result<Parcel, StatusCode>) -> binder::Result<()> {
    let reply = reply_result?;
    let status: Status = reply.read()?;
    if !status.is_ok() {
        return Err(status);
    }
    Ok(())
}

fn write_aidl_value<T: Serialize>(
    reply: &mut BorrowedParcel<'_>,
    result: binder::Result<T>,
) -> std::result::Result<(), StatusCode> {
    match result {
        Ok(value) => {
            reply.write(&Status::ok())?;
            reply.write(&value)?;
        }
        Err(status) => reply.write(&status)?,
    }
    Ok(())
}

fn write_aidl_status(
    reply: &mut BorrowedParcel<'_>,
    result: binder::Result<()>,
) -> std::result::Result<(), StatusCode> {
    match result {
        Ok(()) => reply.write(&Status::ok())?,
        Err(status) => reply.write(&status)?,
    }
    Ok(())
}

pub mod common {
    use super::*;

    declare_binder_enum! {
        #[repr(C, align(4))]
        CameraDeviceStatus : [i32; 3] {
            NOT_PRESENT = 0,
            PRESENT = 1,
            ENUMERATING = 2,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(4))]
        TorchModeStatus : [i32; 3] {
            NOT_AVAILABLE = 0,
            AVAILABLE_OFF = 1,
            AVAILABLE_ON = 2,
        }
    }

    #[derive(Debug, Clone, Default)]
    pub struct CameraResourceCost {
        pub resource_cost: i32,
        pub conflicting_devices: Vec<String>,
    }

    impl binder::Parcelable for CameraResourceCost {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.resource_cost)?;
                subparcel.write(&self.conflicting_devices)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.resource_cost = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.conflicting_devices = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(CameraResourceCost);
    binder::impl_deserialize_for_parcelable!(CameraResourceCost);
}

pub mod device {
    use super::common::CameraResourceCost;
    use super::*;

    declare_binder_enum! {
        #[repr(C, align(4))]
        RequestTemplate : [i32; 7] {
            PREVIEW = 1,
            STILL_CAPTURE = 2,
            VIDEO_RECORD = 3,
            VIDEO_SNAPSHOT = 4,
            ZERO_SHUTTER_LAG = 5,
            MANUAL = 6,
            VENDOR_TEMPLATE_START = 0x4000_0000,
        }
    }

    #[derive(Debug, Clone, Default)]
    pub struct CameraMetadata {
        pub metadata: Vec<u8>,
    }

    impl binder::Parcelable for CameraMetadata {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.metadata)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.metadata = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(CameraMetadata);
    binder::impl_deserialize_for_parcelable!(CameraMetadata);

    declare_binder_interface! {
        ICameraDeviceCallback["android.hardware.camera.device.ICameraDeviceCallback"] {
            native: BnCameraDeviceCallback(on_transact_callback),
            proxy: BpCameraDeviceCallback,
        }
    }

    pub trait ICameraDeviceCallback: binder::Interface + Send {
        fn notify(&self) -> binder::Result<()>;
        fn process_capture_result(&self) -> binder::Result<()>;
        fn request_stream_buffers(&self) -> binder::Result<()>;
        fn return_stream_buffers(&self) -> binder::Result<()>;
    }

    mod callback_transactions {
        use super::*;

        pub const NOTIFY: TransactionCode = FIRST_CALL_TRANSACTION + 0;
        pub const PROCESS_CAPTURE_RESULT: TransactionCode = FIRST_CALL_TRANSACTION + 1;
        pub const REQUEST_STREAM_BUFFERS: TransactionCode = FIRST_CALL_TRANSACTION + 2;
        pub const RETURN_STREAM_BUFFERS: TransactionCode = FIRST_CALL_TRANSACTION + 3;
    }

    impl ICameraDeviceCallback for BpCameraDeviceCallback {
        fn notify(&self) -> binder::Result<()> {
            let data = self.binder.prepare_transact()?;
            let reply = self
                .binder
                .submit_transact(callback_transactions::NOTIFY, data, 0);
            super::read_aidl_status(reply)
        }

        fn process_capture_result(&self) -> binder::Result<()> {
            let data = self.binder.prepare_transact()?;
            let reply = self.binder.submit_transact(
                callback_transactions::PROCESS_CAPTURE_RESULT,
                data,
                0,
            );
            super::read_aidl_status(reply)
        }

        fn request_stream_buffers(&self) -> binder::Result<()> {
            let data = self.binder.prepare_transact()?;
            let reply = self.binder.submit_transact(
                callback_transactions::REQUEST_STREAM_BUFFERS,
                data,
                0,
            );
            super::read_aidl_status(reply)
        }

        fn return_stream_buffers(&self) -> binder::Result<()> {
            let data = self.binder.prepare_transact()?;
            let reply = self.binder.submit_transact(
                callback_transactions::RETURN_STREAM_BUFFERS,
                data,
                0,
            );
            super::read_aidl_status(reply)
        }
    }

    impl ICameraDeviceCallback for binder::binder_impl::Binder<BnCameraDeviceCallback> {
        fn notify(&self) -> binder::Result<()> {
            self.0.notify()
        }

        fn process_capture_result(&self) -> binder::Result<()> {
            self.0.process_capture_result()
        }

        fn request_stream_buffers(&self) -> binder::Result<()> {
            self.0.request_stream_buffers()
        }

        fn return_stream_buffers(&self) -> binder::Result<()> {
            self.0.return_stream_buffers()
        }
    }

    fn on_transact_callback(
        service: &dyn ICameraDeviceCallback,
        code: TransactionCode,
        _data: &BorrowedParcel<'_>,
        reply: &mut BorrowedParcel<'_>,
    ) -> std::result::Result<(), StatusCode> {
        match code {
            callback_transactions::NOTIFY => super::write_aidl_status(reply, service.notify()),
            callback_transactions::PROCESS_CAPTURE_RESULT => {
                super::write_aidl_status(reply, service.process_capture_result())
            }
            callback_transactions::REQUEST_STREAM_BUFFERS => {
                super::write_aidl_status(reply, service.request_stream_buffers())
            }
            callback_transactions::RETURN_STREAM_BUFFERS => {
                super::write_aidl_status(reply, service.return_stream_buffers())
            }
            _ => Err(StatusCode::UNKNOWN_TRANSACTION),
        }
    }

    declare_binder_interface! {
        ICameraDeviceSession["android.hardware.camera.device.ICameraDeviceSession"] {
            native: BnCameraDeviceSession(on_transact_session),
            proxy: BpCameraDeviceSession,
        }
    }

    pub trait ICameraDeviceSession: binder::Interface + Send {
        fn close(&self) -> binder::Result<()>;
        fn construct_default_request_settings(
            &self,
            template: RequestTemplate,
        ) -> binder::Result<CameraMetadata>;
    }

    mod session_transactions {
        use super::*;

        pub const CLOSE: TransactionCode = FIRST_CALL_TRANSACTION + 0;
        pub const CONSTRUCT_DEFAULT_REQUEST_SETTINGS: TransactionCode =
            FIRST_CALL_TRANSACTION + 2;
    }

    impl ICameraDeviceSession for BpCameraDeviceSession {
        fn close(&self) -> binder::Result<()> {
            let data = self.binder.prepare_transact()?;
            let reply = self
                .binder
                .submit_transact(session_transactions::CLOSE, data, 0);
            super::read_aidl_status(reply)
        }

        fn construct_default_request_settings(
            &self,
            template: RequestTemplate,
        ) -> binder::Result<CameraMetadata> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&template)?;
            let reply = self.binder.submit_transact(
                session_transactions::CONSTRUCT_DEFAULT_REQUEST_SETTINGS,
                data,
                0,
            );
            super::read_aidl_reply(reply)
        }
    }

    impl ICameraDeviceSession for binder::binder_impl::Binder<BnCameraDeviceSession> {
        fn close(&self) -> binder::Result<()> {
            self.0.close()
        }

        fn construct_default_request_settings(
            &self,
            template: RequestTemplate,
        ) -> binder::Result<CameraMetadata> {
            self.0.construct_default_request_settings(template)
        }
    }

    fn on_transact_session(
        service: &dyn ICameraDeviceSession,
        code: TransactionCode,
        data: &BorrowedParcel<'_>,
        reply: &mut BorrowedParcel<'_>,
    ) -> std::result::Result<(), StatusCode> {
        match code {
            session_transactions::CLOSE => super::write_aidl_status(reply, service.close()),
            session_transactions::CONSTRUCT_DEFAULT_REQUEST_SETTINGS => {
                let template: RequestTemplate = data.read()?;
                super::write_aidl_value(
                    reply,
                    service.construct_default_request_settings(template),
                )
            }
            _ => Err(StatusCode::UNKNOWN_TRANSACTION),
        }
    }

    declare_binder_interface! {
        ICameraDevice["android.hardware.camera.device.ICameraDevice"] {
            native: BnCameraDevice(on_transact),
            proxy: BpCameraDevice,
        }
    }

    pub trait ICameraDevice: binder::Interface + Send {
        fn get_camera_characteristics(&self) -> binder::Result<CameraMetadata>;
        fn get_resource_cost(&self) -> binder::Result<CameraResourceCost>;
        fn open(
            &self,
            callback: &Strong<dyn ICameraDeviceCallback>,
        ) -> binder::Result<Strong<dyn ICameraDeviceSession>>;
        fn construct_default_request_settings(
            &self,
            template: RequestTemplate,
        ) -> binder::Result<CameraMetadata>;
    }

    mod transactions {
        use super::*;

        pub const GET_CAMERA_CHARACTERISTICS: TransactionCode = FIRST_CALL_TRANSACTION + 0;
        pub const GET_RESOURCE_COST: TransactionCode = FIRST_CALL_TRANSACTION + 2;
        pub const OPEN: TransactionCode = FIRST_CALL_TRANSACTION + 4;
        pub const CONSTRUCT_DEFAULT_REQUEST_SETTINGS: TransactionCode =
            FIRST_CALL_TRANSACTION + 9;
    }

    impl ICameraDevice for BpCameraDevice {
        fn get_camera_characteristics(&self) -> binder::Result<CameraMetadata> {
            let data = self.binder.prepare_transact()?;
            let reply =
                self.binder
                    .submit_transact(transactions::GET_CAMERA_CHARACTERISTICS, data, 0);
            super::read_aidl_reply(reply)
        }

        fn get_resource_cost(&self) -> binder::Result<CameraResourceCost> {
            let data = self.binder.prepare_transact()?;
            let reply = self
                .binder
                .submit_transact(transactions::GET_RESOURCE_COST, data, 0);
            super::read_aidl_reply(reply)
        }

        fn open(
            &self,
            callback: &Strong<dyn ICameraDeviceCallback>,
        ) -> binder::Result<Strong<dyn ICameraDeviceSession>> {
            let mut data = self.binder.prepare_transact()?;
            data.write(callback)?;
            let reply = self.binder.submit_transact(transactions::OPEN, data, 0);
            super::read_aidl_reply(reply)
        }

        fn construct_default_request_settings(
            &self,
            template: RequestTemplate,
        ) -> binder::Result<CameraMetadata> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&template)?;
            let reply = self.binder.submit_transact(
                transactions::CONSTRUCT_DEFAULT_REQUEST_SETTINGS,
                data,
                0,
            );
            super::read_aidl_reply(reply)
        }
    }

    impl ICameraDevice for binder::binder_impl::Binder<BnCameraDevice> {
        fn get_camera_characteristics(&self) -> binder::Result<CameraMetadata> {
            self.0.get_camera_characteristics()
        }

        fn get_resource_cost(&self) -> binder::Result<CameraResourceCost> {
            self.0.get_resource_cost()
        }

        fn open(
            &self,
            callback: &Strong<dyn ICameraDeviceCallback>,
        ) -> binder::Result<Strong<dyn ICameraDeviceSession>> {
            self.0.open(callback)
        }

        fn construct_default_request_settings(
            &self,
            template: RequestTemplate,
        ) -> binder::Result<CameraMetadata> {
            self.0.construct_default_request_settings(template)
        }
    }

    fn on_transact(
        service: &dyn ICameraDevice,
        code: TransactionCode,
        data: &BorrowedParcel<'_>,
        reply: &mut BorrowedParcel<'_>,
    ) -> std::result::Result<(), StatusCode> {
        match code {
            transactions::GET_CAMERA_CHARACTERISTICS => {
                super::write_aidl_value(reply, service.get_camera_characteristics())
            }
            transactions::GET_RESOURCE_COST => {
                super::write_aidl_value(reply, service.get_resource_cost())
            }
            transactions::OPEN => {
                let callback: Strong<dyn ICameraDeviceCallback> = data.read()?;
                super::write_aidl_value(reply, service.open(&callback))
            }
            transactions::CONSTRUCT_DEFAULT_REQUEST_SETTINGS => {
                let template: RequestTemplate = data.read()?;
                super::write_aidl_value(reply, service.construct_default_request_settings(template))
            }
            _ => Err(StatusCode::UNKNOWN_TRANSACTION),
        }
    }

    pub fn new_callback<T>(inner: T) -> Strong<dyn ICameraDeviceCallback>
    where
        T: ICameraDeviceCallback + Interface + Send + Sync + 'static,
    {
        BnCameraDeviceCallback::new_binder(inner, BinderFeatures::default())
    }
}

pub mod provider {
    use super::common::{CameraDeviceStatus, TorchModeStatus};
    use super::device::ICameraDevice;
    use super::*;

    declare_binder_interface! {
        ICameraProviderCallback["android.hardware.camera.provider.ICameraProviderCallback"] {
            native: BnCameraProviderCallback(on_transact_callback),
            proxy: BpCameraProviderCallback,
        }
    }

    pub trait ICameraProviderCallback: binder::Interface + Send {
        fn camera_device_status_change(
            &self,
            camera_device_name: &str,
            new_status: CameraDeviceStatus,
        ) -> binder::Result<()>;
        fn torch_mode_status_change(
            &self,
            camera_device_name: &str,
            new_status: TorchModeStatus,
        ) -> binder::Result<()>;
        fn physical_camera_device_status_change(
            &self,
            camera_device_name: &str,
            physical_camera_device_name: &str,
            new_status: CameraDeviceStatus,
        ) -> binder::Result<()>;
    }

    mod callback_transactions {
        use super::*;

        pub const CAMERA_DEVICE_STATUS_CHANGE: TransactionCode = FIRST_CALL_TRANSACTION + 0;
        pub const TORCH_MODE_STATUS_CHANGE: TransactionCode = FIRST_CALL_TRANSACTION + 1;
        pub const PHYSICAL_CAMERA_DEVICE_STATUS_CHANGE: TransactionCode =
            FIRST_CALL_TRANSACTION + 2;
    }

    impl ICameraProviderCallback for BpCameraProviderCallback {
        fn camera_device_status_change(
            &self,
            camera_device_name: &str,
            new_status: CameraDeviceStatus,
        ) -> binder::Result<()> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&camera_device_name.to_owned())?;
            data.write(&new_status)?;
            let reply = self.binder.submit_transact(
                callback_transactions::CAMERA_DEVICE_STATUS_CHANGE,
                data,
                0,
            );
            super::read_aidl_status(reply)
        }

        fn torch_mode_status_change(
            &self,
            camera_device_name: &str,
            new_status: TorchModeStatus,
        ) -> binder::Result<()> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&camera_device_name.to_owned())?;
            data.write(&new_status)?;
            let reply = self.binder.submit_transact(
                callback_transactions::TORCH_MODE_STATUS_CHANGE,
                data,
                0,
            );
            super::read_aidl_status(reply)
        }

        fn physical_camera_device_status_change(
            &self,
            camera_device_name: &str,
            physical_camera_device_name: &str,
            new_status: CameraDeviceStatus,
        ) -> binder::Result<()> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&camera_device_name.to_owned())?;
            data.write(&physical_camera_device_name.to_owned())?;
            data.write(&new_status)?;
            let reply = self.binder.submit_transact(
                callback_transactions::PHYSICAL_CAMERA_DEVICE_STATUS_CHANGE,
                data,
                0,
            );
            super::read_aidl_status(reply)
        }
    }

    impl ICameraProviderCallback for binder::binder_impl::Binder<BnCameraProviderCallback> {
        fn camera_device_status_change(
            &self,
            camera_device_name: &str,
            new_status: CameraDeviceStatus,
        ) -> binder::Result<()> {
            self.0
                .camera_device_status_change(camera_device_name, new_status)
        }

        fn torch_mode_status_change(
            &self,
            camera_device_name: &str,
            new_status: TorchModeStatus,
        ) -> binder::Result<()> {
            self.0
                .torch_mode_status_change(camera_device_name, new_status)
        }

        fn physical_camera_device_status_change(
            &self,
            camera_device_name: &str,
            physical_camera_device_name: &str,
            new_status: CameraDeviceStatus,
        ) -> binder::Result<()> {
            self.0.physical_camera_device_status_change(
                camera_device_name,
                physical_camera_device_name,
                new_status,
            )
        }
    }

    fn on_transact_callback(
        service: &dyn ICameraProviderCallback,
        code: TransactionCode,
        data: &BorrowedParcel<'_>,
        reply: &mut BorrowedParcel<'_>,
    ) -> std::result::Result<(), StatusCode> {
        match code {
            callback_transactions::CAMERA_DEVICE_STATUS_CHANGE => {
                let camera_device_name: String = data.read()?;
                let new_status: CameraDeviceStatus = data.read()?;
                super::write_aidl_status(
                    reply,
                    service.camera_device_status_change(&camera_device_name, new_status),
                )
            }
            callback_transactions::TORCH_MODE_STATUS_CHANGE => {
                let camera_device_name: String = data.read()?;
                let new_status: TorchModeStatus = data.read()?;
                super::write_aidl_status(
                    reply,
                    service.torch_mode_status_change(&camera_device_name, new_status),
                )
            }
            callback_transactions::PHYSICAL_CAMERA_DEVICE_STATUS_CHANGE => {
                let camera_device_name: String = data.read()?;
                let physical_camera_device_name: String = data.read()?;
                let new_status: CameraDeviceStatus = data.read()?;
                super::write_aidl_status(
                    reply,
                    service.physical_camera_device_status_change(
                        &camera_device_name,
                        &physical_camera_device_name,
                        new_status,
                    ),
                )
            }
            _ => Err(StatusCode::UNKNOWN_TRANSACTION),
        }
    }

    declare_binder_interface! {
        ICameraProvider["android.hardware.camera.provider.ICameraProvider"] {
            native: BnCameraProvider(on_transact_provider),
            proxy: BpCameraProvider,
        }
    }

    pub trait ICameraProvider: binder::Interface + Send {
        fn set_callback(
            &self,
            callback: &Strong<dyn ICameraProviderCallback>,
        ) -> binder::Result<()>;
        fn get_camera_id_list(&self) -> binder::Result<Vec<String>>;
        fn get_camera_device_interface(
            &self,
            camera_device_name: &str,
        ) -> binder::Result<Strong<dyn ICameraDevice>>;
        fn notify_device_state_change(&self, device_state: i64) -> binder::Result<()>;
    }

    mod provider_transactions {
        use super::*;

        pub const SET_CALLBACK: TransactionCode = FIRST_CALL_TRANSACTION + 0;
        pub const GET_CAMERA_ID_LIST: TransactionCode = FIRST_CALL_TRANSACTION + 2;
        pub const GET_CAMERA_DEVICE_INTERFACE: TransactionCode = FIRST_CALL_TRANSACTION + 3;
        pub const NOTIFY_DEVICE_STATE_CHANGE: TransactionCode = FIRST_CALL_TRANSACTION + 4;
    }

    impl ICameraProvider for BpCameraProvider {
        fn set_callback(
            &self,
            callback: &Strong<dyn ICameraProviderCallback>,
        ) -> binder::Result<()> {
            let mut data = self.binder.prepare_transact()?;
            data.write(callback)?;
            let reply = self
                .binder
                .submit_transact(provider_transactions::SET_CALLBACK, data, 0);
            super::read_aidl_status(reply)
        }

        fn get_camera_id_list(&self) -> binder::Result<Vec<String>> {
            let data = self.binder.prepare_transact()?;
            let reply =
                self.binder
                    .submit_transact(provider_transactions::GET_CAMERA_ID_LIST, data, 0);
            super::read_aidl_reply(reply)
        }

        fn get_camera_device_interface(
            &self,
            camera_device_name: &str,
        ) -> binder::Result<Strong<dyn ICameraDevice>> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&camera_device_name.to_owned())?;
            let reply = self.binder.submit_transact(
                provider_transactions::GET_CAMERA_DEVICE_INTERFACE,
                data,
                0,
            );
            super::read_aidl_reply(reply)
        }

        fn notify_device_state_change(&self, device_state: i64) -> binder::Result<()> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&device_state)?;
            let reply = self.binder.submit_transact(
                provider_transactions::NOTIFY_DEVICE_STATE_CHANGE,
                data,
                0,
            );
            super::read_aidl_status(reply)
        }
    }

    impl ICameraProvider for binder::binder_impl::Binder<BnCameraProvider> {
        fn set_callback(
            &self,
            callback: &Strong<dyn ICameraProviderCallback>,
        ) -> binder::Result<()> {
            self.0.set_callback(callback)
        }

        fn get_camera_id_list(&self) -> binder::Result<Vec<String>> {
            self.0.get_camera_id_list()
        }

        fn get_camera_device_interface(
            &self,
            camera_device_name: &str,
        ) -> binder::Result<Strong<dyn ICameraDevice>> {
            self.0.get_camera_device_interface(camera_device_name)
        }

        fn notify_device_state_change(&self, device_state: i64) -> binder::Result<()> {
            self.0.notify_device_state_change(device_state)
        }
    }

    fn on_transact_provider(
        service: &dyn ICameraProvider,
        code: TransactionCode,
        data: &BorrowedParcel<'_>,
        reply: &mut BorrowedParcel<'_>,
    ) -> std::result::Result<(), StatusCode> {
        match code {
            provider_transactions::SET_CALLBACK => {
                let callback: Strong<dyn ICameraProviderCallback> = data.read()?;
                super::write_aidl_status(reply, service.set_callback(&callback))
            }
            provider_transactions::GET_CAMERA_ID_LIST => {
                super::write_aidl_value(reply, service.get_camera_id_list())
            }
            provider_transactions::GET_CAMERA_DEVICE_INTERFACE => {
                let camera_device_name: String = data.read()?;
                super::write_aidl_value(
                    reply,
                    service.get_camera_device_interface(&camera_device_name),
                )
            }
            provider_transactions::NOTIFY_DEVICE_STATE_CHANGE => {
                let device_state: i64 = data.read()?;
                super::write_aidl_status(reply, service.notify_device_state_change(device_state))
            }
            _ => Err(StatusCode::UNKNOWN_TRANSACTION),
        }
    }

    pub const DEVICE_STATE_NORMAL: i64 = 0;

    pub fn new_callback<T>(inner: T) -> Strong<dyn ICameraProviderCallback>
    where
        T: ICameraProviderCallback + Interface + Send + Sync + 'static,
    {
        BnCameraProviderCallback::new_binder(inner, BinderFeatures::default())
    }
}
