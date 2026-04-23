use serde_json::{json, Value};
use std::env;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::process::Command;

macro_rules! read_u16 {
    ($field:expr) => {
        unsafe { std::ptr::addr_of!($field).read_unaligned() }
    };
}

macro_rules! read_u32 {
    ($field:expr) => {
        unsafe { std::ptr::addr_of!($field).read_unaligned() }
    };
}

macro_rules! read_i32 {
    ($field:expr) => {
        unsafe { std::ptr::addr_of!($field).read_unaligned() }
    };
}

macro_rules! read_u64 {
    ($field:expr) => {
        unsafe { std::ptr::addr_of!($field).read_unaligned() }
    };
}

const SCHEMA_VERSION: u32 = 1;

const IOC_NRBITS: u64 = 8;
const IOC_TYPEBITS: u64 = 8;
const IOC_SIZEBITS: u64 = 14;
const IOC_NRSHIFT: u64 = 0;
const IOC_TYPESHIFT: u64 = IOC_NRSHIFT + IOC_NRBITS;
const IOC_SIZESHIFT: u64 = IOC_TYPESHIFT + IOC_TYPEBITS;
const IOC_DIRSHIFT: u64 = IOC_SIZESHIFT + IOC_SIZEBITS;
const IOC_WRITE: u64 = 1;
const IOC_READ: u64 = 2;

const CAM_COMMON_OPCODE_BASE: u32 = 0x100;
const CAM_QUERY_CAP: u32 = CAM_COMMON_OPCODE_BASE + 0x1;
const CAM_HANDLE_USER_POINTER: u32 = 1;

const BASE_VIDIOC_PRIVATE: u8 = 192;

type IoctlRequest = libc::Ioctl;

const fn ioc(dir: u64, ty: u8, nr: u8, size: usize) -> IoctlRequest {
    ((dir << IOC_DIRSHIFT)
        | ((ty as u64) << IOC_TYPESHIFT)
        | ((nr as u64) << IOC_NRSHIFT)
        | ((size as u64) << IOC_SIZESHIFT)) as IoctlRequest
}

const fn ior<T>(ty: u8, nr: u8) -> IoctlRequest {
    ioc(IOC_READ, ty, nr, std::mem::size_of::<T>())
}

const fn iowr<T>(ty: u8, nr: u8) -> IoctlRequest {
    ioc(IOC_READ | IOC_WRITE, ty, nr, std::mem::size_of::<T>())
}

const VIDIOC_QUERYCAP: IoctlRequest = ior::<V4l2Capability>(b'V', 0);
const VIDIOC_SUBDEV_QUERYCAP: IoctlRequest = ior::<V4l2SubdevCapability>(b'V', 0);
const VIDIOC_CAM_CONTROL: IoctlRequest = iowr::<CamControl>(b'V', BASE_VIDIOC_PRIVATE);
const MEDIA_IOC_DEVICE_INFO: IoctlRequest = iowr::<MediaDeviceInfo>(b'|', 0x00);
const MEDIA_IOC_G_TOPOLOGY: IoctlRequest = iowr::<MediaV2Topology>(b'|', 0x04);
const MEDIA_IOC_ENUM_ENTITIES: IoctlRequest = iowr::<MediaEntityDesc>(b'|', 0x01);

