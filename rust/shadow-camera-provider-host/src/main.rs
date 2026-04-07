#[cfg(target_os = "android")]
mod android_service;
#[cfg(target_os = "android")]
mod camera_aidl;

#[cfg(target_os = "android")]
use android_service::{
    get_declared_instances, is_declared, set_thread_pool_max_thread_count, start_thread_pool,
    wait_for_interface,
};
#[cfg(target_os = "android")]
use camera_aidl::device::{self, ICameraDeviceCallback, RequestTemplate};
#[cfg(target_os = "android")]
use camera_aidl::provider::{self, ICameraProvider, ICameraProviderCallback};
use serde_json::json;
use std::env;
use std::ffi::OsString;
#[cfg(target_os = "android")]
use std::sync::{Arc, Mutex};
#[cfg(target_os = "android")]
use std::time::Duration;

#[cfg(not(target_os = "android"))]
fn main() {
    let mut args = env::args_os();
    let _program = args.next();
    let command = args.next().unwrap_or_else(|| OsString::from("ping"));
    let argv: Vec<OsString> = args.collect();
    let response = json!({
        "ok": false,
        "command": command.to_string_lossy().into_owned(),
        "pid": std::process::id(),
        "cwd": current_dir_string(),
        "argv": argv_strings(&argv),
        "error": "shadow-camera-provider-host only supports target_os=android",
    });
    println!("{}", serde_json::to_string(&response).unwrap());
}

#[cfg(target_os = "android")]
fn main() {
    let mut args = env::args_os();
    let _program = args.next();
    let command = args.next().unwrap_or_else(|| OsString::from("ping"));
    let argv: Vec<OsString> = args.collect();

    let response = match command.to_string_lossy().as_ref() {
        "ping" => make_response("ping", &argv),
        "info" => make_response("info", &argv),
        "list" => make_list_response(&argv),
        "open" => make_open_response(&argv),
        other => make_error(other, &argv, "unsupported command"),
    };

    println!(
        "{}",
        serde_json::to_string(&response).unwrap_or_else(|error| {
            format!(
                "{{\"ok\":false,\"command\":\"serialize\",\"error\":\"{}\"}}",
                escape_json(&error.to_string())
            )
        })
    );
}

#[cfg(target_os = "android")]
fn make_response(command: &str, argv: &[OsString]) -> serde_json::Value {
    json!({
        "ok": true,
        "command": command,
        "pid": std::process::id(),
        "cwd": current_dir_string(),
        "argv": argv_strings(argv),
    })
}

#[cfg(target_os = "android")]
fn make_error(command: &str, argv: &[OsString], error: &str) -> serde_json::Value {
    json!({
        "ok": false,
        "command": command,
        "pid": std::process::id(),
        "cwd": current_dir_string(),
        "argv": argv_strings(argv),
        "error": error,
    })
}

