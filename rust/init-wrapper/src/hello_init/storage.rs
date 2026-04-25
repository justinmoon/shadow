use super::*;

pub(super) fn init_metadata_stage_runtime(config: &Config) -> MetadataStageRuntime {
    let mut runtime = MetadataStageRuntime::default();
    runtime.enabled = config.orange_gpu_metadata_stage_breadcrumb
        && config.mount_dev
        && !config.run_token.is_empty();
    if !runtime.enabled {
        return runtime;
    }

    runtime.stage_dir = Path::new(METADATA_BY_TOKEN_ROOT).join(&config.run_token);
    runtime.stage_path = runtime.stage_dir.join("stage.txt");
    runtime.temp_stage_path = runtime.stage_dir.join(".stage.txt.tmp");
    runtime.probe_stage_path = runtime.stage_dir.join("probe-stage.txt");
    runtime.temp_probe_stage_path = runtime.stage_dir.join(".probe-stage.txt.tmp");
    runtime.probe_fingerprint_path = runtime.stage_dir.join("probe-fingerprint.txt");
    runtime.temp_probe_fingerprint_path = runtime.stage_dir.join(".probe-fingerprint.txt.tmp");
    runtime.probe_report_path = runtime.stage_dir.join("probe-report.txt");
    runtime.temp_probe_report_path = runtime.stage_dir.join(".probe-report.txt.tmp");
    runtime.probe_timeout_class_path = runtime.stage_dir.join("probe-timeout-class.txt");
    runtime.temp_probe_timeout_class_path = runtime.stage_dir.join(".probe-timeout-class.txt.tmp");
    runtime.probe_summary_path = runtime.stage_dir.join("probe-summary.json");
    runtime.temp_probe_summary_path = runtime.stage_dir.join(".probe-summary.json.tmp");
    runtime.compositor_frame_path = runtime.stage_dir.join("compositor-frame.ppm");
    runtime
}

pub(super) fn capture_metadata_block_identity(runtime: &mut MetadataStageRuntime, config: &Config) {
    if !runtime.enabled || config.dev_mount != "tmpfs" {
        return;
    }
    let Ok(metadata) = fs::metadata(METADATA_DEVICE_PATH) else {
        return;
    };
    if !metadata.file_type().is_block_device() {
        return;
    }
    use std::os::unix::fs::MetadataExt;
    let rdev = metadata.rdev();
    runtime.block_device = BlockDeviceIdentity {
        available: true,
        major_num: libc::major(rdev) as u32,
        minor_num: libc::minor(rdev) as u32,
    };
}

pub(super) fn discover_metadata_block_identity_from_sysfs(
    runtime: &mut MetadataStageRuntime,
    config: &Config,
) {
    if !runtime.enabled
        || runtime.block_device.available
        || config.dev_mount != "tmpfs"
        || !config.mount_sys
    {
        return;
    }
    let Ok(entries) = fs::read_dir(METADATA_SYSFS_BLOCK_ROOT) else {
        return;
    };
    for entry in entries.flatten() {
        let uevent_path = entry.path().join("uevent");
        let Ok(text) = fs::read_to_string(&uevent_path) else {
            continue;
        };
        let mut partname_matches = false;
        let mut major_num = None;
        let mut minor_num = None;
        for line in text.lines() {
            if let Some(value) = line.strip_prefix("PARTNAME=") {
                partname_matches = value == METADATA_PARTNAME;
            } else if let Some(value) = line.strip_prefix("MAJOR=") {
                major_num = value.parse::<u32>().ok();
            } else if let Some(value) = line.strip_prefix("MINOR=") {
                minor_num = value.parse::<u32>().ok();
            }
        }
        if partname_matches {
            if let (Some(major_num), Some(minor_num)) = (major_num, minor_num) {
                runtime.block_device = BlockDeviceIdentity {
                    available: true,
                    major_num,
                    minor_num,
                };
                break;
            }
        }
    }
}

pub(super) fn discover_block_identity_by_partname(
    config: &Config,
    partname: &str,
) -> BlockDeviceIdentity {
    if config.dev_mount != "tmpfs" || !config.mount_sys {
        return BlockDeviceIdentity::default();
    }
    let Ok(entries) = fs::read_dir(METADATA_SYSFS_BLOCK_ROOT) else {
        return BlockDeviceIdentity::default();
    };
    for entry in entries.flatten() {
        let uevent_path = entry.path().join("uevent");
        let Ok(text) = fs::read_to_string(&uevent_path) else {
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
                return BlockDeviceIdentity {
                    available: true,
                    major_num,
                    minor_num,
                };
            }
        }
    }
    BlockDeviceIdentity::default()
}

