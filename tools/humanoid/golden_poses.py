# Golden poses: the key drawings of a clip, each a whole body written out in
# full. Nothing is merged from a base pose or offset from another key; every
# part of every pose is placed on purpose, so each one reads on its own as a
# still. The motion between them comes later, from per-joint curves timed on a
# sheet, not from blending one pose into another.
#
# Pose dicts as body_rig.py describes them: Blender space, the body faces -Y,
# +X is the character's left, Z up. Hands in "chest" space are placed as if
# the chest were at rest.

from motion import plant

L, R = 1.0, -1.0


def hung(side, x, y, z, pitch, toe=6.0, pole=None):
    """A foot in the air, toes let down by pitch degrees."""
    s = L if side == "l" else R
    return {"at": (x, y, z), "rot": (pitch, s * 1.0, s * 8.0), "toe": toe,
            "pole": pole or (s * 0.25, -1.0, -0.15)}


def arm(side, x, y, z, pole, curl, thumb=0.25, spread=0.0):
    return {"at": (x, y, z), "space": "chest", "pole": pole, "curl": curl, "thumb": thumb, "spread": spread}


# ---- Hover ------------------------------------------------------------------
# Held up, not standing on anything. The right knee is drawn up in front and
# the left leg hangs long under it, toes let down: one leg working, one at
# rest, so the silhouette never mirrors. The chest sits a touch back over the
# hips, the arms float out from the sides with the elbows soft and the left
# hand a little ahead of the right. The bob is two drawings, top and bottom.

HOVER_UP = {  # top of the bob: the body pulled up, the knee higher, arms open wider
    "hip": (0.004, 0.005, 1.295),
    "hip_rot": (-3.0, -2.0, 4.0),
    "chest_rot": (-5.0, 1.5, -3.0),
    "look": (0.02, -1.0, -0.06),
    "feet": {
        "l": hung("l", 0.115, 0.10, 0.585, 52.0, toe=8.0),
        "r": hung("r", -0.06, 0.045, 0.775, 38.0, toe=4.0, pole=(-0.2, -1.0, 0.25)),
    },
    "hands": {
        "l": arm("l", 0.54, -0.1, 1.08, (0.4, 0.85, -0.5), 0.34, spread=0.15),
        "r": arm("r", -0.53, 0.14, 1.06, (-0.4, 0.85, -0.5), 0.4, spread=0.1),
    },
}

HOVER_DOWN = {  # bottom of the bob: the body settles, the knee lets down a little, arms gather in
    "hip": (-0.004, 0.0, 1.185),
    "hip_rot": (-1.5, -1.0, 2.5),
    "chest_rot": (-3.5, 0.5, -1.5),
    "look": (0.0, -1.0, -0.1),
    "feet": {
        "l": hung("l", 0.11, 0.055, 0.47, 46.0, toe=6.0),
        "r": hung("r", -0.065, 0.06, 0.63, 34.0, toe=4.0, pole=(-0.2, -1.0, 0.2)),
    },
    "hands": {
        "l": arm("l", 0.5, -0.07, 1.02, (0.4, 0.85, -0.5), 0.38, spread=0.08),
        "r": arm("r", -0.49, 0.12, 1.0, (-0.4, 0.85, -0.5), 0.44, spread=0.05),
    },
}

# ---- Takeoff ----------------------------------------------------------------
# A knee-drive launch: the body dips, the left knee drives up and forward
# while the right leg pushes off the floor, and once airborne the legs trade,
# the left letting down long and the right drawing up into the hover. The
# arms swing out and up with the drive and then open into the hover's float.

TAKEOFF_STANCE = {  # standing, the same as the stance every clip starts from
    "hip": (0.012, 0.035, 0.897),
    "hip_rot": (5.0, -1.5, -2.0),
    "chest_rot": (3.0, 1.0, 1.5),
    "look": (0.0, -1.0, -0.03),
    "feet": {"l": plant(0.118, -0.165, yaw=9.0), "r": plant(-0.128, -0.085, yaw=-13.0)},
    "hands": {
        "l": arm("l", 0.25, 0.02, 0.905, (0.25, 0.8, -1.0), 0.32),
        "r": arm("r", -0.255, 0.035, 0.91, (-0.25, 0.8, -1.0), 0.36),
    },
}

