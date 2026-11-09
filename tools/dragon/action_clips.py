# The dragon's action clips, every one solved from the rest pose and starting
# and ending on the stance (poses.py).
#
# A one-shot is a list of key poses at frames. A pose here is what body_rig.py
# reads, except the wing is given as wing_a, the angles of the spread wing, and
# wing_k, how far it has opened out of the fold (0 shut, 1 spread).

import math

import poses
from poses import HOVER_TIMES, STANCE, TAKEOFF_WING, TAKEOFF_WING_LAG, _between, _once, _scaled, hover_at, open_wing, wing_unfold

FLARE = TAKEOFF_WING[0]
POSES = poses.POSES

# In frames. The body throws itself and the ends catch up.
ACTION_LAG = {
    "hip": 0.0, "back": 0.2, "chest": 0.3, "chest_rot": 0.4,
    "neck": [0.4, 0.6, 0.8], "head": 1.0, "look": 1.2,
    "tail": [1.0, 2.0, 3.0, 4.0],
}
# A strike is led by the thing striking: the skull arrives first, the body behind it.
HEAD_LEADS = {
    "hip": 0.8, "back": 0.6, "chest": 0.5, "chest_rot": 0.5,
    "neck": [0.3, 0.2, 0.1], "head": 0.0, "look": 0.0,
    "tail": [1.0, 2.0, 3.0, 4.0],
}


def _k(**changes):
    """A key pose: the stance, mouth shut, with these parts changed."""
    return {**{k: v for k, v in STANCE.items() if k != "wing"}, "jaw": 0.0, "lip": 0.0, "wing_a": FLARE, "wing_k": 0.0, **changes}


def _feet(**changes):
    """The stance's feet with these ones moved."""
    return dict(STANCE["feet"], **changes)


def _wing_at(keys, frames, f, fade, late, side):
    """One wing through the keys. A key can give a side its own wing_a_L or wing_k_R."""
    u = f - late * fade
    angles = [k.get("wing_a_" + side, k["wing_a"]) for k in keys]
    spread = open_wing(**_between(angles, frames, u, _scaled(TAKEOFF_WING_LAG, fade), _once))
    k = _once([k.get("wing_k_" + side, k["wing_k"]) for k in keys], frames, u)
    return spread if k >= 1.0 else wing_unfold(STANCE["wing"], spread, k)


def one_shot(keys, frames, lag=ACTION_LAG, moments=None):
    """A clip through the keys. Its lags close up at the end, so it finishes exactly on the last key."""
    length = frames[-1]
    names = [n for n in keys[0] if not n.startswith("wing")]

    def at(t):
        f = t * length
        fade = min(1.0, (length - f) / 6.0)
        out = {n: _between([k[n] for k in keys], frames, f, _scaled(lag.get(n, 0.0), fade), _once) for n in names}
        out["wing_L"] = _wing_at(keys, frames, f, fade, 0.0, "L")
        out["wing_R"] = _wing_at(keys, frames, f, fade, 0.3, "R")
        return out
    return {"length": length / 24.0, "at": at, "moments": moments or {}}


# --- Bite -------------------------------------------------------------------
# The neck draws up and back over planted forepaws with the mouth opening, hangs
# there long enough to read from the CRPG camera, then the head goes in first and
# the body follows it. The jaws snap on the impact frame and it tugs.

BITE_COIL = _k(
    hip=(0.0, 0.25, 0.275), back=[(0.0, 0.09, 0.31)], chest=(0.0, -0.075, 0.262), chest_rot=(-8, 0, 0),
    neck=[(0.0, -0.215, 0.345), (0.0, -0.225, 0.42), (0.0, -0.265, 0.46)],
    head=(0.0, -0.29, 0.475), look=(0.0, -1.0, 0.05),
    tail=[(0.0, 0.46, 0.22), (0.06, 0.75, 0.10), (0.22, 1.07, 0.03), (0.47, 1.30, 0.03)],
    jaw=24.0, lip=8.0, wing_k=0.2,
)
BITE_TOP = dict(BITE_COIL, head=(0.0, -0.285, 0.482), look=(0.0, -1.0, 0.1), jaw=38.0, lip=10.0, wing_k=0.25,
                neck=[(0.0, -0.215, 0.348), (0.0, -0.222, 0.425), (0.0, -0.26, 0.468)])
BITE_STRIKE = _k(
    hip=(0.0, 0.14, 0.255), back=[(0.0, 0.0, 0.27)], chest=(0.0, -0.19, 0.205), chest_rot=(16, 0, 0),
    neck=[(0.0, -0.33, 0.19), (0.0, -0.42, 0.19), (0.0, -0.50, 0.20)],
    head=(0.0, -0.545, 0.20), look=(0.0, -1.0, -0.22),
    tail=[(0.03, 0.35, 0.18), (0.16, 0.62, 0.06), (0.42, 0.90, 0.03), (0.72, 1.05, 0.03)],
    wing_k=0.12,
)
BITE_REACH = dict(BITE_STRIKE, jaw=44.0, lip=14.0,
                  head=(0.0, -0.50, 0.255), look=(0.0, -1.0, -0.12),
                  neck=[(0.0, -0.31, 0.215), (0.0, -0.39, 0.235), (0.0, -0.46, 0.25)])
BITE_TUG = _k(
    hip=(0.0, 0.165, 0.26), back=[(0.0, 0.02, 0.275)], chest=(0.0, -0.17, 0.215), chest_rot=(12, 0, 0),
    neck=[(0.02, -0.315, 0.20), (0.04, -0.40, 0.205), (0.05, -0.48, 0.215)],
    head=(0.06, -0.52, 0.215), look=(0.35, -1.0, -0.15),
    tail=[(0.02, 0.37, 0.185), (0.10, 0.66, 0.06), (0.30, 0.96, 0.03), (0.58, 1.14, 0.03)],
)

_BITE = one_shot([_k(), BITE_COIL, BITE_TOP, BITE_REACH, BITE_STRIKE, BITE_STRIKE, BITE_TUG, _k()],
                 [0, 7, 10, 12, 13, 15, 19, 32], HEAD_LEADS, {"impact": [13]})


# --- Claw -------------------------------------------------------------------
# Weight rolls onto the left legs, the right forepaw comes up and out and hangs,
# then rakes down and across. The paw is lifted home so it doesn't slide.

_CLAW_LEAN = dict(
    hip=(0.012, 0.235, 0.27), back=[(0.02, 0.08, 0.305)], chest=(0.03, -0.09, 0.27), chest_rot=(-4, -4, 5),
    neck=[(0.03, -0.235, 0.31), (0.02, -0.28, 0.375), (0.01, -0.32, 0.43)],
    head=(0.03, -0.355, 0.455), look=(0.22, -1.0, -0.08),
)
CLAW_LIFT = _k(feet=_feet(Hand_R={"at": (-0.12, -0.21, 0.10), "rot": (-10, -10, 0)}), wing_k=0.15, jaw=8.0, **_CLAW_LEAN)
CLAW_RAISED = _k(
    feet=_feet(Hand_R={"at": (-0.17, -0.29, 0.32), "rot": (-30, -15, 0)}),
    tail=[(0.0, 0.44, 0.20), (0.04, 0.73, 0.09), (0.16, 1.05, 0.03), (0.38, 1.28, 0.03)],
    wing_k=0.3, jaw=22.0, lip=8.0, **_CLAW_LEAN)
CLAW_HANG = dict(CLAW_RAISED, feet=_feet(Hand_R={"at": (-0.18, -0.27, 0.345), "rot": (-38, -15, 0)}), jaw=26.0, lip=10.0)
CLAW_STRIKE = _k(
    hip=(0.0, 0.155, 0.255), back=[(0.0, 0.01, 0.272)], chest=(0.0, -0.175, 0.215), chest_rot=(14, 3, -6),
    neck=[(-0.01, -0.315, 0.215), (-0.025, -0.385, 0.235), (-0.03, -0.44, 0.26)],
    head=(-0.03, -0.475, 0.28), look=(-0.2, -1.0, -0.3),
    feet=_feet(Hand_R={"at": (-0.02, -0.44, 0.06), "rot": (60, 30, 0)}),
    tail=[(0.04, 0.35, 0.18), (0.20, 0.62, 0.06), (0.47, 0.88, 0.03), (0.78, 1.02, 0.03)],
    wing_k=0.15, jaw=14.0,
)
CLAW_FOLLOW = dict(CLAW_STRIKE, chest=(0.02, -0.17, 0.215), chest_rot=(13, 6, -8),
                   feet=_feet(Hand_R={"at": (0.03, -0.39, 0.04), "rot": (72, 35, 0)}),
                   head=(0.0, -0.47, 0.27), look=(0.05, -1.0, -0.28),
                   neck=[(0.01, -0.31, 0.215), (0.005, -0.38, 0.235), (0.0, -0.435, 0.255)])
CLAW_RETURN = _k(
    hip=(0.0, 0.20, 0.262), back=[(0.0, 0.05, 0.29)], chest=(0.01, -0.13, 0.235), chest_rot=(8, 2, -2),
    neck=[(0.005, -0.28, 0.25), (0.005, -0.335, 0.30), (0.008, -0.375, 0.355)],
    head=(0.012, -0.415, 0.375), look=(0.08, -1.0, -0.2),
    feet=_feet(Hand_R={"at": (-0.09, -0.26, 0.085), "rot": (20, -4, 0)}),
    wing_k=0.05,
)

_CLAW = one_shot([_k(), CLAW_LIFT, CLAW_RAISED, CLAW_HANG, CLAW_STRIKE, CLAW_FOLLOW, CLAW_RETURN, _k()],
                 [0, 5, 10, 12, 15, 18, 25, 34], ACTION_LAG, {"impact": [15]})


