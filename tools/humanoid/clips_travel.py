# Flying and ladders. No weapons in any of these.
#
# The ladder numbers are the game's (world/ladder.gd, tools/make_ladder_animations.gd):
# rungs lie 0.278677 apart in a plane 0.15 ahead of the unit's origin (RUNG_OFFSET).
# At the top the unit's origin stops OVER_RUNGS (3) rungs below the landing, and every
# rung, seen from there, is at a whole number of spacings. Rungs only go up to 2.
#
# Climb_Up climbs TWO rungs per cycle, one each way of the alternating gait: see RISE.
# The game plays it at climb_speed * length / rise, so the clip's "rise" is what it reads.
#
# Climb_Over_Top / Climb_On_Top are keyed where the body really goes, in the frame of the
# climb's stop (floor of the landing at LANDING), and then the unit's own path is taken off
# (root() below, the same straight legs Ladder.climb_waypoints walks at one speed).

import math

import motion as m

TAU = 2.0 * math.pi
STANCE = m.STANCE

# ---- Ladder geometry -------------------------------------------------------

RUNG = 0.278677
RUNG_Y = -0.15
RUNG_RADIUS = 0.018
LANDING = 3.0 * RUNG
OVER_REACH = 1.0
# Each limb goes up two rungs a cycle; the other side has gone up in between.
RISE = 2.0 * RUNG
# The share of a cycle a limb is on its rung.
GRIP = 0.62
# When each limb takes its rung (0-1 through the cycle). Opposite hand and foot go together, the
# hand a little ahead. Whole-rung heights fall out of these (see top_of).
FOOT_ON = {"l": 0.35, "r": 0.85}
HAND_ON = {"r": 0.31, "l": 0.81}
HIP_Z = 0.865
HIP_Y = 0.2
SHOULDER_Z = HIP_Z + 0.53


def top_of(on, near):
    """The height a rung is at when a limb takes it at phase `on`: the rungs
    stand at (k - 2p) spacings, so the whole-number k nearest `near`."""
    k = round(near / RUNG + 2.0 * on)
    return RUNG * (k - 2.0 * on)


FOOT_TOP = {s: top_of(FOOT_ON[s], 0.37) for s in "lr"}
HAND_TOP = {s: top_of(HAND_ON[s], 1.78) for s in "lr"}
SIDE = {"l": 1.0, "r": -1.0}


def _hermite(a, b, m0, m1, u):
    return ((2 * u ** 3 - 3 * u ** 2 + 1) * a + (u ** 3 - 2 * u ** 2 + u) * m0
            + (3 * u ** 2 - 2 * u ** 3) * b + (u ** 3 - u ** 2) * m1)


def limb_stroke(on, top, p):
    """A hand or foot's height at p, how far through its reach it is (0 on the
    rung), and where it is in the cycle. On the rung it goes down with the rung at
    exactly the rungs' speed, and comes off and lands at that speed too, so there is no stall."""
    u = (p - on) % 1.0
    if u < GRIP:
        return top - RISE * u, 0.0, u
    s = (u - GRIP) / (1.0 - GRIP)
    slope = -RISE * (1.0 - GRIP)
    return _hermite(top - RISE * GRIP, top, slope, slope, s), s, u


def hand_pose(side, p):
    """Grips over the rung: the rung lies across the palm, the wrist behind and below
    it, the fingers along the forearm so the wrist is neutral."""
    s = SIDE[side]
    z, reach, _ = limb_stroke(HAND_ON[side], HAND_TOP[side], p)
    lift = math.sin(math.pi * reach) ** 2
    # How far the forearm leans out of vertical: more as the hand comes down to the chest.
    up = max(0.0, min(1.0, (z - SHOULDER_Z) / 0.42))
    lean = math.radians(52.0 - 36.0 * up)
    point = (-s * 0.16, -math.sin(lean), math.cos(lean))
    palm = (0.0, -math.cos(lean), -math.sin(lean))
    # Off the rung the hand comes back toward the body and opens.
    grip_y = RUNG_Y + 0.1 * lift
    at = (s * 0.2 - point[0] * 0.085,
          grip_y - point[1] * 0.085 - palm[1] * 0.035,
          z - point[2] * 0.085 - palm[2] * 0.035)
    return {"at": at, "point": point, "palm": palm,
            "pole": (s * 0.75, 0.45, -0.75), "curl": 0.86 - 0.6 * lift, "thumb": 0.6 - 0.35 * lift}


