"""Native candidate proof from identified CI artifacts, without release admission."""
import argparse
from functools import partial
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import threading

import gui_smoke
import gui_suite
import spec_driver
import toolchain
from windows_gnu_coff import identity, normalize

ROOT = Path(__file__).resolve().parents[1]
REPO = 'lukewilliamboswell/roc-signals'
HOST = (34349654208, '457188029f74c44ef3a3a6cdff340bdf7f3a096c', 'windows-gnu-build')
IMPORTS = (34339580699, 'a1867b046fa2d4e83b6e2f2d2c512b93b3890652', 'windows-system-imports-candidate')
IMPORT_SHA = '6038a2993557f50c84ce818b72a7abe9cd70260d05668003cc21ea6da8caccd0'


def download(run, source, name, output):
    record = json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/actions/runs/{run}']))
    if record['head_sha'] != source or record['status'] != 'completed' or record['conclusion'] != 'success':
        raise ValueError('candidate run is not successful at the expected source')
    artifacts = json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/actions/runs/{run}/artifacts']))['artifacts']
    selected = [a for a in artifacts if a['name'] == name and not a['expired']]
    if len(selected) != 1:
        raise ValueError('expected one unexpired candidate artifact')
    subprocess.run(['gh', 'run', 'download', str(run), '--repo', REPO, '--name', name, '--dir', str(output)], check=True)
    return {'run': run, 'source': source, 'artifact': selected[0]['id'], 'name': name}


def stage_package(archive, expected, stage):
    if identity(archive.read_bytes())['sha256'] != expected:
        raise ValueError('candidate package hash differs from reviewed input')
    with tarfile.open(archive) as source:
        manifest = json.load(source.extractfile('dependency.json'))
        for name, record in manifest['files'].items():
            relative = Path(name)
            if relative.is_absolute() or '..' in relative.parts or '\\' in name:
                raise ValueError('unsafe candidate package path')
            member = source.getmember(name)
            if not member.isfile():
                raise ValueError('candidate package contains nonregular input')
            data = source.extractfile(member).read()
            if identity(data) != {key: record[key] for key in ('sha256', 'size')}:
                raise ValueError('candidate manifest payload mismatch')
            if name.startswith(('targets/', 'licenses/')):
                destination = stage / name
                if destination.exists():
                    raise ValueError('candidate dependency inputs overlap')
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
        inventory_name = 'sources/windows-system-imports/dependencies/windows-system-imports/inventory.json'
        inventory = json.load(source.extractfile(inventory_name)) if manifest['name'] == 'windows-system-imports' else None
    return manifest, inventory


