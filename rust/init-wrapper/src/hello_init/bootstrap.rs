use super::*;

pub(super) fn bootstrap_tmpfs_dev_runtime(config: &Config) -> io::Result<()> {
    if !config.mount_dev || config.dev_mount != "tmpfs" {
        return Ok(());
    }
    ensure_char_device(Path::new("/dev/null"), 0o666, 1, 3)?;
    ensure_char_device(Path::new("/dev/console"), 0o600, 5, 1)?;
    if config.log_kmsg {
        ensure_char_device(Path::new("/dev/kmsg"), 0o600, 1, 11)?;
    }
    if config.log_pmsg {
        ensure_char_device(Path::new("/dev/pmsg0"), 0o222, 250, 0)?;
    }
    ensure_stdio_fds()
}

pub(super) fn bootstrap_proc_stdio_links(config: &Config) -> io::Result<()> {
    if !config.mount_dev || !config.mount_proc || config.dev_mount != "tmpfs" {
        return Ok(());
    }
    ensure_symlink_target(Path::new("/dev/stdin"), Path::new("/proc/self/fd/0"))?;
    ensure_symlink_target(Path::new("/dev/stdout"), Path::new("/proc/self/fd/1"))?;
    ensure_symlink_target(Path::new("/dev/stderr"), Path::new("/proc/self/fd/2"))?;
    Ok(())
}

pub(super) fn android_ipc_nodes_for_config(config: &Config) -> &'static [&'static str] {
    if config.wifi_bootstrap == "sunfish-wlan0" {
        return match config.wifi_helper_profile.as_str() {
            "aidl-sm-core" => &["binder"],
            "vnd-sm-core" => &["vndbinder"],
            // Proven Pixel 4a scan seam: vndservicemanager owns the
            // vendor Binder registry for PM/CNSS, while /dev/binder is
            // only exposed so vendor wpa_supplicant's AIDL ProcessState
            // can initialize. No framework servicemanager is started.
            "vnd-sm-core-binder-node" => &["vndbinder", "binder"],
            "all-sm-core" | "full" => &["vndbinder", "hwbinder", "binder"],
            "none" => &[],
            _ => &["vndbinder", "hwbinder", "binder"],
        };
    }
    if config.orange_gpu_mode == "camera-hal-link-probe" {
        return &["vndbinder", "hwbinder", "binder"];
    }
    &[]
}

pub(super) fn bootstrap_tmpfs_android_ipc_runtime(config: &Config) -> io::Result<()> {
    let android_ipc_nodes = android_ipc_nodes_for_config(config);
    if android_ipc_nodes.is_empty() || !config.mount_dev || config.dev_mount != "tmpfs" {
        return Ok(());
    }
    for name in android_ipc_nodes {
        let sysfs_path = format!("/sys/class/misc/{name}/dev");
        let device_path = format!("/dev/{name}");
        ensure_char_device_from_sysfs(Path::new(&sysfs_path), Path::new(&device_path), 0o666)?;
    }
    Ok(())
}

pub(super) fn bootstrap_tmpfs_dri_runtime(config: &Config) -> io::Result<()> {
    if !config.mount_dev || config.dev_mount != "tmpfs" || config.dri_bootstrap == "none" {
        return Ok(());
    }
    ensure_directory(Path::new("/dev/dri"), 0o755)?;
    ensure_char_device(Path::new("/dev/dri/card0"), 0o600, 226, 0)?;
    ensure_char_device(Path::new("/dev/dri/renderD128"), 0o600, 226, 128)?;
    if config.dri_bootstrap == "sunfish-card0-renderD128-kgsl3d0" {
        ensure_char_device(Path::new("/dev/kgsl-3d0"), 0o666, 508, 0)?;
        ensure_char_device(Path::new("/dev/ion"), 0o666, 10, 63)?;
    }
    Ok(())
}

pub(super) fn bootstrap_tmpfs_camera_runtime(config: &Config) -> io::Result<()> {
    if !config.mount_dev
        || config.dev_mount != "tmpfs"
        || config.orange_gpu_mode != "camera-hal-link-probe"
    {
        return Ok(());
    }

    let video_nodes = [(0, 0), (1, 1), (2, 2), (32, 32), (33, 33), (34, 34)];
    for (index, minor) in video_nodes {
        ensure_char_device(Path::new(&format!("/dev/video{index}")), 0o660, 81, minor)?;
    }
    ensure_char_device(Path::new("/dev/media0"), 0o660, 247, 0)?;
    ensure_char_device(Path::new("/dev/media1"), 0o660, 247, 1)?;
    for index in 0..=16 {
        ensure_char_device(
            Path::new(&format!("/dev/v4l-subdev{index}")),
            0o660,
            81,
            128 + index,
        )?;
    }
    ensure_char_device(Path::new("/dev/ion"), 0o666, 10, 63)?;
    Ok(())
}

pub(super) fn insert_kernel_module_from_path(path: &Path) -> io::Result<()> {
    let params = CString::new("").unwrap();
    let file = File::open(path)?;
    let rc = unsafe { libc::syscall(libc::SYS_finit_module, file.as_raw_fd(), params.as_ptr(), 0) };
    if rc == 0 {
        return Ok(());
    }

    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::EEXIST) {
        return Ok(());
    }
    if error.raw_os_error() != Some(libc::ENOSYS) {
        return Err(error);
    }

    let module = fs::read(path)?;
    let rc = unsafe {
        libc::syscall(
            libc::SYS_init_module,
            module.as_ptr(),
            module.len(),
            params.as_ptr(),
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EEXIST) {
            Ok(())
        } else {
            Err(error)
        }
    }
}

