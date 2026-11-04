# Required main collides with the C host

Reproduced with Roc `nightly-2026-09-04-c125b82` on Linux x64/glibc. The C host
returns immediately; none of its allocation callbacks execute in this case.

Supply x64 glibc link inputs, a `crt1.o` and a `libc.so` link stub, in
`repro/required-main-host-collision/targets/x64glibc/`, then run from the
repository root:

```sh
mkdir -p repro/required-main-host-collision/targets/x64glibc
cc -c repro/required-main-host-collision/host.c -o .test-out/repro-host.o
ar rcs repro/required-main-host-collision/targets/x64glibc/libhost.a .test-out/repro-host.o
roc run repro/required-main-host-collision/app.roc
```

Expected failure: duplicate `main` defined by `host.o` and `roc_platform_shim`.
The platform provides only `roc_ui_init`; the app's required `main` should not
be emitted as another C process entry. No Signals engine is linked.