def foot_pose(side, p):
    """On the ball of the foot, on the rung. Off it the foot drops back clear of the rungs,
    toes down, and comes in over the next one."""
    s = SIDE[side]
    z, reach, u = limb_stroke(FOOT_ON[side], FOOT_TOP[side], p)
    lift = math.sin(math.pi * reach) ** 2
    heel = m.cycle([-4.0, 10.0, 24.0, 34.0, 8.0], [0.0, 0.3, 0.62, 0.8, 0.96], u)
    foot = m.plant(s * 0.125, RUNG_Y + 0.14 * lift, heel=heel, yaw=s * 7.0, z=z + RUNG_RADIUS)
    foot["toe"] = max(0.0, heel) * 0.5
    foot["pole"] = (s * 0.95, -0.7, 0.2)
    return foot


def climb_at(p):
    """Rungs go down past a still body. Hips go toward the rising knee, the opposite
    shoulder comes up and forward with the reaching hand."""
    # 1 while the left foot is coming up, -1 for the right.
    side = math.cos(TAU * (p - 0.16))
    # The legs push twice a cycle; each drive starts as a foot takes its rung.
    drive = math.cos(TAU * 2.0 * (p - 0.63))
    return {
        "hip": (0.03 * side, HIP_Y - 0.012 * drive, HIP_Z + 0.016 * drive),
        "hip_rot": (9.0 - 1.5 * drive, -2.5 * side, -4.0 * side),
        "chest_rot": (7.0 + 2.0 * drive, 3.5 * side, 5.0 * side),
        "look": (0.1 * math.cos(TAU * (p - 0.05)), -1.0, 0.32 + 0.04 * drive),
        "hands": {s: hand_pose(s, p) for s in "lr"},
        "feet": {s: foot_pose(s, p) for s in "lr"},
    }


CLIMB_START = climb_at(0.0)

# ---- Climb over: helpers ----------------------------------------------------

BODY = ("hip", "hip_rot", "chest_rot", "look")


def _track(keys, frames, part, side):
    """One limb's own keys: a key that leaves it None doesn't stop it there."""
    held = [(f, k[part][side]) for f, k in zip(frames, keys) if k[part][side] is not None]
    return [c for _, c in held], [f for f, _ in held]


def _carried(limbs, times, f):
    """A limb moved along the ground is picked up and set down, not dragged."""
    pose = m.between(limbs, times, f, None, m.once)
    if f <= times[0] or f >= times[-1]:
        return pose
    i = max(n for n, x in enumerate(times) if x <= f)
    a, b = limbs[i]["at"], limbs[i + 1]["at"]
    apart = math.hypot(a[0] - b[0], a[1] - b[1])
    # Only along the ground: a foot already up over the lip is carried by its own keys.
    if apart > 0.1 and abs(a[2] - b[2]) < 0.1:
        u = (f - times[i]) / (times[i + 1] - times[i])
        x, y, z = pose["at"]
        pose = dict(pose, at=(x, y, z + min(0.1, 0.25 * apart) * math.sin(math.pi * u)))
    return pose


def _kept_above_floor(foot):
    """A foot between two ground poses, lifted just enough that its ball stays on the floor."""
    pitch, roll, yaw = foot["rot"]
    lowest = m.plant(0.0, 0.0, heel=pitch, yaw=yaw, roll=roll)["at"][2]
    x, y, z = foot["at"]
    return dict(foot, at=(x, y, max(z, lowest)))


