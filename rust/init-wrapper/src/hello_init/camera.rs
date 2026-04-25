use super::*;

pub(super) fn c_string_from_ptr(ptr: *const libc::c_char) -> Option<String> {
    if ptr.is_null() {
        None
    } else {
        Some(
            unsafe { CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned(),
        )
    }
}

pub(super) fn dl_error_message(prefix: &str) -> String {
    let error = unsafe { libc::dlerror() };
    if error.is_null() {
        prefix.to_string()
    } else {
        format!(
            "{}: {}",
            prefix,
            unsafe { CStr::from_ptr(error) }.to_string_lossy()
        )
    }
}

pub(super) fn camera_boot_hal_path_status_json(path: &str) -> String {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            let file_type = if metadata.file_type().is_char_device() {
                "char"
            } else if metadata.file_type().is_block_device() {
                "block"
            } else if metadata.file_type().is_symlink() {
                "symlink"
            } else if metadata.file_type().is_dir() {
                "dir"
            } else if metadata.file_type().is_file() {
                "file"
            } else {
                "other"
            };
            format!(
                "{{\"path\":{},\"exists\":true,\"type\":{},\"mode\":\"{:o}\",\"uid\":{},\"gid\":{},\"size\":{}}}",
                json_string(path),
                json_string(file_type),
                metadata.mode() & 0o7777,
                metadata.uid(),
                metadata.gid(),
                metadata.len()
            )
        }
        Err(error) => format!(
            "{{\"path\":{},\"exists\":false,\"errno\":{},\"error\":{}}}",
            json_string(path),
            error.raw_os_error().unwrap_or(0),
            json_string(&error.to_string())
        ),
    }
}

pub(super) fn push_camera_boot_hal_stage(
    stages: &mut Vec<String>,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
    stage: &str,
    status: &str,
    detail: &str,
) {
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        &format!("{stage}-{status}"),
    );
    stages.push(format!(
        "{{\"stage\":{},\"status\":{},\"detail\":{}}}",
        json_string(stage),
        json_string(status),
        json_string(detail)
    ));
}

pub(super) fn write_camera_boot_hal_summary(summary: &str) -> io::Result<()> {
    let temp_path = Path::new(ORANGE_GPU_ROOT).join(".camera-boot-hal-summary.json.tmp");
    write_atomic_text_file(&temp_path, Path::new(ORANGE_GPU_SUMMARY_PATH), summary)
}

pub(super) fn run_camera_hal_bionic_probe_helper(
    config: &Config,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
    stages: &mut Vec<String>,
) -> Option<i32> {
    if !Path::new(CAMERA_HAL_BIONIC_PROBE_PATH).is_file()
        || !Path::new(CAMERA_HAL_BIONIC_LINKER_PATH).is_file()
    {
        return None;
    }

    push_camera_boot_hal_stage(
        stages,
        probe_stage_path,
        probe_stage_prefix,
        "link",
        "bionic-helper-start",
        CAMERA_HAL_BIONIC_PROBE_PATH,
    );
    remove_file_best_effort(CAMERA_HAL_BIONIC_PROBE_SUMMARY_PATH);
    remove_file_best_effort(CAMERA_HAL_BIONIC_PROBE_OUTPUT_PATH);

    let mut command = Command::new(CAMERA_HAL_BIONIC_LINKER_PATH);
    command.arg(CAMERA_HAL_BIONIC_PROBE_PATH);
    command.arg("--output");
    command.arg(CAMERA_HAL_BIONIC_PROBE_SUMMARY_PATH);
    command.arg("--run-token");
    command.arg(run_token_or_unset(config));
    command.arg("--camera-id");
    command.arg(&config.camera_hal_camera_id);
    command.arg("--dev-mount");
    command.arg(&config.dev_mount);
    command.arg("--mount-dev");
    command.arg(bool_word(config.mount_dev));
    command.arg("--mount-proc");
    command.arg(bool_word(config.mount_proc));
    command.arg("--mount-sys");
    command.arg(bool_word(config.mount_sys));
    command.arg("--call-open");
    command.arg(bool_word(config.camera_hal_call_open));
    command.arg("--child-timeout-secs");
    command.arg(
        resolve_watchdog_timeout(config)
            .saturating_sub(10)
            .max(1)
            .to_string(),
    );
    command.env(LD_LIBRARY_PATH_ENV, CAMERA_HAL_BIONIC_LIBRARY_PATH);
    command.env("ANDROID_ROOT", "/system");
    command.env("ANDROID_DATA", "/data");
    command.env("LD_CONFIG_FILE", "/linkerconfig/ld.config.txt");
    if let Ok((stdout, stderr)) = redirect_output(CAMERA_HAL_BIONIC_PROBE_OUTPUT_PATH) {
        command.stdout(stdout);
        command.stderr(stderr);
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            log_line(&format!(
                "camera HAL bionic helper failed to spawn: {error}"
            ));
            return None;
        }
    };
    let watch_result = match wait_for_child_with_watchdog(
        &mut child,
        "camera-hal-bionic-probe",
        1,
        resolve_watchdog_timeout(config),
        true,
        None,
    ) {
        Ok(result) => result,
        Err(error) => {
            log_line(&format!("camera HAL bionic helper wait failed: {error}"));
            return None;
        }
    };
    if watch_result.timed_out {
        log_line("camera HAL bionic helper timed out before writing a summary");
        return None;
    }
    if watch_result.exit_status != Some(0) {
        log_line(&format!(
            "camera HAL bionic helper exited nonzero: {:?}",
            watch_result.exit_status
        ));
    }

    match fs::read_to_string(CAMERA_HAL_BIONIC_PROBE_SUMMARY_PATH) {
        Ok(summary) => match write_camera_boot_hal_summary(&summary) {
            Ok(()) => Some(0),
            Err(error) => {
                log_line(&format!(
                    "failed to persist camera HAL bionic helper summary: {error}"
                ));
                Some(1)
            }
        },
        Err(error) => {
            log_line(&format!(
                "camera HAL bionic helper did not write a readable summary: {error}"
            ));
            None
        }
    }
}