# --- Breath -----------------------------------------------------------------
# Draws in with the neck up and the wings part open, drives the head down and
# forward, and holds. The mouth ends where the game's Mouth node is.

BREATH_DRAW = _k(
    hip=(0.0, 0.24, 0.275), back=[(0.0, 0.085, 0.315)], chest=(0.0, -0.085, 0.27), chest_rot=(-10, 0, 0),
    neck=[(0.0, -0.215, 0.35), (0.0, -0.235, 0.425), (0.0, -0.27, 0.48)],
    head=(0.0, -0.30, 0.50), look=(0.0, -1.0, 0.2),
    tail=[(0.0, 0.45, 0.22), (0.07, 0.74, 0.10), (0.24, 1.06, 0.03), (0.50, 1.28, 0.03)],
    jaw=6.0, lip=2.0, wing_k=0.35,
)
BREATH_DEEP = dict(BREATH_DRAW, chest=(0.0, -0.083, 0.276), head=(0.0, -0.295, 0.508), look=(0.0, -1.0, 0.26), jaw=10.0, wing_k=0.42)
BREATH_FIRE = _k(
    hip=(0.0, 0.19, 0.262), back=[(0.0, 0.03, 0.275)], chest=(0.0, -0.135, 0.225), chest_rot=(10, 0, 0),
    neck=[(0.0, -0.31, 0.225), (0.0, -0.375, 0.22), (0.0, -0.43, 0.215)],
    head=(0.0, -0.47, 0.21), look=(0.0, -1.0, -0.2),
    tail=[(0.02, 0.39, 0.19), (0.12, 0.68, 0.07), (0.34, 0.98, 0.03), (0.64, 1.15, 0.03)],
    jaw=42.0, lip=14.0, wing_k=0.25,
)
BREATH_DRIVE = dict(BREATH_FIRE, head=(0.0, -0.455, 0.25), look=(0.0, -1.0, -0.08), jaw=20.0, lip=8.0,
                    neck=[(0.0, -0.30, 0.25), (0.0, -0.365, 0.255), (0.0, -0.42, 0.25)])

_BREATH = one_shot([_k(), BREATH_DRAW, BREATH_DEEP, BREATH_DRIVE, BREATH_FIRE],
                   [0, 8, 13, 17, 20], HEAD_LEADS, {"release": [19]})

_FIRE = {n: v for n, v in BREATH_FIRE.items() if n not in ("wing_a", "wing_k")}
_FIRE_WING = wing_unfold(STANCE["wing"], open_wing(**FLARE), BREATH_FIRE["wing_k"])


def breath_hold_at(t):
    """The fire going: the neck rides the recoil, the mouth works, both zero at the seam."""
    a = math.sin(2.0 * math.pi * t)
    b = math.sin(4.0 * math.pi * t)
    out = dict(_FIRE)
    out["neck"] = [(x + 0.010 * a, y, z + 0.004 * b) for x, y, z in _FIRE["neck"]]
    out["head"] = (_FIRE["head"][0] + 0.016 * a, _FIRE["head"][1], _FIRE["head"][2] + 0.006 * b)
    out["look"] = (_FIRE["look"][0] + 0.04 * a, _FIRE["look"][1], _FIRE["look"][2] + 0.02 * b)
    out["jaw"] = _FIRE["jaw"] + 3.0 * b
    out["lip"] = _FIRE["lip"] + 1.5 * b
    out["chest"] = (_FIRE["chest"][0], _FIRE["chest"][1], _FIRE["chest"][2] + 0.003 * b)
    out["wing_L"] = out["wing_R"] = _FIRE_WING
    return out


_BREATH_EASE = _k(
    hip=(0.0, 0.215, 0.266), back=[(0.0, 0.055, 0.292)], chest=(0.0, -0.115, 0.24), chest_rot=(8, 0, 0),
    neck=[(0.0, -0.285, 0.25), (0.0, -0.345, 0.285), (0.0, -0.395, 0.325)],
    head=(0.0, -0.435, 0.335), look=(0.04, -1.0, -0.18),
    tail=[(0.02, 0.41, 0.19), (0.12, 0.70, 0.07), (0.33, 1.0, 0.03), (0.63, 1.18, 0.03)],
    jaw=8.0, lip=3.0, wing_k=0.12,
)
_BREATH_OUT = one_shot([BREATH_FIRE, _BREATH_EASE, _k()], [0, 6, 16])


# --- Walk -------------------------------------------------------------------
# A slow lateral sequence, low and heavy. Each foot that lands takes the weight:
# the shoulders and the pelvis each lean over their planted foot a quarter cycle
# apart, so the back bends as a wave from the neck to the tail tip. The feet
# travel at the game's move speed while planted (stride / (duty * length) = 0.79
# model units a second against the game's 0.8), so they barely skate.

WALK_FRAMES = 22
_WALK_DUTY = 0.55
_WALK_STRIDE = 0.40
_WALK_LIFT = 0.085
_WALK_FEET = {
    # name: phase, x, centre y, ground height, yaw
    "back_food_L": (0.0, 0.098, 0.21, 0.1016, 5.0),
    "Hand_L": (0.25, 0.108, -0.14, 0.0165, 8.0),
    "back_food_R": (0.5, -0.098, 0.21, 0.1016, -5.0),
    "Hand_R": (0.75, -0.104, -0.14, 0.0165, -6.0),
}
_WALK_TAIL = [(0.0, 0.43, 0.215), (0.0, 0.72, 0.125), (0.0, 1.02, 0.07), (0.0, 1.30, 0.05)]
# How far each tail joint swings, and when it is furthest left: a wave running
# on from the pelvis, about one body length from crest to crest.
_WALK_TAIL_SWING = [0.024, 0.075, 0.15, 0.23]
_WALK_TAIL_PEAK = [0.445, 0.70, 0.98, 1.25]
_WALK_HIP_PEAK = 0.275  # mid-stance on the left hind foot
_WALK_CHEST_PEAK = 0.025  # mid-stance on the left forefoot


def _smooth(u):
    return u * u * (3.0 - 2.0 * u)


def _wave(t, peak):
    return math.cos(2.0 * math.pi * (t - peak))


def _beat(t, peak):
    return math.cos(4.0 * math.pi * (t - peak))


def _walk_foot(t, phase, x, centre, ground, yaw):
    p = (t + phase) % 1.0
    back = centre + _WALK_STRIDE * 0.5
    # The hind foot's ankle stands high, so its toes need more room to tip down.
    rise = 0.04 + 0.5 * ground
    if p < _WALK_DUTY:
        u = p / _WALK_DUTY
        y = centre - _WALK_STRIDE * 0.5 + _WALK_STRIDE * u
        peel = max(0.0, (u - 0.8) / 0.2)
        settle = max(0.0, 1.0 - u / 0.08)
        return {"at": (x, y, ground + rise * peel * peel), "rot": (40.0 * peel * peel - 12.0 * settle, yaw, 0.0)}
    v = (p - _WALK_DUTY) / (1.0 - _WALK_DUTY)
    y = back - _WALK_STRIDE * _smooth(v)
    z = ground + rise * (1.0 - v) + _WALK_LIFT * math.sin(math.pi * v)
    return {"at": (x, y, z), "rot": (40.0 - 52.0 * _smooth(v), yaw, 0.0)}


def walk_at(t):
    hip_x = 0.034 * _wave(t, _WALK_HIP_PEAK)
    chest_x = 0.04 * _wave(t, _WALK_CHEST_PEAK)
    # Each end drops onto the foot that has just landed and rises over it.
    hip_z = 0.262 + 0.013 * _beat(t, 0.30)
    chest_z = 0.232 + 0.013 * _beat(t, 0.05)
    surge = 0.008 * _beat(t, 0.18)
    head_x = -0.02 * _wave(t, 0.11)
    bob = 0.015 * _beat(t, 0.14)
    neck_y_z = [(-0.255, 0.265), (-0.315, 0.315), (-0.365, 0.365)]
    neck = [(chest_x + (head_x - chest_x) * s, y + surge, z + bob * s)
            for s, (y, z) in zip((0.3, 0.62, 0.86), neck_y_z)]
    tail = [(swing * _wave(t, peak), y, z + 0.008 * _beat(t, 0.30 + 0.08 * (i + 1)))
            for i, ((_, y, z), swing, peak) in enumerate(zip(_WALK_TAIL, _WALK_TAIL_SWING, _WALK_TAIL_PEAK))]
    spread = open_wing(**FLARE)
    return {
        "hip": (hip_x, 0.225 + surge, hip_z),
        "back": [((hip_x + chest_x) * 0.5 + 0.014 * _wave(t, 0.15), 0.07 + surge, 0.293 + 0.5 * (hip_z - 0.262 + chest_z - 0.232))],
        "chest": (chest_x, -0.10 + surge, chest_z),
        "chest_rot": (6.0, 10.0 * math.sin(2.0 * math.pi * t), 6.0 * _wave(t, _WALK_CHEST_PEAK)),
        "neck": neck,
        "head": (head_x, -0.41 + surge, 0.382 + bob),
        "look": (-0.16 * _wave(t, 0.11), -1.0, -0.2 + 0.05 * _beat(t, 0.14)),
        "feet": {name: _walk_foot(t, *foot) for name, foot in _WALK_FEET.items()},
        "tail": tail,
        "wing_L": wing_unfold(STANCE["wing"], spread, 0.05 + 0.03 * (0.5 + 0.5 * _beat(t, 0.12))),
        "wing_R": wing_unfold(STANCE["wing"], spread, 0.05 + 0.03 * (0.5 + 0.5 * _beat(t, 0.15))),
    }


