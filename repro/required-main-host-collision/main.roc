platform ""
    requires { main : () -> I64 }
    exposes []
    packages {}
    provides { "roc_ui_init": ui_init }
    targets: { inputs_dir: "targets/", x64glibc: { inputs: ["crt1.o", "libhost.a", app, "libc.so"] } }

ui_init : () -> I64
ui_init = || main()
