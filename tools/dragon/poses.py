# The dragon's key poses, as body_rig.py reads them.

import math

from body_rig import WING_FACE
from mathutils import Matrix, Quaternion, Vector

# The stance every clip starts and ends on: low and heavy, weight toward the
# forelegs, feet on a diagonal, neck in an S, wings shut on the back, the tail
# laid out to one side so the shape reads from a CRPG camera.
STANCE = {
    "hip": (0.0, 0.225, 0.268),
    "back": [(0.0, 0.07, 0.302)],
    "chest": (0.0, -0.10, 0.25),
    "chest_rot": (5, 0, 0),
    "neck": [(0.0, -0.25, 0.275), (0.0, -0.30, 0.335), (0.0, -0.345, 0.395)],
    "head": (0.012, -0.385, 0.415),
    "look": (0.10, -1.0, -0.18),
    "feet": {
        "Hand_L": {"at": (0.108, -0.235, 0.0165), "rot": (0, 8, 0)},
        "Hand_R": {"at": (-0.104, -0.175, 0.0165), "rot": (0, -6, 0)},
        "back_food_L": {"at": (0.098, 0.238, 0.1016), "rot": (0, 5, 0)},
        "back_food_R": {"at": (-0.098, 0.195, 0.1016), "rot": (0, -5, 0)},
    },
    "tail": [(0.02, 0.43, 0.195), (0.12, 0.72, 0.075), (0.33, 1.02, 0.03), (0.62, 1.2, 0.03)],
    "wing": {
        "out": (1.0, 0.0, 0.3),
        "fingers": [
            [(0.12, 0.22, 0.40), (0.15, -0.04, 0.56), (0.17, 0.70, 0.20)],
            [(0.11, 0.09, 0.26), (0.145, -0.12, 0.42), (0.17, 0.40, 0.17)],
            [(0.09, -0.01, 0.31), (0.12, -0.12, 0.33), (0.15, 0.14, 0.13)],
        ],
    },
}

# Top of the breath: ribcage up and forward, head carried up with it, the wings
# lifted by the chest, the tail drifting away. The paws never move.
INHALE = dict(STANCE, **{
    "hip": (0.0, 0.225, 0.273),
    "back": [(0.0, 0.07, 0.314)],
    "chest": (0.0, -0.106, 0.268),
    "chest_rot": (1, 0, 0),
    "neck": [(0.0, -0.255, 0.296), (0.0, -0.303, 0.358), (0.0, -0.343, 0.42)],
    "head": (0.012, -0.38, 0.442),
    "look": (0.10, -1.0, -0.10),
    "tail": [(0.024, 0.43, 0.2), (0.14, 0.72, 0.08), (0.37, 1.01, 0.03), (0.68, 1.17, 0.03)],
    "wing": {
        "out": (1.0, 0.0, 0.34),
        "fingers": [
            [(0.125, 0.22, 0.405), (0.158, -0.04, 0.565), (0.185, 0.70, 0.215)],
            [(0.115, 0.09, 0.265), (0.153, -0.12, 0.425), (0.19, 0.40, 0.18)],
            [(0.092, -0.01, 0.312), (0.125, -0.12, 0.333), (0.165, 0.14, 0.14)],
        ],
    },
})

# Weight over the left legs. Played negative it goes over the right.
WEIGHT = dict(STANCE, **{
    "hip": (0.007, 0.225, 0.268),
    "back": [(0.011, 0.07, 0.302)],
    "chest": (0.015, -0.10, 0.25),
    "chest_rot": (5, 0, 2.5),
    "neck": [(0.009, -0.25, 0.275), (0.005, -0.30, 0.335), (0.002, -0.345, 0.395)],
})

# Head turned to its left, the neck giving a little. Negative looks right.
GLANCE = dict(STANCE, **{
    "neck": [(0.003, -0.25, 0.275), (0.01, -0.30, 0.335), (0.022, -0.345, 0.395)],
    "head": (0.034, -0.385, 0.415),
    "look": (0.30, -1.0, -0.18),
})

# The tail laid further out to its side. Negative curls it back in.
TAIL_SWAY = dict(STANCE, **{
    "tail": [(0.026, 0.43, 0.195), (0.15, 0.715, 0.075), (0.39, 1.0, 0.03), (0.71, 1.14, 0.03)],
})

# Wings hitched up and in against the back, the shrug of something settling.
WING_SETTLE = dict(STANCE, **{
    "wing": {
        "out": (1.0, 0.0, 0.3),
        "fingers": [
            [(0.117, 0.22, 0.414), (0.142, -0.04, 0.578), (0.15, 0.70, 0.215)],
            [(0.107, 0.09, 0.272), (0.138, -0.12, 0.436), (0.15, 0.40, 0.185)],
            [(0.087, -0.01, 0.32), (0.114, -0.12, 0.342), (0.135, 0.14, 0.14)],
        ],
    },
})

