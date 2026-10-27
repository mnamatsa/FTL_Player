# Test helper: moves the FTL Player test window onto the laptop's built-in display (the non-primary
# monitor here), without activating it and behind all other windows, so tests stay out of the way.
import ctypes
from testwin import is_test_window   # only test copies, never the installed app
from ctypes import wintypes

u = ctypes.windll.user32
u.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))

class MONITORINFO(ctypes.Structure):
    _fields_ = [('cbSize', wintypes.DWORD), ('rcMonitor', wintypes.RECT), ('rcWork', wintypes.RECT), ('dwFlags', wintypes.DWORD)]

monitors = []
MONITORENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMONITOR, wintypes.HDC, ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)
def on_monitor(h, _dc, _r, _l):
    mi = MONITORINFO(ctypes.sizeof(MONITORINFO)); u.GetMonitorInfoW(h, ctypes.byref(mi)); monitors.append(mi)
    return True
u.EnumDisplayMonitors(None, None, MONITORENUMPROC(on_monitor), 0)
laptop = next((m for m in monitors if not m.dwFlags & 1), monitors[0])  # MONITORINFOF_PRIMARY = 1

wins = []
@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def on_window(h, _):
    n = u.GetWindowTextLengthW(h); t = ctypes.create_unicode_buffer(n + 1); u.GetWindowTextW(h, t, n + 1)
    c = ctypes.create_unicode_buffer(256); u.GetClassNameW(h, c, 256)
    if u.IsWindowVisible(h) and 'QWindowIcon' in c.value and t.value.endswith('FTL Player') and is_test_window(h):
        wins.append(h)
    return True
u.EnumWindows(on_window, 0)
if not wins:
    raise SystemExit('window not found')
w = laptop.rcWork
# HWND_BOTTOM, SWP_NOSIZE | SWP_NOACTIVATE; Qt rescales the window itself for the monitor's DPI
u.SetWindowPos(wins[0], 1, w.left + 40, w.top + 40, 0, 0, 0x0001 | 0x0010)
print(f'moved to laptop display at ({w.left},{w.top}) {w.right - w.left}x{w.bottom - w.top}')
