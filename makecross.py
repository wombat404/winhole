#!/usr/bin/env python3
# takes the uploaded cross, recolors it white on transparent, and builds a
# 6x4 sprite sheet (24 frames of 200x200, each rotated by 15 degrees).
from PIL import Image
import os

SRC = "/home/simon/.claude/uploads/c536aa32-598a-4c2e-97e3-8868cabb9e93/8f4f7d7c-IMG_4600-removebg-preview.png"
OUT = "/home/simon/cross_sprite.png"
COLS, ROWS, FS = 6, 4, 200
FIT = 150          # target cross size inside the 200px frame (leaves margin for rotation)

im = Image.open(SRC).convert("RGBA")
px = im.load()
W, H = im.size

# mask: cross = visible (alpha>10) AND dark (in case background is white, not transparent)
mask = Image.new("L", (W, H), 0)
mp = mask.load()
for y in range(H):
    for x in range(W):
        r, g, b, a = px[x, y]
        lum = (r * 299 + g * 587 + b * 114) // 1000
        if a > 10 and lum < 128:
            mp[x, y] = a          # keep cross alpha (soft edges)

# white cross on transparent
white = Image.new("RGBA", (W, H), (255, 255, 255, 0))
white.putalpha(mask)

# crop to bounding box and scale proportionally to FIT
bbox = mask.getbbox()
cross = white.crop(bbox)
cw, ch = cross.size
scale = FIT / max(cw, ch)
cross = cross.resize((max(1, int(cw * scale)), max(1, int(ch * scale))), Image.LANCZOS)

# center into a 200x200 base frame
base = Image.new("RGBA", (FS, FS), (0, 0, 0, 0))
base.paste(cross, ((FS - cross.width) // 2, (FS - cross.height) // 2), cross)

# sheet with 24 rotated frames
sheet = Image.new("RGBA", (COLS * FS, ROWS * FS), (0, 0, 0, 0))
for i in range(COLS * ROWS):
    rot = base.rotate(-i * 15, resample=Image.BICUBIC, center=(FS // 2, FS // 2))
    c, r = i % COLS, i // COLS
    sheet.paste(rot, (c * FS, r * FS), rot)

if os.path.exists(OUT):
    os.replace(OUT, OUT + ".bak")
sheet.save(OUT)
print("new sheet:", OUT, sheet.size, "| old backed up as", OUT + ".bak")
