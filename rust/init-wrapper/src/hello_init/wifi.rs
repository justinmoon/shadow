use super::*;

pub(super) fn wifi_boot_path_status_json(path: &str) -> String {
    camera_boot_hal_path_status_json(path)
}

pub(super) fn read_trimmed_file(path: &str, max_bytes: usize) -> Option<String> {
    fs::read(path).ok().map(|bytes| {
        String::from_utf8_lossy(&bytes[..bytes.len().min(max_bytes)])
            .trim()
            .to_string()
    })
}

pub(super) fn read_dir_names(path: &str, max_entries: usize) -> Vec<String> {
    let mut names = Vec::new();
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten().take(max_entries) {
            names.push(entry.file_name().to_string_lossy().into_owned());
        }
    }
    names.sort();
    names
}

pub(super) const WIFI_HELPER_PROCESS_NAMES: &[&str] = &[
    "servicemanager",
    "hwservicemanager",
    "vndservicemanager",
    "qseecomd",
    "irsc_util",
    "qrtr-ns",
    "rmt_storage",
    "tftp_server",
    "modem_svc",
    "pd-mapper",
    "pm-service",
    "pm-proxy",
    "cnss-daemon",
    "wpa_supplicant",
];

pub(super) const WIFI_PROFILE_CONTRACT_HELPERS: &[&str] = &[
    "servicemanager",
    "hwservicemanager",
    "vndservicemanager",
    "qrtr-ns",
    "rmt_storage",
    "tftp_server",
    "modem_svc",
    "pd-mapper",
    "pm-service",
    "pm-proxy",
    "cnss-daemon",
];

pub(super) fn json_str_array(values: &[&str]) -> String {
    format!(
        "[{}]",
        values
            .iter()
            .map(|value| json_string(value))
            .collect::<Vec<_>>()
            .join(",")
    )
}

pub(super) fn wifi_helper_logs_json() -> String {
    let entries = WIFI_HELPER_PROCESS_NAMES
        .iter()
        .map(|name| {
            let path = format!("/orange-gpu/wifi-helper-{name}.log");
            format!(
                "{{\"name\":{},\"path\":{},\"excerpt\":{}}}",
                json_string(name),
                json_string(&path),
                json_string(&redact_wifi_sensitive_text(&read_file_excerpt(&path, 8192)))
            )
        })
        .collect::<Vec<_>>()
        .join(",\n    ");
    format!("[\n    {}\n  ]", entries)
}

pub(super) struct WifiHelperProcessSnapshot {
    processes_json: String,
    running_names: Vec<String>,
}

pub(super) fn wifi_helper_process_snapshot() -> WifiHelperProcessSnapshot {
    let mut processes = Vec::new();
    let mut running_names = Vec::new();
    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let pid = entry.file_name().to_string_lossy().into_owned();
            if pid.is_empty() || pid.chars().any(|ch| !ch.is_ascii_digit()) {
                continue;
            }
            let cmdline = read_trimmed_file(&format!("/proc/{pid}/cmdline"), 2048)
                .unwrap_or_default()
                .replace('\0', " ");
            let Some(name) = WIFI_HELPER_PROCESS_NAMES.iter().find(|name| {
                cmdline.split_whitespace().any(|part| {
                    Path::new(part)
                        .file_name()
                        .and_then(|file_name| file_name.to_str())
                        == Some(*name)
                })
            }) else {
                continue;
            };
            if !running_names.iter().any(|running| running == name) {
                running_names.push((*name).to_string());
            }
            let comm = read_trimmed_file(&format!("/proc/{pid}/comm"), 128).unwrap_or_default();
            processes.push(format!(
                "{{\"pid\":{},\"name\":{},\"comm\":{},\"cmdline\":{}}}",
                json_string(&pid),
                json_string(name),
                json_string(&comm),
                json_string(&cmdline)
            ));
        }
    }
    WifiHelperProcessSnapshot {
        processes_json: format!("[{}]", processes.join(",")),
        running_names,
    }
}

pub(super) fn wifi_helper_processes_json() -> String {
    wifi_helper_process_snapshot().processes_json
}

pub(super) fn wifi_helper_profile_is_known(profile: &str) -> bool {
    matches!(
        profile,
        "full"
            | "no-service-managers"
            | "no-pm"
            | "no-modem-svc"
            | "no-rfs-storage"
            | "no-pd-mapper"
            | "no-cnss"
            | "qrtr-only"
            | "qrtr-pd"
            | "qrtr-pd-tftp"
            | "qrtr-pd-rfs"
            | "qrtr-pd-rfs-cnss"
            | "qrtr-pd-rfs-modem"
            | "qrtr-pd-rfs-modem-cnss"
            | "qrtr-pd-rfs-modem-pm"
            | "qrtr-pd-rfs-modem-pm-cnss"
            | "aidl-sm-core"
            | "vnd-sm-core"
            | "vnd-sm-core-binder-node"
            | "all-sm-core"
            | "none"
    )
}

pub(super) fn wifi_helper_profile_expected_helpers(profile: &str) -> Vec<&'static str> {
    WIFI_PROFILE_CONTRACT_HELPERS
        .iter()
        .copied()
        .filter(|name| wifi_helper_profile_allows(profile, name))
        .collect()
}

pub(super) fn wifi_helper_contract_missing(
    expected: &[&str],
    snapshot: &WifiHelperProcessSnapshot,
) -> Vec<String> {
    expected
        .iter()
        .filter(|name| {
            !snapshot
                .running_names
                .iter()
                .any(|running_name| running_name == **name)
        })
        .map(|name| (*name).to_string())
        .collect()
}

pub(super) fn wifi_helper_contract_unexpected(
    profile: &str,
    snapshot: &WifiHelperProcessSnapshot,
) -> Vec<String> {
    WIFI_PROFILE_CONTRACT_HELPERS
        .iter()
        .filter(|name| {
            !wifi_helper_profile_allows(profile, name)
                && snapshot
                    .running_names
                    .iter()
                    .any(|running_name| running_name == **name)
        })
        .map(|name| (*name).to_string())
        .collect()
}

pub(super) fn wifi_helper_contract_ok(profile: &str, snapshot: &WifiHelperProcessSnapshot) -> bool {
    let expected = wifi_helper_profile_expected_helpers(profile);
    wifi_helper_profile_is_known(profile)
        && wifi_helper_contract_missing(&expected, snapshot).is_empty()
        && wifi_helper_contract_unexpected(profile, snapshot).is_empty()
}

pub(super) fn wifi_helper_contract_json(
    profile: &str,
    snapshot: &WifiHelperProcessSnapshot,
) -> String {
    let expected = wifi_helper_profile_expected_helpers(profile);
    let missing = wifi_helper_contract_missing(&expected, snapshot);
    let unexpected = wifi_helper_contract_unexpected(profile, snapshot);
    format!(
        concat!(
            "{{\"profile\":{},\"knownProfile\":{},\"expected\":{},",
            "\"running\":{},\"missing\":{},\"unexpectedRunning\":{},\"requiredOk\":{}}}"
        ),
        json_string(profile),
        bool_word(wifi_helper_profile_is_known(profile)),
        json_str_array(&expected),
        json_string_array(&snapshot.running_names),
        json_string_array(&missing),
        json_string_array(&unexpected),
        bool_word(
            wifi_helper_profile_is_known(profile) && missing.is_empty() && unexpected.is_empty()
        )
    )
}