#[cfg(target_os = "android")]
fn make_list_response(argv: &[OsString]) -> serde_json::Value {
    set_thread_pool_max_thread_count(1);
    start_thread_pool();

    let argv_strings = argv_strings(argv);
    let interface_name = "android.hardware.camera.provider.ICameraProvider";
    let declared_instances: Vec<String> = match get_declared_instances(interface_name) {
        Ok(instances) => instances,
        Err(status) => return command_error("list", argv, "get_declared_instances", &status),
    };

    let (service_name, requested_camera) = resolve_provider_args(&argv_strings);

    let is_declared_value = match is_declared(&service_name) {
        Ok(value) => value,
        Err(status) => {
            return command_error_with_context(
                "list",
                argv,
                "is_declared",
                &status,
                Some(&declared_instances),
                &service_name,
            );
        }
    };

    let provider: binder::Strong<dyn ICameraProvider> =
        match wait_for_interface::<dyn ICameraProvider>(&service_name) {
            Ok(provider) => provider,
            Err(status) => {
                return command_error_with_context(
                    "list",
                    argv,
                    "wait_for_interface",
                    &status,
                    Some(&declared_instances),
                    &service_name,
                );
            }
        };

    let callback_log = Arc::new(Mutex::new(Vec::new()));
    let callback = provider::new_callback(CallbackRecorder {
        events: Arc::clone(&callback_log),
    });

    if let Err(status) = provider.set_callback(&callback) {
        return command_error_with_context(
            "list",
            argv,
            "set_callback",
            &status,
            Some(&declared_instances),
            &service_name,
        );
    }

    std::thread::sleep(Duration::from_millis(250));

    let camera_ids: Vec<String> = match provider.get_camera_id_list() {
        Ok(camera_ids) => camera_ids,
        Err(status) => {
            return command_error_with_context(
                "list",
                argv,
                "get_camera_id_list",
                &status,
                Some(&declared_instances),
                &service_name,
            );
        }
    };

    let selected_camera = select_camera(&camera_ids);
    let mut selected_resource_cost = None;
    let mut selected_characteristics = None;

    if let Some(camera_id) = selected_camera.as_deref() {
        match provider.get_camera_device_interface(camera_id) {
            Ok(device) => {
                match device.get_resource_cost() {
                    Ok(resource_cost) => {
                        selected_resource_cost = Some(json!({
                            "resourceCost": resource_cost.resource_cost,
                            "conflictingDevices": resource_cost.conflicting_devices,
                        }));
                    }
                    Err(status) => selected_resource_cost = Some(status_json(&status)),
                }

                match device.get_camera_characteristics() {
                    Ok(characteristics) => {
                        selected_characteristics = Some(json!({
                            "bytes": characteristics.metadata.len(),
                            "hexPreview": hex_preview(&characteristics.metadata, 48),
                        }));
                    }
                    Err(status) => selected_characteristics = Some(status_json(&status)),
                }
            }
            Err(status) => {
                return command_error_with_context(
                    "list",
                    argv,
                    "get_camera_device_interface",
                    &status,
                    Some(&declared_instances),
                    &service_name,
                );
            }
        }
    }

    std::thread::sleep(Duration::from_millis(250));

    let callback_events = callback_log
        .lock()
        .map(|events| events.clone())
        .unwrap_or_default();

    json!({
        "ok": true,
        "command": "list",
        "pid": std::process::id(),
        "cwd": current_dir_string(),
        "argv": argv_strings,
        "interface": interface_name,
        "serviceName": service_name,
        "isDeclared": is_declared_value,
        "declaredInstances": declared_instances,
        "cameraIds": camera_ids,
        "requestedCamera": requested_camera,
        "selectedCamera": selected_camera,
        "selectedResourceCost": selected_resource_cost,
        "selectedCharacteristics": selected_characteristics,
        "callbackEvents": callback_events,
    })
}