pub(super) fn load_sunfish_touch_modules() -> io::Result<()> {
    for module in SUNFISH_TOUCH_MODULES {
        let module_path = Path::new("/lib/modules").join(module);
        append_wrapper_log(&format!(
            "input-bootstrap-module-loading module={} path={}",
            module,
            module_path.display()
        ));
        insert_kernel_module_from_path(&module_path).map_err(|error| {
            append_wrapper_log(&format!(
                "input-bootstrap-module-failed module={} error={}",
                module, error
            ));
            error
        })?;
        append_wrapper_log(&format!("input-bootstrap-module-ready module={module}"));
    }
    Ok(())
}

pub(super) fn load_sunfish_wifi_modules(
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> io::Result<()> {
    for module in ["wlan.ko"] {
        let module_path = Path::new("/lib/modules").join(module);
        append_wrapper_log(&format!(
            "wifi-bootstrap-module-loading module={} path={}",
            module,
            module_path.display()
        ));
        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-module-loading");
        insert_kernel_module_from_path(&module_path).map_err(|error| {
            append_wrapper_log(&format!(
                "wifi-bootstrap-module-failed module={} error={}",
                module, error
            ));
            write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-module-failed");
            error
        })?;
        append_wrapper_log(&format!("wifi-bootstrap-module-ready module={module}"));
        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-module-ready");
    }
    Ok(())
}

pub(super) fn ensure_char_device_from_sysfs(
    sysfs_dev_path: &Path,
    device_path: &Path,
    mode: u32,
) -> io::Result<(u64, u64)> {
    let dev = fs::read_to_string(sysfs_dev_path)?;
    let Some((major, minor)) = dev.trim().split_once(':') else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid sysfs dev value at {}", sysfs_dev_path.display()),
        ));
    };
    let major = major.parse::<u64>().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid major at {}: {error}", sysfs_dev_path.display()),
        )
    })?;
    let minor = minor.parse::<u64>().map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid minor at {}: {error}", sysfs_dev_path.display()),
        )
    })?;
    ensure_char_device(device_path, mode, major, minor)?;
    Ok((major, minor))
}

pub(super) fn ensure_sunfish_subsystem_node(name: &str) -> io::Result<(String, u64, u64)> {
    let sysfs_dev_path = format!("/sys/class/subsys/subsys_{name}/dev");
    let device_path = format!("/dev/subsys_{name}");
    let (major, minor) =
        ensure_char_device_from_sysfs(Path::new(&sysfs_dev_path), Path::new(&device_path), 0o660)?;
    Ok((device_path, major, minor))
}

pub(super) fn open_sunfish_subsystem(
    name: &str,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> io::Result<File> {
    let (device_path, major, minor) = ensure_sunfish_subsystem_node(name)?;
    append_wrapper_log(&format!(
        "wifi-bootstrap-subsys-node name={} device={} major={} minor={}",
        name, device_path, major, minor
    ));
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        &format!("wifi-subsys-{name}-opening"),
    );
    let file = File::open(&device_path).map_err(|error| {
        append_wrapper_log(&format!(
            "wifi-bootstrap-subsys-open-failed name={} error={}",
            name, error
        ));
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            &format!("wifi-subsys-{name}-open-failed"),
        );
        error
    })?;
    append_wrapper_log(&format!(
        "wifi-bootstrap-subsys-opened name={} device={}",
        name, device_path
    ));
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        &format!("wifi-subsys-{name}-opened"),
    );
    Ok(file)
}

