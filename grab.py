#!/usr/bin/env python3
# connects to QEMU's QMP socket and takes a series of screendumps (PPM) while
# the recovery animation runs, then converts them to PNG.
import socket, json, time, os, sys
from PIL import Image

SOCK = "/tmp/qmp.sock"
OUT  = "/home/simon/recovery-build/shots"
N    = int(sys.argv[1]) if len(sys.argv) > 1 else 40
IVAL = float(sys.argv[2]) if len(sys.argv) > 2 else 0.4

os.makedirs(OUT, exist_ok=True)

# wait for socket
s = None
for _ in range(100):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(SOCK); break
    except OSError:
        time.sleep(0.2)
if not s:
    print("no QMP socket"); sys.exit(1)

f = s.makefile("rw")
def cmd(obj):
    f.write(json.dumps(obj) + "\r\n"); f.flush()
    while True:                     # skip event lines, wait for return
        line = f.readline()
        if not line:
            return None
        msg = json.loads(line)
        if "event" in msg:
            continue
        return msg

f.readline()                       # greeting
cmd({"execute": "qmp_capabilities"})

made = []
for i in range(N):
    ppm = f"{OUT}/f{i:03d}.ppm"
    if cmd({"execute": "screendump", "arguments": {"filename": ppm}}) is None:
        break
    made.append(ppm)
    time.sleep(IVAL)

# PPM -> PNG, keep only non-fully-black
kept = []
for p in made:
    if not os.path.exists(p):
        continue
    try:
        im = Image.open(p).convert("RGB")
    except Exception:
        continue
    extrema = im.getextrema()
    maxval = max(e[1] for e in extrema)
    png = p[:-4] + ".png"
    im.save(png)
    kept.append((png, maxval))
    os.remove(p)

nonblack = [k for k in kept if k[1] > 20]
print("frames total:", len(kept), "| with content:", len(nonblack))
for k, v in kept:
    print(f"  {os.path.basename(k)}  max={v}")
