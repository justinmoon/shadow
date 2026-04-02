use std::fs;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=DENO_RUNTIME_SMOKE_SNAPSHOT_SOURCE");
    let out_dir = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR must be set"));
    let snapshot_path = out_dir.join("RUNTIME_SNAPSHOT.bin");
    let snapshot_source = PathBuf::from(
        std::env::var_os("DENO_RUNTIME_SMOKE_SNAPSHOT_SOURCE")
            .expect("DENO_RUNTIME_SMOKE_SNAPSHOT_SOURCE must be set"),
    );
    println!("cargo:rerun-if-changed={}", snapshot_source.display());
    println!(
        "cargo:warning=deno-runtime-smoke build.rs staging snapshot {} -> {}",
        snapshot_source.display(),
        snapshot_path.display()
    );
    fs::copy(&snapshot_source, &snapshot_path).unwrap_or_else(|error| {
        panic!(
            "copy runtime snapshot {} -> {}: {error}",
            snapshot_source.display(),
            snapshot_path.display()
        )
    });
}