# --- Hit --------------------------------------------------------------------
# Struck from the front: the head and chest snap back and away, the wings jolt,
# and it settles. The feet stay planted.

HIT_RECOIL = _k(
    hip=(0.0, 0.25, 0.275), back=[(0.0, 0.095, 0.315)], chest=(0.0, -0.07, 0.262), chest_rot=(-6, -4, -4),
    neck=[(-0.01, -0.215, 0.33), (-0.02, -0.235, 0.40), (-0.025, -0.27, 0.45)],
    head=(-0.03, -0.31, 0.47), look=(-0.25, -1.0, 0.2),
    tail=[(0.0, 0.46, 0.215), (0.08, 0.75, 0.095), (0.27, 1.06, 0.03), (0.56, 1.26, 0.03)],
    jaw=20.0, lip=6.0, wing_k=0.25,
)
HIT_SAG = _k(
    hip=(0.0, 0.232, 0.262), back=[(0.0, 0.075, 0.295)], chest=(0.0, -0.095, 0.242), chest_rot=(7, -1, -1),
    neck=[(-0.005, -0.245, 0.265), (-0.008, -0.30, 0.325), (-0.01, -0.345, 0.38)],
    head=(-0.01, -0.385, 0.395), look=(0.0, -1.0, -0.22),
    jaw=6.0, wing_k=0.08,
)
_HIT = one_shot([_k(), HIT_RECOIL, HIT_RECOIL, HIT_SAG, _k()], [0, 3, 5, 9, 16], ACTION_LAG)


# --- Knockdown and getting up -----------------------------------------------
# Thrown onto its belly with the legs splayed. Get_Up starts on that sprawl and
# plants each paw on the way back to the stance.

_SPRAWL_FEET = {
    "Hand_L": {"at": (0.21, -0.265, 0.0165), "rot": (0, 24, 0)},
    "Hand_R": {"at": (-0.20, -0.235, 0.0165), "rot": (0, -22, 0)},
    "back_food_L": {"at": (0.20, 0.30, 0.1016), "rot": (0, 22, 0)},
    "back_food_R": {"at": (-0.20, 0.29, 0.1016), "rot": (0, -20, 0)},
}
_SPRAWL_WING = {"lift": 18, "sweep": -10, "twist": -8, "elbow": 20, "wrist": -34, "back": 12, "fan": 0.55}
SPRAWL = _k(
    hip=(0.0, 0.235, 0.125), back=[(0.0, 0.075, 0.145)], chest=(0.0, -0.09, 0.115), chest_rot=(4, 3, -5),
    neck=[(0.015, -0.235, 0.12), (0.05, -0.30, 0.125), (0.09, -0.355, 0.125)],
    head=(0.125, -0.39, 0.115), look=(0.45, -1.0, -0.12),
    feet=_SPRAWL_FEET,
    tail=[(0.03, 0.44, 0.10), (0.15, 0.72, 0.05), (0.38, 1.0, 0.03), (0.68, 1.18, 0.03)],
    jaw=10.0, lip=2.0, wing_k=0.55, wing_a=_SPRAWL_WING,
)
_KD_THROWN = _k(
    hip=(0.0, 0.26, 0.285), back=[(0.0, 0.105, 0.325)], chest=(0.0, -0.06, 0.268), chest_rot=(-10, -5, -7),
    neck=[(-0.015, -0.20, 0.345), (-0.03, -0.215, 0.42), (-0.03, -0.25, 0.475)],
    head=(-0.035, -0.285, 0.50), look=(-0.3, -1.0, 0.35),
    tail=[(0.0, 0.49, 0.235), (0.08, 0.78, 0.13), (0.28, 1.08, 0.05), (0.56, 1.3, 0.03)],
    jaw=32.0, lip=10.0, wing_k=0.65,
)
_KD_FALLING = _k(
    hip=(0.0, 0.25, 0.20), back=[(0.0, 0.09, 0.225)], chest=(0.0, -0.075, 0.20), chest_rot=(0, 2, -6),
    neck=[(0.0, -0.225, 0.235), (0.025, -0.285, 0.275), (0.05, -0.34, 0.30)],
    head=(0.075, -0.375, 0.30), look=(0.3, -1.0, -0.05),
    feet={
        "Hand_L": {"at": (0.16, -0.25, 0.05), "rot": (0, 16, 0)},
        "Hand_R": {"at": (-0.15, -0.22, 0.05), "rot": (0, -15, 0)},
        "back_food_L": {"at": (0.15, 0.27, 0.13), "rot": (0, 14, 0)},
        "back_food_R": {"at": (-0.15, 0.26, 0.13), "rot": (0, -13, 0)},
    },
    tail=[(0.015, 0.47, 0.17), (0.08, 0.76, 0.10), (0.26, 1.05, 0.05), (0.55, 1.26, 0.03)],
    jaw=24.0, lip=6.0, wing_k=0.7, wing_a=_SPRAWL_WING,
)
_KD_SLAM = dict(SPRAWL, hip=(0.0, 0.235, 0.112), back=[(0.0, 0.075, 0.13)], chest=(0.0, -0.09, 0.10),
                head=(0.13, -0.395, 0.095), jaw=26.0, wing_k=0.62,
                neck=[(0.015, -0.235, 0.105), (0.05, -0.30, 0.105), (0.09, -0.355, 0.10)])
_KD_BOUNCE = dict(SPRAWL, hip=(0.0, 0.235, 0.14), back=[(0.0, 0.075, 0.165)], chest=(0.0, -0.09, 0.135),
                  head=(0.125, -0.39, 0.15), jaw=14.0, wing_k=0.5,
                  neck=[(0.015, -0.235, 0.14), (0.05, -0.30, 0.155), (0.09, -0.355, 0.155)])
_KNOCKDOWN = one_shot([_k(), _KD_THROWN, _KD_FALLING, _KD_SLAM, _KD_BOUNCE, SPRAWL], [0, 4, 11, 15, 19, 26], ACTION_LAG)


def _feet_mix(**changes):
    return dict(_SPRAWL_FEET, **changes)


# The head comes up first, each forepaw is dragged in under its shoulder, then
# the forelegs press the chest up with the hindquarters still on the floor like
# a dog sitting. The weight goes forward over the paws, the hind feet come in
# one at a time, and the wings press down as the hips heave up past standing
# and settle.

