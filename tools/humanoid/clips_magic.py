# Spellcasting and breath. The caster is doing work: every key is a body
# bracing or straining against something real, and the hands shape that force.

import math

import motion as m

TAU = 2.0 * math.pi

# m.STANCE's hands, said in world space with stated directions, so a clip can
# run point + palm from its first frame and still start exactly on the stance.
_REST_R = {"at": (-0.25732, 0.00483, 0.8919), "point": (-0.08493, -0.2578, -0.96246),
           "palm": (0.97413, 0.18154, -0.13458), "pole": (-0.28885, 0.84397, -0.95225),
           "curl": 0.36, "thumb": 0.25, "spread": 0.0, "clav": (0.0, 0.0)}
_REST_L = {"at": (0.24772, 0.00333, 0.87731), "point": (0.05666, -0.2426, -0.96847),
           "palm": (-0.98598, 0.13889, -0.09247), "pole": (0.2109, 0.85705, -0.96098),
           "curl": 0.32, "thumb": 0.25, "spread": 0.0, "clav": (0.0, 0.0)}

REST = dict(m.STANCE, hands={"l": _REST_L, "r": _REST_R})

FOOT_L = m.STANCE["feet"]["l"]
FOOT_R = m.STANCE["feet"]["r"]


def _scaled(lag, fade):
    if isinstance(lag, dict):
        return {k: _scaled(v, fade) for k, v in lag.items()}
    return lag * fade


def act(keys, frames, curve=m.spline, lag=None, **extra):
    """m.action with the lag fading over the last frames, so the last key is
    really reached, and with feet on the monotone curve so they never dip."""
    lag = m.BODY_LAG if lag is None else lag
    count = frames[-1]
    feet = [k["feet"] for k in keys]

    def at(t):
        f = t * count
        pose = m.between(keys, frames, f, _scaled(lag, min(1.0, max(0.0, (count - f) / 4.0))), curve)
        pose["feet"] = m.between(feet, frames, f, None, m.once)
        return pose

    clip = {"length": count / m.FPS, "at": at}
    clip.update(extra)
    return clip


def wave(t, n, phase=0.0):
    """Periodic over the loop and exactly 0 at t = 0, so a loop's first frame is its key."""
    return math.sin(TAU * (n * t + phase)) - math.sin(TAU * phase)


def plus(v, d):
    return tuple(a + b for a, b in zip(v, d))


def nudge(pose, **parts):
    """Adds offsets to a pose in place. hip/hip_rot/chest_rot/look, and
    r/l: {field: offset} for hands (numbers or tuples)."""
    for part in ("hip", "hip_rot", "chest_rot", "look"):
        if part in parts:
            pose[part] = plus(pose[part], parts[part])
    for side in "rl":
        for field, d in parts.get(side, {}).items():
            cur = pose["hands"][side][field]
            pose["hands"][side][field] = plus(cur, d) if isinstance(cur, tuple) else cur + d
    return pose


# ---- Simple: a ball of force, held and thrown ------------------------------

# Rear foot set back, bearing down over the thing: the lower hand carries it,
# the upper hand presses on it, and the back is rounded around it.
BRACE_R = m.plant(-0.165, 0.03, yaw=-20.0)
SIMPLE = m.merge(REST, {
    "hip": (0.0, 0.05, 0.862),
    "hip_rot": (9.0, 0.0, -10.0),
    "chest_rot": (15.0, -1.0, -3.0),
    "look": (0.02, -1.0, -0.2),
    "feet": {"r": BRACE_R},
    "hands": {
        "r": {"at": (-0.12, -0.3, 1.07), "point": (0.48, -0.85, 0.12), "palm": (0.15, 0.1, 0.98),
              "pole": (-0.6, 0.6, -0.65), "curl": 0.42, "thumb": 0.32, "spread": 12.0},
        "l": {"at": (0.1, -0.34, 1.28), "point": (-0.72, -0.66, -0.1), "palm": (-0.1, 0.05, -0.99),
              "pole": (0.9, 0.3, -0.2), "curl": 0.42, "thumb": 0.32, "spread": 12.0},
    },
})

SIMPLE_ENTER = [
    REST,
    m.merge(REST, {  # dips, arms swing out low, palms turning up to scoop
        "hip": (0.005, 0.045, 0.872), "hip_rot": (9.0, -1.0, -5.0), "chest_rot": (13.0, 0.0, -1.0),
        "look": (0.0, -1.0, -0.3),
        "feet": {"r": m.plant(-0.135, -0.07, heel=22.0, yaw=-15.0)},
        "hands": {
            "r": {"at": (-0.31, -0.14, 0.93), "point": (0.2, -0.92, -0.3), "palm": (0.75, -0.2, 0.6),
                  "curl": 0.25, "thumb": 0.15, "spread": 16.0, "pole": (-0.55, 0.7, -0.75)},
            "l": {"at": (0.3, -0.14, 0.96), "point": (-0.2, -0.92, -0.3), "palm": (-0.9, -0.1, 0.4),
                  "curl": 0.25, "thumb": 0.15, "spread": 16.0, "pole": (0.55, 0.7, -0.75)},
        },
    }),
    m.merge(REST, {  # hauling it up: chest lifts, rear foot travelling back
        "hip": (0.0, 0.055, 0.88), "hip_rot": (6.0, 0.0, -8.0), "chest_rot": (4.0, -1.0, -4.0),
        "look": (0.0, -1.0, -0.2),
        "feet": {"r": m.plant(-0.152, -0.02, heel=18.0, yaw=-18.0, z=0.022)},
        "hands": {
            "r": {"at": (-0.19, -0.33, 1.09), "point": (0.4, -0.9, 0.1), "palm": (0.2, 0.0, 0.98),
                  "curl": 0.32, "thumb": 0.25, "spread": 16.0, "pole": (-0.6, 0.6, -0.65)},
            "l": {"at": (0.19, -0.32, 1.17), "point": (-0.4, -0.9, 0.1), "palm": (-0.9, 0.35, 0.2),
                  "curl": 0.32, "thumb": 0.25, "spread": 16.0, "pole": (0.65, 0.55, -0.6)},
        },
    }),
    m.merge(SIMPLE, {  # top of the lift: the upper hand rolls over the top of it
        "hip": (0.0, 0.05, 0.876), "hip_rot": (7.0, 0.0, -10.0), "chest_rot": (8.0, -1.0, -3.0),
        "look": (0.02, -1.0, -0.14),
        "feet": {"r": m.plant(-0.165, 0.03, heel=7.0, yaw=-20.0)},
        "hands": {
            "r": {"at": (-0.13, -0.31, 1.13), "spread": 16.0},
            "l": {"at": (0.11, -0.35, 1.35), "palm": (-0.45, 0.1, -0.88), "spread": 16.0},
        },
    }),
    SIMPLE,  # the weight of it lands in the hands
]