pub(super) fn prepare_sunfish_wifi_android_runtime_dirs() {
    let dirs = [
        ("/dev/socket", 0o755),
        ("/dev/socket/qmux_radio", 0o770),
        ("/data", 0o771),
        ("/data/vendor", 0o771),
        ("/data/vendor/firmware", 0o770),
        ("/data/vendor/firmware/wifi", 0o750),
        ("/data/vendor/pddump", 0o770),
        ("/data/vendor/rfs", 0o770),
        ("/data/vendor/rfs/mpss", 0o770),
        ("/data/vendor/tombstones", 0o770),
        ("/data/vendor/tombstones/rfs", 0o770),
        ("/data/vendor/tombstones/rfs/modem", 0o770),
        ("/data/vendor/tombstones/rfs/lpass", 0o770),
        ("/data/vendor/tombstones/rfs/tn", 0o770),
        ("/data/vendor/tombstones/rfs/slpi", 0o770),
        ("/data/vendor/tombstones/rfs/cdsp", 0o770),
        ("/data/vendor/tombstones/rfs/wpss", 0o770),
        ("/data/vendor/wifi", 0o771),
        ("/data/vendor/wifi/wpa", 0o770),
        ("/data/vendor/wifi/wpa/sockets", 0o770),
        ("/data/vendor/wifidump", 0o771),
        ("/mnt", 0o755),
        ("/mnt/vendor", 0o755),
        ("/mnt/vendor/persist", 0o771),
        ("/mnt/vendor/persist/hlos_rfs", 0o770),
        ("/mnt/vendor/persist/hlos_rfs/shared", 0o770),
        ("/mnt/vendor/persist/rfs", 0o770),
        ("/mnt/vendor/persist/rfs/shared", 0o770),
        ("/mnt/vendor/persist/rfs/msm", 0o770),
        ("/mnt/vendor/persist/rfs/msm/adsp", 0o770),
        ("/mnt/vendor/persist/rfs/msm/mpss", 0o770),
        ("/mnt/vendor/persist/rfs/msm/slpi", 0o770),
        ("/mnt/vendor/persist/rfs/mdm", 0o770),
        ("/mnt/vendor/persist/rfs/mdm/adsp", 0o770),
        ("/mnt/vendor/persist/rfs/mdm/mpss", 0o770),
        ("/mnt/vendor/persist/rfs/mdm/slpi", 0o770),
        ("/mnt/vendor/persist/rfs/mdm/tn", 0o770),
        ("/mnt/vendor/persist/rfs/apq", 0o770),
        ("/mnt/vendor/persist/rfs/apq/gnss", 0o770),
        ("/tombstones", 0o755),
        ("/tombstones/wcnss", 0o771),
        ("/sys/fs/selinux", 0o755),
        ("/vendor/rfs", 0o755),
        ("/vendor/rfs/msm", 0o755),
        ("/vendor/rfs/msm/mpss", 0o755),
    ];
    for (path, mode) in dirs {
        let _ = ensure_directory(Path::new(path), mode);
    }
    for (path, uid, gid) in [
        ("/data/vendor/rfs", 2903, 2903),
        ("/data/vendor/rfs/mpss", 2903, 2903),
        ("/data/vendor/wifi", 1010, 1010),
        ("/data/vendor/wifi/wpa", 1010, 1010),
        ("/data/vendor/wifi/wpa/sockets", 1010, 1010),
        ("/data/vendor/tombstones/rfs", 2903, 2903),
        ("/data/vendor/tombstones/rfs/modem", 2903, 2903),
        ("/data/vendor/tombstones/rfs/lpass", 2903, 2903),
        ("/data/vendor/tombstones/rfs/tn", 2903, 2903),
        ("/data/vendor/tombstones/rfs/slpi", 2903, 2903),
        ("/data/vendor/tombstones/rfs/cdsp", 2903, 2903),
        ("/data/vendor/tombstones/rfs/wpss", 2903, 2903),
        ("/mnt/vendor/persist/rfs", 0, 1000),
        ("/mnt/vendor/persist/rfs/shared", 0, 1000),
        ("/mnt/vendor/persist/rfs/msm", 0, 1000),
        ("/mnt/vendor/persist/rfs/msm/mpss", 0, 1000),
        ("/mnt/vendor/persist/hlos_rfs", 0, 1000),
        ("/mnt/vendor/persist/hlos_rfs/shared", 0, 1000),
    ] {
        let Ok(c_path) = CString::new(path) else {
            continue;
        };
        let rc = unsafe { libc::chown(c_path.as_ptr(), uid, gid) };
        if rc != 0 {
            append_wrapper_log(&format!(
                "wifi-bootstrap-rfs-chown-failed path={} error={}",
                path,
                io::Error::last_os_error()
            ));
        }
    }
    for (path, target) in [
        ("/vendor/rfs/msm/mpss/readwrite", "/data/vendor/rfs/mpss"),
        (
            "/vendor/rfs/msm/mpss/ramdumps",
            "/data/vendor/tombstones/rfs/modem",
        ),
        (
            "/vendor/rfs/msm/mpss/hlos",
            "/mnt/vendor/persist/hlos_rfs/shared",
        ),
        (
            "/vendor/rfs/msm/mpss/shared",
            "/mnt/vendor/persist/rfs/shared",
        ),
    ] {
        if !Path::new(path).exists() {
            if let Err(error) = ensure_symlink_target(Path::new(path), Path::new(target)) {
                append_wrapper_log(&format!(
                    "wifi-bootstrap-rfs-symlink-failed path={} target={} error={}",
                    path, target, error
                ));
            }
        }
    }
    for (path, mode, major, minor) in [
        ("/dev/null", 0o666, 1, 3),
        ("/dev/zero", 0o666, 1, 5),
        ("/dev/random", 0o666, 1, 8),
        ("/dev/urandom", 0o666, 1, 9),
    ] {
        if let Err(error) = ensure_char_device(Path::new(path), mode, major, minor) {
            append_wrapper_log(&format!(
                "wifi-bootstrap-android-dev-node-failed path={} error={}",
                path, error
            ));
        }
    }
    if !Path::new("/sys/fs/selinux/status").exists() {
        match mount_fs("selinuxfs", "/sys/fs/selinux", "selinuxfs", 0, None) {
            Ok(()) => append_wrapper_log("wifi-bootstrap-selinuxfs-mounted"),
            Err(error) => append_wrapper_log(&format!(
                "wifi-bootstrap-selinuxfs-mount-failed error={error}"
            )),
        }
    }
}

pub(super) fn load_sunfish_wifi_selinux_policy(
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) {
    let policy_path = Path::new("/vendor/etc/selinux/precompiled_sepolicy");
    let load_path = Path::new("/sys/fs/selinux/load");
    if !policy_path.is_file() {
        append_wrapper_log(
            "wifi-bootstrap-selinux-policy-missing path=/vendor/etc/selinux/precompiled_sepolicy",
        );
        return;
    }
    if !load_path.exists() {
        append_wrapper_log("wifi-bootstrap-selinux-policy-load-missing path=/sys/fs/selinux/load");
        return;
    }
    let policy = match fs::read(policy_path) {
        Ok(policy) => policy,
        Err(error) => {
            append_wrapper_log(&format!(
                "wifi-bootstrap-selinux-policy-read-failed error={error}"
            ));
            return;
        }
    };
    match OpenOptions::new()
        .write(true)
        .open(load_path)
        .and_then(|mut file| file.write_all(&policy))
    {
        Ok(()) => {
            append_wrapper_log(&format!(
                "wifi-bootstrap-selinux-policy-loaded bytes={}",
                policy.len()
            ));
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                "wifi-selinux-policy-loaded",
            );
        }
        Err(error) => append_wrapper_log(&format!(
            "wifi-bootstrap-selinux-policy-load-failed error={error}"
        )),
    }
}