_STAND = STANCE["feet"]
_UP_PUSH = {"lift": 6, "sweep": -12, "twist": -10, "elbow": 14, "wrist": -30, "back": 14, "fan": 0.6}
_UP_LOOK = _k(
    hip=(0.0, 0.235, 0.118), back=[(0.0, 0.075, 0.14)], chest=(0.0, -0.09, 0.135), chest_rot=(-4, 1, -2),
    neck=[(0.01, -0.225, 0.20), (0.02, -0.27, 0.27), (0.03, -0.31, 0.33)],
    head=(0.045, -0.35, 0.355), look=(0.18, -1.0, 0.12),
    feet=_feet_mix(Hand_L={"at": (0.17, -0.255, 0.085), "rot": (-14, 15, 0)}),
    tail=SPRAWL["tail"], jaw=6.0, lip=2.0, wing_k=0.45, wing_a=_SPRAWL_WING,
)
_UP_PAW = _k(
    hip=(0.0, 0.235, 0.116), back=[(0.0, 0.075, 0.142)], chest=(0.012, -0.09, 0.152), chest_rot=(0, -1, 4),
    neck=[(0.012, -0.235, 0.20), (0.02, -0.295, 0.25), (0.025, -0.34, 0.285)],
    head=(0.03, -0.375, 0.30), look=(0.1, -1.0, -0.1),
    feet=_feet_mix(Hand_L={"at": (0.125, -0.235, 0.0165), "rot": (0, 10, 0)},
                   Hand_R={"at": (-0.16, -0.22, 0.085), "rot": (-14, -14, 0)}),
    tail=SPRAWL["tail"], jaw=4.0, wing_k=0.5, wing_a=_SPRAWL_WING,
)
_UP_BRACE = _k(
    hip=(0.0, 0.232, 0.112), back=[(0.0, 0.075, 0.14)], chest=(0.0, -0.09, 0.172), chest_rot=(4, 0, 0),
    neck=[(0.0, -0.245, 0.195), (0.005, -0.305, 0.225), (0.01, -0.35, 0.255)],
    head=(0.01, -0.385, 0.268), look=(0.0, -1.0, -0.3),
    feet=_feet_mix(Hand_L={"at": (0.125, -0.235, 0.0165), "rot": (0, 10, 0)},
                   Hand_R={"at": (-0.12, -0.185, 0.0165), "rot": (0, -8, 0)}),
    tail=[(0.03, 0.44, 0.09), (0.15, 0.72, 0.05), (0.38, 1.0, 0.03), (0.68, 1.18, 0.03)],
    jaw=14.0, lip=4.0, wing_k=0.62, wing_a=_SPRAWL_WING,
)
_UP_PRESS = _k(
    hip=(0.0, 0.212, 0.125), back=[(0.0, 0.07, 0.20)], chest=(0.0, -0.075, 0.27), chest_rot=(-18, 0, 0),
    neck=[(0.0, -0.17, 0.355), (0.0, -0.195, 0.43), (0.0, -0.235, 0.49)],
    head=(0.0, -0.27, 0.525), look=(0.0, -1.0, 0.18),
    feet=_feet_mix(Hand_L={"at": (0.125, -0.235, 0.0165), "rot": (0, 10, 0)},
                   Hand_R={"at": (-0.12, -0.185, 0.0165), "rot": (0, -8, 0)}),
    tail=[(0.03, 0.42, 0.10), (0.14, 0.70, 0.05), (0.36, 0.98, 0.03), (0.66, 1.16, 0.03)],
    jaw=30.0, lip=10.0, wing_k=0.56, wing_a=_UP_PUSH,
)
_UP_FORWARD = _k(
    hip=(0.0, 0.185, 0.15), back=[(0.0, 0.03, 0.225)], chest=(0.0, -0.125, 0.255), chest_rot=(-4, 0, 0),
    neck=[(0.0, -0.25, 0.30), (0.0, -0.31, 0.345), (0.0, -0.36, 0.36)],
    head=(0.0, -0.40, 0.36), look=(0.0, -1.0, -0.18),
    feet={"Hand_L": _STAND["Hand_L"], "Hand_R": _STAND["Hand_R"],
          "back_food_L": {"at": (0.14, 0.255, 0.18), "rot": (-14, 12, 0)}, "back_food_R": _SPRAWL_FEET["back_food_R"]},
    tail=[(0.03, 0.40, 0.13), (0.13, 0.69, 0.06), (0.34, 0.98, 0.03), (0.64, 1.16, 0.03)],
    jaw=16.0, lip=5.0, wing_k=0.56, wing_a=_UP_PUSH,
)
_UP_DRIVE = _k(
    hip=(0.0, 0.20, 0.215), back=[(0.0, 0.05, 0.275)], chest=(0.0, -0.12, 0.25), chest_rot=(4, 0, 0),
    neck=[(0.0, -0.26, 0.285), (0.0, -0.32, 0.33), (0.0, -0.37, 0.355)],
    head=(0.0, -0.41, 0.36), look=(0.0, -1.0, -0.2),
    feet={"Hand_L": _STAND["Hand_L"], "Hand_R": _STAND["Hand_R"], "back_food_L": _STAND["back_food_L"],
          "back_food_R": {"at": (-0.145, 0.24, 0.19), "rot": (-14, -12, 0)}},
    tail=[(0.02, 0.42, 0.19), (0.10, 0.71, 0.10), (0.30, 1.0, 0.04), (0.60, 1.19, 0.03)],
    jaw=10.0, lip=3.0, wing_k=0.5, wing_a=_UP_PUSH,
)
_UP_HEAVE = _k(
    hip=(0.0, 0.232, 0.302), back=[(0.0, 0.075, 0.325)], chest=(0.0, -0.09, 0.245), chest_rot=(10, 0, 0),
    neck=[(0.0, -0.25, 0.265), (0.0, -0.315, 0.32), (0.0, -0.37, 0.36)],
    head=(0.0, -0.41, 0.37), look=(0.0, -1.0, -0.26),
    tail=[(0.0, 0.44, 0.25), (0.06, 0.73, 0.16), (0.24, 1.05, 0.08), (0.52, 1.28, 0.04)],
    jaw=6.0, lip=2.0, wing_k=0.28, wing_a=_UP_PUSH,
)
_UP_SETTLE = _k(
    hip=(0.0, 0.227, 0.258), back=[(0.0, 0.072, 0.295)], chest=(0.0, -0.098, 0.258), chest_rot=(1, 0, 0),
    neck=[(0.0, -0.245, 0.285), (0.005, -0.30, 0.35), (0.01, -0.345, 0.41)],
    head=(0.012, -0.378, 0.435), look=(0.1, -1.0, -0.1),
    tail=[(0.015, 0.43, 0.19), (0.10, 0.72, 0.07), (0.31, 1.02, 0.03), (0.60, 1.2, 0.03)],
    wing_k=0.04, wing_a=_UP_PUSH,
)
_GET_UP = one_shot([SPRAWL, _UP_LOOK, _UP_PAW, _UP_BRACE, _UP_PRESS, _UP_FORWARD, _UP_DRIVE, _UP_HEAVE, _UP_SETTLE, _k()],
                   [0, 7, 12, 17, 23, 28, 33, 38, 45, 56], ACTION_LAG)


# --- Death ------------------------------------------------------------------
# Struck, it throws its head back and hangs there. The left foreleg folds and the
# shoulder drops; it catches itself on the right for one last lift of the head,
# then the hindquarters go and the belly hits, with the neck and tail still
# coming down after it. The wings fall open and drape over the ground.

_DIE_LOOSE = {"lift": 22, "sweep": -16, "twist": -6, "elbow": -10, "wrist": -24, "back": 20, "fan": 0.5}
_DRAPE_L = {"lift": 24, "sweep": -20, "twist": 8, "elbow": -14, "wrist": 4, "back": 34, "fan": 0.5}
_DRAPE_R = {"lift": 12, "sweep": -26, "twist": 8, "elbow": -14, "wrist": -6, "back": 40, "fan": 0.42}
_DEAD_FEET = {
    "Hand_L": {"at": (0.225, -0.25, 0.022), "rot": (20, 26, 30)},
    "Hand_R": {"at": (-0.205, -0.20, 0.022), "rot": (20, -24, -24)},
    "back_food_L": {"at": (0.225, 0.30, 0.088), "rot": (20, 26, 0)},
    "back_food_R": {"at": (-0.205, 0.30, 0.088), "rot": (16, -24, 0)},
}
_DEAD_TAIL = [(0.05, 0.42, 0.075), (0.15, 0.71, 0.045), (0.36, 1.0, 0.035), (0.64, 1.2, 0.035)]


def _dk(**changes):
    """A death key: _k with the skull's roll free, so the head can end on its side."""
    return _k(**dict({"head_up": (0.0, 0.0, 1.0)}, **changes))


_DIE_SNAP = _dk(
    hip=(0.0, 0.25, 0.272), back=[(0.0, 0.095, 0.325)], chest=(0.0, -0.07, 0.28), chest_rot=(-14, -3, -4),
    neck=[(-0.005, -0.20, 0.365), (-0.02, -0.21, 0.45), (-0.04, -0.24, 0.51)],
    head=(-0.05, -0.275, 0.545), look=(-0.25, -1.0, 0.6),
    tail=[(0.0, 0.47, 0.23), (0.08, 0.76, 0.125), (0.26, 1.07, 0.05), (0.54, 1.28, 0.03)],
    jaw=46.0, lip=16.0, wing_k=0.35, wing_a=_DIE_LOOSE,
)
_DIE_HANG = dict(_DIE_SNAP, chest=(0.0, -0.07, 0.272), head=(-0.055, -0.275, 0.53), look=(-0.3, -1.0, 0.5), jaw=52.0, lip=18.0, wing_k=0.42)
_DIE_FOLD = _dk(
    hip=(0.0, 0.225, 0.262), back=[(0.015, 0.07, 0.275)], chest=(0.03, -0.095, 0.185), chest_rot=(14, 6, 10),
    neck=[(0.035, -0.245, 0.20), (0.07, -0.31, 0.235), (0.095, -0.365, 0.27)],
    head=(0.115, -0.405, 0.27), look=(0.2, -1.0, -0.35),
    feet=_feet(Hand_L={"at": (0.125, -0.175, 0.05), "rot": (38, 10, 0)}),
    tail=[(0.02, 0.44, 0.20), (0.08, 0.73, 0.10), (0.25, 1.05, 0.05), (0.52, 1.27, 0.03)],
    jaw=30.0, lip=8.0, wing_k=0.5, wing_a=_DIE_LOOSE,
)
_DIE_CATCH = _dk(
    hip=(0.01, 0.225, 0.25), back=[(0.02, 0.07, 0.262)], chest=(0.035, -0.095, 0.175), chest_rot=(6, 2, 12),
    neck=[(0.04, -0.24, 0.225), (0.07, -0.30, 0.285), (0.08, -0.345, 0.335)],
    head=(0.085, -0.365, 0.355), look=(0.1, -1.0, 0.12),
    feet=_feet(Hand_L={"at": (0.14, -0.17, 0.045), "rot": (60, 12, 0)},
               Hand_R={"at": (-0.16, -0.16, 0.0165), "rot": (0, -14, 0)}),
    tail=[(0.02, 0.44, 0.19), (0.09, 0.73, 0.09), (0.27, 1.05, 0.04), (0.55, 1.27, 0.03)],
    jaw=36.0, lip=10.0, wing_k=0.62, wing_a=_DIE_LOOSE,
)
_DIE_SAG = _dk(
    hip=(0.03, 0.228, 0.175), back=[(0.035, 0.07, 0.19)], chest=(0.04, -0.095, 0.125), chest_rot=(10, 4, 14),
    neck=[(0.05, -0.245, 0.17), (0.08, -0.31, 0.20), (0.10, -0.365, 0.215)],
    head=(0.12, -0.40, 0.215), look=(0.25, -1.0, -0.3),
    feet={"Hand_L": {"at": (0.17, -0.20, 0.03), "rot": (60, 18, 0)},
          "Hand_R": {"at": (-0.18, -0.18, 0.03), "rot": (40, -16, 0)},
          "back_food_L": {"at": (0.17, 0.27, 0.10), "rot": (0, 16, 0)},
          "back_food_R": {"at": (-0.16, 0.27, 0.10), "rot": (0, -14, 0)}},
    tail=[(0.03, 0.43, 0.17), (0.11, 0.72, 0.09), (0.30, 1.03, 0.04), (0.58, 1.25, 0.03)],
    jaw=22.0, lip=5.0, wing_k=0.85, wing_a_L=_DRAPE_L, wing_a_R=_DRAPE_R,
)
_DIE_IMPACT = _dk(
    hip=(0.035, 0.235, 0.104), back=[(0.04, 0.075, 0.116)], chest=(0.045, -0.09, 0.092), chest_rot=(6, 4, 10),
    neck=[(0.055, -0.235, 0.145), (0.085, -0.30, 0.16), (0.11, -0.365, 0.175)],
    head=(0.14, -0.42, 0.165), look=(0.4, -1.0, -0.2),
    feet=_DEAD_FEET,
    tail=[(0.05, 0.42, 0.12), (0.15, 0.71, 0.08), (0.35, 1.0, 0.04), (0.62, 1.21, 0.03)],
    jaw=26.0, lip=6.0, wing_k=1.0, wing_a_L=_DRAPE_L, wing_a_R=_DRAPE_R,
)
_DIE_HEAD_DOWN = _dk(
    hip=(0.035, 0.235, 0.102), back=[(0.04, 0.075, 0.112)], chest=(0.045, -0.09, 0.09), chest_rot=(6, 4, 10),
    neck=[(0.06, -0.24, 0.10), (0.10, -0.31, 0.085), (0.15, -0.375, 0.075)],
    head=(0.20, -0.43, 0.068), look=(0.6, -1.0, -0.08), head_up=(0.6, 0.0, 0.8),
    feet=_DEAD_FEET, tail=_DEAD_TAIL,
    jaw=32.0, lip=6.0, wing_k=1.0, wing_a_L=_DRAPE_L, wing_a_R=_DRAPE_R,
)
_DIE_REBOUND = dict(_DIE_HEAD_DOWN, hip=(0.035, 0.235, 0.112), chest=(0.045, -0.09, 0.098),
                    neck=[(0.06, -0.24, 0.115), (0.10, -0.31, 0.105), (0.15, -0.375, 0.10)],
                    head=(0.20, -0.43, 0.105), jaw=24.0,
                    tail=[(0.05, 0.42, 0.095), (0.15, 0.71, 0.06), (0.36, 1.0, 0.04), (0.64, 1.2, 0.035)])