# Each left finger at rest: shoulder, knuckle, knuckle, tip. The rest pose is a
# fully spread wing, so an open wing is that one turned at its joints.
_WING_REST = [
    [(0.0578, -0.1305, 0.3133), (0.3614, -0.359, 0.3667), (0.6466, -0.4739, 0.2995), (1.3918, -0.2273, 0.0792)],
    [(0.052, -0.1278, 0.3296), (0.2997, -0.1153, 0.3246), (0.5851, -0.2325, 0.3679), (1.1159, -0.0137, 0.3127)],
    [(0.0597, -0.1103, 0.3462), (0.1029, -0.0045, 0.3001), (0.2161, -0.0608, 0.3291), (0.1894, 0.2049, 0.205)],
]


def _about(axis, degrees):
    return Quaternion(axis, math.radians(degrees))


def open_wing(lift=0.0, sweep=0.0, twist=0.0, elbow=0.0, wrist=0.0, back=0.0, fan=1.0):
    """A spread wing, in degrees relative to the ribcage.

    lift raises the whole wing at the shoulder, sweep brings it forward, twist
    dips its leading edge. elbow and wrist bend the outer wing up at those
    joints (negative droops it), back folds the hand behind the wrist, and fan
    is how open the fingers are, 1 fully, 0 shut onto the leading finger.
    """
    x, y, z = (1, 0, 0), (0, 1, 0), (0, 0, 1)
    whole = _about(y, -lift) @ _about(z, -sweep) @ _about(x, twist)
    at_elbow = _about(y, -elbow)
    at_wrist = _about(y, -wrist) @ _about(z, back)
    lead = Vector(_WING_REST[0][3]) - Vector(_WING_REST[0][0])
    fingers, ups = [], []
    for rest in _WING_REST:
        j = [Vector(p) for p in rest]
        heading = math.degrees((j[3] - j[0]).xy.angle_signed(lead.xy))
        fold = _about(z, heading * (fan - 1.0))
        turns = [whole @ fold, whole @ fold @ at_elbow, whole @ fold @ at_elbow @ at_wrist]
        p = j[0]
        points = []
        for i, turn in enumerate(turns):
            p = p + turn @ (j[i + 1] - j[i])
            points.append(tuple(p))
        fingers.append(points)
        ups.append([tuple(turn @ Vector(z)) for turn in turns])
    return {"out": (0.0, 0.0, 1.0), "fingers": fingers, "ups": ups}


def _flight_feet(hand_y, hand_z, foot_y, foot_z):
    """Forelegs drawn up to the chest, hind legs hanging, one side a beat off."""
    return {
        "Hand_L": {"at": (0.085, hand_y, hand_z), "rot": (70, 6, 0)},
        "Hand_R": {"at": (-0.085, hand_y + 0.014, hand_z + 0.012), "rot": (64, -5, 0)},
        "back_food_L": {"at": (0.135, foot_y, foot_z), "rot": (58, 14, 0)},
        "back_food_R": {"at": (-0.12, foot_y - 0.03, foot_z + 0.05), "rot": (42, -12, 0)},
    }


# Hovering: spine pitched up about 30 degrees, the ribcage hung from the wings,
# the tail low and then curling out behind as the counterweight. Height matches
# where the model flew, so the game places it the same.

# The wing at each key, as angles: a stroke is swung through these, so the tips
# travel arcs instead of cutting straight across.
HOVER_WING = [
    {"lift": 50, "sweep": -10, "twist": -15, "elbow": 0, "wrist": -25, "back": 0, "fan": 0.9},
    {"lift": 5, "sweep": 5, "twist": 18, "elbow": 6, "wrist": 12, "back": 0, "fan": 1.0},
    {"lift": -38, "sweep": 4, "twist": 14, "elbow": -6, "wrist": -12, "back": 0, "fan": 0.95},
    {"lift": 30, "sweep": -6, "twist": -20, "elbow": 15, "wrist": -95, "back": 35, "fan": 0.55},
]

# Wings high and open, about to drive. The body has sunk to its lowest.
HOVER_TOP = {
    "hip": (0.0, 0.20, 0.535),
    "back": [(0.0, 0.06, 0.628)],
    "chest": (0.0, -0.085, 0.693),
    "chest_rot": (-27, 0, 0),
    "neck": [(0.0, -0.189, 0.806), (0.0, -0.215, 0.874), (0.0, -0.252, 0.931)],
    "head": (0.0, -0.275, 0.965),
    "look": (0.0, -1.0, -0.12),
    "feet": _flight_feet(-0.205, 0.55, 0.26, 0.255),
    "tail": [(0.015, 0.36, 0.41), (0.04, 0.62, 0.29), (0.08, 0.96, 0.28), (0.14, 1.22, 0.36)],
    "wing": open_wing(**HOVER_WING[0]),
}

# Wings level at full spread, leading edge dipped, the tips bent up by the air.
HOVER_DRIVE = {
    "hip": (0.0, 0.20, 0.565),
    "back": [(0.0, 0.06, 0.66)],
    "chest": (0.0, -0.079, 0.733),
    "chest_rot": (-29, 0, 0),
    "neck": [(0.0, -0.18, 0.8425), (0.0, -0.21, 0.9036), (0.0, -0.253, 0.9545)],
    "head": (0.0, -0.28, 0.985),
    "look": (0.0, -1.0, -0.12),
    "feet": _flight_feet(-0.205, 0.58, 0.25, 0.27),
    "tail": [(0.015, 0.36, 0.435), (0.04, 0.625, 0.305), (0.08, 0.96, 0.30), (0.14, 1.22, 0.40)],
    "wing": open_wing(**HOVER_WING[1]),
}