pub(super) fn bootstrap_tmpfs_userdata_block_runtime(config: &Config) -> io::Result<()> {
    if config.dev_mount != "tmpfs" {
        return Ok(());
    }
    let block_device = discover_block_identity_by_partname(config, USERDATA_PARTNAME);
    if !block_device.available {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "userdata block device unavailable",
        ));
    }
    ensure_directory(Path::new("/dev/block"), 0o755)?;
    ensure_directory(Path::new("/dev/block/by-name"), 0o755)?;
    ensure_directory(Path::new("/dev/block/bootdevice"), 0o755)?;
    ensure_directory(Path::new("/dev/block/bootdevice/by-name"), 0o755)?;
    ensure_block_device(
        Path::new(USERDATA_DEVICE_PATH),
        0o600,
        block_device.major_num as u64,
        block_device.minor_num as u64,
    )?;
    ensure_block_device(
        Path::new(USERDATA_BOOTDEVICE_PATH),
        0o600,
        block_device.major_num as u64,
        block_device.minor_num as u64,
    )
}

pub(super) fn bootstrap_tmpfs_named_block_device(
    config: &Config,
    partname: &str,
    path: &Path,
) -> io::Result<()> {
    if config.dev_mount != "tmpfs" {
        return Ok(());
    }
    let block_device = discover_block_identity_by_partname(config, partname);
    if !block_device.available {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("{partname} block device unavailable"),
        ));
    }
    ensure_directory(Path::new("/dev/block"), 0o755)?;
    ensure_directory(Path::new("/dev/block/by-name"), 0o755)?;
    ensure_block_device(
        path,
        0o600,
        block_device.major_num as u64,
        block_device.minor_num as u64,
    )
}

pub(super) fn prepare_userdata_payload_root(
    config: &Config,
    payload_root: &Path,
) -> Result<bool, String> {
    if !payload_root.starts_with(USERDATA_MOUNT_PATH) {
        return Ok(false);
    }
    bootstrap_tmpfs_userdata_block_runtime(config)
        .map_err(|error| format!("userdata-block-bootstrap:{error}"))?;
    ensure_directory(Path::new(USERDATA_MOUNT_PATH), 0o771)
        .map_err(|error| format!("userdata-mkdir:{error}"))?;
    let mount_flags = (libc::MS_NOATIME | libc::MS_NODEV | libc::MS_NOSUID) as libc::c_ulong;
    mount_fs(
        USERDATA_DEVICE_PATH,
        USERDATA_MOUNT_PATH,
        "f2fs",
        mount_flags,
        Some(""),
    )
    .map_err(|error| format!("userdata-mount-f2fs:{error}"))?;
    Ok(true)
}

pub(super) fn prepare_shadow_logical_payload_root(
    config: &Config,
    payload_root: &Path,
) -> Result<bool, String> {
    if !payload_root.starts_with(SHADOW_PAYLOAD_MOUNT_PATH) {
        return Ok(false);
    }
    bootstrap_tmpfs_named_block_device(config, SUPER_PARTNAME, Path::new(SUPER_DEVICE_PATH))
        .map_err(|error| format!("shadow-logical-super-bootstrap:{error}"))?;
    let slot_suffix = active_slot_suffix().unwrap_or_else(|| "_a".to_string());
    let partition_name = format!("{SHADOW_PAYLOAD_PARTITION_PREFIX}{slot_suffix}");
    let dm_path = create_shadow_payload_dm_linear(&partition_name)
        .map_err(|error| format!("shadow-logical-dm:{error}"))?;
    ensure_directory(Path::new(SHADOW_PAYLOAD_MOUNT_PATH), 0o755)
        .map_err(|error| format!("shadow-logical-mkdir:{error}"))?;
    let mount_flags =
        (libc::MS_RDONLY | libc::MS_NOATIME | libc::MS_NODEV | libc::MS_NOSUID) as libc::c_ulong;
    mount_fs(
        &dm_path,
        SHADOW_PAYLOAD_MOUNT_PATH,
        "ext4",
        mount_flags,
        Some(""),
    )
    .map_err(|error| format!("shadow-logical-mount-ext4:{error}"))?;
    Ok(true)
}

