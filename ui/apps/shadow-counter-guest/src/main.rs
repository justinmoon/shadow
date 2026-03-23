#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("shadow-counter-guest currently targets Linux only.");
}

#[cfg(target_os = "linux")]
mod wayland;

#[cfg(target_os = "linux")]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    wayland::run()
}
