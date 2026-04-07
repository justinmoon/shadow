use crate::camera_aidl::common::NativeHandle as AidlNativeHandle;
use crate::camera_aidl::device::{HalStream, Stream};
use binder::ParcelFileDescriptor;
use ndk::hardware_buffer::{
    HardwareBuffer, HardwareBufferDesc, HardwareBufferRef, HardwareBufferUsage,
};
use ndk::hardware_buffer_format::HardwareBufferFormat;
use std::ffi::c_void;
use std::io::{self, Error, ErrorKind};
use std::os::fd::{FromRawFd, OwnedFd};
use std::path::Path;

pub const DEFAULT_CAPTURE_PATH: &str = "/data/local/tmp/shadow-camera-provider-host-capture.jpg";

const AIDL_CAMERA_BLOB_JPEG_ID: i32 = 255;
const HIDL_CAMERA_BLOB_JPEG_ID: u16 = 0x00ff;

#[repr(C)]
struct NativeHandleRaw {
    version: i32,
    num_fds: i32,
    num_ints: i32,
    data: [i32; 0],
}

unsafe extern "C" {
    fn AHardwareBuffer_getNativeHandle(buffer: *const c_void) -> *const NativeHandleRaw;
}

#[derive(Clone)]
pub struct AllocatedCaptureBuffer {
    pub buffer: HardwareBufferRef,
    pub aidl_handle: AidlNativeHandle,
    pub buffer_id: i64,
    pub allocation_width: usize,
    pub allocation_usage: u64,
}

// `AHardwareBuffer` is a reference-counted NDK object intended to be shared
// across threads and processes. The Rust wrapper does not currently mark it as
// `Send`/`Sync`, so the helper carries that guarantee at the owned buffer seam.
unsafe impl Send for AllocatedCaptureBuffer {}
unsafe impl Sync for AllocatedCaptureBuffer {}

pub fn allocate_jpeg_capture_buffer(
    requested_stream: &Stream,
    hal_stream: &HalStream,
) -> io::Result<AllocatedCaptureBuffer> {
    let allocation_width: usize = requested_stream.buffer_size.try_into().map_err(|_| {
        Error::new(
            ErrorKind::InvalidInput,
            "jpeg stream buffer_size must be positive",
        )
    })?;

    let allocation_width_u32 = u32::try_from(allocation_width).map_err(|_| {
        Error::new(
            ErrorKind::InvalidInput,
            "jpeg stream buffer_size overflowed u32",
        )
    })?;

    let allocation_usage = (requested_stream.usage.0 as u64)
        | (hal_stream.producer_usage.0 as u64)
        | (hal_stream.consumer_usage.0 as u64);

    let buffer = HardwareBuffer::allocate(HardwareBufferDesc {
        width: allocation_width_u32,
        height: 1,
        layers: 1,
        format: HardwareBufferFormat::BLOB,
        usage: HardwareBufferUsage::from_bits_retain(allocation_usage),
        stride: 0,
    })?;

    let aidl_handle = clone_native_handle(&buffer)?;
    let buffer_id = i64::try_from(buffer.id()?)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "hardware buffer id overflowed i64"))?;

    Ok(AllocatedCaptureBuffer {
        buffer,
        aidl_handle,
        buffer_id,
        allocation_width,
        allocation_usage,
    })
}

