# Melee: guards and blows, one weapon stance each.
#
# Weapon clips keep their hands in the world ("space": None), so a blade's arc
# is exactly what is keyed and the body turns under it. Unarmed clips start on
# m.STANCE and so stay in chest space: shoulders at (+-0.19, 0.065, 1.44).
#
# A wrist is neutral when the forearm runs along the edge, so `edge` is the
# forearm's own direction, squared to the blade: the blade trails the hand
# through a cut and the edge leads it.

import math

import motion as m

TAU = 2.0 * math.pi
STANCE = m.STANCE

SWORD = {"r": "iron_sword"}
GREAT = {"r": "greatsword"}
SHIELD = {"r": "iron_sword", "l": "wooden_shield"}

FREE_L = (0.85, 0.4, -0.3)  # the free left arm's elbow: out and a little back


def wave(t, count=1, phase=0.0):
    """A sine round the loop that is zero at t=0, so a loop starts on its guard."""
    return math.sin(TAU * (count * t + phase)) - math.sin(TAU * phase)


def add(a, b):
    return tuple(x + y for x, y in zip(a, b))


def heel_down(x, y, pitch=16.0, yaw=0.0):
    """A foot landing: heel on the floor, toes still up."""
    foot = m.plant(x, y, heel=-pitch, yaw=yaw, z=0.2 * math.sin(math.radians(pitch)))
    foot["toe"] = 0.0
    return foot


def lifted(x, y, z, pitch=20.0, yaw=0.0):
    """A foot off the floor, toes hanging."""
    foot = m.plant(x, y, heel=pitch, yaw=yaw, z=z)
    foot["toe"] = pitch * 0.4
    return foot


def two_hands(at, blade, edge, edge_l=None, pole_r=(-0.25, 0.2, -0.95), pole_l=(0.25, 0.1, -0.95)):
    """A two-hander: the left hand lower on the same handle, rolled its own way if edge_l is given."""
    n = math.sqrt(sum(b * b for b in blade))
    low = tuple(a - b / n * 0.16 for a, b in zip(at, blade))
    return {"r": {"at": at, "blade": blade, "edge": edge, "pole": pole_r},
            "l": {"at": low, "blade": blade, "edge": edge_l or edge, "pole": pole_l}}


def guard_loop(base, seconds, weapons, breaths=1, drift=1.0):
    """base, breathing: the weight rocks across the feet, the ribs rise and
    fall, the blade wanders a little off its line and comes back."""
    r0 = base["hands"]["r"]
    l0 = base["hands"]["l"]
    two_handed = "blade" in l0

    def at(t):
        breath = wave(t, breaths)
        sway = wave(t, 1, 0.12)
        shift = wave(t, 2, 0.4)
        wander = wave(t, 1, 0.33)
        hand = add(r0["at"], (0.012 * sway * drift, 0.008 * wander * drift, 0.01 * breath * drift))
        blade = add(r0["blade"], (0.035 * wander * drift, 0.025 * shift * drift, 0.0))
        hands = {"r": {"at": hand, "blade": blade}}
        if two_handed:
            hands["l"] = {"at": add(hand, tuple(l - r for l, r in zip(l0["at"], r0["at"]))), "blade": blade}
        else:
            hands["l"] = {"at": add(l0["at"], (0.008 * sway, 0.0, -0.008 * breath))}
        return m.merge(base, {
            "hip": add(base["hip"], (0.016 * sway, 0.005 * shift, -0.009 * breath)),
            "hip_rot": add(base["hip_rot"], (0.6 * shift, -1.4 * sway, 1.0 * wander)),
            "chest_rot": add(base["chest_rot"], (-1.6 * breath, 1.0 * sway, -1.4 * wander)),
            "look": add(base["look"], (0.04 * wander, 0.0, 0.012 * shift)),
            "hands": hands,
        })

    return {"length": seconds, "loop": True, "at": at, "weapons": weapons}


# One-handed guard: left foot leading, right hip back, sword up in front.
GUARD = m.merge(STANCE, {
    "hip": (0.0, 0.03, 0.858),
    "hip_rot": (8.0, 0.0, -12.0),
    "chest_rot": (8.0, 0.0, -5.0),
    "look": (0.05, -1.0, -0.05),
    "feet": {"l": m.plant(0.16, -0.25, yaw=6.0), "r": m.plant(-0.17, 0.09, yaw=-32.0, heel=6.0)},
    "hands": {
        "l": {"space": None, "at": (0.3, -0.12, 0.94), "pole": FREE_L, "curl": 0.5, "thumb": 0.4},
        "r": {"space": None, "at": (-0.25, -0.34, 1.06), "blade": (-0.06, -0.48, 0.87), "edge": (0.37, -0.82, -0.43),
              "pole": (-0.75, 0.45, -0.5), "curl": 0.9, "thumb": 0.7},
    },
})

# Two-handed guard: wide and low, hands at the breastbone, the blade laid back over the right shoulder.
GREAT_GUARD = m.merge(STANCE, {
    "hip": (0.0, 0.05, 0.815),
    "hip_rot": (10.0, 0.0, -18.0),
    "chest_rot": (10.0, 0.0, -14.0),
    "look": (0.1, -1.0, -0.06),
    "feet": {"l": m.plant(0.22, -0.3, yaw=8.0), "r": m.plant(-0.24, 0.16, yaw=-38.0, heel=8.0)},
    "hands": m.merge(
        {"l": {"space": None, "curl": 0.9, "thumb": 0.7}, "r": {"space": None, "curl": 0.9, "thumb": 0.7}},
        two_hands((-0.1, -0.3, 1.18), (-0.45, 0.65, 0.6), (-0.15, -0.6, 0.7))),
})

# Sword and board: shield square in front, sword cocked beside it, feet closer.
SHIELD_GUARD = m.merge(STANCE, {
    "hip": (0.0, 0.02, 0.865),
    "hip_rot": (9.0, 0.0, -16.0),
    "chest_rot": (9.0, 0.0, -14.0),
    "look": (0.08, -1.0, -0.04),
    "feet": {"l": m.plant(0.13, -0.22, yaw=5.0), "r": m.plant(-0.15, 0.07, yaw=-28.0, heel=5.0)},
    "hands": {
        "l": {"space": None, "at": (0.03, -0.38, 1.18), "aim": (-0.96, -0.25, 0.1), "up": (0.02, -0.1, 1.0),
              "pole": (0.8, 0.3, -0.4), "curl": 0.85, "thumb": 0.6},
        "r": {"space": None, "at": (-0.28, -0.16, 1.24), "blade": (0.12, -0.35, 0.93), "edge": (0.22, -0.9, -0.37),
              "pole": (-0.7, 0.2, -0.7), "curl": 0.9, "thumb": 0.7},
    },
})


def g(**patch):
    return m.merge(GUARD, patch)


def gg(**patch):
    return m.merge(GREAT_GUARD, patch)


def gs(**patch):
    return m.merge(SHIELD_GUARD, patch)


def s(**patch):
    return m.merge(STANCE, patch)


# Each blow below is a set of channels with their own timing, not a stack of
# whole-body poses: the hips turn before the chest, the chest before the hand,
# and the hand travels a real arc, so nothing arrives together and nothing stops
# until the blow is spent.


def blow(frames, base, tracks, feet, **extra):
    """A one-shot from channels. tracks: hip, hip_lean, hip_yaw, chest_lean,
    chest_yaw, look, r_at, r_blade, r_pole, l_at, l_pole. feet: {"l": (frames,
    plants), "r": ...}. The sword's edge lies along the forearm: a straight wrist."""
    def at(t):
        f = t * frames
        v = {k: m.track(keys, f) for k, keys in tracks.items()}
        return m.merge(base, {
            "hip": v["hip"],
            "hip_rot": m.turned(*v["hip_lean"], v["hip_yaw"]),
            "chest_rot": m.turned(*v["chest_lean"], v["chest_yaw"]),
            "look": v["look"],
            "feet": {side: m.between(p, t_, f) for side, (t_, p) in feet.items()},
            "hands": {"r": {"at": v["r_at"], "blade": v["r_blade"], "edge": "forearm", "pole": v["r_pole"]},
                      "l": {"at": v["l_at"], "pole": v["l_pole"]}},
        })

    clip = {"length": frames / m.FPS, "at": at}
    clip.update(extra)
    return clip


# Side-on and sunk: left foot well ahead, right hip back, sword low and forward.
READY = m.merge(STANCE, {
    "hip": (0.0, 0.02, 0.79),
    "hip_rot": m.turned(8.0, 0.0, -48.0),
    "chest_rot": m.turned(8.0, 0.0, -50.0),
    "look": (0.05, -1.0, -0.05),
    "feet": {"l": m.plant(0.16, -0.36, yaw=-15.0), "r": m.plant(-0.14, 0.34, yaw=-70.0, heel=5.0)},
    "hands": {
        "l": {"space": None, "at": (0.22, -0.38, 1.02), "pole": FREE_L, "curl": 0.5, "thumb": 0.4},
        "r": {"space": None, "at": (-0.3, 0.16, 0.98), "blade": (0.05, -0.75, 0.65), "edge": "forearm",
              "pole": (-0.8, 0.45, -0.4), "curl": 0.9, "thumb": 0.7},
    },
})
READY_L = READY["feet"]["l"]
READY_R = READY["feet"]["r"]