pub(super) fn create_sunfish_android_core_device_nodes() {
    for (name, sysfs_path, device_path, mode) in [
        (
            "qseecom",
            "/sys/class/qseecom/qseecom/dev",
            "/dev/qseecom",
            0o660,
        ),
        (
            "smcinvoke",
            "/sys/class/smcinvoke/smcinvoke/dev",
            "/dev/smcinvoke",
            0o600,
        ),
        ("ion", "/sys/class/misc/ion/dev", "/dev/ion", 0o664),
        (
            "adsprpc-smd",
            "/sys/class/fastrpc/adsprpc-smd/dev",
            "/dev/adsprpc-smd",
            0o664,
        ),
        ("ipa", "/sys/class/ipa/ipa/dev", "/dev/ipa", 0o660),
        (
            "ipaNatTable",
            "/sys/class/ipaNatTable/ipaNatTable/dev",
            "/dev/ipaNatTable",
            0o660,
        ),
        (
            "ipa_adpl",
            "/sys/class/ipa_adpl/ipa_adpl/dev",
            "/dev/ipa_adpl",
            0o660,
        ),
    ] {
        match ensure_char_device_from_sysfs(Path::new(sysfs_path), Path::new(device_path), mode) {
            Ok((major, minor)) => append_wrapper_log(&format!(
                "wifi-bootstrap-android-node name={} device={} major={} minor={}",
                name, device_path, major, minor
            )),
            Err(error) => append_wrapper_log(&format!(
                "wifi-bootstrap-android-node-failed name={} device={} error={}",
                name, device_path, error
            )),
        }
    }
}

pub(super) fn trigger_sunfish_ipa_firmware_load() {
    match OpenOptions::new()
        .write(true)
        .open("/dev/ipa")
        .and_then(|mut file| file.write_all(b"1"))
    {
        Ok(()) => append_wrapper_log("wifi-bootstrap-ipa-triggered path=/dev/ipa"),
        Err(error) => {
            append_wrapper_log(&format!("wifi-bootstrap-ipa-trigger-failed error={error}"))
        }
    }
}

pub(super) fn find_block_device_by_partname(partname: &str) -> Option<(u32, u32)> {
    let entries = fs::read_dir(METADATA_SYSFS_BLOCK_ROOT).ok()?;
    for entry in entries.flatten() {
        let Ok(text) = fs::read_to_string(entry.path().join("uevent")) else {
            continue;
        };
        let mut partname_matches = false;
        let mut major_num = None;
        let mut minor_num = None;
        for line in text.lines() {
            if let Some(value) = line.strip_prefix("PARTNAME=") {
                partname_matches = value == partname;
            } else if let Some(value) = line.strip_prefix("MAJOR=") {
                major_num = value.parse::<u32>().ok();
            } else if let Some(value) = line.strip_prefix("MINOR=") {
                minor_num = value.parse::<u32>().ok();
            }
        }
        if partname_matches {
            if let (Some(major_num), Some(minor_num)) = (major_num, minor_num) {
                return Some((major_num, minor_num));
            }
        }
    }
    None
}

pub(super) fn mount_sunfish_modem_firmware_partition(
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> io::Result<()> {
    if Path::new("/vendor/firmware_mnt/image/modem.mdt").is_file() {
        return Ok(());
    }
    ensure_directory(Path::new("/dev/block/by-name"), 0o755)?;
    ensure_directory(Path::new("/vendor"), 0o755)?;
    ensure_directory(Path::new("/vendor/firmware_mnt"), 0o755)?;

    for partname in sunfish_modem_partition_order() {
        let Some((major, minor)) = find_block_device_by_partname(partname) else {
            continue;
        };
        let device_path = Path::new("/dev/block/by-name").join(partname);
        ensure_block_device(&device_path, 0o600, major as u64, minor as u64)?;
        match mount_fs(
            device_path.to_string_lossy().as_ref(),
            "/vendor/firmware_mnt",
            "vfat",
            libc::MS_RDONLY,
            None,
        ) {
            Ok(()) => {
                append_wrapper_log(&format!(
                    "wifi-bootstrap-modem-firmware-mounted part={} device={} major={} minor={}",
                    partname,
                    device_path.display(),
                    major,
                    minor
                ));
                write_payload_probe_stage(
                    probe_stage_path,
                    probe_stage_prefix,
                    "wifi-modem-firmware-mounted",
                );
                return Ok(());
            }
            Err(error) => {
                append_wrapper_log(&format!(
                    "wifi-bootstrap-modem-firmware-mount-failed part={} error={}",
                    partname, error
                ));
            }
        }
    }

    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-modem-firmware-mount-failed",
    );
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "unable to mount sunfish modem firmware partition",
    ))
}

pub(super) fn sunfish_modem_partition_order() -> [&'static str; 2] {
    let cmdline = fs::read_to_string("/proc/cmdline").unwrap_or_default();
    if cmdline.contains("androidboot.slot_suffix=_b")
        || cmdline.contains("androidboot.slot=b")
        || cmdline.contains("androidboot.slot_suffix=b")
    {
        ["modem_b", "modem_a"]
    } else {
        ["modem_a", "modem_b"]
    }
}