# Wings low and forward, the body carried to the top of its bounce.
HOVER_BOTTOM = {
    "hip": (0.0, 0.20, 0.60),
    "back": [(0.0, 0.06, 0.697)],
    "chest": (0.0, -0.07, 0.782),
    "chest_rot": (-32, 0, 0),
    "neck": [(0.0, -0.1655, 0.8875), (0.0, -0.196, 0.94), (0.0, -0.255, 0.984)],
    "head": (0.0, -0.29, 1.01),
    "look": (0.0, -1.0, -0.12),
    "feet": _flight_feet(-0.20, 0.615, 0.24, 0.285),
    "tail": [(0.015, 0.36, 0.47), (0.04, 0.625, 0.32), (0.08, 0.955, 0.28), (0.14, 1.21, 0.34)],
    "wing": open_wing(**HOVER_WING[2]),
}

# Coming back up: the arm lifts first, the hand hanging and folded behind it so
# the wing slips through the air it has just pushed.
HOVER_RECOVER = {
    "hip": (0.0, 0.20, 0.575),
    "back": [(0.0, 0.06, 0.67)],
    "chest": (0.0, -0.076, 0.748),
    "chest_rot": (-30, 0, 0),
    "neck": [(0.0, -0.174, 0.859), (0.0, -0.206, 0.919), (0.0, -0.255, 0.97)],
    "head": (0.0, -0.285, 1.0),
    "look": (0.0, -1.0, -0.12),
    "feet": _flight_feet(-0.205, 0.60, 0.25, 0.28),
    "tail": [(0.015, 0.36, 0.45), (0.04, 0.625, 0.32), (0.08, 0.96, 0.33), (0.14, 1.22, 0.45)],
    "wing": open_wing(**HOVER_WING[3]),
}

HOVER_KEYS = [HOVER_TOP, HOVER_DRIVE, HOVER_BOTTOM, HOVER_RECOVER]


# Flying forward: the spine laid out nearly level, neck reaching ahead, legs
# drawn up and back, tail streaming straight behind. The same beat as the hover
# and at the same height, so the two loops cross-fade on the stroke.
def _cruise(rise, head_rise, wing, tail_z):
    """Key pose: rise lifts the body, head_rise the head, which moves less."""
    hip, chest = 0.62 + rise, 0.675 + rise * 1.25
    head = 0.795 + head_rise
    return {
        "hip": (0.0, 0.22, hip),
        "back": [(0.0, 0.06, (hip + chest) * 0.5 + 0.022)],
        "chest": (0.0, -0.10, chest),
        "chest_rot": (-8, 0, 0),
        "neck": [(0.0, -0.241, chest + 0.059), (0.0, -0.31, chest + 0.085 + (head_rise - rise) * 0.4), (0.0, -0.38, head - 0.015)],
        "head": (0.0, -0.44, head),
        "look": (0.0, -1.0, -0.16),
        "feet": {
            "Hand_L": {"at": (0.085, -0.17, chest - 0.165), "rot": (104, 6, 0)},
            "Hand_R": {"at": (-0.085, -0.155, chest - 0.155), "rot": (97, -5, 0)},
            "back_food_L": {"at": (0.125, 0.56, hip - 0.13), "rot": (138, 8, 0)},
            "back_food_R": {"at": (-0.125, 0.53, hip - 0.105), "rot": (126, -8, 0)},
        },
        "tail": [(0.005, 0.48, hip - 0.03 + tail_z * 0.2), (0.02, 0.78, hip - 0.09 + tail_z * 0.5), (0.05, 1.1, hip - 0.145 + tail_z), (0.1, 1.41, hip - 0.11 + tail_z * 1.6)],
        "wing": open_wing(**wing),
    }


CRUISE_WING = [
    {"lift": 42, "sweep": -6, "twist": -6, "elbow": 0, "wrist": -20, "back": 0, "fan": 0.95},
    {"lift": 2, "sweep": 12, "twist": 12, "elbow": 5, "wrist": 10, "back": 0, "fan": 1.0},
    {"lift": -32, "sweep": 14, "twist": 8, "elbow": -5, "wrist": -10, "back": 0, "fan": 1.0},
    {"lift": 22, "sweep": -14, "twist": -14, "elbow": 18, "wrist": -80, "back": 45, "fan": 0.5},
]

CRUISE_KEYS = [
    _cruise(0.0, 0.0, CRUISE_WING[0], 0.0),
    _cruise(0.015, 0.008, CRUISE_WING[1], 0.01),
    _cruise(0.03, 0.018, CRUISE_WING[2], -0.01),
    _cruise(0.018, 0.012, CRUISE_WING[3], 0.02),
]

POSES = {
    "stance": STANCE,
    "inhale": INHALE,
    "weight": WEIGHT,
    "glance": GLANCE,
    "wing_settle": WING_SETTLE,
    "hover_top": HOVER_TOP,
    "hover_drive": HOVER_DRIVE,
    "hover_bottom": HOVER_BOTTOM,
    "hover_recover": HOVER_RECOVER,
    "cruise_top": CRUISE_KEYS[0],
    "cruise_drive": CRUISE_KEYS[1],
    "cruise_bottom": CRUISE_KEYS[2],
    "cruise_recover": CRUISE_KEYS[3],
}