# Big loop up and behind, a four-frame cut from the right across the front with
# a lunge under it, a hold while the blow is spent, then a long unwinding.
SWING_CLIP = blow(40, READY, {
    "hip": [(0, READY["hip"]), (3, (-0.02, 0.09, 0.815)), (8, (0.0, 0.1, 0.73)), (9, (0.0, 0.04, 0.72)),
            (10, (0.02, -0.16, 0.705)), (11, (0.04, -0.31, 0.695)), (12, (0.05, -0.37, 0.7)),
            (14, (0.05, -0.39, 0.705), "stop"),
            (20, (0.05, -0.37, 0.715)), (27, (0.03, -0.2, 0.8)), (33, (0.0, 0.0, 0.84)), (40, READY["hip"])],
    "hip_lean": [(0, (8.0, 0.0)), (8, (2.0, 0.0)), (10, (12.0, 2.0)), (12, (18.0, 4.0)), (20, (15.0, 3.0)),
                 (30, (4.0, 0.0)), (40, (8.0, 0.0))],
    "hip_yaw": [(0, -48.0), (4, -70.0), (8, -88.0), (9, -55.0), (10, -8.0), (11, 20.0), (12, 38.0), (14, 43.0, "stop"),
                (20, 32.0), (27, -15.0), (33, -42.0), (40, -48.0)],
    "chest_lean": [(0, (8.0, 0.0)), (4, (2.0, -3.0)), (8, (-4.0, -6.0)), (10, (10.0, 0.0)), (12, (28.0, 6.0)),
                   (14, (32.0, 8.0), "stop"), (20, (28.0, 6.0)), (30, (4.0, -2.0)), (40, (8.0, 0.0))],
    "chest_yaw": [(0, -50.0), (3, -66.0), (7, -96.0), (8, -98.0), (9, -88.0), (10, -42.0), (11, 30.0), (12, 78.0),
                  (13, 95.0), (14, 97.0, "stop"), (20, 85.0), (27, 10.0), (33, -40.0), (40, -50.0)],
    "look": [(0, READY["look"]), (5, (-0.2, -1.0, -0.02)), (9, (-0.15, -1.0, -0.05)), (12, (0.15, -1.0, -0.22)),
             (20, (0.25, -1.0, -0.25)), (30, (0.05, -1.0, -0.05)), (40, READY["look"])],
    "r_at": [(0, READY["hands"]["r"]["at"]), (2, (-0.32, 0.12, 1.14)), (3.2, (-0.26, 0.3, 1.3)), (4, (-0.08, 0.5, 1.38)),
             (5, (0.1, 0.58, 1.32)), (6.5, (0.24, 0.58, 1.22)), (8, (0.27, 0.55, 1.18)), (9, (-0.12, 0.17, 1.32)),
             (10, (-0.46, -0.38, 1.2)), (11, (-0.28, -1.0, 0.95)), (12, (0.3, -0.9, 0.78)), (13, (0.4, -0.68, 0.74)),
             (14, (0.33, -0.46, 0.78), "stop"), (20, (0.32, -0.46, 0.8)), (25, (0.02, -0.55, 0.98)), (30, (-0.35, -0.25, 1.4)),
             (35, (-0.38, 0.1, 1.14)), (40, READY["hands"]["r"]["at"])],
    "r_blade": [(0, READY["hands"]["r"]["blade"]), (2.4, (0.2, -0.55, 0.8)), (3.2, (0.0, -0.35, 0.93)), (4, (0.35, 0.6, 0.72)),
                (4.8, (0.2, 0.75, -0.6)), (5.6, (-0.25, 0.8, -0.54)), (6.4, (-0.2, 0.86, -0.46)), (8, (0.0, 0.85, -0.5)),
                (9, (-0.35, 0.75, -0.45)), (10, (-0.5, 0.1, -0.85)), (11, (-0.15, -0.25, -0.95)), (12, (0.15, -0.9, -0.35)),
                (13, (0.7, -0.7, 0.1)), (14, (0.75, -0.48, 0.42), "stop"), (20, (0.68, -0.46, 0.58)), (25, (0.45, -0.54, 0.71)),
                (30, (-0.25, -0.2, 0.95)), (35, (-0.05, -0.55, 0.82)), (40, READY["hands"]["r"]["blade"])],
    "r_pole": [(0, READY["hands"]["r"]["pole"]), (2.4, (-0.8, 0.5, -0.1)), (3.2, (0.05, 1.0, -0.1)), (4, (0.7, 0.6, -0.3)),
               (4.8, (0.6, 0.3, -0.6)), (6.4, (0.45, 0.15, -0.9)), (8, (0.45, 0.2, -0.9)), (9, (-0.5, 0.4, -0.8)),
               (9.6, (-0.4, -0.2, -0.9)), (10.4, (-0.6, 0.1, -0.3)), (11.2, (0.0, -0.7, -0.6)), (12, (0.0, -0.7, -0.7)), (13, (0.1, -0.5, -0.85)),
               (14, (0.2, -0.3, -0.9)), (20, (0.2, -0.3, -0.9)), (30, (-0.8, 0.2, -0.3)), (40, READY["hands"]["r"]["pole"])],
    "l_at": [(0, READY["hands"]["l"]["at"]), (4, (-0.02, -0.42, 1.18)), (6, (0.0, -0.48, 1.1)), (8, (0.08, -0.5, 1.06)),
             (9, (0.14, -0.58, 1.03)), (10, (0.38, -0.55, 1.06)), (11, (0.4, -0.46, 1.14)), (12, (0.42, -0.38, 1.12)),
             (14, (0.36, -0.3, 1.0)), (20, (0.34, -0.26, 0.98)), (30, (0.2, -0.35, 1.12)), (40, READY["hands"]["l"]["at"])],
    "l_pole": [(0, FREE_L), (8, (0.7, -0.1, -0.6)), (12, (0.85, 0.4, -0.3)), (40, FREE_L)],
}, {
    "l": ([0, 4, 8, 10, 11, 22, 30, 35, 40],
          [READY_L, m.plant(0.16, -0.36, yaw=-15.0, heel=18.0), lifted(0.2, -0.42, 0.04, 8.0, yaw=-5.0),
           heel_down(0.24, -0.56, 10.0, yaw=0.0), m.plant(0.24, -0.56, yaw=0.0), m.plant(0.24, -0.56, yaw=0.0),
           m.plant(0.22, -0.5, yaw=-6.0, heel=15.0), lifted(0.18, -0.42, 0.03, 12.0, yaw=-12.0), READY_L]),
    "r": ([0, 8, 10, 12, 22, 30, 35, 40],
          [READY_R, m.plant(-0.14, 0.34, yaw=-70.0, heel=8.0), m.plant(-0.16, 0.3, yaw=-66.0, heel=35.0),
           m.plant(-0.3, 0.1, yaw=-50.0, heel=45.0), m.plant(-0.3, 0.1, yaw=-50.0, heel=45.0),
           m.plant(-0.2, 0.3, yaw=-62.0, heel=20.0), m.plant(-0.15, 0.34, yaw=-68.0, heel=8.0), READY_R]),
}, weapons=SWORD, moments={"impact": [11]})