def check_apps(stage, output, roc, url=None):
    apps_root = output / ('http-apps' if url else 'local-apps')
    apps_root.mkdir()
    shutil.copytree(ROOT / 'examples-gui', apps_root / 'examples-gui')
    shutil.copytree(ROOT / 'vendor', apps_root / 'vendor')
    env = dict(os.environ, ROC_CACHE_DIR=str(apps_root / 'cache'), XDG_CACHE_HOME=str(apps_root / 'cache'))
    # GNU final linking must not discover installed SDK/MSVC library directories.
    for key in ('LIB', 'LIBPATH', 'INCLUDE', 'WindowsSdkDir', 'WindowsSDKVersion', 'VCINSTALLDIR', 'VCToolsInstallDir'):
        env.pop(key, None)
    results = {}
    for app in gui_suite.examples(apps_root):
        source = app / 'main.roc'
        source.write_text(toolchain.replace_platform(source.read_text(), url or (stage / 'main.roc').as_posix()))
        executable = apps_root / (app.name + '.exe')
        subprocess.run([roc, 'build', '--no-cache', '--target=x64mingw', str(source), f'--output={executable}'],
                       cwd=apps_root, env=env, check=True, timeout=180)
        specs = spec_driver.run_suite(executable, app / 'specs', jobs=1)
        spec_driver.print_summary(specs)
        if not specs or any(not result.passed for result in specs):
            raise ValueError('native candidate spec failure: ' + app.name)
        arguments = ('--smoke-click', 'Increment', '--smoke-expect', 'Count: 1') if app.name == 'counter' else ()
        gui_smoke.check(executable, arguments, env)
        results[app.name] = {'executable': identity(executable.read_bytes()), 'specs': len(specs), 'render': True}
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-run', type=int, required=True)
    parser.add_argument('--runtime-source', required=True)
    parser.add_argument('--runtime-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--roc', default='roc')
    args = parser.parse_args()
    if sys.platform != 'win32':
        raise ValueError('native Windows execution required')
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=ROOT):
        raise ValueError('candidate proof requires clean committed source')
    source_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    identities = {'host': download(*HOST, output / 'host'), 'imports': download(*IMPORTS, output / 'imports'),
                  'runtime': download(args.runtime_run, args.runtime_source, 'windows-gnu-runtime-candidate', output / 'runtime')}
    host_source = output / 'host-source'
    subprocess.run(['git', 'fetch', '--depth=1', 'origin', HOST[1]], cwd=ROOT, check=True)
    subprocess.run(['git', 'worktree', 'add', '--detach', str(host_source), HOST[1]], cwd=ROOT, check=True)
    from host_build_identity import HOST_FILES, source_fingerprint, validate_outputs
    fingerprint = source_fingerprint(host_source)
    evidence = json.loads((output / 'host/evidence.json').read_text())
    build = json.loads((output / 'host/build.json').read_text())
    raw_outputs = {name: (output / 'host/payload' / name).read_bytes() for name in HOST_FILES['x64mingw']}
    validate_outputs(build, 'x64mingw', fingerprint, evidence['host'], raw_outputs)
    stage = output / 'platform-gui'
    from bundle_platforms import prepare_platform
    subprocess.run([sys.executable, ROOT / 'scripts/prepare_platforms.py'], check=True)
    prepare_platform(ROOT / 'platform-gui', stage)
    shutil.copyfile(ROOT / 'LICENSE', stage / 'LICENSE')
    shutil.copyfile(ROOT / 'crates/gpui-host/LICENSE-GPUI', stage / 'LICENSE-GPUI')
    imports_archive = output / 'imports/windows-system-imports-x64mingw.tar'
    imports_manifest, inventory = stage_package(imports_archive, IMPORT_SHA, stage)
    runtime_archive = output / 'runtime/windows-gnu-runtime-x64mingw.tar'
    runtime_manifest, _ = stage_package(runtime_archive, args.runtime_sha256, stage)
    if imports_manifest['target'] != 'x64mingw' or runtime_manifest['target'] != 'x64mingw':
        raise ValueError('wrong candidate dependency target')
    destination = stage / 'targets/x64mingw'
    raw = output / 'host/payload/libsignals_gpui_host.a'
    engine = output / 'host/payload/libengine.a'
    resource = output / 'host/payload/signals.res'
    host_receipt = json.loads((output / 'host/candidate.json').read_text())
    if host_receipt['source_commit'] != HOST[1] or host_receipt['rust_target'] != 'x86_64-pc-windows-gnullvm':
        raise ValueError('host candidate source/target mismatch')
    for path in (raw, engine, resource):
        if identity(path.read_bytes()) != host_receipt['outputs'][path.name]:
            raise ValueError('raw host candidate output mismatch')
    zig = shutil.which('zig')
    if subprocess.check_output([zig, 'version'], text=True).strip() != '0.16.0':
        raise ValueError('candidate requires Zig0.16.0')
    normalization = normalize(raw, destination / raw.name, inventory, zig)
    (destination / 'normalization.json').write_text(json.dumps(normalization, indent=2) + '\n')
    shutil.copyfile(destination / 'normalization.json', stage / 'normalization.json')
    shutil.copyfile(engine, destination / engine.name)
    shutil.copyfile(resource, destination / resource.name)
    from prepare_gui_host_release import compose_notices
    notice_output = compose_notices('x64mingw', destination, output / 'host',
                                    output / 'host-notices', output / 'notice-cache', root=host_source)
    (destination / 'normalization.json').unlink()
    notice_destination = stage / 'licenses/gui-host'
    notice_destination.mkdir(parents=True, exist_ok=True)
    for notice in (notice_output / 'notices').iterdir():
        shutil.copyfile(notice, notice_destination / notice.name)
    providers = sorted(n.removeprefix('targets/x64mingw/') for n in imports_manifest['files'] if n.startswith('targets/x64mingw/'))
    if len(providers) != 340:
        raise ValueError('complete provider inventory changed; review required')
    providers.remove('ole32.lib')
    providers.insert(0, 'ole32.lib')
    runtimes = sorted(n.removeprefix('targets/x64mingw/') for n in runtime_manifest['files'] if n.startswith('targets/x64mingw/'))
    if len(runtimes) != 21:
        raise ValueError('runtime inventory changed; review required')
    runtimes.remove('crt2.obj')
    inputs = ['crt2.obj', raw.name, engine.name, 'signals.res', 'APP', *runtimes, *providers]
    header = stage / 'main.roc'
    contents = header.read_text()
    line = next(line for line in contents.splitlines() if 'x64win: { inputs:' in line or 'x64mingw: { inputs:' in line)
    header.write_text(contents.replace(line, '        x64mingw: { inputs: [' + ', '.join('app' if n == 'APP' else json.dumps(n) for n in inputs) + '] },'))
    (stage / 'CANDIDATE.json').write_text(json.dumps({
        'candidate_only': True, 'complete_host_notices': True,
        'consumer_source': source_commit, 'inputs': identities,
        'runtime_sha256': args.runtime_sha256, 'imports_sha256': IMPORT_SHA,
        'note': 'Native test candidate; no release attestations or production dependency lock.'
    }, indent=2) + '\n')
    toolchain.verify_compiler(args.roc, toolchain.read_pin(header))
    proof = {'candidate_only': True, 'consumer_source': source_commit, 'inputs': identities,
             'runtime_archive_sha256': args.runtime_sha256, 'imports_archive_sha256': IMPORT_SHA,
             'host_source': HOST[1], 'link_order': inputs, 'native': check_apps(stage, output, args.roc)}
    # Full original notices are bundled; paired sources remain a separate artifact.
    proof['complete_host_notices'] = True
    proof['host_source_companion'] = identity((notice_output / 'gui-host-sources-x64mingw.tar').read_bytes())
    files = sorted(p.relative_to(stage).as_posix() for p in stage.rglob('*') if p.is_file())
    proof['candidate_expanded_bytes'] = sum((stage / n).stat().st_size for n in files)
    if proof['candidate_expanded_bytes'] >= 100 * 1024 * 1024:
        raise ValueError('candidate alone exceeds pinned Roc bundle limit')
    bundle = output / 'bundle'
    bundle.mkdir()
    subprocess.run([args.roc, 'bundle', *files, '--output-dir', str(bundle)], cwd=stage, check=True)
    archives = list(bundle.glob('*.tar.zst'))
    if len(archives) != 1:
        raise ValueError('expected one candidate bundle')
    handler = partial(http.server.SimpleHTTPRequestHandler, directory=str(bundle))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        proof['http'] = check_apps(stage, output, args.roc, f'http://127.0.0.1:{server.server_port}/{archives[0].name}')
    finally:
        server.shutdown()
        thread.join()
        server.server_close()
    proof['bundle'] = identity(archives[0].read_bytes())
    proof['targets'] = {p.name: identity(p.read_bytes()) for p in destination.iterdir() if p.is_file()}
    (output / 'proof.json').write_text(json.dumps(proof, indent=2) + '\n')


if __name__ == '__main__':
    main()
