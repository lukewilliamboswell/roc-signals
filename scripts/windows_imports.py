"""Generate Windows import libraries from Zig's bundled MinGW definitions."""

from pathlib import Path
import re
import shutil
import subprocess
from windows_import_validation import validate_import_library


def zig_lib_dir():
    """Zig prints its environment as a Zig literal, not JSON."""
    output = subprocess.check_output(['zig', 'env'], text=True)
    match = re.search(r'\.lib_dir = "((?:[^"\\]|\\.)*)"', output)
    if not match:
        raise SystemExit('zig env did not report lib_dir')
    return Path(match.group(1).encode().decode('unicode_escape'))


def windows_import_library(name, dest):
    """Generate one import library from the MinGW-w64 definitions Zig bundles.

    A `.def.in` carries architecture macros and is expanded with Zig's C
    preprocessor the way Zig's own libc build expands it; a plain `.def` is
    used as is. The result binds symbol names to the system DLL and contains no
    code, so it is what the Windows SDK's own import library would provide.
    """
    common = zig_lib_dir() / 'libc/mingw/lib-common'
    definition = dest / (name + '.def')
    if (common / (name + '.def.in')).is_file():
        subprocess.run(['zig', 'cc', '-E', '-P', '-xc', '-D__x86_64__', '-I', str(common.parent / 'def-include'),
                        str(common / (name + '.def.in')), '-o', str(definition)], check=True)
    elif (common / (name + '.def')).is_file():
        shutil.copyfile(common / (name + '.def'), definition)
    else:
        raise SystemExit('Zig does not bundle a MinGW definition for ' + name)
    subprocess.run(['zig', 'dlltool', '-m', 'i386:x86-64', '-d', str(definition), '-l', str(dest / (name + '.lib'))], check=True)
    validate_import_library((dest / (name + '.lib')).read_bytes(), definition.read_text())
    definition.unlink()

