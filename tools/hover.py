# Test helper: briefly puts the real cursor over the video (centre-bottom), screenshots, then restores it.
import ctypes, subprocess, sys, time
from testwin import is_test_window   # only test copies, never the installed app
from ctypes import wintypes
user32 = ctypes.windll.user32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
tops = []
@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def enum_top(h, _):
    n = user32.GetWindowTextLengthW(h); t = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(h, t, n + 1)
    if user32.IsWindowVisible(h) and t.value.endswith('FTL Player') and is_test_window(h): tops.append(h)
    return True
user32.EnumWindows(enum_top, 0)
kids = []
@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def enum_kid(k, _):
    if user32.GetParent(k) == tops[0]: kids.append(k)
    return True
user32.EnumChildWindows(tops[0], enum_kid, 0)
r = wintypes.RECT(); user32.GetWindowRect(kids[0], ctypes.byref(r))
old = wintypes.POINT(); user32.GetCursorPos(ctypes.byref(old))
HWND_TOPMOST, HWND_NOTOPMOST, HWND_BOTTOM, FLAGS = -1, -2, 1, 0x0001 | 0x0002 | 0x0010  # NOSIZE|NOMOVE|NOACTIVATE
user32.SetWindowPos(tops[0], HWND_TOPMOST, 0, 0, 0, 0, FLAGS)
try:
    x, y = (r.left + r.right) // 2, r.bottom - 40
    for dx in (0, 10, 20):
        user32.SetCursorPos(x + dx, y); time.sleep(0.15)
    time.sleep(0.5)
    subprocess.run([sys.executable, 'shot.py', sys.argv[1]])
finally:
    user32.SetCursorPos(old.x, old.y)
    user32.SetWindowPos(tops[0], HWND_NOTOPMOST, 0, 0, 0, 0, FLAGS)
    user32.SetWindowPos(tops[0], HWND_BOTTOM, 0, 0, 0, 0, FLAGS)
