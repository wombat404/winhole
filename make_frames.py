#!/usr/bin/env python3
# writes three raw frame files to initramfs/anim/:
#   frames.bin             - "doing the magic stuff" (boot phase, mode unknown)
#   frames_installing.bin  - "doing the magic stuff" + "installing"
#   frames_restoring.bin   - "doing the magic stuff" + "restoring"
# if cross_sprite.png is missing, a 24-frame cross sheet (15 deg steps) is generated.
import os, struct, sys
from PIL import Image, ImageDraw, ImageFont

HERE   = os.path.dirname(os.path.abspath(__file__))
SHEET  = sys.argv[1] if len(sys.argv) > 1 else "/home/simon/cross_sprite.png"
OUTDIR = os.path.join(HERE, "initramfs/anim")
COLS, ROWS, FS = 6, 4, 200
NFRAMES = COLS * ROWS
CANVAS_W, CANVAS_H = 520, 340
TEXT_MAIN = "doing the magic stuff"
MODES = ("installing", "restoring")


def make_sheet():
    sheet = Image.new("RGBA", (COLS * FS, ROWS * FS), (0, 0, 0, 0))
    base = Image.new("RGBA", (FS, FS), (0, 0, 0, 0))
    d = ImageDraw.Draw(base)
    cx, cy = FS // 2, FS // 2
    arm_w = 28
    v_top, v_bot = 20, 180
    h_l, h_r = 50, 150
    bar_y = 70
    d.rectangle([cx - arm_w, v_top, cx + arm_w, v_bot], fill=(255, 255, 255, 255))
    d.rectangle([h_l, bar_y - arm_w, h_r, bar_y + arm_w], fill=(255, 255, 255, 255))
    for i in range(NFRAMES):
        rot = base.rotate(-i * 15, resample=Image.BICUBIC, center=(cx, cy))
        c, r = i % COLS, i // COLS
        sheet.paste(rot, (c * FS, r * FS), rot)
    return sheet


def load_font(size):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()


def text_width(draw, text, font):
    try:
        bb = draw.textbbox((0, 0), text, font=font)
        return bb[2] - bb[0]
    except Exception:
        return len(text) * 6


def write_frames(path, sheet, font_main, font_mode=None, mode_label=None):
    with open(path, "wb") as f:
        f.write(struct.pack("<III", CANVAS_W, CANVAS_H, NFRAMES))
        for i in range(NFRAMES):
            c, r = i % COLS, i // COLS
            frame = sheet.crop((c * FS, r * FS, c * FS + FS, r * FS + FS))
            canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 255))
            canvas.paste(frame, ((CANVAS_W - FS) // 2, 10), frame)
            d = ImageDraw.Draw(canvas)
            tw = text_width(d, TEXT_MAIN, font_main)
            d.text(((CANVAS_W - tw) // 2, 230), TEXT_MAIN,
                   fill=(255, 255, 255, 255), font=font_main)
            if mode_label and font_mode:
                mw = text_width(d, mode_label, font_mode)
                d.text(((CANVAS_W - mw) // 2, 285), mode_label,
                       fill=(180, 220, 255, 255), font=font_mode)
            f.write(canvas.tobytes("raw", "RGBA"))
    print("wrote:", path, os.path.getsize(path), "bytes",
          f"({NFRAMES} frames {CANVAS_W}x{CANVAS_H})")


def main():
    if os.path.exists(SHEET):
        sheet = Image.open(SHEET).convert("RGBA")
        print("sheet loaded:", SHEET, sheet.size)
    else:
        sheet = make_sheet()
        print("sheet generated (cross_sprite.png was missing)")

    font_main = load_font(30)
    font_mode = load_font(24)
    os.makedirs(OUTDIR, exist_ok=True)
    write_frames(os.path.join(OUTDIR, "frames.bin"), sheet, font_main)
    for mode in MODES:
        write_frames(os.path.join(OUTDIR, f"frames_{mode}.bin"),
                     sheet, font_main, font_mode, mode)


if __name__ == "__main__":
    main()
