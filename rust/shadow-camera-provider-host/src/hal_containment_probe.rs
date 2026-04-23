use crate::android_service::{
    check_for_interface, get_declared_instances, is_declared, set_thread_pool_max_thread_count,
    start_thread_pool,
};
use crate::camera_aidl::provider::ICameraProvider;
use crate::hal_probe_support::*;
use libc::{c_void, dlerror, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::ffi::{CString, OsString};
use std::os::raw::c_char;
use std::path::Path;

const SCHEMA_VERSION: u32 = 1;
const DEFAULT_HAL_PATH: &str = "/vendor/lib64/hw/camera.sm6150.so";
const PROVIDER_INTERFACE: &str = "android.hardware.camera.provider.ICameraProvider";
const DEFAULT_PROVIDER_SERVICE: &str =
    "android.hardware.camera.provider.ICameraProvider/internal/0";
const ANDROID_DLEXT_USE_NAMESPACE: u64 = 0x200;

type AndroidDlopenExtFn =
    unsafe extern "C" fn(*const c_char, libc::c_int, *const AndroidDlExtInfo) -> *mut c_void;
type AndroidGetExportedNamespaceFn = unsafe extern "C" fn(*const c_char) -> *mut c_void;

struct HalLoadAttempt {
    value: Value,
    handle: *mut c_void,
}

#[repr(C)]
struct HwModulePartial {
    tag: u32,
    module_api_version: u16,
    hal_api_version: u16,
    id: *const c_char,
    name: *const c_char,
    author: *const c_char,
    methods: *const c_void,
}

#[repr(C)]
struct AndroidDlExtInfo {
    flags: u64,
    reserved_addr: *mut c_void,
    reserved_size: usize,
    relro_fd: i32,
    library_fd: i32,
    library_fd_offset: i64,
    library_namespace: *mut c_void,
}

pub fn make_hal_probe_response(argv: &[OsString]) -> Value {
    let argv_strings = argv_strings(argv);
    let hal_path = argv_strings
        .iter()
        .find(|arg| arg.starts_with('/'))
        .cloned()
        .unwrap_or_else(|| DEFAULT_HAL_PATH.to_owned());

    let provider_service = probe_provider_service();
    let maps_before = mapped_shared_libraries();
    let direct_hal = probe_direct_hal(&hal_path, &maps_before);
    let dependency_closure = probe_dependency_closure(&hal_path);
    let provider_ok = provider_service.get("ok").and_then(Value::as_bool) == Some(true);
    let direct_load_ok = direct_hal
        .get("dlopen")
        .and_then(|value| value.get("ok"))
        .and_then(Value::as_bool)
        == Some(true);
    let direct_hmi_ok = direct_hal
        .get("hmiSymbol")
        .and_then(|value| value.get("ok"))
        .and_then(Value::as_bool)
        == Some(true);

    json!({
        "ok": true,
        "command": "hal-probe",
        "schemaVersion": SCHEMA_VERSION,
        "pid": std::process::id(),
        "cwd": current_dir_string(),
        "argv": argv_strings,
        "serial": command_stdout("getprop", &["ro.serialno"]),
        "fingerprint": command_stdout("getprop", &["ro.build.fingerprint"]),
        "kernelRelease": command_stdout("uname", &["-r"]),
        "selinuxMode": command_stdout("getenforce", &[]),
        "directHal": direct_hal,
        "providerService": provider_service,
        "dependencyClosure": dependency_closure,
        "containmentAssessment": {
            "providerServiceListedCameras": provider_ok,
            "directHalLoaded": direct_load_ok,
            "directHalIdentified": direct_hmi_ok,
            "providerMeasuredBeforeDirectHalLoad": true,
            "smallerBackendSeam": if provider_ok { "provider-service" } else if direct_hmi_ok { "direct-hal-load" } else { "blocked" },
            "shadowFacingProtocol": "Rust-owned helper command/socket API; Android Binder, HAL structs, native handles, gralloc/AHardwareBuffer, and vendor libraries stay behind the backend boundary",
        },
        "frameCapture": {
            "attempted": false,
            "blocker": frame_blocker(provider_ok, direct_hmi_ok),
            "nextProbe": "choose provider-service one-frame containment or add a C/C++ camera_module_t shim before direct HAL capture",
        },
    })
}

fn probe_direct_hal(path: &str, maps_before: &BTreeSet<String>) -> Value {
    let mut load_attempts = vec![
        load_hal_exported_namespace(path, "sphal"),
        load_hal_exported_namespace(path, "default"),
    ];
    if load_attempts
        .iter()
        .any(|attempt| !attempt.handle.is_null())
    {
        load_attempts.push(HalLoadAttempt {
            handle: std::ptr::null_mut(),
            value: json!({
                "mode": "current-namespace",
                "ok": false,
                "skipped": true,
                "reason": "skipped after successful namespace load; plain dlopen would not be an independent cold-load measurement in this process",
            }),
        });
    } else {
        load_attempts.push(load_hal_current_namespace(path));
    }
    let selected_handle = load_attempts
        .iter()
        .find(|attempt| !attempt.handle.is_null())
        .map(|attempt| attempt.handle)
        .unwrap_or(std::ptr::null_mut());

    if selected_handle.is_null() {
        return json!({
            "path": path,
            "file": file_json(Path::new(path)),
            "dlopen": {"ok": false},
            "loadAttempts": load_attempts
                .into_iter()
                .map(|attempt| attempt.value)
                .collect::<Vec<_>>(),
            "loadedLibraryDelta": Vec::<String>::new(),
        });
    }

    let maps_after = mapped_shared_libraries();
    let loaded_delta = maps_after
        .difference(maps_before)
        .cloned()
        .collect::<Vec<_>>();

    json!({
        "path": path,
        "file": file_json(Path::new(path)),
        "dlopen": {"ok": true, "handle": pointer_hex(selected_handle)},
        "loadAttempts": load_attempts
            .into_iter()
            .map(|attempt| attempt.value)
            .collect::<Vec<_>>(),
        "hmiSymbol": probe_hmi_symbol(selected_handle),
        "loadedLibraryDelta": loaded_delta,
        "cameraMappedLibraries": maps_after
            .iter()
            .filter(|path| contains_any(path, &["camera", "camx", "chi", "hidl", "binder", "gralloc"]))
            .cloned()
            .collect::<Vec<_>>(),
    })
}

fn load_hal_current_namespace(path: &str) -> HalLoadAttempt {
    let path_c = match CString::new(path) {
        Ok(path) => path,
        Err(error) => {
            return HalLoadAttempt {
                handle: std::ptr::null_mut(),
                value: json!({
                    "mode": "current-namespace",
                    "ok": false,
                    "error": format!("invalid path CString: {error}"),
                }),
            };
        }
    };
    let handle = unsafe {
        let _ = dlerror();
        dlopen(path_c.as_ptr(), RTLD_NOW | RTLD_LOCAL)
    };
    HalLoadAttempt {
        handle,
        value: if handle.is_null() {
            json!({
                "mode": "current-namespace",
                "ok": false,
                "error": dl_error_message("dlopen camera HAL"),
            })
        } else {
            json!({
                "mode": "current-namespace",
                "ok": true,
                "handle": pointer_hex(handle),
            })
        },
    }
}

fn load_hal_exported_namespace(path: &str, namespace: &str) -> HalLoadAttempt {
    let Ok(path_c) = CString::new(path) else {
        return HalLoadAttempt {
            handle: std::ptr::null_mut(),
            value: json!({"mode": "android-dlopen-ext", "namespace": namespace, "ok": false, "error": "invalid path CString"}),
        };
    };
    let Ok(namespace_c) = CString::new(namespace) else {
        return HalLoadAttempt {
            handle: std::ptr::null_mut(),
            value: json!({"mode": "android-dlopen-ext", "namespace": namespace, "ok": false, "error": "invalid namespace CString"}),
        };
    };
    let get_namespace = match load_libdl_symbol::<AndroidGetExportedNamespaceFn>(
        "android_get_exported_namespace",
    ) {
        Ok(function) => function,
        Err(error) => {
            return HalLoadAttempt {
                handle: std::ptr::null_mut(),
                value: json!({"mode": "android-dlopen-ext", "namespace": namespace, "ok": false, "error": error}),
            };
        }
    };
    let android_dlopen_ext = match load_libdl_symbol::<AndroidDlopenExtFn>("android_dlopen_ext") {
        Ok(function) => function,
        Err(error) => {
            return HalLoadAttempt {
                handle: std::ptr::null_mut(),
                value: json!({"mode": "android-dlopen-ext", "namespace": namespace, "ok": false, "error": error}),
            };
        }
    };
    let namespace_handle = unsafe { get_namespace(namespace_c.as_ptr()) };
    if namespace_handle.is_null() {
        return HalLoadAttempt {
            handle: std::ptr::null_mut(),
            value: json!({
                "mode": "android-dlopen-ext",
                "namespace": namespace,
                "ok": false,
                "error": "exported namespace unavailable",
            }),
        };
    }

    let info = AndroidDlExtInfo {
        flags: ANDROID_DLEXT_USE_NAMESPACE,
        reserved_addr: std::ptr::null_mut(),
        reserved_size: 0,
        relro_fd: -1,
        library_fd: -1,
        library_fd_offset: 0,
        library_namespace: namespace_handle,
    };
    let handle = unsafe {
        let _ = dlerror();
        android_dlopen_ext(path_c.as_ptr(), RTLD_NOW | RTLD_LOCAL, &info)
    };
    HalLoadAttempt {
        handle,
        value: if handle.is_null() {
            json!({
                "mode": "android-dlopen-ext",
                "namespace": namespace,
                "namespaceHandle": pointer_hex(namespace_handle),
                "ok": false,
                "error": dl_error_message(format!("android_dlopen_ext {namespace}")),
            })
        } else {
            json!({
                "mode": "android-dlopen-ext",
                "namespace": namespace,
                "namespaceHandle": pointer_hex(namespace_handle),
                "ok": true,
                "handle": pointer_hex(handle),
            })
        },
    }
}

fn probe_hmi_symbol(handle: *mut c_void) -> Value {
    let symbol = CString::new("HMI").expect("static symbol CString");
    let ptr = unsafe {
        let _ = dlerror();
        dlsym(handle, symbol.as_ptr())
    };
    if ptr.is_null() {
        return json!({"ok": false, "error": dl_error_message("dlsym HMI")});
    }

    let module = unsafe { &*(ptr as *const HwModulePartial) };
    json!({
        "ok": true,
        "address": pointer_hex(ptr),
        "tag": module.tag,
        "moduleApiVersion": module.module_api_version,
        "halApiVersion": module.hal_api_version,
        "id": c_string(module.id),
        "name": c_string(module.name),
        "author": c_string(module.author),
        "methods": pointer_hex(module.methods as *mut c_void),
    })
}

fn probe_provider_service() -> Value {
    set_thread_pool_max_thread_count(1);
    start_thread_pool();

    let declared_instances = match get_declared_instances(PROVIDER_INTERFACE) {
        Ok(instances) => instances,
        Err(status) => {
            return json!({
                "ok": false,
                "step": "getDeclaredInstances",
                "interface": PROVIDER_INTERFACE,
                "status": binder_status_json(&status),
            });
        }
    };

    let Some(service_name) = provider_service_name(&declared_instances) else {
        return json!({
            "ok": false,
            "step": "selectProviderService",
            "interface": PROVIDER_INTERFACE,
            "declaredInstances": declared_instances,
            "blocker": "no declared camera provider instances",
        });
    };

    let is_declared_value = match is_declared(&service_name) {
        Ok(value) => value,
        Err(status) => {
            return json!({
                "ok": false,
                "step": "isDeclared",
                "interface": PROVIDER_INTERFACE,
                "serviceName": service_name,
                "declaredInstances": declared_instances,
                "status": binder_status_json(&status),
            });
        }
    };
    if !is_declared_value {
        return json!({
            "ok": false,
            "step": "isDeclared",
            "interface": PROVIDER_INTERFACE,
            "serviceName": service_name,
            "isDeclared": false,
            "declaredInstances": declared_instances,
            "blocker": "camera provider service is not declared; not calling waitForService",
        });
    }

    let provider = match check_for_interface::<dyn ICameraProvider>(&service_name) {
        Ok(provider) => provider,
        Err(status) => {
            return json!({
                "ok": false,
                "step": "checkForInterface",
                "interface": PROVIDER_INTERFACE,
                "serviceName": service_name,
                "isDeclared": is_declared_value,
                "declaredInstances": declared_instances,
                "status": binder_status_json(&status),
                "blocker": "camera provider service is declared but not currently registered; not calling waitForService",
            });
        }
    };

    let camera_ids = match provider.get_camera_id_list() {
        Ok(camera_ids) => camera_ids,
        Err(status) => {
            return json!({
                "ok": false,
                "step": "getCameraIdList",
                "interface": PROVIDER_INTERFACE,
                "serviceName": service_name,
                "isDeclared": is_declared_value,
                "declaredInstances": declared_instances,
                "status": binder_status_json(&status),
            });
        }
    };

    let cameras = camera_ids
        .iter()
        .map(|camera_id| provider_camera_json(&*provider, camera_id))
        .collect::<Vec<_>>();

    json!({
        "ok": true,
        "interface": PROVIDER_INTERFACE,
        "serviceName": service_name,
        "isDeclared": is_declared_value,
        "declaredInstances": declared_instances,
        "cameraIds": camera_ids,
        "cameras": cameras,
    })
}

fn provider_service_name(declared_instances: &[String]) -> Option<String> {
    if declared_instances
        .iter()
        .any(|instance| instance == "internal/0")
    {
        return Some(DEFAULT_PROVIDER_SERVICE.to_owned());
    }
    declared_instances
        .first()
        .map(|instance| format!("{PROVIDER_INTERFACE}/{instance}"))
}

fn provider_camera_json(provider: &dyn ICameraProvider, camera_id: &str) -> Value {
    let device = match provider.get_camera_device_interface(camera_id) {
        Ok(device) => device,
        Err(status) => {
            return json!({
                "id": camera_id,
                "ok": false,
                "step": "getCameraDeviceInterface",
                "status": binder_status_json(&status),
            });
        }
    };

    let resource_cost = match device.get_resource_cost() {
        Ok(cost) => json!({
            "ok": true,
            "resourceCost": cost.resource_cost,
            "conflictingDevices": cost.conflicting_devices,
        }),
        Err(status) => json!({"ok": false, "status": binder_status_json(&status)}),
    };
    let characteristics = match device.get_camera_characteristics() {
        Ok(characteristics) => json!({
            "ok": true,
            "metadataBytes": characteristics.metadata.len(),
            "hexPreview": hex_preview(&characteristics.metadata, 48),
        }),
        Err(status) => json!({"ok": false, "status": binder_status_json(&status)}),
    };

    json!({
        "id": camera_id,
        "ok": true,
        "resourceCost": resource_cost,
        "characteristics": characteristics,
    })
}

fn probe_dependency_closure(hal_path: &str) -> Value {
    json!({
        "candidateLibraries": candidate_libraries(hal_path),
        "supportLibraryLoads": [
            probe_support_dlopen("libbinder_ndk.so"),
            probe_support_dlopen("libhidlbase.so"),
            probe_support_dlopen("libhardware.so"),
            probe_support_dlopen("libnativewindow.so"),
            probe_support_dlopen("libgralloctypes.so"),
        ],
        "androidProperties": command_lines_json("getprop", &[], &["camera", "cam.", "persist.vendor.camera", "vendor.camera"]),
        "serviceManager": command_lines_json("service", &["list"], &["camera", "graphics", "allocator"]),
        "halServiceManager": command_lines_json("lshal", &["--neat"], &["camera", "graphics", "allocator"]),
        "providerProcesses": command_lines_json("ps", &["-A"], &["camera", "provider", "cameraserver"]),
        "deviceNodes": [
            file_json(Path::new("/dev/binder")),
            file_json(Path::new("/dev/hwbinder")),
            file_json(Path::new("/dev/vndbinder")),
            file_json(Path::new("/dev/dma_heap/system")),
            file_json(Path::new("/dev/ion")),
            file_json(Path::new("/dev/sync")),
            file_json(Path::new("/dev/video1")),
        ],
        "linkerConfig": {
            "linkerconfigDir": file_json(Path::new("/linkerconfig")),
            "ldConfig": file_json(Path::new("/linkerconfig/ld.config.txt")),
        },
    })
}

fn frame_blocker(provider_ok: bool, direct_load_ok: bool) -> &'static str {
    if provider_ok && direct_load_ok {
        "provider service can list cameras and direct HAL loads, but direct frame capture still needs a contained camera_module_t/open shim plus native-handle and gralloc policy"
    } else if provider_ok {
        "provider service can list cameras; direct HAL capture remains blocked on loading/instantiating the vendor HAL outside its provider process"
    } else if direct_load_ok {
        "direct HAL loads, but no contained Rust-facing camera list/capture shim exists yet"
    } else {
        "neither provider-service listing nor direct HAL loading succeeded in this probe"
    }
}
