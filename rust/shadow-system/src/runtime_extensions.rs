use deno_core::Extension;

pub fn runtime_extensions() -> Vec<Extension> {
    vec![
        runtime_camera_host::init_extension(),
        runtime_nostr_host::init_extension(),
        runtime_audio_host::init_extension(),
        runtime_cashu_host::init_extension(),
    ]
}

#[cfg(test)]
mod tests {
    use super::runtime_extensions;

    #[test]
    fn runtime_extensions_include_all_current_hosts() {
        assert_eq!(runtime_extensions().len(), 4);
    }
}