_DIE_REST = dict(_DIE_HEAD_DOWN, hip=(0.035, 0.235, 0.104), chest=(0.045, -0.09, 0.092), head=(0.205, -0.435, 0.066), jaw=22.0, lip=2.0)
_DIE_EXHALE = dict(_DIE_REST, hip=(0.035, 0.235, 0.10), chest=(0.045, -0.09, 0.086), jaw=15.0, lip=1.0)
# The ends are heavy and come down last.
DEATH_LAG = dict(ACTION_LAG, neck=[0.8, 1.2, 1.6], head=2.0, head_up=2.0, look=2.2, tail=[1.5, 3.0, 4.5, 6.0])
_DEATH = one_shot([_dk(), _DIE_SNAP, _DIE_HANG, _DIE_FOLD, _DIE_CATCH, _DIE_SAG, _DIE_IMPACT, _DIE_HEAD_DOWN, _DIE_REBOUND, _DIE_REST, _DIE_EXHALE],
                  [0, 5, 11, 18, 24, 31, 36, 41, 46, 56, 70], DEATH_LAG)


# --- Roar -------------------------------------------------------------------
# Draws its head down and in, then throws it up and open with the wings half
# out, shakes it, and folds back. Nothing plays this yet.

_ROAR_DRAW = _k(
    hip=(0.0, 0.232, 0.262), back=[(0.0, 0.08, 0.3)], chest=(0.0, -0.09, 0.238), chest_rot=(10, 0, 0),
    neck=[(0.0, -0.235, 0.255), (0.0, -0.27, 0.30), (0.0, -0.30, 0.335)],
    head=(0.0, -0.335, 0.335), look=(0.0, -1.0, -0.45),
    tail=[(0.0, 0.44, 0.21), (0.07, 0.73, 0.10), (0.24, 1.05, 0.03), (0.52, 1.28, 0.03)],
    jaw=6.0, lip=2.0, wing_k=0.1,
)
_ROAR_OPEN = _k(
    hip=(0.0, 0.245, 0.275), back=[(0.0, 0.09, 0.32)], chest=(0.0, -0.08, 0.272), chest_rot=(-12, 0, 0),
    neck=[(0.0, -0.205, 0.36), (0.0, -0.245, 0.44), (0.0, -0.30, 0.505)],
    head=(0.0, -0.345, 0.54), look=(0.0, -1.0, 0.42),
    tail=[(0.0, 0.47, 0.235), (0.05, 0.76, 0.13), (0.18, 1.08, 0.05), (0.42, 1.33, 0.03)],
    jaw=58.0, lip=20.0, wing_k=0.82,
)
_ROAR_L = dict(_ROAR_OPEN, head=(0.05, -0.345, 0.53), look=(0.3, -1.0, 0.36),
               neck=[(0.0, -0.205, 0.36), (0.02, -0.245, 0.44), (0.035, -0.30, 0.50)], jaw=56.0, wing_k=0.85)
_ROAR_R = dict(_ROAR_OPEN, head=(-0.05, -0.345, 0.53), look=(-0.3, -1.0, 0.36),
               neck=[(0.0, -0.205, 0.36), (-0.02, -0.245, 0.44), (-0.035, -0.30, 0.50)], jaw=56.0, wing_k=0.8)
_ROAR_SINK = _k(
    hip=(0.0, 0.235, 0.268), back=[(0.0, 0.08, 0.305)], chest=(0.0, -0.095, 0.25), chest_rot=(3, 0, 0),
    neck=[(0.0, -0.24, 0.285), (0.0, -0.29, 0.35), (0.0, -0.335, 0.41)],
    head=(0.005, -0.375, 0.43), look=(0.04, -1.0, -0.1),
    jaw=16.0, lip=5.0, wing_k=0.28,
)
_ROAR = one_shot([_k(), _ROAR_DRAW, _ROAR_DRAW, _ROAR_OPEN, _ROAR_L, _ROAR_R, _ROAR_OPEN, _ROAR_SINK, _k()],
                 [0, 9, 13, 19, 25, 31, 37, 44, 54], HEAD_LEADS)


# --- Tail swipe -------------------------------------------------------------
# No turn of the whole body: the feet stay down and the spine does it. It coils
# into a C with the tail wound round to the right and the head glancing back at
# it, then the C snaps the other way. The hips throw out to the right, the root
# of the tail goes first, and the tip arrives last and fastest, round the left
# side. The momentum drags the left hind foot out a step.

_SW_WIND = _k(
    hip=(0.035, 0.24, 0.255), back=[(0.03, 0.085, 0.285)], chest=(0.0, -0.085, 0.24), chest_rot=(8, -16, -6),
    neck=[(-0.02, -0.235, 0.27), (-0.05, -0.29, 0.33), (-0.08, -0.335, 0.38)],
    head=(-0.10, -0.37, 0.40), look=(-0.7, -1.0, -0.1),
    wing_k=0.0, jaw=6.0,
)
_SW_COIL = _k(
    hip=(0.045, 0.245, 0.25), back=[(0.04, 0.09, 0.275)], chest=(-0.005, -0.08, 0.238), chest_rot=(10, -20, -8),
    neck=[(-0.025, -0.23, 0.265), (-0.06, -0.285, 0.325), (-0.10, -0.325, 0.37)],
    head=(-0.13, -0.365, 0.39), look=(-0.85, -1.0, -0.1),
    wing_k=0.0, jaw=8.0,
)
_SW_SNAP = _k(
    hip=(0.0, 0.235, 0.26), back=[(0.0, 0.08, 0.285)], chest=(0.01, -0.09, 0.24), chest_rot=(8, 0, 0),
    neck=[(0.005, -0.24, 0.265), (0.0, -0.30, 0.325), (0.0, -0.35, 0.38)],
    head=(0.0, -0.39, 0.40), look=(0.0, -1.0, -0.15),
    wing_k=0.02, jaw=14.0, lip=4.0,
)
_SW_WHIP = _k(
    hip=(-0.05, 0.215, 0.26), back=[(-0.03, 0.06, 0.29)], chest=(0.03, -0.105, 0.24), chest_rot=(9, 18, 7),
    neck=[(0.04, -0.25, 0.26), (0.05, -0.32, 0.315), (0.055, -0.37, 0.365)],
    head=(0.06, -0.41, 0.385), look=(0.25, -1.0, -0.14),
    wing_k=0.05, wing_k_R=0.07, jaw=34.0, lip=10.0,
)
_SW_PAST = dict(_SW_WHIP, hip=(-0.058, 0.21, 0.262), chest=(0.036, -0.108, 0.243), chest_rot=(9, 20, 8), jaw=30.0)
_SW_DRAG = _k(
    hip=(-0.04, 0.218, 0.262), back=[(-0.02, 0.065, 0.292)], chest=(0.03, -0.105, 0.24), chest_rot=(8, 14, 5),
    neck=[(0.035, -0.25, 0.262), (0.045, -0.315, 0.32), (0.05, -0.365, 0.37)],
    head=(0.05, -0.405, 0.39), look=(0.2, -1.0, -0.15),
    feet=_feet(back_food_L={"at": (0.125, 0.235, 0.175), "rot": (-14, 10, 0)}),
    wing_k=0.03, jaw=12.0, lip=3.0,
)
_SW_STAGGER = _k(
    hip=(-0.012, 0.222, 0.258), back=[(-0.005, 0.068, 0.288)], chest=(0.015, -0.103, 0.24), chest_rot=(7, 8, 3),
    neck=[(0.015, -0.25, 0.268), (0.02, -0.31, 0.33), (0.025, -0.355, 0.385)],
    head=(0.03, -0.395, 0.405), look=(0.12, -1.0, -0.16),
    feet=_feet(back_food_L={"at": (0.14, 0.235, 0.1016), "rot": (0, 10, 0)}),
    wing_k=0.0, jaw=4.0,
)
_SW_RETURN = _k(
    hip=(0.0, 0.225, 0.266), back=[(0.0, 0.07, 0.298)], chest=(0.0, -0.10, 0.247), chest_rot=(6, 2, 1),
    head=(0.012, -0.385, 0.413),
    feet=_feet(back_food_L={"at": (0.12, 0.235, 0.17), "rot": (-14, 8, 0)}),
    wing_k=0.05,
)
_SWIPE_FRAMES = [0, 10, 15, 19, 22, 25, 30, 36, 43, 50]
_SWIPE_BODY = one_shot([_k(), _SW_WIND, _SW_COIL, _SW_SNAP, _SW_WHIP, _SW_PAST, _SW_DRAG, _SW_STAGGER, _SW_RETURN, _k()],
                       _SWIPE_FRAMES, ACTION_LAG, {"impact": [23]})