# Diagonal cut, high right to low left. The hips start the blow, the chest
# follows, the sword comes last and fastest, trailing its own hand until it lands.
SWING = [
    GUARD,
    g(  # gathering: weight back, sword rising
        hip=(-0.02, 0.06, 0.85), hip_rot=(4.0, -3.0, -28.0), chest_rot=(0.0, -6.0, -42.0),
        look=(-0.1, -1.0, 0.0),
        feet={"l": m.plant(0.16, -0.25, yaw=6.0, heel=8.0)},
        hands={"l": {"at": (0.34, -0.2, 1.04)},
               "r": {"at": (-0.36, -0.08, 1.48), "blade": (-0.12, 0.38, 0.92), "edge": (0.37, -0.84, 0.4), "pole": (-0.9, 0.3, -0.2)}},
    ),
    g(  # top of the wind-up: chest turned away, front heel light
        hip=(-0.03, 0.075, 0.845), hip_rot=(2.0, -4.0, -36.0), chest_rot=(-3.0, -8.0, -56.0),
        look=(-0.14, -1.0, 0.02),
        feet={"l": m.plant(0.16, -0.25, yaw=6.0, heel=16.0)},
        hands={"l": {"at": (0.36, -0.22, 1.1)},
               "r": {"at": (-0.34, 0.1, 1.56), "blade": (-0.3, 0.7, 0.65), "edge": (0.16, -0.64, 0.76), "pole": (-0.9, 0.2, 0.1)}},
    ),
    g(  # hips already through, sword still behind, front foot in the air
        hip=(0.02, 0.0, 0.83), hip_rot=(10.0, 0.0, -5.0), chest_rot=(8.0, -2.0, -28.0),
        feet={"l": lifted(0.17, -0.34, 0.03, 10.0, yaw=8.0)},
        hands={"l": {"at": (0.36, -0.04, 1.04)},
               "r": {"at": (-0.46, -0.16, 1.5), "blade": (-0.66, 0.3, 0.69), "edge": (-0.1, -0.94, 0.31), "pole": (-0.9, 0.3, -0.1)}},
    ),
    g(  # sword coming round flat; the heel lands
        hip=(0.04, -0.05, 0.815), hip_rot=(13.0, 2.0, 10.0), chest_rot=(14.0, 2.0, 2.0),
        feet={"l": heel_down(0.18, -0.42, 12.0, yaw=12.0), "r": m.plant(-0.17, 0.09, yaw=-26.0, heel=14.0)},
        hands={"l": {"at": (0.32, 0.12, 1.0)},
               "r": {"at": (-0.32, -0.42, 1.38), "blade": (-0.75, -0.25, 0.6), "edge": (0.41, -0.9, 0.13), "pole": (-0.8, 0.2, -0.4)}},
    ),
    g(  # the blow lands
        hip=(0.06, -0.08, 0.80), hip_rot=(16.0, 3.0, 22.0), chest_rot=(20.0, 4.0, 28.0),
        look=(0.12, -1.0, -0.2),
        feet={"l": m.plant(0.18, -0.42, yaw=12.0), "r": m.plant(-0.17, 0.09, yaw=-22.0, heel=22.0)},
        hands={"l": {"at": (0.28, 0.2, 0.98)},
               "r": {"at": (-0.06, -0.6, 1.16), "blade": (-0.22, -0.93, 0.28), "edge": (0.89, -0.31, -0.34), "pole": (-0.8, 0.1, -0.4)}},
    ),
    g(  # carried through past the target, the blade still behind the hand
        hip=(0.07, -0.09, 0.795), hip_rot=(18.0, 4.0, 34.0), chest_rot=(22.0, 5.0, 46.0),
        look=(0.16, -1.0, -0.25),
        feet={"l": m.plant(0.18, -0.42, yaw=12.0), "r": m.plant(-0.17, 0.09, yaw=-18.0, heel=26.0)},
        hands={"l": {"at": (0.26, 0.24, 0.98)},
               "r": {"at": (0.2, -0.44, 0.98), "blade": (0.5, -0.82, -0.28), "edge": (0.85, 0.53, -0.02), "pole": (-0.7, -0.1, -0.7)}},
    ),
    g(  # the sword's weight still dragging the shoulder down
        hip=(0.06, -0.08, 0.805), hip_rot=(16.0, 3.0, 28.0), chest_rot=(19.0, 4.0, 36.0),
        look=(0.12, -1.0, -0.22),
        feet={"l": m.plant(0.18, -0.42, yaw=12.0), "r": m.plant(-0.17, 0.09, yaw=-20.0, heel=22.0)},
        hands={"l": {"at": (0.27, 0.22, 0.98)},
               "r": {"at": (0.16, -0.45, 1.0), "blade": (0.42, -0.85, -0.3), "edge": (0.9, 0.44, 0.01), "pole": (-0.7, -0.1, -0.7)}},
    ),
    g(  # recovering, weight coming back, front heel up to step home
        hip=(0.03, -0.02, 0.835), hip_rot=(11.0, 1.0, 6.0), chest_rot=(12.0, 2.0, 10.0),
        look=(0.05, -1.0, -0.1),
        feet={"l": lifted(0.17, -0.33, 0.025, 14.0, yaw=9.0), "r": m.plant(-0.17, 0.09, yaw=-28.0, heel=10.0)},
        hands={"l": {"at": (0.29, 0.02, 0.96)},
               "r": {"at": (-0.16, -0.42, 1.08), "blade": (0.2, -0.7, 0.55), "edge": (0.47, -0.46, -0.75), "pole": (-0.7, 0.3, -0.65)}},
    ),
    GUARD,
]

# Straight down from overhead: the body rises and arches, then drops and folds.
# The whole arm stays in the plane of the cut, elbow under it, so the forearm leads.
SWORD_ATTACK = [
    GUARD,
    g(  # rising onto the back leg, hand climbing past the face, blade tipping back
        hip=(0.0, 0.06, 0.87), hip_rot=(3.0, 0.0, -14.0), chest_rot=(-6.0, 0.0, -16.0),
        look=(0.0, -1.0, 0.12),
        feet={"l": m.plant(0.16, -0.25, yaw=6.0, heel=10.0)},
        hands={"l": {"at": (0.26, -0.3, 1.16)},
               "r": {"at": (-0.2, -0.18, 1.62), "blade": (0.0, 0.6, 0.8), "edge": (0.45, -0.7, 0.55), "pole": (-0.15, 0.2, -0.95)}},
    ),
    g(  # top: arched back, chest open, blade laid back over the head
        hip=(-0.01, 0.09, 0.885), hip_rot=(-2.0, -2.0, -16.0), chest_rot=(-14.0, -2.0, -18.0),
        look=(0.0, -1.0, 0.2),
        feet={"l": lifted(0.16, -0.26, 0.015, 16.0, yaw=6.0)},
        hands={"l": {"at": (0.26, -0.34, 1.24)},
               "r": {"at": (-0.2, 0.02, 1.76), "blade": (0.0, 0.92, 0.38), "edge": (0.35, -0.38, 0.86), "pole": (-0.2, -0.4, -0.85)}},
    ),
    g(  # hips dropping, sword left behind overhead, front foot reaching
        hip=(0.01, 0.0, 0.85), hip_rot=(8.0, 0.0, -8.0), chest_rot=(6.0, 0.0, -10.0),
        look=(0.0, -1.0, 0.05),
        feet={"l": lifted(0.17, -0.36, 0.04, 6.0, yaw=8.0)},
        hands={"l": {"at": (0.28, -0.26, 1.14)},
               "r": {"at": (-0.17, -0.24, 1.72), "blade": (0.0, 0.78, 0.62), "edge": (0.35, -0.55, 0.76), "pole": (-0.2, -0.3, -0.9)}},
    ),
    g(  # coming over, the hand leading, the blade still upright behind it
        hip=(0.02, -0.07, 0.81), hip_rot=(14.0, 0.0, -2.0), chest_rot=(18.0, 0.0, -2.0),
        look=(0.0, -1.0, -0.1),
        feet={"l": heel_down(0.18, -0.42, 12.0, yaw=10.0), "r": m.plant(-0.17, 0.09, yaw=-28.0, heel=14.0)},
        hands={"l": {"at": (0.3, -0.2, 1.04)},
               "r": {"at": (-0.14, -0.56, 1.48), "blade": (0.0, -0.15, 0.99), "edge": (0.15, -0.97, -0.15), "pole": (-0.2, 0.1, -0.95)}},
    ),
    g(  # the blow lands; the stamp, hips dropped
        hip=(0.03, -0.14, 0.775), hip_rot=(20.0, 1.0, 2.0), chest_rot=(30.0, 1.0, 4.0),
        look=(0.0, -1.0, -0.35),
        feet={"l": m.plant(0.18, -0.42, yaw=10.0), "r": m.plant(-0.17, 0.09, yaw=-26.0, heel=22.0)},
        hands={"l": {"at": (0.31, -0.2, 0.98)},
               "r": {"at": (-0.12, -0.84, 1.12), "blade": (0.0, -0.84, 0.54), "edge": (0.0, -0.54, -0.84), "pole": (-0.2, 0.3, -0.92)}},
    ),
    g(  # through: folded over the arm, tip near the floor
        hip=(0.03, -0.16, 0.755), hip_rot=(24.0, 1.0, 4.0), chest_rot=(38.0, 1.0, 6.0),
        look=(0.0, -0.8, -0.6),
        feet={"l": m.plant(0.18, -0.42, yaw=10.0), "r": m.plant(-0.17, 0.09, yaw=-24.0, heel=26.0)},
        hands={"l": {"at": (0.31, -0.24, 0.9)},
               "r": {"at": (-0.12, -0.92, 0.86), "blade": (0.0, -0.99, 0.1), "edge": (0.0, -0.1, -0.99), "pole": (-0.2, 0.4, -0.9)}},
    ),
    g(  # held down a beat by the sword's weight
        hip=(0.03, -0.14, 0.765), hip_rot=(22.0, 1.0, 2.0), chest_rot=(34.0, 1.0, 4.0),
        look=(0.0, -0.9, -0.45),
        feet={"l": m.plant(0.18, -0.42, yaw=10.0), "r": m.plant(-0.17, 0.09, yaw=-24.0, heel=22.0)},
        hands={"l": {"at": (0.31, -0.22, 0.92)},
               "r": {"at": (-0.13, -0.86, 0.9), "blade": (0.0, -0.97, 0.22), "edge": (0.0, -0.22, -0.97), "pole": (-0.2, 0.4, -0.9)}},
    ),
    g(  # rising, stepping home
        hip=(0.01, -0.03, 0.83), hip_rot=(12.0, 0.0, -8.0), chest_rot=(16.0, 0.0, -4.0),
        look=(0.03, -1.0, -0.15),
        feet={"l": lifted(0.17, -0.33, 0.025, 14.0, yaw=8.0), "r": m.plant(-0.17, 0.09, yaw=-30.0, heel=12.0)},
        hands={"l": {"at": (0.3, -0.14, 0.95)},
               "r": {"at": (-0.2, -0.46, 1.0), "blade": (-0.03, -0.7, 0.71), "edge": (0.1, -0.71, -0.7), "pole": (-0.55, 0.4, -0.75)}},
    ),
    GUARD,
]

