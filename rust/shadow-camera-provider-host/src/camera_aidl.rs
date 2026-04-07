use binder::binder_impl::{
    BorrowedParcel, IBinderInternal, Parcel, Serialize, TransactionCode, FIRST_CALL_TRANSACTION,
};
use binder::declare_binder_enum;
use binder::declare_binder_interface;
use binder::{BinderFeatures, Interface, ParcelFileDescriptor, Status, StatusCode, Strong};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

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

    #[derive(Debug, Default)]
    pub struct NativeHandle {
        pub fds: Vec<ParcelFileDescriptor>,
        pub ints: Vec<i32>,
    }

    impl NativeHandle {
        pub fn empty() -> Self {
            Self::default()
        }

        pub fn is_empty(&self) -> bool {
            self.fds.is_empty() && self.ints.is_empty()
        }

        pub fn dup_first_owned_fd(&self) -> io::Result<Option<OwnedFd>> {
            let Some(parcel_fd) = self.fds.first() else {
                return Ok(None);
            };

            let duplicated = unsafe { libc::fcntl(parcel_fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
            if duplicated < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(Some(unsafe { OwnedFd::from_raw_fd(duplicated) }))
            }
        }
    }

    impl Clone for NativeHandle {
        fn clone(&self) -> Self {
            let fds = self
                .fds
                .iter()
                .map(|parcel_fd| {
                    let duplicated =
                        unsafe { libc::fcntl(parcel_fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
                    assert!(
                        duplicated >= 0,
                        "failed to duplicate native-handle fd: {}",
                        io::Error::last_os_error()
                    );
                    let owned = unsafe { OwnedFd::from_raw_fd(duplicated) };
                    ParcelFileDescriptor::new(owned)
                })
                .collect();
            Self {
                fds,
                ints: self.ints.clone(),
            }
        }
    }

    impl binder::Parcelable for NativeHandle {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.fds)?;
                subparcel.write(&self.ints)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.fds = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.ints = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(NativeHandle);
    binder::impl_deserialize_for_parcelable!(NativeHandle);
}

pub mod graphics {
    use super::*;

    declare_binder_enum! {
        #[repr(C, align(4))]
        PixelFormat : [i32; 2] {
            UNSPECIFIED = 0,
            BLOB = 0x21,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(8))]
        BufferUsage : [i64; 4] {
            CPU_READ_NEVER = 0,
            CPU_READ_RARELY = 2,
            CPU_READ_OFTEN = 3,
            CAMERA_OUTPUT = 131072,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(4))]
        Dataspace : [i32; 2] {
            UNKNOWN = 0x0,
            JFIF = 146931712,
        }
    }
}

pub mod metadata {
    use super::*;

    declare_binder_enum! {
        #[repr(C, align(4))]
        SensorPixelMode : [i32; 2] {
            ANDROID_SENSOR_PIXEL_MODE_DEFAULT = 0,
            ANDROID_SENSOR_PIXEL_MODE_MAXIMUM_RESOLUTION = 1,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(8))]
        RequestAvailableDynamicRangeProfilesMap : [i64; 1] {
            ANDROID_REQUEST_AVAILABLE_DYNAMIC_RANGE_PROFILES_MAP_STANDARD = 0x1,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(8))]
        ScalerAvailableStreamUseCases : [i64; 2] {
            ANDROID_SCALER_AVAILABLE_STREAM_USE_CASES_DEFAULT = 0x0,
            ANDROID_SCALER_AVAILABLE_STREAM_USE_CASES_STILL_CAPTURE = 0x2,
        }
    }
}

pub mod device {
    use super::common::{CameraResourceCost, NativeHandle};
    use super::graphics::{BufferUsage, Dataspace, PixelFormat};
    use super::metadata::{
        RequestAvailableDynamicRangeProfilesMap, ScalerAvailableStreamUseCases, SensorPixelMode,
    };
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