# Where the tail points at each key, in degrees, + to its left. Each joint gets a
# growing share of it, later than the joint before: the root leads and the tip
# cracks round after it.
_SWIPE_ANGLE = [25.0, -72.0, -82.0, -38.0, 62.0, 102.0, 110.0, 62.0, 32.0, 25.0]
_SWIPE_SHARE = [0.35, 0.7, 1.0, 1.2]
_SWIPE_LENGTH = [0.205, 0.31, 0.365, 0.34]
_SWIPE_Z = [0.20, 0.105, 0.08, 0.07]
_SWIPE_JOINT_LAG = 1.4


def tail_swipe_at(t):
    out = _SWIPE_BODY["at"](t)
    length = _SWIPE_FRAMES[-1]
    f = t * length
    fade = min(1.0, (length - f) / 6.0)
    x, y = out["hip"][0], out["hip"][1]
    swept = []
    for i, z in enumerate(_SWIPE_Z):
        heading = math.radians(_once(_SWIPE_ANGLE, _SWIPE_FRAMES, f - (i + 1.0) * _SWIPE_JOINT_LAG * fade) * _SWIPE_SHARE[i])
        x += _SWIPE_LENGTH[i] * math.sin(heading)
        y += _SWIPE_LENGTH[i] * math.cos(heading)
        swept.append((x, y, z))
    w = _smooth(min(1.0, f / 4.0, (length - f) / 4.0))
    out["tail"] = [tuple(a + (b - a) * w for a, b in zip(rest, p)) for rest, p in zip(STANCE["tail"], swept)]
    return out


_TAIL_SWIPE = dict(_SWIPE_BODY, at=tail_swipe_at)


# --- Wing buffet ------------------------------------------------------------
# Rears off its forepaws with the wings thrown up and back, then claps them
# forward and down, and drops back onto its paws. It stays on its hind feet.

_BUFFET_UP_WING = {"lift": 66, "sweep": -32, "twist": -12, "elbow": 10, "wrist": -30, "back": 12, "fan": 0.9}
_BUFFET_DOWN_WING = {"lift": 4, "sweep": 44, "twist": -34, "elbow": 6, "wrist": 16, "back": 0, "fan": 1.0}
_REAR_FEET = _feet(
    Hand_L={"at": (0.09, -0.14, 0.33), "rot": (56, 6, 0)},
    Hand_R={"at": (-0.09, -0.125, 0.345), "rot": (52, -5, 0)},
)
_BUF_CROUCH = _k(
    hip=(0.0, 0.232, 0.232), back=[(0.0, 0.08, 0.27)], chest=(0.0, -0.095, 0.238), chest_rot=(4, 0, 0),
    neck=[(0.0, -0.24, 0.272), (0.0, -0.285, 0.335), (0.0, -0.325, 0.39)],
    head=(0.0, -0.365, 0.405), look=(0.0, -1.0, -0.2),
    wing_k=0.5, wing_a=_BUFFET_UP_WING,
)
_BUF_REAR = _k(
    hip=(0.0, 0.245, 0.242), back=[(0.0, 0.135, 0.37)], chest=(0.0, 0.01, 0.485), chest_rot=(-52, 0, 0),
    neck=[(0.0, -0.06, 0.60), (0.0, -0.08, 0.675), (0.0, -0.125, 0.73)],
    head=(0.0, -0.165, 0.755), look=(0.0, -1.0, 0.05),
    feet=_REAR_FEET,
    tail=[(0.0, 0.46, 0.20), (0.05, 0.76, 0.09), (0.16, 1.08, 0.03), (0.38, 1.33, 0.03)],
    jaw=26.0, lip=8.0, wing_k=1.0, wing_a=_BUFFET_UP_WING,
)
_BUF_SLAM = _k(
    hip=(0.0, 0.215, 0.255), back=[(0.0, 0.085, 0.345)], chest=(0.0, -0.06, 0.43), chest_rot=(-30, 0, 0),
    neck=[(0.0, -0.165, 0.505), (0.0, -0.225, 0.545), (0.0, -0.29, 0.555)],
    head=(0.0, -0.335, 0.55), look=(0.0, -1.0, -0.3),
    feet=_feet(
        Hand_L={"at": (0.09, -0.20, 0.25), "rot": (40, 6, 0)},
        Hand_R={"at": (-0.09, -0.19, 0.265), "rot": (36, -5, 0)},
    ),
    tail=[(0.0, 0.42, 0.20), (0.08, 0.70, 0.08), (0.28, 1.0, 0.03), (0.56, 1.25, 0.03)],
    jaw=36.0, lip=12.0, wing_k=1.0, wing_a=_BUFFET_DOWN_WING,
)
_BUF_DROP = _k(
    hip=(0.0, 0.22, 0.262), back=[(0.0, 0.07, 0.30)], chest=(0.0, -0.095, 0.27), chest_rot=(-2, 0, 0),
    neck=[(0.0, -0.235, 0.30), (0.0, -0.29, 0.35), (0.0, -0.345, 0.385)],
    head=(0.0, -0.39, 0.395), look=(0.0, -1.0, -0.22),
    feet=_feet(
        Hand_L={"at": (0.105, -0.23, 0.07), "rot": (16, 8, 0)},
        Hand_R={"at": (-0.102, -0.17, 0.08), "rot": (14, -6, 0)},
    ),
    jaw=10.0, lip=3.0, wing_k=0.7, wing_a=_BUFFET_DOWN_WING,
)
_BUF_LAND = _k(
    hip=(0.0, 0.222, 0.255), back=[(0.0, 0.07, 0.285)], chest=(0.0, -0.105, 0.232), chest_rot=(8, 0, 0),
    neck=[(0.0, -0.255, 0.26), (0.0, -0.31, 0.32), (0.0, -0.36, 0.375)],
    head=(0.006, -0.40, 0.39), look=(0.03, -1.0, -0.22),
    wing_k=0.28, wing_a=_BUFFET_UP_WING,
)
_WING_BUFFET = one_shot(
    [_k(wing_a=_BUFFET_UP_WING), _BUF_CROUCH, _BUF_REAR, _BUF_REAR, _BUF_SLAM, _BUF_DROP, _BUF_LAND, _k(wing_a=_BUFFET_UP_WING)],
    [0, 6, 12, 15, 19, 25, 31, 42], ACTION_LAG, {"impact": [19]})


# --- Turning on the spot ----------------------------------------------------
# The game rotates the unit; this is the body going round with it. The head and
# neck reach into the turn, the spine bends after them and the tail is left
# behind, so the body is a C around the side it is turning to. In the unit's own
# frame a planted foot swings back along a circle round the middle of the body
# and a lifted one steps ahead along it, fore and hind in turn.

TURN_FRAMES = 24
_TURN_ORDER = {"Hand_L": 0.5, "back_food_R": 0.25, "Hand_R": 0.0, "back_food_L": 0.75}
_TURN_MIRROR = {"Hand_L": "Hand_R", "Hand_R": "Hand_L", "back_food_L": "back_food_R", "back_food_R": "back_food_L"}
_TURN_ARC = 20.0
_TURN_PIVOT_Y = 0.03
_TURN_DUTY = 0.6
_TURN_LIFT = 0.09
_TURN_NECK = [(0.085, -0.245, 0.29), (0.13, -0.285, 0.345), (0.17, -0.30, 0.395)]
_TURN_TAIL = [(0.04, 0.42, 0.20), (0.18, 0.69, 0.09), (0.40, 0.92, 0.04), (0.68, 1.04, 0.04)]
_TURN_TAIL_SWING = [0.008, 0.025, 0.05, 0.08]


def _turn_foot(name, t, sign):
    rest = STANCE["feet"][name]
    order = _TURN_ORDER[name if sign > 0.0 else _TURN_MIRROR[name]]
    p = (t + order) % 1.0
    if p < _TURN_DUTY:
        a = 1.0 - 2.0 * p / _TURN_DUTY
        lift = 0.0
        tip = 0.0
    else:
        v = (p - _TURN_DUTY) / (1.0 - _TURN_DUTY)
        a = -1.0 + 2.0 * _smooth(v)
        lift = _TURN_LIFT * math.sin(math.pi * v)
        tip = math.sin(math.pi * v) * (30.0 * (1.0 - v) - 12.0 * v)
    degrees = _TURN_ARC * a * sign
    turn = math.radians(degrees)
    x, y, z = rest["at"]
    y -= _TURN_PIVOT_Y
    rot = rest["rot"]
    return {"at": (x * math.cos(turn) - y * math.sin(turn), x * math.sin(turn) + y * math.cos(turn) + _TURN_PIVOT_Y, z + lift),
            "rot": (rot[0] + tip, rot[1] + degrees, rot[2])}