pub(super) fn wifi_module_details_json() -> String {
    let fields = [
        ("/sys/module/wlan/initstate", "initstate"),
        ("/sys/module/wlan/refcnt", "refcnt"),
        ("/sys/module/wlan/taint", "taint"),
        ("/sys/module/wlan/parameters/fwpath", "fwpath"),
        ("/sys/module/wlan/parameters/con_mode", "conMode"),
        ("/sys/module/wlan/uevent", "uevent"),
    ];
    let entries = fields
        .iter()
        .map(|(path, key)| {
            format!(
                "{}:{}",
                json_string(key),
                json_optional_string(read_trimmed_file(path, 2048))
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    format!("{{{entries}}}")
}

pub(super) fn wifi_kernel_log_excerpt() -> String {
    let toybox = Path::new("/system/bin/toybox");
    if !toybox.is_file() {
        return "<unavailable missing /system/bin/toybox>\n".to_string();
    }
    match Command::new(toybox).arg("dmesg").output() {
        Ok(output) => {
            let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
            if text.len() > 131072 {
                text = text[text.len() - 131072..].to_string();
                text.insert_str(0, "<truncated>\n");
            }
            if !text.ends_with('\n') {
                text.push('\n');
            }
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                text.push_str(&format!(
                    "<dmesg-exit status={} stderr={}>\n",
                    output.status, stderr
                ));
            }
            text
        }
        Err(error) => format!(
            "<unavailable errno={:?} error={}>\n",
            error.raw_os_error(),
            error
        ),
    }
}

pub(super) fn wifi_interface_json(iface: &str) -> String {
    let root = format!("/sys/class/net/{iface}");
    let present = Path::new(&root).exists();
    let device_link = fs::read_link(format!("{root}/device"))
        .map(|path| path.display().to_string())
        .unwrap_or_default();
    format!(
        concat!(
            "{{\"name\":{},\"present\":{},\"operstate\":{},\"address\":{},",
            "\"ifindex\":{},\"type\":{},\"uevent\":{},\"deviceLink\":{}}}"
        ),
        json_string(iface),
        bool_word(present),
        json_optional_string(read_trimmed_file(&format!("{root}/operstate"), 128)),
        json_optional_string(
            read_trimmed_file(&format!("{root}/address"), 128).map(|address| {
                if address.is_empty() {
                    address
                } else {
                    "<redacted>".to_string()
                }
            })
        ),
        json_optional_string(read_trimmed_file(&format!("{root}/ifindex"), 64)),
        json_optional_string(read_trimmed_file(&format!("{root}/type"), 64)),
        json_optional_string(
            read_trimmed_file(&format!("{root}/uevent"), 1024)
                .map(|text| redact_wifi_sensitive_text(&text))
        ),
        json_string(&device_link)
    )
}

pub(super) fn wifi_interface_is_admin_up(iface: &str) -> bool {
    read_trimmed_file(&format!("/sys/class/net/{iface}/flags"), 64)
        .and_then(|flags| {
            let value = flags
                .strip_prefix("0x")
                .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                .or_else(|| flags.parse::<u32>().ok())?;
            Some((value & 0x1) != 0)
        })
        .unwrap_or(false)
}

pub(super) fn wifi_command_text(bytes: &[u8], max_bytes: usize) -> String {
    let mut text = String::from_utf8_lossy(&bytes[..bytes.len().min(max_bytes)]).into_owned();
    if bytes.len() > max_bytes {
        text.push_str("\n<truncated>");
    }
    redact_wifi_sensitive_text(&text)
}

pub(super) fn redact_wifi_sensitive_text(text: &str) -> String {
    let mut lines = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim_start();
        let mut redacted_line = redact_wpa_network_command_line(line, trimmed);
        for key in [
            "address=",
            "bssid=",
            "ssid=",
            "psk=",
            "password=",
            "passphrase=",
            "uuid=",
            "p2p_device_address=",
            "ip_address=",
        ] {
            if redacted_line.is_some() {
                break;
            }
            if let Some(value) = trimmed.strip_prefix(key) {
                if !value.is_empty() {
                    let indent_len = line.len() - trimmed.len();
                    redacted_line = Some(format!("{}{}<redacted>", &line[..indent_len], key));
                    break;
                }
            }
        }
        let line = redacted_line
            .unwrap_or_else(|| redact_mac_like_tokens(&redact_inline_wifi_sensitive_tokens(line)));
        lines.push(line);
    }
    let mut output = lines.join("\n");
    if text.ends_with('\n') {
        output.push('\n');
    }
    output
}

pub(super) fn redact_wpa_network_command_line(line: &str, trimmed: &str) -> Option<String> {
    let mut parts = trimmed.split_whitespace();
    if parts.next()? != "SET_NETWORK" {
        return None;
    }
    let network_id = parts.next()?;
    let field = parts.next()?;
    if !matches!(field, "ssid" | "psk" | "password" | "passphrase") {
        return None;
    }
    let indent_len = line.len() - trimmed.len();
    Some(format!(
        "{}SET_NETWORK {} {} <redacted>",
        &line[..indent_len],
        network_id,
        field
    ))
}

pub(super) fn redact_inline_wifi_sensitive_tokens(line: &str) -> String {
    let mut output = line.to_string();
    for marker in ["ssid:", "SSID:"] {
        let mut cursor = 0_usize;
        while cursor < output.len() {
            let Some(relative_start) = output[cursor..].find(marker) else {
                break;
            };
            let start = cursor + relative_start;
            let value_start = start + marker.len();
            let rest = &output[value_start..];
            let value_len = [
                " bssid",
                " BSSID",
                " rssi",
                " RSSI",
                " channel",
                " country_code",
            ]
            .iter()
            .filter_map(|terminator| rest.find(terminator))
            .min()
            .unwrap_or(rest.len());
            output.replace_range(value_start..value_start + value_len, "<redacted>");
            cursor = value_start + "<redacted>".len();
        }
    }
    output
}

pub(super) fn redact_mac_like_tokens(text: &str) -> String {
    let mut output = String::new();
    let bytes = text.as_bytes();
    let mut index = 0_usize;
    while index < bytes.len() {
        if index + 17 <= bytes.len() && looks_like_mac(&bytes[index..index + 17]) {
            output.push_str("<redacted-mac>");
            index += 17;
        } else {
            output.push(bytes[index] as char);
            index += 1;
        }
    }
    output
}

pub(super) fn looks_like_mac(bytes: &[u8]) -> bool {
    if bytes.len() != 17 {
        return false;
    }
    for (index, byte) in bytes.iter().enumerate() {
        if index % 3 == 2 {
            if *byte != b':' {
                return false;
            }
        } else if !byte.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

pub(super) fn wifi_interface_activation_probe_json(
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> String {
    let before = wifi_interface_json("wlan0");
    let before_flags = read_trimmed_file("/sys/class/net/wlan0/flags", 64);
    let before_admin_up = wifi_interface_is_admin_up("wlan0");
    let toybox = Path::new("/system/bin/toybox");
    if !Path::new("/sys/class/net/wlan0").exists() {
        return format!(
            "{{\"attempted\":false,\"reason\":\"missing-wlan0\",\"before\":{},\"beforeFlags\":{},\"beforeAdminUp\":{}}}",
            before,
            json_optional_string(before_flags),
            bool_word(before_admin_up)
        );
    }
    if !toybox.is_file() {
        return format!(
            "{{\"attempted\":false,\"reason\":\"missing-toybox\",\"before\":{},\"beforeFlags\":{},\"beforeAdminUp\":{}}}",
            before,
            json_optional_string(before_flags),
            bool_word(before_admin_up)
        );
    }

    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-ifconfig-up-start",
    );
    let output = Command::new(toybox)
        .args(["ifconfig", "wlan0", "up"])
        .output();
    thread::sleep(Duration::from_millis(300));
    let after = wifi_interface_json("wlan0");
    let after_flags = read_trimmed_file("/sys/class/net/wlan0/flags", 64);
    let after_admin_up = wifi_interface_is_admin_up("wlan0");
    let ifconfig_after = Command::new(toybox)
        .args(["ifconfig", "wlan0"])
        .output()
        .ok();
    let ifconfig_after_text = ifconfig_after
        .as_ref()
        .map(|output| wifi_command_text(&output.stdout, 4096))
        .unwrap_or_default();

    match output {
        Ok(output) => {
            let exit_code = output
                .status
                .code()
                .map(|code| code.to_string())
                .unwrap_or_else(|| "null".to_string());
            let success = output.status.success() && after_admin_up;
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                if success {
                    "wifi-ifconfig-up-ok"
                } else {
                    "wifi-ifconfig-up-failed"
                },
            );
            format!(
                concat!(
                    "{{\"attempted\":true,\"command\":\"/system/bin/toybox ifconfig wlan0 up\",",
                    "\"exitCode\":{},\"success\":{},\"stdout\":{},\"stderr\":{},",
                    "\"before\":{},\"beforeFlags\":{},\"beforeAdminUp\":{},",
                    "\"after\":{},\"afterFlags\":{},\"afterAdminUp\":{},\"ifconfigAfter\":{}}}"
                ),
                exit_code,
                bool_word(success),
                json_string(&wifi_command_text(&output.stdout, 4096)),
                json_string(&wifi_command_text(&output.stderr, 4096)),
                before,
                json_optional_string(before_flags),
                bool_word(before_admin_up),
                after,
                json_optional_string(after_flags),
                bool_word(after_admin_up),
                json_string(&ifconfig_after_text)
            )
        }
        Err(error) => {
            write_payload_probe_stage(
                probe_stage_path,
                probe_stage_prefix,
                "wifi-ifconfig-up-spawn-failed",
            );
            format!(
                concat!(
                    "{{\"attempted\":true,\"command\":\"/system/bin/toybox ifconfig wlan0 up\",",
                    "\"exitCode\":null,\"success\":false,\"spawnError\":{},",
                    "\"before\":{},\"beforeFlags\":{},\"beforeAdminUp\":{},",
                    "\"after\":{},\"afterFlags\":{},\"afterAdminUp\":{},\"ifconfigAfter\":{}}}"
                ),
                json_string(&error.to_string()),
                before,
                json_optional_string(before_flags),
                bool_word(before_admin_up),
                after,
                json_optional_string(after_flags),
                bool_word(after_admin_up),
                json_string(&ifconfig_after_text)
            )
        }
    }
}

pub(super) fn ensure_sunfish_wpa_supplicant_config() -> io::Result<()> {
    prepare_sunfish_wifi_android_runtime_dirs();
    let config_path = Path::new("/data/vendor/wifi/wpa/wpa_supplicant.conf");
    if !config_path.is_file() {
        fs::write(
            config_path,
            concat!(
                "update_config=1\n",
                "eapol_version=1\n",
                "ap_scan=1\n",
                "fast_reauth=1\n",
                "pmf=1\n",
                "p2p_add_cli_chan=1\n",
                "oce=1\n",
                "sae_pwe=2\n"
            ),
        )?;
    }
    fs::set_permissions(config_path, fs::Permissions::from_mode(0o660))?;
    let c_config_path = CString::new(config_path.as_os_str().as_bytes())?;
    let _ = unsafe { libc::chown(c_config_path.as_ptr(), 1010, 1010) };
    Ok(())
}

pub(super) fn wpa_ctrl_response_text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes)
        .trim_end_matches('\0')
        .trim()
        .to_string()
}

pub(super) struct WpaCtrlCommandResult {
    command_label: String,
    ok: bool,
    response: String,
    error: String,
}

pub(super) struct WifiCredentials {
    ssid: Vec<u8>,
    psk_config_value: String,
    psk_kind: &'static str,
}

pub(super) struct WifiCredentialLoad {
    attempted: bool,
    path_configured: bool,
    read_ok: bool,
    remove_ok: bool,
    error: String,
    credentials: Option<WifiCredentials>,
}

pub(super) struct WifiAssociationRun {
    json: String,
    completed: bool,
    network_id: Option<u32>,
}

pub(super) struct WifiRuntimeNetwork {
    child: Child,
    socket_path: PathBuf,
    busybox_path: PathBuf,
    network_id: u32,
}

pub(super) struct WifiRuntimeNetworkStart {
    pub(super) json: String,
    pub(super) completed: bool,
    pub(super) network: Option<WifiRuntimeNetwork>,
}

pub(super) struct WifiRuntimeClockSet {
    json: String,
    ready: bool,
}

pub(super) struct WifiChildLiveness {
    json: String,
    alive: bool,
}

pub(super) struct TcpConnectProbe {
    json: String,
    connected: bool,
}

