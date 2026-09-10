import sys, os, pathlib
sys.path.insert(0, os.path.dirname(__file__))
from winshot import Session
ROOT = pathlib.Path(__file__).resolve().parents[4]  # repository root
OUT = pathlib.Path(__file__).parent / "shots"
OUT.mkdir(exist_ok=True)
apps = {
    "counter": [], "keyed-rows": [], "notes-editor": [], "activity-monitor": [],
    "task-board": ["--host-assets-root", str(ROOT / "examples-gui/task-board/assets")],
    "folder-explorer": ["--host-assets-root", str(ROOT / "examples-gui/folder-explorer/assets")],
}
sizes = [(1200, 820), (800, 600), (360, 600)]
for app, args in apps.items():
    s = Session(ROOT / ".test-out/gui" / f"{app}.exe", args, cwd=str(ROOT))
    try:
        for w, h in sizes:
            s.resize(w, h)
            print(app, (w, h), "rect", s.window_rect(), "client", s.client_origin(), flush=True)
            s.shot(OUT / f"{app}-{w}x{h}.png")
    finally:
        code, out, err = s.close()
        print(app, "exit", code, err[-300:].strip(), flush=True)
