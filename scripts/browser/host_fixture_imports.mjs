// These fixtures link the Zig host without a Roc application. They exercise
// allocator, publication, and diagnostics exports, never application callbacks.
// Fail loudly if a test accidentally crosses that boundary.
function unexpectedApplicationCall() {
  throw new Error("Host-only fixture called a Roc application or HTTP effect");
}

export const hostFixtureImports = {
  env: {
    roc_ui_init: unexpectedApplicationCall,
    roc_prepare_effect: unexpectedApplicationCall,
    roc_run_effect: unexpectedApplicationCall,
    roc_ui_http_send: unexpectedApplicationCall,
    // These raw, host-only links never enter an effect stack. A bounds switch
    // would mean the fixture crossed into an untested application path.
    roc_ui_set_stack_limits: unexpectedApplicationCall,
  },
};
