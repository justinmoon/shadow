pub mod camera;
#[doc(hidden)]
pub mod camera_backend;
pub mod clipboard;
#[cfg(feature = "nostr")]
pub mod nostr;
#[doc(hidden)]
pub mod session_config;

#[cfg(test)]
pub(crate) fn test_env_lock() -> &'static std::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| std::sync::Mutex::new(()))
}
