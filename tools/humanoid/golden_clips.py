# Clips made from golden poses (golden_poses.py): each key is a whole drawn
# body, set on a timing sheet, and the motion between keys comes from per-joint
# curves. Parts of the body arrive at their own times (overlap): the hips lead,
# the chest and head follow, the limbs trail.
#
# Nothing here is blended out of one base pose. The sheet is the whole clip.

import motion as m
from golden_poses import GOLDEN

FPS = m.FPS


def _with_pole(foot, side):
    """A planted foot written with the knee direction the rig would pick, so a
    planted key and a hung key share the same channels and can be curved between."""
    if "pole" in foot:
        return foot
    s = 1.0 if side == "l" else -1.0
    turn = m._rot(*foot["rot"])
    return dict(foot, pole=tuple(turn @ m.Vector((-s * 0.08, -1.0, 0.0))))


# Where each ball stays while its foot is on the floor.
BALLS = {"l": (0.118, -0.165), "r": (-0.128, -0.085)}


def _rolled(keys, frames, f, side):
    """A foot on the floor between planted keys: the ball stays put and the heel
    rolls up round it, so the ankle travels an arc, never a chord into the floor."""
    heel, roll, yaw = (m.once([k["rot"][i] for k in keys], frames, f) for i in range(3))
    return _with_pole(m.plant(*BALLS[side], heel=heel, yaw=yaw, roll=roll), side)


def _key(name):
    return _hip_relative(GOLDEN[name])


def _hip_relative(pose):
    """Feet written as offsets from the hips. A leg that rides the bob late then
    changes shape late, rather than its foot being left behind in the world,
    which would ask the leg to reach past its length and snap the knee straight."""
    hip = pose["hip"]
    feet = {}
    for s, f in pose["feet"].items():
        f = _with_pole(f, s)
        feet[s] = dict(f, at=tuple(a - h for a, h in zip(f["at"], hip)))
    return dict(pose, feet=feet)


def _placed(pose):
    """Back from hip-relative feet to world, under where the hips are now."""
    hip = pose["hip"]
    pose["feet"] = {s: dict(f, at=tuple(a + h for a, h in zip(f["at"], hip))) for s, f in pose["feet"].items()}
    return pose


# ---- Hover ------------------------------------------------------------------
# Three bobs in the loop, bottom to top and back. The hips carry the bob; the
# chest, head, legs and arms ride it late by their own amounts, the hanging
# left leg latest and the hands after everything, so the body reads as carried
# and the limbs as weight hanging off it.

HOVER_SECONDS = 6.0
BOBS = 3
# Lag as fractions of the loop (one bob is a third of it).
HOVER_LAG = {
    "hip": 0.0, "hip_rot": 0.012, "chest_rot": 0.025, "look": 0.04,
    "feet": {"l": 0.05, "r": 0.03},
    "hands": {"l": 0.06, "r": 0.075},
}

_HOVER_KEYS, _HOVER_TIMES = [], []
for b in range(BOBS):
    _HOVER_KEYS += [_key("Hover_Down"), _key("Hover_Up")]
    _HOVER_TIMES += [b / BOBS, (b + 0.5) / BOBS]

_HOVER_LOOP = m.loop(_HOVER_KEYS, _HOVER_TIMES, HOVER_SECONDS, HOVER_LAG)
HOVER = dict(_HOVER_LOOP, at=lambda t: _placed(_HOVER_LOOP["at"](t)))


# ---- Takeoff ----------------------------------------------------------------
# Timing sheet. (frame, golden pose). The dip is quick, the drive and push are
# the fast part, then the rise carries past the hover to the peak and floats
# down into the loop's first frame.

TAKEOFF_SHEET = [
    (0, "Takeoff_Stance"),
    (4, "Takeoff_Dip"),
    (8, "Takeoff_Drive"),
    (11, "Takeoff_Push"),
    (15, "Takeoff_Rise"),
    (21, "Takeoff_Peak"),
    (30, None),  # the hover loop's first frame, so the two clips join
]
# Lag in frames. The feet carry no lag while either is on the floor; the
# planted foot must stay where it is put.
TAKEOFF_LAG = {
    "hip": 0.0, "hip_rot": 0.4, "chest_rot": 1.0, "look": 1.6,
    "feet": {"l": 0.6, "r": 0.0},
    "hands": {"l": 1.4, "r": 1.8},
}


def _takeoff():
    end = HOVER["at"](0.0)
    keys = [_key(n) if n else _hip_relative(end) for _, n in TAKEOFF_SHEET]
    frames = [f for f, _ in TAKEOFF_SHEET]
    count = frames[-1]

    def at(t):
        f = t * count
        pose = _placed(m.between(keys, frames, f, TAKEOFF_LAG, m.spline))
        # The right foot is on the floor until the push leaves it: hold its key
        # positions exactly with a monotone curve, no overshoot under the floor.
        if f <= frames[3]:
            pose["feet"]["r"] = _rolled([k["feet"]["r"] for k in keys[:4]], frames[:4], f, "r")
        if f <= frames[1]:
            pose["feet"]["l"] = _rolled([k["feet"]["l"] for k in keys[:2]], frames[:2], f, "l")
        return pose

    return {"length": count / FPS, "at": at}


TAKEOFF = _takeoff()

CLIPS = {"Hover": HOVER, "Takeoff": TAKEOFF}
