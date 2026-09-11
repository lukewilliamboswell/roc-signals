"""Apply mandatory shadow-stack checks to a freshly linked browser module."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def instrument_wasm(path: Path) -> None:
    """Replace a linked module only after instrumentation and validation succeed.

    Debug sections are removed because Binaryen 116 cannot rewrite the DWARF
    emitted by the pinned Zig toolchain. The input remains intact on failure.
    Call this once after the final Roc link, before hashing or packaging.
    """
    path = path.resolve(strict=True)
    subprocess.run([
        "node", "--input-type=module", "-e",
        'import {readFile} from "node:fs/promises"; '
        'const module = await WebAssembly.compile(await readFile(process.argv[1])); '
        'if (WebAssembly.Module.exports(module).some(x => x.name === "__set_stack_limits")) '
        'throw new Error("module already has stack instrumentation; rebuild before instrumenting");',
        str(path),
    ], check=True)
    with tempfile.TemporaryDirectory(prefix="signals-stack-", dir=path.parent) as scratch:
        output = Path(scratch) / "checked.wasm"
        subprocess.run([
            "wasm-opt", str(path), "--strip-debug", "--enable-bulk-memory",
            "--enable-mutable-globals", "--enable-sign-ext", "--enable-simd",
            "--stack-check", "-o", str(output),
        ], check=True)
        subprocess.run([
            "node", "--input-type=module", "-e",
            'import {readFile} from "node:fs/promises"; '
            'const module = await WebAssembly.compile(await readFile(process.argv[1])); '
            'const exports = WebAssembly.Module.exports(module); '
            'if (!exports.some(x => x.name === "__set_stack_limits" && x.kind === "function")) '
            'throw new Error("stack instrumentation did not produce its required export");',
            str(output),
        ], check=True)
        output.replace(path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wasm", type=Path)
    instrument_wasm(parser.parse_args().wasm)
