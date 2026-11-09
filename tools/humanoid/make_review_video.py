# Joins the frames from video_lab.py into one labelled review video: three
# views side by side, one-shots at full speed then half speed, loops twice.
#
#   python tools/humanoid/make_review_video.py <frames dir> <out.mp4> [<clip> ...]

import json
import os
import sys

import imageio_ffmpeg
from PIL import Image, ImageDraw, ImageFont

FRAMES, OUT = sys.argv[1], sys.argv[2]
ONLY = set(sys.argv[3:])
FPS = 24
CELL = 480
BAR = 64
VIEW_NAMES = ["SIDE", "FRONT", "GAME CAMERA"]
BG = (24, 26, 30)
FG = (236, 236, 232)
DIM = (150, 154, 162)
HOT = (255, 92, 60)
BIG = ImageFont.truetype("arialbd.ttf", 30)
SMALL = ImageFont.truetype("arial.ttf", 18)

manifest = json.load(open(os.path.join(FRAMES, "manifest.json"), encoding="utf-8"))
if ONLY:
    manifest = [c for c in manifest if c["name"] in ONLY]
WIDTH, HEIGHT = CELL * 3, CELL + BAR
writer = imageio_ffmpeg.write_frames(
    OUT, (WIDTH, HEIGHT), fps=FPS, codec="libx264", macro_block_size=2,
    output_params=["-crf", "25", "-preset", "medium", "-movflags", "+faststart"])
writer.send(None)


def panels(name, f):
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    for v in range(3):
        with Image.open(os.path.join(FRAMES, name, "v%d_%03d.png" % (v, f))) as p:
            img.paste(p.convert("RGB"), (v * CELL, BAR))
    draw = ImageDraw.Draw(img)
    for v in range(3):
        draw.text((v * CELL + 12, BAR + 10), VIEW_NAMES[v], font=SMALL, fill=FG)
    return img


def card(clip, index, count, f, speed, img):
    """The label bar over a copy of the panels: name, speed, timeline with its moments."""
    out = img.copy()
    draw = ImageDraw.Draw(out)
    total = clip["frames"]
    draw.text((16, 12), "%d/%d  %s" % (index, count, clip["name"]), font=BIG, fill=FG)
    kind = "loop" if clip["loop"] else "one-shot"
    draw.text((WIDTH * 0.42, 14), "%s  %s  %.2fs" % (clip["group"], kind, total / FPS), font=SMALL, fill=DIM)
    draw.text((WIDTH * 0.42, 36), "speed %s" % speed, font=SMALL, fill=DIM)
    left, right, y = int(WIDTH * 0.62), WIDTH - 24, 32
    span = right - left
    draw.line((left, y, right, y), fill=DIM, width=2)
    hot = False
    for frames in clip["moments"].values():
        for m in frames:
            x = left + span * m / total
            draw.line((x, y - 12, x, y + 12), fill=HOT, width=3)
            hot = hot or 0 <= f - m < 3
    x = left + span * f / total
    draw.ellipse((x - 7, y - 7, x + 7, y + 7), fill=HOT if hot else FG)
    if hot:
        draw.text((left, 2), "/".join(clip["moments"]).upper(), font=SMALL, fill=HOT)
    return out


def emit(img):
    writer.send(img.tobytes())


for i, clip in enumerate(manifest):
    name, total = clip["name"], clip["frames"]
    count = total if clip["loop"] else total + 1
    made = [panels(name, f) for f in range(count)]
    if clip["loop"]:
        repeats = 1 if total >= 5 * FPS else (2 if total >= 2 * FPS else 3)
        for _ in range(repeats):
            for f in range(count):
                emit(card(clip, i + 1, len(manifest), f, "1x", made[f]))
    else:
        for f in range(count):
            emit(card(clip, i + 1, len(manifest), f, "1x", made[f]))
        for _ in range(10):
            emit(card(clip, i + 1, len(manifest), count - 1, "1x", made[-1]))
        for f in range(count):
            for _ in range(2):
                emit(card(clip, i + 1, len(manifest), f, "half", made[f]))
        for _ in range(12):
            emit(card(clip, i + 1, len(manifest), count - 1, "half", made[-1]))
    print("JOINED", name, flush=True)
writer.close()
print("VIDEO", OUT, os.path.getsize(OUT) / (1024 * 1024), "MiB")
