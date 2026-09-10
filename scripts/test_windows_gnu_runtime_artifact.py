#!/usr/bin/env python3
"""Link a candidate CRT/unwinder and execute native startup, TLS and failure tests."""

import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import shutil

from dependency_artifacts import unpack_verified
from windows_runtime_validation import ucrt_inventory

ROOT = Path(__file__).resolve().parents[1]
ROC_PROBE_OPT = '--opt=dev'


def check(candidate, require_native=False, zig='zig', evidence=None, roc='roc'):
    if require_native and platform.system() != 'Windows':
        raise ValueError('native Windows runtime test required')
    recipe = json.loads((ROOT / 'dependencies/windows-gnu-runtime.json').read_text())
    if subprocess.check_output([zig, 'version'], text=True).strip() != recipe['zig_version']:
        raise ValueError('unexpected Zig probe version')
    if not subprocess.check_output(['rustc', '+1.95.0', '--version'], text=True).startswith('rustc 1.95.0 '):
        raise ValueError('Rust probe requires version 1.95.0')
    if recipe['probe_roc_version'].rsplit('-', 1)[-1] not in subprocess.check_output([roc, 'version'], text=True):
        raise ValueError('unexpected Roc probe compiler')
    with tempfile.TemporaryDirectory(prefix='signals-windows-runtime-probe-') as temporary:
        work = Path(temporary)
        if any(c.isspace() for c in str(work)):
            raise ValueError('probe TMPDIR must have no whitespace for Zig verbose-link diagnostics')
        stage = work / 'candidate'
        manifest = unpack_verified(candidate, {'name': recipe['name'], 'target': recipe['target']}, stage)
        target = stage / 'targets/x64mingw'
        if {p.name for p in target.iterdir()} != set(recipe['files']):
            raise ValueError('incomplete runtime candidate')
        expected = json.loads((ROOT / 'dependencies/windows-gnu-runtime/ucrt-inventory.json').read_text())
        for name, inventory in expected.items():
            if ucrt_inventory((target / name).read_bytes()) != inventory:
                raise ValueError('candidate UCRT imports or aliases differ')
        environment = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(work / 'global'), ZIG_LOCAL_CACHE_DIR=str(work / 'local'))
        for name in ('ZIG_LIB_DIR', 'ZIG_LIBC', 'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH', 'LD_LIBRARY_PATH', 'LD_PRELOAD'):
            environment.pop(name, None)
        compiler = [zig, 'c++', *recipe['cc_args']]
        seed = work / 'seed.cpp'
        seed.write_text('int main() { try { throw 42; } catch (int n) { return n == 42 ? 0 : 1; } }\n')
        subprocess.run([*compiler, str(seed), '-lws2_32', '-luserenv', '-o', str(work / 'seed.exe')], env=environment, check=True, timeout=600)
        rust = work / 'rust-probe.lib'
        subprocess.run(['rustc', '+1.95.0', '--target=x86_64-pc-windows-gnullvm', '--crate-type=staticlib',
                        '--edition=2024', '-C', 'panic=unwind', '-C', 'opt-level=2',
                        str(ROOT / 'test/dependencies/windows_gnu_runtime.rs'), '-o', str(rust)],
                       env=environment, check=True, timeout=180)
        main = work / 'main.obj'
        overflow = work / 'overflow.obj'
        subprocess.run([*compiler, '-c', str(ROOT / 'test/dependencies/windows_gnu_runtime.cpp'), '-o', str(main)], env=environment, check=True)
        subprocess.run([zig, 'cc', *recipe['cc_args'], '-fsanitize=signed-integer-overflow', '-fno-sanitize-recover=all',
                        '-c', str(ROOT / 'test/dependencies/windows_gnu_ubsan.c'), '-o', str(overflow)], env=environment, check=True)
        support = []
        for name in ('c++.lib', 'c++abi.lib', 'advapi32.lib', 'kernel32.lib', 'ntdll.lib', 'shell32.lib', 'user32.lib', 'userenv.lib', 'ws2_32.lib'):
            matches = list((work / 'global/o').glob('*/' + name))
            if len(matches) != 1:
                raise ValueError('ambiguous private full-source probe support: ' + name)
            support.append(str(matches[0]))
        def link(name, objects, expected_providers, omissions):
            executable = work / (name + '.exe')
            command = [zig, 'cc', *recipe['cc_args'], '-v', '-nostdlib', str(target / 'crt2.obj'),
                            *(str(p) for p in objects),
                            *(str(target / n) for n in recipe['files'] if n != 'crt2.obj'), *support,
                            '-Wl,--entry,mainCRTStartup', '-o', str(executable)]
            linked = subprocess.run(command, env=environment, check=True, capture_output=True, text=True, timeout=120)
            for library, required_symbol in omissions.items():
                omitted = [argument for argument in command if argument != str(target / library)]
                omitted[-1] = str(work / (name + '-must-fail.exe'))
                failure = subprocess.run(omitted, env=environment, capture_output=True, text=True, timeout=120)
                diagnostic = failure.stdout + failure.stderr
                if failure.returncode == 0 or 'undefined symbol' not in diagnostic or required_symbol not in diagnostic:
                    raise ValueError('omitting candidate did not expose its required symbol: ' + library)
                if evidence is not None:
                    evidence.mkdir(parents=True, exist_ok=True)
                    (evidence / (name + '-without-' + library + '.txt')).write_text(diagnostic)
            # Zig does not expose COFF /map. Replay its exact link with pinned
            # Rust LLD for diagnostics, preserving the Zig-linked native probe.
            commands = [line.split() for line in linked.stderr.splitlines() if line.startswith('lld-link ')]
            if len(commands) != 1:
                raise ValueError('expected one explicit final COFF linker invocation')
            sysroot = Path(subprocess.check_output(['rustc', '+1.95.0', '--print', 'sysroot'], text=True).strip())
            rust_host = subprocess.check_output(['rustc', '+1.95.0', '-vV'], text=True).split('host: ', 1)[1].splitlines()[0]
            linker = sysroot / 'lib/rustlib' / rust_host / 'bin' / ('rust-lld.exe' if os.name == 'nt' else 'rust-lld')
            arguments = [a for a in commands[0][1:] if not a.lower().startswith('-out:') and not a.lower().startswith('/out:')]
            mapping = work / (name + '.map')
            subprocess.run([str(linker), '-flavor', 'link', *arguments, '/out:' + str(work / (name + '-mapped.exe')),
                            '/map:' + str(mapping)], env=environment, check=True, timeout=120)
            lines = [line.split() for line in mapping.read_text().splitlines()]
            for symbol, provider in expected_providers.items():
                matches = [parts for parts in lines if len(parts) >= 4 and parts[1] == symbol]
                if len(matches) != 1 or not matches[0][-1].startswith(provider):
                    raise ValueError('unexpected runtime provider for ' + symbol + ': ' + repr(matches))
            if evidence is not None:
                evidence.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(mapping, evidence / mapping.name)
            return executable

        executable = link('probe', [main, overflow, rust], {
            'mainCRTStartup': 'crt2.obj', '__dyn_tls_init': 'libmingw32:',
            '_Unwind_RaiseException': 'unwind:', '_Unwind_Resume': 'unwind:',
            '__ubsan_handle_add_overflow_abort': 'ubsan_rt:',
        }, {'unwind.lib': '_Unwind_', 'ubsan_rt.lib': '__ubsan_handle_add_overflow_abort'})
        arithmetic = work / 'arithmetic.obj'
        subprocess.run([zig, 'cc', *recipe['cc_args'], '-c',
                        str(ROOT / 'test/dependencies/windows_gnu_compiler_rt.c'), '-o', str(arithmetic)],
                       env=environment, check=True)
        arithmetic_executable = link('arithmetic', [arithmetic], {'__divti3': 'compiler_rt:'}, {'compiler_rt.lib': '__divti3'})
        # Exercise the actual Roc/lld path too: its linker settings previously
        # exposed stale .llvm_addrsig indices that the Zig driver accepted.
        roc_inputs = [target / 'crt2.obj', main, overflow, rust]
        roc_inputs += [target / n for n in recipe['files'] if n != 'crt2.obj']
        roc_inputs += [Path(p) for p in support]
        roc_target = work / 'roc-targets/x64mingw'
        roc_target.mkdir(parents=True)
        for path in roc_inputs:
            shutil.copyfile(path, roc_target / path.name)
        entries = ', '.join(json.dumps(path.name) for path in roc_inputs)
        platform_source = ('platform ""\n    requires { main : U64 }\n    exposes []\n'
                           '    packages { roc: "' + recipe['probe_roc_version'] + '" }\n'
                           '    provides { "roc_runtime_probe": main_for_host }\n'
                           '    targets: { inputs_dir: "roc-targets/", x64mingw: { inputs: [' + entries + ', app] } }\n'
                           'main_for_host : U64\nmain_for_host = main\n')
        (work / 'runtime-platform.roc').write_text(platform_source)
        app = work / 'runtime-app.roc'
        app.write_text('app [main] { pf: platform "runtime-platform.roc" }\nmain : U64\nmain = 42\n')
        roc_executable = work / 'roc-probe.exe'
        roc_link = subprocess.run([roc, 'build', str(app), '--target=x64mingw', ROC_PROBE_OPT,
                                   '--output=' + str(roc_executable)],
                                  cwd=work, env=environment, capture_output=True, text=True, timeout=180)
        if evidence is not None:
            (evidence / 'roc-link.txt').write_text(roc_link.stdout + roc_link.stderr)
        if roc_link.returncode:
            raise ValueError('actual Roc final link failed: ' + roc_link.stdout + roc_link.stderr)
        if platform.system() == 'Windows':
            system = Path(os.environ['SystemRoot'])
            environment['PATH'] = str(system / 'System32') + os.pathsep + str(system)
            subprocess.run([str(arithmetic_executable)], cwd=work, env=environment, check=True, timeout=30)
            roc_result = subprocess.run([str(roc_executable)], cwd=work, env=environment, check=True, capture_output=True, text=True, timeout=30)
            result = subprocess.run([str(executable)], cwd=work, env=environment, check=True, capture_output=True, text=True, timeout=30)
            if result.stdout.splitlines() != ['PASS: Windows GNU runtime startup threads C++ and Rust unwinding', 'PASS: Windows GNU runtime teardown']:
                raise ValueError('candidate did not prove startup, unwinding and teardown')
            if roc_result.stdout != result.stdout:
                raise ValueError('Roc-linked runtime execution differs from Zig-linked probe')
            failure = subprocess.run([str(executable), 'overflow'], cwd=work, env=environment, capture_output=True, text=True, timeout=30)
            if failure.returncode == 0 or 'integer overflow' not in failure.stderr:
                raise ValueError('candidate did not reject instrumented signed overflow')
            print(result.stdout, end='')
            print('PASS: UBSan rejected signed integer overflow')
        else:
            print('Windows runtime and instrumented failure probes cross-linked; native execution remains required.')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--require-native', action='store_true')
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--roc', default='roc')
    args = parser.parse_args()
    check(args.candidate.resolve(), args.require_native, args.zig, args.evidence, args.roc)
