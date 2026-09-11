import sys, os, pathlib, time
sys.path.insert(0, os.path.dirname(__file__))
from winshot import *
ROOT = pathlib.Path(__file__).resolve().parents[4]  # repository root
S = pathlib.Path(__file__).parent
OUT = S / "shots"; OUT.mkdir(exist_ok=True)
FIX = S / "fixtures"
def start(app, extra=()):
    s = Session(ROOT / ".test-out/gui" / f"{app}.exe", list(extra), cwd=str(ROOT))
    s.resize(1200, 820)
    return s
def dialog(s, name, timeout=8):
    d = wait_window(s.process.pid, exclude=s.hwnd, timeout=timeout)
    print(name, "dialog:", d, flush=True)
    if d: shot_hwnd(d[0], OUT / f"{name}.png")
    return d
def finish(s, label):
    code, out, err = s.close()
    print(label, "exit", code, "| stderr:", err[-800:].strip(), flush=True)
