# Curves, foot placement and the neutral stance every unarmed clip starts and
# ends on. No Blender imports beyond mathutils, so it can be read on its own.

import copy
import math
from mathutils import Matrix, Vector

FPS = 24


def _rot(pitch, roll, yaw):
    return (Matrix.Rotation(math.radians(yaw), 3, "Z") @ Matrix.Rotation(math.radians(roll), 3, "Y")
            @ Matrix.Rotation(math.radians(pitch), 3, "X"))


def merge(base, patch):
    """A deep copy of base with patch laid over it, dict by dict."""
    out = copy.deepcopy(base)
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


BALL_TO_ANKLE = Vector((0.0, 0.149, 0.089))
ANKLE_FLAT_Z = 0.104


def plant(x, y, heel=0.0, yaw=0.0, z=0.0, roll=0.0):
    """A foot with its ball at (x, y, z above the floor). heel lifts the heel
    around the ball in degrees, the toes staying flat on the ground."""
    turn = _rot(heel, roll, yaw)
    at = Vector((x, y, z + 0.015)) + turn @ BALL_TO_ANKLE
    return {"at": tuple(at), "rot": (heel, roll, yaw), "toe": heel}


def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3.0 - 2.0 * x)


def smoother(x):
    x = max(0.0, min(1.0, x))
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0)


def _hermite(a, b, m0, m1, h, u):
    return ((2 * u ** 3 - 3 * u ** 2 + 1) * a + (u ** 3 - 2 * u ** 2 + u) * h * m0
            + (3 * u ** 2 - 2 * u ** 3) * b + (u ** 3 - u ** 2) * h * m1)


def once(values, times, t):
    """Monotone through its keys, holding the first and last. A plateau or a
    reversal gets a zero tangent: right for a blow landing, wrong for a slow
    whole-body move, which reads as stop-start. Use spline there."""
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
    return _hermite(values[i], values[i + 1], tangent(i), tangent(i + 1), h, (t - times[i]) / h)


def spline(values, times, t):
    """Catmull-Rom on uneven times: keeps moving through its keys, may
    overshoot a little. For slow transitions and anything that must not stall."""
    if t <= times[0]:
        return values[0]
    if t >= times[-1]:
        return values[-1]
    i = 0
    while times[i + 1] <= t:
        i += 1

    def tangent(a):
        if a <= 0 or a >= len(values) - 1:
            return 0.0
        return (values[a + 1] - values[a - 1]) / (times[a + 1] - times[a - 1])

    h = times[i + 1] - times[i]
    return _hermite(values[i], values[i + 1], tangent(i), tangent(i + 1), h, (t - times[i]) / h)


def cycle(values, times, t):
    """Catmull-Rom round a loop. times in [0, 1), t wraps."""
    n = len(values)
    t = t % 1.0
    i = n - 1
    for k in range(n):
        if times[k] <= t:
            i = k
    i1 = (i + 1) % n
    i0 = (i - 1) % n
    i2 = (i + 2) % n

    def gap(a, b):
        return (times[b] - times[a]) % 1.0 or 1.0

    h = gap(i, i1)
    u = ((t - times[i]) % 1.0) / h
    a, b = values[i], values[i1]
    m0 = (b - values[i0]) / (gap(i0, i) + h)
    m1 = (values[i2] - a) / (h + gap(i1, i2))
    return _hermite(a, b, m0, m1, h, u)


def between(keys, times, t, lag=None, curve=once):
    """The pose swung through at t. keys is a list of matching pose trees
    (same dict keys in every one). lag is a tree like them, or one number, or
    None: how many of the same units as t that part arrives late.
    Non-numbers come from the first key."""
    first = keys[0]
    if isinstance(first, dict):
        return {k: between([p[k] for p in keys], times, t, lag.get(k) if isinstance(lag, dict) else lag, curve) for k in first}
    if isinstance(first, tuple):
        lag = lag if isinstance(lag, (int, float)) else 0.0
        return tuple(curve([p[i] for p in keys], times, t - lag) for i in range(len(first)))
    if isinstance(first, (int, float)) and not isinstance(first, bool):
        lag = lag if isinstance(lag, (int, float)) else 0.0
        return curve(keys, times, t - lag)
    return first


