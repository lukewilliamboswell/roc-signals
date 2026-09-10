from scn_common import *
s = start("task-board", ["--assets-root", str(ROOT / "examples-gui/task-board/assets")])
try:
    s.click(196, 134); d = dialog(s, "board-win-save-as-dialog")
    if d: type_text(str(FIX / "launch-board.json")); keys("enter"); time.sleep(2.0)
    s.shot(OUT / "board-win-after-save-as.png")
    print("saved file exists:", (FIX / "launch-board.json").exists(), flush=True)
    s.drag(152, 412, 686, 619); time.sleep(0.5); s.shot(OUT / "board-win-after-drag.png")
    s.keys("ctrl+z"); time.sleep(0.5); s.shot(OUT / "board-win-after-ctrl-z.png")
    s.click(57, 134); d = dialog(s, "board-win-open-dialog", 6)
    if d: keys("escape"); time.sleep(0.5)
    s.click(153, 195); s.type("A task added on Windows"); s.keys("enter"); time.sleep(0.5); s.shot(OUT / "board-win-after-add.png")
    user32.PostMessageW(s.hwnd, WM_CLOSE, 0, 0); time.sleep(1.0); s.shot(OUT / "board-win-close-dialog.png")
finally:
    finish(s, "board")
