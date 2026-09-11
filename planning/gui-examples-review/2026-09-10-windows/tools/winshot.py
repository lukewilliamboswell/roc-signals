"""Dependency-free Win32 driver: launch a GUI exe, resize its window, send input, capture PNGs.

Usage as a library:
    s = Session(exe, args=[...], cwd=...)
    s.resize(1200, 820); s.shot("out.png"); s.click(100, 200); s.keys("ctrl+z"); s.close()
"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import struct
import subprocess
import sys
import time
import zlib

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
dwmapi = ctypes.WinDLL("dwmapi", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

try:
    user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))  # per-monitor v2
except Exception:
    pass

WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.GetForegroundWindow.restype = wintypes.HWND
user32.GetDC.argtypes = [wintypes.HWND]
user32.GetDC.restype = wintypes.HDC
user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
gdi32.CreateCompatibleDC.restype = wintypes.HDC
gdi32.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
gdi32.CreateCompatibleBitmap.restype = wintypes.HBITMAP
gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
gdi32.SelectObject.restype = wintypes.HGDIOBJ
gdi32.BitBlt.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD]
gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
gdi32.DeleteDC.argtypes = [wintypes.HDC]
dwmapi.DwmGetWindowAttribute.argtypes = [wintypes.HWND, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD]

SWP_NOZORDER, SWP_NOACTIVATE, SWP_SHOWWINDOW = 0x0004, 0x0010, 0x0040
SRCCOPY, CAPTUREBLT = 0x00CC0020, 0x40000000
DWMWA_EXTENDED_FRAME_BOUNDS = 9
WM_CLOSE = 0x0010

# ---- input -----------------------------------------------------------------
ULONG_PTR = ctypes.c_size_t


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
MOUSEEVENTF_MOVE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0001, 0x0002, 0x0004
MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_WHEEL = 0x0008, 0x0010, 0x0800
MOUSEEVENTF_ABSOLUTE = 0x8000
KEYEVENTF_KEYUP, KEYEVENTF_UNICODE = 0x0002, 0x0004

VK = {
    "ctrl": 0x11, "control": 0x11, "shift": 0x10, "alt": 0x12, "win": 0x5B, "meta": 0x5B,
    "enter": 0x0D, "return": 0x0D, "tab": 0x09, "escape": 0x1B, "esc": 0x1B, "space": 0x20,
    "backspace": 0x08, "delete": 0x2E, "home": 0x24, "end": 0x23, "pageup": 0x21, "pagedown": 0x22,
    "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28, "f1": 0x70, "f2": 0x71, "f5": 0x74,
}


def _send(inputs):
    array = (INPUT * len(inputs))(*inputs)
    sent = user32.SendInput(len(inputs), array, ctypes.sizeof(INPUT))
    if sent != len(inputs):
        raise OSError(ctypes.get_last_error(), "SendInput failed")


def _key(vk, up=False):
    item = INPUT(type=INPUT_KEYBOARD)
    item.u.ki = KEYBDINPUT(wVk=vk, wScan=0, dwFlags=KEYEVENTF_KEYUP if up else 0, time=0, dwExtraInfo=0)
    return item


def _unicode(char, up=False):
    item = INPUT(type=INPUT_KEYBOARD)
    item.u.ki = KEYBDINPUT(wVk=0, wScan=ord(char), dwFlags=KEYEVENTF_UNICODE | (KEYEVENTF_KEYUP if up else 0), time=0, dwExtraInfo=0)
    return item


def _mouse(flags, data=0):
    item = INPUT(type=INPUT_MOUSE)
    item.u.mi = MOUSEINPUT(dx=0, dy=0, mouseData=data, dwFlags=flags, time=0, dwExtraInfo=0)
    return item


def keys(chord: str, repeat: int = 1):
    """Press a chord like 'ctrl+shift+z' or a single key name / character."""
    parts = chord.split("+") if chord != "+" else ["+"]
    mods = [VK[p.lower()] for p in parts[:-1]]
    last = parts[-1]
    for _ in range(repeat):
        _send([_key(m) for m in mods])
        if last.lower() in VK:
            _send([_key(VK[last.lower()]), _key(VK[last.lower()], up=True)])
        elif len(last) == 1 and (mods or not last.isalnum()):
            vk = user32.VkKeyScanW(ord(last)) & 0xFF if last.isalnum() else None
            if vk is not None:
                _send([_key(vk), _key(vk, up=True)])
            else:
                _send([_unicode(last), _unicode(last, up=True)])
        else:
            for ch in last:
                _send([_unicode(ch), _unicode(ch, up=True)])
        _send([_key(m, up=True) for m in reversed(mods)])
        time.sleep(0.05)


def type_text(text: str, delay: float = 0.01):
    for ch in text:
        if ch == "\n":
            keys("enter")
        else:
            _send([_unicode(ch), _unicode(ch, up=True)])
        time.sleep(delay)


# ---- PNG -------------------------------------------------------------------

def write_png(path, width, height, bgra: bytes):
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        row = bgra[y * stride:(y + 1) * stride]
        raw.append(0)
        # BGRA -> RGB
        raw.extend(bytes(b for px in (row[i:i + 4] for i in range(0, stride, 4)) for b in (px[2], px[1], px[0])))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    data += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


def capture_rect(left, top, width, height, path):
    screen = user32.GetDC(None)
    mem = gdi32.CreateCompatibleDC(screen)
    bmp = gdi32.CreateCompatibleBitmap(screen, width, height)
    old = gdi32.SelectObject(mem, bmp)
    if not gdi32.BitBlt(mem, 0, 0, width, height, screen, left, top, SRCCOPY | CAPTUREBLT):
        raise OSError(ctypes.get_last_error(), "BitBlt failed")

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG), ("biHeight", wintypes.LONG),
                    ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                    ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG), ("biYPelsPerMeter", wintypes.LONG),
                    ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]

    info = BITMAPINFOHEADER(biSize=ctypes.sizeof(BITMAPINFOHEADER), biWidth=width, biHeight=-height, biPlanes=1, biBitCount=32, biCompression=0)
    buffer = ctypes.create_string_buffer(width * height * 4)
    gdi32.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]
    lines = gdi32.GetDIBits(mem, bmp, 0, height, buffer, ctypes.byref(info), 0)
    gdi32.SelectObject(mem, old)
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mem)
    user32.ReleaseDC(None, screen)
    if lines != height:
        raise OSError("GetDIBits returned %d lines" % lines)
    write_png(path, width, height, buffer.raw)


# ---- session ---------------------------------------------------------------

def windows_of(pid: int):
    found = []

    @WNDENUMPROC
    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            n = user32.GetWindowTextLengthW(hwnd)
            buf = ctypes.create_unicode_buffer(n + 1)
            user32.GetWindowTextW(hwnd, buf, n + 1)
            found.append((hwnd, buf.value))
        return True

    user32.EnumWindows(visit, 0)
    return found


class Session:
    def __init__(self, exe, args=(), cwd=None, env=None, wait=3.0, title_filter=None):
        self.process = subprocess.Popen([str(exe), *map(str, args)], cwd=cwd, env=env,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 30
        self.hwnd = None
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                out, err = self.process.communicate()
                raise RuntimeError(f"process exited {self.process.returncode}: {err.decode(errors='replace')[-2000:]}")
            for hwnd, title in windows_of(self.process.pid):
                if title_filter is None or title_filter in title:
                    self.hwnd, self.title = hwnd, title
                    break
            if self.hwnd:
                break
            time.sleep(0.2)
        if not self.hwnd:
            self.close()
            raise RuntimeError("no visible window appeared")
        time.sleep(wait)
        user32.SetForegroundWindow(self.hwnd)

    # geometry ---------------------------------------------------------------
    def frame(self):
        r = wintypes.RECT()
        dwmapi.DwmGetWindowAttribute(self.hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, ctypes.byref(r), ctypes.sizeof(r))
        return r.left, r.top, r.right - r.left, r.bottom - r.top

    def window_rect(self):
        r = wintypes.RECT()
        user32.GetWindowRect(self.hwnd, ctypes.byref(r))
        return r.left, r.top, r.right - r.left, r.bottom - r.top

    def client_origin(self):
        p = wintypes.POINT(0, 0)
        user32.ClientToScreen(self.hwnd, ctypes.byref(p))
        r = wintypes.RECT()
        user32.GetClientRect(self.hwnd, ctypes.byref(r))
        return p.x, p.y, r.right, r.bottom

    def resize(self, width, height, x=40, y=40, settle=1.0):
        """Set the OUTER window rect (GetWindowRect coordinates)."""
        user32.SetWindowPos(self.hwnd, None, x, y, width, height, SWP_NOZORDER | SWP_SHOWWINDOW)
        time.sleep(settle)
        return self.window_rect()

    # capture ----------------------------------------------------------------
    def shot(self, path, settle=0.4):
        user32.SetForegroundWindow(self.hwnd)
        time.sleep(settle)
        left, top, width, height = self.frame()
        capture_rect(left, top, width, height, path)
        return path

    # input (client coordinates) --------------------------------------------
    def to_screen(self, x, y):
        cx, cy, _, _ = self.client_origin()
        return cx + int(x), cy + int(y)

    def move(self, x, y):
        sx, sy = self.to_screen(x, y)
        user32.SetCursorPos(sx, sy)
        _send([_mouse(MOUSEEVENTF_MOVE)])
        time.sleep(0.05)

    def click(self, x, y, button="left", settle=0.3, double=False):
        self.move(x, y)
        down, up = (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP) if button == "left" else (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP)
        _send([_mouse(down), _mouse(up)])
        if double:
            time.sleep(0.05)
            _send([_mouse(down), _mouse(up)])
        time.sleep(settle)

    def drag(self, x1, y1, x2, y2, steps=12, settle=0.3):
        self.move(x1, y1)
        _send([_mouse(MOUSEEVENTF_LEFTDOWN)])
        for i in range(1, steps + 1):
            self.move(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps)
            time.sleep(0.02)
        _send([_mouse(MOUSEEVENTF_LEFTUP)])
        time.sleep(settle)

    def wheel(self, x, y, clicks=-3, settle=0.3):
        self.move(x, y)
        for _ in range(abs(clicks)):
            _send([_mouse(MOUSEEVENTF_WHEEL, (120 if clicks > 0 else -120) & 0xFFFFFFFF)])
            time.sleep(0.03)
        time.sleep(settle)

    def keys(self, chord, repeat=1, settle=0.2):
        user32.SetForegroundWindow(self.hwnd)
        keys(chord, repeat)
        time.sleep(settle)

    def type(self, text, settle=0.2):
        user32.SetForegroundWindow(self.hwnd)
        type_text(text)
        time.sleep(settle)

    # lifecycle --------------------------------------------------------------
    def close(self, timeout=5.0):
        if self.process.poll() is None and getattr(self, "hwnd", None):
            user32.PostMessageW(self.hwnd, WM_CLOSE, 0, 0)
            try:
                self.process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                pass
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        out, err = self.process.communicate()
        return self.process.returncode, out.decode(errors="replace"), err.decode(errors="replace")


if __name__ == "__main__":
    exe, out = sys.argv[1], sys.argv[2]
    extra = sys.argv[3:]
    s = Session(exe, extra)
    print("window", s.title, "rect", s.window_rect(), "frame", s.frame(), "client", s.client_origin())
    s.resize(1200, 820)
    print("after resize rect", s.window_rect(), "frame", s.frame(), "client", s.client_origin())
    s.shot(out)
    print(s.close())


# ---- dialogs / extra windows ----------------------------------------------
def find_window(pid, contains=None, exclude=None):
    for hwnd, title in windows_of(pid):
        if hwnd == exclude:
            continue
        if contains is None or contains.lower() in title.lower():
            return hwnd, title
    return None


def wait_window(pid, contains=None, exclude=None, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = find_window(pid, contains, exclude)
        if found:
            time.sleep(0.6)
            return found
        time.sleep(0.2)
    return None


def shot_hwnd(hwnd, path, settle=0.4):
    user32.SetForegroundWindow(hwnd)
    time.sleep(settle)
    r = wintypes.RECT()
    dwmapi.DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, ctypes.byref(r), ctypes.sizeof(r))
    capture_rect(r.left, r.top, r.right - r.left, r.bottom - r.top, path)
    return path


def shot_screen_union(hwnds, path, settle=0.4):
    """Capture the bounding box of several windows (e.g. app + modal dialog)."""
    time.sleep(settle)
    boxes = []
    for hwnd in hwnds:
        r = wintypes.RECT()
        dwmapi.DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, ctypes.byref(r), ctypes.sizeof(r))
        boxes.append((r.left, r.top, r.right, r.bottom))
    left, top = min(b[0] for b in boxes), min(b[1] for b in boxes)
    right, bottom = max(b[2] for b in boxes), max(b[3] for b in boxes)
    capture_rect(left, top, right - left, bottom - top, path)
    return path


def other_windows(pid, exclude):
    return [(h, t) for h, t in windows_of(pid) if h != exclude]