pub(super) fn run_camera_hal_link_probe_internal(
    config: &Config,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> i32 {
    let mut stages = Vec::new();
    let path_probe_targets = [
        CAMERA_HAL_PATH,
        "/vendor",
        "/vendor/lib64",
        "/vendor/lib64/hw",
        "/system/lib64/libhardware.so",
        "/system/lib64/libcamera_metadata.so",
        "/apex/com.android.runtime/bin/linker64",
        "/linkerconfig/ld.config.txt",
        "/dev/binder",
        "/dev/hwbinder",
        "/dev/vndbinder",
        "/dev/video0",
        "/dev/video1",
        "/dev/media0",
        "/dev/dma_heap/system",
    ];
    let path_statuses = path_probe_targets
        .iter()
        .map(|path| camera_boot_hal_path_status_json(path))
        .collect::<Vec<_>>()
        .join(",\n    ");

    let mut link_json =
        "{\"attempted\":false,\"ok\":false,\"handle\":null,\"error\":null}".to_string();
    let mut hmi_json =
        "{\"attempted\":false,\"ok\":false,\"address\":null,\"error\":null}".to_string();
    let mut module_json = "{\"attempted\":false,\"ok\":false,\"cameraCount\":null}".to_string();
    let mut open_json =
        "{\"attempted\":false,\"ok\":false,\"ready\":false,\"blocker\":\"not reached\"}"
            .to_string();
    let configure_json =
        "{\"attempted\":false,\"ok\":false,\"blocker\":\"not reached\"}".to_string();
    let request_json = "{\"attempted\":false,\"ok\":false,\"blocker\":\"not reached\"}".to_string();
    let mut blocker_stage = "link";
    let mut blocker = "vendor camera HAL path is not visible in Shadow boot userspace";
    let mut next_step = "mount or stage the vendor partition plus the Android bionic/linker namespace before attempting HMI/open";

    push_camera_boot_hal_stage(
        &mut stages,
        probe_stage_path,
        probe_stage_prefix,
        "link",
        "start",
        CAMERA_HAL_PATH,
    );
    if let Some(status) = run_camera_hal_bionic_probe_helper(
        config,
        probe_stage_path,
        probe_stage_prefix,
        &mut stages,
    ) {
        return status;
    }

    let hal_metadata = fs::metadata(CAMERA_HAL_PATH);
    let hal_file_visible = match &hal_metadata {
        Ok(metadata) => metadata.is_file(),
        Err(_) => false,
    };
    if !hal_file_visible {
        let detail = match hal_metadata {
            Ok(_) => "path resolves but is not a regular file".to_string(),
            Err(error) => error.to_string(),
        };
        link_json = format!(
            "{{\"attempted\":false,\"ok\":false,\"handle\":null,\"error\":{},\"fileVisible\":false}}",
            json_string(&detail)
        );
        push_camera_boot_hal_stage(
            &mut stages,
            probe_stage_path,
            probe_stage_prefix,
            "link",
            "blocked",
            "vendor HAL file missing from boot namespace",
        );
    } else {
        let path_c = CString::new(CAMERA_HAL_PATH).expect("static camera HAL path CString");
        let handle = unsafe {
            let _ = libc::dlerror();
            libc::dlopen(path_c.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL)
        };
        if handle.is_null() {
            let error = dl_error_message("dlopen camera HAL");
            link_json = format!(
                "{{\"attempted\":true,\"ok\":false,\"handle\":null,\"error\":{}}}",
                json_string(&error)
            );
            blocker = "dlopen failed from Shadow boot userspace";
            next_step = "provide the Android bionic linker namespace and dependent vendor/system/apex libraries without starting cameraserver";
            push_camera_boot_hal_stage(
                &mut stages,
                probe_stage_path,
                probe_stage_prefix,
                "link",
                "blocked",
                &error,
            );
        } else {
            link_json = format!(
                "{{\"attempted\":true,\"ok\":true,\"handle\":{},\"error\":null}}",
                json_pointer(handle)
            );
            push_camera_boot_hal_stage(
                &mut stages,
                probe_stage_path,
                probe_stage_prefix,
                "link",
                "ok",
                "dlopen succeeded",
            );

            push_camera_boot_hal_stage(
                &mut stages,
                probe_stage_path,
                probe_stage_prefix,
                "hmi",
                "start",
                "dlsym HMI",
            );
            let symbol = CString::new("HMI").expect("static HMI symbol CString");
            let hmi_ptr = unsafe {
                let _ = libc::dlerror();
                libc::dlsym(handle, symbol.as_ptr())
            };
            if hmi_ptr.is_null() {
                let error = dl_error_message("dlsym HMI");
                hmi_json = format!(
                    "{{\"attempted\":true,\"ok\":false,\"address\":null,\"error\":{}}}",
                    json_string(&error)
                );
                blocker_stage = "hmi";
                blocker = "camera HAL loaded but did not expose HAL_MODULE_INFO_SYM/HMI";
                next_step = "verify the vendor HAL export surface and whether the direct path needs hw_get_module-style loading";
                push_camera_boot_hal_stage(
                    &mut stages,
                    probe_stage_path,
                    probe_stage_prefix,
                    "hmi",
                    "blocked",
                    &error,
                );
            } else {
                let module = unsafe { &*(hmi_ptr as *const CameraModulePartial) };
                let id = c_string_from_ptr(module.common.id);
                let name = c_string_from_ptr(module.common.name);
                let author = c_string_from_ptr(module.common.author);
                hmi_json = format!(
                    "{{\"attempted\":true,\"ok\":true,\"address\":{},\"tag\":{},\"moduleApiVersion\":{},\"halApiVersion\":{},\"id\":{},\"name\":{},\"author\":{},\"methods\":{}}}",
                    json_pointer(hmi_ptr),
                    module.common.tag,
                    module.common.module_api_version,
                    module.common.hal_api_version,
                    json_optional_string(id.clone()),
                    json_optional_string(name),
                    json_optional_string(author),
                    json_pointer(module.common.methods as *mut libc::c_void)
                );
                push_camera_boot_hal_stage(
                    &mut stages,
                    probe_stage_path,
                    probe_stage_prefix,
                    "hmi",
                    "ok",
                    "HMI identified",
                );

                push_camera_boot_hal_stage(
                    &mut stages,
                    probe_stage_path,
                    probe_stage_prefix,
                    "module",
                    "start",
                    "camera_module_t prefix",
                );
                let mut camera_count_json = "null".to_string();
                let mut camera_info_json = "null".to_string();
                if let Some(get_number_of_cameras) = module.get_number_of_cameras {
                    let count = unsafe { get_number_of_cameras() };
                    camera_count_json = count.to_string();
                    if count > 0 {
                        if let Some(get_camera_info) = module.get_camera_info {
                            let mut info = std::mem::MaybeUninit::<CameraInfoPartial>::zeroed();
                            let status = unsafe { get_camera_info(0, info.as_mut_ptr()) };
                            if status == 0 {
                                let info = unsafe { info.assume_init() };
                                camera_info_json = format!(
                                    "{{\"attempted\":true,\"status\":0,\"facing\":{},\"orientation\":{},\"deviceVersion\":{},\"staticMetadata\":{},\"resourceCost\":{},\"conflictingDevicesLength\":{}}}",
                                    info.facing,
                                    info.orientation,
                                    info.device_version,
                                    json_pointer(info.static_camera_characteristics as *mut libc::c_void),
                                    info.resource_cost,
                                    info.conflicting_devices_length
                                );
                            } else {
                                camera_info_json = format!(
                                    "{{\"attempted\":true,\"status\":{},\"ok\":false}}",
                                    status
                                );
                            }
                        }
                    }
                }
                let module_ok = id.as_deref() == Some("camera") && !module.common.methods.is_null();
                module_json = format!(
                    "{{\"attempted\":true,\"ok\":{},\"id\":{},\"methodsPresent\":{},\"getNumberOfCamerasPresent\":{},\"getCameraInfoPresent\":{},\"cameraCount\":{},\"camera0\":{}}}",
                    bool_word(module_ok),
                    json_optional_string(id),
                    bool_word(!module.common.methods.is_null()),
                    bool_word(module.get_number_of_cameras.is_some()),
                    bool_word(module.get_camera_info.is_some()),
                    camera_count_json,
                    camera_info_json
                );
                if module_ok {
                    push_camera_boot_hal_stage(
                        &mut stages,
                        probe_stage_path,
                        probe_stage_prefix,
                        "module",
                        "ok",
                        "camera_module_t prefix readable",
                    );
                    let open_ready = unsafe { (*module.common.methods).open.is_some() };
                    open_json = format!(
                        "{{\"attempted\":false,\"ok\":false,\"ready\":{},\"cameraId\":{},\"blocker\":{}}}",
                        bool_word(open_ready),
                        json_string(&config.camera_hal_camera_id),
                        json_string("first boot probe stops before invoking camera_module_t.open; next slice must own close/error recovery plus native buffer, fence, and gralloc policy")
                    );
                    blocker_stage = "open";
                    blocker = "HMI/module is reachable, but direct camera_module_t.open/configure/request is intentionally left to the next contained shim slice";
                    next_step = "add a tiny open/close shim with watchdog-safe cleanup, then wire camera3 stream configuration and a single native buffer request";
                    push_camera_boot_hal_stage(
                        &mut stages,
                        probe_stage_path,
                        probe_stage_prefix,
                        "open",
                        "blocked",
                        "open shim not invoked in this boot-safe probe",
                    );
                } else {
                    blocker_stage = "module";
                    blocker =
                        "HMI was found but did not look like a camera module with usable methods";
                    next_step = "tighten the camera_module_t shim against the vendor module layout before open/configure/request";
                    push_camera_boot_hal_stage(
                        &mut stages,
                        probe_stage_path,
                        probe_stage_prefix,
                        "module",
                        "blocked",
                        "camera module prefix unusable",
                    );
                }
            }
        }
    }

    if blocker_stage != "open" {
        push_camera_boot_hal_stage(
            &mut stages,
            probe_stage_path,
            probe_stage_prefix,
            "open",
            "not-reached",
            blocker,
        );
    }
    push_camera_boot_hal_stage(
        &mut stages,
        probe_stage_path,
        probe_stage_prefix,
        "configure",
        "not-reached",
        blocker,
    );
    push_camera_boot_hal_stage(
        &mut stages,
        probe_stage_path,
        probe_stage_prefix,
        "request",
        "not-reached",
        blocker,
    );

    let summary = format!(
        concat!(
            "{{\n",
            "  \"schemaVersion\": 1,\n",
            "  \"kind\": \"camera-boot-hal-probe\",\n",
            "  \"mode\": \"camera-hal-link-probe\",\n",
            "  \"pid\": {},\n",
            "  \"runToken\": {},\n",
            "  \"halPath\": {},\n",
            "  \"cameraId\": {},\n",
            "  \"mounts\": {{\"dev\": {}, \"proc\": {}, \"sys\": {}, \"devMount\": {}}},\n",
            "  \"androidCameraApiUse\": {{\"ICameraProvider\": false, \"cameraserver\": false, \"javaCamera2\": false, \"rootedAndroidShellCameraApi\": false, \"rootedAndroidShellRecoveryOnly\": true}},\n",
            "  \"pathStatus\": [\n    {}\n  ],\n",
            "  \"stages\": [\n    {}\n  ],\n",
            "  \"link\": {},\n",
            "  \"hmi\": {},\n",
            "  \"module\": {},\n",
            "  \"open\": {},\n",
            "  \"configure\": {},\n",
            "  \"request\": {},\n",
            "  \"frameCapture\": {{\"attempted\": false, \"captured\": false, \"artifactPath\": null}},\n",
            "  \"blockerStage\": {},\n",
            "  \"blocker\": {},\n",
            "  \"nextStep\": {}\n",
            "}}\n"
        ),
        process::id(),
        json_string(run_token_or_unset(config)),
        json_string(CAMERA_HAL_PATH),
        json_string(&config.camera_hal_camera_id),
        bool_word(config.mount_dev),
        bool_word(config.mount_proc),
        bool_word(config.mount_sys),
        json_string(&config.dev_mount),
        path_statuses,
        stages.join(",\n    "),
        link_json,
        hmi_json,
        module_json,
        open_json,
        configure_json,
        request_json,
        json_string(blocker_stage),
        json_string(blocker),
        json_string(next_step)
    );

    match write_camera_boot_hal_summary(&summary) {
        Ok(()) => 0,
        Err(error) => {
            log_line(&format!("failed to write camera boot HAL summary: {error}"));
            1
        }
    }
}
