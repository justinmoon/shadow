use libc::{c_void, dlerror, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::env;
use std::ffi::{CStr, CString, OsString};
use std::fs;
use std::os::raw::c_char;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;

pub(crate) fn candidate_libraries(hal_path: &str) -> Vec<Value> {
    let mut paths = BTreeSet::new();
    paths.insert(PathBuf::from(hal_path));
    collect_matching_libs("/vendor/lib64/hw", &["camera", "gralloc"], &mut paths);
    collect_matching_libs(
        "/vendor/lib64",
        &["camera", "camx", "chi", "googlecamerahal", "gralloc"],
        &mut paths,
    );
    collect_matching_libs(
        "/system/lib64",
        &[
            "libbinder",
            "libhidl",
            "libhardware",
            "libnativewindow",
            "libgralloc",
        ],
        &mut paths,
    );
    paths.iter().map(|path| file_json(path)).collect()
}

fn collect_matching_libs(dir: &str, needles: &[&str], out: &mut BTreeSet<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if name.ends_with(".so") && contains_any(&name.to_ascii_lowercase(), needles) {
            out.insert(path);
        }
    }
}

pub(crate) fn probe_support_dlopen(name: &str) -> Value {
    let name_c = CString::new(name).expect("static library CString");
    let handle = unsafe {
        let _ = dlerror();
        dlopen(name_c.as_ptr(), RTLD_NOW | RTLD_LOCAL)
    };
    if handle.is_null() {
        json!({"name": name, "ok": false, "error": dl_error_message(format!("dlopen {name}"))})
    } else {
        json!({"name": name, "ok": true, "handle": pointer_hex(handle)})
    }
}

pub(crate) fn file_json(path: &Path) -> Value {
    match fs::metadata(path) {
        Ok(metadata) => json!({
            "path": path.to_string_lossy(),
            "exists": true,
            "size": metadata.len(),
            "mode": format!("{:o}", metadata.mode()),
            "uid": metadata.uid(),
            "gid": metadata.gid(),
            "selinuxLabel": selinux_label(path),
        }),
        Err(error) => json!({
            "path": path.to_string_lossy(),
            "exists": false,
            "error": error.to_string(),
        }),
    }
}

pub(crate) fn mapped_shared_libraries() -> BTreeSet<String> {
    fs::read_to_string("/proc/self/maps")
        .ok()
        .into_iter()
        .flat_map(|maps| {
            maps.lines()
                .filter_map(|line| line.split_whitespace().last())
                .filter(|field| field.starts_with('/') && field.contains(".so"))
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .collect()
}

pub(crate) fn command_lines_json(program: &str, args: &[&str], needles: &[&str]) -> Value {
    let output = match Command::new(program).args(args).output() {
        Ok(output) => output,
        Err(error) => return json!({"ok": false, "program": program, "error": error.to_string()}),
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    json!({
        "ok": output.status.success(),
        "program": program,
        "args": args,
        "status": output.status.code(),
        "lines": stdout
            .lines()
            .filter(|line| contains_any(&line.to_ascii_lowercase(), needles))
            .take(200)
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>(),
        "stderr": stderr.lines().take(20).collect::<Vec<_>>(),
    })
}

pub(crate) fn command_stdout(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

pub(crate) fn binder_status_json(status: &binder::Status) -> Value {
    json!({
        "description": status.get_description(),
        "exceptionCode": format!("{:?}", status.exception_code()),
        "transactionError": format!("{:?}", status.transaction_error()),
        "serviceSpecificError": status.service_specific_error(),
    })
}

pub(crate) fn dl_error_message(prefix: impl Into<String>) -> String {
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

pub(crate) fn load_libdl_symbol<T>(name: &str) -> Result<T, String> {
    let symbol = CString::new(name).map_err(|error| format!("invalid symbol CString: {error}"))?;
    let default_ptr = unsafe {
        let _ = dlerror();
        dlsym(libc::RTLD_DEFAULT, symbol.as_ptr())
    };
    if !default_ptr.is_null() {
        return Ok(unsafe { std::mem::transmute_copy(&default_ptr) });
    }

    let default_error = dl_error_message(format!("dlsym RTLD_DEFAULT {name}"));
    let libdl = CString::new("libdl.so").expect("static libdl CString");
    let handle = unsafe { dlopen(libdl.as_ptr(), RTLD_NOW | RTLD_LOCAL) };
    if handle.is_null() {
        return Err(format!(
            "{default_error}; {}",
            dl_error_message("dlopen libdl.so")
        ));
    }
    let ptr = unsafe {
        let _ = dlerror();
        dlsym(handle, symbol.as_ptr())
    };
    if ptr.is_null() {
        return Err(format!(
            "{default_error}; {}",
            dl_error_message(format!("dlsym libdl.so {name}"))
        ));
    }
    Ok(unsafe { std::mem::transmute_copy(&ptr) })
}

pub(crate) fn c_string(ptr: *const c_char) -> Option<String> {
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

pub(crate) fn hex_preview(bytes: &[u8], limit: usize) -> String {
    let mut preview = String::new();
    for byte in bytes.iter().take(limit) {
        preview.push_str(&format!("{byte:02x}"));
    }
    if bytes.len() > limit {
        preview.push_str("...");
    }
    preview
}

pub(crate) fn contains_any(value: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| value.contains(needle))
}

pub(crate) fn pointer_hex(ptr: *mut c_void) -> String {
    format!("0x{:x}", ptr as usize)
}

pub(crate) fn current_dir_string() -> Option<String> {
    env::current_dir()
        .ok()
        .map(|path| path.to_string_lossy().into_owned())
}

pub(crate) fn argv_strings(argv: &[OsString]) -> Vec<String> {
    argv.iter()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect()
}

fn selinux_label(path: &Path) -> Option<String> {
    let output = Command::new("ls").arg("-Zd").arg(path).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}