SIMPLE_EXIT = [
    SIMPLE,
    m.merge(SIMPLE, {  # lets it go: hands part and open, a breath out, chest lifting off it
        "hip": (0.0, 0.05, 0.873), "hip_rot": (8.0, 0.0, -9.0), "chest_rot": (8.0, 0.0, -2.0),
        "look": (0.0, -1.0, -0.1),
        "feet": {"r": m.plant(-0.16, 0.02, heel=18.0, yaw=-19.0)},
        "hands": {
            "r": {"at": (-0.2, -0.27, 1.0), "palm": (0.5, 0.0, 0.87), "curl": 0.15, "thumb": 0.1, "spread": 18.0},
            "l": {"at": (0.2, -0.29, 1.18), "palm": (-0.55, -0.1, -0.83), "curl": 0.15, "thumb": 0.1, "spread": 18.0},
        },
    }),
    m.merge(REST, {  # arms falling, rear foot coming home
        "hip": (0.005, 0.042, 0.888), "hip_rot": (6.0, -1.0, -5.0), "chest_rot": (4.0, 0.5, 0.0),
        "look": (0.0, -1.0, -0.06),
        "feet": {"r": m.plant(-0.142, -0.04, heel=14.0, yaw=-16.0, z=0.016)},
        "hands": {
            "r": {"at": (-0.26, -0.1, 0.93), "point": (0.1, -0.5, -0.85), "palm": (0.9, 0.2, 0.1), "curl": 0.25, "spread": 6.0},
            "l": {"at": (0.26, -0.1, 0.96), "point": (-0.25, -0.55, -0.8), "palm": (-0.9, 0.1, -0.4), "curl": 0.25, "spread": 6.0},
        },
    }),
    REST,
]

