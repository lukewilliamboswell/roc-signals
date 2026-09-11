"""Final-link released macOS interfaces with selected hosts and HTTP bundles."""

import argparse
from functools import partial
import hashlib
import http.server
import json
import importlib.util
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def check_apps(platform_path, roc, *, root=ROOT, url=None):
    """Link examples and internal GUI fixtures with fresh compiler caches."""
    # Import lazily: the GUI builder also imports the interface generator.
    import gui_suite
    import spec_driver
    import toolchain
    if root.resolve() != ROOT:
        # The spec CLI is part of the released host contract too. Load its
        # matching driver rather than guessing flags for an older host.
        spec = importlib.util.spec_from_file_location(
            '_macos_release_spec_driver', root / 'scripts/spec_driver.py')
        spec_driver = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = spec_driver
        spec.loader.exec_module(spec_driver)
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise ValueError('macOS interface compatibility requires native Apple Silicon validation')
    pin = toolchain.read_pin(root / 'platform-gui/main.roc')
    toolchain.verify_compiler(roc, pin)
    results_by_app = {}
    with tempfile.TemporaryDirectory(prefix='signals-macos-link-') as temporary:
        stage = Path(temporary)
        shutil.copytree(root / 'examples-gui', stage / 'examples-gui')
        shutil.copytree(root / 'test/gui', stage / 'test/gui')
        shutil.copytree(root / 'vendor', stage / 'vendor')
        environment = dict(os.environ, ROC_CACHE_DIR=str(stage / 'cache'), XDG_CACHE_HOME=str(stage / 'cache'))
        examples = gui_suite.examples(stage)
        fixtures = gui_suite.fixtures(stage)
        if not examples or not fixtures:
            raise ValueError('macOS validation requires maintained examples and GUI fixtures')
        for app in examples + fixtures:
            source = app / 'main.roc'
            # Internal fixtures inherit the platform's pin; published examples
            # also declare their own pin, which must agree with the platform.
            if app in examples and toolchain.read_pin(source) != pin:
                raise ValueError('example compiler differs from platform compiler')
            source.write_text(toolchain.replace_platform(source.read_text(), url or str(platform_path / 'main.roc')))
            name = app.name if app in examples else 'fixture-' + app.name
            executable = stage / name
            subprocess.run([roc, 'build', '--no-cache', '--target=arm64mac', '--opt=dev',
                            f'--output={executable}', str(source)], cwd=stage, env=environment, check=True, timeout=180)
            results = spec_driver.run_suite(executable, app / 'specs', jobs=1)
            spec_driver.print_summary(results)
            if not results or any(not result.passed for result in results):
                raise ValueError('macOS interface semantic validation failed: ' + app.name)
            results_by_app[name] = len(results)
    return {'compiler_pin': pin, 'examples': results_by_app}


def validate_platform(stage, roc, *, root=ROOT):
    """Final-link and execute apps without rewriting the released interface tree."""
    before = {path.relative_to(stage).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in (stage / 'targets/macos-sysroot').rglob('*') if path.is_file()}
    result = check_apps(stage, roc, root=root)
    after = {path.relative_to(stage).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in (stage / 'targets/macos-sysroot').rglob('*') if path.is_file()}
    if after != before:
        raise ValueError('macOS interface inputs changed during final-link validation')
    return result


def check_bundle(directory, roc):
    """Exercise the emitted archive through HTTP, never the local platform tree."""
    name = json.loads((directory / 'bundles.json').read_text())['gui']
    if Path(name).name != name or not (directory / name).is_file():
        raise ValueError('expected one GUI bundle filename')
    handler = partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        return check_apps(None, roc, url=f'http://127.0.0.1:{server.server_port}/{name}')
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--roc', default=os.environ.get('ROC_BIN', 'roc'))
    args = parser.parse_args()
    print(json.dumps(check_bundle(args.bundle.resolve(), args.roc), indent=2))
