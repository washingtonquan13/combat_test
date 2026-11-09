# Locomotion and reactions: the jog, flinch, death, knockdown and get-up, and the jump.
# No weapons. Blender axes: faces -Y, +X is their left, +Z up, floor at 0.

import math

import motion as m

STANCE = m.STANCE
TAU = 2.0 * math.pi
Vector = m.Vector


# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------

def shot(keys, frames, lag=None, curve=m.once, taper=5.0, **extra):
    """action(), except the lag closes to nothing over the last frames, so the
    clip ends exactly on its last key."""
    lag = m.BODY_LAG if lag is None else lag
    count = frames[-1]

    def at(t):
        f = t * count
        k = min(1.0, (count - f) / taper)
        return m.between(keys, frames, f, {a: b * k for a, b in lag.items()}, curve)

    clip = {"length": count / m.FPS, "at": at}
    clip.update(extra)
    return clip


SIDE = {"l": 1.0, "r": -1.0}


def knee_default(side, pitch=0.0, roll=0.0, yaw=0.0):
    """The way body_rig points a knee when no pole is given."""
    return tuple(m._rot(pitch, roll, yaw) @ Vector((SIDE[side] * 0.08, -1.0, 0.0)))


def down(side, x, y, heel=0.0, yaw=0.0, z=0.0, roll=0.0, pole=None):
    """A foot on the ground (or just off it), with its knee direction spelled out."""
    f = m.plant(x, y, heel=heel, yaw=yaw, z=z, roll=roll)
    f["pole"] = pole or knee_default(side, heel, roll, yaw)
    return f


def free(at, rot, pole, toe=0.0):
    """A foot in the air or lying on its heel."""
    return {"at": at, "rot": rot, "toe": toe, "pole": pole}


def hand(at, pole, curl=0.3, thumb=0.25):
    return {"at": at, "pole": pole, "curl": curl, "thumb": thumb, "space": "world"}


# STANCE with its hands written in the world (the solved chest-space targets)
# and every knee spelled out, so falls can put hands on the floor.
STAND = m.merge(STANCE, {
    "head_up": (0.0, 0.0, 1.0),
    "feet": {"l": down("l", 0.118, -0.165, yaw=9.0), "r": down("r", -0.128, -0.085, yaw=-13.0)},
    "hands": {
        "l": hand((0.2477, 0.0033, 0.8773), (0.2109, 0.8571, -0.961), 0.32, 0.25),
        "r": hand((-0.2573, 0.0048, 0.8919), (-0.2889, 0.844, -0.9523), 0.36, 0.25),
    },
})


def K(base=STAND, **patch):
    return m.merge(base, patch)


# --------------------------------------------------------------------------
# Jog_Fwd: a treadmill. During contact a foot rides a belt moving backward at
# one steady speed; only the part touching the belt changes, heel then ball.
# --------------------------------------------------------------------------

JOG_DUTY = 0.36                # share of the cycle a foot is on the ground
JOG_HEEL_LAND = -0.235         # where the heel touches down, relative to the hip's column
JOG_TRAVEL = 0.80              # belt travel while the foot is down
JOG_HEEL_TO_BALL = 0.189
JOG_HEEL_ANKLE = Vector((0.0, -0.04, 0.104))
JOG_SEC = 0.93
JOG_X = {"l": 0.078, "r": -0.078}
JOG_YAW = {"l": 5.0, "r": -7.0}


def _smooth_rise(u):
    return 0.0 if u <= 0.0 else u * u


def jog_contact_pitch(u):
    """Heel strike, rolled flat quickly, flat, then peeling up over the ball."""
    if u < 0.17:
        return -17.0 * (1.0 - m.smooth(u / 0.17))
    if u < 0.40:
        return 0.0
    return 52.0 * _smooth_rise((u - 0.40) / 0.60)


def jog_contact(side, u):
    """(ankle, pitch, toe) during contact, u 0..1."""
    yaw = JOG_YAW[side]
    x = JOG_X[side]
    heel_y = JOG_HEEL_LAND + JOG_TRAVEL * u
    pitch = jog_contact_pitch(u)
    flat = m._rot(0.0, 0.0, yaw)
    heel = Vector((x, heel_y, 0.0))
    if pitch < 0.0:
        ankle = heel + m._rot(pitch, 0.0, yaw) @ JOG_HEEL_ANKLE
        return ankle, pitch, 0.0
    ball = heel + flat @ Vector((0.0, -JOG_HEEL_TO_BALL, 0.0))
    f = m.plant(ball.x, ball.y, heel=pitch, yaw=yaw)
    return Vector(f["at"]), pitch, pitch


def _herm(a, b, ma, mb, h, u):
    return m._hermite(a, b, ma, mb, h, u)


