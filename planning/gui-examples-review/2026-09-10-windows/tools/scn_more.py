from scn_common import *
import os
NOHOME = {k: v for k, v in os.environ.items() if k.upper() != "HOME"}
def run_nohome(app, label, extra=(), click=(196,134)):
    s = Session(ROOT / ".test-out/gui" / f"{app}.exe", list(extra), cwd=str(ROOT), env=NOHOME); s.resize(1200, 820)
    try:
        s.click(*click); d = dialog(s, f"{label}-nohome-dialog", 5)
        s.shot(OUT / f"{label}-nohome-after-click.png")
        if d: keys("escape")
    finally: finish(s, label + "-nohome")
run_nohome("task-board", "board-save-as", ["--assets-root", str(ROOT / "examples-gui/task-board/assets")], (196,134))
run_nohome("notes-editor", "notes-save-as", (), (253,134))

# --- activity crash isolation
def activity(label, steps):
    s = start("activity-monitor")
    try:
        for name, fn in steps:
            fn(s); time.sleep(1.0); print(label, "after", name, "alive:", s.process.poll() is None, flush=True)
    finally: finish(s, "activity-" + label)
def open_log(s):
    s.click(70, 183); d = wait_window(s.process.pid, exclude=s.hwnd, timeout=6)
    if d: type_text(str(FIX / "app.log")); keys("enter"); time.sleep(1.5)
activity("open-close", [("open", open_log)])
activity("open-cancel-close", [("open", open_log), ("cancel", lambda s: s.click(462, 183))])
activity("open-cancel-retry-close", [("open", open_log), ("cancel", lambda s: s.click(462, 183)), ("retry", lambda s: s.click(341, 183))])
activity("replay-steps-close", [("simulated", lambda s: s.click(206, 183)), ("step", lambda s: (s.click(176, 270), s.click(176, 270)))])
activity("replay-running-close", [("start", lambda s: s.click(72, 270))])
activity("open-then-simulated-close", [("open", open_log), ("simulated", lambda s: s.click(206, 183)), ("step", lambda s: s.click(176, 270))])

# --- explorer extras
s = start("folder-explorer", ["--assets-root", str(ROOT / "examples-gui/folder-explorer/assets")])
def choose(path):
    s.click(342, 134); d = wait_window(s.process.pid, exclude=s.hwnd, timeout=6)
    if d:
        type_text(path); keys("enter"); time.sleep(1.0)
        if find_window(s.process.pid, exclude=s.hwnd): keys("enter"); time.sleep(1.0)
        if find_window(s.process.pid, exclude=s.hwnd): keys("alt+s"); time.sleep(1.0)
    time.sleep(1.0)
try:
    choose(str(FIX / "Project")); s.click(65, 537); time.sleep(0.5); s.shot(OUT / "explorer-win-readme-selected.png")
    s.click(936, 582); time.sleep(1.5); s.shot(OUT / "explorer-win-readme-preview.png")
    before = user32.GetForegroundWindow()
    s.click(1047, 582); time.sleep(3.0)
    fg = user32.GetForegroundWindow()
    n = user32.GetWindowTextLengthW(fg); buf = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(fg, buf, n + 1)
    print("foreground after Open in app:", fg, repr(buf.value), "same as app:", fg == s.hwnd, flush=True)
    s.shot(OUT / "explorer-win-after-open-in-app.png")
    if fg != s.hwnd and fg != before:
        shot_hwnd(fg, OUT / "explorer-win-opened-external.png"); user32.PostMessageW(fg, WM_CLOSE, 0, 0); time.sleep(1.0)
    choose("C:\\"); s.shot(OUT / "explorer-win-drive-root.png")
    s.click(181, 134); time.sleep(1.0); s.shot(OUT / "explorer-win-drive-root-up.png")
    od = os.path.join(os.environ["USERPROFILE"], "OneDrive")
    if os.path.isdir(od):
        choose(od); s.shot(OUT / "explorer-win-onedrive.png")
    choose(str(FIX)); s.shot(OUT / "explorer-win-fixtures.png")
finally: finish(s, "explorer-more")

# --- notes: BOM + word motion
s = start("notes-editor")
try:
    s.click(113, 134); d = wait_window(s.process.pid, exclude=s.hwnd, timeout=6)
    if d: type_text(str(FIX / "bom.txt")); keys("enter"); time.sleep(1.5)
    s.shot(OUT / "notes-win-bom-opened.png")
    s.click(589, 469); s.keys("ctrl+home"); s.keys("right"); s.type("X"); s.shot(OUT / "notes-win-bom-caret-after-one-right.png")
    s.keys("ctrl+end"); s.keys("ctrl+left"); s.type("Y"); s.shot(OUT / "notes-win-ctrl-left.png")
    s.keys("ctrl+a"); s.keys("ctrl+c"); s.keys("end"); s.keys("ctrl+v"); s.shot(OUT / "notes-win-after-paste.png")
finally: finish(s, "notes-bom")