# Framed for open wings and height off the ground.
ALOFT = {"hover_top", "hover_drive", "hover_bottom", "hover_recover", "hover_blocked", "hover",
         "cruise_top", "cruise_drive", "cruise_bottom", "cruise_recover", "cruise_blocked", "cruise", "land_blocked", "land"}


def _layer(value, stance, key, curve, t, lag):
    """Adds key's offset from the stance. A list of lags trails along a chain."""
    if isinstance(value, dict):
        return {k: _layer(value[k], stance[k], key[k], curve, t, lag) for k in value}
    if isinstance(value, list):
        lags = lag if isinstance(lag, list) else [lag] * len(value)
        return [_layer(v, s, k, curve, t, l) for v, s, k, l in zip(value, stance, key, lags)]
    w = curve(t - lag)
    return tuple(v + (k - s) * w for v, s, k in zip(value, stance, key))


def _breaths(t):
    """Two breaths to the loop, the second shallower. A shorter draw in, a longer let go."""
    t %= 1.0
    depth = 1.0 if t < 0.5 else 0.82
    u = (t * 2.0) % 1.0
    k = u / 0.42 if u < 0.42 else (1.0 - u) / 0.58
    return depth * (0.5 - 0.5 * math.cos(math.pi * k))


def _moves(moves):
    """Holds joined by eased moves: (start, end, value) in fractions of the loop."""
    def at(t):
        t %= 1.0
        value = moves[-1][2]
        for start, end, target in moves:
            if t >= end:
                value = target
            elif t > start:
                k = (t - start) / (end - start)
                return value + (target - value) * k * k * k * (k * (6.0 * k - 15.0) + 10.0)
            else:
                break
        return value
    return at


def _sway(t):
    return math.sin(2.0 * math.pi * t)


_WEIGHT = _moves([(0.04, 0.24, 1.0), (0.46, 0.68, -1.0), (0.8, 0.98, 0.0)])
_GLANCE = _moves([(0.10, 0.16, 1.0), (0.36, 0.42, 0.0), (0.62, 0.68, -0.9), (0.84, 0.90, 0.0)])
_HITCH = _moves([(0.52, 0.56, 1.0), (0.58, 0.66, 0.0)])

# (key pose, curve, lag per control). The ribcage leads and the ends arrive late;
# a head turn starts at the skull and the neck follows it.
IDLE_LAYERS = [
    (INHALE, _breaths, {
        "chest": 0.0, "chest_rot": 0.0, "back": 0.005, "hip": 0.01,
        "neck": [0.02, 0.03, 0.04], "head": 0.05, "look": 0.065,
        "tail": [0.05, 0.07, 0.09, 0.11], "wing": 0.03,
    }),
    (WEIGHT, _WEIGHT, {"hip": 0.0, "back": 0.006, "chest": 0.012, "chest_rot": 0.012, "neck": [0.02, 0.024, 0.028]}),
    (GLANCE, _GLANCE, {"look": 0.0, "head": 0.006, "neck": [0.02, 0.014, 0.01]}),
    (TAIL_SWAY, _sway, {"tail": [0.0, 0.03, 0.06, 0.09]}),
]


def idle_at(t):
    out = dict(STANCE)
    for key, curve, lags in IDLE_LAYERS:
        for name, lag in lags.items():
            out[name] = _layer(out[name], STANCE[name], key[name], curve, t, lag)
    for side, lag in (("wing_L", 0.0), ("wing_R", 0.012)):
        out[side] = _layer(out["wing"], STANCE["wing"], WING_SETTLE["wing"], _HITCH, t, lag)
    return out


def _cycle(values, times, t):
    """A looping curve through values at times. Turns around on the keys, never past them."""
    t %= 1.0
    n = len(values)
    i = n - 1
    while times[i] > t:
        i -= 1
    span = lambda a: ((times[(a + 1) % n] - times[a % n]) % 1.0) or 1.0
    slope = lambda a: (values[(a + 1) % n] - values[a % n]) / span(a)

    def tangent(a):
        before, after = slope(a - 1), slope(a)
        return 0.0 if before * after <= 0.0 else 2.0 * before * after / (before + after)

    h = span(i)
    u = ((t - times[i]) % 1.0) / h
    a, b = values[i], values[(i + 1) % n]
    return ((2 * u ** 3 - 3 * u ** 2 + 1) * a + (u ** 3 - 2 * u ** 2 + u) * h * tangent(i)
            + (3 * u ** 2 - 2 * u ** 3) * b + (u ** 3 - u ** 2) * h * tangent(i + 1))


