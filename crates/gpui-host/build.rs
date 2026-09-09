fn main() {
    // Shared Cargo target directories can consider another checkout's host
    // fresh when its source timestamps precede the cached build. The builder
    // receives the checkout identity from .cargo/config.toml so switching trees
    // invalidates this crate, including for direct Cargo invocations.
    println!("cargo::rerun-if-env-changed=SIGNALS_HOST_SOURCE_ROOT");
}
