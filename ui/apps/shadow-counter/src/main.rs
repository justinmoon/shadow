mod color;
mod layout;
mod model;

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("shadow-counter currently targets Linux only.");
}

#[cfg(target_os = "linux")]
mod wayland;

#[cfg(target_os = "linux")]
fn main() {
    wayland::run();
}