#[cfg(target_os = "android")]
fn make_open_response(argv: &[OsString]) -> serde_json::Value {
    set_thread_pool_max_thread_count(1);
    start_thread_pool();

    let argv_strings = argv_strings(argv);
    let interface_name = "android.hardware.camera.provider.ICameraProvider";
    let declared_instances: Vec<String> = match get_declared_instances(interface_name) {
        Ok(instances) => instances,
        Err(status) => return command_error("open", argv, "get_declared_instances", &status),
    };

    let (service_name, requested_camera) = resolve_provider_args(&argv_strings);
    let is_declared_value = match is_declared(&service_name) {
        Ok(value) => value,
        Err(status) => {
            return command_error_with_context(
                "open",
                argv,
                "is_declared",
                &status,
                Some(&declared_instances),
                &service_name,
            );
        }
    };

    let provider: binder::Strong<dyn ICameraProvider> =
        match wait_for_interface::<dyn ICameraProvider>(&service_name) {
            Ok(provider) => provider,
            Err(status) => {
                return command_error_with_context(
                    "open",
                    argv,
                    "wait_for_interface",
                    &status,
                    Some(&declared_instances),
                    &service_name,
                );
            }
        };

    let provider_callback_log = Arc::new(Mutex::new(Vec::new()));
    let provider_callback = provider::new_callback(CallbackRecorder {
        events: Arc::clone(&provider_callback_log),
    });

    if let Err(status) = provider.set_callback(&provider_callback) {
        return command_error_with_context(
            "open",
            argv,
            "set_callback",
            &status,
            Some(&declared_instances),
            &service_name,
        );
    }

    if let Err(status) = provider.notify_device_state_change(provider::DEVICE_STATE_NORMAL) {
        return command_error_with_context(
            "open",
            argv,
            "notify_device_state_change",
            &status,
            Some(&declared_instances),
            &service_name,
        );
    }

    std::thread::sleep(Duration::from_millis(250));

    let camera_ids: Vec<String> = match provider.get_camera_id_list() {
        Ok(camera_ids) => camera_ids,
        Err(status) => {
            return command_error_with_context(
                "open",
                argv,
                "get_camera_id_list",
                &status,
                Some(&declared_instances),
                &service_name,
            );
        }
    };

    let selected_camera = requested_camera
        .clone()
        .or_else(|| select_camera(&camera_ids));
    let Some(camera_id) = selected_camera.clone() else {
        return json!({
            "ok": false,
            "command": "open",
            "pid": std::process::id(),
            "cwd": current_dir_string(),
            "argv": argv_strings,
            "serviceName": service_name,
            "declaredInstances": declared_instances,
            "cameraIds": camera_ids,
            "error": "no camera devices returned by provider",
        });
    };

    let device = match provider.get_camera_device_interface(&camera_id) {
        Ok(device) => device,
        Err(status) => {
            return command_error_with_context(
                "open",
                argv,
                "get_camera_device_interface",
                &status,
                Some(&declared_instances),
                &service_name,
            );
        }
    };

    let selected_resource_cost = match device.get_resource_cost() {
        Ok(resource_cost) => json!({
            "resourceCost": resource_cost.resource_cost,
            "conflictingDevices": resource_cost.conflicting_devices,
        }),
        Err(status) => status_json(&status),
    };

    let selected_characteristics = match device.get_camera_characteristics() {
        Ok(characteristics) => json!({
            "bytes": characteristics.metadata.len(),
            "hexPreview": hex_preview(&characteristics.metadata, 48),
        }),
        Err(status) => status_json(&status),
    };

    let device_default_request_settings = match device
        .construct_default_request_settings(RequestTemplate::STILL_CAPTURE)
    {
        Ok(settings) => Some(json!({
            "source": "device",
            "template": "STILL_CAPTURE",
            "templateValue": RequestTemplate::STILL_CAPTURE.0,
            "bytes": settings.metadata.len(),
            "hexPreview": hex_preview(&settings.metadata, 48),
        })),
        Err(status) => Some(status_json(&status)),
    };

    let device_callback_log = Arc::new(Mutex::new(Vec::new()));
    let device_callback = device::new_callback(DeviceCallbackRecorder {
        events: Arc::clone(&device_callback_log),
    });

    let session = match device.open(&device_callback) {
        Ok(session) => session,
        Err(status) => {
            return command_error_with_context(
                "open",
                argv,
                "open",
                &status,
                Some(&declared_instances),
                &service_name,
            );
        }
    };

    let default_request_settings = match session
        .construct_default_request_settings(RequestTemplate::STILL_CAPTURE)
    {
        Ok(settings) => json!({
            "source": "session",
            "template": "STILL_CAPTURE",
            "templateValue": RequestTemplate::STILL_CAPTURE.0,
            "bytes": settings.metadata.len(),
            "hexPreview": hex_preview(&settings.metadata, 48),
        }),
        Err(status) => {
            return command_error_with_context(
                "open",
                argv,
                "session_construct_default_request_settings",
                &status,
                Some(&declared_instances),
                &service_name,
            );
        }
    };

    let session_closed = match session.close() {
        Ok(()) => true,
        Err(status) => {
            return command_error_with_context(
                "open",
                argv,
                "close",
                &status,
                Some(&declared_instances),
                &service_name,
            );
        }
    };

    std::thread::sleep(Duration::from_millis(250));

    let provider_callback_events = provider_callback_log
        .lock()
        .map(|events| events.clone())
        .unwrap_or_default();
    let device_callback_events = device_callback_log
        .lock()
        .map(|events| events.clone())
        .unwrap_or_default();

    json!({
        "ok": true,
        "command": "open",
        "pid": std::process::id(),
        "cwd": current_dir_string(),
        "argv": argv_strings,
        "interface": interface_name,
        "serviceName": service_name,
        "isDeclared": is_declared_value,
        "declaredInstances": declared_instances,
        "cameraIds": camera_ids,
        "requestedCamera": requested_camera,
        "selectedCamera": camera_id,
        "selectedResourceCost": selected_resource_cost,
        "selectedCharacteristics": selected_characteristics,
        "deviceState": "DEVICE_STATE_NORMAL",
        "deviceDefaultRequestSettings": device_default_request_settings,
        "defaultRequestSettings": default_request_settings,
        "sessionOpened": true,
        "sessionClosed": session_closed,
        "providerCallbackEvents": provider_callback_events,
        "deviceCallbackEvents": device_callback_events,
    })
}