pub(super) fn wpa_ctrl_command_label(command: &str) -> String {
    let redacted = redact_wifi_sensitive_text(command.trim());
    if redacted.is_empty() {
        return "<empty>".to_string();
    }
    if redacted.chars().count() <= 160 {
        return redacted;
    }
    let mut truncated = redacted.chars().take(160).collect::<String>();
    truncated.push_str("<truncated>");
    truncated
}

pub(super) fn wpa_ctrl_client_suffix(command_label: &str) -> String {
    let suffix = command_label
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .take(48)
        .collect::<String>()
        .to_ascii_lowercase();
    if suffix.is_empty() {
        "cmd".to_string()
    } else {
        suffix
    }
}

pub(super) fn wpa_ctrl_command_ok(command: &str, response: &str) -> bool {
    let command_word = command.split_whitespace().next().unwrap_or_default();
    match command_word {
        "PING" => response == "PONG",
        "SCAN" => response == "OK",
        "STATUS" => !response.is_empty(),
        "ADD_NETWORK" => response.parse::<u32>().is_ok(),
        _ => !response.starts_with("FAIL") && !response.is_empty(),
    }
}

pub(super) fn wpa_ctrl_command(
    socket_path: &Path,
    command: &str,
    timeout: Duration,
) -> WpaCtrlCommandResult {
    let command_label = wpa_ctrl_command_label(command);
    let client_path = PathBuf::from(format!(
        "/data/vendor/wifi/wpa/sockets/shadow-wpa-{}-{}",
        process::id(),
        wpa_ctrl_client_suffix(&command_label)
    ));
    let _ = fs::remove_file(&client_path);
    let socket = match UnixDatagram::bind(&client_path) {
        Ok(socket) => socket,
        Err(error) => {
            return WpaCtrlCommandResult {
                command_label,
                ok: false,
                response: String::new(),
                error: format!("bind {client_path:?}: {error}"),
            }
        }
    };
    let _ = fs::set_permissions(&client_path, fs::Permissions::from_mode(0o770));
    if let Ok(c_client_path) = CString::new(client_path.as_os_str().as_bytes()) {
        let _ = unsafe { libc::chown(c_client_path.as_ptr(), 1010, 1010) };
    }
    let _ = socket.set_read_timeout(Some(timeout));
    let result = if let Err(error) = socket.connect(socket_path) {
        WpaCtrlCommandResult {
            command_label,
            ok: false,
            response: String::new(),
            error: format!("connect {socket_path:?}: {error}"),
        }
    } else if let Err(error) = socket.send(command.as_bytes()) {
        WpaCtrlCommandResult {
            command_label,
            ok: false,
            response: String::new(),
            error: format!("send: {error}"),
        }
    } else {
        let mut buf = vec![0_u8; 65536];
        match socket.recv(&mut buf) {
            Ok(size) => {
                let response = wpa_ctrl_response_text(&buf[..size]);
                WpaCtrlCommandResult {
                    command_label,
                    ok: wpa_ctrl_command_ok(command, &response),
                    response,
                    error: String::new(),
                }
            }
            Err(error) => WpaCtrlCommandResult {
                command_label,
                ok: false,
                response: String::new(),
                error: format!("recv: {error}"),
            },
        }
    };
    let _ = fs::remove_file(&client_path);
    result
}

pub(super) fn wpa_ctrl_result_json(result: &WpaCtrlCommandResult) -> String {
    let command_label = redact_wifi_sensitive_text(&result.command_label);
    if result.error.is_empty() {
        format!(
            "{{\"command\":{},\"ok\":{},\"response\":{}}}",
            json_string(&command_label),
            bool_word(result.ok),
            json_string(&wifi_command_text(result.response.as_bytes(), 8192))
        )
    } else {
        format!(
            "{{\"command\":{},\"ok\":false,\"error\":{}}}",
            json_string(&command_label),
            json_string(&result.error)
        )
    }
}

pub(super) fn wpa_ctrl_command_result_json(
    socket_path: &Path,
    command: &str,
    timeout: Duration,
) -> String {
    wpa_ctrl_result_json(&wpa_ctrl_command(socket_path, command, timeout))
}

pub(super) fn hex_encode(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(&mut output, "{byte:02x}");
    }
    output
}

pub(super) fn sha256_hex_digest(bytes: &[u8]) -> String {
    hex_encode(&sha256_bytes(bytes))
}

pub(super) fn parse_hex_bytes(value: &str) -> Option<Vec<u8>> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.len() % 2 != 0 {
        return None;
    }
    let mut output = Vec::with_capacity(trimmed.len() / 2);
    let bytes = trimmed.as_bytes();
    let mut index = 0_usize;
    while index < bytes.len() {
        let pair = std::str::from_utf8(&bytes[index..index + 2]).ok()?;
        output.push(u8::from_str_radix(pair, 16).ok()?);
        index += 2;
    }
    Some(output)
}

pub(super) fn is_hex_psk(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

pub(super) fn wpa_config_quote(value: &str) -> String {
    let mut output = String::with_capacity(value.len() + 2);
    output.push('"');
    for ch in value.chars() {
        if ch == '"' || ch == '\\' {
            output.push('\\');
        }
        output.push(ch);
    }
    output.push('"');
    output
}

pub(super) fn parse_wifi_credentials_text(text: &str) -> Result<WifiCredentials, String> {
    let mut ssid_text = None;
    let mut ssid_hex = None;
    let mut psk_text = None;

    for raw_line in text.lines() {
        let line = raw_line.trim_start();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim_end_matches('\r').to_string();
        match key.trim().to_ascii_lowercase().as_str() {
            "ssid" => ssid_text = Some(value),
            "ssid_hex" => ssid_hex = Some(value),
            "psk" | "password" | "passphrase" => psk_text = Some(value),
            _ => {}
        }
    }

    let ssid = if let Some(value) = ssid_hex {
        parse_hex_bytes(&value).ok_or_else(|| "invalid-ssid-hex".to_string())?
    } else {
        ssid_text
            .ok_or_else(|| "missing-ssid".to_string())?
            .into_bytes()
    };
    if ssid.is_empty() || ssid.len() > 32 {
        return Err("invalid-ssid-length".to_string());
    }

    let psk = psk_text.ok_or_else(|| "missing-psk".to_string())?;
    let (psk_config_value, psk_kind) = if is_hex_psk(&psk) {
        (psk, "raw-psk")
    } else {
        let psk_len = psk.as_bytes().len();
        if !(8..=63).contains(&psk_len) {
            return Err("invalid-passphrase-length".to_string());
        }
        (wpa_config_quote(&psk), "passphrase")
    };

    Ok(WifiCredentials {
        ssid,
        psk_config_value,
        psk_kind,
    })
}

pub(super) fn read_wifi_credentials_once(path: &str) -> WifiCredentialLoad {
    let path = path.trim();
    if path.is_empty() {
        return WifiCredentialLoad {
            attempted: true,
            path_configured: false,
            read_ok: false,
            remove_ok: false,
            error: "missing-credentials-path".to_string(),
            credentials: None,
        };
    }

    let read_result = fs::read_to_string(path);
    let remove_ok = fs::remove_file(path).is_ok();
    match read_result {
        Ok(text) => match parse_wifi_credentials_text(&text) {
            Ok(credentials) => WifiCredentialLoad {
                attempted: true,
                path_configured: true,
                read_ok: true,
                remove_ok,
                error: String::new(),
                credentials: Some(credentials),
            },
            Err(error) => WifiCredentialLoad {
                attempted: true,
                path_configured: true,
                read_ok: true,
                remove_ok,
                error,
                credentials: None,
            },
        },
        Err(error) => WifiCredentialLoad {
            attempted: true,
            path_configured: true,
            read_ok: false,
            remove_ok,
            error: format!("read-failed:{error}"),
            credentials: None,
        },
    }
}

pub(super) fn wifi_credential_load_json(load: &WifiCredentialLoad) -> String {
    let (ssid_len, ssid_sha256, psk_kind) = match &load.credentials {
        Some(credentials) => (
            credentials.ssid.len().to_string(),
            format!("sha256:{}", sha256_hex_digest(&credentials.ssid)),
            credentials.psk_kind.to_string(),
        ),
        None => ("null".to_string(), String::new(), String::new()),
    };
    format!(
        concat!(
            "{{\"attempted\":{},\"pathConfigured\":{},\"readOk\":{},",
            "\"removeOk\":{},\"error\":{},\"ssidLen\":{},",
            "\"ssidSha256\":{},\"pskKind\":{}}}"
        ),
        bool_word(load.attempted),
        bool_word(load.path_configured),
        bool_word(load.read_ok),
        bool_word(load.remove_ok),
        json_string(&load.error),
        ssid_len,
        json_string(&ssid_sha256),
        json_string(&psk_kind)
    )
}

pub(super) fn wpa_status_value(status: &str, key: &str) -> Option<String> {
    let prefix = format!("{key}=");
    status
        .lines()
        .find_map(|line| line.strip_prefix(&prefix).map(|value| value.to_string()))
}

pub(super) fn wifi_association_status_poll_json(
    attempt: u32,
    result: &WpaCtrlCommandResult,
) -> String {
    let state = wpa_status_value(&result.response, "wpa_state").unwrap_or_default();
    format!(
        "{{\"attempt\":{},\"state\":{},\"result\":{}}}",
        attempt,
        json_string(&state),
        wpa_ctrl_result_json(result)
    )
}

pub(super) fn wifi_association_cleanup_json(socket_path: &Path, network_id: u32) -> String {
    let mut cleanup = Vec::new();
    let cleanup_disconnect = wpa_ctrl_command(socket_path, "DISCONNECT", Duration::from_secs(2));
    cleanup.push(format!(
        "{{\"step\":\"disconnect\",\"result\":{}}}",
        wpa_ctrl_result_json(&cleanup_disconnect)
    ));
    let cleanup_remove = wpa_ctrl_command(
        socket_path,
        &format!("REMOVE_NETWORK {network_id}"),
        Duration::from_secs(2),
    );
    cleanup.push(format!(
        "{{\"step\":\"remove-network\",\"result\":{}}}",
        wpa_ctrl_result_json(&cleanup_remove)
    ));
    let cleanup_status = wpa_ctrl_command(socket_path, "STATUS", Duration::from_secs(2));
    cleanup.push(format!(
        "{{\"step\":\"status\",\"result\":{}}}",
        wpa_ctrl_result_json(&cleanup_status)
    ));
    format!("[{}]", cleanup.join(","))
}

pub(super) fn run_wifi_association(
    socket_path: &Path,
    credential_load: &WifiCredentialLoad,
    cleanup_after: bool,
) -> WifiAssociationRun {
    let credentials_json = wifi_credential_load_json(credential_load);
    let Some(credentials) = credential_load.credentials.as_ref() else {
        return WifiAssociationRun {
            json: format!(
                "{{\"attempted\":false,\"reason\":\"credentials-unavailable\",\"credentials\":{credentials_json}}}"
            ),
            completed: false,
            network_id: None,
        };
    };
    if !credential_load.remove_ok {
        return WifiAssociationRun {
            json: format!(
                "{{\"attempted\":false,\"reason\":\"credentials-not-removed\",\"credentials\":{credentials_json}}}"
            ),
            completed: false,
            network_id: None,
        };
    }

    let mut steps = Vec::new();
    let disconnect = wpa_ctrl_command(socket_path, "DISCONNECT", Duration::from_secs(2));
    steps.push(format!(
        "{{\"step\":\"disconnect\",\"result\":{}}}",
        wpa_ctrl_result_json(&disconnect)
    ));
    let remove_all = wpa_ctrl_command(socket_path, "REMOVE_NETWORK all", Duration::from_secs(2));
    steps.push(format!(
        "{{\"step\":\"remove-all\",\"result\":{}}}",
        wpa_ctrl_result_json(&remove_all)
    ));
    let add_network = wpa_ctrl_command(socket_path, "ADD_NETWORK", Duration::from_secs(2));
    steps.push(format!(
        "{{\"step\":\"add-network\",\"result\":{}}}",
        wpa_ctrl_result_json(&add_network)
    ));
    let network_id = add_network.response.trim().parse::<u32>().ok();
    let Some(network_id) = network_id else {
        return WifiAssociationRun {
            json: format!(
                concat!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"add-network-failed\",",
                    "\"credentials\":{},\"steps\":[{}],\"polls\":[],\"cleanup\":[]}}"
                ),
                credentials_json,
                steps.join(",")
            ),
            completed: false,
            network_id: None,
        };
    };

    let set_commands = [
        (
            "set-ssid",
            format!(
                "SET_NETWORK {network_id} ssid {}",
                hex_encode(&credentials.ssid)
            ),
        ),
        (
            "set-key-mgmt",
            format!("SET_NETWORK {network_id} key_mgmt WPA-PSK"),
        ),
        (
            "set-mem-only-psk",
            format!("SET_NETWORK {network_id} mem_only_psk 1"),
        ),
        (
            "set-psk",
            format!(
                "SET_NETWORK {network_id} psk {}",
                credentials.psk_config_value
            ),
        ),
        ("select-network", format!("SELECT_NETWORK {network_id}")),
    ];
    let mut setup_ok = true;
    for (step, command) in set_commands {
        let result = wpa_ctrl_command(socket_path, &command, Duration::from_secs(2));
        setup_ok = setup_ok && result.ok;
        steps.push(format!(
            "{{\"step\":{},\"result\":{}}}",
            json_string(step),
            wpa_ctrl_result_json(&result)
        ));
        if !setup_ok {
            break;
        }
    }

    let mut polls = Vec::new();
    let mut completed = false;
    let mut final_state = String::new();
    if setup_ok {
        for attempt in 0..60_u32 {
            if attempt > 0 {
                thread::sleep(Duration::from_millis(500));
            }
            let status = wpa_ctrl_command(socket_path, "STATUS", Duration::from_secs(2));
            final_state = wpa_status_value(&status.response, "wpa_state").unwrap_or_default();
            completed = status.ok && final_state == "COMPLETED";
            polls.push(wifi_association_status_poll_json(attempt, &status));
            if completed {
                break;
            }
        }
    }

    let cleanup = if cleanup_after {
        wifi_association_cleanup_json(socket_path, network_id)
    } else {
        "[]".to_string()
    };

    WifiAssociationRun {
        json: format!(
            concat!(
                "{{\"attempted\":true,\"completed\":{},\"reason\":{},",
                "\"networkId\":{},\"finalState\":{},\"credentials\":{},",
                "\"steps\":[{}],\"polls\":[{}],\"cleanup\":{}}}"
            ),
            bool_word(completed),
            json_string(if completed {
                ""
            } else if setup_ok {
                "association-timeout"
            } else {
                "network-setup-failed"
            }),
            network_id,
            json_string(&final_state),
            credentials_json,
            steps.join(","),
            polls.join(","),
            cleanup
        ),
        completed,
        network_id: Some(network_id),
    }
}

