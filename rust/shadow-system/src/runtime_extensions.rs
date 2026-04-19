use deno_core::Extension;

use crate::services;

pub fn runtime_extensions() -> Vec<Extension> {
    vec![
        services::camera::init_extension(),
        services::nostr::init_extension(),
        services::audio::init_extension(),
        services::cashu::init_extension(),
        services::clipboard::init_extension(),
        services::bootstrap::init_extension(),
    ]
}

#[cfg(test)]
mod tests {
    use super::runtime_extensions;

    #[test]
    fn runtime_extensions_include_all_current_hosts() {
        assert_eq!(runtime_extensions().len(), 6);
    }
}