pub(super) fn active_slot_suffix() -> Option<String> {
    for path in ["/proc/bootconfig", "/proc/cmdline"] {
        let Ok(text) = fs::read_to_string(path) else {
            continue;
        };
        for token in text.split_whitespace() {
            let token = token.trim_matches('"');
            for prefix in ["androidboot.slot_suffix=", "androidboot.slot="] {
                if let Some(value) = token.strip_prefix(prefix) {
                    let value = value.trim_matches('"');
                    if value == "a" || value == "b" {
                        return Some(format!("_{value}"));
                    }
                    if value == "_a" || value == "_b" {
                        return Some(value.to_string());
                    }
                }
            }
        }
    }
    None
}

#[derive(Clone, Debug)]
pub(super) struct LogicalExtent {
    logical_start: u64,
    sectors: u64,
    physical_sector: u64,
}

pub(super) fn read_exact_at(path: &Path, offset: u64, size: usize) -> io::Result<Vec<u8>> {
    use std::os::unix::fs::FileExt;
    let file = File::open(path)?;
    let mut buffer = vec![0_u8; size];
    let mut read_total = 0_usize;
    while read_total < size {
        let count = file.read_at(&mut buffer[read_total..], offset + read_total as u64)?;
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "short positioned read",
            ));
        }
        read_total += count;
    }
    Ok(buffer)
}

pub(super) fn le_u16(data: &[u8], offset: usize) -> Result<u16, String> {
    let bytes: [u8; 2] = data
        .get(offset..offset + 2)
        .ok_or_else(|| "lp-read-u16-oob".to_string())?
        .try_into()
        .map_err(|_| "lp-read-u16-slice".to_string())?;
    Ok(u16::from_le_bytes(bytes))
}

pub(super) fn le_u32(data: &[u8], offset: usize) -> Result<u32, String> {
    let bytes: [u8; 4] = data
        .get(offset..offset + 4)
        .ok_or_else(|| "lp-read-u32-oob".to_string())?
        .try_into()
        .map_err(|_| "lp-read-u32-slice".to_string())?;
    Ok(u32::from_le_bytes(bytes))
}

pub(super) fn le_u64(data: &[u8], offset: usize) -> Result<u64, String> {
    let bytes: [u8; 8] = data
        .get(offset..offset + 8)
        .ok_or_else(|| "lp-read-u64-oob".to_string())?
        .try_into()
        .map_err(|_| "lp-read-u64-slice".to_string())?;
    Ok(u64::from_le_bytes(bytes))
}

pub(super) fn c_name(data: &[u8]) -> String {
    let end = data
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(data.len());
    String::from_utf8_lossy(&data[..end]).into_owned()
}

pub(super) fn sha256_bytes(data: &[u8]) -> [u8; 32] {
    let digest = Sha256::digest(data);
    let mut out = [0_u8; 32];
    out.copy_from_slice(&digest);
    out
}

pub(super) fn validate_lp_geometry_checksum(geometry: &[u8]) -> Result<(), String> {
    let struct_size = le_u32(geometry, 4)? as usize;
    if struct_size > geometry.len() || struct_size < 52 {
        return Err(format!("lp-geometry-size:{struct_size}"));
    }
    let expected = geometry
        .get(8..40)
        .ok_or_else(|| "lp-geometry-checksum-oob".to_string())?;
    let mut checksum_input = geometry[..struct_size].to_vec();
    checksum_input[8..40].fill(0);
    if sha256_bytes(&checksum_input) != expected {
        return Err("lp-geometry-checksum".to_string());
    }
    Ok(())
}

pub(super) fn validate_lp_header_checksum(header: &[u8], header_size: usize) -> Result<(), String> {
    let expected = header
        .get(12..44)
        .ok_or_else(|| "lp-header-checksum-oob".to_string())?;
    let mut checksum_input = header
        .get(..header_size)
        .ok_or_else(|| "lp-header-checksum-size".to_string())?
        .to_vec();
    checksum_input[12..44].fill(0);
    if sha256_bytes(&checksum_input) != expected {
        return Err("lp-header-checksum".to_string());
    }
    Ok(())
}

pub(super) fn validate_lp_table_checksum(header: &[u8], tables: &[u8]) -> Result<(), String> {
    let expected = header
        .get(48..80)
        .ok_or_else(|| "lp-tables-checksum-oob".to_string())?;
    if sha256_bytes(tables) != expected {
        return Err("lp-tables-checksum".to_string());
    }
    Ok(())
}

