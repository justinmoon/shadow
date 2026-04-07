fn main() {
    println!("cargo::rustc-check-cfg=cfg(android_ndk)");
    println!("cargo::rustc-check-cfg=cfg(android_vndk)");
    println!("cargo::rustc-check-cfg=cfg(android_vendor)");
    println!("cargo::rustc-check-cfg=cfg(trusty)");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        println!("cargo::rustc-cfg=android_ndk");
    }
}