# Long lunge: pulled back onto the rear leg, then front foot out, rear leg driving straight.
# The hand arrives below the shoulder so the blade can sit level above the forearm.
THRUST = [
    GUARD,
    g(  # sword drawn back beside the ribs, weight on the back foot
        hip=(-0.02, 0.09, 0.84), hip_rot=(4.0, -2.0, -30.0), chest_rot=(2.0, -4.0, -42.0),
        look=(-0.06, -1.0, -0.02),
        feet={"l": m.plant(0.16, -0.25, yaw=6.0, heel=12.0)},
        hands={"l": {"at": (0.28, -0.3, 1.05)},
               "r": {"at": (-0.3, 0.04, 1.1), "blade": (0.05, -0.84, 0.54), "edge": (0.18, -0.52, -0.83), "pole": (-0.55, 0.6, -0.6)}},
    ),
    g(  # front foot up and out, hips going
        hip=(0.0, -0.04, 0.8), hip_rot=(9.0, 0.0, -8.0), chest_rot=(10.0, -2.0, -16.0),
        feet={"l": lifted(0.18, -0.46, 0.05, 2.0, yaw=8.0)},
        hands={"l": {"at": (0.3, -0.1, 1.04)},
               "r": {"at": (-0.22, -0.3, 1.04), "blade": (0.04, -0.88, 0.47), "edge": (0.45, -0.4, -0.8), "pole": (-0.5, 0.5, -0.7)}},
    ),
    g(  # heel lands far out, arm unfolding
        hip=(0.02, -0.18, 0.755), hip_rot=(14.0, 1.0, 16.0), chest_rot=(18.0, 2.0, 18.0),
        look=(0.08, -1.0, -0.08),
        feet={"l": heel_down(0.19, -0.66, 14.0, yaw=10.0), "r": m.plant(-0.17, 0.09, yaw=-30.0, heel=22.0)},
        hands={"l": {"at": (0.32, 0.05, 1.04)},
               "r": {"at": (-0.12, -0.8, 1.0), "blade": (0.03, -0.92, 0.39), "edge": (0.1, -0.4, -0.91), "pole": (-0.3, 0.4, -0.85)}},
    ),
    g(  # the point arrives: rear leg straight, body one long line
        hip=(0.03, -0.25, 0.72), hip_rot=(20.0, 2.0, 26.0), chest_rot=(28.0, 3.0, 36.0),
        look=(0.1, -1.0, -0.1),
        feet={"l": m.plant(0.19, -0.66, yaw=10.0), "r": m.plant(-0.17, 0.09, yaw=-30.0, heel=32.0)},
        hands={"l": {"at": (0.32, 0.1, 1.04)},
               "r": {"at": (-0.07, -0.99, 0.98), "blade": (0.02, -0.94, 0.34), "edge": (0.0, -0.34, -0.94), "pole": (-0.3, 0.3, -0.9)}},
    ),
    g(  # overshoot, sinking into the front thigh
        hip=(0.03, -0.27, 0.71), hip_rot=(21.0, 2.0, 28.0), chest_rot=(30.0, 3.0, 40.0),
        look=(0.1, -1.0, -0.12),
        feet={"l": m.plant(0.19, -0.66, yaw=10.0), "r": m.plant(-0.17, 0.09, yaw=-30.0, heel=33.0)},
        hands={"l": {"at": (0.32, 0.1, 1.04)},
               "r": {"at": (-0.05, -1.07, 0.96), "blade": (0.02, -0.95, 0.31), "edge": (-0.1, -0.3, -0.95), "pole": (-0.3, 0.3, -0.9)}},
    ),
    g(  # held, starting to pull out
        hip=(0.02, -0.16, 0.76), hip_rot=(13.0, 1.0, 16.0), chest_rot=(16.0, 2.0, 22.0),
        look=(0.08, -1.0, -0.08),
        feet={"l": m.plant(0.19, -0.66, yaw=10.0), "r": m.plant(-0.17, 0.09, yaw=-30.0, heel=22.0)},
        hands={"l": {"at": (0.32, 0.04, 1.0)},
               "r": {"at": (-0.12, -0.84, 1.0), "blade": (0.0, -0.9, 0.44), "edge": (0.05, -0.44, -0.9), "pole": (-0.4, 0.4, -0.8)}},
    ),
    g(  # front foot up, coming home
        hip=(0.01, -0.06, 0.8), hip_rot=(10.0, 0.0, -2.0), chest_rot=(10.0, 0.0, 2.0),
        feet={"l": lifted(0.18, -0.46, 0.05, 12.0, yaw=8.0), "r": m.plant(-0.17, 0.09, yaw=-32.0, heel=12.0)},
        hands={"l": {"at": (0.3, -0.05, 0.97)},
               "r": {"at": (-0.2, -0.54, 1.06), "blade": (-0.03, -0.72, 0.68), "edge": (0.61, -0.56, -0.56), "pole": (-0.65, 0.45, -0.6)}},
    ),
    g(  # foot down, weight settling
        hip=(0.0, 0.02, 0.85), hip_rot=(8.0, 0.0, -10.0), chest_rot=(8.0, 0.0, -5.0),
        feet={"l": m.plant(0.16, -0.26, yaw=6.0), "r": m.plant(-0.17, 0.09, yaw=-32.0, heel=7.0)},
        hands={"l": {"at": (0.3, -0.11, 0.945)},
               "r": {"at": (-0.25, -0.36, 1.05), "blade": (-0.06, -0.52, 0.85), "edge": (0.33, -0.8, -0.5)}},
    ),
    GUARD,
]