#[cfg(target_os = "android")]
fn command_error(command: &str, argv: &[OsString], step: &str, status: &binder::Status) -> serde_json::Value {
    command_error_with_context(command, argv, step, status, None, "")
}

#[cfg(target_os = "android")]
fn command_error_with_context(
    command: &str,
    argv: &[OsString],
    step: &str,
    status: &binder::Status,
    declared_instances: Option<&[String]>,
    service_name: &str,
) -> serde_json::Value {
    let mut value = json!({
        "ok": false,
        "command": command,
        "pid": std::process::id(),
        "cwd": current_dir_string(),
        "argv": argv_strings(argv),
        "step": step,
        "serviceName": service_name,
        "status": status_json(status),
    });

    if let Some(instances) = declared_instances {
        value["declaredInstances"] = json!(instances);
    }

    value
}

#[cfg(target_os = "android")]
fn status_json(status: &binder::Status) -> serde_json::Value {
    json!({
        "description": status.get_description(),
        "exceptionCode": format!("{:?}", status.exception_code()),
        "transactionError": format!("{:?}", status.transaction_error()),
        "serviceSpecificError": status.service_specific_error(),
    })
}

#[cfg(target_os = "android")]
fn select_camera(camera_ids: &[String]) -> Option<String> {
    camera_ids
        .iter()
        .find(|camera_id| camera_id.ends_with("/0"))
        .cloned()
        .or_else(|| camera_ids.first().cloned())
}

#[cfg(target_os = "android")]
fn resolve_provider_args(argv: &[String]) -> (String, Option<String>) {
    const DEFAULT_SERVICE: &str =
        "android.hardware.camera.provider.ICameraProvider/internal/0";
    const PROVIDER_PREFIX: &str = "android.hardware.camera.provider.ICameraProvider/";

    match argv.first() {
        Some(first) if first.starts_with(PROVIDER_PREFIX) => {
            (first.clone(), argv.get(1).cloned())
        }
        Some(first) => (String::from(DEFAULT_SERVICE), Some(first.clone())),
        None => (String::from(DEFAULT_SERVICE), None),
    }
}

fn argv_strings(argv: &[OsString]) -> Vec<String> {
    argv.iter()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect()
}

fn current_dir_string() -> Option<String> {
    env::current_dir()
        .ok()
        .map(|cwd| cwd.to_string_lossy().into_owned())
}

#[cfg(target_os = "android")]
fn hex_preview(bytes: &[u8], limit: usize) -> String {
    let mut preview = String::with_capacity(limit * 2 + if bytes.len() > limit { 3 } else { 0 });
    for byte in bytes.iter().take(limit) {
        preview.push(nibble_to_hex(byte >> 4));
        preview.push(nibble_to_hex(byte & 0x0f));
    }
    if bytes.len() > limit {
        preview.push_str("...");
    }
    preview
}

#[cfg(target_os = "android")]
fn nibble_to_hex(nibble: u8) -> char {
    match nibble {
        0..=9 => (b'0' + nibble) as char,
        10..=15 => (b'a' + nibble - 10) as char,
        _ => '?',
    }
}

