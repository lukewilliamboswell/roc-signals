import sys, os, pathlib, time
sys.path.insert(0, os.path.dirname(__file__))
from winshot import *
ROOT = pathlib.Path(__file__).resolve().parents[4]  # repository root
S = pathlib.Path(__file__).parent
OUT = S / "shots"; OUT.mkdir(exist_ok=True)
FIX = S / "fixtures"
s = Session(ROOT / ".test-out/gui/notes-editor.exe", [], cwd=str(ROOT))
s.resize(1200, 820)
pid = s.process.pid
try:
    # 1. Open... -> native dialog, type a Windows path
    s.click(113, 134)
    dlg = wait_window(pid, exclude=s.hwnd)
    print("open dialog:", dlg, flush=True)
    if dlg:
        shot_hwnd(dlg[0], OUT / "notes-win-open-dialog.png")
        type_text(str(FIX / "Ideas.txt")); time.sleep(0.3); keys("enter"); time.sleep(1.5)
    s.shot(OUT / "notes-win-opened-windows-path.png")
    # 2. Type, then undo
    s.click(589, 469); s.keys("ctrl+end"); s.type("\nThird idea typed on Windows")
    s.shot(OUT / "notes-win-edited.png")
    s.keys("ctrl+z"); s.shot(OUT / "notes-win-after-ctrl-z.png")
    s.keys("ctrl+shift+z"); time.sleep(0.2); s.keys("ctrl+y"); s.shot(OUT / "notes-win-after-redo.png")
    # 3. Ctrl+S shortcut
    s.keys("ctrl+s"); time.sleep(1.0); s.shot(OUT / "notes-win-after-ctrl-s.png")
    print("Ideas.txt now:", repr((FIX / "Ideas.txt").read_bytes()), flush=True)
    # 4. Save As -> dialog (suggested name)
    s.click(253, 134)
    dlg = wait_window(pid, exclude=s.hwnd)
    print("save-as dialog:", dlg, flush=True)
    if dlg:
        shot_hwnd(dlg[0], OUT / "notes-win-save-as-dialog.png")
        keys("escape"); time.sleep(0.8)
    # 5. Edit then New -> discard dialog
    s.click(589, 469); s.type(" dirty"); s.click(48, 134); time.sleep(0.8)
    s.shot(OUT / "notes-win-discard-dialog.png")
    others = other_windows(pid, s.hwnd); print("other windows during discard:", others, flush=True)
    s.keys("escape"); time.sleep(0.5)
    # 6. narrow dialog
    s.resize(376, 600); s.click(48, 134); time.sleep(0.8); s.shot(OUT / "notes-win-discard-dialog-360.png"); s.keys("escape")
    s.resize(1200, 820)
    # 7. Close with unsaved changes -> close dialog
    user32.PostMessageW(s.hwnd, WM_CLOSE, 0, 0); time.sleep(1.0)
    s.shot(OUT / "notes-win-close-dialog.png")
    print("windows after WM_CLOSE:", windows_of(pid), flush=True)
finally:
    print(s.close())