pub(super) fn wifi_association_probe_json(
    socket_path: &Path,
    credential_load: &WifiCredentialLoad,
) -> String {
    run_wifi_association(socket_path, credential_load, true).json
}

pub(super) fn write_udhcpc_script(script_path: &Path, busybox_path: &str) -> io::Result<()> {
    let script = format!(
        concat!(
            "#!{} sh\n",
            "set -eu\n",
            "bb={}\n",
            "case \"${{1:-}}\" in\n",
            "  deconfig)\n",
            "    \"$bb\" ifconfig \"${{interface:-wlan0}}\" 0.0.0.0 || true\n",
            "    ;;\n",
            "  bound|renew)\n",
            "    \"$bb\" ifconfig \"$interface\" \"$ip\" netmask \"$subnet\"\n",
            "    \"$bb\" route del default dev \"$interface\" 2>/dev/null || true\n",
            "    for r in ${{router:-}}; do \"$bb\" route add default gw \"$r\" dev \"$interface\"; break; done\n",
            "    \"$bb\" mkdir -p /etc\n",
            "    : > /etc/resolv.conf\n",
            "    for d in ${{dns:-}}; do echo \"nameserver $d\" >> /etc/resolv.conf; done\n",
            "    ;;\n",
            "esac\n"
        ),
        busybox_path, busybox_path
    );
    fs::write(script_path, script)?;
    fs::set_permissions(script_path, fs::Permissions::from_mode(0o755))
}

pub(super) fn command_output_json(
    command: &str,
    output: io::Result<std::process::Output>,
) -> String {
    match output {
        Ok(output) => format!(
            "{{\"command\":{},\"exitCode\":{},\"success\":{},\"stdout\":{},\"stderr\":{}}}",
            json_string(command),
            output
                .status
                .code()
                .map(|code| code.to_string())
                .unwrap_or_else(|| "null".to_string()),
            bool_word(output.status.success()),
            json_string(&wifi_command_text(&output.stdout, 8192)),
            json_string(&wifi_command_text(&output.stderr, 8192))
        ),
        Err(error) => format!(
            "{{\"command\":{},\"exitCode\":null,\"success\":false,\"spawnError\":{}}}",
            json_string(command),
            json_string(&error.to_string())
        ),
    }
}

pub(super) fn command_success(output: &io::Result<std::process::Output>) -> bool {
    output
        .as_ref()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

pub(super) fn wifi_ip_state_cleanup_json(busybox_path: &Path) -> String {
    let busybox_label = busybox_path.display().to_string();
    let route_del = Command::new(busybox_path)
        .args(["route", "del", "default", "dev", "wlan0"])
        .output();
    let ifconfig_clear = Command::new(busybox_path)
        .args(["ifconfig", "wlan0", "0.0.0.0"])
        .output();
    let resolv_remove = Command::new(busybox_path)
        .args(["rm", "-f", "/etc/resolv.conf"])
        .output();
    format!(
        concat!(
            "[{{\"step\":\"route-del-default\",\"result\":{}}},",
            "{{\"step\":\"ifconfig-clear\",\"result\":{}}},",
            "{{\"step\":\"resolv-conf-remove\",\"result\":{}}}]"
        ),
        command_output_json(
            &format!("{busybox_label} route del default dev wlan0"),
            route_del
        ),
        command_output_json(
            &format!("{busybox_label} ifconfig wlan0 0.0.0.0"),
            ifconfig_clear
        ),
        command_output_json(
            &format!("{busybox_label} rm -f /etc/resolv.conf"),
            resolv_remove
        )
    )
}

pub(super) fn proc_net_route_has_default_wlan0(text: &str) -> bool {
    text.lines().skip(1).any(|line| {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        fields.len() > 2 && fields[0] == "wlan0" && fields[1] == "00000000"
    })
}

pub(super) fn resolv_conf_has_nameserver(text: &str) -> bool {
    text.lines().any(|line| {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            return false;
        }
        let fields = trimmed.split_whitespace().collect::<Vec<_>>();
        fields.len() >= 2 && fields[0] == "nameserver" && !fields[1].is_empty()
    })
}

pub(super) fn wlan0_has_ipv4_address(ifconfig_text: &str) -> bool {
    ifconfig_text.contains("inet addr:") || ifconfig_text.contains("inet ")
}

pub(super) fn tcp_connect_probe(host: &str, port: u16) -> TcpConnectProbe {
    let target = format!("{host}:{port}");
    let mut resolved = Vec::new();
    let mut connected = false;
    let mut error = String::new();
    match target.to_socket_addrs() {
        Ok(addrs) => {
            for addr in addrs.take(8) {
                resolved.push(addr.to_string());
                match TcpStream::connect_timeout(&addr, Duration::from_secs(4)) {
                    Ok(_) => {
                        connected = true;
                        break;
                    }
                    Err(connect_error) => {
                        if error.is_empty() {
                            error = connect_error.to_string();
                        }
                    }
                }
            }
        }
        Err(resolve_error) => error = resolve_error.to_string(),
    }
    TcpConnectProbe {
        json: format!(
            "{{\"target\":{},\"resolved\":{},\"connected\":{},\"error\":{}}}",
            json_string(&target),
            json_string_array(&resolved),
            bool_word(connected),
            json_string(&error)
        ),
        connected,
    }
}