SIMPLE_SHOOT = [
    SIMPLE,
    m.merge(SIMPLE, {  # the hips start to turn away, right hand rolling up the side of the ball
        "hip": (-0.007, 0.07, 0.857), "hip_rot": (8.0, -1.5, -20.0), "chest_rot": (10.0, -3.0, -24.0),
        "look": (0.05, -1.0, -0.12),
        "hands": {
            "r": {"at": (-0.42, -0.14, 1.36), "point": (0.35, -0.75, 0.55), "palm": (0.9, 0.2, 0.3),
                  "pole": (-0.8, 0.4, -0.45), "curl": 0.46, "thumb": 0.36, "spread": 13.0},
            "l": {"at": (0.17, -0.37, 1.28), "point": (-0.45, -0.85, 0.05), "palm": (-0.4, 0.05, -0.9),
                  "pole": (0.7, 0.3, -0.55), "curl": 0.3, "thumb": 0.28, "spread": 10.0},
        },
    }),
    m.merge(SIMPLE, {  # coiled: hips and ribs wrung to the right, the ball hauled back by the ear
        "hip": (-0.015, 0.085, 0.852), "hip_rot": (6.0, -3.0, -30.0), "chest_rot": (4.0, -5.0, -46.0),
        "look": (0.08, -1.0, -0.06),
        "hands": {
            "r": {"at": (-0.43, 0.22, 1.62), "point": (0.3, -0.35, 0.88), "palm": (0.49, -0.63, -0.41),
                  "pole": (-0.95, 0.05, -0.25), "curl": 0.5, "thumb": 0.4, "spread": 14.0},
            "l": {"at": (0.2, -0.38, 1.27), "point": (-0.2, -0.95, 0.15), "palm": (-0.7, 0.05, -0.7),
                  "pole": (0.5, 0.3, -0.8), "curl": 0.15, "thumb": 0.25, "spread": 8.0},
        },
    }),
    m.merge(SIMPLE, {  # release: hips through, shoulder behind the arm, hand burst open, left yanked back
        "hip": (0.035, -0.09, 0.842), "hip_rot": (14.0, 2.0, 18.0), "chest_rot": (24.0, 3.0, 36.0),
        "look": (0.04, -1.0, -0.1),
        "feet": {"r": m.plant(-0.165, 0.03, heel=34.0, yaw=-18.0)},
        "hands": {
            "r": {"at": (-0.07, -0.65, 1.33), "point": (0.1, -0.97, 0.14), "palm": (0.2, -0.15, -0.97),
                  "pole": (-0.4, 0.1, -0.9), "curl": 0.04, "thumb": 0.05, "spread": 22.0},
            "l": {"at": (0.3, -0.22, 1.15), "point": (-0.3, -0.9, -0.3), "palm": (-0.9, 0.3, 0.0),
                  "pole": (0.4, 0.9, -0.1), "curl": 0.7, "thumb": 0.6, "spread": 0.0},
        },
    }),
    m.merge(SIMPLE, {  # carried past: chest still going, the arm dropping across
        "hip": (0.04, -0.1, 0.836), "hip_rot": (16.0, 3.0, 26.0), "chest_rot": (27.0, 4.0, 46.0),
        "look": (0.05, -1.0, -0.14),
        "feet": {"r": m.plant(-0.165, 0.03, heel=40.0, yaw=-16.0)},
        "hands": {
            "r": {"at": (0.05, -0.72, 1.12), "point": (0.3, -0.9, -0.1), "palm": (0.3, -0.2, -0.93),
                  "pole": (-0.3, 0.1, -0.95), "curl": 0.15, "thumb": 0.12, "spread": 14.0},
            "l": {"at": (0.33, -0.18, 1.12), "point": (-0.3, -0.9, -0.35), "palm": (-0.9, 0.3, 0.05),
                  "pole": (0.4, 0.9, -0.1), "curl": 0.6, "thumb": 0.5, "spread": 0.0},
        },
    }),
    m.merge(REST, {  # rear foot comes through to catch it, the arm spent and falling
        "hip": (0.025, -0.02, 0.862), "hip_rot": (11.0, 0.0, 9.0), "chest_rot": (13.0, 2.0, 16.0),
        "look": (0.03, -1.0, -0.08),
        "feet": {"r": m.plant(-0.14, -0.05, heel=16.0, yaw=-14.0, z=0.016)},
        "hands": {
            "r": {"at": (-0.17, -0.42, 0.98), "point": (0.15, -0.75, -0.65), "palm": (0.8, 0.3, -0.15),
                  "pole": (-0.5, 0.5, -0.8), "curl": 0.3, "thumb": 0.2, "spread": 6.0},
            "l": {"at": (0.3, 0.0, 0.95), "curl": 0.42, "thumb": 0.3},
        },
    }),
    REST,
]


def simple_idle_at(t):
    """One slow breath; the hands work the ball a little; the fingers never settle."""
    breath = wave(t, 1)
    sway = wave(t, 1, 0.3)
    orbit = wave(t, 2, 0.15)
    pose = m.merge(SIMPLE, {})
    nudge(pose,
          hip=(0.006 * sway, 0.003 * wave(t, 2, 0.4), 0.004 * breath),
          hip_rot=(0.5 * wave(t, 2), -0.7 * sway, 0.8 * wave(t, 1, 0.1)),
          chest_rot=(-1.4 * breath, 0.5 * sway, -1.0 * wave(t, 1, 0.22)),
          look=(0.012 * wave(t, 2, 0.6), 0.0, 0.012 * breath),
          r={"at": (0.007 * orbit, 0.005 * wave(t, 2, 0.4), 0.007 * breath + 0.002 * wave(t, 7, 0.1)),
             "curl": 0.05 * wave(t, 5, 0.1) + 0.03 * wave(t, 8, 0.7),
             "spread": 3.0 * wave(t, 6, 0.3) + 2.0 * wave(t, 9, 0.5),
             "thumb": 0.05 * wave(t, 4, 0.2)},
          l={"at": (-0.007 * orbit, -0.005 * wave(t, 2, 0.4), 0.006 * breath - 0.002 * wave(t, 7, 0.45)),
             "curl": 0.05 * wave(t, 6, 0.55) + 0.03 * wave(t, 9, 0.2),
             "spread": 3.0 * wave(t, 5, 0.8) + 2.0 * wave(t, 8, 0.1),
             "thumb": 0.05 * wave(t, 3, 0.7)})
    pose["hands"]["r"]["clav"] = (0.0, 1.5 * breath)
    pose["hands"]["l"]["clav"] = (0.0, 1.5 * breath)
    return pose


# ---- Charged: the hand drawn back with a fire in it ------------------------

# Javelin held back: rear leg loaded, hips and ribs turned away from the target,
# right hand cocked by the shoulder with the fire in its claw, left arm a sight.
LOAD_R = m.plant(-0.175, 0.07, yaw=-32.0)
HOLD = m.merge(REST, {
    "hip": (-0.055, 0.115, 0.852),
    "hip_rot": (2.0, -4.0, -27.0),
    "chest_rot": (-6.0, -7.0, -41.0),
    "look": (0.04, -1.0, -0.04),
    "feet": {"l": m.plant(0.118, -0.165, yaw=9.0, heel=5.0), "r": LOAD_R},
    "hands": {
        "r": {"at": (-0.38, 0.25, 1.53), "point": (0.19, -0.44, 0.87), "palm": (0.1, -0.87, -0.45),
              "pole": (-0.9, 0.4, -0.35), "curl": 0.46, "thumb": 0.42, "spread": 16.0},
        "l": {"at": (0.15, -0.5, 1.36), "point": (-0.1, -0.98, 0.1), "palm": (-0.85, 0.1, -0.5),
              "pole": (0.4, 0.3, -0.9), "curl": 0.14, "thumb": 0.25, "spread": 6.0},
    },
})

