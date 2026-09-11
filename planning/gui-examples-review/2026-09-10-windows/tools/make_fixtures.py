"""Create the small Windows fixture files the scenario scripts open (CRLF text, a BOM file, a log, a folder tree)."""
from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent / "fixtures")
(root / "Project" / "src").mkdir(parents=True, exist_ok=True)
(root / "Project" / "docs").mkdir(parents=True, exist_ok=True)
(root / "Ideas.txt").write_bytes(b"First idea\r\nSecond idea with CRLF endings\r\n")
(root / "bom.txt").write_bytes(b"\xef\xbb\xbfBOM line one\r\nBOM line two\r\n")
(root / "Project" / "README.txt").write_bytes(b"line one\r\nline two\r\n")
(root / "Project" / "src" / "main.rs").write_bytes(b"fn main() {}\r\n")
(root / "app.log").write_bytes(
    b"2026-09-10T10:00:00Z INFO service started\r\n"
    b"2026-09-10T10:00:01Z WARN cache cold\r\n"
    b"2026-09-10T10:00:02Z ERROR upstream timeout\r\n")
print(root)
