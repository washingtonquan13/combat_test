# The dragon's key poses, as body_rig.py reads them.

import math

from mathutils import Quaternion, Vector

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
         "cruise_top", "cruise_drive", "cruise_bottom", "cruise_recover", "cruise_blocked", "cruise"}


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


def _between(keys, times, t, lag):
    """The keys swung through at t, with lag shaped like them: one number or a matching tree."""
    first = keys[0]
    if isinstance(first, dict):
        return {k: _between([p[k] for p in keys], times, t, lag[k] if isinstance(lag, dict) else lag) for k in first}
    if isinstance(first, list):
        lags = lag if isinstance(lag, list) else [lag] * len(first)
        return [_between([p[i] for p in keys], times, t, lags[i]) for i in range(len(first))]
    if isinstance(first, tuple):
        return tuple(_cycle([p[i] for p in keys], times, t - lag) for i in range(len(first)))
    return _cycle(keys, times, t - lag)


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


# length in seconds; `at` takes 0..1 of the loop and returns a pose.
CLIPS = {
    "idle": {"length": 8.0, "at": idle_at},
    "hover": {"length": 40.0 / 24.0, "at": hover_at},
    "cruise": {"length": 40.0 / 24.0, "at": cruise_at},
    "idle_blocked": {"length": 2.0 / 24.0, "at": lambda t: INHALE if t >= 0.5 else STANCE},
    "cruise_blocked": {"length": 4.0 / 24.0, "at": lambda t: CRUISE_KEYS[min(int(t * 4.0 + 1e-6), 3)]},
    "hover_blocked": {"length": 4.0 / 24.0, "at": lambda t: HOVER_KEYS[min(int(t * 4.0 + 1e-6), 3)]},
}
