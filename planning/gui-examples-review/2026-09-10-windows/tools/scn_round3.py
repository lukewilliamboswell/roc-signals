from scn_common import *
from winshot import _send, _mouse
import subprocess
# a. close while following, no cancel click, varying dwell
res = []
for i, dwell in enumerate((0.5, 1.5, 2.5, 3.5, 4.5, 6.0)):
    s = start("activity-monitor")
    s.click(70, 183); d = wait_window(s.process.pid, exclude=s.hwnd, timeout=6)
    if d: type_text(str(FIX / "app.log")); keys("enter")
    time.sleep(dwell)
    code, out, err = s.close(); res.append((dwell, code)); print("dwell", dwell, "exit", hex(code & 0xFFFFFFFF), flush=True)
# a2. simulated replay running for 6s then close (no file)
s = start("activity-monitor"); s.click(72, 270); time.sleep(6.0); code, _, _ = s.close(); print("replay 6s then close exit", hex(code & 0xFFFFFFFF), flush=True)
# a3. open log, then Pause following, then close after 4s
s = start("activity-monitor"); s.click(70, 183); d = wait_window(s.process.pid, exclude=s.hwnd, timeout=6)
if d: type_text(str(FIX / "app.log")); keys("enter")
time.sleep(1.5); s.click(90, 270); time.sleep(4.0); code, _, _ = s.close(); print("open, pause, 4s, close exit", hex(code & 0xFFFFFFFF), flush=True)
# b. board add + drag with settle
s = start("task-board", ["--host-assets-root", str(ROOT / "examples-gui/task-board/assets")])
try:
    s.click(153, 195); time.sleep(0.3); s.type("A task added on Windows"); time.sleep(0.3); s.shot(OUT / "board-win-typed-title.png")
    s.keys("enter"); time.sleep(0.6); s.shot(OUT / "board-win-after-enter.png")
    s.click(335, 188); time.sleep(0.6); s.shot(OUT / "board-win-after-add-button.png")
    s.move(152, 412); _send([_mouse(MOUSEEVENTF_LEFTDOWN)])
    for i in range(1, 16): s.move(152 + (686-152)*i/15, 412 + (619-412)*i/15); time.sleep(0.03)
    time.sleep(0.5); s.shot(OUT / "board-win-drag-hover-complete.png"); _send([_mouse(MOUSEEVENTF_LEFTUP)]); time.sleep(0.6)
    s.shot(OUT / "board-win-after-drag-settled.png")
finally: finish(s, "board-r3")
# c. explorer tall window: preview + open in app
s = Session(ROOT / ".test-out/gui/folder-explorer.exe", ["--host-assets-root", str(ROOT / "examples-gui/folder-explorer/assets")], cwd=str(ROOT)); s.resize(1200, 1040, x=40, y=0)
try:
    s.click(342, 134); d = wait_window(s.process.pid, exclude=s.hwnd, timeout=6)
    if d:
        type_text(str(FIX / "Project")); keys("enter"); time.sleep(1.0)
        if find_window(s.process.pid, exclude=s.hwnd): keys("enter"); time.sleep(1.0)
    time.sleep(1.0); s.click(65, 537); time.sleep(0.5); s.shot(OUT / "explorer-win-tall-readme-selected.png")
    s.click(936, 582); time.sleep(1.5); s.shot(OUT / "explorer-win-tall-readme-preview.png")
    s.click(1047, 582); time.sleep(3.0); s.shot(OUT / "explorer-win-tall-after-open-in-app.png")
    print("windows of pid:", windows_of(s.process.pid))
    fg = user32.GetForegroundWindow(); n = user32.GetWindowTextLengthW(fg); buf = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(fg, buf, n + 1); print("foreground:", repr(buf.value))
    print(subprocess.run(["tasklist"], capture_output=True, text=True).stdout.count("Notepad"), "Notepad processes", flush=True)
    s.click(65, 449); time.sleep(0.8); s.shot(OUT / "explorer-win-tall-docs-folder.png")
finally: finish(s, "explorer-r3")