def jog_swing(side, v):
    """(ankle, pitch, toe) in the air, v 0..1, leaving and arriving at belt speed."""
    span = 1.0 - JOG_DUTY
    eps = 1e-3
    a0, p0, _ = jog_contact(side, 1.0)
    a1, p1, _ = jog_contact(side, 0.0)
    prev, _, _ = jog_contact(side, 1.0 - eps)
    nxt, _, _ = jog_contact(side, eps)
    m0 = (a0 - prev) / (eps * JOG_DUTY)
    m1 = (nxt - a1) / (eps * JOG_DUTY)
    x = JOG_X[side]
    # Mid-swing: the heel has kicked up behind the knee, passing under the hip.
    mid = Vector((x * 0.92, 0.17, 0.40))
    mid_m = Vector((0.0, (a1.y - a0.y) / span * 1.25, -0.10 / span))
    h = span * 0.5
    if v < 0.5:
        u = v * 2.0
        ankle = Vector(tuple(_herm(a0[i], mid[i], m0[i], mid_m[i], h, u) for i in range(3)))
        pitch = _herm(p0, 70.0, 150.0, -60.0, h, u)
    else:
        u = v * 2.0 - 1.0
        ankle = Vector(tuple(_herm(mid[i], a1[i], mid_m[i], m1[i], h, u) for i in range(3)))
        pitch = _herm(70.0, p1, -60.0, 0.0, h, u)
    toe = 52.0 * (1.0 - m.smooth(v / 0.42)) + 4.0 * m.smooth(v / 0.42) * (1.0 - m.smooth((v - 0.6) / 0.4))
    return ankle, pitch, toe


def jog_foot(side, phase):
    phase %= 1.0
    if phase < JOG_DUTY:
        ankle, pitch, toe = jog_contact(side, phase / JOG_DUTY)
    else:
        ankle, pitch, toe = jog_swing(side, (phase - JOG_DUTY) / (1.0 - JOG_DUTY))
    return {"at": tuple(ankle), "rot": (pitch, 0.0, JOG_YAW[side]), "toe": toe,
            "pole": (SIDE[side] * 0.1, -1.0, 0.05)}


def jog_arm(side, swing):
    """swing +1: fist forward at the chest, -1: elbow driven behind. Chest space."""
    s = SIDE[side]
    q = 0.5 + 0.5 * swing
    y = 0.20 - 0.44 * q
    z = 1.06 + 0.15 * q * q
    x = 0.275 - 0.075 * q
    return {"at": (s * x, y, z), "space": "chest",
            "pole": (s * (0.55 - 0.2 * q), 0.95, -0.35 - 0.2 * q),
            "curl": 0.62, "thumb": 0.5}


def jog_at(t):
    """Left heel strikes at t=0, right at t=0.5; both flights between."""
    c = lambda shift: math.cos(TAU * (t + shift))
    c2 = lambda shift: math.cos(2.0 * TAU * (t + shift))
    # Highest in flight (t = duty + half the gap), lowest at mid-contact.
    top = (JOG_DUTY + 0.5) * 0.5
    bounce = c2(-top)
    hip = (0.012 * c(-0.18), 0.02 + 0.006 * c2(-0.08), 0.866 + 0.024 * bounce)
    # Left leg forward = left hip forward = pelvis turned right (yaw negative).
    hip_yaw = -9.0 * c(0.03)
    chest_yaw = 12.5 * c(0.0)
    hip_rot = (9.5 + 1.5 * c2(-0.30), -3.5 * c(-0.2), hip_yaw)
    chest_rot = (11.0 + 2.2 * c2(-0.34), 2.0 * c(-0.25), chest_yaw)
    look = (0.05 * c(-0.1) * 0.25, -1.0, -0.11 + 0.012 * bounce)
    # Each arm against its own leg; arms a touch behind the legs.
    swing = c(-0.02)
    return m.merge(STANCE, {
        "hip": hip, "hip_rot": hip_rot, "chest_rot": chest_rot, "look": look,
        "feet": {"l": jog_foot("l", t), "r": jog_foot("r", t + 0.5)},
        "hands": {"r": jog_arm("r", swing), "l": jog_arm("l", -swing)},
    })


# --------------------------------------------------------------------------
# Hit_Chest: a blow on the right of the chest. The ribcage goes first, the hips
# give, the arms and head are left behind, then the weight comes back.
# --------------------------------------------------------------------------

_HIT_LAG = {"hip": 0.0, "hip_rot": 0.0, "chest_rot": 0.3, "look": 0.9, "head_up": 0.9}

HIT_CHEST = [
    STANCE,
    m.merge(STANCE, {  # struck: ribs driven back and to the right, arms left in front
        "hip": (0.02, 0.075, 0.884), "hip_rot": (0.0, -2.0, -6.0), "chest_rot": (-17.0, 4.0, -15.0),
        "look": (-0.1, -1.0, 0.08),
        "hands": {"l": {"at": (0.3, -0.12, 0.99)}, "r": {"at": (-0.32, -0.15, 1.03)}},
    }),
    m.merge(STANCE, {  # carried back: hips still going, chest at its furthest, head snapped up
        "hip": (0.022, 0.1, 0.87), "hip_rot": (2.0, -3.0, -8.0), "chest_rot": (-13.0, 5.0, -18.0),
        "look": (-0.14, -1.0, 0.2),
        "feet": {"l": m.plant(0.118, -0.165, yaw=9.0, heel=7.0)},
        "hands": {"l": {"at": (0.3, -0.05, 0.95)}, "r": {"at": (-0.31, -0.1, 0.99)}},
    }),
    m.merge(STANCE, {  # the weight comes back, chest over-corrects forward
        "hip": (0.016, 0.06, 0.876), "hip_rot": (7.0, -2.0, -4.0), "chest_rot": (6.0, 2.0, -5.0),
        "look": (-0.05, -1.0, -0.05),
        "hands": {"l": {"at": (0.26, 0.0, 0.91)}, "r": {"at": (-0.27, 0.0, 0.92)}},
    }),
    STANCE,
]

