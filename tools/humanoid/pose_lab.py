# Clay contact sheets of humanoid clips, from Blender, outside the game.
#
#   blender -b -Y --python tools/humanoid/pose_lab.py -- <out dir> <clip> [<clip>@0,7,13 ...]
#
# <clip> alone: one sheet, <out dir>/<clip>.png, 8 moments across the clip
# (columns) by side / front / CRPG camera (rows), held weapons included.
# <clip>@0,7,13: those frames instead. Frame numbers are at 24 fps.

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab_setup as lab  # noqa: E402
import action_clips  # noqa: E402
from mathutils import Vector  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:]
OUT = ARGS[0]
NAMES = ARGS[1:]
os.makedirs(OUT, exist_ok=True)
FPS = 24
COLUMNS = 8
CELL = 300
VIEWS = [
    ((5, 0.0, 1.0), (0, 0.0, 0.95), 2.5),      # their left side
    ((0, -5, 1.0), (0, 0, 0.95), 2.5),         # from the front
    ((-2.4, -2.4, 3.6), (0, 0.0, 0.7), 2.6),   # the game's camera
]

arm, body, rig = lab.open_mannequin()
stage = lab.Stage(arm, body, rig, CELL)
stage.warm(os.path.join(OUT, "_warm.png"))


def _angle(a, b):
    d = math.degrees(a.rotation_difference(b).angle)
    return min(d, 360.0 - d)


def check(name, clip):
    """Things a picture hides. Reach: hand asked to go where the arm can't.
    Floor: a foot below the ground. Jump: one bone turning too far in one
    frame (a flip or an elbow snapping). Close: a loop's last frame vs first."""
    total = max(1, int(round(clip["length"] * FPS)))
    reach, floor, jump, last, first = (0, 0), (0, 0), (0, "", 0), None, None
    for f in range(total + 1):
        rig.solve(clip["at"](f / total))
        reach = max(reach, (max(rig.miss.values() or [0.0]), f))
        for side in "lr":
            ball = rig.P["ball_" + side]
            tip = ball @ Vector((0.0, rig.bones["ball_" + side].length, 0.0))
            floor = max(floor, (0.015 - ball.translation.z, f), (-tip.z, f))
        rots = {b: m.to_quaternion() for b, m in rig.P.items() if "_0" not in b or "spine" in b}
        if last is not None:
            for b, q in rots.items():
                d = _angle(q, last[b])
                if d > jump[0]:
                    jump = (d, b, f)
        last = rots
        first = first or rots
    close = 0.0
    if clip.get("loop"):
        close = max(_angle(q, first[b]) for b, q in last.items())
    print("CHECK %s reach_miss %.1f cm @%d | below_floor %.1f cm @%d | biggest_bone_step %.0f deg %s @%d | loop_close %.1f deg"
          % (name, reach[0] * 100, reach[1], floor[0] * 100, floor[1], jump[0], jump[1], jump[2], close), flush=True)


for request in NAMES:
    name, _, wanted = request.partition("@")
    clip = action_clips.CLIPS[name]
    total = max(1, int(round(clip["length"] * FPS)))
    last = total if not clip.get("loop") else total - 1
    frames = ([int(x) for x in wanted.split(",")] if wanted
              else [round(last * i / (COLUMNS - 1)) for i in range(COLUMNS)])
    weapons = clip.get("weapons")
    stage.show(weapons)
    rows = [[] for _ in VIEWS]
    for f in frames:
        stage.pose(clip["at"](f / total), weapons)
        for i, (loc, at, scale) in enumerate(VIEWS):
            path = os.path.join(OUT, "_v.png")
            stage.shoot(loc, at, scale, path)
            rows[i].append(lab.read_png(path))
    panels = [p for row in rows for p in row]
    lab.write_sheet(panels, len(frames), os.path.join(OUT, name + ".png"))
    print("LAB", name, "frames", frames, "of", total, flush=True)
    check(name, clip)
if os.path.exists(os.path.join(OUT, "_v.png")):
    os.remove(os.path.join(OUT, "_v.png"))
print("LAB OK")
