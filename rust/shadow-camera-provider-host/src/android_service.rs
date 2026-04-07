use binder::unstable_api::{new_spibinder, AIBinder};
use binder::{ExceptionCode, FromIBinder, SpIBinder, StatusCode, Strong};
use libc::{c_void, dlerror, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::OnceLock;

type WaitForServiceFn = unsafe extern "C" fn(*const c_char) -> *mut AIBinder;
type IsDeclaredFn = unsafe extern "C" fn(*const c_char) -> bool;
type ForEachDeclaredInstanceFn = unsafe extern "C" fn(
    *const c_char,
    *mut c_void,
    Option<unsafe extern "C" fn(*const c_char, *mut c_void)>,
);
type StartThreadPoolFn = unsafe extern "C" fn();
type SetThreadPoolMaxThreadCountFn = unsafe extern "C" fn(u32) -> bool;

struct BinderNdkPlatformApi {
    wait_for_service: WaitForServiceFn,
    is_declared: IsDeclaredFn,
    for_each_declared_instance: ForEachDeclaredInstanceFn,
    start_thread_pool: StartThreadPoolFn,
    set_thread_pool_max_thread_count: SetThreadPoolMaxThreadCountFn,
}

static BINDER_NDK_PLATFORM_API: OnceLock<BinderNdkPlatformApi> = OnceLock::new();

fn platform_error(message: impl Into<String>) -> binder::Status {
    binder::Status::new_exception_str(ExceptionCode::ILLEGAL_STATE, Some(message.into()))
}

fn platform_api() -> binder::Result<&'static BinderNdkPlatformApi> {
    if let Some(api) = BINDER_NDK_PLATFORM_API.get() {
        return Ok(api);
    }

    let api = load_platform_api()?;
    let _ = BINDER_NDK_PLATFORM_API.set(api);
    Ok(BINDER_NDK_PLATFORM_API
        .get()
        .expect("binder_ndk platform api initialized"))
}

fn load_platform_api() -> binder::Result<BinderNdkPlatformApi> {
    let library_name = CString::new("libbinder_ndk.so").expect("valid library name");
    let handle = unsafe { dlopen(library_name.as_ptr(), RTLD_NOW | RTLD_LOCAL) };
    if handle.is_null() {
        return Err(platform_error(dl_error_message("dlopen libbinder_ndk.so")));
    }

    Ok(BinderNdkPlatformApi {
        wait_for_service: unsafe { load_symbol(handle, b"AServiceManager_waitForService\0")? },
        is_declared: unsafe { load_symbol(handle, b"AServiceManager_isDeclared\0")? },
        for_each_declared_instance: unsafe {
            load_symbol(handle, b"AServiceManager_forEachDeclaredInstance\0")?
        },
        start_thread_pool: unsafe { load_symbol(handle, b"ABinderProcess_startThreadPool\0")? },
        set_thread_pool_max_thread_count: unsafe {
            load_symbol(handle, b"ABinderProcess_setThreadPoolMaxThreadCount\0")?
        },
    })
}

unsafe fn load_symbol<T>(handle: *mut c_void, symbol: &[u8]) -> binder::Result<T> {
    let _ = unsafe { dlerror() };
    let ptr = unsafe { dlsym(handle, symbol.as_ptr().cast()) };
    if ptr.is_null() {
        let symbol_name = String::from_utf8_lossy(&symbol[..symbol.len() - 1]).into_owned();
        return Err(platform_error(dl_error_message(format!(
            "missing symbol {symbol_name}"
        ))));
    }

    Ok(unsafe { std::mem::transmute_copy(&ptr) })
}

fn dl_error_message(prefix: impl Into<String>) -> String {
    let prefix = prefix.into();
    let error = unsafe { dlerror() };
    if error.is_null() {
        prefix
    } else {
        format!(
            "{prefix}: {}",
            unsafe { CStr::from_ptr(error) }.to_string_lossy()
        )
    }
}

fn interface_cast<T: FromIBinder + ?Sized>(
    service: Option<SpIBinder>,
) -> binder::Result<Strong<T>> {
    if let Some(service) = service {
        Ok(FromIBinder::try_from(service)?)
    } else {
        Err(StatusCode::NAME_NOT_FOUND.into())
    }
}

fn wait_for_service(name: &str) -> Option<SpIBinder> {
    let name = CString::new(name).ok()?;
    let api = platform_api().ok()?;
    unsafe { new_spibinder((api.wait_for_service)(name.as_ptr())) }
}

pub fn start_thread_pool() {
    if let Ok(api) = platform_api() {
        unsafe { (api.start_thread_pool)() };
    }
}

pub fn set_thread_pool_max_thread_count(num_threads: u32) {
    if let Ok(api) = platform_api() {
        unsafe {
            let _ = (api.set_thread_pool_max_thread_count)(num_threads);
        }
    }
}

pub fn wait_for_interface<T: FromIBinder + ?Sized>(name: &str) -> binder::Result<Strong<T>> {
    interface_cast(wait_for_service(name))
}

pub fn is_declared(interface: &str) -> binder::Result<bool> {
    let interface = CString::new(interface).or(Err(StatusCode::UNEXPECTED_NULL))?;
    let api = platform_api()?;
    unsafe { Ok((api.is_declared)(interface.as_ptr())) }
}

pub fn get_declared_instances(interface: &str) -> binder::Result<Vec<String>> {
    unsafe extern "C" fn callback(instance: *const c_char, opaque: *mut c_void) {
        if let Some(instances) = unsafe { opaque.cast::<Vec<CString>>().as_mut() } {
            unsafe {
                instances.push(CStr::from_ptr(instance).to_owned());
            }
        }
    }

    let interface = CString::new(interface).or(Err(StatusCode::UNEXPECTED_NULL))?;
    let api = platform_api()?;
    let mut instances: Vec<CString> = vec![];
    unsafe {
        (api.for_each_declared_instance)(
            interface.as_ptr(),
            &mut instances as *mut _ as *mut c_void,
            Some(callback),
        );
    }

    instances
        .into_iter()
        .map(CString::into_string)
        .collect::<std::result::Result<Vec<String>, _>>()
        .map_err(|_| StatusCode::BAD_VALUE.into())
}