# --------------------------------------------------------------------------
# Falls. LIE is the last frame of the knockdown and the first of the get-up.
# --------------------------------------------------------------------------

LIE = K(
    hip=(0.0, 0.08, 0.1), hip_rot=(-83.0, 4.0, 5.0), chest_rot=(-88.0, -5.0, 2.0),
    look=(0.12, 0.42, 1.0), head_up=(0.0, 0.92, -0.38),
    feet={"l": free((0.2, -0.71, 0.098), (-55.0, 0.0, 26.0), (0.35, -0.2, 1.0)),
          "r": free((-0.1, -0.65, 0.11), (-48.0, 0.0, -18.0), (-0.45, -0.1, 1.0))},
    hands={"l": hand((0.5, 0.42, 0.098), (0.8, 0.5, -0.1), 0.3, 0.2),
           "r": hand((-0.5, 0.15, 0.098), (-0.8, 0.3, -0.1), 0.42, 0.25)},
)

KNOCKBACK = [
    STAND,
    K(  # struck: ribs thrown back, hips still under him, arms left in front
        hip=(0.0, 0.08, 0.872), hip_rot=(-5.0, -1.0, -3.0), chest_rot=(-26.0, 3.0, -8.0),
        look=(0.0, -1.0, 0.05),
        feet={"l": down("l", 0.118, -0.165, heel=-0.0, yaw=9.0), "r": down("r", -0.128, -0.085, heel=8.0, yaw=-13.0)},
        hands={"l": hand((0.3, -0.26, 1.13), (0.6, 0.4, -0.7)), "r": hand((-0.32, -0.3, 1.2), (-0.6, 0.4, -0.7))},
    ),
    K(  # feet gone: the body is a C, legs trail forward, arms flung up in front
        hip=(0.0, 0.17, 0.79), hip_rot=(-26.0, 0.0, 0.0), chest_rot=(-52.0, 3.0, -6.0),
        look=(0.03, -0.8, 0.55), head_up=(0.0, 0.5, 0.85),
        feet={"l": free((0.13, -0.3, 0.17), (-18.0, 0.0, 9.0), (0.1, -1.0, 0.25)),
              "r": free((-0.13, -0.33, 0.26), (-26.0, 0.0, -13.0), (-0.1, -1.0, 0.35))},
        hands={"l": hand((0.42, 0.22, 1.38), (0.7, 0.4, -0.5)), "r": hand((-0.44, 0.24, 1.44), (-0.7, 0.4, -0.5))},
    ),
    K(  # flat out in the air, tipping
        hip=(0.0, 0.16, 0.58), hip_rot=(-55.0, 2.0, 2.0), chest_rot=(-78.0, 1.0, -3.0),
        look=(0.05, -0.45, 0.9), head_up=(0.0, 0.85, 0.5),
        feet={"l": free((0.15, -0.54, 0.4), (-46.0, 0.0, 14.0), (0.15, -0.8, 0.7)),
              "r": free((-0.14, -0.58, 0.54), (-52.0, 0.0, -14.0), (-0.15, -0.8, 0.7))},
        hands={"l": hand((0.46, 0.45, 1.0), (0.7, 0.6, -0.1)), "r": hand((-0.47, 0.47, 1.04), (-0.7, 0.6, -0.1))},
    ),
    K(  # coming down: legs still up, arms still high
        hip=(0.0, 0.12, 0.27), hip_rot=(-78.0, 3.0, 4.0), chest_rot=(-88.0, -2.0, 0.0),
        look=(0.06, -0.35, 0.95), head_up=(0.0, 0.92, 0.35),
        feet={"l": free((0.18, -0.68, 0.42), (-58.0, 0.0, 20.0), (0.25, -0.5, 1.0)),
              "r": free((-0.14, -0.66, 0.6), (-58.0, 0.0, -16.0), (-0.3, -0.5, 1.0))},
        hands={"l": hand((0.62, 0.45, 0.48), (0.8, 0.4, 0.2)), "r": hand((-0.62, 0.42, 0.5), (-0.8, 0.4, 0.2))},
    ),
    K(  # back and hips hit, head still coming, legs slapping down after
        hip=(0.0, 0.09, 0.105), hip_rot=(-84.0, 4.0, 5.0), chest_rot=(-88.0, -4.0, 2.0),
        look=(0.08, -0.5, 0.85), head_up=(0.0, 0.85, 0.5),
        feet={"l": free((0.2, -0.72, 0.22), (-58.0, 0.0, 24.0), (0.3, -0.3, 1.0)),
              "r": free((-0.11, -0.66, 0.34), (-54.0, 0.0, -18.0), (-0.45, -0.2, 1.0))},
        hands={"l": hand((0.56, 0.45, 0.19), (0.8, 0.5, 0.05), 0.2, 0.2), "r": hand((-0.56, 0.2, 0.2), (-0.8, 0.35, 0.05), 0.28, 0.2)},
    ),
    K(  # the small rebound: ribs lift off the floor, head taps down
        hip=(0.0, 0.08, 0.11), hip_rot=(-81.0, 4.0, 5.0), chest_rot=(-78.0, -5.0, 2.0),
        look=(0.09, -0.3, 0.95), head_up=(0.0, 0.95, 0.3),
        feet={"l": free((0.2, -0.71, 0.1), (-54.0, 0.0, 26.0), (0.35, -0.2, 1.0)),
              "r": free((-0.1, -0.65, 0.14), (-50.0, 0.0, -18.0), (-0.45, -0.1, 1.0))},
        hands={"l": hand((0.5, 0.42, 0.13), (0.8, 0.5, -0.1), 0.3, 0.2), "r": hand((-0.5, 0.15, 0.13), (-0.8, 0.3, -0.1), 0.42, 0.25)},
    ),
    LIE,
]