pub(super) fn validate_lp_table_bounds(
    tables_size: usize,
    offset: usize,
    count: usize,
    entry_size: usize,
    label: &str,
) -> Result<(), String> {
    let table_size = count
        .checked_mul(entry_size)
        .ok_or_else(|| format!("lp-{label}-table-size-overflow"))?;
    let end = offset
        .checked_add(table_size)
        .ok_or_else(|| format!("lp-{label}-table-end-overflow"))?;
    if end > tables_size {
        return Err(format!(
            "lp-{label}-table-bounds:{offset}+{table_size}>{tables_size}"
        ));
    }
    Ok(())
}

pub(super) fn find_logical_partition_extents(
    partition_name: &str,
) -> Result<Vec<LogicalExtent>, String> {
    const LP_METADATA_GEOMETRY_MAGIC: u32 = 0x616c4467;
    const LP_METADATA_HEADER_MAGIC: u32 = 0x414c5030;
    const LP_METADATA_GEOMETRY_SIZE: u64 = 4096;
    const LP_PARTITION_RESERVED_BYTES: u64 = 4096;
    const LP_TARGET_TYPE_LINEAR: u32 = 0;
    const LP_PARTITION_ENTRY_SIZE: usize = 52;
    const LP_EXTENT_ENTRY_SIZE: usize = 24;

    let geometry = read_exact_at(
        Path::new(SUPER_DEVICE_PATH),
        LP_PARTITION_RESERVED_BYTES,
        LP_METADATA_GEOMETRY_SIZE as usize,
    )
    .map_err(|error| format!("lp-geometry-read:{error}"))?;
    if le_u32(&geometry, 0)? != LP_METADATA_GEOMETRY_MAGIC {
        return Err("lp-geometry-magic".to_string());
    }
    validate_lp_geometry_checksum(&geometry)?;
    let metadata_max_size = le_u32(&geometry, 40)? as u64;
    let slot_count = le_u32(&geometry, 44)? as u64;
    if metadata_max_size == 0 || metadata_max_size % 512 != 0 {
        return Err(format!("lp-metadata-max-size:{metadata_max_size}"));
    }
    let slot_suffix = active_slot_suffix().unwrap_or_else(|| "_a".to_string());
    let slot_index = match slot_suffix.as_str() {
        "_a" => 0_u64,
        "_b" => 1_u64,
        _ => 0_u64,
    };
    if slot_index >= slot_count {
        return Err(format!("lp-slot-out-of-range:{slot_suffix}/{slot_count}"));
    }
    let metadata_offset = LP_PARTITION_RESERVED_BYTES
        + (LP_METADATA_GEOMETRY_SIZE * 2)
        + metadata_max_size * slot_index;
    let header_prefix = read_exact_at(Path::new(SUPER_DEVICE_PATH), metadata_offset, 256)
        .map_err(|error| format!("lp-header-read:{error}"))?;
    if le_u32(&header_prefix, 0)? != LP_METADATA_HEADER_MAGIC {
        return Err("lp-header-magic".to_string());
    }
    if le_u16(&header_prefix, 4)? != 10 {
        return Err(format!("lp-header-major:{}", le_u16(&header_prefix, 4)?));
    }
    let header_size = le_u32(&header_prefix, 8)? as usize;
    if header_size > header_prefix.len() || header_size < 128 {
        return Err(format!("lp-header-size:{header_size}"));
    }
    validate_lp_header_checksum(&header_prefix, header_size)?;
    let tables_size = le_u32(&header_prefix, 44)? as usize;
    if tables_size > metadata_max_size as usize {
        return Err(format!("lp-tables-size:{tables_size}>{metadata_max_size}"));
    }
    let partitions_offset = le_u32(&header_prefix, 80)? as usize;
    let partitions_count = le_u32(&header_prefix, 84)? as usize;
    let partitions_entry_size = le_u32(&header_prefix, 88)? as usize;
    let extents_offset = le_u32(&header_prefix, 92)? as usize;
    let extents_count = le_u32(&header_prefix, 96)? as usize;
    let extents_entry_size = le_u32(&header_prefix, 100)? as usize;
    if partitions_entry_size < LP_PARTITION_ENTRY_SIZE {
        return Err(format!("lp-partition-entry-size:{partitions_entry_size}"));
    }
    if extents_entry_size < LP_EXTENT_ENTRY_SIZE {
        return Err(format!("lp-extent-entry-size:{extents_entry_size}"));
    }
    validate_lp_table_bounds(
        tables_size,
        partitions_offset,
        partitions_count,
        partitions_entry_size,
        "partition",
    )?;
    validate_lp_table_bounds(
        tables_size,
        extents_offset,
        extents_count,
        extents_entry_size,
        "extent",
    )?;
    let tables = read_exact_at(
        Path::new(SUPER_DEVICE_PATH),
        metadata_offset + header_size as u64,
        tables_size,
    )
    .map_err(|error| format!("lp-tables-read:{error}"))?;
    validate_lp_table_checksum(&header_prefix, &tables)?;
    let partition_table = tables
        .get(partitions_offset..)
        .ok_or_else(|| "lp-partition-table-oob".to_string())?;
    let extent_table = tables
        .get(extents_offset..)
        .ok_or_else(|| "lp-extent-table-oob".to_string())?;

    for index in 0..partitions_count {
        let start = index * partitions_entry_size;
        let Some(entry) = partition_table.get(start..start + partitions_entry_size) else {
            return Err("lp-partition-entry-oob".to_string());
        };
        let name = c_name(&entry[..36]);
        if name != partition_name {
            continue;
        }
        let first_extent = le_u32(entry, 40)? as usize;
        let num_extents = le_u32(entry, 44)? as usize;
        if first_extent + num_extents > extents_count {
            return Err("lp-partition-extents-oob".to_string());
        }
        let mut logical_start = 0_u64;
        let mut extents = Vec::new();
        for extent_index in first_extent..first_extent + num_extents {
            let extent_start = extent_index * extents_entry_size;
            let Some(extent) = extent_table.get(extent_start..extent_start + extents_entry_size)
            else {
                return Err("lp-extent-entry-oob".to_string());
            };
            let sectors = le_u64(extent, 0)?;
            let target_type = le_u32(extent, 8)?;
            let physical_sector = le_u64(extent, 12)?;
            let target_source = le_u32(extent, 20)?;
            if target_type != LP_TARGET_TYPE_LINEAR {
                return Err(format!("lp-extent-target-type:{target_type}"));
            }
            if target_source != 0 {
                return Err(format!("lp-extent-target-source:{target_source}"));
            }
            extents.push(LogicalExtent {
                logical_start,
                sectors,
                physical_sector,
            });
            logical_start = logical_start.saturating_add(sectors);
        }
        if extents.is_empty() {
            return Err("lp-partition-empty".to_string());
        }
        return Ok(extents);
    }
    Err(format!("lp-partition-missing:{partition_name}"))
}