def _once(values, times, t):
    """_cycle for a clip that ends: holds its first and last values."""
    if t <= times[0]:
        return values[0]
    if t >= times[-1]:
        return values[-1]
    i = 0
    while times[i + 1] <= t:
        i += 1
    slope = lambda a: (values[a + 1] - values[a]) / (times[a + 1] - times[a])

    def tangent(a):
        if a <= 0 or a >= len(values) - 1:
            return 0.0
        before, after = slope(a - 1), slope(a)
        return 0.0 if before * after <= 0.0 else 2.0 * before * after / (before + after)

    h = times[i + 1] - times[i]
    u = (t - times[i]) / h
    a, b = values[i], values[i + 1]
    return ((2 * u ** 3 - 3 * u ** 2 + 1) * a + (u ** 3 - 2 * u ** 2 + u) * h * tangent(i)
            + (3 * u ** 2 - 2 * u ** 3) * b + (u ** 3 - u ** 2) * h * tangent(i + 1))


def _between(keys, times, t, lag, curve=_cycle):
    """The keys swung through at t, with lag shaped like them: one number or a matching tree."""
    first = keys[0]
    if isinstance(first, dict):
        return {k: _between([p[k] for p in keys], times, t, lag[k] if isinstance(lag, dict) else lag, curve) for k in first}
    if isinstance(first, list):
        lags = lag if isinstance(lag, list) else [lag] * len(first)
        return [_between([p[i] for p in keys], times, t, lags[i], curve) for i in range(len(first))]
    if isinstance(first, tuple):
        return tuple(curve([p[i] for p in keys], times, t - lag) for i in range(len(first)))
    return curve(keys, times, t - lag)


# Top, drive, bottom, recover. The push down is the hit, about a third of the beat;
# the lift back is unhurried and never faster than the push.
HOVER_TIMES = [0.0, 0.17, 0.36, 0.74]

# The arm leads, the hand arrives late. The leading edge turns first.
HOVER_WING_LAG = {"lift": 0.0, "sweep": 0.0, "twist": -0.012, "elbow": 0.015, "wrist": 0.035, "back": 0.03, "fan": 0.02}
HOVER_WING_R_LAG = 0.008

# The wings push and the body answers after them: ribcage, then the hips hung
# under it, then the legs and tail. Split at the ribcage so a breath can take
# the upper half and leave the wings and legs flying.
HOVER_UPPER_LAG = {
    "chest": 0.04, "chest_rot": 0.05,
    "neck": [0.05, 0.055, 0.06], "head": 0.065, "look": 0.07,
}
HOVER_LOWER_LAG = {
    "hip": 0.07, "back": 0.055,
    "tail": [0.09, 0.13, 0.17, 0.22],
    "feet": {"Hand_L": 0.09, "Hand_R": 0.105, "back_food_L": 0.12, "back_food_R": 0.145},
}

# Sideways and up-down reach of the whip along the tail, and how far behind each point runs.
HOVER_WHIP = [(0.0, 0.0, 0.0), (0.014, 0.02, 0.06), (0.035, 0.055, 0.12), (0.06, 0.1, 0.19)]


# Forward flight drags the tail straight: less side to side, more up and down.
CRUISE_WHIP = [(0.0, 0.0, 0.0), (0.008, 0.025, 0.06), (0.02, 0.065, 0.12), (0.035, 0.12, 0.19)]


def _whip(tail, table, t):
    out = []
    for point, (sideways, up, lag) in zip(tail, table):
        wave = math.sin(2.0 * math.pi * (t - lag))
        out.append((point[0] + sideways * wave, point[1], point[2] + up * wave))
    return out


def _flap(keys, wings, whip, t):
    """One wingbeat at t. Every flying loop shares its times, so they cross-fade on the stroke."""
    lags = dict(HOVER_UPPER_LAG, **HOVER_LOWER_LAG)
    out = {name: _between([key[name] for key in keys], HOVER_TIMES, t, lag) for name, lag in lags.items()}
    out["tail"] = _whip(out["tail"], whip, t)
    wing = lambda u: open_wing(**_between(wings, HOVER_TIMES, u, HOVER_WING_LAG))
    out["wing_L"] = wing(t)
    out["wing_R"] = wing(t - HOVER_WING_R_LAG)
    return out


def hover_at(t):
    return _flap(HOVER_KEYS, HOVER_WING, HOVER_WHIP, t)


def cruise_at(t):
    return _flap(CRUISE_KEYS, CRUISE_WING, CRUISE_WHIP, t)


# Taking off. The game holds the unit on the ground for 0.2 s (fly.tres
# lift_delay), then eases it up 3 m over 0.6 s; these keys sit on that climb, so
# a foot still pushing is placed against the ground it is leaving.
TAKEOFF_FRAMES = [0, 5, 9, 15, 24]


def takeoff_lift(frame):
    """How far the game has raised the body by this frame, at SM 0."""
    u = max(0.0, min(1.0, (frame / 24.0 - 0.2) / 0.6))
    return 0.6 * (0.5 - 0.5 * math.cos(math.pi * u))


def _facing(forward, up):
    y = forward.normalized()
    x = y.cross(up).normalized()
    return Matrix((x, y, x.cross(y))).transposed().to_quaternion()