# The get-up. Sits up on the right hand, tucks the right leg under, comes onto
# the right knee over a planted left foot, pushes off the left thigh, and steps through.
_KNEE_L_FWD = (0.2, -1.0, 0.2)

GET_UP = [
    LIE,
    K(  # stirs: head comes up, knees draw in, ribs start to curl, rolling toward the right
        hip=(0.0, 0.08, 0.11), hip_rot=(-80.0, -3.0, 2.0), chest_rot=(-72.0, -14.0, -6.0),
        look=(-0.1, -0.75, 0.65), head_up=(0.0, 0.65, 0.76),
        feet={"l": free((0.16, -0.5, 0.104), (-14.0, 0.0, 14.0), (0.3, -0.5, 1.0)),
              "r": free((-0.2, -0.56, 0.104), (-22.0, -8.0, -24.0), (-0.65, -0.4, 0.8))},
        hands={"l": hand((0.34, 0.14, 0.22), (0.7, 0.3, 0.3), 0.3, 0.2), "r": hand((-0.42, 0.3, 0.13), (-0.8, 0.6, -0.1), 0.42, 0.25)},
    ),
    K(  # sitting up, propped on the right hand, left foot planted, right leg folding out
        hip=(-0.03, 0.09, 0.135), hip_rot=(-54.0, -8.0, -6.0), chest_rot=(-28.0, -18.0, -18.0),
        look=(-0.18, -1.0, 0.2), head_up=(0.0, 0.15, 1.0),
        feet={"l": down("l", 0.13, -0.47, yaw=8.0, pole=(0.35, -0.8, 0.6)),
              "r": free((-0.36, -0.2, 0.125), (-8.0, -38.0, -55.0), (-0.4, 0.2, 0.9))},
        hands={"l": hand((0.22, -0.04, 0.56), (0.7, 0.5, -0.1), 0.45, 0.3), "r": hand((-0.42, 0.34, 0.19), (-0.7, 0.8, 0.1), 0.15, 0.2)},
    ),
    K(  # rocking onto the hand, the right shin sweeps under him with the knee up
        hip=(-0.055, 0.095, 0.185), hip_rot=(-35.0, -9.0, -10.0), chest_rot=(1.0, -19.0, -21.0),
        look=(-0.19, -1.0, 0.03), head_up=(0.0, 0.08, 1.0),
        feet={"l": down("l", 0.13, -0.425, yaw=8.0, pole=(0.32, -0.9, 0.55)),
              "r": free((-0.41, 0.05, 0.17), (16.0, -30.0, -45.0), (-0.25, -0.9, 0.35), toe=10.0)},
        hands={"l": hand((0.2, -0.22, 0.64), (0.75, 0.45, -0.15), 0.48, 0.32), "r": hand((-0.43, 0.22, 0.215), (-0.7, 0.8, 0.05), 0.15, 0.2)},
    ),
    K(  # hips up off the floor, weight onto the hand, right knee comes under
        hip=(-0.08, 0.1, 0.265), hip_rot=(-16.0, -10.0, -14.0), chest_rot=(30.0, -20.0, -24.0),
        look=(-0.2, -1.0, -0.15), head_up=(0.0, 0.0, 1.0),
        feet={"l": down("l", 0.13, -0.38, yaw=8.0, pole=(0.3, -1.0, 0.5)),
              "r": free((-0.42, 0.28, 0.2), (40.0, -22.0, -35.0), (-0.42, -0.78, -0.3), toe=20.0)},
        hands={"l": hand((0.19, -0.32, 0.68), (0.8, 0.4, -0.2), 0.5, 0.35), "r": hand((-0.44, 0.1, 0.235), (-0.7, 0.8, 0.0), 0.15, 0.2)},
    ),
    K(  # on the right knee, left foot forward, the hand comes off the floor
        hip=(-0.02, 0.1, 0.49), hip_rot=(10.0, -4.0, -10.0), chest_rot=(26.0, -4.0, -10.0),
        look=(-0.08, -1.0, -0.2), head_up=(0.0, 0.0, 1.0),
        feet={"l": down("l", 0.13, -0.33, yaw=8.0, pole=(0.2, -1.0, 0.2)),
              "r": free((-0.18, 0.5, 0.205), (62.0, 0.0, -12.0), (-0.12, -1.0, -0.4), toe=55.0)},
        hands={"l": hand((0.19, -0.42, 0.67), (0.7, 0.6, -0.2), 0.55, 0.4), "r": hand((-0.33, -0.02, 0.5), (-0.6, 0.7, -0.5), 0.2, 0.25)},
    ),
    K(  # pushing off the left thigh, hips up and forward, back knee leaving
        hip=(0.03, -0.09, 0.71), hip_rot=(26.0, -1.0, -6.0), chest_rot=(36.0, 0.0, -4.0),
        look=(-0.03, -1.0, -0.25), head_up=(0.0, 0.0, 1.0),
        feet={"l": down("l", 0.13, -0.33, yaw=8.0, pole=(0.15, -1.0, 0.1)),
              "r": free((-0.17, 0.42, 0.235), (55.0, 0.0, -14.0), (-0.1, -1.0, -0.1), toe=32.0)},
        hands={"l": hand((0.2, -0.46, 0.74), (0.7, 0.6, -0.3), 0.55, 0.4), "r": hand((-0.3, -0.15, 0.68), (-0.5, 0.7, -0.7), 0.3, 0.25)},
    ),
    K(  # standing into it, right leg swings through
        hip=(0.06, -0.09, 0.85), hip_rot=(13.0, 2.0, -3.0), chest_rot=(15.0, 2.0, 0.0),
        look=(0.0, -1.0, -0.1), head_up=(0.0, 0.0, 1.0),
        feet={"l": down("l", 0.13, -0.3, yaw=8.0),
              "r": free((-0.14, 0.03, 0.2), (18.0, 0.0, -13.0), (-0.1, -1.0, 0.1), toe=8.0)},
        hands={"l": hand((0.25, -0.12, 0.86), (0.4, 0.8, -0.8), 0.4, 0.3), "r": hand((-0.27, -0.04, 0.86), (-0.35, 0.8, -0.9), 0.35, 0.25)},
    ),
    K(  # right foot down, weight on it now; left heel lifts to shuffle back
        hip=(-0.03, -0.03, 0.885), hip_rot=(7.0, -2.0, -3.0), chest_rot=(6.0, 0.0, 1.0),
        look=(0.0, -1.0, -0.05), head_up=(0.0, 0.0, 1.0),
        feet={"l": down("l", 0.124, -0.22, heel=20.0, yaw=9.0),
              "r": down("r", -0.128, -0.085, yaw=-13.0)},
    ),
    STAND,
]