def _turn_at(t, sign):
    # The shoulders lean off the forefoot that is up, the pelvis off the hind one.
    chest_x = 0.05 - 0.02 * _wave(t, 0.30)
    hip_x = 0.0 + 0.016 * _wave(t, 0.55)
    chest_z = 0.24 - 0.009 * _beat(t, 0.30)
    hip_z = 0.262 - 0.009 * _beat(t, 0.05)
    nod = 0.008 * _beat(t, 0.38)
    tail = [(sign * (x + _TURN_TAIL_SWING[i] * _wave(t, 0.5 + 0.12 * i)), y, z)
            for i, (x, y, z) in enumerate(_TURN_TAIL)]
    wing = wing_unfold(STANCE["wing"], open_wing(**FLARE), 0.06 + 0.03 * (0.5 + 0.5 * _beat(t, 0.32)))
    return {
        "hip": (sign * hip_x, 0.225, hip_z),
        "back": [(sign * -0.018, 0.07, 0.29 + 0.5 * (hip_z - 0.262 + chest_z - 0.24))],
        "chest": (sign * chest_x, -0.10, chest_z),
        "chest_rot": (6.0, sign * (18.0 - 4.0 * _wave(t, 0.30)), sign * 4.0 * _wave(t, 0.30)),
        "neck": [(sign * x, y, z + nod * (i + 1) / 3.0) for i, (x, y, z) in enumerate(_TURN_NECK)],
        "head": (sign * 0.195, -0.325, 0.415 + nod),
        "look": (sign * 0.95, -1.0, -0.12),
        "feet": {name: _turn_foot(name, t, sign) for name in _TURN_ORDER},
        "tail": tail,
        "wing_L": wing,
        "wing_R": wing,
    }


# --- In the air -------------------------------------------------------------
# An air attack is one wingbeat with the attack on top of it: the keys pose the
# body against the hover's own first frame, and every frame adds how far the
# hover has moved since then. The wings are simply the hover's, so the beat
# never breaks, and the clip starts and ends in the hover.

_HOVER_0 = hover_at(0.0)
_HOVER_BODY = ("hip", "back", "chest", "chest_rot", "neck", "head", "look", "tail", "feet")
_HOVER_WING_0 = _between(poses.HOVER_WING, HOVER_TIMES, 0.0, poses.HOVER_WING_LAG)


AIR_WING_RAISE = 1.1


def _beat_wing(t, higher):
    angles = _between(poses.HOVER_WING, HOVER_TIMES, t, poses.HOVER_WING_LAG)
    return open_wing(**dict(angles, lift=angles["lift"] + higher))


def _a(**changes):
    """A key pose: the hover's first frame, mouth shut, with these parts changed."""
    return {**{n: _HOVER_0[n] for n in _HOVER_BODY}, "jaw": 0.0, "lip": 0.0, **changes}


def _hover_feet(**changes):
    return dict(_HOVER_0["feet"], **changes)


def _plus(value, now, rest):
    if isinstance(value, dict):
        return {k: _plus(value[k], now[k], rest[k]) for k in value}
    if isinstance(value, list):
        return [_plus(v, n, r) for v, n, r in zip(value, now, rest)]
    return tuple(v + n - r for v, n, r in zip(value, now, rest))


def _on_the_beat(pose, t):
    """Adds the hover's motion at t, and takes its wings."""
    hover = hover_at(t)
    out = dict(pose)
    for n in _HOVER_BODY:
        out[n] = _plus(pose[n], hover[n], _HOVER_0[n])
    # A flatter chest swings the wing roots forward and down, so the beat rides
    # that much higher against the ribs and keeps its height off the ground.
    higher = max(0.0, pose["chest_rot"][0] - _HOVER_0["chest_rot"][0]) * AIR_WING_RAISE
    out["wing_L"] = _beat_wing(t, higher)
    out["wing_R"] = _beat_wing(t - poses.HOVER_WING_R_LAG, higher)
    return out


def air_shot(keys, frames, lag=ACTION_LAG, moments=None):
    length = frames[-1]
    names = list(keys[0])

    def at(t):
        f = t * length
        fade = min(1.0, (length - f) / 6.0)
        pose = {n: _between([k[n] for k in keys], frames, f, _scaled(lag.get(n, 0.0), fade), _once) for n in names}
        return _on_the_beat(pose, t)
    return {"length": length / 24.0, "at": at, "moments": moments or {}}


_AIR_BITE_COIL = _a(
    hip=(0.0, 0.215, 0.505), back=[(0.0, 0.07, 0.61)], chest=(0.0, -0.05, 0.705), chest_rot=(-38, 0, 0),
    neck=[(0.0, -0.155, 0.83), (0.0, -0.17, 0.905), (0.0, -0.205, 0.965)],
    head=(0.0, -0.23, 1.0), look=(0.0, -1.0, 0.05), jaw=34.0, lip=10.0,
)
_AIR_BITE_STRIKE = _a(
    hip=(0.0, 0.16, 0.595), back=[(0.0, 0.0, 0.645)], chest=(0.0, -0.16, 0.655), chest_rot=(-8, 0, 0),
    neck=[(0.0, -0.30, 0.665), (0.0, -0.39, 0.655), (0.0, -0.465, 0.645)],
    head=(0.0, -0.51, 0.625), look=(0.0, -1.0, -0.25),
    tail=[(0.015, 0.33, 0.46), (0.035, 0.60, 0.33), (0.056, 0.93, 0.28), (0.084, 1.2, 0.32)],
)
_AIR_BITE_REACH = dict(_AIR_BITE_STRIKE, jaw=46.0, lip=14.0, head=(0.0, -0.47, 0.665), look=(0.0, -1.0, -0.12),
                       neck=[(0.0, -0.285, 0.685), (0.0, -0.365, 0.685), (0.0, -0.435, 0.675)])
_AIR_BITE_TUG = dict(_AIR_BITE_STRIKE, head=(0.05, -0.49, 0.635), look=(0.3, -1.0, -0.2),
                     neck=[(0.01, -0.29, 0.67), (0.03, -0.375, 0.66), (0.045, -0.45, 0.65)])
_BITE_AIR = air_shot([_a(), _AIR_BITE_COIL, _AIR_BITE_COIL, _AIR_BITE_REACH, _AIR_BITE_STRIKE, _AIR_BITE_STRIKE, _AIR_BITE_TUG, _a()],
                     [0, 7, 10, 12, 13, 15, 19, 32], HEAD_LEADS, {"impact": [13]})

_TUCK_TALONS = _hover_feet(
    back_food_L={"at": (0.12, 0.06, 0.53), "rot": (-20, 12, 0)},
    back_food_R={"at": (-0.12, 0.05, 0.55), "rot": (-20, -12, 0)},
)
_RAKE_TALONS = _hover_feet(
    back_food_L={"at": (0.10, -0.15, 0.29), "rot": (28, 8, 0)},
    back_food_R={"at": (-0.10, -0.17, 0.31), "rot": (24, -8, 0)},
)


def _paws_with_chest(key):
    """The forepaws where the hover holds them against the chest, wherever the chest has gone."""
    c = key["chest"]
    near = {"Hand_L": (0.085, -0.12, -0.134), "Hand_R": (-0.085, -0.106, -0.118)}
    feet = dict(key["feet"])
    for name, off in near.items():
        feet[name] = dict(feet[name], at=(c[0] + off[0], c[1] + off[1], c[2] + off[2]))
    return dict(key, feet=feet)


_AIR_CLAW_TUCK = _a(
    hip=(0.0, 0.20, 0.585), back=[(0.0, 0.085, 0.70)], chest=(0.0, -0.02, 0.83), chest_rot=(-50, 0, 0),
    neck=[(0.0, -0.12, 0.95), (0.0, -0.14, 1.02), (0.0, -0.18, 1.08)],
    head=(0.0, -0.215, 1.11), look=(0.0, -1.0, -0.28), feet=_TUCK_TALONS, jaw=18.0, lip=6.0,
)
_AIR_CLAW_RAKE = _a(
    hip=(0.0, 0.195, 0.565), back=[(0.0, 0.07, 0.665)], chest=(0.0, -0.04, 0.785), chest_rot=(-42, 0, 0),
    neck=[(0.0, -0.15, 0.90), (0.0, -0.185, 0.965), (0.0, -0.235, 1.015)],
    head=(0.0, -0.275, 1.04), look=(0.0, -1.0, -0.42), feet=_RAKE_TALONS, jaw=28.0, lip=8.0,
)
_AIR_CLAW_FOLLOW = dict(_AIR_CLAW_RAKE, feet=_hover_feet(
    back_food_L={"at": (0.10, -0.05, 0.25), "rot": (55, 8, 0)},
    back_food_R={"at": (-0.10, -0.07, 0.27), "rot": (50, -8, 0)},
), jaw=14.0)
_CLAW_AIR = air_shot([_a(), _paws_with_chest(_AIR_CLAW_TUCK), _paws_with_chest(_AIR_CLAW_TUCK), _paws_with_chest(_AIR_CLAW_RAKE),
                      _paws_with_chest(_AIR_CLAW_FOLLOW), _a()],
                     [0, 8, 11, 15, 19, 34], ACTION_LAG, {"impact": [15]})