pub(super) fn wifi_ip_probe_json(
    config: &Config,
    socket_path: &Path,
    credential_load: &WifiCredentialLoad,
) -> String {
    let association = run_wifi_association(socket_path, credential_load, false);
    let Some(network_id) = association.network_id else {
        return format!(
            "{{\"attempted\":true,\"completed\":false,\"reason\":\"association-setup-failed\",\"association\":{},\"dhcp\":null,\"cleanup\":[]}}",
            association.json
        );
    };
    if !association.completed {
        let cleanup = wifi_association_cleanup_json(socket_path, network_id);
        return format!(
            "{{\"attempted\":true,\"completed\":false,\"reason\":\"association-failed\",\"association\":{},\"dhcp\":null,\"cleanup\":{}}}",
            association.json, cleanup
        );
    }

    let busybox_path = Path::new(&config.wifi_dhcp_client_path);
    if !busybox_path.is_file() {
        let cleanup = wifi_association_cleanup_json(socket_path, network_id);
        return format!(
            "{{\"attempted\":true,\"completed\":false,\"reason\":\"missing-dhcp-client\",\"association\":{},\"dhcp\":null,\"cleanup\":{}}}",
            association.json, cleanup
        );
    }

    let script_path = Path::new("/orange-gpu/udhcpc-script");
    let script_result = write_udhcpc_script(script_path, &config.wifi_dhcp_client_path);
    if let Err(error) = script_result {
        let cleanup = wifi_association_cleanup_json(socket_path, network_id);
        return format!(
            "{{\"attempted\":true,\"completed\":false,\"reason\":\"dhcp-script-failed\",\"association\":{},\"dhcpScriptError\":{},\"dhcp\":null,\"cleanup\":{}}}",
            association.json,
            json_string(&error.to_string()),
            cleanup
        );
    }

    let pre_dhcp_cleanup = wifi_ip_state_cleanup_json(busybox_path);
    let dhcp_output = Command::new(busybox_path)
        .args([
            "udhcpc",
            "-i",
            "wlan0",
            "-n",
            "-q",
            "-t",
            "5",
            "-T",
            "3",
            "-s",
            "/orange-gpu/udhcpc-script",
        ])
        .output();
    let dhcp_success = command_success(&dhcp_output);
    let busybox_label = busybox_path.display().to_string();
    let dhcp_json = command_output_json(
        &format!("{busybox_label} udhcpc -i wlan0 -n -q -t 5 -T 3 -s /orange-gpu/udhcpc-script"),
        dhcp_output,
    );
    let ifconfig_output = Command::new(busybox_path)
        .args(["ifconfig", "wlan0"])
        .output();
    let ifconfig_text = ifconfig_output
        .as_ref()
        .ok()
        .map(|output| wifi_command_text(&output.stdout, 8192))
        .unwrap_or_default();
    let ifconfig_json =
        command_output_json(&format!("{busybox_label} ifconfig wlan0"), ifconfig_output);
    let route_text = read_file_excerpt("/proc/net/route", 8192);
    let resolv_conf = read_file_excerpt("/etc/resolv.conf", 4096);
    let default_route = proc_net_route_has_default_wlan0(&route_text);
    let ipv4_address = wlan0_has_ipv4_address(&ifconfig_text);
    let relay_connect = tcp_connect_probe("relay.damus.io", 443);
    let primal_connect = tcp_connect_probe("relay.primal.net", 443);
    let fallback_connect = tcp_connect_probe("1.1.1.1", 53);
    let dns_ready = resolv_conf_has_nameserver(&resolv_conf);
    let hostname_tcp_ready = relay_connect.connected || primal_connect.connected;
    let completed =
        dhcp_success && ipv4_address && default_route && dns_ready && hostname_tcp_ready;
    let post_dhcp_cleanup = wifi_ip_state_cleanup_json(busybox_path);
    let cleanup = wifi_association_cleanup_json(socket_path, network_id);

    format!(
        concat!(
            "{{\"attempted\":true,\"completed\":{},\"reason\":{},",
            "\"association\":{},\"preDhcpCleanup\":{},\"dhcp\":{},\"dhcpSuccess\":{},",
            "\"ifconfig\":{},\"ipv4AddressPresent\":{},\"defaultRoutePresent\":{},",
            "\"dnsReady\":{},\"hostnameTcpReady\":{},\"procNetRoute\":{},\"resolvConf\":{},",
            "\"tcpConnect\":[{},{},{}],\"postDhcpCleanup\":{},\"cleanup\":{}}}"
        ),
        bool_word(completed),
        json_string(if completed { "" } else { "ip-proof-failed" }),
        association.json,
        pre_dhcp_cleanup,
        dhcp_json,
        bool_word(dhcp_success),
        ifconfig_json,
        bool_word(ipv4_address),
        bool_word(default_route),
        bool_word(dns_ready),
        bool_word(hostname_tcp_ready),
        json_string(&route_text),
        json_string(&resolv_conf),
        relay_connect.json,
        primal_connect.json,
        fallback_connect.json,
        post_dhcp_cleanup,
        cleanup
    )
}

pub(super) fn wifi_runtime_clock_json(config: &Config) -> WifiRuntimeClockSet {
    let secs = config.wifi_runtime_clock_unix_secs;
    if secs == 0 {
        return WifiRuntimeClockSet {
            json: "{\"attempted\":false,\"reason\":\"disabled\"}".to_string(),
            ready: true,
        };
    }
    let timespec = libc::timespec {
        tv_sec: secs as libc::time_t,
        tv_nsec: 0,
    };
    let rc = unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &timespec) };
    if rc == 0 {
        WifiRuntimeClockSet {
            json: format!("{{\"attempted\":true,\"ok\":true,\"unixSecs\":{secs}}}"),
            ready: true,
        }
    } else {
        WifiRuntimeClockSet {
            json: format!(
                "{{\"attempted\":true,\"ok\":false,\"unixSecs\":{},\"error\":{}}}",
                secs,
                json_string(&io::Error::last_os_error().to_string())
            ),
            ready: false,
        }
    }
}

