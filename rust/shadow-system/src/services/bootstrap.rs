use deno_core::{extension, Extension};

extension!(
    shadow_system_bootstrap_extension,
    esm_entry_point = "ext:shadow_system_bootstrap_extension/bootstrap.js",
    esm = [dir "js", "bootstrap.js"],
);

pub fn init_extension() -> Extension {
    shadow_system_bootstrap_extension::init()
}
