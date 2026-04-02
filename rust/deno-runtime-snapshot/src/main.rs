use std::env;
use std::path::PathBuf;

fn main() {
    let output_path = env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .expect("usage: deno-runtime-snapshot <output-path> <target-triple>");
    let target = env::args()
        .nth(2)
        .expect("usage: deno-runtime-snapshot <output-path> <target-triple>");

    let snapshot_options = deno_runtime::ops::bootstrap::SnapshotOptions {
        // This should track the Deno runtime version family we are pinned to.
        ts_version: "5.9.2".to_owned(),
        v8_version: deno_core::v8::VERSION_STRING,
        target,
    };

    deno_runtime::snapshot::create_runtime_snapshot(
        output_path,
        snapshot_options,
        vec![],
    );
}