_AIR_DRAW = _a(
    hip=(0.0, 0.215, 0.52), back=[(0.0, 0.075, 0.625)], chest=(0.0, -0.05, 0.712), chest_rot=(-38, 0, 0),
    neck=[(0.0, -0.15, 0.835), (0.0, -0.165, 0.915), (0.0, -0.20, 0.98)],
    head=(0.0, -0.235, 1.02), look=(0.0, -1.0, 0.25), jaw=8.0, lip=3.0,
)
_AIR_FIRE = _a(
    hip=(0.0, 0.17, 0.59), back=[(0.0, 0.01, 0.645)], chest=(0.0, -0.15, 0.67), chest_rot=(-12, 0, 0),
    neck=[(0.0, -0.295, 0.665), (0.0, -0.375, 0.64), (0.0, -0.44, 0.61)],
    head=(0.0, -0.48, 0.58), look=(0.0, -1.0, -0.42), jaw=42.0, lip=14.0,
)
_AIR_DRIVE = dict(_AIR_FIRE, head=(0.0, -0.465, 0.615), look=(0.0, -1.0, -0.22), jaw=20.0, lip=8.0,
                  neck=[(0.0, -0.285, 0.685), (0.0, -0.365, 0.665), (0.0, -0.43, 0.64)])
_BREATH_AIR = air_shot([_a(), _AIR_DRAW, _AIR_DRAW, _AIR_DRIVE, _AIR_FIRE], [0, 9, 13, 20, 24], HEAD_LEADS, {"release": [23]})
_BREATH_OUT_AIR = air_shot([_AIR_FIRE, _AIR_DRIVE, _a()], [0, 7, 24], ACTION_LAG)


def breath_hold_air_at(t):
    """The fire going in the air, on the wingbeat. One beat, so it loops with the hover."""
    a = math.sin(2.0 * math.pi * t)
    b = math.sin(4.0 * math.pi * t)
    pose = dict(_AIR_FIRE)
    pose["head"] = (_AIR_FIRE["head"][0] + 0.016 * a, _AIR_FIRE["head"][1], _AIR_FIRE["head"][2] + 0.006 * b)
    pose["look"] = (_AIR_FIRE["look"][0] + 0.04 * a, _AIR_FIRE["look"][1], _AIR_FIRE["look"][2] + 0.02 * b)
    pose["neck"] = [(x + 0.010 * a, y, z + 0.004 * b) for x, y, z in _AIR_FIRE["neck"]]
    pose["jaw"] = _AIR_FIRE["jaw"] + 3.0 * b
    pose["lip"] = _AIR_FIRE["lip"] + 1.5 * b
    return _on_the_beat(pose, t)


# Struck in the air: the wings lose their stroke, it drops and pitches back, and
# it beats its way back up. Shorter than a wingbeat, so it holds the hover's
# first wing pose and falters from there rather than running a beat.

_AIR_FALTER_WING = dict(_HOVER_WING_0, lift=_HOVER_WING_0["lift"] - 34.0, back=_HOVER_WING_0["back"] + 14.0,
                        wrist=_HOVER_WING_0["wrist"] - 18.0)
_AIR_CATCH_WING = dict(_HOVER_WING_0, lift=_HOVER_WING_0["lift"] - 12.0, back=_HOVER_WING_0["back"] + 5.0)
_AIR_FALTER = _a(
    hip=(0.0, 0.215, 0.475), back=[(0.0, 0.075, 0.585)], chest=(0.0, -0.06, 0.67), chest_rot=(-38, 0, -6),
    neck=[(-0.01, -0.145, 0.80), (-0.02, -0.15, 0.875), (-0.03, -0.185, 0.935)],
    head=(-0.035, -0.215, 0.975), look=(-0.25, -1.0, 0.2),
    tail=[(0.015, 0.385, 0.34), (0.05, 0.655, 0.20), (0.09, 0.99, 0.15), (0.16, 1.25, 0.20)],
    jaw=24.0, lip=8.0,
)
_AIR_CATCH = _a(
    hip=(0.0, 0.205, 0.515), back=[(0.0, 0.065, 0.61)], chest=(0.0, -0.08, 0.675), chest_rot=(-30, 0, -2),
    neck=[(-0.003, -0.18, 0.79), (-0.006, -0.205, 0.86), (-0.01, -0.24, 0.915)],
    head=(-0.01, -0.265, 0.95), look=(-0.05, -1.0, -0.05), jaw=6.0, lip=2.0,
)
_HIT_AIR_KEYS = [_a(), _AIR_FALTER, _AIR_CATCH, _a()]
_HIT_AIR_FRAMES = [0, 3, 9, 16]


def hit_air_at(t):
    length = _HIT_AIR_FRAMES[-1]
    f = t * length
    fade = min(1.0, (length - f) / 6.0)
    out = {n: _between([k[n] for k in _HIT_AIR_KEYS], _HIT_AIR_FRAMES, f, _scaled(ACTION_LAG.get(n, 0.0), fade), _once)
           for n in _HIT_AIR_KEYS[0]}
    wings = [_HOVER_WING_0, _AIR_FALTER_WING, _AIR_CATCH_WING, _HOVER_WING_0]
    out["wing_L"] = open_wing(**_between(wings, _HIT_AIR_FRAMES, f, _scaled(TAKEOFF_WING_LAG, fade), _once))
    out["wing_R"] = open_wing(**_between(wings, _HIT_AIR_FRAMES, f - 0.3 * fade, _scaled(TAKEOFF_WING_LAG, fade), _once))
    return out


# Roaring in the air: one slow wingbeat, the downstroke landing as the head goes
# up, so the body is thrown up and back on it and hangs open-mouthed on the wings.

_AIR_ROAR_DRAW = _a(
    hip=(0.0, 0.22, 0.515), back=[(0.0, 0.08, 0.615)], chest=(0.0, -0.055, 0.70), chest_rot=(-32, 0, 0),
    neck=[(0.0, -0.17, 0.795), (0.0, -0.205, 0.85), (0.0, -0.24, 0.875)],
    head=(0.0, -0.28, 0.875), look=(0.0, -1.0, -0.45), jaw=6.0, lip=2.0,
)
_AIR_ROAR_OPEN = _a(
    hip=(0.0, 0.19, 0.47), back=[(0.0, 0.10, 0.595)], chest=(0.0, -0.015, 0.725), chest_rot=(-58, 0, 0),
    neck=[(0.0, -0.08, 0.865), (0.0, -0.095, 0.96), (0.0, -0.135, 1.04)],
    head=(0.0, -0.175, 1.085), look=(0.0, -1.0, 0.5),
    tail=[(0.01, 0.37, 0.33), (0.03, 0.62, 0.20), (0.06, 0.90, 0.13), (0.10, 1.18, 0.14)],
    jaw=58.0, lip=20.0,
)
_AIR_ROAR_L = dict(_AIR_ROAR_OPEN, head=(0.05, -0.175, 1.075), look=(0.3, -1.0, 0.44), jaw=56.0,
                   neck=[(0.0, -0.08, 0.865), (0.02, -0.095, 0.96), (0.035, -0.135, 1.035)])
_AIR_ROAR_R = dict(_AIR_ROAR_OPEN, head=(-0.05, -0.175, 1.075), look=(-0.3, -1.0, 0.44), jaw=56.0,
                   neck=[(0.0, -0.08, 0.865), (-0.02, -0.095, 0.96), (-0.035, -0.135, 1.035)])
_AIR_ROAR_SINK = _a(
    hip=(0.0, 0.21, 0.525), back=[(0.0, 0.075, 0.625)], chest=(0.0, -0.05, 0.712), chest_rot=(-36, 0, 0),
    neck=[(0.0, -0.15, 0.83), (0.0, -0.17, 0.905), (0.0, -0.21, 0.96)],
    head=(0.005, -0.245, 0.99), look=(0.04, -1.0, -0.05), jaw=16.0, lip=5.0,
)
_ROAR_AIR = air_shot([_a(), _AIR_ROAR_DRAW, _AIR_ROAR_DRAW, _AIR_ROAR_OPEN, _AIR_ROAR_L, _AIR_ROAR_R, _AIR_ROAR_OPEN, _AIR_ROAR_SINK, _a()],
                     [0, 9, 13, 19, 25, 31, 37, 44, 54], HEAD_LEADS)


CLIPS = dict(
    poses.CLIPS,
    walk={"length": WALK_FRAMES / 24.0, "at": walk_at},
    hit=_HIT,
    hit_air={"length": _HIT_AIR_FRAMES[-1] / 24.0, "at": hit_air_at},
    death=_DEATH,
    knockdown=_KNOCKDOWN,
    get_up=_GET_UP,
    bite=_BITE,
    bite_air=_BITE_AIR,
    claw=_CLAW,
    claw_air=_CLAW_AIR,
    breath=_BREATH,
    breath_hold={"length": 1.0, "at": breath_hold_at},
    breath_out=_BREATH_OUT,
    breath_air=_BREATH_AIR,
    breath_hold_air={"length": 40.0 / 24.0, "at": breath_hold_air_at},
    breath_out_air=_BREATH_OUT_AIR,
    roar=_ROAR,
    roar_air=_ROAR_AIR,
    tail_swipe=_TAIL_SWIPE,
    wing_buffet=_WING_BUFFET,
    turn_l={"length": TURN_FRAMES / 24.0, "at": lambda t: _turn_at(t, 1.0)},
    turn_r={"length": TURN_FRAMES / 24.0, "at": lambda t: _turn_at(t, -1.0)},
)
ALOFT = set(poses.ALOFT) | {"bite_air", "claw_air", "breath_air", "breath_hold_air", "breath_out_air", "hit_air", "roar_air", "wing_buffet"}
LIFTED = set(poses.LIFTED)
