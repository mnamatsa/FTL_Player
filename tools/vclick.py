# Test helper: click inside the mpv video area at screenshot (window) coordinates, via the video window.
# usage: vclick.py X Y [move]   (X Y as in shot.py screenshots; 'move' only moves the pointer there)
import ctypes, sys, time
from testwin import is_test_window   # only test copies, never the installed app
from ctypes import wintypes
u = ctypes.windll.user32
u.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
tops = []
@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def e(h, _):
    n = u.GetWindowTextLengthW(h); t = ctypes.create_unicode_buffer(n + 1); u.GetWindowTextW(h, t, n + 1)
    c = ctypes.create_unicode_buffer(256); u.GetClassNameW(h, c, 256)
    if u.IsWindowVisible(h) and 'QWindowIcon' in c.value and t.value.endswith('FTL Player') and is_test_window(h): tops.append(h)
    return True
u.EnumWindows(e, 0)
main = tops[0]; kids = []
@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def k(h, _):
    if u.GetParent(h) == main: kids.append(h)
    return True
u.EnumChildWindows(main, k, 0)
video = kids[0]
mr = wintypes.RECT(); u.GetWindowRect(main, ctypes.byref(mr)); vr = wintypes.RECT(); u.GetWindowRect(video, ctypes.byref(vr))
x, y = int(sys.argv[1]) + mr.left - vr.left, int(sys.argv[2]) + mr.top - vr.top
lp = (y << 16) | x
msgs = ((0x200, 0),) if len(sys.argv) > 3 and sys.argv[3] == 'move' else ((0x200, 0), (0x201, 1), (0x202, 0))
for m, w in msgs:
    u.PostMessageW(video, m, w, lp); time.sleep(0.08)
print('video', 'move' if len(msgs) == 1 else 'click', 'at', x, y)