ARM = [
    REST,
    m.merge(REST, {  # dips and reaches in low with both hands, as if lifting something from the ground
        "hip": (0.0, 0.04, 0.862), "hip_rot": (13.0, 0.0, -7.0), "chest_rot": (17.0, 0.0, -2.0),
        "look": (0.0, -1.0, -0.36),
        "feet": {"r": m.plant(-0.135, -0.07, heel=20.0, yaw=-16.0)},
        "hands": {
            "r": {"at": (-0.17, -0.3, 0.95), "point": (0.35, -0.9, -0.2), "palm": (0.15, -0.2, 0.97),
                  "pole": (-0.55, 0.6, -0.75), "curl": 0.3, "thumb": 0.25, "spread": 14.0},
            "l": {"at": (0.17, -0.27, 1.04), "point": (-0.4, -0.9, -0.1), "palm": (-0.75, 0.0, -0.65),
                  "pole": (0.6, 0.6, -0.7), "curl": 0.35, "thumb": 0.25, "spread": 10.0},
        },
    }),
    m.merge(REST, {  # hauls it up the centre of the body, rear foot travelling back
        "hip": (-0.015, 0.06, 0.872), "hip_rot": (9.0, -1.0, -14.0), "chest_rot": (8.0, -2.0, -14.0),
        "look": (0.0, -1.0, -0.15),
        "feet": {"r": m.plant(-0.155, -0.01, heel=16.0, yaw=-24.0, z=0.022)},
        "hands": {
            "r": {"at": (-0.13, -0.31, 1.25), "point": (0.6, -0.62, 0.5), "palm": (0.75, 0.55, -0.2),
                  "pole": (-0.7, 0.5, -0.5), "curl": 0.42, "thumb": 0.35, "spread": 16.0},
            "l": {"at": (0.19, -0.33, 1.13), "point": (-0.3, -0.92, 0.2), "palm": (-0.5, -0.05, -0.86),
                  "pole": (0.55, 0.5, -0.65), "curl": 0.3, "thumb": 0.25, "spread": 8.0},
        },
    }),
    m.merge(HOLD, {  # passing the face: weight rolling onto the back foot, left arm going out
        "hip": (-0.035, 0.085, 0.862), "hip_rot": (5.0, -3.0, -22.0), "chest_rot": (0.0, -5.0, -30.0),
        "look": (0.02, -1.0, -0.07),
        "feet": {"l": m.plant(0.118, -0.165, yaw=9.0, heel=2.0), "r": m.plant(-0.175, 0.07, yaw=-32.0, heel=6.0)},
        "hands": {
            "r": {"at": (-0.33, -0.06, 1.52), "point": (0.5, -0.4, 0.77), "palm": (0.6, -0.75, -0.25),
                  "pole": (-0.85, 0.4, -0.4), "curl": 0.46, "thumb": 0.4},
            "l": {"at": (0.16, -0.43, 1.25), "point": (-0.2, -0.95, 0.15), "palm": (-0.8, 0.0, -0.6), "curl": 0.2},
        },
    }),
    m.merge(HOLD, {  # over-draws: leans away from it, drawn further than it can stay
        "hip": (-0.055, 0.11, 0.854), "hip_rot": (1.0, -5.0, -30.0), "chest_rot": (-8.0, -9.0, -47.0),
        "hands": {
            "r": {"at": (-0.39, 0.29, 1.55), "curl": 0.55, "thumb": 0.5, "spread": 20.0},
            "l": {"at": (0.16, -0.52, 1.39)},
        },
    }),
    HOLD,
]

DISARM = [
    HOLD,
    m.merge(HOLD, {  # lets it go: the claw bursts open, the body sags as the tension goes
        "hip": (-0.04, 0.09, 0.868), "hip_rot": (4.0, -3.0, -24.0), "chest_rot": (2.0, -5.0, -33.0),
        "look": (0.02, -1.0, -0.1),
        "hands": {
            "r": {"at": (-0.38, 0.14, 1.48), "point": (0.1, -0.3, 0.95), "palm": (0.1, -0.9, -0.35), "curl": 0.04, "thumb": 0.05, "spread": 24.0},
            "l": {"at": (0.17, -0.46, 1.27), "curl": 0.25},
        },
    }),
    m.merge(HOLD, {  # the forearm tips over forward under its own weight
        "hip": (-0.03, 0.08, 0.871), "hip_rot": (5.0, -2.5, -19.0), "chest_rot": (4.0, -3.5, -24.0),
        "look": (0.01, -1.0, -0.1),
        "hands": {
            "r": {"at": (-0.38, 0.03, 1.31), "point": (0.15, -0.85, 0.3), "palm": (0.45, 0.1, -0.88), "curl": 0.1, "thumb": 0.08, "spread": 18.0},
            "l": {"at": (0.21, -0.36, 1.16), "point": (-0.05, -0.9, -0.3), "palm": (-0.9, 0.05, -0.4), "curl": 0.28},
        },
    }),
    m.merge(REST, {  # arms falling, hips unwinding, rear foot lifting to come home
        "hip": (-0.015, 0.06, 0.875), "hip_rot": (6.0, -2.0, -12.0), "chest_rot": (7.0, -1.0, -11.0),
        "look": (0.0, -1.0, -0.1),
        "feet": {"r": m.plant(-0.16, 0.02, heel=20.0, yaw=-24.0, z=0.02)},
        "hands": {
            "r": {"at": (-0.36, -0.07, 1.08), "point": (-0.1, -0.55, -0.8), "palm": (0.85, 0.1, -0.5),
                  "pole": (-0.7, 0.6, -0.5), "curl": 0.2, "thumb": 0.15, "spread": 10.0},
            "l": {"at": (0.26, -0.2, 1.03), "point": (0.1, -0.75, -0.65), "palm": (-0.97, 0.1, -0.1), "curl": 0.3, "spread": 3.0},
        },
    }),
    REST,
]