#[repr(C)]
#[derive(Clone, Copy)]
pub(super) struct DmIoctl {
    version: [u32; 3],
    data_size: u32,
    data_start: u32,
    target_count: u32,
    open_count: i32,
    flags: u32,
    event_nr: u32,
    padding: u32,
    dev: u64,
    name: [u8; 128],
    uuid: [u8; 129],
    data: [u8; 7],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub(super) struct DmTargetSpec {
    sector_start: u64,
    length: u64,
    status: i32,
    next: u32,
    target_type: [u8; 16],
}

pub(super) fn dm_ioctl_init(name: &str) -> DmIoctl {
    let mut io = DmIoctl {
        version: [4, 0, 0],
        data_size: std::mem::size_of::<DmIoctl>() as u32,
        data_start: 0,
        target_count: 0,
        open_count: 0,
        flags: 0,
        event_nr: 0,
        padding: 0,
        dev: 0,
        name: [0; 128],
        uuid: [0; 129],
        data: [0; 7],
    };
    let bytes = name.as_bytes();
    let len = bytes.len().min(io.name.len() - 1);
    io.name[..len].copy_from_slice(&bytes[..len]);
    io
}

pub(super) fn align8(value: usize) -> usize {
    (value + 7) & !7
}

pub(super) fn append_dm_linear_target(buffer: &mut Vec<u8>, extent: &LogicalExtent) {
    let params = format!("{SUPER_DEVICE_PATH} {}", extent.physical_sector);
    let record_len = align8(std::mem::size_of::<DmTargetSpec>() + params.len() + 1);
    let mut spec = DmTargetSpec {
        sector_start: extent.logical_start,
        length: extent.sectors,
        status: 0,
        next: record_len as u32,
        target_type: [0; 16],
    };
    spec.target_type[..6].copy_from_slice(b"linear");
    let spec_bytes = unsafe {
        std::slice::from_raw_parts(
            (&spec as *const DmTargetSpec).cast::<u8>(),
            std::mem::size_of::<DmTargetSpec>(),
        )
    };
    buffer.extend_from_slice(spec_bytes);
    buffer.extend_from_slice(params.as_bytes());
    buffer.push(0);
    while buffer.len() % 8 != 0 {
        buffer.push(0);
    }
}

pub(super) fn create_shadow_payload_dm_linear(partition_name: &str) -> Result<String, String> {
    const DM_DEV_CREATE: libc::c_int = 0xc138fd03_u32 as libc::c_int;
    const DM_DEV_SUSPEND: libc::c_int = 0xc138fd06_u32 as libc::c_int;
    const DM_TABLE_LOAD: libc::c_int = 0xc138fd09_u32 as libc::c_int;
    const DM_READONLY_FLAG: u32 = 1 << 0;

    let extents = find_logical_partition_extents(partition_name)?;
    ensure_directory(Path::new("/dev/block/mapper"), 0o755)
        .map_err(|error| format!("dm-mapper-dir:{error}"))?;
    ensure_char_device(Path::new("/dev/device-mapper"), 0o600, 10, 236)
        .map_err(|error| format!("dm-control-node:{error}"))?;

    let control = CString::new("/dev/device-mapper").unwrap();
    let fd = unsafe { libc::open(control.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(format!("dm-control-open:{}", io::Error::last_os_error()));
    }

    let mut create = dm_ioctl_init(partition_name);
    let rc = unsafe { libc::ioctl(fd, DM_DEV_CREATE, &mut create) };
    if rc != 0 {
        let error = io::Error::last_os_error();
        unsafe {
            libc::close(fd);
        }
        return Err(format!("dm-dev-create:{error}"));
    }

    let mut payload = vec![0_u8; std::mem::size_of::<DmIoctl>()];
    for extent in &extents {
        append_dm_linear_target(&mut payload, extent);
    }
    let io = payload.as_mut_ptr().cast::<DmIoctl>();
    unsafe {
        *io = dm_ioctl_init(partition_name);
        (*io).data_size = payload.len() as u32;
        (*io).data_start = std::mem::size_of::<DmIoctl>() as u32;
        (*io).target_count = extents.len() as u32;
        (*io).flags |= DM_READONLY_FLAG;
    }
    let rc = unsafe { libc::ioctl(fd, DM_TABLE_LOAD, io) };
    if rc != 0 {
        let error = io::Error::last_os_error();
        unsafe {
            libc::close(fd);
        }
        return Err(format!("dm-table-load:{error}"));
    }

    let mut suspend = dm_ioctl_init(partition_name);
    let rc = unsafe { libc::ioctl(fd, DM_DEV_SUSPEND, &mut suspend) };
    if rc != 0 {
        let error = io::Error::last_os_error();
        unsafe {
            libc::close(fd);
        }
        return Err(format!("dm-dev-suspend:{error}"));
    }
    unsafe {
        libc::close(fd);
    }

    let major_num = libc::major(suspend.dev as libc::dev_t) as u64;
    let minor_num = libc::minor(suspend.dev as libc::dev_t) as u64;
    let dm_path = format!("/dev/block/mapper/{partition_name}");
    ensure_block_device(Path::new(&dm_path), 0o600, major_num, minor_num)
        .map_err(|error| format!("dm-node:{error}"))?;
    Ok(dm_path)
}

pub(super) fn write_atomic_text_file(
    temp_path: &Path,
    final_path: &Path,
    contents: &str,
) -> io::Result<()> {
    let parent = final_path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "missing parent"))?;
    {
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(temp_path)?;
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
    }
    fs::rename(temp_path, final_path)?;
    let dir = File::open(parent)?;
    dir.sync_all()?;
    Ok(())
}

pub(super) fn sync_directory(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}

pub(super) fn write_metadata_stage(runtime: &mut MetadataStageRuntime, value: &str) {
    if !runtime.enabled || runtime.write_failed || !runtime.prepared {
        return;
    }
    let payload = format!("{value}\n");
    if write_atomic_text_file(&runtime.temp_stage_path, &runtime.stage_path, &payload).is_err() {
        runtime.write_failed = true;
    }
}

pub(super) fn write_payload_probe_stage(path: Option<&Path>, prefix: Option<&str>, value: &str) {
    let (Some(path), Some(prefix)) = (path, prefix) else {
        return;
    };
    let temp_path = path.with_extension("tmp");
    let payload = format!("{prefix}:{value}\n");
    let _ = write_atomic_text_file(&temp_path, path, &payload);
}