#[repr(C)]
#[derive(Clone, Copy)]
struct V4l2Capability {
    driver: [u8; 16],
    card: [u8; 32],
    bus_info: [u8; 32],
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [u32; 3],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct V4l2SubdevCapability {
    version: u32,
    capabilities: u32,
    reserved: [u32; 14],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MediaDeviceInfo {
    driver: [u8; 16],
    model: [u8; 32],
    serial: [u8; 40],
    bus_info: [u8; 32],
    media_version: u32,
    hw_revision: u32,
    driver_version: u32,
    reserved: [u32; 31],
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct MediaV2Entity {
    id: u32,
    name: [u8; 64],
    function: u32,
    reserved: [u32; 6],
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct MediaV2Interface {
    id: u32,
    intf_type: u32,
    flags: u32,
    reserved: [u32; 9],
    raw: [u32; 16],
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct MediaV2Pad {
    id: u32,
    entity_id: u32,
    flags: u32,
    reserved: [u32; 5],
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct MediaV2Link {
    id: u32,
    source_id: u32,
    sink_id: u32,
    flags: u32,
    reserved: [u32; 6],
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct MediaV2Topology {
    topology_version: u64,
    num_entities: u32,
    reserved1: u32,
    ptr_entities: u64,
    num_interfaces: u32,
    reserved2: u32,
    ptr_interfaces: u64,
    num_pads: u32,
    reserved3: u32,
    ptr_pads: u64,
    num_links: u32,
    reserved4: u32,
    ptr_links: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct MediaEntityDesc {
    id: u32,
    name: [u8; 32],
    entity_type: u32,
    revision: u32,
    flags: u32,
    group_id: u32,
    pads: u16,
    links: u16,
    reserved: [u32; 4],
    raw: [u8; 184],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamControl {
    op_code: u32,
    size: u32,
    handle_type: u32,
    reserved: u32,
    handle: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamQueryCapCmd {
    size: u32,
    handle_type: u32,
    caps_handle: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamHwVersion {
    major: u32,
    minor: u32,
    incr: u32,
    reserved: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamIommuHandle {
    non_secure: i32,
    secure: i32,
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct CamSensorQueryCap {
    slot_info: u32,
    secure_camera: u32,
    pos_pitch: u32,
    pos_roll: u32,
    pos_yaw: u32,
    actuator_slot_id: u32,
    eeprom_slot_id: u32,
    ois_slot_id: u32,
    flash_slot_id: u32,
    csiphy_slot_id: u32,
    ir_led_slot_id: i32,
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct CamCsiphyQueryCap {
    slot_info: u32,
    version: u32,
    clk_lane: u32,
    reserved: u32,
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct CamActuatorQueryCap {
    slot_info: u32,
    reserved: u32,
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct CamEepromQueryCap {
    slot_info: u32,
    eeprom_kernel_probe: u16,
    reserved: u16,
}

#[repr(C, packed)]
#[derive(Clone, Copy)]
struct CamOisQueryCap {
    slot_info: u32,
    reserved: u16,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamCpasQueryCap {
    camera_family: u32,
    reserved: u32,
    camera_version: CamHwVersion,
    cpas_version: CamHwVersion,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamIspDevCapInfo {
    hw_type: u32,
    reserved: u32,
    hw_version: CamHwVersion,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamIspQueryCap {
    device_iommu: CamIommuHandle,
    cdm_iommu: CamIommuHandle,
    num_dev: i32,
    reserved: u32,
    dev_caps: [CamIspDevCapInfo; 5],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamJpegDevVer {
    size: u32,
    dev_type: u32,
    hw_ver: CamHwVersion,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamJpegQueryCap {
    dev_iommu_handle: CamIommuHandle,
    cdm_iommu_handle: CamIommuHandle,
    num_enc: u32,
    num_dma: u32,
    dev_ver: [CamJpegDevVer; 2],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamFdHwCaps {
    core_version: CamHwVersion,
    wrapper_version: CamHwVersion,
    raw_results_available: u32,
    supported_modes: u32,
    reserved: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamFdQueryCap {
    device_iommu: CamIommuHandle,
    cdm_iommu: CamIommuHandle,
    hw_caps: CamFdHwCaps,
    reserved: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamLrmeHwVersion {
    gen: u32,
    rev: u32,
    step: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamLrmeDevCap {
    clc_hw_version: CamLrmeHwVersion,
    bus_rd_hw_version: CamLrmeHwVersion,
    bus_wr_hw_version: CamLrmeHwVersion,
    top_hw_version: CamLrmeHwVersion,
    top_titan_version: CamLrmeHwVersion,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CamLrmeQueryCap {
    device_iommu: CamIommuHandle,
    cdm_iommu: CamIommuHandle,
    num_devices: u32,
    dev_caps: [CamLrmeDevCap; 1],
}

#[derive(Clone, Copy)]
enum PayloadKind {
    Sensor,
    Cpas,
    Csiphy,
    Actuator,
    Eeprom,
    Ois,
    Isp,
    Jpeg,
    Fd,
    Lrme,
}

impl PayloadKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Sensor => "sensor",
            Self::Cpas => "cpas",
            Self::Csiphy => "csiphy",
            Self::Actuator => "actuator",
            Self::Eeprom => "eeprom",
            Self::Ois => "ois",
            Self::Isp => "isp",
            Self::Jpeg => "jpeg",
            Self::Fd => "fd",
            Self::Lrme => "lrme",
        }
    }
}

pub fn make_linux_probe_response(argv: &[OsString]) -> Value {
    let argv_strings = argv_strings(argv);
    let android_camera_provider = android_camera_provider_state();
    let media_nodes = collect_dev_nodes("media");
    let video_nodes = collect_dev_nodes("video");
    let subdev_nodes = collect_dev_nodes("v4l-subdev");
    let mut ioctl_successes = 0usize;
    let mut exclusive_open_notes = Vec::new();

    let media_devices = media_nodes
        .iter()
        .map(|path| probe_media_device(path, &mut ioctl_successes))
        .collect::<Vec<_>>();

    let video_node_results = video_nodes
        .iter()
        .map(|path| probe_video_node(path, &mut ioctl_successes, &mut exclusive_open_notes))
        .collect::<Vec<_>>();

    let mut qualcomm_query_caps = Vec::new();
    let subdev_node_results = subdev_nodes
        .iter()
        .map(|path| {
            probe_subdev_node(
                path,
                &mut ioctl_successes,
                &mut qualcomm_query_caps,
                &mut exclusive_open_notes,
            )
        })
        .collect::<Vec<_>>();

    let discovered_nodes = media_nodes.len() + video_nodes.len() + subdev_nodes.len();
    let interpretation = if discovered_nodes == 0 {
        "blocked"
    } else if qualcomm_query_caps
        .iter()
        .any(|value| value.get("ok").and_then(Value::as_bool) == Some(true))
    {
        "topology-visible"
    } else if ioctl_successes > 0 {
        "surface-inventory-only"
    } else {
        "blocked"
    };

    json!({
        "ok": true,
        "command": "linux-probe",
        "schemaVersion": SCHEMA_VERSION,
        "pid": std::process::id(),
        "cwd": current_dir_string(),
        "argv": argv_strings,
        "serial": command_stdout("getprop", &["ro.serialno"]),
        "fingerprint": command_stdout("getprop", &["ro.build.fingerprint"]),
        "kernelRelease": command_stdout("uname", &["-r"]),
        "selinuxMode": command_stdout("getenforce", &[]),
        "androidCameraProviderDeclared": android_camera_provider
            .get("providerInternal0")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        "androidCameraProviderServices": android_camera_provider,
        "nodeCounts": {
            "media": media_nodes.len(),
            "video": video_nodes.len(),
            "subdev": subdev_nodes.len(),
        },
        "mediaDevices": media_devices,
        "videoNodes": video_node_results,
        "subdevNodes": subdev_node_results,
        "qualcommQueryCaps": qualcomm_query_caps,
        "exclusiveOpenNotes": exclusive_open_notes,
        "forbiddenIoctls": [
            "CAM_SENSOR_PROBE_CMD",
            "CAM_ACQUIRE_DEV",
            "CAM_START_DEV",
            "CAM_STOP_DEV",
            "CAM_CONFIG_DEV",
            "CAM_REQ_MGR_CREATE_SESSION",
            "CAM_REQ_MGR_LINK",
            "CAM_REQ_MGR_SCHED_REQ",
            "CAM_SYNC_CREATE",
            "CAM_SYNC_DESTROY",
            "CAM_SYNC_WAIT",
            "VIDIOC_REQBUFS",
        ],
        "ioctlSuccesses": ioctl_successes,
        "interpretation": interpretation,
    })
}

fn probe_media_device(path: &Path, ioctl_successes: &mut usize) -> Value {
    let base = node_base_json(path);
    let file = match open_read(path) {
        Ok(file) => file,
        Err(error) => {
            return extend_json(
                base,
                json!({
                    "open": errno_json(&error),
                }),
            );
        }
    };

    let mut device_info = unsafe_zeroed::<MediaDeviceInfo>();
    let device_info_json = match ioctl_mut(&file, MEDIA_IOC_DEVICE_INFO, &mut device_info) {
        Ok(()) => {
            *ioctl_successes += 1;
            json!({
                "ok": true,
                "driver": c_array_string(&device_info.driver),
                "model": c_array_string(&device_info.model),
                "serial": c_array_string(&device_info.serial),
                "busInfo": c_array_string(&device_info.bus_info),
                "mediaVersion": device_info.media_version,
                "hwRevision": device_info.hw_revision,
                "driverVersion": device_info.driver_version,
            })
        }
        Err(error) => errno_json(&error),
    };

    let topology_json = probe_media_topology(&file, ioctl_successes);

    extend_json(
        base,
        json!({
            "open": {"ok": true, "mode": "read"},
            "deviceInfo": device_info_json,
            "topology": topology_json,
        }),
    )
}

fn probe_media_topology(file: &File, ioctl_successes: &mut usize) -> Value {
    let mut counts = unsafe_zeroed::<MediaV2Topology>();
    if let Err(error) = ioctl_mut(file, MEDIA_IOC_G_TOPOLOGY, &mut counts) {
        return json!({
            "ok": false,
            "gTopology": errno_json(&error),
            "legacyEntities": probe_legacy_media_entities(file, ioctl_successes),
        });
    }

    *ioctl_successes += 1;
    let num_entities = read_u32!(counts.num_entities);
    let num_interfaces = read_u32!(counts.num_interfaces);
    let num_pads = read_u32!(counts.num_pads);
    let num_links = read_u32!(counts.num_links);
    let topology_version = read_u64!(counts.topology_version);

    let sane = [num_entities, num_interfaces, num_pads, num_links]
        .into_iter()
        .all(|count| count <= 4096);
    if !sane {
        return json!({
            "ok": false,
            "topologyVersion": topology_version,
            "counts": {
                "entities": num_entities,
                "interfaces": num_interfaces,
                "pads": num_pads,
                "links": num_links,
            },
            "error": "media topology counts exceeded safety cap",
        });
    }

    let mut entities = vec![unsafe_zeroed::<MediaV2Entity>(); num_entities as usize];
    let mut interfaces = vec![unsafe_zeroed::<MediaV2Interface>(); num_interfaces as usize];
    let mut pads = vec![unsafe_zeroed::<MediaV2Pad>(); num_pads as usize];
    let mut links = vec![unsafe_zeroed::<MediaV2Link>(); num_links as usize];
    let mut topology = MediaV2Topology {
        topology_version,
        num_entities,
        reserved1: 0,
        ptr_entities: entities.as_mut_ptr() as u64,
        num_interfaces,
        reserved2: 0,
        ptr_interfaces: interfaces.as_mut_ptr() as u64,
        num_pads,
        reserved3: 0,
        ptr_pads: pads.as_mut_ptr() as u64,
        num_links,
        reserved4: 0,
        ptr_links: links.as_mut_ptr() as u64,
    };

    match ioctl_mut(file, MEDIA_IOC_G_TOPOLOGY, &mut topology) {
        Ok(()) => {
            *ioctl_successes += 1;
            json!({
                "ok": true,
                "topologyVersion": read_u64!(topology.topology_version),
                "counts": {
                    "entities": read_u32!(topology.num_entities),
                    "interfaces": read_u32!(topology.num_interfaces),
                    "pads": read_u32!(topology.num_pads),
                    "links": read_u32!(topology.num_links),
                },
                "entities": entities.iter().map(media_v2_entity_json).collect::<Vec<_>>(),
                "interfaces": interfaces.iter().map(media_v2_interface_json).collect::<Vec<_>>(),
                "pads": pads.iter().map(media_v2_pad_json).collect::<Vec<_>>(),
                "links": links.iter().map(media_v2_link_json).collect::<Vec<_>>(),
            })
        }
        Err(error) => json!({
            "ok": false,
            "topologyVersion": topology_version,
            "counts": {
                "entities": num_entities,
                "interfaces": num_interfaces,
                "pads": num_pads,
                "links": num_links,
            },
            "gTopology": errno_json(&error),
        }),
    }
}

fn probe_legacy_media_entities(file: &File, ioctl_successes: &mut usize) -> Value {
    let mut entities = Vec::new();
    for index in 0..256u32 {
        let mut desc = unsafe_zeroed::<MediaEntityDesc>();
        desc.id = index | (1 << 31);
        match ioctl_mut(file, MEDIA_IOC_ENUM_ENTITIES, &mut desc) {
            Ok(()) => {
                *ioctl_successes += 1;
                entities.push(json!({
                    "id": desc.id,
                    "name": c_array_string(&desc.name),
                    "type": desc.entity_type,
                    "revision": desc.revision,
                    "flags": desc.flags,
                    "groupId": desc.group_id,
                    "pads": desc.pads,
                    "links": desc.links,
                }));
            }
            Err(error) => {
                return json!({
                    "ok": !entities.is_empty(),
                    "entities": entities,
                    "stopIndex": index,
                    "stopError": errno_json(&error),
                });
            }
        }
    }

    json!({
        "ok": !entities.is_empty(),
        "entities": entities,
        "truncated": true,
    })
}

fn probe_video_node(
    path: &Path,
    ioctl_successes: &mut usize,
    exclusive_open_notes: &mut Vec<Value>,
) -> Value {
    let name = video4linux_name(path);
    let mut base = node_base_json(path);
    base["sysfsName"] = json!(name.clone());

    if name.as_deref() == Some("cam-req-mgr") {
        let note = json!({
            "node": path.to_string_lossy(),
            "sysfsName": name.clone(),
            "reason": "skipped direct open by default; cam_req_mgr_dev.c allows one opener and close runs request-manager shutdown",
        });
        exclusive_open_notes.push(note.clone());
        return extend_json(
            base,
            json!({
                "open": {"ok": false, "skipped": true, "reason": "exclusive cam-req-mgr node"},
                "querycap": {"ok": false, "skipped": true},
            }),
        );
    }

    let file = match open_read(path) {
        Ok(file) => file,
        Err(error) => {
            return extend_json(base, json!({"open": errno_json(&error)}));
        }
    };

    let mut capability = unsafe_zeroed::<V4l2Capability>();
    let querycap = match ioctl_mut(&file, VIDIOC_QUERYCAP, &mut capability) {
        Ok(()) => {
            *ioctl_successes += 1;
            v4l2_capability_json(&capability)
        }
        Err(error) => errno_json(&error),
    };

    extend_json(
        base,
        json!({
            "open": {"ok": true, "mode": "read"},
            "querycap": querycap,
        }),
    )
}

fn probe_subdev_node(
    path: &Path,
    ioctl_successes: &mut usize,
    qualcomm_query_caps: &mut Vec<Value>,
    exclusive_open_notes: &mut Vec<Value>,
) -> Value {
    let name = video4linux_name(path);
    let mut base = node_base_json(path);
    base["sysfsName"] = json!(name.clone());

    let file = match open_read_write(path) {
        Ok(file) => file,
        Err(error) => {
            return extend_json(base, json!({"open": errno_json(&error)}));
        }
    };

    let mut capability = unsafe_zeroed::<V4l2SubdevCapability>();
    let querycap = match ioctl_mut(&file, VIDIOC_SUBDEV_QUERYCAP, &mut capability) {
        Ok(()) => {
            *ioctl_successes += 1;
            json!({
                "ok": true,
                "version": capability.version,
                "capabilities": capability.capabilities,
                "capabilitiesHex": format_u32_hex(capability.capabilities),
            })
        }
        Err(error) => errno_json(&error),
    };

    let payload_kind = name.as_deref().and_then(payload_kind_for_name);
    if let Some(kind) = payload_kind {
        let result = query_qualcomm_cap(&file, path, name.as_deref(), kind);
        if result.get("ok").and_then(Value::as_bool) == Some(true) {
            *ioctl_successes += 1;
        }
        if name.as_deref() == Some("cam-sensor-driver") {
            exclusive_open_notes.push(json!({
                "node": path.to_string_lossy(),
                "sysfsName": name.clone(),
                "reason": "sensor subdev close path calls cam_sensor_shutdown; probe only uses CAM_QUERY_CAP and must run with no active Android camera session",
            }));
        }
        qualcomm_query_caps.push(result);
    }

    extend_json(
        base,
        json!({
            "open": {"ok": true, "mode": "read-write"},
            "querycap": querycap,
            "qualcommPayloadKind": payload_kind.map(PayloadKind::as_str),
        }),
    )
}

fn query_qualcomm_cap(
    file: &File,
    path: &Path,
    sysfs_name: Option<&str>,
    kind: PayloadKind,
) -> Value {
    match kind {
        PayloadKind::Sensor => query_direct::<CamSensorQueryCap, _>(
            file,
            path,
            sysfs_name,
            kind,
            cam_sensor_query_json,
        ),
        PayloadKind::Cpas => {
            query_direct::<CamCpasQueryCap, _>(file, path, sysfs_name, kind, cam_cpas_query_json)
        }
        PayloadKind::Csiphy => query_direct::<CamCsiphyQueryCap, _>(
            file,
            path,
            sysfs_name,
            kind,
            cam_csiphy_query_json,
        ),
        PayloadKind::Actuator => query_direct::<CamActuatorQueryCap, _>(
            file,
            path,
            sysfs_name,
            kind,
            cam_actuator_query_json,
        ),
        PayloadKind::Eeprom => query_direct::<CamEepromQueryCap, _>(
            file,
            path,
            sysfs_name,
            kind,
            cam_eeprom_query_json,
        ),
        PayloadKind::Ois => {
            query_direct::<CamOisQueryCap, _>(file, path, sysfs_name, kind, cam_ois_query_json)
        }
        PayloadKind::Isp => {
            query_nested::<CamIspQueryCap, _>(file, path, sysfs_name, kind, cam_isp_query_json)
        }
        PayloadKind::Jpeg => {
            query_nested::<CamJpegQueryCap, _>(file, path, sysfs_name, kind, cam_jpeg_query_json)
        }
        PayloadKind::Fd => {
            query_nested::<CamFdQueryCap, _>(file, path, sysfs_name, kind, cam_fd_query_json)
        }
        PayloadKind::Lrme => {
            query_nested::<CamLrmeQueryCap, _>(file, path, sysfs_name, kind, cam_lrme_query_json)
        }
    }
}

fn query_direct<T, F>(
    file: &File,
    path: &Path,
    sysfs_name: Option<&str>,
    kind: PayloadKind,
    decode: F,
) -> Value
where
    F: Fn(&T) -> Value,
{
    let mut payload = unsafe_zeroed::<T>();
    let mut control = CamControl {
        op_code: CAM_QUERY_CAP,
        size: std::mem::size_of::<T>() as u32,
        handle_type: CAM_HANDLE_USER_POINTER,
        reserved: 0,
        handle: (&mut payload as *mut T) as u64,
    };

    match ioctl_mut(file, VIDIOC_CAM_CONTROL, &mut control) {
        Ok(()) => json!({
            "ok": true,
            "node": path.to_string_lossy(),
            "sysfsName": sysfs_name,
            "payloadKind": kind.as_str(),
            "payloadMode": "direct",
            "payloadSize": std::mem::size_of::<T>(),
            "controlSize": std::mem::size_of::<CamControl>(),
            "opCode": CAM_QUERY_CAP,
            "decoded": decode(&payload),
        }),
        Err(error) => json!({
            "ok": false,
            "node": path.to_string_lossy(),
            "sysfsName": sysfs_name,
            "payloadKind": kind.as_str(),
            "payloadMode": "direct",
            "payloadSize": std::mem::size_of::<T>(),
            "controlSize": std::mem::size_of::<CamControl>(),
            "opCode": CAM_QUERY_CAP,
            "error": errno_json(&error),
        }),
    }
}

fn query_nested<T, F>(
    file: &File,
    path: &Path,
    sysfs_name: Option<&str>,
    kind: PayloadKind,
    decode: F,
) -> Value
where
    F: Fn(&T) -> Value,
{
    let mut payload = unsafe_zeroed::<T>();
    let mut query = CamQueryCapCmd {
        size: std::mem::size_of::<T>() as u32,
        handle_type: CAM_HANDLE_USER_POINTER,
        caps_handle: (&mut payload as *mut T) as u64,
    };
    let mut control = CamControl {
        op_code: CAM_QUERY_CAP,
        size: std::mem::size_of::<CamQueryCapCmd>() as u32,
        handle_type: CAM_HANDLE_USER_POINTER,
        reserved: 0,
        handle: (&mut query as *mut CamQueryCapCmd) as u64,
    };

    match ioctl_mut(file, VIDIOC_CAM_CONTROL, &mut control) {
        Ok(()) => json!({
            "ok": true,
            "node": path.to_string_lossy(),
            "sysfsName": sysfs_name,
            "payloadKind": kind.as_str(),
            "payloadMode": "nested",
            "payloadSize": std::mem::size_of::<T>(),
            "queryCapCmdSize": std::mem::size_of::<CamQueryCapCmd>(),
            "controlSize": std::mem::size_of::<CamControl>(),
            "opCode": CAM_QUERY_CAP,
            "decoded": decode(&payload),
        }),
        Err(error) => json!({
            "ok": false,
            "node": path.to_string_lossy(),
            "sysfsName": sysfs_name,
            "payloadKind": kind.as_str(),
            "payloadMode": "nested",
            "payloadSize": std::mem::size_of::<T>(),
            "queryCapCmdSize": std::mem::size_of::<CamQueryCapCmd>(),
            "controlSize": std::mem::size_of::<CamControl>(),
            "opCode": CAM_QUERY_CAP,
            "error": errno_json(&error),
        }),
    }
}

fn payload_kind_for_name(name: &str) -> Option<PayloadKind> {
    match name {
        "cam-sensor-driver" => Some(PayloadKind::Sensor),
        "cam-cpas" => Some(PayloadKind::Cpas),
        "cam-csiphy-driver" => Some(PayloadKind::Csiphy),
        "cam-actuator-driver" => Some(PayloadKind::Actuator),
        "cam-eeprom" => Some(PayloadKind::Eeprom),
        "cam-ois" => Some(PayloadKind::Ois),
        "cam-isp" => Some(PayloadKind::Isp),
        "cam-jpeg" => Some(PayloadKind::Jpeg),
        "cam-fd" => Some(PayloadKind::Fd),
        "cam-lrme" => Some(PayloadKind::Lrme),
        _ => None,
    }
}

fn node_base_json(path: &Path) -> Value {
    json!({
        "path": path.to_string_lossy(),
        "basename": path.file_name().map(|name| name.to_string_lossy().into_owned()),
        "metadata": metadata_json(path),
        "selinuxLabel": selinux_label(path),
    })
}

fn metadata_json(path: &Path) -> Value {
    match fs::metadata(path) {
        Ok(metadata) => json!({
            "mode": format!("{:o}", metadata.mode()),
            "uid": metadata.uid(),
            "gid": metadata.gid(),
            "rdev": metadata.rdev(),
            "major": libc_major(metadata.rdev()),
            "minor": libc_minor(metadata.rdev()),
            "isCharDevice": metadata.file_type().is_char_device(),
        }),
        Err(error) => errno_json(&error),
    }
}

fn selinux_label(path: &Path) -> Option<String> {
    let output = Command::new("ls").arg("-Zd").arg(path).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn collect_dev_nodes(prefix: &str) -> Vec<PathBuf> {
    let mut paths = fs::read_dir("/dev")
        .ok()
        .into_iter()
        .flat_map(|entries| entries.filter_map(Result::ok))
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| {
                    name.starts_with(prefix)
                        && name[prefix.len()..].chars().all(|c| c.is_ascii_digit())
                })
        })
        .collect::<Vec<_>>();
    paths.sort_by_key(|path| dev_node_sort_key(path, prefix));
    paths
}

fn dev_node_sort_key(path: &Path, prefix: &str) -> u32 {
    path.file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_prefix(prefix))
        .and_then(|tail| tail.parse::<u32>().ok())
        .unwrap_or(u32::MAX)
}

fn video4linux_name(path: &Path) -> Option<String> {
    let basename = path.file_name()?.to_string_lossy();
    let name_path = format!("/sys/class/video4linux/{basename}/name");
    read_trimmed(name_path)
}

fn open_read(path: &Path) -> io::Result<File> {
    OpenOptions::new().read(true).open(path)
}

fn open_read_write(path: &Path) -> io::Result<File> {
    OpenOptions::new().read(true).write(true).open(path)
}

fn ioctl_mut<T>(file: &File, request: IoctlRequest, arg: &mut T) -> io::Result<()> {
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), request, arg as *mut T) };
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn v4l2_capability_json(capability: &V4l2Capability) -> Value {
    json!({
        "ok": true,
        "driver": c_array_string(&capability.driver),
        "card": c_array_string(&capability.card),
        "busInfo": c_array_string(&capability.bus_info),
        "version": capability.version,
        "capabilities": capability.capabilities,
        "capabilitiesHex": format_u32_hex(capability.capabilities),
        "deviceCapabilities": capability.device_caps,
        "deviceCapabilitiesHex": format_u32_hex(capability.device_caps),
    })
}

fn media_v2_entity_json(entity: &MediaV2Entity) -> Value {
    json!({
        "id": read_u32!(entity.id),
        "name": c_array_string(&entity.name),
        "function": read_u32!(entity.function),
        "functionHex": format_u32_hex(read_u32!(entity.function)),
    })
}

fn media_v2_interface_json(interface: &MediaV2Interface) -> Value {
    let raw0 = read_u32!(interface.raw[0]);
    let raw1 = read_u32!(interface.raw[1]);
    json!({
        "id": read_u32!(interface.id),
        "type": read_u32!(interface.intf_type),
        "typeHex": format_u32_hex(read_u32!(interface.intf_type)),
        "flags": read_u32!(interface.flags),
        "devnode": {
            "major": raw0,
            "minor": raw1,
        },
    })
}

fn media_v2_pad_json(pad: &MediaV2Pad) -> Value {
    json!({
        "id": read_u32!(pad.id),
        "entityId": read_u32!(pad.entity_id),
        "flags": read_u32!(pad.flags),
        "flagsHex": format_u32_hex(read_u32!(pad.flags)),
    })
}

fn media_v2_link_json(link: &MediaV2Link) -> Value {
    json!({
        "id": read_u32!(link.id),
        "sourceId": read_u32!(link.source_id),
        "sinkId": read_u32!(link.sink_id),
        "flags": read_u32!(link.flags),
        "flagsHex": format_u32_hex(read_u32!(link.flags)),
    })
}

fn cam_sensor_query_json(payload: &CamSensorQueryCap) -> Value {
    json!({
        "slotInfo": read_u32!(payload.slot_info),
        "secureCamera": read_u32!(payload.secure_camera),
        "posPitch": read_u32!(payload.pos_pitch),
        "posRoll": read_u32!(payload.pos_roll),
        "posYaw": read_u32!(payload.pos_yaw),
        "actuatorSlotId": read_u32!(payload.actuator_slot_id),
        "eepromSlotId": read_u32!(payload.eeprom_slot_id),
        "oisSlotId": read_u32!(payload.ois_slot_id),
        "flashSlotId": read_u32!(payload.flash_slot_id),
        "csiphySlotId": read_u32!(payload.csiphy_slot_id),
        "irLedSlotId": read_i32!(payload.ir_led_slot_id),
    })
}

fn cam_cpas_query_json(payload: &CamCpasQueryCap) -> Value {
    json!({
        "cameraFamily": payload.camera_family,
        "cameraVersion": cam_hw_version_json(&payload.camera_version),
        "cpasVersion": cam_hw_version_json(&payload.cpas_version),
    })
}

fn cam_csiphy_query_json(payload: &CamCsiphyQueryCap) -> Value {
    json!({
        "slotInfo": read_u32!(payload.slot_info),
        "version": read_u32!(payload.version),
        "clkLane": read_u32!(payload.clk_lane),
    })
}

fn cam_actuator_query_json(payload: &CamActuatorQueryCap) -> Value {
    json!({
        "slotInfo": read_u32!(payload.slot_info),
    })
}

fn cam_eeprom_query_json(payload: &CamEepromQueryCap) -> Value {
    json!({
        "slotInfo": read_u32!(payload.slot_info),
        "eepromKernelProbe": read_u16!(payload.eeprom_kernel_probe),
    })
}

fn cam_ois_query_json(payload: &CamOisQueryCap) -> Value {
    json!({
        "slotInfo": read_u32!(payload.slot_info),
    })
}

fn cam_isp_query_json(payload: &CamIspQueryCap) -> Value {
    json!({
        "deviceIommu": cam_iommu_json(&payload.device_iommu),
        "cdmIommu": cam_iommu_json(&payload.cdm_iommu),
        "numDev": payload.num_dev,
        "devCaps": payload.dev_caps.iter().map(cam_isp_dev_cap_json).collect::<Vec<_>>(),
    })
}

fn cam_jpeg_query_json(payload: &CamJpegQueryCap) -> Value {
    json!({
        "deviceIommu": cam_iommu_json(&payload.dev_iommu_handle),
        "cdmIommu": cam_iommu_json(&payload.cdm_iommu_handle),
        "numEnc": payload.num_enc,
        "numDma": payload.num_dma,
        "devVer": payload.dev_ver.iter().map(cam_jpeg_dev_ver_json).collect::<Vec<_>>(),
    })
}

fn cam_fd_query_json(payload: &CamFdQueryCap) -> Value {
    json!({
        "deviceIommu": cam_iommu_json(&payload.device_iommu),
        "cdmIommu": cam_iommu_json(&payload.cdm_iommu),
        "hwCaps": {
            "coreVersion": cam_hw_version_json(&payload.hw_caps.core_version),
            "wrapperVersion": cam_hw_version_json(&payload.hw_caps.wrapper_version),
            "rawResultsAvailable": payload.hw_caps.raw_results_available,
            "supportedModes": payload.hw_caps.supported_modes,
        },
    })
}

fn cam_lrme_query_json(payload: &CamLrmeQueryCap) -> Value {
    json!({
        "deviceIommu": cam_iommu_json(&payload.device_iommu),
        "cdmIommu": cam_iommu_json(&payload.cdm_iommu),
        "numDevices": payload.num_devices,
        "devCaps": payload.dev_caps.iter().map(cam_lrme_dev_cap_json).collect::<Vec<_>>(),
    })
}

fn cam_isp_dev_cap_json(value: &CamIspDevCapInfo) -> Value {
    json!({
        "hwType": value.hw_type,
        "hwVersion": cam_hw_version_json(&value.hw_version),
    })
}

fn cam_jpeg_dev_ver_json(value: &CamJpegDevVer) -> Value {
    json!({
        "size": value.size,
        "devType": value.dev_type,
        "hwVersion": cam_hw_version_json(&value.hw_ver),
    })
}

fn cam_lrme_dev_cap_json(value: &CamLrmeDevCap) -> Value {
    json!({
        "clcHwVersion": cam_lrme_hw_version_json(&value.clc_hw_version),
        "busRdHwVersion": cam_lrme_hw_version_json(&value.bus_rd_hw_version),
        "busWrHwVersion": cam_lrme_hw_version_json(&value.bus_wr_hw_version),
        "topHwVersion": cam_lrme_hw_version_json(&value.top_hw_version),
        "topTitanVersion": cam_lrme_hw_version_json(&value.top_titan_version),
    })
}

fn cam_hw_version_json(value: &CamHwVersion) -> Value {
    json!({
        "major": value.major,
        "minor": value.minor,
        "incr": value.incr,
    })
}

fn cam_lrme_hw_version_json(value: &CamLrmeHwVersion) -> Value {
    json!({
        "gen": value.gen,
        "rev": value.rev,
        "step": value.step,
    })
}

fn cam_iommu_json(value: &CamIommuHandle) -> Value {
    json!({
        "nonSecure": value.non_secure,
        "secure": value.secure,
    })
}

fn android_camera_provider_state() -> Value {
    let Some(service_list) = command_stdout("service", &["list"]) else {
        return json!({
            "ok": false,
            "error": "service list command failed",
        });
    };
    let camera_services = service_list
        .lines()
        .filter(|line| line.contains("camera"))
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    json!({
        "ok": true,
        "providerInternal0": camera_services.iter().any(|line| {
            line.contains("android.hardware.camera.provider.ICameraProvider/internal/0")
        }),
        "cameraServices": camera_services,
    })
}

fn extend_json(mut base: Value, extension: Value) -> Value {
    let Some(base_object) = base.as_object_mut() else {
        return extension;
    };
    if let Some(extension_object) = extension.as_object() {
        for (key, value) in extension_object {
            base_object.insert(key.clone(), value.clone());
        }
    }
    base
}

fn errno_json(error: &io::Error) -> Value {
    json!({
        "ok": false,
        "errno": error.raw_os_error(),
        "kind": format!("{:?}", error.kind()),
        "message": error.to_string(),
    })
}

fn command_stdout(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn read_trimmed(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn c_array_string(bytes: &[u8]) -> String {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn current_dir_string() -> String {
    env::current_dir()
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|_| String::from("<unknown>"))
}

fn argv_strings(argv: &[OsString]) -> Vec<String> {
    argv.iter()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect()
}

fn format_u32_hex(value: u32) -> String {
    format!("0x{value:08x}")
}

fn libc_major(dev: u64) -> u64 {
    ((dev >> 8) & 0xfff) | ((dev >> 32) & !0xfff)
}

fn libc_minor(dev: u64) -> u64 {
    (dev & 0xff) | ((dev >> 12) & !0xff)
}

fn unsafe_zeroed<T>() -> T {
    unsafe { std::mem::zeroed() }
}
