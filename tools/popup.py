# Test helper: lists / screenshots / clicks FTL Player's popup windows (Popup.Window menus and lists).
# usage: popup.py shot out.png | popup.py click X Y
import ctypes, sys, time
from testwin import is_test_window   # only test copies, never the installed app
from ctypes import wintypes
from PIL import Image
u, g = ctypes.windll.user32, ctypes.windll.gdi32
u.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
main = []
@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def e1(h, _):
    n = u.GetWindowTextLengthW(h); t = ctypes.create_unicode_buffer(n + 1); u.GetWindowTextW(h, t, n + 1)
    c = ctypes.create_unicode_buffer(256); u.GetClassNameW(h, c, 256)
    if u.IsWindowVisible(h) and t.value.endswith('FTL Player') and 'QWindowIcon' in c.value and is_test_window(h): main.append(h)
    return True
u.EnumWindows(e1, 0)
pid = wintypes.DWORD(); u.GetWindowThreadProcessId(main[0], ctypes.byref(pid))
pops = []
@ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
def e2(h, _):
    p = wintypes.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(p))
    c = ctypes.create_unicode_buffer(256); u.GetClassNameW(h, c, 256)
    if p.value == pid.value and 'Popup' in c.value and u.IsWindowVisible(h): pops.append(h)
    return True
u.EnumWindows(e2, 0)
if not pops: sys.exit('no popup window')
h = pops[0]
r = wintypes.RECT(); u.GetWindowRect(h, ctypes.byref(r)); w, hh = r.right - r.left, r.bottom - r.top
if sys.argv[1] == 'shot':
    dc = u.GetWindowDC(h); mem = g.CreateCompatibleDC(dc); bmp = g.CreateCompatibleBitmap(dc, w, hh); g.SelectObject(mem, bmp)
    u.PrintWindow(h, mem, 2)
    class BIH(ctypes.Structure):
        _fields_ = [(n, t) for n, t in [('biSize', wintypes.DWORD), ('biWidth', wintypes.LONG), ('biHeight', wintypes.LONG), ('biPlanes', wintypes.WORD), ('biBitCount', wintypes.WORD), ('biCompression', wintypes.DWORD), ('biSizeImage', wintypes.DWORD), ('a', wintypes.LONG), ('b', wintypes.LONG), ('c', wintypes.DWORD), ('d', wintypes.DWORD)]]
    bi = BIH(ctypes.sizeof(BIH), w, -hh, 1, 32, 0, 0, 0, 0, 0, 0); buf = ctypes.create_string_buffer(w * hh * 4)
    g.GetDIBits(mem, bmp, 0, hh, buf, ctypes.byref(bi), 0)
    Image.frombuffer('RGBA', (w, hh), buf, 'raw', 'BGRA', 0, 1).convert('RGB').save(sys.argv[2])
    print(f'popup {w}x{hh} at ({r.left},{r.top}) saved')
else:
    x, y = int(sys.argv[2]), int(sys.argv[3]); lp = (y << 16) | x
    u.PostMessageW(h, 0x200, 0, lp); time.sleep(0.05); u.PostMessageW(h, 0x201, 1, lp); time.sleep(0.05); u.PostMessageW(h, 0x202, 0, lp)
    print('clicked popup at', x, y)