pub(super) fn create_sunfish_remote_storage_block_nodes() {
    let _ = ensure_directory(Path::new("/dev/block/bootdevice/by-name"), 0o755);
    for partname in ["modemst1", "modemst2", "fsg", "fsc"] {
        let Some((major, minor)) = find_block_device_by_partname(partname) else {
            append_wrapper_log(&format!(
                "wifi-bootstrap-rmt-storage-block-missing part={partname}"
            ));
            continue;
        };
        let device_path = Path::new("/dev/block/bootdevice/by-name").join(partname);
        match ensure_block_device(&device_path, 0o600, major as u64, minor as u64) {
            Ok(()) => append_wrapper_log(&format!(
                "wifi-bootstrap-rmt-storage-block-node part={} device={} major={} minor={}",
                partname,
                device_path.display(),
                major,
                minor
            )),
            Err(error) => append_wrapper_log(&format!(
                "wifi-bootstrap-rmt-storage-block-node-failed part={} error={}",
                partname, error
            )),
        }
    }
}

pub(super) fn create_sunfish_rmtfs_uio_node() {
    let Ok(entries) = fs::read_dir("/sys/class/uio") else {
        append_wrapper_log("wifi-bootstrap-rmtfs-uio-missing-root path=/sys/class/uio");
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = fs::read_to_string(path.join("name")).unwrap_or_default();
        if name.trim() != "rmtfs" {
            continue;
        }
        let device_path = Path::new("/dev").join(entry.file_name());
        match ensure_char_device_from_sysfs(&path.join("dev"), &device_path, 0o660) {
            Ok((major, minor)) => append_wrapper_log(&format!(
                "wifi-bootstrap-rmtfs-uio-node device={} major={} minor={}",
                device_path.display(),
                major,
                minor
            )),
            Err(error) => append_wrapper_log(&format!(
                "wifi-bootstrap-rmtfs-uio-node-failed device={} error={}",
                device_path.display(),
                error
            )),
        }
        return;
    }
    append_wrapper_log("wifi-bootstrap-rmtfs-uio-missing-name name=rmtfs");
}

pub(super) fn spawn_sunfish_wifi_android_helper(
    name: &str,
    args: &[&str],
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> Option<Child> {
    let helper_path = match name {
        "servicemanager" | "hwservicemanager" => Path::new("/system/bin").join(name),
        "wpa_supplicant" => Path::new("/vendor/bin/hw/wpa_supplicant").to_path_buf(),
        _ => Path::new("/vendor/bin").join(name),
    };
    let direct_exec = matches!(
        name,
        "servicemanager" | "hwservicemanager" | "vndservicemanager"
    );
    let linker_path = Path::new(CAMERA_HAL_BIONIC_LINKER_PATH);
    if (!direct_exec && !linker_path.is_file()) || !helper_path.is_file() {
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            &format!("wifi-android-helper-missing-{name}"),
        );
        return None;
    }

    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        &format!("wifi-android-helper-start-{name}"),
    );
    let mut command = if direct_exec {
        Command::new(&helper_path)
    } else if name == "wpa_supplicant" && Path::new("/system/bin/toybox").is_file() {
        let mut command = Command::new("/system/bin/toybox");
        command.arg("runcon");
        command.arg("u:r:hal_wifi_supplicant_default:s0");
        command.arg(linker_path);
        command.arg(&helper_path);
        command
    } else {
        let mut command = Command::new(linker_path);
        command.arg(&helper_path);
        command
    };
    for arg in args {
        command.arg(arg);
    }
    command.env(LD_LIBRARY_PATH_ENV, CAMERA_HAL_BIONIC_LIBRARY_PATH);
    command.env("ANDROID_ROOT", "/system");
    command.env("ANDROID_DATA", "/data");
    command.env("LD_CONFIG_FILE", "/linkerconfig/ld.config.txt");
    if Path::new("/vendor/lib64/libshadowprop.so").is_file() {
        command.env("LD_PRELOAD", "/vendor/lib64/libshadowprop.so");
    }
    if name == "wpa_supplicant" {
        command.env("SHADOW_FAKE_WIFI_SUPPLICANT_SERVICE_REGISTRATION", "1");
    }
    let output_path = format!("/orange-gpu/wifi-helper-{name}.log");
    if let Ok((stdout, stderr)) = redirect_output(&output_path) {
        command.stdout(stdout);
        command.stderr(stderr);
    }
    match command.spawn() {
        Ok(child) => {
            append_wrapper_log(&format!(
                "wifi-android-helper-started name={} pid={}",
                name,
                child.id()
            ));
            Some(child)
        }
        Err(error) => {
            append_wrapper_log(&format!(
                "wifi-android-helper-spawn-failed name={} error={}",
                name, error
            ));
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                &format!("wifi-android-helper-failed-{name}"),
            );
            None
        }
    }
}

