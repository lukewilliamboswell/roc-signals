"""Record fresh GPUI Metal compilation without redistributing Apple tool or SDK files."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def file_record(path):
    path = Path(path).resolve(strict=True)
    with path.open('rb') as source:
        return {'path': str(path), 'sha256': hashlib.file_digest(source, 'sha256').hexdigest(),
                'size': path.stat().st_size}


def output(command, environment=None):
    return subprocess.check_output(command, env=environment, text=True, stderr=subprocess.STDOUT).strip()


def component_identity(tool):
    """Retain identity fields and a hash, not the toolchain's plist payload."""
    for directory in Path(tool).parents:
        if directory.suffix == '.xctoolchain':
            path = directory / 'Info.plist'
            data = plistlib.loads(path.read_bytes())
            fields = {key: data[key] for key in ('CFBundleIdentifier', 'CFBundleVersion',
                      'CFBundleShortVersionString', 'DTCompiler', 'DTPlatformBuild') if key in data}
            if not fields:
                raise ValueError('Metal toolchain has no recorded identity fields')
            return dict(file_record(path), fields=fields)
    raise ValueError('Metal tool is not within an identifiable toolchain')


def invoke(arguments, environment):
    """Delegate the original xcrun command and record completed shader invocations."""
    real = environment['SIGNALS_REAL_XCRUN']
    if len(arguments) < 3 or arguments[:2] != ['-sdk', 'macosx'] or arguments[2] not in ('metal', 'metallib'):
        return subprocess.run([real, *arguments], env=environment).returncode
    name = arguments[2]
    tool = output([real, '-sdk', 'macosx', '--find', name], environment)
    before = file_record(tool)
    # --log records the command xcrun actually executes, in addition to the
    # independently resolved path. Retain the original invocation semantics.
    command = [real, '--log', *arguments]
    inputs = {}
    for flag, label in (('-c', 'shader'), ('-include', 'generated_header')):
        if flag in arguments:
            inputs[label] = file_record(arguments[arguments.index(flag) + 1])
    if name == 'metallib':
        inputs['air'] = file_record(arguments[3])
    destination = Path(arguments[arguments.index('-o') + 1]).resolve()
    if destination.exists():
        raise ValueError('fresh shader invocation must not reuse an existing output')
    version = subprocess.run([tool, '--version'], env=environment, capture_output=True, text=True, timeout=30)
    completed = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=180)
    sys.stdout.write(completed.stdout)
    sys.stderr.write(completed.stderr)
    if file_record(tool) != before:
        raise ValueError('Metal compiler changed during invocation')
    record = {'tool': name, 'resolved_tool': tool, 'tool_file': before, 'toolchain': component_identity(tool),
              'version': {'returncode': version.returncode, 'output': version.stdout + version.stderr},
              'cwd': str(Path.cwd()), 'command': command, 'inputs': inputs,
              'returncode': completed.returncode, 'xcrun_log': completed.stderr,
              'output': file_record(destination) if completed.returncode == 0 else None}
    directory = Path(environment['SIGNALS_METAL_INVOCATIONS'])
    (directory / (uuid.uuid4().hex + '.json')).write_text(json.dumps(record, indent=2) + '\n')
    return completed.returncode


def validate_invocations(records, metadata, target_directory):
    """Require one fresh shader compilation and its exact linked Metal library."""
    target_directory = target_directory.resolve()
    if len(records) != 2 or sorted(r['tool'] for r in records) != ['metal', 'metallib']:
        raise ValueError('expected fresh metal and metallib invocations')
    by_tool = {record['tool']: record for record in records}
    gpui = [p for p in metadata['packages'] if p['name'] == 'gpui']
    if len(gpui) != 1 or gpui[0]['version'] != '0.2.2':
        raise ValueError('review shader evidence for the selected GPUI version')
    source = Path(gpui[0]['manifest_path']).parent / 'src/platform/mac/shaders.metal'
    if by_tool['metal']['inputs']['shader'] != file_record(source):
        raise ValueError('recorded shader differs from selected Cargo package source')
    for record in records:
        if record['returncode'] or not record['output']:
            raise ValueError('shader evidence contains an unsuccessful invocation')
        if record['resolved_tool'] not in record['xcrun_log']:
            raise ValueError('xcrun execution log does not identify the resolved shader tool')
        if not record['version']['output'].strip():
            raise ValueError('shader tool returned no version diagnostics')
        if file_record(record['tool_file']['path']) != record['tool_file']:
            raise ValueError('shader tool identity changed after compilation')
        path = Path(record['output']['path'])
        if not path.is_relative_to(target_directory) or file_record(path) != record['output']:
            raise ValueError('shader output is outside the fresh target or changed')
    if by_tool['metal']['output'] != by_tool['metallib']['inputs']['air']:
        raise ValueError('metallib did not consume the recorded Metal output')
    header = by_tool['metal']['inputs']['generated_header']
    if not Path(header['path']).is_relative_to(target_directory) or file_record(header['path']) != header:
        raise ValueError('generated shader header is not a fresh retained build input')
    return by_tool


