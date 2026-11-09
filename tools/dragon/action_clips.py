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
# A lateral sequence, low and heavy. The feet travel at the game's move speed
# while they are planted (stride / (duty * length) = 0.78 model units a second
# against the game's 0.8), so they barely skate.

WALK_FRAMES = 18
_WALK_DUTY = 0.55
_WALK_STRIDE = 0.32
_WALK_LIFT = 0.07
_WALK_FEET = {
    # name: phase, x, centre y, ground height, yaw
    "back_food_L": (0.0, 0.098, 0.21, 0.1016, 5.0),
    "Hand_L": (0.25, 0.108, -0.165, 0.0165, 8.0),
    "back_food_R": (0.5, -0.098, 0.21, 0.1016, -5.0),
    "Hand_R": (0.75, -0.104, -0.165, 0.0165, -6.0),
}
_WALK_TAIL = [(0.0, 0.43, 0.20), (0.02, 0.72, 0.09), (0.05, 1.02, 0.04), (0.08, 1.30, 0.03)]
_WALK_TAIL_SWING = [0.01, 0.03, 0.07, 0.12]
_WALK_NECK = [(0.0, -0.255, 0.265), (0.0, -0.315, 0.315), (0.0, -0.365, 0.365)]


def _smooth(u):
    return u * u * (3.0 - 2.0 * u)


def _walk_foot(t, phase, x, centre, ground, yaw):
    p = (t + phase) % 1.0
    back = centre + _WALK_STRIDE * 0.5
    # The hind foot's ankle stands high, so its toes need more room to tip down.
    rise = 0.03 + 0.4 * ground
    if p < _WALK_DUTY:
        u = p / _WALK_DUTY
        y = centre - _WALK_STRIDE * 0.5 + _WALK_STRIDE * u
        peel = max(0.0, (u - 0.8) / 0.2)
        settle = max(0.0, 1.0 - u / 0.08)
        return {"at": (x, y, ground + rise * peel * peel), "rot": (30.0 * peel * peel - 10.0 * settle, yaw, 0.0)}
    v = (p - _WALK_DUTY) / (1.0 - _WALK_DUTY)
    y = back - _WALK_STRIDE * _smooth(v)
    z = ground + rise * (1.0 - v) + _WALK_LIFT * math.sin(math.pi * v)
    return {"at": (x, y, z), "rot": (30.0 - 40.0 * _smooth(v), yaw, 0.0)}