# The big sweep, right to left: everything winds up to the right rear, the left
# foot steps in, and the sword's mass drags the whole body round past the target.
HEAVY_SWING = [
    GREAT_GUARD,
    gg(  # gathering: weight pours onto the back leg, sword sinking behind the shoulder
        hip=(-0.02, 0.1, 0.8), hip_rot=(6.0, -3.0, -36.0), chest_rot=(4.0, -6.0, -60.0),
        look=(-0.18, -1.0, -0.02),
        feet={"l": m.plant(0.22, -0.3, yaw=8.0, heel=10.0)},
        hands=two_hands((-0.3, 0.02, 1.28), (-0.62, 0.68, 0.4), (-0.2, -0.62, 0.76), (-0.6, -0.73, 0.32)),
    ),
    gg(  # top of the wind-up: wrung out, front heel off, blade way behind
        hip=(-0.03, 0.13, 0.81), hip_rot=(3.0, -4.0, -46.0), chest_rot=(-3.0, -8.0, -80.0),
        look=(-0.3, -1.0, 0.0),
        feet={"l": lifted(0.22, -0.3, 0.015, 18.0, yaw=8.0)},
        hands=two_hands((-0.38, 0.14, 1.38), (-0.55, 0.65, 0.52), (-0.21, -0.71, 0.67), (-0.65, -0.72, 0.2)),
    ),
    gg(  # hips go first: the left foot strides, the sword still far behind
        hip=(0.02, 0.0, 0.78), hip_rot=(12.0, -1.0, -8.0), chest_rot=(10.0, -4.0, -36.0),
        look=(-0.1, -1.0, -0.05),
        feet={"l": lifted(0.24, -0.42, 0.06, 6.0, yaw=10.0), "r": m.plant(-0.24, 0.16, yaw=-34.0, heel=14.0)},
        hands=two_hands((-0.42, -0.16, 1.36), (-0.55, 0.35, 0.75), (0.01, -0.9, 0.43), (-0.75, -0.25, -0.35)),
    ),
    gg(  # heel down, sword coming round flat and fast
        hip=(0.05, -0.1, 0.755), hip_rot=(17.0, 1.0, 14.0), chest_rot=(18.0, 0.0, -6.0),
        look=(0.0, -1.0, -0.15),
        feet={"l": heel_down(0.25, -0.54, 12.0, yaw=12.0), "r": m.plant(-0.24, 0.16, yaw=-28.0, heel=22.0)},
        hands=two_hands((-0.24, -0.48, 1.3), (-0.65, -0.35, 0.67), (0.65, -0.6, 0.35), (-0.85, 0.15, -0.35)),
    ),
    gg(  # the blow lands: hips sunk, everything committed
        hip=(0.07, -0.15, 0.74), hip_rot=(20.0, 3.0, 30.0), chest_rot=(26.0, 4.0, 26.0),
        look=(0.15, -1.0, -0.22),
        feet={"l": m.plant(0.25, -0.54, yaw=12.0), "r": m.plant(-0.24, 0.16, yaw=-22.0, heel=28.0)},
        hands=two_hands((0.1, -0.56, 1.2), (-0.25, -0.93, 0.25), (0.82, -0.12, 0.55), (-0.97, 0.22, 0.06)),
    ),
    gg(  # carried on by its own weight
        hip=(0.09, -0.17, 0.732), hip_rot=(22.0, 4.0, 44.0), chest_rot=(30.0, 6.0, 56.0),
        look=(0.3, -1.0, -0.25),
        feet={"l": m.plant(0.25, -0.54, yaw=12.0), "r": m.plant(-0.24, 0.16, yaw=-14.0, heel=32.0)},
        hands=two_hands((0.32, -0.46, 1.16), (0.6, -0.8, -0.1), (0.46, 0.26, 0.77), (-0.5, -0.45, 0.75)),
    ),
    gg(  # dragged right round, back heel high, body twisted over the front knee
        hip=(0.1, -0.16, 0.74), hip_rot=(21.0, 4.0, 52.0), chest_rot=(28.0, 6.0, 68.0),
        look=(0.4, -1.0, -0.2),
        feet={"l": m.plant(0.25, -0.54, yaw=12.0), "r": m.plant(-0.24, 0.16, yaw=-8.0, heel=34.0)},
        hands=two_hands((0.4, -0.14, 1.12), (0.95, 0.25, -0.2), (0.1, 0.6, 0.75), (0.23, 0.2, 0.95)),
    ),
    gg(  # the sword's weight spent: it stops dragging and the arms start to bring it round
        hip=(0.08, -0.12, 0.76), hip_rot=(18.0, 3.0, 36.0), chest_rot=(22.0, 4.0, 44.0),
        look=(0.25, -1.0, -0.15),
        feet={"l": m.plant(0.25, -0.54, yaw=12.0), "r": m.plant(-0.24, 0.16, yaw=-14.0, heel=28.0)},
        hands=two_hands((0.32, -0.26, 1.1), (0.75, -0.2, 0.62), (0.52, 0.76, -0.39), (-0.52, -0.76, 0.39)),
    ),
    gg(  # the heavy haul back: sword lifted up across the body, front foot lightening
        hip=(0.05, -0.06, 0.78), hip_rot=(14.0, 1.0, 14.0), chest_rot=(16.0, 2.0, 18.0),
        look=(0.1, -1.0, -0.12),
        feet={"l": lifted(0.24, -0.42, 0.03, 16.0, yaw=10.0), "r": m.plant(-0.24, 0.16, yaw=-30.0, heel=16.0)},
        hands=two_hands((0.1, -0.36, 1.12), (0.3, -0.2, 0.93), (0.79, -0.49, -0.36), (-0.53, -0.85, -0.01)),
    ),
    gg(  # foot home, blade upright, going back over the shoulder
        hip=(0.01, 0.03, 0.81), hip_rot=(10.0, 0.0, -12.0), chest_rot=(10.0, 0.0, -10.0),
        look=(0.08, -1.0, -0.07),
        feet={"l": m.plant(0.22, -0.31, yaw=8.0), "r": m.plant(-0.24, 0.16, yaw=-36.0, heel=9.0)},
        hands=two_hands((-0.05, -0.3, 1.18), (-0.12, -0.1, 0.99), (0.7, -0.7, 0.02), (-0.81, -0.56, -0.16)),
    ),
    GREAT_GUARD,
]

# Both hands drive it forward from the hip, the whole body behind the pommel.
HEAVY_THRUST = [
    GREAT_GUARD,
    gg(  # sword hauled down to the right hip, point forward, body coiled back
        hip=(-0.01, 0.11, 0.79), hip_rot=(8.0, -2.0, -26.0), chest_rot=(6.0, -3.0, -34.0),
        look=(-0.05, -1.0, -0.05),
        feet={"l": m.plant(0.22, -0.3, yaw=8.0, heel=10.0)},
        hands=two_hands((-0.24, 0.08, 0.98), (0.05, -0.84, 0.54), (0.12, -0.53, -0.84), (-0.72, -0.5, -0.48)),
    ),
    gg(  # front foot up, the hips starting forward
        hip=(0.0, 0.0, 0.77), hip_rot=(12.0, 0.0, -12.0), chest_rot=(12.0, -1.0, -18.0),
        feet={"l": lifted(0.23, -0.44, 0.05, 4.0, yaw=9.0)},
        hands=two_hands((-0.16, -0.12, 0.98), (0.04, -0.86, 0.5), (0.72, -0.32, -0.61), (-0.99, 0.0, 0.1)),
    ),
    gg(  # heel down, both arms beginning to straighten
        hip=(0.02, -0.15, 0.735), hip_rot=(15.0, 1.0, 6.0), chest_rot=(18.0, 1.0, 8.0),
        look=(0.05, -1.0, -0.1),
        feet={"l": heel_down(0.24, -0.62, 12.0, yaw=10.0), "r": m.plant(-0.24, 0.16, yaw=-34.0, heel=20.0)},
        hands=two_hands((-0.08, -0.5, 0.97), (0.02, -0.86, 0.5), (0.85, -0.2, -0.4), (-1.0, -0.05, -0.04)),
    ),
    gg(  # the point goes in: back leg driving, hips low
        hip=(0.03, -0.23, 0.715), hip_rot=(18.0, 2.0, 14.0), chest_rot=(25.0, 2.0, 18.0),
        look=(0.05, -1.0, -0.14),
        feet={"l": m.plant(0.24, -0.62, yaw=10.0), "r": m.plant(-0.24, 0.16, yaw=-32.0, heel=30.0)},
        hands=two_hands((-0.04, -0.76, 0.94), (0.02, -0.86, 0.5), (0.85, -0.25, -0.46), (-0.93, -0.2, -0.3)),
    ),
    gg(  # the sword's weight carries it another hand's breadth
        hip=(0.03, -0.26, 0.705), hip_rot=(20.0, 2.0, 16.0), chest_rot=(28.0, 2.0, 22.0),
        look=(0.05, -1.0, -0.16),
        feet={"l": m.plant(0.24, -0.62, yaw=10.0), "r": m.plant(-0.24, 0.16, yaw=-32.0, heel=33.0)},
        hands=two_hands((-0.03, -0.82, 0.92), (0.02, -0.87, 0.48), (0.87, -0.23, -0.45), (-0.91, -0.21, -0.35)),
    ),
    gg(  # hauling it back out, weight rocking onto the back leg
        hip=(0.02, -0.14, 0.75), hip_rot=(15.0, 1.0, 6.0), chest_rot=(18.0, 1.0, 8.0),
        look=(0.05, -1.0, -0.1),
        feet={"l": m.plant(0.24, -0.62, yaw=10.0), "r": m.plant(-0.24, 0.16, yaw=-34.0, heel=20.0)},
        hands=two_hands((-0.12, -0.5, 0.98), (0.0, -0.84, 0.54), (0.63, -0.42, -0.65), (-0.98, -0.09, -0.15)),
    ),
    gg(  # front foot stepping home, the blade rising
        hip=(0.01, -0.02, 0.79), hip_rot=(12.0, 0.0, -10.0), chest_rot=(12.0, 0.0, -8.0),
        look=(0.08, -1.0, -0.08),
        feet={"l": lifted(0.23, -0.44, 0.04, 14.0, yaw=9.0), "r": m.plant(-0.24, 0.16, yaw=-36.0, heel=12.0)},
        hands=two_hands((-0.12, -0.32, 1.12), (-0.2, -0.5, 0.84), (0.6, -0.72, -0.28), (-0.9, -0.4, -0.05)),
    ),
    GREAT_GUARD,
]