def wing_unfold(shut, spread, k):
    """A wing part way open. Each segment turns from its folded heading to its
    spread one about its own joint, so the zigzag opens instead of cutting
    straight across the back. k is 0 folded, 1 spread."""
    out = Vector(shut["out"]).normalized()
    fingers, ups = [], []
    for rest, closed, opened, opened_ups in zip(_WING_REST, shut["fingers"], spread["fingers"], spread["ups"]):
        p, from_closed, from_opened = Vector(rest[0]), Vector(rest[0]), Vector(rest[0])
        points, faces = [], []
        for i in range(3):
            a, b = Vector(closed[i]), Vector(opened[i])
            turn = _facing(a - from_closed, out * WING_FACE[i]).slerp(_facing(b - from_opened, Vector(opened_ups[i])), k)
            from_closed, from_opened = a, b
            p = p + turn @ Vector((0.0, (Vector(rest[i + 1]) - Vector(rest[i])).length, 0.0))
            points.append(tuple(p))
            faces.append(tuple(turn @ Vector((0.0, 0.0, 1.0))))
        fingers.append(points)
        ups.append(faces)
    return {"out": shut["out"], "fingers": fingers, "ups": ups}


TAKEOFF_WING = [
    {"lift": 62, "sweep": -14, "twist": -14, "elbow": 8, "wrist": -38, "back": 18, "fan": 0.7},
    {"lift": 32, "sweep": -2, "twist": 10, "elbow": 5, "wrist": -8, "back": 0, "fan": 1.0},
    {"lift": -42, "sweep": 6, "twist": 16, "elbow": -8, "wrist": -14, "back": 0, "fan": 1.0},
]

# Sunk over its haunches with the head low, wings thrown up and nearly open.
TAKEOFF_CROUCH = {
    "hip": (0.0, 0.215, 0.205),
    "back": [(0.0, 0.07, 0.238)],
    "chest": (0.0, -0.095, 0.19),
    "chest_rot": (9, 0, 0),
    "neck": [(0.0, -0.245, 0.205), (0.0, -0.305, 0.25), (0.0, -0.36, 0.30)],
    "head": (0.0, -0.405, 0.32),
    "look": (0.0, -1.0, 0.02),
    "feet": STANCE["feet"],
    "tail": [(0.02, 0.41, 0.14), (0.11, 0.70, 0.04), (0.30, 1.0, 0.03), (0.58, 1.18, 0.03)],
    "wing": wing_unfold(STANCE["wing"], open_wing(**TAKEOFF_WING[0]), 0.8),
}

# Hind legs straight and still on the ground, forelegs already up, chest thrown
# skyward, the wings starting down.
TAKEOFF_PUSH = {
    "hip": (0.0, 0.22, 0.35),
    "back": [(0.0, 0.07, 0.43)],
    "chest": (0.0, -0.075, 0.50),
    "chest_rot": (-24, 0, 0),
    "neck": [(0.0, -0.18, 0.615), (0.0, -0.22, 0.672), (0.0, -0.265, 0.72)],
    "head": (0.0, -0.30, 0.745),
    "look": (0.0, -1.0, 0.05),
    "feet": {
        "Hand_L": {"at": (0.095, -0.20, 0.29), "rot": (60, 6, 0)},
        "Hand_R": {"at": (-0.09, -0.185, 0.305), "rot": (54, -5, 0)},
        "back_food_L": {"at": (0.098, 0.238, 0.1016 - takeoff_lift(9)), "rot": (25, 5, 0)},
        "back_food_R": {"at": (-0.098, 0.195, 0.1016 - takeoff_lift(9)), "rot": (25, -5, 0)},
    },
    "tail": [(0.015, 0.40, 0.31), (0.06, 0.67, 0.15), (0.17, 0.97, 0.03), (0.36, 1.24, -0.06)],
    "wing": open_wing(**TAKEOFF_WING[1]),
}

# Bottom of the first stroke: off the ground, hind legs trailing where they
# pushed, tail still catching up.
TAKEOFF_BOTTOM = {
    "hip": (0.0, 0.205, 0.52),
    "back": [(0.0, 0.06, 0.62)],
    "chest": (0.0, -0.075, 0.70),
    "chest_rot": (-32, 0, 0),
    "neck": [(0.0, -0.17, 0.81), (0.0, -0.20, 0.875), (0.0, -0.25, 0.93)],
    "head": (0.0, -0.285, 0.96),
    "look": (0.0, -1.0, -0.12),
    "feet": {
        "Hand_L": {"at": (0.085, -0.20, 0.53), "rot": (66, 6, 0)},
        "Hand_R": {"at": (-0.085, -0.186, 0.542), "rot": (60, -5, 0)},
        "back_food_L": {"at": (0.12, 0.30, 0.19), "rot": (75, 10, 0)},
        "back_food_R": {"at": (-0.11, 0.27, 0.22), "rot": (65, -10, 0)},
    },
    "tail": [(0.015, 0.37, 0.39), (0.05, 0.62, 0.22), (0.12, 0.93, 0.12), (0.24, 1.20, 0.13)],
    "wing": open_wing(**TAKEOFF_WING[2]),
}

# The last stretch is the hover's own upstroke, so the loop picks up with no seam.
TAKEOFF_HOVER_FROM = 0.75
TAKEOFF_KEYS = [STANCE, TAKEOFF_CROUCH, TAKEOFF_PUSH, TAKEOFF_BOTTOM, hover_at(TAKEOFF_HOVER_FROM), hover_at(0.0)]
_TAKEOFF_KEY_FRAMES = TAKEOFF_FRAMES + [34]


