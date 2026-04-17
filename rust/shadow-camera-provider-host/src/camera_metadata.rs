use crate::camera_aidl::device;
use libc::{c_char, c_void, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW};
use std::mem::MaybeUninit;
use std::sync::OnceLock;

const ANDROID_LENS_FACING: u32 = 524_293;
const ANDROID_SENSOR_ORIENTATION: u32 = 917_518;
const TYPE_BYTE: u8 = 0;
const TYPE_INT32: u8 = 1;
const LENS_FACING_FRONT: i32 = 0;
const LENS_FACING_BACK: i32 = 1;
const LENS_FACING_EXTERNAL: i32 = 2;

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

pub fn lens_facing(characteristics: &device::CameraMetadata) -> Option<&'static str> {
    match integer_metadata_value(characteristics, ANDROID_LENS_FACING)? {
        LENS_FACING_FRONT => Some("front"),
        LENS_FACING_BACK => Some("rear"),
        LENS_FACING_EXTERNAL => Some("external"),
        _ => None,
    }
}

pub fn sensor_orientation_degrees(characteristics: &device::CameraMetadata) -> Option<u16> {
    integer_metadata_value(characteristics, ANDROID_SENSOR_ORIENTATION)
        .and_then(|value| u16::try_from(value.rem_euclid(360)).ok())
}

fn integer_metadata_value(characteristics: &device::CameraMetadata, tag: u32) -> Option<i32> {
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

    let value = integer_entry_value(camera_metadata, copied, tag);

    unsafe {
        (camera_metadata.free_camera_metadata)(copied);
    }

    value
}

fn integer_entry_value(
    camera_metadata: &CameraMetadataFns,
    copied: *mut CameraMetadataOpaque,
    tag: u32,
) -> Option<i32> {
    let mut entry = MaybeUninit::<CameraMetadataRoEntry>::zeroed();
    let status = unsafe {
        (camera_metadata.find_camera_metadata_ro_entry)(copied, tag, entry.as_mut_ptr())
    };
    if status != 0 {
        return None;
    }

    let entry = unsafe { entry.assume_init() };
    if entry.count == 0 {
        return None;
    }

    match entry.type_ {
        TYPE_BYTE => {
            let value_ptr = unsafe { entry.data.u8_ };
            if value_ptr.is_null() {
                None
            } else {
                Some(i32::from(unsafe { *value_ptr }))
            }
        }
        TYPE_INT32 => {
            let value_ptr = unsafe { entry.data.i32_ };
            if value_ptr.is_null() {
                None
            } else {
                Some(unsafe { *value_ptr })
            }
        }
        _ => None,
    }
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
