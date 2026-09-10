from scn_common import *
import subprocess, os
LOG = S / "dbg_activity_close.txt"
if LOG.exists(): LOG.unlink()
exe = str(ROOT / ".test-out/gui/activity-monitor.exe")
cmd = ["WinDbgX", "-loga", str(LOG), "-g", "-c", "sxe av; g; .ecxr; r; k 40; .logclose; q", exe]
dbg = subprocess.Popen(cmd, cwd=str(ROOT))
def find_title(title):
    out = []
    @WNDENUMPROC
    def visit(h, _):
        if user32.IsWindowVisible(h):
            n = user32.GetWindowTextLengthW(h); b = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(h, b, n + 1)
            if b.value == title: out.append(h)
        return True
    user32.EnumWindows(visit, 0); return out
deadline = time.monotonic() + 60; hwnd = None
while time.monotonic() < deadline and not hwnd:
    found = find_title("Roc Signals"); hwnd = found[0] if found else None; time.sleep(0.3)
print("app window:", hwnd, flush=True)
s = Session.__new__(Session); s.hwnd = hwnd; s.title = "Roc Signals"
class P:
    def poll(self): return None
    pid = 0
s.process = P()
pid = wintypes.DWORD(); user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid)); s.process.pid = pid.value
time.sleep(2.0); s.resize(1200, 820)
s.click(70, 183); d = wait_window(pid.value, exclude=hwnd, timeout=8); print("dialog", d, flush=True)
if d: type_text(str(FIX / "app.log")); keys("enter")
time.sleep(5.0)
user32.PostMessageW(hwnd, WM_CLOSE, 0, 0)
for _ in range(60):
    time.sleep(1.0)
    if dbg.poll() is not None: break
print("windbg exit:", dbg.poll(), flush=True)
if dbg.poll() is None: dbg.kill()
print(LOG.read_text(errors="replace")[-6000:] if LOG.exists() else "no log")
