# Test helper: clicks inside the FTL Player window without moving the real mouse.
# usage: click.py X Y [left|middle|right]   (coordinates as in shot.py screenshots, i.e. relative to the window's outer corner)
import ctypes, sys, time
from testwin import is_test_window   # only test copies, never the installed app
from ctypes import wintypes

user32 = ctypes.windll.user32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))  # per-monitor aware: real pixels on every screen
found = []


def _is_popup(h):  # Qt popup windows (menus, combo box lists) share the app's title
    c = ctypes.create_unicode_buffer(256); ctypes.windll.user32.GetClassNameW(h, c, 256)
    return 'QWindowIcon' not in c.value  # only the main window has this class

@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def enum(hwnd, _):
    n = user32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(hwnd, buf, n + 1)
    if user32.IsWindowVisible(hwnd) and not _is_popup(hwnd) and buf.value.endswith('FTL Player') and is_test_window(hwnd):
        found.append(hwnd)
    return True

user32.EnumWindows(enum, 0)
if not found:
    sys.exit('window not found')
hwnd = found[0]
r = wintypes.RECT()
user32.GetWindowRect(hwnd, ctypes.byref(r))
origin = wintypes.POINT(0, 0)
user32.ClientToScreen(hwnd, ctypes.byref(origin))
x = int(sys.argv[1]) - (origin.x - r.left)
y = int(sys.argv[2]) - (origin.y - r.top)
lp = (y << 16) | (x & 0xFFFF)
# optional 3rd argument: left (default) | middle | right
down, up, mk = {'left': (0x201, 0x202, 1), 'middle': (0x207, 0x208, 0x10), 'right': (0x204, 0x205, 2)}[
    sys.argv[3] if len(sys.argv) > 3 else 'left']
user32.PostMessageW(hwnd, 0x200, 0, lp)  # WM_MOUSEMOVE
time.sleep(0.05)
user32.PostMessageW(hwnd, down, mk, lp)
time.sleep(0.05)
user32.PostMessageW(hwnd, up, 0, lp)
print(f'clicked client ({x},{y})')
