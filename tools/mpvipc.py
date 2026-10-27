# Test helper: sends commands to the test player's mpv over its IPC pipe
# (start the app with FTL_MPV_OPTS containing "input-ipc-server=\\.\pipe\ftl-test").
# usage: mpvipc.py '["mouse", 700, 900]' ['["get_property", "osd-dimensions"]' ...]
import json, os, sys

# Start the app with FTL_MPV_OPTS containing "input-ipc-server=ftl-test"; FTL_PIPE overrides the path.
PIPE = os.environ.get('FTL_PIPE', '\\\\.\\pipe\\ftl-test')

with open(PIPE, 'r+b', buffering=0) as pipe:
    for arg in sys.argv[1:]:
        pipe.write((json.dumps({'command': json.loads(arg)}) + '\n').encode())
        while True:
            line = b''
            while not line.endswith(b'\n'):
                line += pipe.read(1)
            msg = json.loads(line)
            if 'event' not in msg:
                print(json.dumps(msg)[:300])
                break