def track(keys, f):
    """One channel with its own timing, so each part of the body can arrive
    when it should. keys: (frame, value), or (frame, value, "stop") to come to
    rest there. value is a number or a tuple. Everywhere else it keeps moving
    through its keys, and the shorter neighbouring gap sets the speed."""
    if f <= keys[0][0]:
        return keys[0][1]
    if f >= keys[-1][0]:
        return keys[-1][1]
    i = 0
    while keys[i + 1][0] <= f:
        i += 1
    single = not isinstance(keys[0][1], tuple)
    value = (lambda k: (k[1],)) if single else (lambda k: k[1])

    def tangent(a, c):
        if a <= 0 or a >= len(keys) - 1 or len(keys[a]) > 2:
            return 0.0
        h0, h1 = keys[a][0] - keys[a - 1][0], keys[a + 1][0] - keys[a][0]
        s0 = (value(keys[a])[c] - value(keys[a - 1])[c]) / h0
        s1 = (value(keys[a + 1])[c] - value(keys[a])[c]) / h1
        return (h1 * s0 + h0 * s1) / (h0 + h1)

    h = keys[i + 1][0] - keys[i][0]
    u = (f - keys[i][0]) / h
    out = tuple(_hermite(value(keys[i])[c], value(keys[i + 1])[c], tangent(i, c), tangent(i + 1, c), h, u)
                for c in range(len(value(keys[0]))))
    return out[0] if single else out


def turned(forward, side, yaw):
    """(pitch, roll, yaw) for a body turned by yaw that leans in the world:
    forward toward -Y, side toward +X, in degrees. A lean named this way stays
    a lean toward the target however far the body has turned."""
    a = math.radians(yaw)
    local_x = math.cos(a) * side - math.sin(a) * forward
    local_y = -math.sin(a) * side - math.cos(a) * forward
    return (-local_y, local_x, yaw)


# In frames. The hips drive; the chest answers; the head comes last. Hands are
# left at 0: the blow is what arrives on the beat. To drag a hand behind the
# shoulder on the way in, give the clip its own lag.
BODY_LAG = {"hip": 0.0, "hip_rot": 0.0, "chest_rot": 1.2, "look": 2.0, "head_rot": 2.0, "head_up": 2.0}


def action(keys, frames, lag=None, curve=once, **extra):
    """A one-shot from full poses at frames (24 per second). Starts and ends
    wherever the first and last keys are."""
    lag = BODY_LAG if lag is None else lag
    count = frames[-1]

    def at(t):
        return between(keys, frames, t * count, lag, curve)

    clip = {"length": count / FPS, "at": at}
    clip.update(extra)
    return clip


def loop(keys, times, seconds, lag=None, **extra):
    """A cycle from full poses at times in [0, 1). lag in fractions of the loop."""
    def at(t):
        return between(keys, times, t, lag, cycle)

    clip = {"length": seconds, "at": at, "loop": True}
    clip.update(extra)
    return clip


# Weight a little on the left, the left foot a touch ahead, knees soft, hips
# tipped, the chest over them and the arms hanging from the shoulders with
# some air under them. +X is the character's left.
STANCE = {
    "hip": (0.012, 0.035, 0.897),
    "hip_rot": (5.0, -1.5, -2.0),
    "chest_rot": (3.0, 1.0, 1.5),
    "look": (0.0, -1.0, -0.03),
    "feet": {"l": plant(0.118, -0.165, yaw=9.0), "r": plant(-0.128, -0.085, yaw=-13.0)},
    "hands": {
        "l": {"at": (0.25, 0.02, 0.905), "space": "chest", "pole": (0.25, 0.8, -1.0), "curl": 0.32, "thumb": 0.25},
        "r": {"at": (-0.255, 0.035, 0.91), "space": "chest", "pole": (-0.25, 0.8, -1.0), "curl": 0.36, "thumb": 0.25},
    },
}
