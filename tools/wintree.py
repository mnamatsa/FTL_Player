# Test helper: prints the FTL Player window tree (class, owning thread, styles, rect, enabled/visible).
import ctypes
from testwin import is_test_window   # only test copies, never the installed app
from ctypes import wintypes

user32 = ctypes.windll.user32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))  # per-monitor aware: real pixels on every screen
tops = []

def info(h):
    n = user32.GetWindowTextLengthW(h)
    t = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(h, t, n + 1)
    c = ctypes.create_unicode_buffer(256); user32.GetClassNameW(h, c, 256)
    r = wintypes.RECT(); user32.GetWindowRect(h, ctypes.byref(r))
    pid = wintypes.DWORD(); tid = user32.GetWindowThreadProcessId(h, ctypes.byref(pid))
    style = user32.GetWindowLongW(h, -16) & 0xFFFFFFFF
    ex = user32.GetWindowLongW(h, -20) & 0xFFFFFFFF
    return (f'{c.value!r} title={t.value[:30]!r} thread={tid} style={style:#010x} ex={ex:#010x} '
            f'rect=({r.left},{r.top},{r.right - r.left}x{r.bottom - r.top}) '
            f'visible={bool(user32.IsWindowVisible(h))} enabled={bool(user32.IsWindowEnabled(h))}')

@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def enum_top(h, _):
    n = user32.GetWindowTextLengthW(h)
    t = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(h, t, n + 1)
    if user32.IsWindowVisible(h) and t.value.endswith('FTL Player') and is_test_window(h):
        tops.append(h)
    return True

def walk(h, depth):
    print('  ' * depth + info(h))
    kids = []
    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def enum_kid(k, _):
        if user32.GetParent(k) == h:
            kids.append(k)
        return True
    user32.EnumChildWindows(h, enum_kid, 0)
    for k in kids:
        walk(k, depth + 1)

user32.EnumWindows(enum_top, 0)
for h in tops:
    walk(h, 0)
print('focus thread check: foreground =', user32.GetForegroundWindow(), 'tops =', tops)