# Death01: the knees go, he sits down hard twisting left, the body rolls back and
# to the left, and settles slack.
_DEATH_LAG = {"hip": 0.0, "hip_rot": 0.0, "chest_rot": 2.0, "look": 4.0, "head_up": 4.0}

DEAD = K(
    hip=(0.03, 0.04, 0.095), hip_rot=(-77.0, 16.0, 20.0), chest_rot=(-83.0, 32.0, 14.0),
    look=(0.58, 0.52, 0.63), head_up=(-0.25, 0.8, -0.55),
    feet={"l": free((0.46, -0.66, 0.1), (-40.0, 25.0, 46.0), (0.8, -0.1, 0.55)),
          "r": free((0.12, -0.56, 0.13), (-14.0, 35.0, 14.0), (0.2, -0.4, 1.0))},
    hands={"l": hand((0.5, 0.34, 0.11), (0.6, 0.8, -0.1), 0.25, 0.15),
           "r": hand((0.06, 0.16, 0.29), (-0.7, 0.1, 0.8), 0.45, 0.3)},
)

DEATH = [
    STAND,
    K(  # struck: head jerks, ribs give, weight rocks to the heels
        hip=(0.01, 0.06, 0.885), hip_rot=(1.0, -2.0, -4.0), chest_rot=(-9.0, 2.0, -7.0),
        look=(-0.08, -1.0, 0.1),
        hands={"l": hand((0.26, -0.02, 0.92), (0.25, 0.8, -0.9), 0.3, 0.2), "r": hand((-0.27, -0.03, 0.95), (-0.3, 0.8, -0.9), 0.3, 0.2)},
    ),
    K(  # the knees go: hips sag, ribs fold, head falls forward, arms go dead
        hip=(0.015, 0.06, 0.79), hip_rot=(12.0, 1.0, 2.0), chest_rot=(20.0, 3.0, 3.0),
        look=(0.03, -0.9, -0.45),
        feet={"l": down("l", 0.118, -0.165, yaw=9.0, pole=(0.18, -1.0, 0.0)),
              "r": down("r", -0.128, -0.085, heel=12.0, yaw=-13.0, pole=(-0.18, -1.0, 0.0))},
        hands={"l": hand((0.24, -0.03, 0.79), (0.2, 0.8, -0.9), 0.22, 0.15), "r": hand((-0.24, -0.07, 0.8), (-0.2, 0.8, -0.9), 0.22, 0.15)},
    ),
    K(  # sagging down and turning left, the right knee lets go first
        hip=(0.04, 0.09, 0.6), hip_rot=(14.0, 6.0, 12.0), chest_rot=(30.0, 10.0, 14.0),
        look=(0.18, -0.85, -0.55),
        feet={"l": down("l", 0.118, -0.165, yaw=9.0, pole=(0.45, -1.0, 0.0)),
              "r": down("r", -0.12, -0.11, heel=24.0, yaw=-10.0, pole=(-0.12, -1.0, 0.0))},
        hands={"l": hand((0.32, -0.02, 0.61), (0.3, 0.7, -0.8), 0.2, 0.15), "r": hand((-0.2, -0.2, 0.6), (-0.25, 0.6, -0.9), 0.2, 0.15)},
    ),
    K(  # nearly sitting: hips drop past the knees, feet start to go out in front
        hip=(0.06, 0.12, 0.33), hip_rot=(-14.0, 10.0, 20.0), chest_rot=(16.0, 14.0, 22.0),
        look=(0.3, -0.85, -0.35),
        feet={"l": down("l", 0.17, -0.27, yaw=20.0, pole=(0.7, -0.8, 0.5)),
              "r": down("r", -0.06, -0.26, heel=16.0, yaw=4.0, pole=(-0.1, -0.9, 0.5))},
        hands={"l": hand((0.42, 0.14, 0.34), (0.6, 0.6, -0.3), 0.18, 0.15), "r": hand((-0.18, -0.14, 0.45), (-0.5, 0.2, -0.8), 0.25, 0.2)},
    ),
    K(  # sat down hard on the left cheek; the ribs keep going back
        hip=(0.07, 0.1, 0.065), hip_rot=(-46.0, 14.0, 24.0), chest_rot=(-14.0, 20.0, 22.0),
        look=(0.36, -0.75, 0.0),
        feet={"l": down("l", 0.27, -0.46, yaw=32.0, roll=8.0, z=0.012, pole=(0.8, -0.6, 0.6)),
              "r": down("r", 0.0, -0.45, heel=8.0, yaw=10.0, pole=(0.15, -0.8, 0.7))},
        hands={"l": hand((0.5, 0.2, 0.22), (0.7, 0.6, -0.2), 0.16, 0.12), "r": hand((-0.06, -0.02, 0.28), (-0.5, 0.1, -0.5), 0.3, 0.2)},
    ),
    K(  # toppling back, rolling to the left
        hip=(0.05, 0.07, 0.075), hip_rot=(-64.0, 15.0, 22.0), chest_rot=(-52.0, 27.0, 18.0),
        look=(0.5, -0.65, 0.5), head_up=(-0.1, 0.5, 0.85),
        feet={"l": free((0.38, -0.58, 0.1), (-22.0, 18.0, 40.0), (0.8, -0.3, 0.6)),
              "r": down("r", 0.06, -0.52, heel=2.0, yaw=12.0, roll=14.0, z=0.015, pole=(0.2, -0.6, 0.9))},
        hands={"l": hand((0.6, 0.22, 0.2), (0.7, 0.7, -0.1), 0.15, 0.12), "r": hand((-0.06, 0.02, 0.31), (-0.65, 0.0, 0.6), 0.38, 0.25)},
    ),
    K(  # shoulders land, head still coming down, left arm flops out
        hip=(0.035, 0.05, 0.09), hip_rot=(-75.0, 16.0, 20.0), chest_rot=(-85.0, 31.0, 15.0),
        look=(0.6, 0.0, 0.8), head_up=(-0.25, 0.92, -0.1),
        feet={"l": free((0.45, -0.64, 0.1), (-36.0, 24.0, 44.0), (0.8, -0.1, 0.55)),
              "r": free((0.11, -0.55, 0.14), (-12.0, 30.0, 14.0), (0.2, -0.45, 1.0))},
        hands={"l": hand((0.53, 0.33, 0.14), (0.6, 0.8, -0.1), 0.2, 0.12), "r": hand((0.04, 0.13, 0.31), (-0.7, 0.1, 0.8), 0.42, 0.28)},
    ),
    K(DEAD,  # a last slack rebound: chest lifts a finger's width, head rolls to rest
        hip=(0.033, 0.045, 0.098), hip_rot=(-76.0, 16.0, 20.0), chest_rot=(-79.0, 32.0, 14.0),
        look=(0.59, 0.42, 0.69), head_up=(-0.25, 0.84, -0.48),
    ),
    DEAD,
]