#[cfg(target_os = "android")]
fn escape_json(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\u{08}' => escaped.push_str("\\b"),
            '\u{0C}' => escaped.push_str("\\f"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            c if c.is_control() => escaped.push('?'),
            c => escaped.push(c),
        }
    }
    escaped
}

#[cfg(target_os = "android")]
#[derive(Clone, Debug, serde::Serialize)]
struct CallbackEvent {
    kind: String,
    #[serde(rename = "cameraDeviceName")]
    camera_device_name: String,
    #[serde(rename = "physicalCameraDeviceName")]
    physical_camera_device_name: Option<String>,
    status: i32,
    #[serde(rename = "statusDebug")]
    status_debug: String,
}

#[cfg(target_os = "android")]
#[derive(Clone)]
struct CallbackRecorder {
    events: Arc<Mutex<Vec<CallbackEvent>>>,
}

#[cfg(target_os = "android")]
impl binder::Interface for CallbackRecorder {}

#[cfg(target_os = "android")]
impl ICameraProviderCallback for CallbackRecorder {
    fn camera_device_status_change(
        &self,
        camera_device_name: &str,
        new_status: camera_aidl::common::CameraDeviceStatus,
    ) -> binder::Result<()> {
        self.push_event(CallbackEvent {
            kind: String::from("cameraDeviceStatusChange"),
            camera_device_name: camera_device_name.to_owned(),
            physical_camera_device_name: None,
            status: new_status.0,
            status_debug: format!("{:?}", new_status),
        });
        Ok(())
    }

    fn torch_mode_status_change(
        &self,
        camera_device_name: &str,
        new_status: camera_aidl::common::TorchModeStatus,
    ) -> binder::Result<()> {
        self.push_event(CallbackEvent {
            kind: String::from("torchModeStatusChange"),
            camera_device_name: camera_device_name.to_owned(),
            physical_camera_device_name: None,
            status: new_status.0,
            status_debug: format!("{:?}", new_status),
        });
        Ok(())
    }

    fn physical_camera_device_status_change(
        &self,
        camera_device_name: &str,
        physical_camera_device_name: &str,
        new_status: camera_aidl::common::CameraDeviceStatus,
    ) -> binder::Result<()> {
        self.push_event(CallbackEvent {
            kind: String::from("physicalCameraDeviceStatusChange"),
            camera_device_name: camera_device_name.to_owned(),
            physical_camera_device_name: Some(physical_camera_device_name.to_owned()),
            status: new_status.0,
            status_debug: format!("{:?}", new_status),
        });
        Ok(())
    }
}

#[cfg(target_os = "android")]
impl CallbackRecorder {
    fn push_event(&self, event: CallbackEvent) {
        if let Ok(mut events) = self.events.lock() {
            events.push(event);
        }
    }
}

#[cfg(target_os = "android")]
#[derive(Clone)]
struct DeviceCallbackRecorder {
    events: Arc<Mutex<Vec<String>>>,
}

#[cfg(target_os = "android")]
impl binder::Interface for DeviceCallbackRecorder {}

#[cfg(target_os = "android")]
impl ICameraDeviceCallback for DeviceCallbackRecorder {
    fn notify(&self) -> binder::Result<()> {
        self.push_event("notify");
        Ok(())
    }

    fn process_capture_result(&self) -> binder::Result<()> {
        self.push_event("processCaptureResult");
        Ok(())
    }

    fn request_stream_buffers(&self) -> binder::Result<()> {
        self.push_event("requestStreamBuffers");
        Err(binder::Status::new_service_specific_error_str(
            -38,
            Some("requestStreamBuffers is not implemented"),
        ))
    }

    fn return_stream_buffers(&self) -> binder::Result<()> {
        self.push_event("returnStreamBuffers");
        Ok(())
    }
}

#[cfg(target_os = "android")]
impl DeviceCallbackRecorder {
    fn push_event(&self, event: &str) {
        if let Ok(mut events) = self.events.lock() {
            events.push(String::from(event));
        }
    }
}
