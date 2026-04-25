use super::*;

#[derive(Default)]
pub(super) struct PayloadProbeManifest {
    pub(super) schema: String,
    pub(super) payload_source: String,
    pub(super) payload_version: String,
    pub(super) payload_fingerprint: String,
    pub(super) payload_root: String,
    pub(super) payload_marker: String,
}

pub(super) fn payload_probe_root_path(config: &Config) -> PathBuf {
    if !config.payload_probe_root.is_empty() {
        return PathBuf::from(&config.payload_probe_root);
    }
    Path::new(PAYLOAD_PROBE_METADATA_BY_TOKEN_ROOT).join(&config.run_token)
}

pub(super) fn payload_probe_manifest_path(config: &Config, payload_root: &Path) -> PathBuf {
    if !config.payload_probe_manifest_path.is_empty() {
        return PathBuf::from(&config.payload_probe_manifest_path);
    }
    payload_root.join(PAYLOAD_PROBE_MANIFEST_NAME)
}

pub(super) fn payload_probe_marker_path(
    payload_root: &Path,
    manifest: &PayloadProbeManifest,
) -> PathBuf {
    let marker = if manifest.payload_marker.is_empty() {
        PAYLOAD_PROBE_DEFAULT_MARKER_NAME
    } else {
        manifest.payload_marker.as_str()
    };
    let marker_path = Path::new(marker);
    if marker_path.is_absolute() {
        marker_path.to_path_buf()
    } else {
        payload_root.join(marker_path)
    }
}

pub(super) fn read_payload_probe_manifest(path: &Path) -> Result<PayloadProbeManifest, String> {
    let text = fs::read_to_string(path).map_err(|error| format!("manifest-read:{error}"))?;
    let mut manifest = PayloadProbeManifest::default();
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim().to_string();
        match key.trim() {
            "schema" => manifest.schema = value,
            "payload_source" | "source" => manifest.payload_source = value,
            "payload_version" | "version" => manifest.payload_version = value,
            "payload_fingerprint" | "fingerprint" => manifest.payload_fingerprint = value,
            "payload_root" | "root" => manifest.payload_root = value,
            "payload_marker" | "marker" => manifest.payload_marker = value,
            _ => {}
        }
    }
    if manifest.schema != PAYLOAD_PROBE_STRATEGY {
        return Err(format!("unsupported-schema:{}", manifest.schema));
    }
    if manifest.payload_source.is_empty() {
        manifest.payload_source = PAYLOAD_PROBE_SOURCE.to_string();
    }
    if manifest.payload_version.is_empty() {
        return Err("missing-payload-version".to_string());
    }
    if manifest.payload_fingerprint.is_empty() {
        return Err("missing-payload-fingerprint".to_string());
    }
    Ok(manifest)
}

pub(super) fn sha256_file_fingerprint(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|error| format!("marker-open:{error}"))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|error| format!("marker-read:{error}"))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(64);
    for byte in digest {
        let _ = write!(&mut hex, "{byte:02x}");
    }
    Ok(format!("sha256:{hex}"))
}
