# Complete Windows system import producer

This independent package supplies pure x64 COFF import stubs. Windows supplies
the DLL implementations. The recipe selects complete reviewed source inventories
for 340 DLL identities, including API sets, rather than symbols used by a
particular host. It does not replace the existing ADVAPI32 consumer lock or change
the platform target ABI.

The Linux producer installs checksum-pinned Rust 1.95.0 component archives and
Zig 0.16.0 in a private directory. It verifies every original Cargo archive
against both the recipe and its separate Cargo.lock, constructs a private vendor
directory, and builds with Cargo offline and fresh compiler caches. No platform
host archive, installed Windows SDK, or upstream binary import library is an
input. Only verified downloads are reused across clean builds.

Rust compiles all windows-sys 0.61.2 features and the complete reviewed Windows
0.61.3 module/feature closure in Cargo.toml. Rustc handles architecture conditions
and export-name aliases. The producer extracts only named AMD64 short imports;
implementation objects and Rust helper objects are never published. A separate
source-coverage check visits every Windows 0.61.3 declaration for each selected
DLL, allowing only explicitly x86-only declarations to remain absent. This check
is an inventory guard, not a replacement for Rust's compiler or a generator of
host-specific Rust declarations.

For ADVAPI32, KERNEL32, NTDLL, SHELL32, USER32, USERENV and WS2_32, Zig compiles its
complete bundled MinGW definitions through its normal GNU Windows support path.
The producer admits only the resulting pure import archives and unions every
export with the Rust inventories. Private bootstrap CRT outputs are discarded.
The final 22,925 symbols include correctly typed DATA imports. Named import hints
are an optional loader lookup optimization; generated archives use zero hints
and retain the exact export names and DLL identities.

`inventory.json` is the reviewed complete source inventory, not a scan of current
host usage. Every build must match it exactly, then regenerate and structurally
validate each complete DLL archive. Updates must review full upstream per-DLL
coverage, aliases, architecture conditions and module feature closure together.
A newly required DLL may require a new independent release. These inventories do
not claim to enumerate undocumented Windows exports or establish a minimum
supported Windows version.

The source payload retains original pinned Cargo archives and MinGW definition
inputs, their original notices, Zig/LLVM license texts, the exact inventory,
recipe, probes and reproduction scripts. Compiler and crate download identities
are also recorded in the manifest. There are no Windows DLLs, Microsoft SDK
libraries, CRT implementations, platform hosts or application resources in the
package.

The workflow requires two fresh toolchain installations and builds to produce
identical bytes. Its Windows job validates every extracted archive and executes
ICUUC `u_strlen`, NTDLL time, OLE32 allocation/initialization and KERNEL32 calls.
The executable directory is freshly created and the process PATH contains only
Windows directories; the probe additionally verifies that loaded `icuuc.dll`
resides under the system directory. Native failure is a release blocker, not a
reason to assume `icu.dll` is an equivalent provider. Main-only publication
attests and publishes the tested bytes using the shared immutable-release helper.

Consumers still need a separately tested GNU host/engine ABI, complete CRT inputs
and an explicit library provider order. Multiple complete DLL archives can export
the same COFF symbol; ordering can change the selected DLL. The private application
proof needed OLE32 before COMBASE to preserve existing providers. This producer
does not set or silently infer that host linkage policy. Native GUI tests and
consumer-lock adoption are separate changes.