def capture(destination):
    """Capture a fresh native Cargo build; keep only JSON and Cargo source evidence."""
    from cargo_build_evidence import capture as capture_cargo
    from host_build_identity import source_fingerprint
    if (platform.system(), platform.machine()) != ('Darwin', 'arm64'):
        raise ValueError('Metal evidence requires native Apple Silicon')
    if destination.exists():
        raise FileExistsError(destination)
    fingerprint = source_fingerprint(ROOT)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='signals-metal-build-') as temporary:
        work = Path(temporary).resolve()
        wrappers = work / 'bin'
        wrappers.mkdir()
        invocations = work / 'invocations'
        invocations.mkdir()
        wrapper = wrappers / 'xcrun'
        wrapper.write_text('#!' + sys.executable + '\nimport runpy, sys\nsys.argv = ['
                           + repr(str(Path(__file__).resolve())) + ', "--invoke", *sys.argv[1:]]\nrunpy.run_path('
                           + repr(str(Path(__file__).resolve())) + ', run_name="__main__")\n')
        wrapper.chmod(0o755)
        real = shutil.which('xcrun')
        if not real:
            raise ValueError('xcrun is unavailable')
        target = work / 'cargo-target'
        environment = dict(os.environ, RUSTUP_TOOLCHAIN='1.95.0', CARGO_TARGET_DIR=str(target),
                           PATH=str(wrappers) + os.pathsep + os.environ['PATH'],
                           SIGNALS_REAL_XCRUN=real, SIGNALS_METAL_INVOCATIONS=str(invocations))
        environment.setdefault('TOOLCHAINS', 'Metal')
        developer = output(['xcode-select', '--print-path'], environment)
        identity = {'xcode': output(['xcodebuild', '-version'], environment),
                    'selected_developer_directory': developer,
                    'DEVELOPER_DIR': environment.get('DEVELOPER_DIR'), 'TOOLCHAINS': environment['TOOLCHAINS'],
                    'sdk_path': output([real, '-sdk', 'macosx', '--show-sdk-path'], environment),
                    'sdk_version': output([real, '-sdk', 'macosx', '--show-sdk-version'], environment),
                    'sdk_build': output([real, '-sdk', 'macosx', '--show-sdk-build-version'], environment),
                    'xcrun': file_record(real)}
        host = capture_cargo(ROOT, 'arm64mac', work / 'cargo-evidence', 2, environment, fingerprint)
        metadata = json.loads((work / 'cargo-evidence/metadata.json').read_text())
        records = [json.loads(path.read_text()) for path in invocations.glob('*.json')]
        validate_invocations(records, metadata, target)
        gpui_id = next(p['id'] for p in metadata['packages'] if p['name'] == 'gpui')
        messages = [json.loads(line) for line in (work / 'cargo-evidence/cargo.jsonl').read_text().splitlines()
                    if line.startswith('{')]
        script_outputs = [Path(m['out_dir']).resolve() for m in messages
                          if m.get('reason') == 'build-script-executed' and m['package_id'] == gpui_id]
        if len(script_outputs) != 1 or any(Path(r['output']['path']).parent != script_outputs[0] for r in records):
            raise ValueError('shader outputs do not belong to the selected GPUI build script')

        if source_fingerprint(ROOT) != fingerprint:
            raise ValueError('host source changed during Metal capture')
        inventory = {'schema_version': 1, 'target': 'arm64mac', 'source_fingerprint': fingerprint,
                     'fresh_cargo_target': True, 'host': file_record(host), 'apple_toolchain': identity,
                     'workflow': file_record(ROOT / '.github/workflows/macos-metal-evidence.yml'),
                     'invocations': sorted(records, key=lambda r: r['tool']),
                     'scope': 'Candidate evidence only; SDK/tool binaries are not included and Mac notice/publication eligibility is unchanged.'}
        with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.metal-evidence-') as pending:
            stage = Path(pending) / 'evidence'
            shutil.copytree(work / 'cargo-evidence', stage / 'cargo')
            (stage / 'metal.json').write_text(json.dumps(inventory, indent=2) + '\n')
            inventory['evidence_files_sha256'] = {p.relative_to(stage).as_posix(): file_record(p)['sha256']
                                                  for p in sorted(stage.rglob('*')) if p.is_file()}
            (stage / 'inventory.json').write_text(json.dumps(inventory, indent=2) + '\n')
            stage.rename(destination)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--invoke']:
        raise SystemExit(invoke(sys.argv[2:], dict(os.environ)))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    capture(args.output.resolve())
