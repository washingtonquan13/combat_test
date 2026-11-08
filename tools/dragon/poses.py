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
    "head": (0.03, -0.38, 0.442),
    "look": (0.24, -1.0, -0.10),
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

POSES = {"stance": STANCE, "inhale": INHALE}


def _mix(a, b, w):
    if isinstance(a, dict):
        return {k: _mix(a[k], b[k], w) for k in a}
    if isinstance(a, (list, tuple)):
        return type(a)(_mix(x, y, w) for x, y in zip(a, b))
    return a + (b - a) * w


def _breath(t):
    """0 at rest, 1 at the top: a shorter draw in, a longer let go."""
    t %= 1.0
    k = t / 0.42 if t < 0.42 else (1.0 - t) / 0.58
    return 0.5 - 0.5 * math.cos(math.pi * k)


# The ribcage leads and the ends of the body arrive late.
IDLE_LAG = {"hip": 0.02, "wing": 0.06, "neck": 0.05, "head": 0.08, "look": 0.13, "tail": 0.16}


def idle_at(t):
    return {k: _mix(STANCE[k], INHALE[k], _breath(t - IDLE_LAG.get(k, 0.0))) for k in STANCE}


# length in seconds; `at` takes 0..1 of the loop and returns a pose.
CLIPS = {
    "idle": {"length": 4.0, "at": idle_at},
    "idle_blocked": {"length": 2.0 / 24.0, "at": lambda t: INHALE if t >= 0.5 else STANCE},
}
