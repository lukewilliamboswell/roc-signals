from scn_common import *
import subprocess
s = Session(ROOT / ".test-out/gui/folder-explorer.exe", ["--host-assets-root", str(ROOT / "examples-gui/folder-explorer/assets")], cwd=str(ROOT)); s.resize(1200, 1040, x=40, y=0)
try:
    s.click(65, 621); time.sleep(0.5); s.click(886, 578); time.sleep(1.5); s.shot(OUT / "explorer-win-sample-readme-preview.png")
    s.click(997, 578); time.sleep(3.0); s.shot(OUT / "explorer-win-sample-open-in-app.png")
    print("after sample open-in-app, notepad count:", subprocess.run(["tasklist"], capture_output=True, text=True).stdout.count("Notepad"), "windows:", windows_of(s.process.pid), flush=True)
    fg = user32.GetForegroundWindow(); n = user32.GetWindowTextLengthW(fg); buf = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(fg, buf, n + 1); print("foreground:", repr(buf.value))
    if fg != s.hwnd:
        shot_hwnd(fg, OUT / "explorer-win-sample-external-app.png"); user32.PostMessageW(fg, WM_CLOSE, 0, 0); time.sleep(1.0)
    # now a real folder
    s.click(342, 134); d = wait_window(s.process.pid, exclude=s.hwnd, timeout=6)
    if d:
        type_text(str(FIX / "Project")); keys("enter"); time.sleep(1.0)
        if find_window(s.process.pid, exclude=s.hwnd): keys("enter"); time.sleep(1.0)
    time.sleep(1.0); s.click(65, 537); time.sleep(0.5)
    s.move(936, 582); time.sleep(0.3); s.shot(OUT / "explorer-win-real-hover-preview-button.png")
    s.click(936, 582); time.sleep(2.0); s.shot(OUT / "explorer-win-real-readme-preview-2.png")
    s.keys("tab"); s.keys("tab"); s.shot(OUT / "explorer-win-real-tab-focus.png")
finally: finish(s, "explorer-r4")