TAKEOFF_DIP = {  # the anticipation: knees give, hips sink and sit back, arms draw back
    "hip": (0.0, 0.06, 0.82),
    "hip_rot": (11.0, -1.0, -3.0),
    "chest_rot": (8.0, 1.0, 0.0),
    "look": (0.0, -1.0, -0.18),
    "feet": {"l": plant(0.118, -0.165, yaw=9.0), "r": plant(-0.128, -0.085, yaw=-13.0)},
    "hands": {
        "l": arm("l", 0.38, 0.12, 1.0, (0.6, 0.75, -0.45), 0.3),
        "r": arm("r", -0.38, 0.13, 0.99, (-0.6, 0.75, -0.45), 0.34),
    },
}

TAKEOFF_DRIVE = {  # the left knee drives up in front, the right leg loaded under the body, arms swing out
    "hip": (-0.03, 0.03, 0.84),
    "hip_rot": (6.0, 3.0, 5.0),
    "chest_rot": (4.0, -1.0, -4.0),
    "look": (0.0, -1.0, -0.12),
    "feet": {
        "l": hung("l", 0.13, -0.06, 0.4, 34.0, toe=4.0, pole=(0.1, -1.0, 0.6)),
        "r": plant(-0.128, -0.085, heel=24.0, yaw=-13.0),
    },
    "hands": {
        "l": arm("l", 0.54, 0.08, 1.13, (0.4, 0.85, -0.5), 0.26, spread=0.2),
        "r": arm("r", -0.53, 0.14, 1.12, (-0.4, 0.85, -0.5), 0.3, spread=0.15),
    },
}

TAKEOFF_PUSH = {  # the right leg straightens and rolls onto the ball; left arm goes ahead, right behind
    "hip": (-0.04, -0.13, 0.975),
    "hip_rot": (2.0, 4.0, 6.0),
    "chest_rot": (6.0, -1.0, -6.0),
    "look": (0.0, -1.0, 0.0),
    "feet": {
        "l": hung("l", 0.11, -0.12, 0.5, 36.0, toe=4.0, pole=(0.1, -1.0, 0.6)),
        "r": plant(-0.128, -0.085, heel=62.0, yaw=-13.0),
    },
    "hands": {
        "l": arm("l", 0.46, -0.19, 1.1, (0.4, 0.85, -0.5), 0.24, spread=0.2),
        "r": arm("r", -0.47, 0.2, 1.08, (-0.4, 0.85, -0.5), 0.28, spread=0.15),
    },
}

TAKEOFF_RISE = {  # off the floor, the legs trading: left lets down long, right knee comes up
    "hip": (-0.03, -0.08, 1.17),
    "hip_rot": (-1.0, 1.0, 4.0),
    "chest_rot": (1.0, 0.0, -4.0),
    "look": (0.0, -1.0, 0.04),
    "feet": {
        "l": hung("l", 0.1, -0.02, 0.45, 50.0, toe=6.0),
        "r": hung("r", -0.07, 0.07, 0.52, 52.0, toe=6.0, pole=(-0.15, -1.0, 0.3)),
    },
    "hands": {
        "l": arm("l", 0.51, -0.13, 1.09, (0.4, 0.85, -0.5), 0.28, spread=0.2),
        "r": arm("r", -0.5, 0.17, 1.07, (-0.4, 0.85, -0.5), 0.32, spread=0.15),
    },
}

TAKEOFF_PEAK = {  # carried a little past the hover: left leg long, right knee up, arms high and open
    "hip": (-0.02, -0.01, 1.27),
    "hip_rot": (-3.0, -1.0, 4.0),
    "chest_rot": (-5.0, 1.0, -3.0),
    "look": (0.0, -1.0, 0.0),
    "feet": {
        "l": hung("l", 0.11, 0.06, 0.55, 54.0, toe=8.0),
        "r": hung("r", -0.05, 0.06, 0.76, 42.0, toe=4.0, pole=(-0.2, -1.0, 0.3)),
    },
    "hands": {
        "l": arm("l", 0.55, -0.1, 1.11, (0.4, 0.85, -0.5), 0.32, spread=0.18),
        "r": arm("r", -0.54, 0.14, 1.09, (-0.4, 0.85, -0.5), 0.36, spread=0.12),
    },
}

GOLDEN = {
    "Hover_Up": HOVER_UP,
    "Hover_Down": HOVER_DOWN,
    "Takeoff_Stance": TAKEOFF_STANCE,
    "Takeoff_Dip": TAKEOFF_DIP,
    "Takeoff_Drive": TAKEOFF_DRIVE,
    "Takeoff_Push": TAKEOFF_PUSH,
    "Takeoff_Rise": TAKEOFF_RISE,
    "Takeoff_Peak": TAKEOFF_PEAK,
}
