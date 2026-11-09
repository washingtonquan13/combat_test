# Renders every frame of the humanoid clips from three cameras, for the review
# video. Run several of these at once, then tools/humanoid/make_review_video.py:
#
#   blender -b -Y --python tools/humanoid/video_lab.py -- <out dir> <worker> <workers> [<clip> ...]

import importlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_setup as lab  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:]
OUT, WORKER, WORKERS = ARGS[0], int(ARGS[1]), int(ARGS[2])
ONLY = set(ARGS[3:])
FPS = 24
CELL = 480
GROUPS = ["base", "locomotion", "melee", "ranged", "magic", "travel"]
VIEWS = [
    ((5, 0.0, 1.0), (0, 0.0, 1.0), 3.0),
    ((0, -5, 1.0), (0, 0, 1.0), 3.0),
    ((-2.4, -2.4, 3.6), (0, 0.0, 0.75), 3.2),
]

clips = {}
order = []
for group in GROUPS:
    try:
        found = importlib.import_module("clips_" + group).CLIPS
    except ModuleNotFoundError:
        continue
    for name, clip in found.items():
        if name != "stance":
            clips[name] = clip
            order.append((group, name))

if WORKER == 0:
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump([{
            "group": group,
            "name": name,
            "frames": max(1, int(round(clips[name]["length"] * FPS))),
            "loop": bool(clips[name].get("loop")),
            "moments": clips[name].get("moments", {}),
        } for group, name in order], fh, indent=1)

arm, body, rig = lab.open_mannequin()
stage = lab.Stage(arm, body, rig, CELL)
os.makedirs(OUT, exist_ok=True)
stage.warm(os.path.join(OUT, "_warm_%d.png" % WORKER))

job = 0
for group, name in order:
    clip = clips[name]
    total = max(1, int(round(clip["length"] * FPS)))
    count = total if clip.get("loop") else total + 1
    folder = os.path.join(OUT, name)
    os.makedirs(folder, exist_ok=True)
    weapons = clip.get("weapons")
    if not ONLY or name in ONLY:
        stage.show(weapons)
        for f in range(count):
            job += 1
            if job % WORKERS != WORKER:
                continue
            stage.pose(clip["at"](f / total), weapons)
            for v, (loc, at, scale) in enumerate(VIEWS):
                stage.shoot(loc, at, scale, os.path.join(folder, "v%d_%03d.png" % (v, f)))
        print("VIDEO", WORKER, name, flush=True)
print("VIDEO OK", WORKER, flush=True)