def hold_at(t):
    """The arm can't quite keep it: fine trembling, one held breath, the fire working in the claw."""
    breath = wave(t, 1)
    sink = wave(t, 2, 0.2)
    shake_a = 0.0032 * wave(t, 11, 0.1) + 0.0024 * wave(t, 16, 0.4)
    shake_b = 0.0032 * wave(t, 13, 0.6) + 0.0024 * wave(t, 17, 0.3)
    pose = m.merge(HOLD, {})
    nudge(pose,
          hip=(-0.003 * breath, 0.004 * sink, -0.004 * sink),
          hip_rot=(0.5 * sink, 0.0, -1.0 * wave(t, 1, 0.1)),
          chest_rot=(-1.2 * breath + 0.25 * wave(t, 12, 0.2), 0.3 * wave(t, 14, 0.5), -1.4 * wave(t, 1, 0.18)),
          look=(0.006 * wave(t, 3, 0.3), 0.0, 0.01 * breath),
          r={"at": (shake_a, shake_b, 0.012 * breath + 0.5 * shake_a),
             "curl": 0.06 * wave(t, 6, 0.15) + 0.04 * wave(t, 9, 0.5),
             "spread": 3.5 * wave(t, 7, 0.35) + 2.0 * wave(t, 10, 0.75),
             "thumb": 0.06 * wave(t, 5, 0.6)},
          l={"at": (0.5 * shake_b, 0.5 * shake_a, 0.007 * breath),
             "curl": 0.02 * wave(t, 8, 0.4)})
    pose["hands"]["r"]["clav"] = (0.0, 1.5 * breath)
    pose["hands"]["l"]["clav"] = (0.0, 1.0 * breath)
    return pose


# ---- Cast: the big hurl ----------------------------------------------------

