# The dragon's key poses, as body_rig.py reads them.

import math

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

POSES = {
    "stance": STANCE,
    "inhale": INHALE,
    "weight": WEIGHT,
    "glance": GLANCE,
    "wing_settle": WING_SETTLE,
}


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


# length in seconds; `at` takes 0..1 of the loop and returns a pose.
CLIPS = {
    "idle": {"length": 8.0, "at": idle_at},
    "idle_blocked": {"length": 2.0 / 24.0, "at": lambda t: INHALE if t >= 0.5 else STANCE},
}