pub(super) fn wifi_helper_profile_allows(profile: &str, name: &str) -> bool {
    match profile {
        "full" => true,
        "no-service-managers" => !matches!(
            name,
            "servicemanager" | "hwservicemanager" | "vndservicemanager"
        ),
        "no-pm" => {
            wifi_helper_profile_allows("no-service-managers", name)
                && !matches!(name, "pm-service" | "pm-proxy")
        }
        "no-modem-svc" => wifi_helper_profile_allows("no-pm", name) && name != "modem_svc",
        "no-rfs-storage" => {
            wifi_helper_profile_allows("no-modem-svc", name)
                && !matches!(name, "rmt_storage" | "tftp_server")
        }
        "no-pd-mapper" => wifi_helper_profile_allows("no-rfs-storage", name) && name != "pd-mapper",
        "no-cnss" => wifi_helper_profile_allows("no-pd-mapper", name) && name != "cnss-daemon",
        "qrtr-only" => name == "qrtr-ns",
        "qrtr-pd" => matches!(name, "qrtr-ns" | "pd-mapper"),
        "qrtr-pd-tftp" => matches!(name, "qrtr-ns" | "pd-mapper" | "tftp_server"),
        "qrtr-pd-rfs" => matches!(
            name,
            "qrtr-ns" | "pd-mapper" | "rmt_storage" | "tftp_server"
        ),
        "qrtr-pd-rfs-cnss" => matches!(
            name,
            "qrtr-ns" | "pd-mapper" | "rmt_storage" | "tftp_server" | "cnss-daemon"
        ),
        "qrtr-pd-rfs-modem" => matches!(
            name,
            "qrtr-ns" | "pd-mapper" | "rmt_storage" | "tftp_server" | "modem_svc"
        ),
        "qrtr-pd-rfs-modem-cnss" => matches!(
            name,
            "qrtr-ns" | "pd-mapper" | "rmt_storage" | "tftp_server" | "modem_svc" | "cnss-daemon"
        ),
        "qrtr-pd-rfs-modem-pm" => matches!(
            name,
            "qrtr-ns"
                | "pd-mapper"
                | "rmt_storage"
                | "tftp_server"
                | "modem_svc"
                | "pm-service"
                | "pm-proxy"
        ),
        "qrtr-pd-rfs-modem-pm-cnss" => matches!(
            name,
            "qrtr-ns"
                | "pd-mapper"
                | "rmt_storage"
                | "tftp_server"
                | "modem_svc"
                | "pm-service"
                | "pm-proxy"
                | "cnss-daemon"
        ),
        // Research profile: isolate the framework Binder registry while
        // keeping Android init and the vendor/HIDL registries out of the
        // boot-owned Wi-Fi surface.
        "aidl-sm-core" => matches!(
            name,
            "servicemanager"
                | "qrtr-ns"
                | "pd-mapper"
                | "rmt_storage"
                | "tftp_server"
                | "modem_svc"
                | "pm-service"
                | "pm-proxy"
                | "cnss-daemon"
        ),
        "vnd-sm-core" => matches!(
            name,
            "vndservicemanager"
                | "qrtr-ns"
                | "pd-mapper"
                | "rmt_storage"
                | "tftp_server"
                | "modem_svc"
                | "pm-service"
                | "pm-proxy"
                | "cnss-daemon"
        ),
        // Proven Pixel 4a scan seam. The Qualcomm Wi-Fi chipset helpers
        // are a small distributed process graph; vndservicemanager is the
        // tiny vendor Binder name registry they use to find PM services.
        // This keeps Android init, hwservicemanager, and the framework
        // servicemanager out of the boot-owned Wi-Fi path.
        "vnd-sm-core-binder-node" => matches!(
            name,
            "vndservicemanager"
                | "qrtr-ns"
                | "pd-mapper"
                | "rmt_storage"
                | "tftp_server"
                | "modem_svc"
                | "pm-service"
                | "pm-proxy"
                | "cnss-daemon"
        ),
        "all-sm-core" => matches!(
            name,
            "servicemanager"
                | "hwservicemanager"
                | "vndservicemanager"
                | "qrtr-ns"
                | "pd-mapper"
                | "rmt_storage"
                | "tftp_server"
                | "modem_svc"
                | "pm-service"
                | "pm-proxy"
                | "cnss-daemon"
        ),
        "none" => false,
        _ => false,
    }
}

pub(super) fn spawn_sunfish_wifi_profile_helper(
    profile: &str,
    name: &str,
    args: &[&str],
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> Option<Child> {
    if !wifi_helper_profile_allows(profile, name) {
        append_wrapper_log(&format!(
            "wifi-android-helper-skipped profile={} name={}",
            profile, name
        ));
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            &format!("wifi-android-helper-skipped-{name}"),
        );
        return None;
    }
    spawn_sunfish_wifi_android_helper(name, args, probe_stage_path, probe_stage_prefix)
}

pub(super) fn start_sunfish_wifi_android_core_helpers(
    config: &Config,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) {
    prepare_sunfish_wifi_android_runtime_dirs();
    create_sunfish_android_core_device_nodes();
    load_sunfish_wifi_selinux_policy(probe_stage_path, probe_stage_prefix);
    if let Err(error) = mount_sunfish_modem_firmware_partition(probe_stage_path, probe_stage_prefix)
    {
        append_wrapper_log(&format!(
            "wifi-bootstrap-modem-firmware-unavailable error={error}"
        ));
    }
    create_sunfish_remote_storage_block_nodes();
    create_sunfish_rmtfs_uio_node();
    let helpers: [(&str, &[&str]); 10] = [
        ("servicemanager", &[]),
        ("hwservicemanager", &[]),
        ("vndservicemanager", &["/dev/vndbinder"]),
        ("qseecomd", &[]),
        ("irsc_util", &["/vendor/etc/sec_config"]),
        ("qrtr-ns", &["-f"]),
        ("pd-mapper", &[]),
        ("rmt_storage", &[]),
        ("tftp_server", &[]),
        ("modem_svc", &["-q"]),
    ];
    for (name, args) in helpers {
        let mut child = spawn_sunfish_wifi_profile_helper(
            &config.wifi_helper_profile,
            name,
            args,
            probe_stage_path,
            probe_stage_prefix,
        );
        thread::sleep(Duration::from_millis(250));
        if let Some(child) = child.as_mut() {
            match child.try_wait() {
                Ok(Some(status)) => append_wrapper_log(&format!(
                    "wifi-android-helper-exited name={} status={}",
                    name, status
                )),
                Ok(None) => {}
                Err(error) => append_wrapper_log(&format!(
                    "wifi-android-helper-status-failed name={} error={}",
                    name, error
                )),
            }
        }
    }
    thread::sleep(Duration::from_secs(1));
    trigger_sunfish_ipa_firmware_load();
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-android-helpers-started",
    );
}

