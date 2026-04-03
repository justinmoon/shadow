use std::sync::OnceLock;
use std::time::Instant;

fn start_instant() -> &'static Instant {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now)
}

pub fn runtime_log(message: impl AsRef<str>) {
    let elapsed_ms = start_instant().elapsed().as_millis();
    eprintln!(
        "[shadow-runtime-demo +{elapsed_ms:>6}ms] {}",
        message.as_ref()
    );
}
