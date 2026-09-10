from scn_common import *
import subprocess, os
def choose_folder(s, path):
    s.click(342, 134); d = wait_window(s.process.pid, exclude=s.hwnd, timeout=6)
    assert d, "no folder dialog"
    user32.SetForegroundWindow(d[0]); time.sleep(0.4)
    type_text(path); time.sleep(0.2); keys("enter"); time.sleep(1.2)
    if find_window(s.process.pid, exclude=s.hwnd): keys("enter"); time.sleep(1.0)
    for _ in range(30):
        if not find_window(s.process.pid, exclude=s.hwnd): break
        time.sleep(0.2)
    else:
        shot_hwnd(d[0], OUT / "explorer-dialog-debug.png"); print("dialog still open; escaping"); keys("escape")
    time.sleep(1.2)
s = Session(ROOT / ".test-out/gui/folder-explorer.exe", ["--host-assets-root", str(ROOT / "examples-gui/folder-explorer/assets")], cwd=str(ROOT)); s.resize(1200, 1040, x=40, y=0)
try:
    choose_folder(s, r"C:\Users\bosyl\.claude\skills\windows-debugging")
    s.shot(OUT / "explorer-win-short-path-folder.png")
    s.click(65, 449); time.sleep(0.5); s.shot(OUT / "explorer-win-short-path-selected.png")
    s.click(886, 578); time.sleep(2.0); s.shot(OUT / "explorer-win-short-path-preview.png")
    s.click(997, 578); time.sleep(3.0); s.shot(OUT / "explorer-win-short-path-open-in-app.png")
    fg = user32.GetForegroundWindow(); n = user32.GetWindowTextLengthW(fg); buf = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(fg, buf, n + 1); print("foreground:", repr(buf.value), "notepad:", subprocess.run(["tasklist"], capture_output=True, text=True).stdout.count("Notepad"), flush=True)
    if fg != s.hwnd: shot_hwnd(fg, OUT / "explorer-win-short-path-external.png"); user32.PostMessageW(fg, WM_CLOSE, 0, 0); time.sleep(1.0)
finally: finish(s, "explorer-r6")