pub(super) fn mount_sunfish_wifi_debugfs(
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) {
    if ensure_directory(Path::new("/sys/kernel/debug"), 0o755).is_err() {
        return;
    }
    match mount_fs("debugfs", "/sys/kernel/debug", "debugfs", 0, None) {
        Ok(()) => {
            append_wrapper_log("wifi-bootstrap-debugfs-mounted");
            write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-debugfs-mounted");
        }
        Err(error) => append_wrapper_log(&format!(
            "wifi-bootstrap-debugfs-mount-failed error={error}"
        )),
    }
}

pub(super) fn start_sunfish_wifi_peripheral_manager(
    config: &Config,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) {
    for (name, args) in [("pm-service", &[] as &[&str]), ("pm-proxy", &[])] {
        let mut child = spawn_sunfish_wifi_profile_helper(
            &config.wifi_helper_profile,
            name,
            args,
            probe_stage_path,
            probe_stage_prefix,
        );
        thread::sleep(Duration::from_millis(500));
        if let Some(child) = child.as_mut() {
            match child.try_wait() {
                Ok(Some(status)) => append_wrapper_log(&format!(
                    "wifi-android-helper-exited name={} status={}",
                    name, status
                )),
                Ok(None) => {}
                Err(error) => append_wrapper_log(&format!(
                    "wifi-android-helper-status-failed name={} error={}",
                    name, error
                )),
            }
        }
    }
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-peripheral-manager-started",
    );
}

pub(super) fn start_sunfish_wifi_cnss_daemon(
    config: &Config,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) {
    let _ = spawn_sunfish_wifi_profile_helper(
        &config.wifi_helper_profile,
        "cnss-daemon",
        &["-n", "-d", "-d"],
        probe_stage_path,
        probe_stage_prefix,
    );
    thread::sleep(Duration::from_secs(1));
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-cnss-daemon-started",
    );
}

pub(super) fn bootstrap_tmpfs_input_runtime(config: &Config) -> io::Result<()> {
    if config.input_bootstrap != "sunfish-touch-event2" {
        return Ok(());
    }
    if !config.mount_sys {
        append_wrapper_log(
            "input-bootstrap-invalid-config mode=sunfish-touch-event2 reason=mount_sys_false",
        );
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "sunfish touch input bootstrap requires mount_sys=true",
        ));
    }
    if !config.mount_dev {
        append_wrapper_log(
            "input-bootstrap-invalid-config mode=sunfish-touch-event2 reason=mount_dev_false",
        );
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "sunfish touch input bootstrap requires mount_dev=true",
        ));
    }
    if config.dev_mount != "tmpfs" {
        append_wrapper_log(&format!(
            "input-bootstrap-invalid-config mode=sunfish-touch-event2 reason=dev_mount_{}",
            config.dev_mount
        ));
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "sunfish touch input bootstrap requires dev_mount=tmpfs",
        ));
    }

    ensure_directory(Path::new("/dev/input"), 0o755)?;
    if !Path::new("/lib/firmware/ftm5_fw.ftb").is_file() {
        append_wrapper_log("input-bootstrap-firmware-missing path=/lib/firmware/ftm5_fw.ftb");
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "missing sunfish touch firmware",
        ));
    }

    let firmware_stop = Arc::new(AtomicBool::new(false));
    let firmware_helper = {
        let thread_stop = Arc::clone(&firmware_stop);
        thread::spawn(move || run_ramdisk_firmware_any_helper_loop(thread_stop, "input"))
    };
    if let Err(error) = load_sunfish_touch_modules() {
        firmware_stop.store(true, Ordering::Relaxed);
        let _ = firmware_helper.join();
        return Err(error);
    }

    for attempt in 1..=300 {
        if let Some((event_name, major, minor)) = find_sunfish_touch_event()? {
            let device_path = Path::new("/dev/input").join(&event_name);
            ensure_char_device(&device_path, 0o660, major, minor)?;
            append_wrapper_log(&format!(
                "input-bootstrap-ready mode={} device={} major={} minor={} attempts={}",
                config.input_bootstrap, event_name, major, minor, attempt
            ));
            firmware_stop.store(true, Ordering::Relaxed);
            let _ = firmware_helper.join();
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }

    firmware_stop.store(true, Ordering::Relaxed);
    let _ = firmware_helper.join();
    append_wrapper_log(&format!(
        "input-bootstrap-timeout mode={} waited_ms=12000",
        config.input_bootstrap
    ));
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "sunfish touch input event did not appear",
    ))
}

