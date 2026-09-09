use std::sync::atomic::{AtomicUsize, Ordering};
static DROPPED: AtomicUsize = AtomicUsize::new(0);
struct Guard;
impl Drop for Guard { fn drop(&mut self) { DROPPED.fetch_add(1, Ordering::SeqCst); } }
#[unsafe(no_mangle)]
pub extern "C" fn check_rust_unwind() -> i32 {
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(|| { let _guard = Guard; panic!("intentional probe"); });
    if result.is_err() && DROPPED.load(Ordering::SeqCst) == 1 { 0 } else { 1 }
}