# A fast shove behind the shield: left shoulder and hip go with it.
BASH = [
    SHIELD_GUARD,
    gs(  # the smallest gather: shield pulled in, weight back
        hip=(-0.01, 0.05, 0.85), hip_rot=(8.0, -1.0, -24.0), chest_rot=(6.0, -2.0, -30.0),
        feet={"l": lifted(0.13, -0.24, 0.02, 14.0, yaw=5.0)},
        hands={"l": {"at": (0.05, -0.28, 1.16)}, "r": {"at": (-0.3, -0.12, 1.24)}},
    ),
    gs(  # the slam: arm and shoulder through, foot just down, sword hand drawn back
        hip=(0.02, -0.14, 0.81), hip_rot=(14.0, 2.0, -12.0), chest_rot=(18.0, 2.0, -30.0),
        look=(0.06, -1.0, -0.14),
        feet={"l": heel_down(0.14, -0.4, 10.0, yaw=6.0), "r": m.plant(-0.15, 0.07, yaw=-26.0, heel=20.0)},
        hands={"l": {"at": (0.04, -0.72, 1.24), "up": (0.0, 0.2, 0.98)},
               "r": {"at": (-0.32, -0.22, 1.22), "blade": (0.1, -0.42, 0.9)}},
    ),
    gs(  # pushing on through, shield top tipping away
        hip=(0.02, -0.17, 0.8), hip_rot=(15.0, 2.0, -10.0), chest_rot=(20.0, 2.0, -27.0),
        look=(0.06, -1.0, -0.15),
        feet={"l": m.plant(0.14, -0.4, yaw=6.0), "r": m.plant(-0.15, 0.07, yaw=-26.0, heel=24.0)},
        hands={"l": {"at": (0.04, -0.76, 1.26), "up": (0.0, 0.28, 0.96)},
               "r": {"at": (-0.32, -0.24, 1.22), "blade": (0.1, -0.42, 0.9)}},
    ),
    gs(  # still leaning in behind it
        hip=(0.02, -0.14, 0.81), hip_rot=(13.0, 1.0, -12.0), chest_rot=(17.0, 1.0, -24.0),
        feet={"l": m.plant(0.14, -0.4, yaw=6.0), "r": m.plant(-0.15, 0.07, yaw=-26.0, heel=18.0)},
        hands={"l": {"at": (0.04, -0.68, 1.22), "up": (0.0, 0.16, 0.98)},
               "r": {"at": (-0.31, -0.22, 1.23), "blade": (0.11, -0.4, 0.91)}},
    ),
    gs(  # rocking back, front foot coming home, shield returning to the line
        hip=(0.01, -0.04, 0.85), hip_rot=(10.0, 0.0, -15.0), chest_rot=(11.0, 0.0, -16.0),
        feet={"l": lifted(0.13, -0.31, 0.03, 12.0, yaw=5.0), "r": m.plant(-0.15, 0.07, yaw=-27.0, heel=9.0)},
        hands={"l": {"at": (0.03, -0.48, 1.2), "up": (0.01, 0.0, 1.0)}},
    ),
    SHIELD_GUARD,
]

# Rear-hand cross. Fist targets are in chest space, so the punch line is keyed
# against the chest's own turn: the hip and shoulder do the travelling.
PUNCH = [
    STANCE,
    s(  # coiled: right hip back, hands up, left heel light
        hip=(0.0, 0.06, 0.87), hip_rot=(7.0, -2.0, -24.0), chest_rot=(4.0, -3.0, -34.0),
        look=(-0.08, -1.0, -0.05),
        feet={"l": m.plant(0.118, -0.165, yaw=9.0, heel=14.0), "r": m.plant(-0.128, -0.085, yaw=-16.0, heel=6.0)},
        hands={"l": {"at": (0.22, -0.12, 1.2), "pole": (0.5, 0.5, -0.9), "curl": 0.95, "thumb": 0.7},
               "r": {"at": (-0.22, -0.02, 1.26), "pole": (-0.45, 0.6, -0.9), "curl": 0.95, "thumb": 0.7}},
    ),
    s(  # hips first: front foot out, fist still at the shoulder
        hip=(0.02, -0.02, 0.83), hip_rot=(11.0, 0.0, 0.0), chest_rot=(8.0, -1.0, -14.0),
        look=(0.0, -1.0, -0.08),
        feet={"l": lifted(0.13, -0.3, 0.05, 6.0, yaw=9.0), "r": m.plant(-0.128, -0.085, yaw=-14.0, heel=14.0)},
        hands={"l": {"at": (0.22, -0.16, 1.32), "pole": (0.5, 0.5, -0.9), "curl": 0.95, "thumb": 0.7},
               "r": {"at": (-0.3, -0.2, 1.36), "pole": (-0.5, 0.6, -0.8), "curl": 0.95, "thumb": 0.7}},
    ),
    s(  # heel lands, the shoulder coming through
        hip=(0.03, -0.09, 0.8), hip_rot=(13.0, 1.0, 14.0), chest_rot=(13.0, 1.0, 16.0),
        look=(0.08, -1.0, -0.1),
        feet={"l": heel_down(0.14, -0.4, 10.0, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-10.0, heel=22.0)},
        hands={"l": {"at": (0.22, -0.06, 1.28), "pole": (0.5, 0.5, -0.9), "curl": 0.95, "thumb": 0.7},
               "r": {"at": (-0.38, -0.34, 1.42), "pole": (-0.5, 0.5, -0.7), "curl": 0.95, "thumb": 0.7}},
    ),
    s(  # the fist lands: rear heel pivoted, chest turned right through
        hip=(0.03, -0.12, 0.79), hip_rot=(14.0, 2.0, 24.0), chest_rot=(18.0, 3.0, 42.0),
        look=(0.25, -1.0, -0.12),
        feet={"l": m.plant(0.14, -0.4, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-4.0, heel=28.0)},
        hands={"l": {"at": (0.22, -0.02, 1.26), "pole": (0.5, 0.5, -0.9), "curl": 0.95, "thumb": 0.7},
               "r": {"at": (-0.44, -0.42, 1.42), "pole": (-0.5, 0.5, -0.7), "curl": 0.95, "thumb": 0.7}},
    ),
    s(  # overshoot
        hip=(0.035, -0.14, 0.785), hip_rot=(15.0, 2.0, 28.0), chest_rot=(20.0, 3.0, 48.0),
        look=(0.28, -1.0, -0.13),
        feet={"l": m.plant(0.14, -0.4, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-2.0, heel=30.0)},
        hands={"l": {"at": (0.22, 0.0, 1.25), "pole": (0.5, 0.5, -0.9), "curl": 0.95, "thumb": 0.7},
               "r": {"at": (-0.46, -0.43, 1.4), "pole": (-0.5, 0.5, -0.7), "curl": 0.95, "thumb": 0.7}},
    ),
    s(  # fist snapping home to the chin, the hips turning back
        hip=(0.02, -0.08, 0.81), hip_rot=(11.0, 1.0, 12.0), chest_rot=(11.0, 1.0, 18.0),
        look=(0.1, -1.0, -0.08),
        feet={"l": m.plant(0.14, -0.4, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-10.0, heel=16.0)},
        hands={"l": {"at": (0.22, -0.1, 1.26), "pole": (0.5, 0.5, -0.9), "curl": 0.9, "thumb": 0.6},
               "r": {"at": (-0.26, -0.22, 1.32), "pole": (-0.45, 0.6, -0.85), "curl": 0.9, "thumb": 0.6}},
    ),
    s(  # stepping back to stand, hands sinking
        hip=(0.015, 0.0, 0.865), hip_rot=(7.0, -1.0, 0.0), chest_rot=(5.0, 1.0, 4.0),
        look=(0.03, -1.0, -0.04),
        feet={"l": lifted(0.125, -0.25, 0.03, 12.0, yaw=9.0), "r": m.plant(-0.128, -0.085, yaw=-13.0, heel=5.0)},
        hands={"l": {"at": (0.26, -0.06, 1.1), "pole": (0.3, 0.7, -1.0), "curl": 0.6, "thumb": 0.4},
               "r": {"at": (-0.27, -0.06, 1.1), "pole": (-0.3, 0.7, -1.0), "curl": 0.6, "thumb": 0.4}},
    ),
    STANCE,
]

# A beast's overhand rake. The base carries every optional key the blow touches.
CLAW_BASE = m.merge(STANCE, {"hands": {"l": {"spread": 0.0, "clav": (0.0, 0.0)}, "r": {"spread": 0.0, "clav": (0.0, 0.0)}}})


def c(**patch):
    return m.merge(CLAW_BASE, patch)


OPEN_R = {"curl": 0.5, "thumb": 0.35, "spread": 18.0}
OPEN_L = {"curl": 0.5, "thumb": 0.35, "spread": 14.0}