# --------------------------------------------------------------------------
# The jump. Feet stay on their stance marks, so the land needs no shuffle.
# --------------------------------------------------------------------------

_L_XY = (0.118, -0.165)
_R_XY = (-0.128, -0.085)
_JUMP_LAG = {"hip": 0.0, "hip_rot": 0.0, "chest_rot": 0.8, "look": 1.0, "head_up": 1.0}


def _flat_feet(heel_l=0.0, heel_r=0.0, z=0.0):
    return {"l": m.plant(_L_XY[0], _L_XY[1], heel=heel_l, yaw=9.0, z=z),
            "r": m.plant(_R_XY[0], _R_XY[1], heel=heel_r, yaw=-13.0, z=z)}


# The top of the push, feet just off the floor, arms carried up and out for balance.
JUMP_POSE = m.merge(STANCE, {
    "hip": (0.0, -0.01, 0.97), "hip_rot": (2.0, 0.0, -1.0), "chest_rot": (-1.0, 0.0, 1.0),
    "look": (0.0, -1.0, 0.02),
    "feet": _flat_feet(32.0, 36.0, 0.05),
    "hands": {"l": {"at": (0.5, -0.26, 1.58), "pole": (0.75, 0.35, -0.5)},
              "r": {"at": (-0.51, -0.23, 1.56), "pole": (-0.75, 0.35, -0.5)}},
})