pub(super) fn start_wifi_runtime_network(
    config: &Config,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> WifiRuntimeNetworkStart {
    let clock = wifi_runtime_clock_json(config);
    let clock_json = clock.json;
    if !clock.ready {
        return WifiRuntimeNetworkStart {
            json: format!(
                "{{\"attempted\":true,\"completed\":false,\"reason\":\"clock-set-failed\",\"clock\":{clock_json}}}"
            ),
            completed: false,
            network: None,
        };
    }
    let binary_path = Path::new("/vendor/bin/hw/wpa_supplicant");
    let socket_path = Path::new("/data/vendor/wifi/wpa/sockets/wlan0");
    if !Path::new("/sys/class/net/wlan0").exists() {
        return WifiRuntimeNetworkStart {
            json: format!(
                "{{\"attempted\":true,\"completed\":false,\"reason\":\"missing-wlan0\",\"clock\":{clock_json}}}"
            ),
            completed: false,
            network: None,
        };
    }
    if !binary_path.is_file() {
        return WifiRuntimeNetworkStart {
            json: format!(
                "{{\"attempted\":true,\"completed\":false,\"reason\":\"missing-binary\",\"clock\":{},\"binary\":{}}}",
                clock_json,
                wifi_boot_path_status_json("/vendor/bin/hw/wpa_supplicant")
            ),
            completed: false,
            network: None,
        };
    }
    if let Err(error) = ensure_sunfish_wpa_supplicant_config() {
        return WifiRuntimeNetworkStart {
            json: format!(
                "{{\"attempted\":true,\"completed\":false,\"reason\":\"config-setup-failed\",\"clock\":{},\"error\":{}}}",
                clock_json,
                json_string(&error.to_string())
            ),
            completed: false,
            network: None,
        };
    }

    thread::sleep(Duration::from_secs(2));
    let _ = fs::remove_file(socket_path);
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-runtime-wpa-supplicant-start",
    );
    let mut child = spawn_sunfish_wifi_android_helper(
        "wpa_supplicant",
        &[
            "-iwlan0",
            "-Dnl80211",
            "-c/data/vendor/wifi/wpa/wpa_supplicant.conf",
            "-O/data/vendor/wifi/wpa/sockets",
            "-puse_p2p_group_interface=1",
        ],
        probe_stage_path,
        probe_stage_prefix,
    );
    let Some(mut child) = child.take() else {
        return WifiRuntimeNetworkStart {
            json: format!(
                "{{\"attempted\":true,\"completed\":false,\"started\":false,\"reason\":\"spawn-failed\",\"clock\":{clock_json}}}"
            ),
            completed: false,
            network: None,
        };
    };

    let start = Instant::now();
    let mut early_exit_status = String::new();
    while start.elapsed() < Duration::from_secs(12) {
        if socket_path.exists() {
            break;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                early_exit_status = status.to_string();
                break;
            }
            Ok(None) => {}
            Err(error) => {
                early_exit_status = format!("status-error: {error}");
                break;
            }
        }
        thread::sleep(Duration::from_millis(250));
    }

    let socket_ready = socket_path.exists();
    if !socket_ready {
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-runtime-wpa-supplicant-socket-missing",
        );
        let child_pid = child.id();
        let log_excerpt = redact_wifi_sensitive_text(&read_file_excerpt(
            "/orange-gpu/wifi-helper-wpa_supplicant.log",
            8192,
        ));
        let cleanup = stop_wifi_runtime_child_json(&mut child);
        return WifiRuntimeNetworkStart {
            json: format!(
                concat!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"socket-missing\",",
                    "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":false,",
                    "\"earlyExit\":{},\"socket\":{},\"cleanup\":{},\"logExcerpt\":{}}}"
                ),
                clock_json,
                child_pid,
                json_string(&early_exit_status),
                wifi_boot_path_status_json("/data/vendor/wifi/wpa/sockets/wlan0"),
                cleanup,
                json_string(&log_excerpt)
            ),
            completed: false,
            network: None,
        };
    }

    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-runtime-wpa-ping",
    );
    let ping = wpa_ctrl_command_result_json(socket_path, "PING", Duration::from_secs(2));
    let status_before_scan =
        wpa_ctrl_command_result_json(socket_path, "STATUS", Duration::from_secs(2));
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-runtime-wpa-scan",
    );
    let scan = wpa_ctrl_command_result_json(socket_path, "SCAN", Duration::from_secs(2));
    thread::sleep(Duration::from_secs(6));
    let scan_results = wpa_scan_results_json(socket_path, Duration::from_secs(2));
    let status_after_scan =
        wpa_ctrl_command_result_json(socket_path, "STATUS", Duration::from_secs(2));
    let credentials = read_wifi_credentials_once(&config.wifi_credentials_path);
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-runtime-association-start",
    );
    let association = run_wifi_association(socket_path, &credentials, false);
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-runtime-association-done",
    );
    let Some(network_id) = association.network_id else {
        let cleanup = stop_wifi_runtime_child_json(&mut child);
        return WifiRuntimeNetworkStart {
            json: format!(
                concat!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"association-setup-failed\",",
                    "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":true,",
                    "\"earlyExit\":{},\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
                    "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},\"cleanup\":{}}}"
                ),
                clock_json,
                child.id(),
                json_string(&early_exit_status),
                ping,
                status_before_scan,
                scan,
                scan_results,
                status_after_scan,
                association.json,
                cleanup
            ),
            completed: false,
            network: None,
        };
    };
    if !association.completed {
        let association_cleanup = wifi_association_cleanup_json(socket_path, network_id);
        let child_cleanup = stop_wifi_runtime_child_json(&mut child);
        return WifiRuntimeNetworkStart {
            json: format!(
                concat!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"association-failed\",",
                    "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":true,",
                    "\"earlyExit\":{},\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
                    "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},",
                    "\"associationCleanup\":{},\"cleanup\":{}}}"
                ),
                clock_json,
                child.id(),
                json_string(&early_exit_status),
                ping,
                status_before_scan,
                scan,
                scan_results,
                status_after_scan,
                association.json,
                association_cleanup,
                child_cleanup
            ),
            completed: false,
            network: None,
        };
    }

    let busybox_path = Path::new(&config.wifi_dhcp_client_path);
    if !busybox_path.is_file() {
        let association_cleanup = wifi_association_cleanup_json(socket_path, network_id);
        let child_cleanup = stop_wifi_runtime_child_json(&mut child);
        return WifiRuntimeNetworkStart {
            json: format!(
                concat!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"missing-dhcp-client\",",
                    "\"clock\":{},\"association\":{},\"associationCleanup\":{},\"cleanup\":{}}}"
                ),
                clock_json, association.json, association_cleanup, child_cleanup
            ),
            completed: false,
            network: None,
        };
    }

    let script_path = Path::new("/orange-gpu/udhcpc-script");
    if let Err(error) = write_udhcpc_script(script_path, &config.wifi_dhcp_client_path) {
        let association_cleanup = wifi_association_cleanup_json(socket_path, network_id);
        let child_cleanup = stop_wifi_runtime_child_json(&mut child);
        return WifiRuntimeNetworkStart {
            json: format!(
                concat!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"dhcp-script-failed\",",
                    "\"clock\":{},\"association\":{},\"dhcpScriptError\":{},",
                    "\"associationCleanup\":{},\"cleanup\":{}}}"
                ),
                clock_json,
                association.json,
                json_string(&error.to_string()),
                association_cleanup,
                child_cleanup
            ),
            completed: false,
            network: None,
        };
    }

    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-runtime-dhcp-start",
    );
    let pre_dhcp_cleanup = wifi_ip_state_cleanup_json(busybox_path);
    let dhcp_output = Command::new(busybox_path)
        .args([
            "udhcpc",
            "-i",
            "wlan0",
            "-n",
            "-q",
            "-t",
            "5",
            "-T",
            "3",
            "-s",
            "/orange-gpu/udhcpc-script",
        ])
        .output();
    let dhcp_success = command_success(&dhcp_output);
    let busybox_label = busybox_path.display().to_string();
    let dhcp_json = command_output_json(
        &format!("{busybox_label} udhcpc -i wlan0 -n -q -t 5 -T 3 -s /orange-gpu/udhcpc-script"),
        dhcp_output,
    );
    let ifconfig_output = Command::new(busybox_path)
        .args(["ifconfig", "wlan0"])
        .output();
    let ifconfig_text = ifconfig_output
        .as_ref()
        .ok()
        .map(|output| wifi_command_text(&output.stdout, 8192))
        .unwrap_or_default();
    let ifconfig_json =
        command_output_json(&format!("{busybox_label} ifconfig wlan0"), ifconfig_output);
    let route_text = read_file_excerpt("/proc/net/route", 8192);
    let resolv_conf = read_file_excerpt("/etc/resolv.conf", 4096);
    let default_route = proc_net_route_has_default_wlan0(&route_text);
    let ipv4_address = wlan0_has_ipv4_address(&ifconfig_text);
    let dns_ready = resolv_conf_has_nameserver(&resolv_conf);
    let relay_connect = tcp_connect_probe("relay.damus.io", 443);
    let primal_connect = tcp_connect_probe("relay.primal.net", 443);
    let fallback_connect = tcp_connect_probe("1.1.1.1", 53);
    let supplicant_liveness = wifi_child_liveness_json(&mut child);
    let hostname_tcp_ready = relay_connect.connected || primal_connect.connected;
    let completed = dhcp_success
        && ipv4_address
        && default_route
        && dns_ready
        && hostname_tcp_ready
        && supplicant_liveness.alive;
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-runtime-dhcp-done",
    );

    if !completed {
        let post_dhcp_cleanup = wifi_ip_state_cleanup_json(busybox_path);
        let association_cleanup = wifi_association_cleanup_json(socket_path, network_id);
        let child_cleanup = stop_wifi_runtime_child_json(&mut child);
        return WifiRuntimeNetworkStart {
            json: format!(
                concat!(
                    "{{\"attempted\":true,\"completed\":false,\"reason\":\"runtime-network-failed\",",
                    "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":true,",
                    "\"earlyExit\":{},\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
                    "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},",
                    "\"preDhcpCleanup\":{},\"dhcp\":{},\"dhcpSuccess\":{},\"ifconfig\":{},",
                    "\"ipv4AddressPresent\":{},\"defaultRoutePresent\":{},\"dnsReady\":{},",
                    "\"hostnameTcpReady\":{},\"procNetRoute\":{},\"resolvConf\":{},",
                    "\"tcpConnect\":[{},{},{}],",
                    "\"supplicant\":{},\"postDhcpCleanup\":{},\"associationCleanup\":{},",
                    "\"cleanup\":{}}}"
                ),
                clock_json,
                child.id(),
                json_string(&early_exit_status),
                ping,
                status_before_scan,
                scan,
                scan_results,
                status_after_scan,
                association.json,
                pre_dhcp_cleanup,
                dhcp_json,
                bool_word(dhcp_success),
                ifconfig_json,
                bool_word(ipv4_address),
                bool_word(default_route),
                bool_word(dns_ready),
                bool_word(hostname_tcp_ready),
                json_string(&route_text),
                json_string(&resolv_conf),
                relay_connect.json,
                primal_connect.json,
                fallback_connect.json,
                supplicant_liveness.json,
                post_dhcp_cleanup,
                association_cleanup,
                child_cleanup
            ),
            completed: false,
            network: None,
        };
    }

    let child_pid = child.id();
    WifiRuntimeNetworkStart {
        json: format!(
            concat!(
                "{{\"attempted\":true,\"completed\":true,\"reason\":\"\",",
                "\"clock\":{},\"started\":true,\"pid\":{},\"socketReady\":true,",
                "\"earlyExit\":{},\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
                "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},",
                "\"preDhcpCleanup\":{},\"dhcp\":{},\"dhcpSuccess\":true,\"ifconfig\":{},",
                "\"ipv4AddressPresent\":true,\"defaultRoutePresent\":true,\"dnsReady\":true,",
                "\"hostnameTcpReady\":true,\"procNetRoute\":{},\"resolvConf\":{},",
                "\"tcpConnect\":[{},{},{}],",
                "\"supplicant\":{},\"cleanup\":[]}}"
            ),
            clock_json,
            child_pid,
            json_string(&early_exit_status),
            ping,
            status_before_scan,
            scan,
            scan_results,
            status_after_scan,
            association.json,
            pre_dhcp_cleanup,
            dhcp_json,
            ifconfig_json,
            json_string(&route_text),
            json_string(&resolv_conf),
            relay_connect.json,
            primal_connect.json,
            fallback_connect.json,
            supplicant_liveness.json
        ),
        completed: true,
        network: Some(WifiRuntimeNetwork {
            child,
            socket_path: socket_path.to_path_buf(),
            busybox_path: busybox_path.to_path_buf(),
            network_id,
        }),
    }
}

pub(super) fn stop_wifi_runtime_network_json(
    network: &mut WifiRuntimeNetwork,
    reason: &str,
) -> String {
    let ip_cleanup = wifi_ip_state_cleanup_json(&network.busybox_path);
    let association_cleanup =
        wifi_association_cleanup_json(&network.socket_path, network.network_id);
    let child_cleanup = stop_wifi_runtime_child_json(&mut network.child);
    format!(
        "{{\"attempted\":true,\"reason\":{},\"ipCleanup\":{},\"associationCleanup\":{},\"childCleanup\":{}}}",
        json_string(reason),
        ip_cleanup,
        association_cleanup,
        child_cleanup
    )
}