CAST = [
    REST,
    m.merge(REST, {  # both arms start up, the weight dropping back
        "hip": (-0.015, 0.05, 0.876), "hip_rot": (6.0, -2.0, -13.0), "chest_rot": (6.0, -3.0, -18.0),
        "look": (0.02, -1.0, -0.05),
        "feet": {"l": m.plant(0.118, -0.165, yaw=9.0, heel=14.0)},
        "hands": {
            "r": {"at": (-0.46, -0.08, 1.18), "point": (0.15, -0.8, -0.55), "palm": (0.85, 0.15, 0.5),
                  "pole": (-0.8, 0.6, -0.3), "curl": 0.42, "thumb": 0.35, "spread": 12.0},
            "l": {"at": (0.23, -0.3, 1.1), "point": (-0.2, -0.9, 0.2), "palm": (-0.7, 0.0, -0.7),
                  "pole": (0.5, 0.5, -0.7), "curl": 0.2, "thumb": 0.25, "spread": 6.0},
        },
    }),
    m.merge(REST, {  # the arm swings up outside the shoulder, palm rolling in, chest following it round
        "hip": (-0.035, 0.08, 0.864), "hip_rot": (4.0, -3.5, -22.0), "chest_rot": (-1.0, -6.0, -34.0),
        "look": (0.035, -1.0, -0.03),
        "feet": {"l": m.plant(0.13, -0.22, yaw=10.0, heel=12.0, z=0.03)},
        "hands": {
            "r": {"at": (-0.47, 0.1, 1.45), "point": (0.3, -0.75, 0.6), "palm": (0.75, -0.3, -0.3),
                  "pole": (-0.85, 0.45, -0.28), "curl": 0.46, "thumb": 0.4, "spread": 15.0},
            "l": {"at": (0.2, -0.4, 1.23), "point": (-0.15, -0.95, 0.15), "palm": (-0.8, 0.05, -0.6),
                  "pole": (0.45, 0.4, -0.8), "curl": 0.16, "thumb": 0.25, "spread": 6.0},
        },
    }),
    m.merge(REST, {  # top of the draw: rear leg loaded, ribs wrung away, front foot in the air
        "hip": (-0.05, 0.105, 0.855), "hip_rot": (3.0, -5.0, -30.0), "chest_rot": (-8.0, -9.0, -50.0),
        "look": (0.05, -1.0, -0.02),
        "feet": {"l": m.plant(0.14, -0.27, yaw=11.0, heel=8.0, z=0.05)},
        "hands": {
            "r": {"at": (-0.38, 0.27, 1.55), "point": (0.19, -0.44, 0.87), "palm": (0.1, -0.87, -0.45),
                  "pole": (-0.9, 0.35, -0.25), "curl": 0.5, "thumb": 0.45, "spread": 18.0},
            "l": {"at": (0.17, -0.48, 1.34), "point": (-0.1, -0.98, 0.1), "palm": (-0.85, 0.1, -0.5),
                  "pole": (0.4, 0.3, -0.9), "curl": 0.14, "thumb": 0.25, "spread": 6.0},
        },
    }),
    m.merge(REST, {  # release: foot planted, hips through, right arm whipped out, left yanked to the ribs
        "hip": (0.05, -0.16, 0.835), "hip_rot": (16.0, 3.0, 20.0), "chest_rot": (31.0, 4.0, 38.0),
        "look": (0.04, -1.0, -0.13),
        "feet": {"l": m.plant(0.17, -0.38, yaw=12.0), "r": m.plant(-0.135, -0.03, heel=34.0, yaw=-9.0)},
        "hands": {
            "r": {"at": (-0.07, -0.71, 1.3), "point": (0.1, -0.97, 0.1), "palm": (0.2, -0.1, -0.97),
                  "pole": (-0.4, 0.1, -0.9), "curl": 0.03, "thumb": 0.04, "spread": 24.0},
            "l": {"at": (0.33, -0.28, 1.1), "point": (-0.3, -0.9, -0.3), "palm": (-0.9, 0.3, 0.0),
                  "pole": (0.4, 0.9, -0.1), "curl": 0.72, "thumb": 0.62, "spread": 0.0},
        },
    }),
    m.merge(REST, {  # follow-through: folded over the front knee, the arm swept down across the body
        "hip": (0.075, -0.2, 0.82), "hip_rot": (20.0, 4.0, 30.0), "chest_rot": (42.0, 5.0, 52.0),
        "look": (0.08, -1.0, -0.3),
        "feet": {"l": m.plant(0.17, -0.38, yaw=12.0), "r": m.plant(-0.135, -0.03, heel=46.0, yaw=-5.0)},
        "hands": {
            "r": {"at": (0.12, -0.75, 1.0), "point": (0.45, -0.7, -0.55), "palm": (0.07, 0.56, -0.67),
                  "pole": (-0.35, 0.1, -0.93), "curl": 0.18, "thumb": 0.14, "spread": 12.0},
            "l": {"at": (0.42, -0.29, 1.02), "point": (-0.3, -0.9, -0.3), "palm": (-0.9, 0.3, 0.05),
                  "pole": (0.4, 0.9, -0.1), "curl": 0.55, "thumb": 0.45, "spread": 0.0},
        },
    }),
    m.merge(REST, {  # stays down a moment, breathing out, as the thing it threw goes on
        "hip": (0.068, -0.19, 0.825), "hip_rot": (18.0, 3.0, 26.0), "chest_rot": (37.0, 4.0, 45.0),
        "look": (0.06, -1.0, -0.22),
        "feet": {"l": m.plant(0.17, -0.38, yaw=12.0), "r": m.plant(-0.135, -0.03, heel=38.0, yaw=-6.0)},
        "hands": {
            "r": {"at": (0.08, -0.71, 0.98), "point": (0.4, -0.72, -0.56), "palm": (0.07, 0.56, -0.67),
                  "pole": (-0.35, 0.1, -0.93), "curl": 0.3, "thumb": 0.22, "spread": 6.0},
            "l": {"at": (0.42, -0.3, 1.0), "point": (-0.3, -0.9, -0.3), "palm": (-0.9, 0.3, 0.05),
                  "pole": (0.4, 0.9, -0.1), "curl": 0.42, "thumb": 0.35, "spread": 0.0},
        },
    }),
    m.merge(REST, {  # pushing back up off the front leg, chest unwinding, front heel rolling off
        "hip": (0.03, -0.09, 0.85), "hip_rot": (12.0, 1.0, 12.0), "chest_rot": (15.0, 2.0, 17.0),
        "look": (0.03, -1.0, -0.1),
        "feet": {"l": m.plant(0.16, -0.34, yaw=11.0, heel=14.0), "r": m.plant(-0.135, -0.03, heel=7.0, yaw=-10.0)},
        "hands": {
            "r": {"at": (-0.1, -0.4, 0.93), "point": (0.2, -0.6, -0.77), "palm": (0.8, 0.35, -0.2),
                  "pole": (-0.4, 0.4, -0.85), "curl": 0.32, "thumb": 0.25, "spread": 3.0},
            "l": {"at": (0.33, 0.03, 0.94), "curl": 0.38, "thumb": 0.28},
        },
    }),
    m.merge(REST, {  # front foot lifted, coming home
        "hip": (0.015, 0.02, 0.875), "hip_rot": (8.0, -1.0, 2.0), "chest_rot": (7.0, 1.0, 5.0),
        "look": (0.01, -1.0, -0.06),
        "feet": {"l": m.plant(0.135, -0.24, yaw=10.0, heel=10.0, z=0.022)},
        "hands": {"r": {"at": (-0.2, -0.16, 0.9), "curl": 0.34}},
    }),
    REST,
]


# ---- Breath: a body used as a bellows and then as a nozzle -----------------

BREATH_R = m.plant(-0.21, 0.09, yaw=-26.0)

BREATH_TOP = m.merge(REST, {
    # Rearing: ribs up and open, head back, elbows driven out and behind, fingers splayed.
    "hip": (-0.01, 0.12, 0.885),
    "hip_rot": (-7.0, 0.0, -3.0),
    "chest_rot": (-25.0, 0.0, 1.0),
    "look": (0.0, -0.75, 0.66),
    "feet": {"r": BREATH_R},
    "hands": {
        "r": {"at": (-0.41, 0.19, 1.06), "point": (-0.4, -0.3, -0.87), "palm": (-0.2, -0.95, 0.2),
              "pole": (-0.6, 0.6, -0.5), "curl": 0.28, "thumb": 0.12, "spread": 22.0, "clav": (-8.0, 10.0)},
        "l": {"at": (0.41, 0.19, 1.06), "point": (0.4, -0.3, -0.87), "palm": (0.2, -0.95, 0.2),
              "pole": (0.6, 0.6, -0.5), "curl": 0.28, "thumb": 0.12, "spread": 22.0, "clav": (-8.0, 10.0)},
    },
})

