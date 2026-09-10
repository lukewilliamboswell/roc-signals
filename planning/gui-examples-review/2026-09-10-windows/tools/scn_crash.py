from scn_common import *
results = []
for i in range(6):
    s = Session(ROOT / ".test-out/gui/activity-monitor.exe", ["--host-trace-engine"] if i == 0 else [], cwd=str(ROOT)); s.resize(1200, 820)
    s.click(70, 183); d = wait_window(s.process.pid, exclude=s.hwnd, timeout=6)
    if d: type_text(str(FIX / "app.log")); keys("enter"); time.sleep(1.5)
    s.click(462, 183); time.sleep(0.3 + 0.4 * i)
    alive_before_close = s.process.poll() is None
    code, out, err = s.close()
    results.append((i, alive_before_close, code))
    print("run", i, "alive before close:", alive_before_close, "exit:", code, hex(code & 0xFFFFFFFF), flush=True)
    if i == 0:
        print("--- trace tail ---"); print(err[-2500:]); print("--- stdout tail ---"); print(out[-800:])
print("crashes:", sum(1 for _, _, c in results if c not in (0, 1)), "of", len(results))
# board close dialog (unsaved seed) at wide and narrow sizes
s = start("task-board", ["--assets-root", str(ROOT / "examples-gui/task-board/assets")])
try:
    user32.PostMessageW(s.hwnd, WM_CLOSE, 0, 0); time.sleep(1.0); s.shot(OUT / "board-win-close-dialog.png")
    s.keys("escape"); time.sleep(0.5); s.resize(376, 600)
    user32.PostMessageW(s.hwnd, WM_CLOSE, 0, 0); time.sleep(1.0); s.shot(OUT / "board-win-close-dialog-360.png")
    s.keys("escape"); time.sleep(0.5); s.resize(1200, 820)
    s.click(70, 486); time.sleep(0.5); s.shot(OUT / "board-win-card-edit.png")
finally: finish(s, "board-close")