pub(super) fn remove_wifi_helper_log_json(name: &str) -> String {
    let output_path = format!("/orange-gpu/wifi-helper-{name}.log");
    match fs::remove_file(&output_path) {
        Ok(()) => format!(
            "{{\"attempted\":true,\"removed\":true,\"path\":{}}}",
            json_string(&output_path)
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound => format!(
            "{{\"attempted\":true,\"removed\":false,\"missing\":true,\"path\":{}}}",
            json_string(&output_path)
        ),
        Err(error) => format!(
            "{{\"attempted\":true,\"removed\":false,\"missing\":false,\"path\":{},\"error\":{}}}",
            json_string(&output_path),
            json_string(&error.to_string())
        ),
    }
}

pub(super) fn stop_wifi_runtime_child_json(child: &mut Child) -> String {
    let child_cleanup = stop_child_json(child);
    let log_cleanup = remove_wifi_helper_log_json("wpa_supplicant");
    format!("{{\"child\":{},\"log\":{}}}", child_cleanup, log_cleanup)
}

pub(super) fn stop_wifi_runtime_network(
    network: &mut Option<WifiRuntimeNetwork>,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
    reason: &str,
) {
    let Some(mut network) = network.take() else {
        return;
    };
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-runtime-network-stop",
    );
    let cleanup = stop_wifi_runtime_network_json(&mut network, reason);
    append_wrapper_log(&format!("wifi-runtime-network-cleanup {cleanup}"));
}

pub(super) fn wpa_scan_results_json(socket_path: &Path, timeout: Duration) -> String {
    let client_path = format!(
        "/data/vendor/wifi/wpa/sockets/shadow-wpa-{}-scanresults",
        process::id()
    );
    let client_path = Path::new(&client_path);
    let _ = fs::remove_file(client_path);
    let socket = match UnixDatagram::bind(client_path) {
        Ok(socket) => socket,
        Err(error) => {
            return format!(
                "{{\"command\":\"SCAN_RESULTS\",\"ok\":false,\"error\":{}}}",
                json_string(&format!("bind {client_path:?}: {error}"))
            )
        }
    };
    let _ = fs::set_permissions(client_path, fs::Permissions::from_mode(0o770));
    if let Ok(c_client_path) = CString::new(client_path.as_os_str().as_bytes()) {
        let _ = unsafe { libc::chown(c_client_path.as_ptr(), 1010, 1010) };
    }
    let _ = socket.set_read_timeout(Some(timeout));
    let result = if let Err(error) = socket.connect(socket_path) {
        format!(
            "{{\"command\":\"SCAN_RESULTS\",\"ok\":false,\"error\":{}}}",
            json_string(&format!("connect {socket_path:?}: {error}"))
        )
    } else if let Err(error) = socket.send(b"SCAN_RESULTS") {
        format!(
            "{{\"command\":\"SCAN_RESULTS\",\"ok\":false,\"error\":{}}}",
            json_string(&format!("send: {error}"))
        )
    } else {
        let mut buf = vec![0_u8; 131072];
        match socket.recv(&mut buf) {
            Ok(size) => {
                let response = wpa_ctrl_response_text(&buf[..size]);
                let mut networks = Vec::new();
                let mut bss_count = 0_usize;
                for line in response.lines().skip(1) {
                    let fields = line.split('\t').collect::<Vec<_>>();
                    if fields.len() < 4 {
                        continue;
                    }
                    bss_count += 1;
                    if networks.len() < 20 {
                        networks.push(format!(
                            "{{\"frequency\":{},\"signalLevel\":{},\"flags\":{}}}",
                            json_string(fields[1]),
                            json_string(fields[2]),
                            json_string(fields[3])
                        ));
                    }
                }
                format!(
                    concat!(
                        "{{\"command\":\"SCAN_RESULTS\",\"ok\":{},",
                        "\"bssCount\":{},\"networks\":[{}]}}"
                    ),
                    bool_word(bss_count > 0 || response.starts_with("bssid")),
                    bss_count,
                    networks.join(",")
                )
            }
            Err(error) => format!(
                "{{\"command\":\"SCAN_RESULTS\",\"ok\":false,\"error\":{}}}",
                json_string(&format!("recv: {error}"))
            ),
        }
    };
    let _ = fs::remove_file(client_path);
    result
}

pub(super) fn wifi_child_liveness_json(child: &mut Child) -> WifiChildLiveness {
    match child.try_wait() {
        Ok(Some(status)) => WifiChildLiveness {
            json: format!(
                "{{\"alive\":false,\"status\":{},\"error\":\"\"}}",
                json_string(&status.to_string())
            ),
            alive: false,
        },
        Ok(None) => WifiChildLiveness {
            json: "{\"alive\":true,\"status\":\"\",\"error\":\"\"}".to_string(),
            alive: true,
        },
        Err(error) => WifiChildLiveness {
            json: format!(
                "{{\"alive\":false,\"status\":\"\",\"error\":{}}}",
                json_string(&error.to_string())
            ),
            alive: false,
        },
    }
}

pub(super) fn stop_child_json(child: &mut Child) -> String {
    match child.try_wait() {
        Ok(Some(status)) => format!(
            "{{\"attempted\":true,\"alreadyExited\":true,\"status\":{}}}",
            json_string(&status.to_string())
        ),
        Ok(None) => {
            let kill_result = child.kill();
            let wait_result = child.wait();
            format!(
                concat!(
                    "{{\"attempted\":true,\"alreadyExited\":false,",
                    "\"killOk\":{},\"killError\":{},\"waitOk\":{},\"waitStatus\":{},\"waitError\":{}}}"
                ),
                bool_word(kill_result.is_ok()),
                json_optional_string(kill_result.err().map(|error| error.to_string())),
                bool_word(wait_result.is_ok()),
                json_optional_string(wait_result.as_ref().ok().map(|status| status.to_string())),
                json_optional_string(wait_result.err().map(|error| error.to_string()))
            )
        }
        Err(error) => format!(
            "{{\"attempted\":true,\"alreadyExited\":false,\"statusError\":{}}}",
            json_string(&error.to_string())
        ),
    }
}

pub(super) fn wifi_supplicant_probe_json(
    config: &Config,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> String {
    let binary_path = Path::new("/vendor/bin/hw/wpa_supplicant");
    let socket_path = Path::new("/data/vendor/wifi/wpa/sockets/wlan0");
    if !Path::new("/sys/class/net/wlan0").exists() {
        return "{\"attempted\":false,\"reason\":\"missing-wlan0\"}".to_string();
    }
    if !binary_path.is_file() {
        return format!(
            "{{\"attempted\":false,\"reason\":\"missing-binary\",\"binary\":{}}}",
            wifi_boot_path_status_json("/vendor/bin/hw/wpa_supplicant")
        );
    }
    if let Err(error) = ensure_sunfish_wpa_supplicant_config() {
        return format!(
            "{{\"attempted\":false,\"reason\":\"config-setup-failed\",\"error\":{}}}",
            json_string(&error.to_string())
        );
    }

    thread::sleep(Duration::from_secs(2));
    let _ = fs::remove_file(socket_path);
    write_payload_probe_stage(
        probe_stage_path,
        probe_stage_prefix,
        "wifi-wpa-supplicant-start",
    );
    let mut child = spawn_sunfish_wifi_android_helper(
        "wpa_supplicant",
        &[
            "-iwlan0",
            "-Dnl80211",
            "-c/data/vendor/wifi/wpa/wpa_supplicant.conf",
            "-O/data/vendor/wifi/wpa/sockets",
            "-puse_p2p_group_interface=1",
            "-dd",
        ],
        probe_stage_path,
        probe_stage_prefix,
    );
    let Some(child) = child.as_mut() else {
        return "{\"attempted\":true,\"started\":false,\"reason\":\"spawn-failed\"}".to_string();
    };

    let start = Instant::now();
    let mut early_exit_status = String::new();
    while start.elapsed() < Duration::from_secs(12) {
        if socket_path.exists() {
            break;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                early_exit_status = status.to_string();
                break;
            }
            Ok(None) => {}
            Err(error) => {
                early_exit_status = format!("status-error: {error}");
                break;
            }
        }
        thread::sleep(Duration::from_millis(250));
    }

    let socket_ready = socket_path.exists();
    if !socket_ready {
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-wpa-supplicant-socket-missing",
        );
        let child_pid = child.id();
        let cleanup = stop_child_json(child);
        return format!(
            concat!(
                "{{\"attempted\":true,\"started\":true,\"pid\":{},",
                "\"socketReady\":false,\"earlyExit\":{},\"socket\":{},",
                "\"cleanup\":{},\"logExcerpt\":{}}}"
            ),
            child_pid,
            json_string(&early_exit_status),
            wifi_boot_path_status_json("/data/vendor/wifi/wpa/sockets/wlan0"),
            cleanup,
            json_string(&redact_wifi_sensitive_text(&read_file_excerpt(
                "/orange-gpu/wifi-helper-wpa_supplicant.log",
                8192
            )))
        );
    }

    write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wpa-ping-start");
    let ping = wpa_ctrl_command_result_json(socket_path, "PING", Duration::from_secs(2));
    let status_before_scan =
        wpa_ctrl_command_result_json(socket_path, "STATUS", Duration::from_secs(2));
    write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wpa-scan-start");
    let scan = wpa_ctrl_command_result_json(socket_path, "SCAN", Duration::from_secs(2));
    thread::sleep(Duration::from_secs(6));
    let scan_results = wpa_scan_results_json(socket_path, Duration::from_secs(2));
    let status_after_scan =
        wpa_ctrl_command_result_json(socket_path, "STATUS", Duration::from_secs(2));
    let association_credentials = if config.wifi_association_probe || config.wifi_ip_probe {
        Some(read_wifi_credentials_once(&config.wifi_credentials_path))
    } else {
        None
    };
    let association = if config.wifi_association_probe
        && !config.wifi_ip_probe
        && association_credentials.is_some()
    {
        let credentials = association_credentials.as_ref().expect("checked is_some");
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-wpa-association-start",
        );
        let association = wifi_association_probe_json(socket_path, credentials);
        write_payload_probe_stage(
            probe_stage_path,
            probe_stage_prefix,
            "wifi-wpa-association-done",
        );
        association
    } else {
        "{\"attempted\":false,\"reason\":\"disabled\"}".to_string()
    };
    let ip = if config.wifi_ip_probe {
        if let Some(credentials) = association_credentials.as_ref() {
            write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wpa-ip-start");
            let ip = wifi_ip_probe_json(config, socket_path, credentials);
            write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wpa-ip-done");
            ip
        } else {
            "{\"attempted\":false,\"reason\":\"credentials-unavailable\"}".to_string()
        }
    } else {
        "{\"attempted\":false,\"reason\":\"disabled\"}".to_string()
    };
    write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-wpa-probe-done");
    let child_pid = child.id();
    let cleanup = stop_child_json(child);

    format!(
        concat!(
            "{{\"attempted\":true,\"started\":true,\"pid\":{},",
            "\"socketReady\":true,\"earlyExit\":{},\"socket\":{},",
            "\"ping\":{},\"statusBeforeScan\":{},\"scan\":{},",
            "\"scanResults\":{},\"statusAfterScan\":{},\"association\":{},\"ip\":{},",
            "\"cleanup\":{},\"logExcerpt\":{}}}"
        ),
        child_pid,
        json_string(&early_exit_status),
        wifi_boot_path_status_json("/data/vendor/wifi/wpa/sockets/wlan0"),
        ping,
        status_before_scan,
        scan,
        scan_results,
        status_after_scan,
        association,
        ip,
        cleanup,
        json_string(&redact_wifi_sensitive_text(&read_file_excerpt(
            "/orange-gpu/wifi-helper-wpa_supplicant.log",
            8192
        )))
    )
}