    declare_binder_enum! {
        #[repr(C, align(4))]
        BufferStatus : [i32; 2] {
            OK = 0,
            ERROR = 1,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(4))]
        ErrorCode : [i32; 4] {
            ERROR_DEVICE = 1,
            ERROR_REQUEST = 2,
            ERROR_RESULT = 3,
            ERROR_BUFFER = 4,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(4))]
        StreamType : [i32; 2] {
            OUTPUT = 0,
            INPUT = 1,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(4))]
        StreamRotation : [i32; 4] {
            ROTATION_0 = 0,
            ROTATION_90 = 1,
            ROTATION_180 = 2,
            ROTATION_270 = 3,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(4))]
        StreamConfigurationMode : [i32; 10] {
            NORMAL_MODE = 0,
            CONSTRAINED_HIGH_SPEED_MODE = 1,
            VENDOR_MODE_0 = 32768,
            VENDOR_MODE_1 = 32769,
            VENDOR_MODE_2 = 32770,
            VENDOR_MODE_3 = 32771,
            VENDOR_MODE_4 = 32772,
            VENDOR_MODE_5 = 32773,
            VENDOR_MODE_6 = 32774,
            VENDOR_MODE_7 = 32775,
        }
    }

    #[derive(Debug, Clone)]
    pub struct Stream {
        pub id: i32,
        pub stream_type: StreamType,
        pub width: i32,
        pub height: i32,
        pub format: PixelFormat,
        pub usage: BufferUsage,
        pub data_space: Dataspace,
        pub rotation: StreamRotation,
        pub physical_camera_id: String,
        pub buffer_size: i32,
        pub group_id: i32,
        pub sensor_pixel_modes_used: Vec<SensorPixelMode>,
        pub dynamic_range_profile: RequestAvailableDynamicRangeProfilesMap,
        pub use_case: ScalerAvailableStreamUseCases,
    }

    impl Default for Stream {
        fn default() -> Self {
            Self {
                id: 0,
                stream_type: StreamType::OUTPUT,
                width: 0,
                height: 0,
                format: PixelFormat::UNSPECIFIED,
                usage: BufferUsage::CPU_READ_NEVER,
                data_space: Dataspace::UNKNOWN,
                rotation: StreamRotation::ROTATION_0,
                physical_camera_id: String::new(),
                buffer_size: 0,
                group_id: 0,
                sensor_pixel_modes_used: Vec::new(),
                dynamic_range_profile:
                    RequestAvailableDynamicRangeProfilesMap::
                        ANDROID_REQUEST_AVAILABLE_DYNAMIC_RANGE_PROFILES_MAP_STANDARD,
                use_case:
                    ScalerAvailableStreamUseCases::
                        ANDROID_SCALER_AVAILABLE_STREAM_USE_CASES_DEFAULT,
            }
        }
    }

    impl binder::Parcelable for Stream {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.id)?;
                subparcel.write(&self.stream_type)?;
                subparcel.write(&self.width)?;
                subparcel.write(&self.height)?;
                subparcel.write(&self.format)?;
                subparcel.write(&self.usage)?;
                subparcel.write(&self.data_space)?;
                subparcel.write(&self.rotation)?;
                subparcel.write(&self.physical_camera_id)?;
                subparcel.write(&self.buffer_size)?;
                subparcel.write(&self.group_id)?;
                subparcel.write(&self.sensor_pixel_modes_used)?;
                subparcel.write(&self.dynamic_range_profile)?;
                subparcel.write(&self.use_case)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.stream_type = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.width = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.height = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.format = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.usage = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.data_space = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.rotation = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.physical_camera_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.buffer_size = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.group_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.sensor_pixel_modes_used = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.dynamic_range_profile = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.use_case = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(Stream);
    binder::impl_deserialize_for_parcelable!(Stream);

    #[derive(Debug, Clone, Default)]
    pub struct StreamConfiguration {
        pub streams: Vec<Stream>,
        pub operation_mode: StreamConfigurationMode,
        pub session_params: CameraMetadata,
        pub stream_config_counter: i32,
        pub multi_resolution_input_image: bool,
    }

    impl binder::Parcelable for StreamConfiguration {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.streams)?;
                subparcel.write(&self.operation_mode)?;
                subparcel.write(&self.session_params)?;
                subparcel.write(&self.stream_config_counter)?;
                subparcel.write(&self.multi_resolution_input_image)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.streams = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.operation_mode = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.session_params = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.stream_config_counter = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.multi_resolution_input_image = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(StreamConfiguration);
    binder::impl_deserialize_for_parcelable!(StreamConfiguration);

    #[derive(Debug, Clone)]
    pub struct HalStream {
        pub id: i32,
        pub override_format: PixelFormat,
        pub producer_usage: BufferUsage,
        pub consumer_usage: BufferUsage,
        pub max_buffers: i32,
        pub override_data_space: Dataspace,
        pub physical_camera_id: String,
        pub support_offline: bool,
        pub enable_hal_buffer_manager: bool,
    }

    impl Default for HalStream {
        fn default() -> Self {
            Self {
                id: 0,
                override_format: PixelFormat::UNSPECIFIED,
                producer_usage: BufferUsage::CPU_READ_NEVER,
                consumer_usage: BufferUsage::CPU_READ_NEVER,
                max_buffers: 0,
                override_data_space: Dataspace::UNKNOWN,
                physical_camera_id: String::new(),
                support_offline: false,
                enable_hal_buffer_manager: false,
            }
        }
    }

    impl binder::Parcelable for HalStream {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.id)?;
                subparcel.write(&self.override_format)?;
                subparcel.write(&self.producer_usage)?;
                subparcel.write(&self.consumer_usage)?;
                subparcel.write(&self.max_buffers)?;
                subparcel.write(&self.override_data_space)?;
                subparcel.write(&self.physical_camera_id)?;
                subparcel.write(&self.support_offline)?;
                subparcel.write(&self.enable_hal_buffer_manager)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.override_format = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.producer_usage = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.consumer_usage = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.max_buffers = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.override_data_space = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.physical_camera_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.support_offline = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.enable_hal_buffer_manager = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(HalStream);
    binder::impl_deserialize_for_parcelable!(HalStream);

    #[derive(Clone, Debug)]
    pub struct StreamBuffer {
        pub stream_id: i32,
        pub buffer_id: i64,
        pub buffer: NativeHandle,
        pub status: BufferStatus,
        pub acquire_fence: NativeHandle,
        pub release_fence: NativeHandle,
    }

    impl Default for StreamBuffer {
        fn default() -> Self {
            Self {
                stream_id: -1,
                buffer_id: 0,
                buffer: NativeHandle::empty(),
                status: BufferStatus::OK,
                acquire_fence: NativeHandle::empty(),
                release_fence: NativeHandle::empty(),
            }
        }
    }

    impl binder::Parcelable for StreamBuffer {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.stream_id)?;
                subparcel.write(&self.buffer_id)?;
                subparcel.write(&self.buffer)?;
                subparcel.write(&self.status)?;
                subparcel.write(&self.acquire_fence)?;
                subparcel.write(&self.release_fence)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.stream_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.buffer_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.buffer = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.status = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.acquire_fence = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.release_fence = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(StreamBuffer);
    binder::impl_deserialize_for_parcelable!(StreamBuffer);

    #[derive(Clone, Debug, Default)]
    pub struct PhysicalCameraSetting {
        pub fmq_settings_size: i64,
        pub physical_camera_id: String,
        pub settings: CameraMetadata,
    }

    impl binder::Parcelable for PhysicalCameraSetting {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.fmq_settings_size)?;
                subparcel.write(&self.physical_camera_id)?;
                subparcel.write(&self.settings)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.fmq_settings_size = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.physical_camera_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.settings = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(PhysicalCameraSetting);
    binder::impl_deserialize_for_parcelable!(PhysicalCameraSetting);

    #[derive(Clone, Debug, Default)]
    pub struct PhysicalCameraMetadata {
        pub fmq_metadata_size: i64,
        pub physical_camera_id: String,
        pub metadata: CameraMetadata,
    }

    impl binder::Parcelable for PhysicalCameraMetadata {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.fmq_metadata_size)?;
                subparcel.write(&self.physical_camera_id)?;
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
                    self.fmq_metadata_size = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.physical_camera_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.metadata = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(PhysicalCameraMetadata);
    binder::impl_deserialize_for_parcelable!(PhysicalCameraMetadata);

    #[derive(Clone, Debug, Default)]
    pub struct CaptureRequest {
        pub frame_number: i32,
        pub fmq_settings_size: i64,
        pub settings: CameraMetadata,
        pub input_buffer: StreamBuffer,
        pub input_width: i32,
        pub input_height: i32,
        pub output_buffers: Vec<StreamBuffer>,
        pub physical_camera_settings: Vec<PhysicalCameraSetting>,
    }

    impl binder::Parcelable for CaptureRequest {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.frame_number)?;
                subparcel.write(&self.fmq_settings_size)?;
                subparcel.write(&self.settings)?;
                subparcel.write(&self.input_buffer)?;
                subparcel.write(&self.input_width)?;
                subparcel.write(&self.input_height)?;
                subparcel.write(&self.output_buffers)?;
                subparcel.write(&self.physical_camera_settings)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.frame_number = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.fmq_settings_size = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.settings = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.input_buffer = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.input_width = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.input_height = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.output_buffers = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.physical_camera_settings = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(CaptureRequest);
    binder::impl_deserialize_for_parcelable!(CaptureRequest);

    #[derive(Clone, Debug, Default)]
    pub struct CaptureResult {
        pub frame_number: i32,
        pub fmq_result_size: i64,
        pub result: CameraMetadata,
        pub output_buffers: Vec<StreamBuffer>,
        pub input_buffer: StreamBuffer,
        pub partial_result: i32,
        pub physical_camera_metadata: Vec<PhysicalCameraMetadata>,
    }

    impl binder::Parcelable for CaptureResult {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.frame_number)?;
                subparcel.write(&self.fmq_result_size)?;
                subparcel.write(&self.result)?;
                subparcel.write(&self.output_buffers)?;
                subparcel.write(&self.input_buffer)?;
                subparcel.write(&self.partial_result)?;
                subparcel.write(&self.physical_camera_metadata)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.frame_number = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.fmq_result_size = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.result = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.output_buffers = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.input_buffer = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.partial_result = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.physical_camera_metadata = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(CaptureResult);
    binder::impl_deserialize_for_parcelable!(CaptureResult);

    #[derive(Clone, Debug)]
    pub struct ErrorMsg {
        pub frame_number: i32,
        pub error_stream_id: i32,
        pub error_code: ErrorCode,
    }

    impl Default for ErrorMsg {
        fn default() -> Self {
            Self {
                frame_number: 0,
                error_stream_id: -1,
                error_code: ErrorCode::ERROR_DEVICE,
            }
        }
    }

    impl binder::Parcelable for ErrorMsg {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.frame_number)?;
                subparcel.write(&self.error_stream_id)?;
                subparcel.write(&self.error_code)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.frame_number = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.error_stream_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.error_code = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(ErrorMsg);
    binder::impl_deserialize_for_parcelable!(ErrorMsg);

    #[derive(Clone, Debug, Default)]
    pub struct ShutterMsg {
        pub frame_number: i32,
        pub timestamp: i64,
        pub readout_timestamp: i64,
    }

    impl binder::Parcelable for ShutterMsg {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.frame_number)?;
                subparcel.write(&self.timestamp)?;
                subparcel.write(&self.readout_timestamp)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.frame_number = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.timestamp = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.readout_timestamp = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(ShutterMsg);
    binder::impl_deserialize_for_parcelable!(ShutterMsg);

    #[derive(Clone, Debug)]
    pub enum NotifyMsg {
        Error(ErrorMsg),
        Shutter(ShutterMsg),
    }

    impl Default for NotifyMsg {
        fn default() -> Self {
            Self::Shutter(ShutterMsg::default())
        }
    }

    impl binder::Parcelable for NotifyMsg {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            match self {
                Self::Error(message) => {
                    parcel.write(&0_i32)?;
                    parcel.write(message)?;
                }
                Self::Shutter(message) => {
                    parcel.write(&1_i32)?;
                    parcel.write(message)?;
                }
            }
            Ok(())
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            let tag: i32 = parcel.read()?;
            *self = match tag {
                0 => Self::Error(parcel.read()?),
                1 => Self::Shutter(parcel.read()?),
                _ => return Err(StatusCode::BAD_VALUE),
            };
            Ok(())
        }
    }

    binder::impl_serialize_for_parcelable!(NotifyMsg);
    binder::impl_deserialize_for_parcelable!(NotifyMsg);

    #[derive(Clone, Debug, Default)]
    pub struct BufferRequest {
        pub stream_id: i32,
        pub num_buffers_requested: i32,
    }

    impl binder::Parcelable for BufferRequest {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.stream_id)?;
                subparcel.write(&self.num_buffers_requested)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.stream_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.num_buffers_requested = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(BufferRequest);
    binder::impl_deserialize_for_parcelable!(BufferRequest);

    declare_binder_enum! {
        #[repr(C, align(4))]
        BufferRequestStatus : [i32; 5] {
            OK = 0,
            FAILED_PARTIAL = 1,
            FAILED_CONFIGURING = 2,
            FAILED_ILLEGAL_ARGUMENTS = 3,
            FAILED_UNKNOWN = 4,
        }
    }

    declare_binder_enum! {
        #[repr(C, align(4))]
        StreamBufferRequestError : [i32; 4] {
            NO_BUFFER_AVAILABLE = 1,
            MAX_BUFFER_EXCEEDED = 2,
            STREAM_DISCONNECTED = 3,
            UNKNOWN_ERROR = 4,
        }
    }

    #[derive(Clone, Debug)]
    pub enum StreamBuffersVal {
        Error(StreamBufferRequestError),
        Buffers(Vec<StreamBuffer>),
    }

    impl Default for StreamBuffersVal {
        fn default() -> Self {
            Self::Error(StreamBufferRequestError::UNKNOWN_ERROR)
        }
    }

    impl binder::Parcelable for StreamBuffersVal {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            match self {
                Self::Error(error) => {
                    parcel.write(&0_i32)?;
                    parcel.write(error)?;
                }
                Self::Buffers(buffers) => {
                    parcel.write(&1_i32)?;
                    parcel.write(buffers)?;
                }
            }
            Ok(())
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            let tag: i32 = parcel.read()?;
            *self = match tag {
                0 => Self::Error(parcel.read()?),
                1 => Self::Buffers(parcel.read()?),
                _ => return Err(StatusCode::BAD_VALUE),
            };
            Ok(())
        }
    }

    binder::impl_serialize_for_parcelable!(StreamBuffersVal);
    binder::impl_deserialize_for_parcelable!(StreamBuffersVal);

    #[derive(Clone, Debug, Default)]
    pub struct StreamBufferRet {
        pub stream_id: i32,
        pub val: StreamBuffersVal,
    }

    impl binder::Parcelable for StreamBufferRet {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.stream_id)?;
                subparcel.write(&self.val)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.stream_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.val = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(StreamBufferRet);
    binder::impl_deserialize_for_parcelable!(StreamBufferRet);

    #[derive(Clone, Debug)]
    pub struct BufferRequestResponse {
        pub status: BufferRequestStatus,
        pub buffers: Vec<StreamBufferRet>,
    }

    impl Default for BufferRequestResponse {
        fn default() -> Self {
            Self {
                status: BufferRequestStatus::FAILED_UNKNOWN,
                buffers: Vec::new(),
            }
        }
    }

    #[derive(Clone, Debug, Default)]
    pub struct BufferCache {
        pub stream_id: i32,
        pub buffer_id: i64,
    }

    impl binder::Parcelable for BufferCache {
        fn write_to_parcel(
            &self,
            parcel: &mut BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_write(|subparcel| {
                subparcel.write(&self.stream_id)?;
                subparcel.write(&self.buffer_id)?;
                Ok(())
            })
        }

        fn read_from_parcel(
            &mut self,
            parcel: &BorrowedParcel<'_>,
        ) -> std::result::Result<(), StatusCode> {
            parcel.sized_read(|subparcel| {
                if subparcel.has_more_data() {
                    self.stream_id = subparcel.read()?;
                }
                if subparcel.has_more_data() {
                    self.buffer_id = subparcel.read()?;
                }
                Ok(())
            })
        }
    }

    binder::impl_serialize_for_parcelable!(BufferCache);
    binder::impl_deserialize_for_parcelable!(BufferCache);

    declare_binder_interface! {
        ICameraDeviceCallback["android.hardware.camera.device.ICameraDeviceCallback"] {
            native: BnCameraDeviceCallback(on_transact_callback),
            proxy: BpCameraDeviceCallback,
            stability: binder::binder_impl::Stability::Vintf,
        }
    }

    const CALLBACK_INTERFACE_VERSION: i32 = 3;
    const CALLBACK_INTERFACE_HASH: &str = "ac7c7f74993871015f73daff1ea0c7f4d4f85ca7";

    pub trait ICameraDeviceCallback: binder::Interface + Send {
        fn notify(&self, msgs: &[NotifyMsg]) -> binder::Result<()>;
        fn process_capture_result(&self, results: &[CaptureResult]) -> binder::Result<()>;
        fn request_stream_buffers(
            &self,
            buffer_requests: &[BufferRequest],
        ) -> binder::Result<BufferRequestResponse>;
        fn return_stream_buffers(&self, buffers: &[StreamBuffer]) -> binder::Result<()>;
    }

    mod callback_transactions {
        use super::*;

        pub const NOTIFY: TransactionCode = FIRST_CALL_TRANSACTION + 0;
        pub const PROCESS_CAPTURE_RESULT: TransactionCode = FIRST_CALL_TRANSACTION + 1;
        pub const REQUEST_STREAM_BUFFERS: TransactionCode = FIRST_CALL_TRANSACTION + 2;
        pub const RETURN_STREAM_BUFFERS: TransactionCode = FIRST_CALL_TRANSACTION + 3;
        pub const GET_INTERFACE_HASH: TransactionCode = FIRST_CALL_TRANSACTION + 16_777_213;
        pub const GET_INTERFACE_VERSION: TransactionCode = FIRST_CALL_TRANSACTION + 16_777_214;
    }

    impl ICameraDeviceCallback for BpCameraDeviceCallback {
        fn notify(&self, msgs: &[NotifyMsg]) -> binder::Result<()> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&msgs.to_vec())?;
            let reply = self
                .binder
                .submit_transact(callback_transactions::NOTIFY, data, 0);
            super::read_aidl_status(reply)
        }

        fn process_capture_result(&self, results: &[CaptureResult]) -> binder::Result<()> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&results.to_vec())?;
            let reply = self.binder.submit_transact(
                callback_transactions::PROCESS_CAPTURE_RESULT,
                data,
                0,
            );
            super::read_aidl_status(reply)
        }

        fn request_stream_buffers(
            &self,
            buffer_requests: &[BufferRequest],
        ) -> binder::Result<BufferRequestResponse> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&buffer_requests.to_vec())?;
            let reply = self.binder.submit_transact(
                callback_transactions::REQUEST_STREAM_BUFFERS,
                data,
                0,
            );
            let reply = reply?;
            let status: Status = reply.read()?;
            if !status.is_ok() {
                return Err(status);
            }
            Ok(BufferRequestResponse {
                status: reply.read()?,
                buffers: reply.read()?,
            })
        }

        fn return_stream_buffers(&self, buffers: &[StreamBuffer]) -> binder::Result<()> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&buffers.to_vec())?;
            let reply = self.binder.submit_transact(
                callback_transactions::RETURN_STREAM_BUFFERS,
                data,
                0,
            );
            super::read_aidl_status(reply)
        }
    }

    impl ICameraDeviceCallback for binder::binder_impl::Binder<BnCameraDeviceCallback> {
        fn notify(&self, msgs: &[NotifyMsg]) -> binder::Result<()> {
            self.0.notify(msgs)
        }

        fn process_capture_result(&self, results: &[CaptureResult]) -> binder::Result<()> {
            self.0.process_capture_result(results)
        }

        fn request_stream_buffers(
            &self,
            buffer_requests: &[BufferRequest],
        ) -> binder::Result<BufferRequestResponse> {
            self.0.request_stream_buffers(buffer_requests)
        }

        fn return_stream_buffers(&self, buffers: &[StreamBuffer]) -> binder::Result<()> {
            self.0.return_stream_buffers(buffers)
        }
    }

    fn on_transact_callback(
        service: &dyn ICameraDeviceCallback,
        code: TransactionCode,
        data: &BorrowedParcel<'_>,
        reply: &mut BorrowedParcel<'_>,
    ) -> std::result::Result<(), StatusCode> {
        match code {
            callback_transactions::NOTIFY => {
                let msgs: Vec<NotifyMsg> = data.read()?;
                super::write_aidl_status(reply, service.notify(&msgs))
            }
            callback_transactions::PROCESS_CAPTURE_RESULT => {
                let results: Vec<CaptureResult> = data.read()?;
                super::write_aidl_status(reply, service.process_capture_result(&results))
            }
            callback_transactions::REQUEST_STREAM_BUFFERS => {
                let buffer_requests: Vec<BufferRequest> = data.read()?;
                match service.request_stream_buffers(&buffer_requests) {
                    Ok(response) => {
                        reply.write(&Status::ok())?;
                        reply.write(&response.status)?;
                        reply.write(&response.buffers)?;
                        Ok(())
                    }
                    Err(status) => reply.write(&status),
                }
            }
            callback_transactions::RETURN_STREAM_BUFFERS => {
                let buffers: Vec<StreamBuffer> = data.read()?;
                super::write_aidl_status(reply, service.return_stream_buffers(&buffers))
            }
            callback_transactions::GET_INTERFACE_VERSION => {
                super::write_aidl_value(reply, Ok(CALLBACK_INTERFACE_VERSION))
            }
            callback_transactions::GET_INTERFACE_HASH => {
                super::write_aidl_value(reply, Ok(CALLBACK_INTERFACE_HASH.to_owned()))
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
        fn configure_streams(
            &self,
            requested_configuration: &StreamConfiguration,
        ) -> binder::Result<Vec<HalStream>>;
        fn construct_default_request_settings(
            &self,
            template: RequestTemplate,
        ) -> binder::Result<CameraMetadata>;
        fn process_capture_request(
            &self,
            requests: &[CaptureRequest],
            caches_to_remove: &[BufferCache],
        ) -> binder::Result<i32>;
    }

    mod session_transactions {
        use super::*;

        pub const CLOSE: TransactionCode = FIRST_CALL_TRANSACTION + 0;
        pub const CONFIGURE_STREAMS: TransactionCode = FIRST_CALL_TRANSACTION + 1;
        pub const CONSTRUCT_DEFAULT_REQUEST_SETTINGS: TransactionCode =
            FIRST_CALL_TRANSACTION + 2;
        pub const PROCESS_CAPTURE_REQUEST: TransactionCode = FIRST_CALL_TRANSACTION + 7;
    }

    impl ICameraDeviceSession for BpCameraDeviceSession {
        fn close(&self) -> binder::Result<()> {
            let data = self.binder.prepare_transact()?;
            let reply = self
                .binder
                .submit_transact(session_transactions::CLOSE, data, 0);
            super::read_aidl_status(reply)
        }

        fn configure_streams(
            &self,
            requested_configuration: &StreamConfiguration,
        ) -> binder::Result<Vec<HalStream>> {
            let mut data = self.binder.prepare_transact()?;
            data.write(requested_configuration)?;
            let reply = self.binder.submit_transact(
                session_transactions::CONFIGURE_STREAMS,
                data,
                0,
            );
            super::read_aidl_reply(reply)
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

        fn process_capture_request(
            &self,
            requests: &[CaptureRequest],
            caches_to_remove: &[BufferCache],
        ) -> binder::Result<i32> {
            let mut data = self.binder.prepare_transact()?;
            data.write(&requests.to_vec())?;
            data.write(&caches_to_remove.to_vec())?;
            let reply = self.binder.submit_transact(
                session_transactions::PROCESS_CAPTURE_REQUEST,
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

        fn configure_streams(
            &self,
            requested_configuration: &StreamConfiguration,
        ) -> binder::Result<Vec<HalStream>> {
            self.0.configure_streams(requested_configuration)
        }

        fn construct_default_request_settings(
            &self,
            template: RequestTemplate,
        ) -> binder::Result<CameraMetadata> {
            self.0.construct_default_request_settings(template)
        }

        fn process_capture_request(
            &self,
            requests: &[CaptureRequest],
            caches_to_remove: &[BufferCache],
        ) -> binder::Result<i32> {
            self.0.process_capture_request(requests, caches_to_remove)
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
            session_transactions::CONFIGURE_STREAMS => {
                let requested_configuration: StreamConfiguration = data.read()?;
                super::write_aidl_value(
                    reply,
                    service.configure_streams(&requested_configuration),
                )
            }
            session_transactions::CONSTRUCT_DEFAULT_REQUEST_SETTINGS => {
                let template: RequestTemplate = data.read()?;
                super::write_aidl_value(
                    reply,
                    service.construct_default_request_settings(template),
                )
            }
            session_transactions::PROCESS_CAPTURE_REQUEST => {
                let requests: Vec<CaptureRequest> = data.read()?;
                let caches_to_remove: Vec<BufferCache> = data.read()?;
                super::write_aidl_value(
                    reply,
                    service.process_capture_request(&requests, &caches_to_remove),
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
        fn is_stream_combination_supported(
            &self,
            streams: &StreamConfiguration,
        ) -> binder::Result<bool>;
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
        pub const IS_STREAM_COMBINATION_SUPPORTED: TransactionCode = FIRST_CALL_TRANSACTION + 3;
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

        fn is_stream_combination_supported(
            &self,
            streams: &StreamConfiguration,
        ) -> binder::Result<bool> {
            let mut data = self.binder.prepare_transact()?;
            data.write(streams)?;
            let reply = self.binder.submit_transact(
                transactions::IS_STREAM_COMBINATION_SUPPORTED,
                data,
                0,
            );
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

        fn is_stream_combination_supported(
            &self,
            streams: &StreamConfiguration,
        ) -> binder::Result<bool> {
            self.0.is_stream_combination_supported(streams)
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
            transactions::IS_STREAM_COMBINATION_SUPPORTED => {
                let streams: StreamConfiguration = data.read()?;
                super::write_aidl_value(reply, service.is_stream_combination_supported(&streams))
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
            stability: binder::binder_impl::Stability::Vintf,
        }
    }

    const CALLBACK_INTERFACE_VERSION: i32 = 3;
    const CALLBACK_INTERFACE_HASH: &str = "261437c3d7d6ad09d5560eee5196a28c0b27106e";

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
        pub const GET_INTERFACE_HASH: TransactionCode = FIRST_CALL_TRANSACTION + 16_777_213;
        pub const GET_INTERFACE_VERSION: TransactionCode = FIRST_CALL_TRANSACTION + 16_777_214;
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
            callback_transactions::GET_INTERFACE_VERSION => {
                super::write_aidl_value(reply, Ok(CALLBACK_INTERFACE_VERSION))
            }
            callback_transactions::GET_INTERFACE_HASH => {
                super::write_aidl_value(reply, Ok(CALLBACK_INTERFACE_HASH.to_owned()))
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
