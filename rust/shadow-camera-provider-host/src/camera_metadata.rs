use crate::camera_aidl::device;
use libc::{c_char, c_void, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW};
use std::mem::MaybeUninit;
use std::sync::OnceLock;

const ANDROID_SENSOR_ORIENTATION: u32 = 917_518;

#[repr(C)]
struct CameraMetadataOpaque {
    _private: [u8; 0],
}

#[repr(C)]
struct CameraMetadataRational {
    numerator: i32,
    denominator: i32,
}

#[repr(C)]
union CameraMetadataConstData {
    u8_: *const u8,
    i32_: *const i32,
    f_: *const f32,
    i64_: *const i64,
    d_: *const f64,
    r_: *const CameraMetadataRational,
}

#[repr(C)]
struct CameraMetadataRoEntry {
    index: usize,
    tag: u32,
    type_: u8,
    count: usize,
    data: CameraMetadataConstData,
}

type AllocateCopyCameraMetadataChecked =
    unsafe extern "C" fn(*const CameraMetadataOpaque, usize) -> *mut CameraMetadataOpaque;
type FreeCameraMetadata = unsafe extern "C" fn(*mut CameraMetadataOpaque);
type FindCameraMetadataRoEntry =
    unsafe extern "C" fn(*const CameraMetadataOpaque, u32, *mut CameraMetadataRoEntry) -> i32;

struct CameraMetadataFns {
    _handle: *mut c_void,
    allocate_copy_camera_metadata_checked: AllocateCopyCameraMetadataChecked,
    free_camera_metadata: FreeCameraMetadata,
    find_camera_metadata_ro_entry: FindCameraMetadataRoEntry,
}

unsafe impl Send for CameraMetadataFns {}
unsafe impl Sync for CameraMetadataFns {}

static CAMERA_METADATA_FNS: OnceLock<Option<CameraMetadataFns>> = OnceLock::new();

pub fn sensor_orientation_degrees(characteristics: &device::CameraMetadata) -> Option<u16> {
    let camera_metadata = camera_metadata_fns()?;
    let copied = unsafe {
        (camera_metadata.allocate_copy_camera_metadata_checked)(
            characteristics.metadata.as_ptr().cast::<CameraMetadataOpaque>(),
            characteristics.metadata.len(),
        )
    };
    if copied.is_null() {
        return None;
    }

    let mut entry = MaybeUninit::<CameraMetadataRoEntry>::zeroed();
    let status = unsafe {
        (camera_metadata.find_camera_metadata_ro_entry)(
            copied,
            ANDROID_SENSOR_ORIENTATION,
            entry.as_mut_ptr(),
        )
    };
    let orientation = if status == 0 {
        let entry = unsafe { entry.assume_init() };
        if entry.count == 0 {
            None
        } else {
            let value_ptr = unsafe { entry.data.i32_ };
            if value_ptr.is_null() {
                None
            } else {
                Some(unsafe { *value_ptr })
            }
        }
    } else {
        None
    };

    unsafe {
        (camera_metadata.free_camera_metadata)(copied);
    }

    orientation.and_then(|value| u16::try_from(value.rem_euclid(360)).ok())
}

fn camera_metadata_fns() -> Option<&'static CameraMetadataFns> {
    CAMERA_METADATA_FNS.get_or_init(load_camera_metadata_fns).as_ref()
}

fn load_camera_metadata_fns() -> Option<CameraMetadataFns> {
    let handle = unsafe {
        dlopen(
            c"libcamera_metadata.so".as_ptr(),
            RTLD_NOW | RTLD_LOCAL,
        )
    };
    if handle.is_null() {
        return None;
    }

    Some(CameraMetadataFns {
        _handle: handle,
        allocate_copy_camera_metadata_checked: unsafe {
            load_symbol(handle, b"allocate_copy_camera_metadata_checked\0")?
        },
        free_camera_metadata: unsafe { load_symbol(handle, b"free_camera_metadata\0")? },
        find_camera_metadata_ro_entry: unsafe {
            load_symbol(handle, b"find_camera_metadata_ro_entry\0")?
        },
    })
}

unsafe fn load_symbol<T>(handle: *mut c_void, name: &[u8]) -> Option<T> {
    let symbol = unsafe { dlsym(handle, name.as_ptr().cast::<c_char>()) };
    if symbol.is_null() {
        return None;
    }

    Some(unsafe { std::mem::transmute_copy::<*mut c_void, T>(&symbol) })
}
