# Third-Party Licenses

This project bundles third-party platform link inputs and release tooling.

## macOS linker interfaces

Files: project-generated `.tbd` metadata under `targets/macos-sysroot`.

The generator writes minimal YAML linkage descriptions from the project's
reviewed interface catalog. Its inputs are symbol records and compiled Signals
host archives. Apple API documentation and identified open-source declarations
provide the interface references; the catalog links each source. Generated
packages include the catalog and its provenance statement. See
[`dependencies/macos-interfaces/`](dependencies/macos-interfaces/README.md).
Applications load the framework implementations supplied by macOS at runtime.

## FreeType

Files: verified dependency release input `targets/x64glibc/libfreetype.so`.

This software is based in part on the work of the FreeType Team. The dependency
release selects the FreeType License and includes the upstream license texts and
acknowledgment under `licenses/freetype/`. GUI bundles retain these notices,
the dependency manifest, and the verified release lock.

## roc-automation

Files: `scripts/compiler_pins.py`

The compiler-header parser is vendored from
https://github.com/lukewilliamboswell/roc-automation and licensed under the
Universal Permissive License, Version 1.0. See
[`vendor/roc-automation-LICENSE`](vendor/roc-automation-LICENSE) for its full text.
The local copy explicitly decodes header files as UTF-8 on every operating system.

## musl libc

Files: verified dependency release inputs `targets/*/libc.a` and `targets/*/crt1.o`.

Each dependency archive includes the upstream revision, build configuration, and
complete `licenses/musl/COPYRIGHT` notices. Platform bundles retain those notices
and the dependency lock and manifests.

musl libc is licensed under the MIT License.

Source: https://musl.libc.org/

```
Copyright (C) 2005-2020 Rich Felker, et al.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## MinGW-w64 import library definitions

Files: `platform-gui/targets/x64win/*.lib` other than `host.lib`

The Windows import libraries in the GUI platform bundle come from the dependency
release selected by `dependencies.lock.json`. Its CI producer runs
`scripts/windows_imports.py` with `zig dlltool` on the module definition files
that Zig bundles from MinGW-w64 (`lib/libc/mingw/lib-common`). They contain
only symbol-to-DLL bindings for system libraries. The definitions are
distributed under the Zope Public License (ZPL) Version 2.1. Verified bundles
include the producer's complete `COPYING` notice under
`licenses/windows-imports/`.

Source: https://www.mingw-w64.org/

```
Copyright (c) 2009 - 2013 by the mingw-w64 project

This license has been certified as open source. It has also been designated
as GPL compatible by the Free Software Foundation (FSF).

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

   1. Redistributions in source code must retain the accompanying copyright
      notice, this list of conditions, and the following disclaimer.
   2. Redistributions in binary form must reproduce the accompanying
      copyright notice, this list of conditions, and the following disclaimer
      in the documentation and/or other materials provided with the
      distribution.
   3. Names of the copyright holders must not be used to endorse or promote
      products derived from this software without prior written permission
      from the copyright holders.
   4. The right to distribute this software or to use it for any purpose does
      not give you the right to use Servicemarks (sm) or Trademarks (tm) of
      the copyright holders.  Use of them is covered by separate agreement
      with the copyright holders.
   5. If any files are modified, you must cause the modified files to carry
      prominent notices stating that you changed the files and the date of
      any change.

Disclaimer

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY EXPRESSED
OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