def takeoff_blocked_at(t):
    i = min(int(t * len(TAKEOFF_KEYS) + 1e-6), len(TAKEOFF_KEYS) - 1)
    return dict(TAKEOFF_KEYS[i], lift=takeoff_lift(_TAKEOFF_KEY_FRAMES[i]))


_TAKEOFF_LENGTH = 34
_TAKEOFF_HOVER_AT = 24
_TAKEOFF_RELEASE = 9
_HIND_FEET = ("back_food_L", "back_food_R")

# The extra key is only there to give the last one the hover's speed.
_TAKEOFF_CURVE_FRAMES = TAKEOFF_FRAMES + [25]
_TAKEOFF_CURVE_KEYS = TAKEOFF_KEYS[:5] + [hover_at(TAKEOFF_HOVER_FROM + 1.0 / 40.0)]

# In frames. The legs do the pushing, so the hips lead and the rest is thrown up by them.
TAKEOFF_LAG = {
    "hip": 0.0, "back": 0.3, "chest": 0.5, "chest_rot": 0.6,
    "neck": [1.0, 1.4, 1.8], "head": 2.2, "look": 2.6,
    "tail": [1.0, 2.0, 3.0, 4.0],
    "feet": 0.0,
}
TAKEOFF_WING_LAG = {"lift": 0.0, "sweep": 0.0, "twist": -0.5, "elbow": 0.6, "wrist": 1.4, "back": 1.2, "fan": 0.8}
TAKEOFF_WING_R_LAG = 0.3


def _scaled(lag, w):
    if isinstance(lag, dict):
        return {k: _scaled(v, w) for k, v in lag.items()}
    if isinstance(lag, list):
        return [_scaled(v, w) for v in lag]
    return lag * w


def _takeoff_wing(f, fade, side):
    """The wing's angles along the climb, opened out of the fold over the first frames."""
    hover_lag = HOVER_WING_R_LAG if side == "R" else 0.0
    end = [_between(HOVER_WING, HOVER_TIMES, u - hover_lag, HOVER_WING_LAG)
           for u in (TAKEOFF_HOVER_FROM, TAKEOFF_HOVER_FROM + 1.0 / 40.0)]
    keys = [TAKEOFF_WING[0]] + TAKEOFF_WING + end
    u = f - (TAKEOFF_WING_R_LAG * fade if side == "R" else 0.0)
    spread = open_wing(**_between(keys, _TAKEOFF_CURVE_FRAMES, u, _scaled(TAKEOFF_WING_LAG, fade), _once))
    x = max(0.0, min(1.0, u / 7.0))
    k = x * x * (3.0 - 2.0 * x)
    return spread if k >= 1.0 else wing_unfold(STANCE["wing"], spread, k)


def takeoff_at(t):
    f = t * _TAKEOFF_LENGTH
    if f >= _TAKEOFF_HOVER_AT:
        return dict(hover_at(TAKEOFF_HOVER_FROM + (f - _TAKEOFF_HOVER_AT) / 40.0), lift=takeoff_lift(f))
    # The lags close up before the hover takes over, or the join would step.
    fade = min(1.0, (_TAKEOFF_HOVER_AT - f) / 6.0)
    out = {}
    for name, lag in TAKEOFF_LAG.items():
        keys = [key[name] for key in _TAKEOFF_CURVE_KEYS]
        out[name] = _between(keys, _TAKEOFF_CURVE_FRAMES, f, _scaled(lag, fade), _once)
    if f <= _TAKEOFF_RELEASE:
        # Planted: the armature rises under the game's lift, so the foot sinks in it.
        for foot in _HIND_FEET:
            x, y, z = STANCE["feet"][foot]["at"]
            out["feet"][foot]["at"] = (x, y, z - takeoff_lift(f))
    out["wing_L"] = _takeoff_wing(f, fade, "L")
    out["wing_R"] = _takeoff_wing(f, fade, "R")
    out["lift"] = takeoff_lift(f)
    return out


# Rendered with the game's climb added, so the feet read against the ground.
LIFTED = {"takeoff_blocked", "takeoff"}

# Landing. The game has already set the unit on the ground when this starts
# (unit_movement.gd emits touched_down at the end of the descent), and the hover
# holds the body up on the bones, so the clip carries it the last stretch down.
LAND_WING = [
    {"lift": 20, "sweep": 28, "twist": -30, "elbow": 8, "wrist": 12, "back": 0, "fan": 1.0},
    {"lift": 48, "sweep": 8, "twist": -18, "elbow": 6, "wrist": -22, "back": 10, "fan": 0.85},
    {"lift": 58, "sweep": -14, "twist": -12, "elbow": 8, "wrist": -42, "back": 24, "fan": 0.6},
]