CLAW = [
    CLAW_BASE,
    c(  # hunching in, the right arm starting to climb, left claw reaching out in front
        hip=(0.0, 0.05, 0.85), hip_rot=(5.0, -3.0, -20.0), chest_rot=(-4.0, -5.0, -30.0),
        look=(-0.05, -1.0, 0.05),
        feet={"l": m.plant(0.118, -0.165, yaw=9.0, heel=8.0), "r": m.plant(-0.128, -0.085, yaw=-15.0, heel=3.0)},
        hands={"l": {**OPEN_L, "at": (0.3, -0.24, 1.2), "pole": (0.7, 0.4, -0.6), "clav": (0.2, 0.0)},
               "r": {**OPEN_R, "at": (-0.54, 0.1, 1.42), "pole": (-0.9, 0.35, -0.2), "clav": (0.0, 0.5)}},
    ),
    c(  # top: reared up and wrung back, arm high, the whole shoulder hoisted
        hip=(-0.02, 0.08, 0.875), hip_rot=(-1.0, -5.0, -36.0), chest_rot=(-14.0, -8.0, -48.0),
        look=(-0.1, -1.0, 0.14),
        feet={"l": lifted(0.118, -0.17, 0.02, 16.0, yaw=9.0), "r": m.plant(-0.128, -0.085, yaw=-18.0, heel=4.0)},
        hands={"l": {**OPEN_L, "at": (0.34, -0.3, 1.3), "pole": (0.7, 0.4, -0.6), "clav": (0.3, 0.0)},
               "r": {**OPEN_R, "at": (-0.36, 0.2, 1.8), "pole": (-0.9, 0.25, 0.15), "clav": (-0.15, 1.0)}},
    ),
    c(  # hips drop in and turn, the arm hanging back up there
        hip=(0.02, -0.04, 0.82), hip_rot=(10.0, 0.0, -8.0), chest_rot=(4.0, -2.0, -22.0),
        look=(0.0, -1.0, 0.0),
        feet={"l": lifted(0.13, -0.3, 0.05, 6.0, yaw=9.0), "r": m.plant(-0.128, -0.085, yaw=-14.0, heel=12.0)},
        hands={"l": {**OPEN_L, "at": (0.34, -0.14, 1.22), "pole": (0.7, 0.4, -0.6), "clav": (0.1, 0.0)},
               "r": {**OPEN_R, "at": (-0.42, -0.1, 1.78), "pole": (-0.85, 0.2, 0.1), "clav": (0.1, 0.9)}},
    ),
    c(  # the shoulder pulls it over, heel landing
        hip=(0.04, -0.1, 0.8), hip_rot=(15.0, 2.0, 6.0), chest_rot=(18.0, 2.0, 6.0),
        look=(0.05, -1.0, -0.15),
        feet={"l": heel_down(0.15, -0.4, 10.0, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-10.0, heel=18.0)},
        hands={"l": {**OPEN_L, "at": (0.34, 0.02, 1.14), "pole": (0.7, 0.4, -0.6), "clav": (0.0, 0.0)},
               "r": {**OPEN_R, "at": (-0.2, -0.46, 1.46), "pole": (-0.8, 0.2, -0.4), "clav": (0.5, 0.3)}},
    ),
    c(  # the claws rake through the target, spine curling over it
        hip=(0.06, -0.16, 0.78), hip_rot=(18.0, 3.0, 18.0), chest_rot=(30.0, 4.0, 30.0),
        look=(0.15, -1.0, -0.3),
        feet={"l": m.plant(0.15, -0.4, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-6.0, heel=24.0)},
        hands={"l": {**OPEN_L, "at": (0.32, 0.12, 1.08), "pole": (0.7, 0.4, -0.6), "clav": (0.0, 0.0)},
               "r": {**OPEN_R, "at": (-0.1, -0.46, 1.27), "pole": (-0.7, 0.2, -0.6), "clav": (0.6, 0.0)}},
    ),
    c(  # dragging down and across to the far hip
        hip=(0.07, -0.18, 0.77), hip_rot=(20.0, 4.0, 26.0), chest_rot=(36.0, 5.0, 44.0),
        look=(0.25, -1.0, -0.35),
        feet={"l": m.plant(0.15, -0.4, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-2.0, heel=28.0)},
        hands={"l": {**OPEN_L, "at": (0.32, 0.14, 1.06), "pole": (0.7, 0.4, -0.6), "clav": (0.0, 0.0)},
               "r": {**OPEN_R, "at": (-0.04, -0.34, 1.16), "pole": (-0.6, 0.3, -0.7), "clav": (0.5, -0.2)}},
    ),
    c(  # hanging there, blowing, the arm's weight on the spine
        hip=(0.06, -0.15, 0.78), hip_rot=(18.0, 3.0, 22.0), chest_rot=(32.0, 4.0, 36.0),
        look=(0.2, -1.0, -0.3),
        feet={"l": m.plant(0.15, -0.4, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-4.0, heel=24.0)},
        hands={"l": {**OPEN_L, "at": (0.32, 0.12, 1.04), "pole": (0.7, 0.4, -0.6), "clav": (0.0, 0.0)},
               "r": {**OPEN_R, "at": (-0.03, -0.32, 1.15), "pole": (-0.6, 0.3, -0.7), "clav": (0.4, -0.15)}},
    ),
    c(  # pushing up off the front foot, the arm swinging home
        hip=(0.02, -0.04, 0.84), hip_rot=(11.0, 0.0, 6.0), chest_rot=(14.0, 2.0, 10.0),
        look=(0.05, -1.0, -0.12),
        feet={"l": lifted(0.13, -0.3, 0.03, 14.0, yaw=9.0), "r": m.plant(-0.128, -0.085, yaw=-12.0, heel=10.0)},
        hands={"l": {"at": (0.28, 0.04, 0.98), "pole": (0.4, 0.7, -0.9), "curl": 0.42, "thumb": 0.3, "spread": 6.0, "clav": (0.0, 0.0)},
               "r": {"at": (-0.1, -0.16, 1.02), "pole": (-0.5, 0.5, -0.8), "curl": 0.45, "thumb": 0.3, "spread": 8.0, "clav": (0.1, 0.0)}},
    ),
    c(  # standing, the last of the sway going out
        hip=(0.012, 0.03, 0.89), hip_rot=(6.0, -1.5, -1.0), chest_rot=(5.0, 1.0, 3.0),
        look=(0.0, -1.0, -0.05),
        hands={"l": {"at": (0.25, 0.02, 0.92), "curl": 0.34, "thumb": 0.25, "spread": 2.0},
               "r": {"at": (-0.25, 0.03, 0.93), "curl": 0.38, "thumb": 0.25, "spread": 3.0}},
    ),
    CLAW_BASE,
]

# Lunging for the neck: chest and head first, arms seizing, then the head worries.
BITE_BASE = m.merge(STANCE, {"head_up": (0.0, 0.0, 1.0)})


def b(**patch):
    return m.merge(BITE_BASE, patch)


BITE = [
    BITE_BASE,
    b(  # reared back, mouth up, hands rising open
        hip=(0.0, 0.08, 0.85), hip_rot=(2.0, 0.0, -6.0), chest_rot=(-12.0, 0.0, -6.0),
        look=(0.0, -1.0, 0.35), head_up=(0.0, 0.3, 1.0),
        feet={"l": m.plant(0.118, -0.165, yaw=9.0, heel=10.0)},
        hands={"l": {"at": (0.3, -0.2, 1.12), "pole": (0.8, 0.3, -0.6), "curl": 0.25, "thumb": 0.2},
               "r": {"at": (-0.3, -0.2, 1.12), "pole": (-0.8, 0.3, -0.6), "curl": 0.25, "thumb": 0.2}},
    ),
    b(  # springing: hips forward, chest diving, front foot in the air
        hip=(0.01, -0.12, 0.82), hip_rot=(14.0, 0.0, 0.0), chest_rot=(24.0, 0.0, 2.0),
        look=(0.0, -1.0, 0.1), head_up=(0.0, 0.1, 1.0),
        feet={"l": lifted(0.13, -0.3, 0.04, 8.0, yaw=9.0), "r": m.plant(-0.128, -0.085, yaw=-13.0, heel=14.0)},
        hands={"l": {"at": (0.27, -0.46, 1.38), "pole": (0.8, 0.3, -0.6), "curl": 0.35, "thumb": 0.3},
               "r": {"at": (-0.27, -0.46, 1.38), "pole": (-0.8, 0.3, -0.6), "curl": 0.35, "thumb": 0.3}},
    ),
    b(  # teeth meet: chest over the front foot, hands closing on shoulders
        hip=(0.01, -0.2, 0.8), hip_rot=(18.0, 1.0, 2.0), chest_rot=(38.0, 1.0, 4.0),
        look=(0.0, -0.95, -0.3), head_up=(0.0, -0.3, 1.0),
        feet={"l": heel_down(0.14, -0.38, 10.0, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-12.0, heel=20.0)},
        hands={"l": {"at": (0.2, -0.5, 1.38), "pole": (0.8, 0.3, -0.6), "curl": 0.7, "thumb": 0.6},
               "r": {"at": (-0.2, -0.5, 1.38), "pole": (-0.8, 0.3, -0.6), "curl": 0.7, "thumb": 0.6}},
    ),
    b(  # the head snaps down and bites in
        hip=(0.01, -0.21, 0.79), hip_rot=(19.0, 1.0, 2.0), chest_rot=(42.0, 1.0, 4.0),
        look=(0.0, -0.6, -0.8), head_up=(0.0, -0.8, 0.6),
        feet={"l": m.plant(0.14, -0.38, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-12.0, heel=22.0)},
        hands={"l": {"at": (0.16, -0.46, 1.32), "pole": (0.8, 0.3, -0.6), "curl": 0.9, "thumb": 0.8},
               "r": {"at": (-0.16, -0.46, 1.32), "pole": (-0.8, 0.3, -0.6), "curl": 0.9, "thumb": 0.8}},
    ),
    b(  # wrenching it one way
        hip=(0.02, -0.2, 0.79), hip_rot=(18.0, 3.0, 8.0), chest_rot=(38.0, 3.0, 12.0),
        look=(0.38, -0.85, -0.35), head_up=(0.3, -0.3, 0.9),
        feet={"l": m.plant(0.14, -0.38, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-12.0, heel=20.0)},
        hands={"l": {"at": (0.18, -0.4, 1.3), "pole": (0.8, 0.3, -0.6), "curl": 0.9, "thumb": 0.8},
               "r": {"at": (-0.18, -0.4, 1.3), "pole": (-0.8, 0.3, -0.6), "curl": 0.9, "thumb": 0.8}},
    ),
    b(  # and the other, tearing
        hip=(0.0, -0.18, 0.795), hip_rot=(18.0, -2.0, -6.0), chest_rot=(40.0, -2.0, -8.0),
        look=(-0.28, -0.75, -0.6), head_up=(-0.2, -0.6, 0.8),
        feet={"l": m.plant(0.14, -0.38, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-12.0, heel=18.0)},
        hands={"l": {"at": (0.2, -0.36, 1.26), "pole": (0.8, 0.3, -0.6), "curl": 0.85, "thumb": 0.7},
               "r": {"at": (-0.2, -0.36, 1.26), "pole": (-0.8, 0.3, -0.6), "curl": 0.85, "thumb": 0.7}},
    ),
    b(  # letting go, head coming up, the foot stepping home
        hip=(0.01, -0.05, 0.85), hip_rot=(10.0, 0.0, -2.0), chest_rot=(14.0, 0.0, 0.0),
        look=(0.0, -1.0, -0.1), head_up=(0.0, 0.0, 1.0),
        feet={"l": lifted(0.13, -0.28, 0.03, 14.0, yaw=9.0), "r": m.plant(-0.128, -0.085, yaw=-13.0, heel=8.0)},
        hands={"l": {"at": (0.27, -0.1, 1.06), "pole": (0.6, 0.5, -0.8), "curl": 0.45, "thumb": 0.3},
               "r": {"at": (-0.27, -0.1, 1.06), "pole": (-0.6, 0.5, -0.8), "curl": 0.45, "thumb": 0.3}},
    ),
    BITE_BASE,
]

