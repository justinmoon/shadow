use deno_core::JsRuntime;
use deno_core::RuntimeOptions;

fn main() {
    let mut runtime = JsRuntime::new(RuntimeOptions::default());
    let value = runtime
        .execute_script("<smoke>", "'hello from deno_core'.toUpperCase()")
        .unwrap();

    deno_core::scope!(scope, runtime);
    let local = deno_core::v8::Local::new(scope, value);
    let value = local.to_string(scope).unwrap().to_rust_string_lossy(scope);

    println!("deno_core ok: target={} result={value}", std::env::consts::ARCH);
}
