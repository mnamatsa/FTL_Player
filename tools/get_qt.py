# Downloads Qt 6.11.3 (MinGW), the matching MinGW 13.1 compiler, CMake and Ninja from download.qt.io
# into dev/tools, verifying each archive against the published SHA-256.
import hashlib, os, re, sys, urllib.request
import py7zr

BASE = 'https://download.qt.io/online/qtsdkrepository/windows_x86/desktop'
HERE = os.path.dirname(os.path.abspath(__file__))
DL = os.path.join(HERE, '..', 'downloads')
os.makedirs(DL, exist_ok=True)

def get(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()

def files_in(folder_url):
    html = get(folder_url + '/').decode('utf-8', 'replace')
    return sorted(set(re.findall(r'href="([^"?/]+\.7z)"', html)))

def fetch(folder_url, name, dest_root, want):
    files = [f for f in files_in(folder_url) if any(w in f for w in want)]
    if not files:
        sys.exit(f'nothing matched {want} in {folder_url}')
    for f in files:
        path = os.path.join(DL, f)
        if not os.path.exists(path):
            print('download', f, flush=True)
            data = get(f'{folder_url}/{f}')
            expected = get(f'{folder_url}/{f}.sha256').decode().split()[0]
            if hashlib.sha256(data).hexdigest() != expected:
                sys.exit(f'SHA-256 mismatch for {f}')
            open(path, 'wb').write(data)
        print('extract ', f, flush=True)
        with py7zr.SevenZipFile(path) as z:
            z.extractall(dest_root)
    print('done', name, flush=True)

qt = f'{BASE}/qt6_6113/qt6_6113_mingw/qt.qt6.6113.win64_mingw'
fetch(qt, 'Qt 6.11.3', os.path.join(HERE, 'Qt'), ['qtbase-', 'qtdeclarative-', 'qtsvg-', 'qttools-', 'qttranslations-', 'd3dcompiler_47', 'MinGW-w64'])
fetch(f'{BASE}/tools_mingw1310/qt.tools.win64_mingw1310', 'MinGW 13.1', os.path.join(HERE, 'Qt'), ['.7z'])
for tool in ('cmake', 'ninja'):
    folder = f'{BASE}/tools_{tool}'
    sub = re.findall(r'href="(qt\.tools\.[^"/]+)/"', get(folder + '/').decode())
    fetch(f'{folder}/{sub[0]}', tool, os.path.join(HERE, 'Qt'), ['.7z'])
