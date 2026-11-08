# The dragon's key poses, as body_rig.py reads them.

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

POSES = {"stance": STANCE}
