# Test helper: screenshot of the FTL Player window (even if covered) via PrintWindow.
# usage: shot.py out.png [window-title-substring | --popup]   (--popup: the open popup window, e.g. the timer panel)
import ctypes, sys
from testwin import is_test_window   # only test copies, never the installed app
from ctypes import wintypes
from PIL import Image

user32, gdi32 = ctypes.windll.user32, ctypes.windll.gdi32
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))  # per-monitor aware: real pixels on every screen
popup = len(sys.argv) > 2 and sys.argv[2] == '--popup'
want = sys.argv[2] if len(sys.argv) > 2 and not popup else 'FTL Player'
found = []


def _is_popup(h):  # Qt popup windows (menus, combo box lists) share the app's title
    c = ctypes.create_unicode_buffer(256); ctypes.windll.user32.GetClassNameW(h, c, 256)
    return 'QWindowIcon' not in c.value  # only the main window has this class

@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def enum(hwnd, _):
    n = user32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(n + 1)
    user32.GetWindowTextW(hwnd, buf, n + 1)
    if user32.IsWindowVisible(hwnd) and _is_popup(hwnd) == popup and buf.value.endswith(want) and is_test_window(hwnd):
        found.append(hwnd)
    return True

user32.EnumWindows(enum, 0)
if not found:
    sys.exit('window not found')
hwnd = found[0]
r = wintypes.RECT()
user32.GetWindowRect(hwnd, ctypes.byref(r))
w, h = r.right - r.left, r.bottom - r.top
hdc = user32.GetWindowDC(hwnd)
mem = gdi32.CreateCompatibleDC(hdc)
bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
gdi32.SelectObject(mem, bmp)
user32.PrintWindow(hwnd, mem, 2)  # PW_RENDERFULLCONTENT

class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [('biSize', wintypes.DWORD), ('biWidth', wintypes.LONG), ('biHeight', wintypes.LONG),
                ('biPlanes', wintypes.WORD), ('biBitCount', wintypes.WORD), ('biCompression', wintypes.DWORD),
                ('biSizeImage', wintypes.DWORD), ('biXPelsPerMeter', wintypes.LONG), ('biYPelsPerMeter', wintypes.LONG),
                ('biClrUsed', wintypes.DWORD), ('biClrImportant', wintypes.DWORD)]

bi = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
buf = ctypes.create_string_buffer(w * h * 4)
gdi32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(bi), 0)
Image.frombuffer('RGBA', (w, h), buf, 'raw', 'BGRA', 0, 1).convert('RGB').save(sys.argv[1])
gdi32.DeleteObject(bmp); gdi32.DeleteDC(mem); user32.ReleaseDC(hwnd, hdc)
print(f'saved {w}x{h}')