# Reared up with the wings thrown forward and cupped, hind legs swung under and
# reaching for the ground, tail hanging as a counterweight.
LAND_BRAKE = {
    "hip": (0.0, 0.215, 0.47),
    "back": [(0.0, 0.07, 0.575)],
    "chest": (0.0, -0.055, 0.67),
    "chest_rot": (-42, 0, 0),
    "neck": [(0.0, -0.135, 0.79), (0.0, -0.155, 0.86), (0.0, -0.20, 0.92)],
    "head": (0.0, -0.235, 0.945),
    "look": (0.0, -1.0, -0.35),
    "feet": {
        "Hand_L": {"at": (0.09, -0.19, 0.50), "rot": (50, 6, 0)},
        "Hand_R": {"at": (-0.09, -0.175, 0.515), "rot": (45, -5, 0)},
        "back_food_L": {"at": (0.10, 0.20, 0.20), "rot": (20, 5, 0)},
        "back_food_R": {"at": (-0.10, 0.17, 0.225), "rot": (15, -5, 0)},
    },
    "tail": [(0.015, 0.38, 0.35), (0.05, 0.62, 0.17), (0.12, 0.92, 0.05), (0.24, 1.20, 0.03)],
    "wing": open_wing(**LAND_WING[0]),
}

# Hind feet down and taking the weight, forelegs still reaching.
LAND_TOUCH = {
    "hip": (0.0, 0.225, 0.335),
    "back": [(0.0, 0.075, 0.42)],
    "chest": (0.0, -0.07, 0.49),
    "chest_rot": (-22, 0, 0),
    "neck": [(0.0, -0.175, 0.60), (0.0, -0.225, 0.655), (0.0, -0.275, 0.695)],
    "head": (0.0, -0.31, 0.715),
    "look": (0.0, -1.0, -0.25),
    "feet": {
        "Hand_L": {"at": (0.095, -0.215, 0.27), "rot": (35, 6, 0)},
        "Hand_R": {"at": (-0.095, -0.165, 0.295), "rot": (30, -5, 0)},
        "back_food_L": STANCE["feet"]["back_food_L"],
        "back_food_R": STANCE["feet"]["back_food_R"],
    },
    "tail": [(0.015, 0.40, 0.25), (0.05, 0.67, 0.10), (0.14, 0.97, 0.03), (0.30, 1.22, 0.03)],
    "wing": open_wing(**LAND_WING[1]),
}

# All four down and sunk over them, wings up and starting to close.
LAND_SINK = dict(TAKEOFF_CROUCH, wing=wing_unfold(STANCE["wing"], open_wing(**LAND_WING[2]), 0.6))

LAND_KEYS = [hover_at(0.0), LAND_BRAKE, LAND_TOUCH, LAND_SINK, STANCE]


def land_blocked_at(t):
    return LAND_KEYS[min(int(t * len(LAND_KEYS) + 1e-6), len(LAND_KEYS) - 1)]


_LAND_LENGTH = 30
LAND_FRAMES = [0, 6, 11, 17, _LAND_LENGTH]
_LAND_OPEN = [1.0, 1.0, 1.0, 0.6, 0.0]  # how open the wing is at each key


def _land_wing(f, fade, side):
    """The wing's angles through the landing, folding away once the feet are down."""
    hover_lag = HOVER_WING_R_LAG if side == "R" else 0.0
    keys = [_between(HOVER_WING, HOVER_TIMES, -hover_lag, HOVER_WING_LAG)] + LAND_WING + [LAND_WING[2]]
    u = f - (TAKEOFF_WING_R_LAG * fade if side == "R" else 0.0)
    spread = open_wing(**_between(keys, LAND_FRAMES, u, _scaled(TAKEOFF_WING_LAG, fade), _once))
    k = _once(_LAND_OPEN, LAND_FRAMES, u)
    return spread if k >= 1.0 else wing_unfold(STANCE["wing"], spread, k)


def land_at(t):
    f = t * _LAND_LENGTH
    # The lags close up at the end, so the clip finishes exactly on the stance.
    fade = min(1.0, (_LAND_LENGTH - f) / 6.0)
    out = {}
    for name, lag in TAKEOFF_LAG.items():
        keys = [key[name] for key in LAND_KEYS]
        out[name] = _between(keys, LAND_FRAMES, f, _scaled(lag, fade), _once)
    out["wing_L"] = _land_wing(f, fade, "L")
    out["wing_R"] = _land_wing(f, fade, "R")
    return out


# length in seconds; `at` takes 0..1 of the loop and returns a pose.
CLIPS = {
    "idle": {"length": 8.0, "at": idle_at},
    "hover": {"length": 40.0 / 24.0, "at": hover_at},
    "cruise": {"length": 40.0 / 24.0, "at": cruise_at},
    "idle_blocked": {"length": 2.0 / 24.0, "at": lambda t: INHALE if t >= 0.5 else STANCE},
    "cruise_blocked": {"length": 4.0 / 24.0, "at": lambda t: CRUISE_KEYS[min(int(t * 4.0 + 1e-6), 3)]},
    "hover_blocked": {"length": 4.0 / 24.0, "at": lambda t: HOVER_KEYS[min(int(t * 4.0 + 1e-6), 3)]},
    "takeoff_blocked": {"length": 6.0 / 24.0, "at": takeoff_blocked_at},
    "takeoff": {"length": _TAKEOFF_LENGTH / 24.0, "at": takeoff_at},
    "land_blocked": {"length": 5.0 / 24.0, "at": land_blocked_at},
    "land": {"length": _LAND_LENGTH / 24.0, "at": land_at},
}