def flow(keys, frames, grounded=False, **extra):
    """The trunk runs through its keys without stopping; hands and feet hold where they are put."""
    count = frames[-1]
    bodies = [{k: p[k] for k in BODY} for p in keys]
    tracks = {(part, s): _track(keys, frames, part, s) for part in ("hands", "feet") for s in "lr"}

    def at(t):
        f = t * count
        pose = m.between(bodies, frames, f, m.BODY_LAG, m.spline)
        for part in ("hands", "feet"):
            pose[part] = {s: _carried(*tracks[(part, s)], f) for s in "lr"}
        if grounded:
            pose["feet"] = {s: _kept_above_floor(c) for s, c in pose["feet"].items()}
        return pose

    clip = {"length": count / m.FPS, "at": at}
    clip.update(extra)
    return clip



def root(along):
    """Where the game has the unit, 0-1 along stop -> elbow -> off, at one speed."""
    d = along * (LANDING + OVER_REACH)
    return (0.0, -max(d - LANDING, 0.0), min(d, LANDING))


def _minus(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def in_place(clip, off):
    """The clip as the game plays it: the unit's own path taken off, so the body lands where it is keyed."""
    inner = clip["at"]

    def at(t):
        pose = inner(t)
        r = root(t if off else 1.0 - t)
        pose["hip"] = _minus(pose["hip"], r)
        for part in ("hands", "feet"):
            pose[part] = {s: dict(c, at=_minus(c["at"], r)) for s, c in pose[part].items()}
        return pose

    return dict(clip, at=at)


# STANCE's hands, solved and written out in the world, so a key can be a hand in the same form as
# the rest of the clip and still finish exactly on STANCE. Measured from the rig (rig.solve(STANCE)).
STAND_HANDS = {
    "l": {"at": (0.2477, 0.0033, 0.8773), "point": (0.0567, -0.2426, -0.9685), "palm": (-0.986, 0.1389, -0.0925),
          "pole": (0.2109, 0.8571, -0.961), "curl": 0.32, "thumb": 0.25},
    "r": {"at": (-0.2573, 0.0048, 0.8919), "point": (-0.0849, -0.2578, -0.9625), "palm": (0.9741, 0.1815, -0.1346),
          "pole": (-0.2889, 0.844, -0.9523), "curl": 0.36, "thumb": 0.25},
}


def _shift(v, by):
    return (v[0] + by[0], v[1] + by[1], v[2] + by[2])


STAND_AT = root(1.0)


def foot_key(side, foot):
    """A foot in the same form as the climb's."""
    return dict(foot, pole=(SIDE[side] * 0.5, -1.0, 0.0))


def stand_key():
    """Standing on the landing, off the edge: exactly STANCE at the far end of the unit's path."""
    return {
        "hip": _shift(STANCE["hip"], STAND_AT), "hip_rot": STANCE["hip_rot"],
        "chest_rot": STANCE["chest_rot"], "look": STANCE["look"],
        "hands": {s: dict(STAND_HANDS[s], at=_shift(STAND_HANDS[s]["at"], STAND_AT)) for s in "lr"},
        "feet": {s: foot_key(s, dict(STANCE["feet"][s], at=_shift(STANCE["feet"][s]["at"], STAND_AT))) for s in "lr"},
    }


def flat(side, y, lift=0.0):
    """Palm flat on the landing, fingers forward and a little out."""
    s = SIDE[side]
    return {"at": (s * 0.22, y, LANDING + 0.05 + lift), "point": (s * 0.22, -1.0, -0.12 if lift else 0.0),
            "palm": (0.0, -0.08 if lift else 0.0, -1.0), "pole": (s * 1.0, 0.25, -0.35), "curl": 0.12, "thumb": 0.2}


def on_rung(side, k, heel=0.0):
    s = SIDE[side]
    foot = m.plant(s * 0.125, RUNG_Y, heel=heel, yaw=s * 7.0, z=k * RUNG + RUNG_RADIUS)
    foot["toe"] = max(0.0, heel) * 0.5
    return dict(foot, pole=(s * 0.95, -0.7, 0.2))


STAND = stand_key()
# Where STANCE's feet are on the landing.
L_STAND = STAND["feet"]["l"]
R_STAND = STAND["feet"]["r"]


def key(hip, hip_rot, chest_rot, look, hands, feet):
    return {"hip": hip, "hip_rot": hip_rot, "chest_rot": chest_rot, "look": look, "hands": hands, "feet": feet}


# The kneeling right leg: the knee on the landing ahead of the hips, toes tucked at the lip.
KNEEL_R = foot_key("r", dict(m.plant(-0.1, -0.21, heel=80.0, z=LANDING), toe=36.0))
KNEEL_R["pole"] = (-0.25, -1.0, -0.35)
# The right foot off its rung, drawn up behind the lip while the knee goes forward onto it.
R_DRAWN = foot_key("r", dict(m.plant(-0.1, -0.05, heel=50.0, z=0.72), toe=20.0))
# The left foot up over the lip, toes clear of it.
L_OVER = foot_key("l", dict(m.plant(0.18, -0.24, heel=34.0, yaw=10.0, z=LANDING + 0.06), toe=12.0))
# The toes feeling down for the top rung from just behind it.
L_HUNT = foot_key("l", dict(m.plant(0.15, RUNG_Y + 0.07, heel=36.0, yaw=8.0, z=2.0 * RUNG + 0.12), toe=12.0))
L_OVER["pole"] = (0.3, -1.0, 0.35)
# The left foot on its final spot with the knee up in front: the lunge.
L_LUNGE = dict(L_STAND, pole=(0.25, -0.7, 0.9))


def on_knee(side, y, z):
    """A hand pressing down on the front of the thigh, to push up from a lunge."""
    s = SIDE[side]
    return {"at": (s * 0.15, y, z), "point": (s * 0.1, -0.62, -0.78), "palm": (0.0, 0.78, -0.62),
            "pole": (s * 1.0, 0.25, -0.35), "curl": 0.3, "thumb": 0.3}


L_LUNGE_Z = LANDING + 0.62

OVER_KEYS = [
    CLIMB_START,
    key((0.0, 0.13, 0.9), (11.0, 0.0, 0.0), (18.0, 1.0, 0.0), (0.0, -1.0, -0.1),  # hands off the rungs, up and over the lip
        {"l": flat("l", -0.3, 0.2), "r": flat("r", -0.32, 0.24)},
        {"l": on_rung("l", 1), "r": on_rung("r", 1)}),
    key((0.0, 0.0, 0.9), (20.0, 0.0, 0.0), (38.0, 0.0, 0.0), (0.0, -1.0, -0.42),  # palms down on the landing, chest comes over the edge
        {"l": flat("l", -0.46), "r": flat("r", -0.46)},
        {"l": on_rung("l", 1), "r": on_rung("r", 1)}),
    key((-0.02, -0.04, 1.12), (44.0, -1.0, 2.0), (72.0, 0.0, -2.0), (0.0, -1.0, -0.55),  # arms press, right foot a rung up, hips rise toward the hands
        {"l": flat("l", -0.46), "r": flat("r", -0.46)},
        {"l": on_rung("l", 1), "r": on_rung("r", 2, heel=6.0)}),
    key((-0.03, -0.16, 1.206), (56.0, -2.0, 3.0), (90.0, 0.0, 0.0), (0.0, -1.0, -0.6),  # right knee goes forward over the lip, left hand walks on, left foot up to the top rung
        {"l": flat("l", -0.88), "r": flat("r", -0.46)},
        {"l": on_rung("l", 2, heel=12.0), "r": R_DRAWN}),
    key((-0.03, -0.42, LANDING + 0.42), (58.0, -3.0, 4.0), (96.0, 0.0, 2.0), (0.0, -1.0, -0.5),  # the knee is down, the trunk flat over it like a crawl, right hand follows
        {"l": flat("l", -0.88), "r": flat("r", -0.95)},
        {"l": on_rung("l", 2, heel=18.0), "r": KNEEL_R}),
    key((0.0, -0.48, LANDING + 0.44), (58.0, 2.0, -3.0), (94.0, 1.0, -3.0), (0.02, -1.0, -0.4),  # weight rolls onto the knee and hands, left foot comes up over the lip
        {"l": flat("l", -0.88), "r": flat("r", -0.95)},
        {"l": L_OVER, "r": KNEEL_R}),
    key((0.02, -0.66, LANDING + 0.42), (30.0, 2.0, -2.0), (44.0, 1.0, -2.0), (0.0, -1.0, -0.2),  # left foot set down well ahead, a lunge: left hand on the thigh, right hand off the floor
        {"l": on_knee("l", -1.08, L_LUNGE_Z), "r": flat("r", -1.0, 0.34)},
        {"l": L_LUNGE, "r": KNEEL_R}),
    key((0.03, -0.88, LANDING + 0.72), (12.0, 0.0, -2.0), (14.0, 1.0, 1.0), (0.0, -1.0, -0.08),  # drives up over the left leg, the right foot swinging through
        {"l": None, "r": None},
        {"l": None, "r": None}),
    STAND,
]
OVER_FRAMES = [0.0, 5.0, 11.0, 19.0, 26.0, 32.0, 36.0, 44.0, 50.5, 57.6]

ON_KEYS = [
    STAND,
    key((0.03, -0.92, LANDING + 0.8), (10.0, 1.0, -2.0), (10.0, 1.0, 0.0), (0.0, -1.0, -0.1),  # weight over the left foot, the right heel coming up to step back
        {"l": None, "r": None},
        {"l": None, "r": None}),
    key((0.02, -0.72, LANDING + 0.46), (30.0, 2.0, -2.0), (46.0, 1.0, -2.0), (0.0, -1.0, -0.3),  # sinks into a lunge, right knee goes down behind, left hand braces on the thigh
        {"l": on_knee("l", -1.08, L_LUNGE_Z), "r": flat("r", -1.0, 0.44)},
        {"l": L_LUNGE, "r": KNEEL_R}),
    key((0.0, -0.5, LANDING + 0.44), (58.0, 2.0, -2.0), (94.0, 1.0, -2.0), (0.0, -1.0, -0.5),  # both palms down, the weight goes onto the arms
        {"l": flat("l", -0.97), "r": flat("r", -0.97)},
        {"l": L_LUNGE, "r": KNEEL_R}),
    key((-0.03, -0.42, LANDING + 0.42), (58.0, -2.0, 3.0), (96.0, 0.0, 2.0), (-0.02, -1.0, -0.55),  # left foot lifts and comes back past the knee to the lip
        {"l": flat("l", -0.97), "r": flat("r", -0.97)},
        {"l": L_OVER, "r": KNEEL_R}),
    key((-0.03, -0.4, LANDING + 0.42), (58.0, -3.0, 4.0), (96.0, 0.0, 2.0), (0.0, -1.0, -0.72),  # over the lip, head down, the toes hunting for the top rung
        {"l": flat("l", -0.97), "r": flat("r", -0.97)},
        {"l": L_HUNT, "r": KNEEL_R}),
    key((-0.03, -0.16, 1.206), (56.0, -2.0, 3.0), (90.0, 0.0, 0.0), (0.0, -1.0, -0.6),  # left foot has the rung and takes the weight, right knee slides back off the lip
        {"l": flat("l", -0.88), "r": flat("r", -0.5)},
        {"l": on_rung("l", 2, heel=12.0), "r": R_DRAWN}),
    key((-0.02, -0.04, 1.12), (44.0, -1.0, 2.0), (72.0, 0.0, -2.0), (0.0, -1.0, -0.55),  # right foot reaches a rung down, the left hand walks back to the lip
        {"l": flat("l", -0.46), "r": flat("r", -0.5)},
        {"l": on_rung("l", 2, heel=8.0), "r": on_rung("r", 1)}),
    key((0.0, 0.0, 0.92), (20.0, 0.0, 0.0), (36.0, 0.0, 0.0), (0.0, -1.0, -0.42),  # lowered on bending arms, left foot down beside the right
        {"l": flat("l", -0.46), "r": flat("r", -0.5)},
        {"l": on_rung("l", 1), "r": on_rung("r", 1)}),
    key((0.0, 0.13, 0.9), (11.0, 0.0, 0.0), (16.0, 1.0, 0.0), (0.0, -1.0, -0.05),  # hands come off the lip and go up for the rungs
        {"l": flat("l", -0.3, 0.24), "r": flat("r", -0.32, 0.2)},
        {"l": on_rung("l", 1), "r": on_rung("r", 1)}),
    CLIMB_START,
]
ON_FRAMES = [0.0, 6.0, 13.0, 19.0, 27.0, 32.0, 37.0, 43.0, 47.5, 52.0, 57.6]

# ---- Flight ----------------------------------------------------------------


HOVER_Z = 1.24


def hover_at(t):
    """Hanging in the air: one slow rise and fall, the legs following it late, and the
    arms out a little, feeling for balance."""
    bob = math.sin(TAU * t)
    late = math.sin(TAU * (t - 0.09))
    sway = math.sin(TAU * (t + 0.2))
    drift = math.sin(TAU * (t + 0.55))
    return {
        "hip": (0.015 * sway, 0.02 * drift, HOVER_Z + 0.03 * bob + 0.005 * math.sin(TAU * (2.0 * t + 0.1))),
        "hip_rot": (4.0 + 1.4 * drift, -1.5 * sway, 1.2 * math.sin(TAU * (t + 0.4))),
        "chest_rot": (2.0 + 1.6 * math.sin(TAU * (t + 0.67)), 1.2 * math.sin(TAU * (t + 0.3)), -2.0 * math.sin(TAU * (t + 0.5))),
        "look": (0.06 * math.sin(TAU * (t + 0.3)), -1.0, -0.04 + 0.02 * drift),
        "feet": {
            "l": {"at": (0.125 + 0.012 * sway, -0.05 + 0.02 * drift, HOVER_Z - 0.69 + 0.025 * late), "rot": (34.0 + 3.0 * late, 1.0, 8.0), "toe": 6.0, "pole": (0.3, -1.0, 0.1)},
            "r": {"at": (-0.135 + 0.012 * sway, 0.11 + 0.02 * drift, HOVER_Z - 0.75 + 0.022 * math.sin(TAU * (t - 0.14))), "rot": (28.0 + 3.0 * late, -1.0, -10.0), "toe": 8.0, "pole": (-0.3, -1.0, 0.1)},
        },
        "hands": {
            "l": {"at": (0.33 + 0.012 * late, -0.04 + 0.02 * drift, 0.985 + 0.018 * math.sin(TAU * (t + 0.08))), "space": "chest", "pole": (0.4, 0.8, -0.9), "curl": 0.34, "thumb": 0.25},
            "r": {"at": (-0.34 - 0.01 * late, -0.02 + 0.02 * drift, 0.965 + 0.018 * math.sin(TAU * (t - 0.05))), "space": "chest", "pole": (-0.4, 0.8, -0.9), "curl": 0.38, "thumb": 0.25},
        },
    }


def fly_at(t):
    """A gentle forward drift, close to the hover: the body leans in, the legs trail and
    flutter, the arms hang back a little and steer."""
    flap = math.sin(TAU * t)
    late = math.sin(TAU * (t - 0.12))
    weave = math.sin(TAU * (t + 0.25))
    height = 1.18
    return {
        "hip": (0.012 * weave, 0.03 + 0.01 * late, height + 0.018 * flap),
        "hip_rot": (17.0 + 2.0 * late, -1.5 * weave, -1.5 * flap),
        "chest_rot": (27.0 + 2.5 * flap, 2.0 * weave, 2.0 * flap),
        "look": (0.04 * weave, -1.0, -0.04 + 0.03 * flap),
        "feet": {
            "l": {"at": (0.11 + 0.01 * weave, 0.25 + 0.03 * late, height - 0.69 + 0.04 * late), "rot": (62.0 + 5.0 * late, 0.0, 7.0), "toe": 4.0, "pole": (0.28, -1.0, -0.3)},
            "r": {"at": (-0.125 + 0.01 * weave, 0.36 - 0.03 * late, height - 0.67 - 0.04 * late), "rot": (72.0 - 5.0 * late, 0.0, -9.0), "toe": 4.0, "pole": (-0.28, -1.0, -0.3)},
        },
        "hands": {
            "l": {"at": (0.32 + 0.02 * weave, 0.08 - 0.015 * flap, 0.945 + 0.015 * flap), "space": "chest", "pole": (0.5, 0.85, -0.5), "curl": 0.3, "thumb": 0.22},
            "r": {"at": (-0.325 + 0.02 * weave, 0.09 + 0.015 * flap, 0.94 - 0.015 * flap), "space": "chest", "pole": (-0.5, 0.85, -0.5), "curl": 0.32, "thumb": 0.22},
        },
    }


HOVER0 = hover_at(0.0)


def stance_hand(side, at, pole=None, curl=None):
    h = dict(STANCE["hands"][side], at=at)
    if pole:
        h["pole"] = pole
    if curl is not None:
        h["curl"] = curl
    return h


def stance_foot(side, heel=0.0, up=0.0):
    f = STANCE["feet"][side]
    base = {"l": (0.118, -0.165, 9.0), "r": (-0.128, -0.085, -13.0)}[side]
    return m.plant(base[0], base[1], heel=heel, yaw=base[2], z=up) if heel or up else dict(f)


def air_foot(side, x, y, z, pitch, toe):
    return {"at": (x, y, z), "rot": (pitch, SIDE[side], SIDE[side] * 9.0), "toe": toe, "pole": (SIDE[side] * 0.3, -1.0, 0.1)}


def planted(side, heel=0.0):
    """STANCE's foot with the knee hint the airborne keys use, so the knee doesn't swing between them."""
    return dict(stance_foot(side, heel=heel), pole=(SIDE[side] * 0.3, -1.0, 0.1))


TAKEOFF = [
    m.merge(STANCE, {"feet": {"l": planted("l"), "r": planted("r")}}),
    m.merge(STANCE, {  # gathers: hips drop and sit back, arms drawn behind
        "hip": (0.012, 0.075, 0.79), "hip_rot": (15.0, -1.0, -2.0), "chest_rot": (21.0, 1.0, 1.0), "look": (0.0, -1.0, -0.2),
        "feet": {"l": planted("l"), "r": planted("r")},
        "hands": {"l": stance_hand("l", (0.29, 0.13, 0.9), (0.4, 0.9, -0.6)), "r": stance_hand("r", (-0.29, 0.14, 0.9), (-0.4, 0.9, -0.6))},
    }),
    m.merge(STANCE, {  # the push: legs drive, heels up, chest opens, arms sweep out and up
        "hip": (0.01, 0.01, 0.985), "hip_rot": (1.0, 0.0, -1.0), "chest_rot": (-5.0, 0.5, 1.0), "look": (0.0, -1.0, 0.12),
        "feet": {"l": planted("l", heel=38.0), "r": planted("r", heel=38.0)},
        "hands": {"l": stance_hand("l", (0.4, -0.02, 1.06), (0.5, 0.8, -0.7), 0.2), "r": stance_hand("r", (-0.4, -0.02, 1.05), (-0.5, 0.8, -0.7), 0.22)},
    }),
    m.merge(HOVER0, {  # off the floor and carried past where it will hang, toes trailing
        "hip": (0.005, 0.015, HOVER_Z + 0.08), "hip_rot": (2.0, 0.0, 0.0), "chest_rot": (-4.0, 0.5, 0.5), "look": (0.0, -1.0, 0.08),
        "feet": {"l": air_foot("l", 0.125, -0.1, 0.5, 46.0, 2.0), "r": air_foot("r", -0.13, -0.02, 0.47, 42.0, 2.0)},
        "hands": {"l": {"at": (0.38, -0.03, 1.07), "curl": 0.25}, "r": {"at": (-0.39, -0.02, 1.06), "curl": 0.28}},
    }),
    HOVER0,
]

LAND = [
    HOVER0,
    m.merge(HOVER0, {  # coming down, feet reach for the floor toes first, arms lifting to balance
        "hip": (0.01, 0.025, 1.0), "hip_rot": (6.0, -0.5, -1.0), "chest_rot": (5.0, 0.5, 1.0), "look": (0.0, -1.0, -0.18),
        "feet": {"l": air_foot("l", 0.118, -0.14, 0.2, 30.0, 14.0), "r": air_foot("r", -0.128, -0.06, 0.17, 24.0, 12.0)},
        "hands": {"l": {"at": (0.37, -0.03, 1.05), "curl": 0.25}, "r": {"at": (-0.38, -0.02, 1.04), "curl": 0.28}},
    }),
    m.merge(STANCE, {  # toes touch; the heels still high and the knees starting to give
        "hip": (0.012, 0.03, 0.925), "hip_rot": (9.0, -1.0, -1.5), "chest_rot": (10.0, 1.0, 1.5), "look": (0.0, -1.0, -0.14),
        "feet": {"l": planted("l", heel=22.0), "r": planted("r", heel=26.0)},
        "hands": {"l": stance_hand("l", (0.34, 0.0, 1.0), (0.45, 0.85, -0.8)), "r": stance_hand("r", (-0.35, 0.01, 0.99), (-0.45, 0.85, -0.8))},
    }),
    m.merge(STANCE, {  # the bottom of it: heels down, hips sunk, chest over the knees, arms dropping
        "hip": (0.012, 0.065, 0.8), "hip_rot": (17.0, -1.0, -2.0), "chest_rot": (22.0, 1.0, 1.0), "look": (0.0, -1.0, -0.2),
        "feet": {"l": planted("l"), "r": planted("r")},
        "hands": {"l": stance_hand("l", (0.28, 0.06, 0.93), (0.35, 0.85, -0.9)), "r": stance_hand("r", (-0.285, 0.07, 0.93), (-0.35, 0.85, -0.9))},
    }),
    m.merge(STANCE, {"feet": {"l": planted("l"), "r": planted("r")}}),
]

CLIPS = {
    "Hover": {"length": 3.0, "loop": True, "at": hover_at},
    "Fly_Fwd": {"length": 1.6, "loop": True, "at": fly_at},
    "Takeoff": flow(TAKEOFF, [0.0, 6.0, 10.0, 14.0, 19.2], grounded=True),
    "Land": flow(LAND, [0.0, 6.0, 9.0, 12.0, 16.8], grounded=True),
    "Climb_Up": {"length": 1.367, "loop": True, "at": climb_at, "rise": RISE},
    "Climb_Over_Top": in_place(flow(OVER_KEYS, OVER_FRAMES), True),
    "Climb_On_Top": in_place(flow(ON_KEYS, ON_FRAMES), False),
}