BREATH = [
    REST,
    m.merge(REST, {  # a short crouch to push up from, rear heel coming off
        "hip": (0.0, 0.055, 0.872), "hip_rot": (9.0, 0.0, -3.0), "chest_rot": (10.0, 0.0, 0.0),
        "look": (0.0, -1.0, -0.2),
        "feet": {"r": m.plant(-0.14, -0.06, heel=24.0, yaw=-16.0)},
        "hands": {
            "r": {"at": (-0.31, 0.02, 0.93), "point": (-0.3, -0.25, -0.92), "palm": (0.9, -0.35, -0.25), "curl": 0.25, "spread": 8.0},
            "l": {"at": (0.31, 0.02, 0.93), "point": (0.3, -0.25, -0.92), "palm": (-0.9, -0.35, -0.25), "curl": 0.25, "spread": 8.0},
        },
    }),
    m.merge(BREATH_TOP, {  # going up and back, ribs filling, rear foot landing behind
        "hip": (-0.005, 0.1, 0.885), "hip_rot": (-2.0, 0.0, -3.0), "chest_rot": (-12.0, 0.0, 1.0),
        "look": (0.0, -0.8, 0.45),
        "feet": {"r": m.plant(-0.19, 0.05, heel=14.0, yaw=-24.0, z=0.02)},
        "hands": {
            "r": {"at": (-0.39, 0.13, 1.0), "point": (-0.3, -0.35, -0.88), "palm": (0.4, -0.9, -0.2), "curl": 0.18, "spread": 18.0, "clav": (-4.0, 6.0)},
            "l": {"at": (0.39, 0.13, 1.0), "point": (0.3, -0.35, -0.88), "palm": (-0.4, -0.9, -0.2), "curl": 0.18, "spread": 18.0, "clav": (-4.0, 6.0)},
        },
    }),
    BREATH_TOP,
]

_BLAST_FEET = {"l": m.plant(0.2, -0.3, yaw=14.0), "r": m.plant(-0.21, 0.09, heel=14.0, yaw=-22.0)}
_CLAW = {"curl": 0.35, "thumb": 0.1, "spread": 22.0}
_BH_R = {"point": (-0.25, 0.75, -0.6), "palm": (0.92, 0.35, -0.1), "pole": (-0.12, 0.95, 0.25), "clav": (8.0, 3.0)}
_BH_L = {"point": (0.25, 0.75, -0.6), "palm": (-0.92, 0.35, -0.1), "pole": (0.12, 0.95, 0.25), "clav": (8.0, 3.0)}

BREATH_DRIVE = m.merge(BREATH_TOP, {
    # Thrown forward over the front leg, head leading, arms swept down and behind.
    "hip": (0.01, -0.1, 0.8),
    "hip_rot": (22.0, 0.0, -2.0),
    "chest_rot": (50.0, 0.0, 0.0),
    "look": (0.0, -0.96, -0.28),
    "feet": _BLAST_FEET,
    "hands": {"r": dict(_BH_R, at=(-0.32, 0.0, 0.98), **_CLAW), "l": dict(_BH_L, at=(0.32, 0.0, 0.98), **_CLAW)},
})

BREATH_HOLD = [
    BREATH_TOP,
    m.merge(BREATH_TOP, {  # the front foot stamps out as the body starts down
        "hip": (0.0, 0.03, 0.85), "hip_rot": (8.0, 0.0, -3.0), "chest_rot": (6.0, 0.0, 0.0),
        "look": (0.0, -0.9, 0.2),
        "feet": {"l": m.plant(0.16, -0.24, heel=12.0, yaw=11.0, z=0.03)},
        "hands": {
            "r": {"at": (-0.39, 0.15, 1.02), "point": (-0.4, 0.3, -0.85), "palm": (0.45, -0.7, -0.55), "curl": 0.27, "thumb": 0.1, "spread": 20.0},
            "l": {"at": (0.39, 0.15, 1.02), "point": (0.4, 0.3, -0.85), "palm": (-0.45, -0.7, -0.55), "curl": 0.27, "thumb": 0.1, "spread": 20.0},
        },
    }),
    BREATH_DRIVE,
    m.merge(BREATH_DRIVE, {  # the kick of it pushes him back on his heels
        "hip": (0.008, -0.07, 0.81), "hip_rot": (18.0, 0.0, -2.0), "chest_rot": (41.0, 0.0, 0.0),
        "look": (0.0, -0.98, -0.18),
        "hands": {"r": {"at": (-0.33, 0.06, 1.0)}, "l": {"at": (0.33, 0.06, 1.0)}},
    }),
    m.merge(BREATH_DRIVE, {  # leans back into it, pushing the blast out
        "hip": (0.01, -0.11, 0.798), "hip_rot": (23.0, 0.0, -2.0), "chest_rot": (50.0, 0.0, 0.0),
        "look": (0.0, -0.96, -0.3),
        "hands": {"r": {"at": (-0.33, -0.02, 0.95)}, "l": {"at": (0.33, -0.02, 0.95)}},
    }),
    m.merge(BREATH_DRIVE, {  # the last of the air, bent as far as it goes
        "hip": (0.012, -0.12, 0.79), "hip_rot": (25.0, 0.0, -2.0), "chest_rot": (55.0, 0.0, 0.0),
        "look": (0.0, -0.92, -0.38),
        "hands": {"r": {"at": (-0.32, -0.08, 0.91)}, "l": {"at": (0.32, -0.08, 0.91)}},
    }),
]
BREATH_HOLD_FRAMES = [0, 2, 5, 9, 18, 29]