def walk_at(t):
    one = math.sin(2.0 * math.pi * t)
    two = math.sin(4.0 * math.pi * t)
    lag = math.sin(4.0 * math.pi * (t - 0.06))
    sway = math.sin(2.0 * math.pi * (t - 0.04))
    neck = [(-0.006 * sway * (i + 1) / 3.0, y, z + 0.002 * lag) for i, (_, y, z) in enumerate(_WALK_NECK)]
    tail = [(x + _WALK_TAIL_SWING[i] * math.sin(2.0 * math.pi * (t - 0.12 * (i + 1))), y, z)
            for i, (x, y, z) in enumerate(_WALK_TAIL)]
    folded = wing_unfold(STANCE["wing"], open_wing(**FLARE), 0.05 + 0.025 * lag)
    return {
        "hip": (0.012 * one, 0.225, 0.262 + 0.005 * two),
        "back": [(0.004 * one, 0.07, 0.293 + 0.003 * two)],
        "chest": (-0.008 * one, -0.10, 0.229 + 0.004 * lag),
        "chest_rot": (6.0, -3.0 * one, 2.0 * one),
        "neck": neck,
        "head": (0.0, -0.41, 0.382 + 0.002 * lag),
        "look": (0.0, -1.0, -0.2),
        "feet": {name: _walk_foot(t, *foot) for name, foot in _WALK_FEET.items()},
        "tail": tail,
        "wing_L": folded,
        "wing_R": folded,
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


_STAND = STANCE["feet"]
_UP_1 = _k(
    hip=SPRAWL["hip"], back=SPRAWL["back"], chest=(0.0, -0.09, 0.135), chest_rot=(0, 2, -3),
    neck=[(0.01, -0.235, 0.165), (0.03, -0.295, 0.215), (0.05, -0.345, 0.26)],
    head=(0.07, -0.385, 0.27), look=(0.25, -1.0, -0.05),
    feet=_feet_mix(Hand_L={"at": (0.16, -0.25, 0.075), "rot": (-12, 15, 0)}),
    tail=SPRAWL["tail"], jaw=4.0, wing_k=0.4, wing_a=_SPRAWL_WING,
)
_UP_2 = _k(
    hip=(0.0, 0.235, 0.14), back=[(0.0, 0.075, 0.175)], chest=(0.0, -0.095, 0.185), chest_rot=(-2, 0, 2),
    neck=[(0.0, -0.24, 0.225), (0.01, -0.30, 0.285), (0.02, -0.345, 0.335)],
    head=(0.03, -0.385, 0.35), look=(0.12, -1.0, -0.1),
    feet=_feet_mix(Hand_L=_STAND["Hand_L"], Hand_R={"at": (-0.145, -0.215, 0.075), "rot": (-12, -13, 0)}),
    tail=[(0.03, 0.44, 0.12), (0.14, 0.72, 0.06), (0.36, 1.0, 0.03), (0.66, 1.18, 0.03)], wing_k=0.3, wing_a=_SPRAWL_WING,
)
_UP_3 = _k(
    hip=(0.0, 0.232, 0.175), back=[(0.0, 0.075, 0.225)], chest=(0.0, -0.098, 0.225), chest_rot=(1, 0, 0),
    neck=[(0.0, -0.245, 0.255), (0.005, -0.30, 0.32), (0.01, -0.345, 0.38)],
    head=(0.02, -0.385, 0.395), look=(0.08, -1.0, -0.14),
    feet={"Hand_L": _STAND["Hand_L"], "Hand_R": _STAND["Hand_R"],
          "back_food_L": {"at": (0.15, 0.27, 0.17), "rot": (-10, 14, 0)}, "back_food_R": _SPRAWL_FEET["back_food_R"]},
    tail=[(0.025, 0.44, 0.15), (0.13, 0.72, 0.07), (0.34, 1.0, 0.03), (0.64, 1.18, 0.03)], wing_k=0.2,
)
_UP_4 = _k(
    hip=(0.0, 0.228, 0.235), back=[(0.0, 0.072, 0.275)], chest=(0.0, -0.10, 0.24), chest_rot=(3, 0, 0),
    neck=[(0.0, -0.25, 0.268), (0.005, -0.30, 0.33), (0.01, -0.345, 0.39)],
    head=(0.015, -0.385, 0.41), look=(0.09, -1.0, -0.16),
    feet={"Hand_L": _STAND["Hand_L"], "Hand_R": _STAND["Hand_R"], "back_food_L": _STAND["back_food_L"],
          "back_food_R": {"at": (-0.145, 0.24, 0.17), "rot": (-10, -12, 0)}},
    tail=[(0.02, 0.435, 0.18), (0.12, 0.72, 0.075), (0.33, 1.02, 0.03), (0.62, 1.2, 0.03)], wing_k=0.1,
)
_GET_UP = one_shot([SPRAWL, _UP_1, _UP_2, _UP_3, _UP_4, _k()], [0, 7, 14, 21, 28, 38], ACTION_LAG)


# --- Death ------------------------------------------------------------------
# Rears in pain, the forelegs give, and the whole body rolls onto its left side
# and settles. The roll is done rigidly with `body` after the rig has solved, so
# the legs and neck are authored in the upright frame: its left side goes to the
# ground, so a limb's local x has to stay small on that side or it sinks.

_UPRIGHT = {"pivot": (0.0, 0.1, 0.25), "rot": (0.0, 0.0, 0.0), "shift": (0.0, 0.0, 0.0)}
_DOWN_ROLL = 76.0
_DOWN_WING_L = {"lift": 88, "sweep": -8, "twist": -6, "elbow": 14, "wrist": -24, "back": 8, "fan": 0.55}
_DOWN_WING_R = {"lift": 100, "sweep": -22, "twist": -10, "elbow": 42, "wrist": -58, "back": 24, "fan": 0.4}


def _d(roll=0.0, shift=(0.0, 0.0, 0.0), **changes):
    return _k(body={"pivot": _UPRIGHT["pivot"], "rot": (0.0, 0.0, roll), "shift": shift}, **changes)


_DIE_REAR = _d(
    hip=(0.0, 0.25, 0.268), back=[(0.0, 0.095, 0.315)], chest=(0.0, -0.075, 0.27), chest_rot=(-10, 2, -3),
    neck=[(0.0, -0.205, 0.355), (-0.015, -0.215, 0.435), (-0.03, -0.245, 0.495)],
    head=(-0.04, -0.28, 0.525), look=(-0.2, -1.0, 0.55),
    tail=[(0.0, 0.47, 0.22), (0.08, 0.76, 0.11), (0.26, 1.07, 0.04), (0.54, 1.28, 0.03)],
    jaw=42.0, lip=14.0, wing_k=0.38,
)
_DIE_BUCKLE = _d(
    roll=6.0, shift=(0.0, 0.0, -0.02),
    hip=(0.0, 0.235, 0.25), back=[(0.0, 0.08, 0.262)], chest=(0.0, -0.09, 0.19), chest_rot=(12, 3, 4),
    neck=[(0.01, -0.245, 0.21), (0.03, -0.31, 0.245), (0.04, -0.365, 0.265)],
    head=(0.05, -0.405, 0.262), look=(0.1, -1.0, -0.3),
    feet=_feet(
        Hand_L={"at": (0.10, -0.215, 0.05), "rot": (28, 8, 0)},
        Hand_R={"at": (-0.10, -0.165, 0.065), "rot": (34, -6, 0)},
    ),
    tail=[(0.02, 0.44, 0.19), (0.06, 0.73, 0.10), (0.16, 1.04, 0.06), (0.30, 1.26, 0.06)],
    jaw=26.0, lip=6.0, wing_k=0.3,
)
_LIMP_FEET = {
    "Hand_L": {"at": (0.03, -0.205, 0.145), "rot": (55, 0, 0)},
    "Hand_R": {"at": (-0.07, -0.20, 0.10), "rot": (60, 0, 0)},
    "back_food_L": {"at": (0.035, 0.28, 0.165), "rot": (40, 0, 0)},
    "back_food_R": {"at": (-0.07, 0.30, 0.13), "rot": (48, 0, 0)},
}
_LIMP = dict(
    hip=(0.0, 0.23, 0.225), back=[(0.0, 0.075, 0.24)], chest=(0.0, -0.09, 0.215), chest_rot=(4, 0, 0),
    neck=[(0.01, -0.245, 0.21), (0.02, -0.32, 0.205), (0.03, -0.40, 0.205)],
    head=(0.035, -0.47, 0.20), look=(0.1, -1.0, -0.1),
    feet=_LIMP_FEET,
    tail=[(0.03, 0.43, 0.13), (0.04, 0.72, 0.17), (0.065, 1.02, 0.26), (0.10, 1.28, 0.40)],
)
_DIE_ROLLING = _d(
    roll=36.0, shift=(0.0, 0.0, -0.03),
    hip=(0.0, 0.232, 0.24), back=[(0.0, 0.08, 0.252)], chest=(0.0, -0.09, 0.20), chest_rot=(8, 2, 2),
    neck=[(0.01, -0.245, 0.215), (0.025, -0.315, 0.225), (0.035, -0.385, 0.235)],
    head=(0.04, -0.44, 0.24), look=(0.1, -1.0, -0.2),
    feet={
        "Hand_L": {"at": (0.06, -0.21, 0.10), "rot": (45, 4, 0)},
        "Hand_R": {"at": (-0.09, -0.185, 0.085), "rot": (48, -4, 0)},
        "back_food_L": {"at": (0.07, 0.25, 0.14), "rot": (22, 3, 0)},
        "back_food_R": {"at": (-0.09, 0.25, 0.115), "rot": (25, -3, 0)},
    },
    tail=[(0.0, 0.43, 0.16), (0.02, 0.72, 0.16), (0.05, 1.03, 0.19), (0.08, 1.27, 0.25)],
    jaw=20.0, lip=4.0, wing_k=0.35, wing_a_L=_DOWN_WING_L, wing_a_R=_DOWN_WING_R,
)
_DIE_HIT = _d(roll=_DOWN_ROLL, shift=(0.0, 0.0, -0.14), jaw=30.0, lip=6.0, wing_k=0.72, wing_k_R=0.55,
              wing_a_L=_DOWN_WING_L, wing_a_R=_DOWN_WING_R, **_LIMP)
_DIE_BOUNCE = _d(roll=_DOWN_ROLL - 7.0, shift=(0.0, 0.0, -0.105), jaw=24.0, lip=4.0, wing_k=0.66, wing_k_R=0.5,
                 wing_a_L=_DOWN_WING_L, wing_a_R=_DOWN_WING_R, **_LIMP)
_DIE_REST = _d(roll=_DOWN_ROLL, shift=(0.0, 0.0, -0.13), jaw=22.0, lip=2.0, wing_k=0.7, wing_k_R=0.46,
               wing_a_L=_DOWN_WING_L, wing_a_R=_DOWN_WING_R, **_LIMP)
_DIE_NEUTRAL = _d()
# Rolling sideways, a tail that trails far behind the body swings through the floor.
DEATH_LAG = dict(ACTION_LAG, tail=[0.5, 1.0, 1.5, 2.0])
_DEATH = one_shot([_DIE_NEUTRAL, _DIE_REAR, _DIE_REAR, _DIE_BUCKLE, _DIE_ROLLING, _DIE_HIT, _DIE_BOUNCE, _DIE_REST],
                  [0, 8, 13, 22, 31, 38, 44, 60], DEATH_LAG)


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
# Winds the tail out to its right, then spins hard so the tail comes round the
# left side at knee height while the head stays on the target. The turn is the
# whole body on `body`; the feet hop through the fast part so they don't skate.

def _spin(yaw, **changes):
    return _k(body={"pivot": (0.0, 0.05, 0.0), "rot": (0.0, yaw, 0.0), "shift": (0.0, 0.0, 0.0)}, **changes)


def _hopped(rise):
    return {n: dict(f, at=(f["at"][0], f["at"][1], f["at"][2] + rise)) for n, f in STANCE["feet"].items()}


_SW_WIND = _spin(
    14.0,
    hip=(-0.01, 0.235, 0.255), back=[(-0.005, 0.08, 0.285)], chest=(0.005, -0.095, 0.24), chest_rot=(8, -10, 0),
    neck=[(-0.01, -0.245, 0.27), (-0.03, -0.30, 0.33), (-0.05, -0.345, 0.385)],
    head=(-0.07, -0.385, 0.40), look=(-0.35, -1.0, -0.15),
    tail=[(-0.04, 0.43, 0.20), (-0.20, 0.70, 0.09), (-0.48, 0.92, 0.04), (-0.82, 0.98, 0.04)],
    wing_k=0.2,
)
_SW_FAST = _spin(
    -24.0,
    hip=(0.0, 0.225, 0.262), back=[(0.0, 0.07, 0.288)], chest=(0.0, -0.10, 0.235), chest_rot=(8, 6, 0),
    neck=[(0.01, -0.25, 0.262), (0.035, -0.31, 0.31), (0.07, -0.355, 0.36)],
    head=(0.10, -0.395, 0.375), look=(0.4, -1.0, -0.16),
    feet=_hopped(0.05),
    tail=[(0.02, 0.44, 0.20), (0.04, 0.74, 0.09), (0.05, 1.05, 0.05), (0.08, 1.33, 0.05)],
    wing_k=0.34,
)
_SW_STRIKE = _spin(
    -52.0,
    hip=(0.01, 0.225, 0.258), back=[(0.01, 0.07, 0.285)], chest=(0.01, -0.10, 0.232), chest_rot=(9, 16, 2),
    neck=[(0.02, -0.25, 0.258), (0.07, -0.30, 0.30), (0.13, -0.335, 0.345)],
    head=(0.18, -0.365, 0.36), look=(0.75, -1.0, -0.14),
    feet=_hopped(0.012),
    tail=[(0.06, 0.43, 0.20), (0.24, 0.69, 0.10), (0.54, 0.86, 0.06), (0.90, 0.86, 0.06)],
    jaw=14.0, lip=4.0, wing_k=0.3,
)
_SW_FOLLOW = _spin(
    -60.0,
    hip=(0.012, 0.225, 0.26), back=[(0.01, 0.07, 0.288)], chest=(0.01, -0.10, 0.238), chest_rot=(8, 18, 2),
    neck=[(0.02, -0.25, 0.262), (0.075, -0.30, 0.31), (0.14, -0.335, 0.36)],
    head=(0.19, -0.365, 0.375), look=(0.82, -1.0, -0.14),
    tail=[(0.07, 0.42, 0.20), (0.28, 0.64, 0.09), (0.62, 0.72, 0.05), (0.96, 0.62, 0.04)],
    jaw=6.0, wing_k=0.22,
)
_SW_BACK = _spin(
    -22.0,
    hip=(0.004, 0.225, 0.264), back=[(0.004, 0.07, 0.296)], chest=(0.004, -0.10, 0.246), chest_rot=(6, 6, 0),
    neck=[(0.006, -0.25, 0.272), (0.02, -0.30, 0.335), (0.035, -0.345, 0.395)],
    head=(0.05, -0.385, 0.413), look=(0.3, -1.0, -0.17),
    feet=_hopped(0.045),
    tail=[(0.03, 0.43, 0.20), (0.14, 0.72, 0.08), (0.36, 1.0, 0.03), (0.66, 1.18, 0.03)],
    wing_k=0.08,
)
_SW_REST = _spin(0.0)
_SWIPE_FRAMES = [0, 8, 12, 16, 19, 24, 31, 40]
_SWIPE_BODY = one_shot([_SW_REST, _SW_WIND, _SW_WIND, _SW_FAST, _SW_STRIKE, _SW_FOLLOW, _SW_BACK, _SW_REST],
                       _SWIPE_FRAMES, ACTION_LAG, {"impact": [19]})
# Where the tail points at each key, in degrees, + to its left. Each joint gets a
# growing share of it, a frame later than the joint before.
_SWIPE_ANGLE = [25.0, -55.0, -55.0, 10.0, 58.0, 62.0, 25.0, 25.0]
_SWIPE_SHARE = [0.35, 0.7, 1.0, 1.2]
_SWIPE_LENGTH = [0.205, 0.31, 0.365, 0.34]
_SWIPE_Z = [0.20, 0.085, 0.05, 0.05]


def tail_swipe_at(t):
    out = _SWIPE_BODY["at"](t)
    length = _SWIPE_FRAMES[-1]
    f = t * length
    fade = min(1.0, (length - f) / 6.0)
    x, y = 0.0, STANCE["hip"][1]
    swept = []
    for i, z in enumerate(_SWIPE_Z):
        heading = math.radians(_once(_SWIPE_ANGLE, _SWIPE_FRAMES, f - (i + 1.0) * fade) * _SWIPE_SHARE[i])
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
# The game rotates the unit; this shuffles the feet under it, head leading. In
# the unit's own frame the planted feet slide against the turn and the lifted
# ones step with it.

TURN_FRAMES = 20
_TURN_ORDER = {"Hand_L": 0.0, "back_food_R": 0.25, "Hand_R": 0.5, "back_food_L": 0.75}
_TURN_STRIDE = 0.10
_TURN_DUTY = 0.62


def _turn_foot(name, t, sign):
    rest = STANCE["feet"][name]
    fore = name.startswith("Hand")
    p = (t + _TURN_ORDER[name]) % 1.0
    if p < _TURN_DUTY:
        slide = 0.5 - p / _TURN_DUTY
        lift = 0.0
    else:
        v = (p - _TURN_DUTY) / (1.0 - _TURN_DUTY)
        slide = -0.5 + _smooth(v)
        lift = 0.06 * math.sin(math.pi * v)
    dx = _TURN_STRIDE * slide * sign * (1.0 if fore else -1.0)
    x, y, z = rest["at"]
    rot = rest["rot"]
    return {"at": (x + dx, y, z + lift), "rot": (rot[0], rot[1] + 12.0 * slide * sign * (1.0 if fore else -1.0), rot[2])}


def _turn_at(t, sign):
    bob = math.sin(4.0 * math.pi * t)
    h, c = STANCE["hip"], STANCE["chest"]
    tail = [(x - sign * (0.02 + 0.05 * i) , y, z) for i, (x, y, z) in enumerate(STANCE["tail"])]
    n = STANCE["neck"]
    return {
        "hip": (h[0] - 0.006 * sign, h[1], h[2] + 0.003 * bob),
        "back": STANCE["back"],
        "chest": (c[0] + 0.006 * sign, c[1], c[2] + 0.003 * bob),
        "chest_rot": (STANCE["chest_rot"][0], 6.0 * sign, 0.0),
        "neck": [(n[0][0] + 0.012 * sign, n[0][1], n[0][2]), (n[1][0] + 0.035 * sign, n[1][1], n[1][2]), (n[2][0] + 0.065 * sign, n[2][1], n[2][2])],
        "head": (STANCE["head"][0] + 0.095 * sign, STANCE["head"][1] + 0.01, STANCE["head"][2]),
        "look": (0.55 * sign, -1.0, -0.15),
        "feet": {name: _turn_foot(name, t, sign) for name in _TURN_ORDER},
        "tail": tail,
        "wing": STANCE["wing"],
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
    tail_swipe=_TAIL_SWIPE,
    wing_buffet=_WING_BUFFET,
    turn_l={"length": TURN_FRAMES / 24.0, "at": lambda t: _turn_at(t, 1.0)},
    turn_r={"length": TURN_FRAMES / 24.0, "at": lambda t: _turn_at(t, -1.0)},
)
ALOFT = set(poses.ALOFT) | {"bite_air", "claw_air", "breath_air", "breath_hold_air", "breath_out_air", "hit_air", "wing_buffet"}
LIFTED = set(poses.LIFTED)
