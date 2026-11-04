# Third-Party Licenses

This project bundles third-party platform link inputs and release tooling.

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
