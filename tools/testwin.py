# Shared by the test tools: whether a window belongs to a test copy (run from dev/build/stage by
# testrun.sh), so the tools never touch the installed app the user may have open.
import ctypes
from ctypes import wintypes

_u, _k = ctypes.windll.user32, ctypes.windll.kernel32


def is_test_window(hwnd):
    pid = wintypes.DWORD()
    _u.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    h = _k.OpenProcess(0x1000, False, pid.value)   # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return False
    buf = ctypes.create_unicode_buffer(1024)
    n = wintypes.DWORD(1024)
    ok = _k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n))
    _k.CloseHandle(h)
    path = buf.value.lower()
    # (dev/build/portable: where portable.sh's output is tried out)
    return bool(ok) and ('\\dev\\build\\stage\\' in path or '\\dev\\build\\portable\\' in path)