JUMP_START = [
    STANCE,
    m.merge(STANCE, {  # the dip starts: hips sink, arms begin to go back
        "hip": (0.006, 0.065, 0.83), "hip_rot": (11.0, -1.0, -2.0), "chest_rot": (10.0, 1.0, 1.5),
        "look": (0.0, -1.0, -0.15),
        "hands": {"l": {"at": (0.28, 0.14, 0.94), "pole": (0.35, 0.7, -0.9)},
                  "r": {"at": (-0.29, 0.15, 0.95), "pole": (-0.35, 0.7, -0.9)}},
    }),
    m.merge(STANCE, {  # loaded: deep in the knees, chest over them, arms cocked behind
        "hip": (0.0, 0.13, 0.66), "hip_rot": (27.0, 0.0, -1.0), "chest_rot": (40.0, 1.0, 1.0),
        "look": (0.0, -1.0, -0.05),
        "feet": _flat_feet(),
        "hands": {"l": {"at": (0.29, 0.34, 1.02), "pole": (0.45, 0.6, -0.5)},
                  "r": {"at": (-0.3, 0.35, 1.02), "pole": (-0.45, 0.6, -0.5)}},
    }),
    m.merge(STANCE, {  # driving: hips rising, arms sweeping down past the thighs
        "hip": (0.0, 0.05, 0.8), "hip_rot": (13.0, 0.0, -1.0), "chest_rot": (19.0, 0.5, 1.0),
        "look": (0.0, -1.0, 0.02),
        "feet": _flat_feet(10.0, 12.0),
        "hands": {"l": {"at": (0.3, -0.08, 0.97), "pole": (0.5, 0.7, -0.7)},
                  "r": {"at": (-0.31, -0.08, 0.97), "pole": (-0.5, 0.7, -0.7)}},
    }),
    m.merge(STANCE, {  # take-off: last of the push through the balls of the feet
        "hip": (0.0, -0.015, 0.955), "hip_rot": (4.0, 0.0, -1.0), "chest_rot": (3.0, 0.0, 1.0),
        "look": (0.0, -1.0, 0.04),
        "feet": _flat_feet(42.0, 46.0),
        "hands": {"l": {"at": (0.32, -0.42, 1.18), "pole": (0.6, 0.55, -0.6)},
                  "r": {"at": (-0.33, -0.41, 1.16), "pole": (-0.6, 0.55, -0.6)}},
    }),
    m.merge(STANCE, {  # just off the floor, arms still going up
        "hip": (0.0, -0.012, 0.968), "hip_rot": (2.5, 0.0, -1.0), "chest_rot": (0.0, 0.0, 1.0),
        "look": (0.0, -1.0, 0.03),
        "feet": _flat_feet(36.0, 40.0, 0.03),
        "hands": {"l": {"at": (0.43, -0.36, 1.42), "pole": (0.7, 0.42, -0.55)},
                  "r": {"at": (-0.44, -0.34, 1.4), "pole": (-0.7, 0.42, -0.55)}},
    }),
    JUMP_POSE,
]


def jump_at(t):
    """Starts exactly on JUMP_POSE, gathers its knees within half a second, then
    drifts. Everything is a whole number of waves across the clip, so it closes."""
    u = 0.5 - 0.5 * math.cos(TAU * t)
    tuck = 1.0 - (1.0 - u) ** 4
    w1 = math.sin(TAU * t)
    w2 = math.sin(2.0 * TAU * t)
    w3 = math.sin(3.0 * TAU * t)

    def lerp(a, b):
        return a + (b - a) * tuck

    l_z = 0.05 + 0.11 * tuck + 0.012 * w2
    r_z = 0.05 + 0.17 * tuck - 0.012 * w2
    feet = {
        "l": m.plant(_L_XY[0] + 0.012 * tuck, _L_XY[1] - 0.05 * tuck + 0.015 * w1, heel=lerp(32.0, 16.0) + 3.0 * w3, yaw=9.0, z=l_z),
        "r": m.plant(_R_XY[0] - 0.008 * tuck, _R_XY[1] + 0.05 * tuck - 0.015 * w1, heel=lerp(36.0, 26.0) - 3.0 * w3, yaw=-13.0, z=r_z),
    }
    return m.merge(JUMP_POSE, {
        "hip": (0.006 * w1, -0.01 + 0.01 * tuck, 0.97 - 0.012 * tuck + 0.004 * w2),
        "hip_rot": (2.0 + 9.0 * tuck + 1.2 * w2, 1.5 * w1, -1.0 + 1.5 * w3),
        "chest_rot": (-1.0 + 7.0 * tuck - 1.5 * w2, -2.0 * w1, 1.0 - 2.0 * w3),
        "look": (0.04 * w1, -1.0, 0.02 - 0.13 * tuck + 0.012 * w2),
        "feet": feet,
        "hands": {
            "l": {"at": (lerp(0.5, 0.5) + 0.018 * w2, lerp(-0.26, -0.08) + 0.02 * w1, lerp(1.58, 1.2) + 0.03 * w3),
                  "pole": (lerp(0.75, 0.55), lerp(0.35, 0.4), lerp(-0.5, -0.8))},
            "r": {"at": (lerp(-0.51, -0.48) + 0.016 * w3, lerp(-0.23, -0.1) - 0.02 * w1, lerp(1.56, 1.25) - 0.03 * w2),
                  "pole": (lerp(-0.75, -0.55), lerp(0.35, 0.4), lerp(-0.5, -0.8))},
        },
    })


