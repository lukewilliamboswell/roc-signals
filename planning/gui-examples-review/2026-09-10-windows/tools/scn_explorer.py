from scn_common import *
s = start("folder-explorer", ["--assets-root", str(ROOT / "examples-gui/folder-explorer/assets")])
try:
    s.click(342, 134); d = dialog(s, "explorer-win-choose-folder-dialog")
    if d:
        type_text(str(FIX / "Project")); keys("enter"); time.sleep(1.0)
        shot_hwnd(d[0], OUT / "explorer-win-choose-folder-dialog-2.png") if find_window(s.process.pid, exclude=s.hwnd) else None
        if find_window(s.process.pid, exclude=s.hwnd):
            keys("enter"); time.sleep(1.0)
        if find_window(s.process.pid, exclude=s.hwnd):
            print("dialog still open; pressing alt+s"); keys("alt+s"); time.sleep(1.0)
    time.sleep(1.0); s.shot(OUT / "explorer-win-project-folder.png")
    s.click(65, 445); time.sleep(0.5); s.shot(OUT / "explorer-win-project-first-row.png")
    s.click(181, 134); time.sleep(1.0); s.shot(OUT / "explorer-win-up.png")
    s.click(48, 134); time.sleep(1.0); s.shot(OUT / "explorer-win-back.png")
finally:
    finish(s, "explorer")
