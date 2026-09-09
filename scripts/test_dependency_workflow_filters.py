"""Check producer triggers against executable scripts and their local imports."""

import ast
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = {
    "musl": "dependencies.yml",
    "windows": "windows-dependencies.yml",
    "windows-system": "windows-system-imports.yml",
    "freetype": "freetype-dependencies.yml",
    "xkbcommon": "xkbcommon-dependencies.yml",
    "glibc": "glibc-dependencies.yml",
    "unwind": "unwind-dependencies.yml",
}


def workflow(name):
    path = ROOT / ".github/workflows" / WORKFLOWS[name]
    text = path.read_text()
    # These workflows deliberately use a plain literal list. Refuse unsupported
    # glob/negation syntax rather than approximating GitHub's matching semantics.
    section = text.split("    paths:\n", 1)[1].split("  workflow_dispatch:", 1)[0]
    paths = [line.removeprefix("      - ") for line in section.splitlines() if line.strip()]
    if any(not line.startswith("      - ") for line in section.splitlines() if line.strip()):
        raise ValueError("expected a literal producer path list")
    if any(re.search(r"[*?!\[\]{}]", path) for path in paths):
        raise ValueError("producer filters must name exact inputs")
    return path.relative_to(ROOT).as_posix(), set(paths), text.split("\njobs:\n", 1)[1]


def script_inputs(jobs):
    """Follow repository Python imports, including tests and publisher imports."""
    pending = list(set(re.findall(r"scripts/[A-Za-z0-9_]+\.py", jobs)))
    seen = set()
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        tree = ast.parse((ROOT / name).read_text())
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                modules = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom) and node.module:
                modules = [node.module]
            else:
                modules = []
            for module in modules:
                path = "scripts/" + module.replace(".", "/") + ".py"
                if (ROOT / path).is_file():
                    pending.append(path)
    return seen


class DependencyWorkflowFilterTests(unittest.TestCase):
    def test_all_executed_scripts_and_transitive_imports_trigger_their_workflow(self):
        for name in WORKFLOWS:
            with self.subTest(producer=name):
                own_path, paths, jobs = workflow(name)
                self.assertIn(own_path, paths)
                self.assertEqual(script_inputs(jobs) - paths, set())

    def test_recipe_toolchain_and_probe_changes_select_only_their_producer(self):
        inputs = {
            "windows-system": {"dependencies/windows-system-imports.json", "test/dependencies/windows_system_imports.c"},
            "musl": {"dependencies/musl.json", "test/dependencies/musl.c"},
            "windows": {"dependencies/windows-imports.json", "test/dependencies/windows_imports.c"},
            "freetype": {"dependencies/freetype.json", "dependencies/linux/Dockerfile",
                         "dependencies/linux/zig-toolchain.cmake", "test/dependencies/freetype.c"},
            "xkbcommon": {"dependencies/xkbcommon.json", "dependencies/xkbcommon/Dockerfile",
                          "dependencies/xkbcommon/cc.sh", "dependencies/xkbcommon/zig.ini",
                          "test/dependencies/xkbcommon.c"},
            "unwind": {"dependencies/unwind.json", "dependencies/unwind/Dockerfile",
                       "test/dependencies/unwind.cpp", "test/dependencies/unwind.rs",
                       "test/dependencies/unwind-rust.c"},
            "glibc": {"dependencies/glibc.json", "dependencies/glibc/Dockerfile",
                      "dependencies/glibc/COPYING.LIB", "test/dependencies/glibc.c"},
        }
        for owner, files in inputs.items():
            for filename in files:
                with self.subTest(input=filename):
                    self.assertTrue((ROOT / filename).is_file())
                    selected = {name for name in WORKFLOWS if filename in workflow(name)[1]}
                    self.assertEqual(selected, {owner})

    def test_shared_admission_and_publication_changes_select_every_producer(self):
        for path in ("scripts/dependency_archive.py", "scripts/dependency_artifacts.py",
                     "scripts/release_dependencies.py", "scripts/test_dependency_artifacts.py"):
            with self.subTest(input=path):
                self.assertTrue(all(path in workflow(name)[1] for name in WORKFLOWS))

    def test_ordinary_consumer_and_documentation_changes_select_no_producer(self):
        unrelated = ("dependencies/README.md", "dependencies/glibc/README.md",
                     "dependencies/xkbcommon/README.md", "dependencies.lock.json",
                     "src/signals/engine.zig", "crates/gpui-host/src/lib.rs",
                     "platform-gui/main.roc", "platform-shared/Signal.roc",
                     "examples-gui/counter/main.roc", "scripts/prepare_dependencies.py",
                     "scripts/release_gui_hosts.py", "scripts/gui_host_artifacts.py",
                     "scripts/cargo_build_evidence.py", "scripts/host_notice_payload.py")
        for path in unrelated:
            with self.subTest(input=path):
                self.assertFalse(any(path in workflow(name)[1] for name in WORKFLOWS))


if __name__ == "__main__":
    unittest.main()