JUMP_LAND = [
    JUMP_POSE,
    m.merge(STANCE, {  # balls touch, legs starting to give, arms still high
        "hip": (0.0, 0.0, 0.925), "hip_rot": (7.0, 0.0, -1.0), "chest_rot": (5.0, 0.0, 1.0),
        "look": (0.0, -1.0, -0.02),
        "feet": _flat_feet(20.0, 24.0),
        "hands": {"l": {"at": (0.48, -0.25, 1.46), "pole": (0.72, 0.38, -0.55)},
                  "r": {"at": (-0.49, -0.22, 1.44), "pole": (-0.72, 0.38, -0.55)}},
    }),
    m.merge(STANCE, {  # heels down, hips falling fast, chest starting over
        "hip": (0.004, 0.06, 0.77), "hip_rot": (18.0, -1.0, -2.0), "chest_rot": (20.0, 1.0, 1.5),
        "look": (0.0, -1.0, -0.12),
        "feet": _flat_feet(),
        "hands": {"l": {"at": (0.38, -0.2, 1.14), "pole": (0.7, 0.45, -0.6)},
                  "r": {"at": (-0.39, -0.17, 1.12), "pole": (-0.7, 0.45, -0.6)}},
    }),
    m.merge(STANCE, {  # the bottom: deep in the knees, chest folded down, arms thrown down and out
        "hip": (0.01, 0.13, 0.565), "hip_rot": (30.0, -2.0, -3.0), "chest_rot": (46.0, 2.0, 2.0),
        "look": (0.0, -1.0, -0.22),
        "feet": {"l": m.plant(_L_XY[0], _L_XY[1], yaw=9.0), "r": m.plant(_R_XY[0], _R_XY[1], yaw=-13.0)},
        "hands": {"l": {"at": (0.38, -0.2, 1.03), "pole": (0.7, 0.6, -0.4), "curl": 0.25},
                  "r": {"at": (-0.38, -0.22, 1.04), "pole": (-0.7, 0.6, -0.4), "curl": 0.25}},
    }),
    m.merge(STANCE, {  # held in the knees, chest beginning to lift first
        "hip": (0.012, 0.125, 0.59), "hip_rot": (28.0, -2.0, -3.0), "chest_rot": (38.0, 2.0, 2.0),
        "look": (0.0, -1.0, -0.16),
        "hands": {"l": {"at": (0.36, -0.15, 1.0), "pole": (0.6, 0.6, -0.55), "curl": 0.28},
                  "r": {"at": (-0.37, -0.17, 1.01), "pole": (-0.6, 0.6, -0.55), "curl": 0.28}},
    }),
    m.merge(STANCE, {  # standing out of it, weight coming forward
        "hip": (0.012, 0.08, 0.77), "hip_rot": (16.0, -2.0, -2.5), "chest_rot": (17.0, 1.5, 1.5),
        "look": (0.0, -1.0, -0.08),
        "hands": {"l": {"at": (0.3, -0.04, 0.92)}, "r": {"at": (-0.31, -0.05, 0.93)}},
    }),
    m.merge(STANCE, {  # a touch past upright, then settles
        "hip": (0.012, 0.04, 0.888), "hip_rot": (6.0, -1.5, -2.0), "chest_rot": (2.0, 1.0, 1.5),
        "look": (0.0, -1.0, -0.02),
    }),
    STANCE,
]


CLIPS = {
    "Jog_Fwd": {"length": JOG_SEC, "loop": True, "at": jog_at},
    "Hit_Chest": shot(HIT_CHEST, [0, 2, 3.5, 5.5, 8], lag=_HIT_LAG, taper=3.0),
    "Death01": shot(DEATH, [0, 3, 8, 14, 20, 25, 31, 37, 44, 58], lag=_DEATH_LAG, taper=10.0),
    "Hit_Knockback": shot(KNOCKBACK, [0, 2, 5, 9, 13, 15, 18, 24], taper=4.0),
    "LayToIdle": shot(GET_UP, [0, 8, 18, 22.5, 27, 37, 46, 53, 58, 64], lag={"chest_rot": 1.2, "look": 2.0, "head_up": 2.0},
                      curve=m.spline, taper=6.0),
    "Jump_Start": shot(JUMP_START, [0, 4, 9.5, 11.5, 13.2, 15.5, 18], lag=_JUMP_LAG, curve=m.spline, taper=2.5,
                       moments={"impact": [13.2]}),
    "Jump": {"length": 2.5, "loop": True, "at": jump_at},
    "Jump_Land": shot(JUMP_LAND, [0, 1.5, 3.5, 6.5, 9.0, 14, 19, 24], lag=_JUMP_LAG, taper=3.0),
}
