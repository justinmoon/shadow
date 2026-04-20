#[cfg(any(feature = "cpu", feature = "gpu"))]
fn main() {
    shadow_blitz_demo::app::run();
}

#[cfg(not(any(feature = "cpu", feature = "gpu")))]
fn main() {
    panic!("enable one shadow-blitz-demo renderer feature");
}