pub fn write_jpeg_from_buffer(
    buffer: &HardwareBufferRef,
    release_fence: Option<OwnedFd>,
    output_path: &Path,
) -> io::Result<usize> {
    let allocation_width = usize::try_from(buffer.describe().width)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "buffer width overflowed usize"))?;
    let locked_ptr = buffer.lock(HardwareBufferUsage::CPU_READ_OFTEN, release_fence, None)?;

    let jpeg_bytes = (|| -> io::Result<Vec<u8>> {
        let bytes =
            unsafe { std::slice::from_raw_parts(locked_ptr.cast::<u8>(), allocation_width) };
        let jpeg_size = parse_jpeg_blob_size(bytes).ok_or_else(|| {
            Error::new(
                ErrorKind::InvalidData,
                "jpeg buffer is missing a recognized camera blob footer",
            )
        })?;
        if jpeg_size > bytes.len() {
            return Err(Error::new(
                ErrorKind::InvalidData,
                "jpeg size from blob footer exceeds allocation size",
            ));
        }
        Ok(bytes[..jpeg_size].to_vec())
    })();

    let unlock_result = buffer.unlock();
    unlock_result?;
    let jpeg_bytes = jpeg_bytes?;
    std::fs::write(output_path, &jpeg_bytes)?;
    Ok(jpeg_bytes.len())
}

fn parse_jpeg_blob_size(bytes: &[u8]) -> Option<usize> {
    if bytes.len() >= 8 {
        let tail = &bytes[bytes.len() - 8..];

        let aidl_blob_id = i32::from_le_bytes([tail[0], tail[1], tail[2], tail[3]]);
        let aidl_blob_size = i32::from_le_bytes([tail[4], tail[5], tail[6], tail[7]]);
        if aidl_blob_id == AIDL_CAMERA_BLOB_JPEG_ID
            && aidl_blob_size >= 0
            && (aidl_blob_size as usize) <= bytes.len().saturating_sub(8)
        {
            return Some(aidl_blob_size as usize);
        }

        let hidl_blob_id = u16::from_le_bytes([tail[0], tail[1]]);
        let hidl_blob_size = u32::from_le_bytes([tail[4], tail[5], tail[6], tail[7]]);
        if hidl_blob_id == HIDL_CAMERA_BLOB_JPEG_ID
            && (hidl_blob_size as usize) <= bytes.len().saturating_sub(8)
        {
            return Some(hidl_blob_size as usize);
        }
    }

    if bytes.len() >= 6 {
        let tail = &bytes[bytes.len() - 6..];
        let hidl_blob_id = u16::from_le_bytes([tail[0], tail[1]]);
        let hidl_blob_size = u32::from_le_bytes([tail[2], tail[3], tail[4], tail[5]]);
        if hidl_blob_id == HIDL_CAMERA_BLOB_JPEG_ID
            && (hidl_blob_size as usize) <= bytes.len().saturating_sub(6)
        {
            return Some(hidl_blob_size as usize);
        }
    }

    None
}

fn clone_native_handle(buffer: &HardwareBufferRef) -> io::Result<AidlNativeHandle> {
    let raw_handle = unsafe { AHardwareBuffer_getNativeHandle(buffer.as_ptr().cast()) };
    if raw_handle.is_null() {
        return Err(Error::new(
            ErrorKind::NotFound,
            "AHardwareBuffer_getNativeHandle returned null",
        ));
    }

    unsafe { raw_native_handle_to_aidl(raw_handle) }
}

unsafe fn raw_native_handle_to_aidl(
    handle: *const NativeHandleRaw,
) -> io::Result<AidlNativeHandle> {
    let raw = unsafe { &*handle };
    let num_fds = usize::try_from(raw.num_fds)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "native handle numFds overflowed"))?;
    let num_ints = usize::try_from(raw.num_ints)
        .map_err(|_| Error::new(ErrorKind::InvalidData, "native handle numInts overflowed"))?;

    let fds = (0..num_fds)
        .map(|index| {
            let fd = unsafe { *raw.data.as_ptr().add(index) };
            let duplicated = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
            if duplicated < 0 {
                Err(io::Error::last_os_error())
            } else {
                let owned = unsafe { OwnedFd::from_raw_fd(duplicated) };
                Ok(ParcelFileDescriptor::new(owned))
            }
        })
        .collect::<io::Result<Vec<_>>>()?;

    let ints = (0..num_ints)
        .map(|index| unsafe { *raw.data.as_ptr().add(num_fds + index) })
        .collect::<Vec<_>>();

    Ok(AidlNativeHandle { fds, ints })
}