pub(super) fn bootstrap_tmpfs_wifi_runtime(
    config: &Config,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> io::Result<()> {
    if config.wifi_bootstrap != "sunfish-wlan0" {
        return Ok(());
    }
    write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-bootstrap-start");
    if !config.mount_sys {
        append_wrapper_log(
            "wifi-bootstrap-invalid-config mode=sunfish-wlan0 reason=mount_sys_false",
        );
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-bootstrap-invalid-mount-sys",
        );
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "sunfish wifi bootstrap requires mount_sys=true",
        ));
    }
    if !config.mount_dev {
        append_wrapper_log(
            "wifi-bootstrap-invalid-config mode=sunfish-wlan0 reason=mount_dev_false",
        );
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-bootstrap-invalid-mount-dev",
        );
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "sunfish wifi bootstrap requires mount_dev=true",
        ));
    }
    if config.dev_mount != "tmpfs" {
        append_wrapper_log(&format!(
            "wifi-bootstrap-invalid-config mode=sunfish-wlan0 reason=dev_mount_{}",
            config.dev_mount
        ));
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-bootstrap-invalid-dev-mount",
        );
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "sunfish wifi bootstrap requires dev_mount=tmpfs",
        ));
    }
    if !Path::new("/lib/modules/wlan.ko").is_file() {
        append_wrapper_log("wifi-bootstrap-module-missing path=/lib/modules/wlan.ko");
        write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-module-missing");
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "missing sunfish wlan.ko",
        ));
    }

    start_sunfish_wifi_android_core_helpers(config, probe_stage_path, probe_stage_prefix);
    mount_sunfish_wifi_debugfs(probe_stage_path, probe_stage_prefix);
    let firmware_stop = Arc::new(AtomicBool::new(false));
    let firmware_helper = {
        let thread_stop = Arc::clone(&firmware_stop);
        thread::spawn(move || run_ramdisk_firmware_any_helper_loop(thread_stop, "wifi"))
    };
    let mut subsystem_handles = Vec::new();
    if let Err(error) = load_sunfish_wifi_modules(probe_stage_path, probe_stage_prefix) {
        firmware_stop.store(true, Ordering::Relaxed);
        let _ = firmware_helper.join();
        return Err(error);
    }
    match ensure_char_device_from_sysfs(
        Path::new("/sys/class/wlan/wlan/dev"),
        Path::new("/dev/wlan"),
        0o666,
    ) {
        Ok((major, minor)) => append_wrapper_log(&format!(
            "wifi-bootstrap-wlan-control-node device=/dev/wlan major={} minor={}",
            major, minor
        )),
        Err(error) => append_wrapper_log(&format!(
            "wifi-bootstrap-wlan-control-node-failed error={error}"
        )),
    }
    match ensure_sunfish_subsystem_node("modem") {
        Ok((device_path, major, minor)) => append_wrapper_log(&format!(
            "wifi-bootstrap-subsys-node-prepared name=modem device={} major={} minor={}",
            device_path, major, minor
        )),
        Err(error) => append_wrapper_log(&format!(
            "wifi-bootstrap-subsys-node-prepare-failed name=modem error={error}"
        )),
    }
    start_sunfish_wifi_peripheral_manager(config, probe_stage_path, probe_stage_prefix);
    let modem_subsystem =
        match open_sunfish_subsystem("modem", probe_stage_path, probe_stage_prefix) {
            Ok(file) => file,
            Err(error) => {
                firmware_stop.store(true, Ordering::Relaxed);
                let _ = firmware_helper.join();
                return Err(error);
            }
        };
    subsystem_handles.push(modem_subsystem);
    start_sunfish_wifi_cnss_daemon(config, probe_stage_path, probe_stage_prefix);

    write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wait-wlan0");
    for attempt in 1..=250 {
        if Path::new("/sys/class/net/wlan0").exists() {
            let (major, minor) = ensure_char_device_from_sysfs(
                Path::new("/sys/class/wlan/wlan/dev"),
                Path::new("/dev/wlan"),
                0o666,
            )?;
            append_wrapper_log(&format!(
                "wifi-bootstrap-ready mode={} interface=wlan0 device=/dev/wlan major={} minor={} attempts={}",
                config.wifi_bootstrap, major, minor, attempt
            ));
            write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-bootstrap-ready");
            std::mem::forget(subsystem_handles);
            firmware_stop.store(true, Ordering::Relaxed);
            let _ = firmware_helper.join();
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }
    firmware_stop.store(true, Ordering::Relaxed);
    let _ = firmware_helper.join();

    append_wrapper_log(&format!(
        "wifi-bootstrap-timeout mode={} waited_ms=25000",
        config.wifi_bootstrap
    ));
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-bootstrap-timeout",
    );
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "sunfish wlan0 did not appear",
    ))
}

pub(super) fn find_sunfish_touch_event() -> io::Result<Option<(String, u64, u64)>> {
    let entries = match fs::read_dir("/sys/class/input") {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };

    for entry in entries {
        let entry = entry?;
        let event_name = entry.file_name();
        let Some(event_name) = event_name.to_str() else {
            continue;
        };
        if !event_name.starts_with("event") {
            continue;
        }

        let event_path = entry.path();
        let device_path = event_path.join("device");
        let name = read_trimmed(&device_path.join("name")).unwrap_or_default();
        let properties = read_trimmed(&device_path.join("properties")).unwrap_or_default();
        if name != "fts" || properties != "2" {
            continue;
        }

        let dev = read_trimmed(&event_path.join("dev"))?;
        let Some((major, minor)) = parse_major_minor(&dev) else {
            continue;
        };
        return Ok(Some((event_name.to_string(), major, minor)));
    }

    Ok(None)
}

pub(super) fn read_trimmed(path: &Path) -> io::Result<String> {
    Ok(fs::read_to_string(path)?.trim().to_string())
}

pub(super) fn parse_major_minor(value: &str) -> Option<(u64, u64)> {
    let (major, minor) = value.trim().split_once(':')?;
    Some((major.parse().ok()?, minor.parse().ok()?))
}
