# Test helper: sends input to FTL Player's windows with PostMessage (the real mouse/keyboard are untouched).
# usage: input.py <target> <action> [args]
#   target: main | video     (video = the native window mpv draws into)
#   action: key VK | move X Y | click X Y | dblclick X Y | close      (X Y in client pixels of the target)
import ctypes, sys, time
from testwin import is_test_window   # only test copies, never the installed app
from ctypes import wintypes

user32 = ctypes.windll.user32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))  # per-monitor aware: real pixels on every screen
tops = []


def _is_popup(h):  # Qt popup windows (menus, combo box lists) share the app's title
    c = ctypes.create_unicode_buffer(256); ctypes.windll.user32.GetClassNameW(h, c, 256)
    return 'QWindowIcon' not in c.value  # only the main window has this class

@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def enum_top(h, _):
    n = user32.GetWindowTextLengthW(h)
    t = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(h, t, n + 1)
    if user32.IsWindowVisible(h) and not _is_popup(h) and t.value.endswith('FTL Player') and is_test_window(h):
        tops.append(h)
    return True

user32.EnumWindows(enum_top, 0)
if not tops:
    sys.exit('window not found')
main = tops[0]
video = None
@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def enum_kid(k, _):
    global video
    if user32.GetParent(k) == main and video is None:
        video = k
    return True
user32.EnumChildWindows(main, enum_kid, 0)

target = main if sys.argv[1] == 'main' else video
if not target:
    sys.exit('target window not found')
action = sys.argv[2]
post = user32.PostMessageW
lp = lambda x, y: (int(y) << 16) | (int(x) & 0xFFFF)
if action == 'key':
    vk = int(sys.argv[3], 0)
    scan = user32.MapVirtualKeyW(vk, 0)
    post(target, 0x100, vk, 1 | (scan << 16))                 # WM_KEYDOWN
    time.sleep(0.05)
    post(target, 0x101, vk, 1 | (scan << 16) | (3 << 30))     # WM_KEYUP
elif action == 'move':
    post(target, 0x200, 0, lp(sys.argv[3], sys.argv[4]))
elif action in ('click', 'dblclick'):
    p = lp(sys.argv[3], sys.argv[4])
    for _ in range(2 if action == 'dblclick' else 1):
        post(target, 0x201, 1, p); time.sleep(0.04); post(target, 0x202, 0, p); time.sleep(0.06)
elif action == 'close':
    post(target, 0x0010, 0, 0)                                # WM_CLOSE
print('sent', action, 'to', sys.argv[1], target)