pub(super) fn write_wifi_boot_summary(summary: &str) -> io::Result<()> {
    let temp_path = Path::new(ORANGE_GPU_ROOT).join(".wifi-linux-surface-summary.json.tmp");
    write_atomic_text_file(&temp_path, Path::new(ORANGE_GPU_SUMMARY_PATH), summary)
}

pub(super) fn run_wifi_linux_surface_probe_internal(
    config: &Config,
    probe_stage_path: Option<&Path>,
    probe_stage_prefix: Option<&str>,
) -> i32 {
    write_payload_probe_stage(probe_stage_path, probe_stage_prefix, "wifi-surface-start");

    let path_statuses = [
        "/sys/class/net/wlan0",
        "/sys/class/net/wlan1",
        "/sys/class/net/p2p0",
        "/sys/module/wlan",
        "/sys/kernel/wlan",
        "/sys/kernel/debug/wlan0",
        "/sys/kernel/debug/icnss",
        "/sys/kernel/debug/icnss/stats",
        "/dev/wlan",
        "/proc/net/wireless",
        "/lib/modules/wlan.ko",
        "/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini",
        "/lib/firmware/wlanmdsp.mbn",
        "/lib/firmware/wlan/qca_cld",
    ]
    .iter()
    .map(|path| wifi_boot_path_status_json(path))
    .collect::<Vec<_>>()
    .join(",\n    ");
    let activation_probe =
        wifi_interface_activation_probe_json(probe_stage_path, probe_stage_prefix);
    let supplicant_probe = if config.wifi_supplicant_probe {
        wifi_supplicant_probe_json(config, probe_stage_path, probe_stage_prefix)
    } else {
        "{\"attempted\":false,\"reason\":\"disabled\"}".to_string()
    };
    let net_interfaces = ["wlan0", "wlan1", "p2p0"]
        .iter()
        .map(|iface| wifi_interface_json(iface))
        .collect::<Vec<_>>()
        .join(",\n    ");
    let sys_module_wlan = read_dir_names("/sys/module/wlan", 64);
    let sys_kernel_wlan = read_dir_names("/sys/kernel/wlan", 64);
    let debug_wlan0 = read_dir_names("/sys/kernel/debug/wlan0", 64);
    let debug_icnss = read_dir_names("/sys/kernel/debug/icnss", 64);
    let debug_icnss_stats = read_file_excerpt("/sys/kernel/debug/icnss/stats", 16384);
    let proc_wireless = read_file_excerpt("/proc/net/wireless", 4096);
    let module_details = wifi_module_details_json();
    let helper_snapshot = wifi_helper_process_snapshot();
    let helper_processes = &helper_snapshot.processes_json;
    let helper_contract = wifi_helper_contract_json(&config.wifi_helper_profile, &helper_snapshot);
    let helper_logs = wifi_helper_logs_json();
    let kernel_log = redact_wifi_sensitive_text(&wifi_kernel_log_excerpt());
    let helper_contract_ok = wifi_helper_contract_ok(&config.wifi_helper_profile, &helper_snapshot);
    let blocker = if !helper_contract_ok {
        "wifi helper profile contract is not satisfied"
    } else if !Path::new("/sys/class/net/wlan0").exists() {
        "wlan0 is not visible in Shadow boot userspace"
    } else if !Path::new("/dev/wlan").exists() {
        "wlan0 exists but /dev/wlan vendor control node is missing"
    } else {
        ""
    };
    let stage = if blocker.is_empty() {
        "surface-ready"
    } else {
        "surface-blocked"
    };
    write_payload_probe_stage(probe_stage_path, probe_stage_prefix, stage);

    let summary = format!(
        concat!(
            "{{\n",
            "  \"schemaVersion\": 1,\n",
            "  \"kind\": \"wifi-linux-surface-probe\",\n",
            "  \"mode\": \"wifi-linux-surface-probe\",\n",
            "  \"pid\": {},\n",
            "  \"runToken\": {},\n",
            "  \"mounts\": {{\"dev\": {}, \"proc\": {}, \"sys\": {}, \"devMount\": {}}},\n",
            "  \"wifiBootstrap\": {},\n",
            "  \"wifiHelperProfile\": {},\n",
            "  \"wifiSupplicantProbe\": {},\n",
            "  \"wifiAssociationProbe\": {},\n",
            "  \"wifiIpProbe\": {},\n",
            "  \"wifiCredentialsPathConfigured\": {},\n",
            "  \"wifiDhcpClientPathConfigured\": {},\n",
            "  \"androidWifiApiUse\": {{\"WifiManager\": false, \"wificond\": false, \"wpaSupplicantService\": false, \"vendorWpaSupplicantControlSocket\": {}, \"rootedAndroidShellWifiApi\": false, \"rootedAndroidShellRecoveryOnly\": true}},\n",
            "  \"pathStatus\": [\n    {}\n  ],\n",
            "  \"interfaces\": [\n    {}\n  ],\n",
            "  \"sysModuleWlanEntries\": {},\n",
            "  \"sysModuleWlanDetails\": {},\n",
            "  \"sysKernelWlanEntries\": {},\n",
            "  \"debugWlan0Entries\": {},\n",
            "  \"debugIcnssEntries\": {},\n",
            "  \"debugIcnssStats\": {},\n",
            "  \"procNetWireless\": {},\n",
            "  \"wifiHelperProcesses\": {},\n",
            "  \"wifiHelperContract\": {},\n",
            "  \"wifiHelperLogs\": {},\n",
            "  \"activationProbe\": {},\n",
            "  \"supplicantProbe\": {},\n",
            "  \"kernelLogExcerpt\": {},\n",
            "  \"surfaceReady\": {},\n",
            "  \"blockerStage\": {},\n",
            "  \"blocker\": {},\n",
            "  \"nextStep\": {}\n",
            "}}\n"
        ),
        process::id(),
        json_string(run_token_or_unset(config)),
        bool_word(config.mount_dev),
        bool_word(config.mount_proc),
        bool_word(config.mount_sys),
        json_string(&config.dev_mount),
        json_string(&config.wifi_bootstrap),
        json_string(&config.wifi_helper_profile),
        bool_word(config.wifi_supplicant_probe),
        bool_word(config.wifi_association_probe),
        bool_word(config.wifi_ip_probe),
        bool_word(!config.wifi_credentials_path.is_empty()),
        bool_word(!config.wifi_dhcp_client_path.is_empty()),
        bool_word(config.wifi_supplicant_probe),
        path_statuses,
        net_interfaces,
        json_string_array(&sys_module_wlan),
        module_details,
        json_string_array(&sys_kernel_wlan),
        json_string_array(&debug_wlan0),
        json_string_array(&debug_icnss),
        json_string(&debug_icnss_stats),
        json_string(&proc_wireless),
        helper_processes,
        helper_contract,
        helper_logs,
        activation_probe,
        supplicant_probe,
        json_string(&kernel_log),
        bool_word(blocker.is_empty()),
        json_string(stage),
        json_string(blocker),
        json_string(if blocker.is_empty() {
            "run a contained WPA association probe against wlan0 using nl80211 or the vendor supplicant binary"
        } else {
            "stage/load wlan.ko plus the minimal qca_cld firmware/config roots, then rerun this probe"
        })
    );

    match write_wifi_boot_summary(&summary) {
        Ok(()) => {
            if blocker.is_empty() {
                0
            } else {
                2
            }
        }
        Err(error) => {
            log_line(&format!(
                "failed to write wifi linux surface summary: {error}"
            ));
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wpa_command_labels_redact_credentials() {
        let ssid = "ExampleNetwork";
        let psk = "example-passphrase";
        let raw = format!("SET_NETWORK 7 ssid {}\nSET_NETWORK 7 psk \"{}\"", ssid, psk);
        let redacted = wpa_ctrl_command_label(&raw);

        assert!(!redacted.contains(ssid));
        assert!(!redacted.contains(psk));
        assert!(redacted.contains("SET_NETWORK 7 ssid <redacted>"));
        assert!(redacted.contains("SET_NETWORK 7 psk <redacted>"));
    }

    #[test]
    fn wpa_result_json_defensively_redacts_raw_command_label() {
        let result = WpaCtrlCommandResult {
            command_label: "SET_NETWORK 3 psk \"example-passphrase\"".to_string(),
            ok: true,
            response: "OK".to_string(),
            error: String::new(),
        };
        let json = wpa_ctrl_result_json(&result);

        assert!(!json.contains("example-passphrase"));
        assert!(json.contains("SET_NETWORK 3 psk <redacted>"));
    }
}