_breath_hold_base = act(BREATH_HOLD, BREATH_HOLD_FRAMES)["at"]


def breath_hold_at(t):
    """The keyed drive, with the whole upper body shaking under the strain."""
    f = t * 29.0
    env = m.smooth((f - 4.0) / 5.0)
    s1 = math.sin(TAU * (f / 3.7 + 0.1))
    s2 = math.sin(TAU * (f / 2.9 + 0.4))
    s3 = math.sin(TAU * (f / 4.3 + 0.7))
    pose = _breath_hold_base(t)
    nudge(pose,
          hip=(0.0015 * env * s2, 0.002 * env * s3, 0.0015 * env * s1),
          chest_rot=(1.0 * env * s1, 0.7 * env * s2, 0.8 * env * s3),
          look=(0.012 * env * s3, 0.0, 0.012 * env * s2),
          r={"at": (0.006 * env * s2, 0.005 * env * s1, 0.007 * env * s3),
             "curl": 0.04 * env * s3},
          l={"at": (0.006 * env * s1, 0.005 * env * s3, 0.007 * env * s2),
             "curl": 0.04 * env * s1})
    return pose


_BH_END = breath_hold_at(1.0)

BREATH_OUT = [
    _BH_END,
    m.merge(_BH_END, {  # air gone: everything sags further, the fists come undone, head hanging
        "hip": (0.012, -0.1, 0.782), "hip_rot": (24.0, 0.0, -2.0), "chest_rot": (58.0, 0.0, 0.0),
        "look": (0.0, -0.72, -0.7),
        "feet": {"l": m.plant(0.19, -0.29, heel=10.0, yaw=13.0)},
        "hands": {
            "r": {"at": (-0.34, -0.2, 0.86), "point": (-0.15, 0.2, -0.97), "palm": (0.97, 0.1, -0.1), "curl": 0.4, "thumb": 0.3, "spread": 8.0, "pole": (-0.3, 0.85, -0.45), "clav": (6.0, 2.0)},
            "l": {"at": (0.34, -0.2, 0.86), "point": (0.15, 0.2, -0.97), "palm": (-0.97, 0.1, -0.1), "curl": 0.4, "thumb": 0.3, "spread": 8.0, "pole": (0.3, 0.85, -0.45), "clav": (6.0, 2.0)},
        },
    }),
    m.merge(_BH_END, {  # front foot brought back to catch the weight, starting up
        "hip": (0.012, -0.0, 0.84), "hip_rot": (16.0, 0.0, -3.0), "chest_rot": (28.0, 0.0, 0.0),
        "look": (0.0, -0.9, -0.4),
        "feet": {"l": m.plant(0.14, -0.22, heel=8.0, yaw=11.0, z=0.02), "r": m.plant(-0.2, 0.06, heel=22.0, yaw=-22.0)},
        "hands": {
            "r": {"at": (-0.3, -0.1, 0.87), "point": (-0.1, -0.2, -0.97), "palm": (0.97, 0.1, -0.15), "curl": 0.35, "thumb": 0.27, "spread": 3.0, "pole": (-0.5, 0.7, -0.7), "clav": (2.0, 0.0)},
            "l": {"at": (0.3, -0.1, 0.87), "point": (0.1, -0.2, -0.97), "palm": (-0.97, 0.1, -0.15), "curl": 0.33, "thumb": 0.27, "spread": 3.0, "pole": (0.5, 0.7, -0.7), "clav": (2.0, 0.0)},
        },
    }),
    m.merge(REST, {  # rear foot brought in; a last hitch upright
        "hip": (0.012, 0.03, 0.89), "hip_rot": (3.0, -1.0, -2.0), "chest_rot": (-1.0, 0.5, 1.0),
        "look": (0.0, -1.0, 0.0),
        "feet": {"r": m.plant(-0.14, -0.04, heel=14.0, yaw=-16.0, z=0.016)},
        "hands": {"r": {"at": (-0.27, 0.0, 0.89)}, "l": {"at": (0.26, 0.0, 0.89)}},
    }),
    REST,
]


CLIPS = {
    "Spell_Simple_Enter": act(SIMPLE_ENTER, [0, 3, 7, 10, 13]),
    "Spell_Simple_Idle": {"length": 2.1, "loop": True, "at": simple_idle_at},
    "Spell_Simple_Shoot": act(SIMPLE_SHOOT, [0, 2, 4, 6.8, 9, 12, 14], curve=m.once, moments={"release": [6.4]}),
    "Spell_Simple_Exit": act(SIMPLE_EXIT, [0, 3, 7, 10]),
    "Arm": act(ARM, [0, 4, 9, 13, 16, 19]),
    "Hold": {"length": 2.4, "loop": True, "at": hold_at},
    "Disarm": act(DISARM, [0, 3, 5, 8, 13]),
    "Cast": act(CAST, [0, 2, 4.25, 6, 9, 12, 17, 23, 27, 31], curve=m.once, moments={"release": [8.8]}),
    "Breath": act(BREATH, [0, 3, 6, 9], moments={"release": [8.64]}),
    "Breath_Hold": {"length": 29.0 / 24.0, "at": breath_hold_at},
    "Breath_Out": act(BREATH_OUT, [0, 3, 6, 9, 12]),
}
