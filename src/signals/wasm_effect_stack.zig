//! Linear-memory stack switching for the browser effect executor. JSPI saves
//! Wasm execution frames, but the compiler's linear-memory stack is a separate
//! resource. Each suspended effect must retain its own stack until it returns.

/// Reads the compiler's current linear-memory stack pointer without allocating
/// a frame. The executor saves it before entering or suspending an effect.
pub inline fn get() usize {
    return asm volatile (
        \\global.get __stack_pointer
        \\local.set %[result]
        : [result] "=r" (-> usize),
    );
}

/// Selects an already reserved, aligned stack. This must be paired with a saved
/// pointer: restore the main stack before a suspending import and the effect
/// stack immediately on resumption, inside Wasm rather than a JS microtask.
/// The caller owns stack storage and must keep it alive across suspension.
pub inline fn set(pointer: usize) void {
    asm volatile (
        \\local.get %[pointer]
        \\global.set __stack_pointer
        :
        : [pointer] "r" (pointer),
    );
}