# A bull's charge on the spot: a deep head-down gather, then the head and right
# shoulder come up and forward from the legs.
GORE = [
    STANCE,
    s(  # sinking, the head going down between the shoulders, arms swept back
        hip=(0.0, 0.08, 0.81), hip_rot=(20.0, 0.0, -8.0), chest_rot=(32.0, 0.0, -12.0),
        look=(0.0, -0.6, -0.8),
        feet={"l": m.plant(0.118, -0.165, yaw=9.0, heel=10.0)},
        hands={"l": {"at": (0.3, 0.14, 1.0), "pole": (0.8, 0.5, -0.3), "curl": 0.8, "thumb": 0.6},
               "r": {"at": (-0.3, 0.14, 1.0), "pole": (-0.8, 0.5, -0.3), "curl": 0.8, "thumb": 0.6}},
    ),
    s(  # the gather: hips deep, spine a bow, front foot off and reaching
        hip=(0.0, 0.1, 0.77), hip_rot=(27.0, 0.0, -12.0), chest_rot=(48.0, 0.0, -16.0),
        look=(0.0, -0.3, -0.95),
        feet={"l": lifted(0.14, -0.3, 0.05, 8.0, yaw=9.0), "r": m.plant(-0.128, -0.085, yaw=-14.0, heel=10.0)},
        hands={"l": {"at": (0.32, 0.22, 0.98), "pole": (0.8, 0.5, -0.3), "curl": 0.85, "thumb": 0.65},
               "r": {"at": (-0.32, 0.22, 0.98), "pole": (-0.8, 0.5, -0.3), "curl": 0.85, "thumb": 0.65}},
    ),
    s(  # legs fire: hips rising forward, heel down, head still low
        hip=(0.01, -0.12, 0.82), hip_rot=(22.0, 2.0, 6.0), chest_rot=(30.0, 3.0, 14.0),
        look=(0.0, -0.7, -0.7),
        feet={"l": heel_down(0.15, -0.4, 10.0, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-10.0, heel=24.0)},
        hands={"l": {"at": (0.32, 0.18, 1.02), "pole": (0.8, 0.5, -0.3), "curl": 0.85, "thumb": 0.65},
               "r": {"at": (-0.32, 0.18, 1.02), "pole": (-0.8, 0.5, -0.3), "curl": 0.85, "thumb": 0.65}},
    ),
    s(  # the horns drive in, right shoulder behind them
        hip=(0.02, -0.2, 0.86), hip_rot=(14.0, 3.0, 14.0), chest_rot=(14.0, 5.0, 28.0),
        look=(0.1, -0.85, -0.5),
        feet={"l": m.plant(0.15, -0.4, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-6.0, heel=30.0)},
        hands={"l": {"at": (0.32, 0.12, 1.06), "pole": (0.8, 0.5, -0.3), "curl": 0.8, "thumb": 0.6},
               "r": {"at": (-0.32, 0.12, 1.06), "pole": (-0.8, 0.5, -0.3), "curl": 0.8, "thumb": 0.6}},
    ),
    s(  # the toss: head flung up, chest opening, back heel high
        hip=(0.02, -0.22, 0.875), hip_rot=(8.0, 3.0, 14.0), chest_rot=(-4.0, 5.0, 26.0),
        look=(0.05, -0.9, 0.35),
        feet={"l": m.plant(0.15, -0.4, yaw=10.0), "r": m.plant(-0.128, -0.085, yaw=-6.0, heel=34.0)},
        hands={"l": {"at": (0.3, 0.08, 1.0), "pole": (0.8, 0.5, -0.4), "curl": 0.6, "thumb": 0.4},
               "r": {"at": (-0.3, 0.08, 1.0), "pole": (-0.8, 0.5, -0.4), "curl": 0.6, "thumb": 0.4}},
    ),
    s(  # settling back, front foot stepping home
        hip=(0.015, -0.08, 0.87), hip_rot=(9.0, 1.0, 6.0), chest_rot=(8.0, 3.0, 12.0),
        look=(0.02, -1.0, 0.0),
        feet={"l": lifted(0.14, -0.3, 0.03, 12.0, yaw=9.0), "r": m.plant(-0.128, -0.085, yaw=-11.0, heel=12.0)},
        hands={"l": {"at": (0.27, 0.05, 0.95), "pole": (0.5, 0.7, -0.8), "curl": 0.45, "thumb": 0.3},
               "r": {"at": (-0.27, 0.05, 0.95), "pole": (-0.5, 0.7, -0.8), "curl": 0.45, "thumb": 0.3}},
    ),
    STANCE,
]

CLIPS = {
    "Stance_Sword": guard_loop(GUARD, 1.33, SWORD),
    "Stance_Greatsword": guard_loop(GREAT_GUARD, 1.33, GREAT),
    "Stance_Shield": guard_loop(SHIELD_GUARD, 2.5, SHIELD, breaths=2),
    "Swing": SWING_CLIP,
    "Sword_Attack": m.action(SWORD_ATTACK, [0, 4, 8, 10, 11, 12, 14, 19, 25, 31], weapons=SWORD, moments={"impact": [12]}),
    "Thrust": m.action(THRUST, [0, 3, 5, 7, 8, 9, 13, 18, 22, 26], weapons=SWORD, moments={"impact": [8]}),
    "Heavy_Swing": m.action(HEAVY_SWING, [0, 5, 9, 12, 13, 14, 16, 19, 23, 28, 33, 38], weapons=GREAT, moments={"impact": [14]}),
    "Heavy_Thrust": m.action(HEAVY_THRUST, [0, 6, 8, 10, 11, 13, 18, 25, 33], weapons=GREAT, moments={"impact": [11]}),
    "Bash": m.action(BASH, [0, 2, 4, 6, 10, 15, 20], weapons=SHIELD, moments={"impact": [4]}),
    "Punch": m.action(PUNCH, [0, 4, 6, 7, 8, 10, 14, 20, 27], moments={"impact": [8]}),
    "Claw": m.action(CLAW, [0, 5, 10, 12, 14, 15, 17, 23, 32, 38, 44], moments={"impact": [15]}),
    "Bite": m.action(BITE, [0, 5, 8, 9, 11, 13, 15, 18, 22], moments={"impact": [9]}),
    "Gore": m.action(GORE, [0, 4, 8, 10, 11, 13, 17, 25], moments={"impact": [11]}),
}

