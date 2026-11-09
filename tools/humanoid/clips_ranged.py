# Ranged: a breathing stance per weapon, its shot, its reload, and the axe throw.
#
# Guns are posed by the right hand. The support hand is worked out from the
# gun every frame while its "glue" is 1, so it never drifts off the forestock.
# Recoil is added on top of the keyed poses as a function of time: it reaches
# the gun first, then the chest, then the hips, then the head.

import math

import motion as m

STANCE = m.STANCE
FPS = m.FPS
TAU = 2.0 * math.pi

PISTOL = {"r": "pistol"}
RIFLE = {"r": "rifle"}
CROSSBOW = {"r": "crossbow"}
LONGBOW = {"l": "longbow"}
AXE = {"r": "throwing_axe"}

# Where the support hand closes on each two-hander, along the muzzle and up.
RIFLE_GRIP = (0.3, 0.1)
CROSSBOW_GRIP = (0.19, 0.015)


# Small vector sums on tuples.
def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def scale(a, k):
    return tuple(x * k for x in a)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def unit(a):
    return scale(a, 1.0 / math.sqrt(dot(a, a)))


def lerp(a, b, k):
    return add(scale(a, 1.0 - k), scale(b, k))


def gun_axes(r):
    """Muzzle, top and the gun's own left, square to each other."""
    aim = unit(r["aim"])
    side = unit(cross(r["up"], aim))
    return aim, cross(aim, side), side


def on_gun(r, along, over, across=0.0, point=(0.72, 0.3, -0.45), palm=(-0.1, 0.9, 0.4), grip=0.085, off=0.035):
    """The support hand's wrist, fingers and palm for a spot on the gun.
    point and palm are given as (muzzle, top, left) of the gun."""
    aim, up, side = gun_axes(r)
    spot = add(add(add(r["at"], scale(aim, along)), scale(up, over)), scale(side, across))
    fingers = unit(add(add(scale(aim, point[0]), scale(up, point[1])), scale(side, point[2])))
    face = add(add(scale(aim, palm[0]), scale(up, palm[1])), scale(side, palm[2]))
    face = unit(add(face, scale(fingers, -dot(face, fingers))))
    wrist = add(add(spot, scale(fingers, -grip)), scale(face, -off))
    return wrist, fingers, face


def support(r, spot, pole, glue=1.0, curl=0.82, thumb=0.75):
    wrist, fingers, face = on_gun(r, spot[0], spot[1])
    return {"at": wrist, "point": fingers, "palm": face, "pole": pole, "curl": curl, "thumb": thumb, "glue": glue}


def glued(pose, spot):
    """Puts the support hand back on the gun, as far as its glue says."""
    if spot is None:
        return pose
    l = pose["hands"]["l"]
    g = min(1.0, max(0.0, l.get("glue", 0.0)))
    if g > 0.0:
        wrist, fingers, face = on_gun(pose["hands"]["r"], spot[0], spot[1])
        l["at"] = lerp(l["at"], wrist, g)
        l["point"] = lerp(l["point"], fingers, g)
        l["palm"] = lerp(l["palm"], face, g)
    return pose


def breathing(base, breaths, spot=None, chest=1.0, hand=0.004):
    """A loop around base that equals base exactly at t = 0."""
    def wave(t, k, phase):
        return math.sin(TAU * (t * k + phase)) - math.sin(TAU * phase)

    def at(t):
        b = wave(t, breaths, 0.0)
        sway = wave(t, 1, 0.13)
        drift = wave(t, 1, 0.41)
        fidget = wave(t, 2, 0.27)
        p = m.merge(base, {})
        p["hip"] = add(p["hip"], (0.007 * sway, 0.003 * drift, -0.0025 * b + 0.0015 * fidget))
        p["hip_rot"] = add(p["hip_rot"], (0.4 * fidget, -0.8 * sway, 0.6 * drift))
        p["chest_rot"] = add(p["chest_rot"], (-1.0 * chest * b + 0.3 * fidget, 0.5 * sway, -0.8 * drift))
        p["look"] = add(p["look"], (0.03 * drift, 0.0, 0.008 * fidget))
        for side in "lr":
            c = p["hands"][side]
            if side == "r" or spot is None:
                k = 1.0 if side == "r" or "aim" in c else 0.6
                c["at"] = add(c["at"], scale((0.25 * sway, 0.35 * drift, 0.9 * b + 0.3 * fidget), hand * k))
        return glued(p, spot)

    return at


def impulse(x, rise, decay):
    """A hit: up in `rise` frames, then a damped fall that dips once past rest."""
    if x <= 0.0:
        return 0.0
    if x < rise:
        return m.smooth(x / rise)
    y = (x - rise) / decay
    return math.exp(-y) * math.cos(1.1 * y)


def kick_gun(p, amount, muzzle, back, lift):
    """Turn the muzzle up by `muzzle` degrees and shove the grip back and up."""
    r = p["hands"]["r"]
    aim, up, side = gun_axes(r)
    a = math.radians(muzzle * amount)
    r["aim"] = add(scale(aim, math.cos(a)), scale(up, math.sin(a)))
    r["up"] = add(scale(up, math.cos(a)), scale(aim, -math.sin(a)))
    r["at"] = add(add(r["at"], scale(aim, -back * amount)), scale(up, lift * amount))


def kick_body(p, chest, hip, head):
    """chest (pitch back, turn right), hip (metres back, pitch back, drop), head (lift)."""
    p["chest_rot"] = add(p["chest_rot"], (-chest[0], 0.0, -chest[1]))
    p["hip"] = add(p["hip"], (0.0, hip[0], -hip[2]))
    p["hip_rot"] = add(p["hip_rot"], (-hip[1], 0.0, -hip[1] * 0.5))
    p["look"] = add(p["look"], (0.0, 0.0, head))


def recoil(shots, rise, decay, muzzle, back, lift, chest, hip, head):
    """Each shot in `shots` travels hand, shoulder, hips, head, a frame or so apart."""
    def layer(p, f):
        hand = sum(impulse(f - s, rise, decay) for s in shots)
        ribs = sum(impulse(f - s - 1.0, rise * 1.5, decay * 1.5) for s in shots)
        hips = sum(impulse(f - s - 2.0, rise * 2.0, decay * 2.0) for s in shots)
        face = sum(impulse(f - s - 2.5, rise * 2.0, decay * 1.6) for s in shots)
        kick_gun(p, hand, muzzle, back, lift)
        # The grip rides the shoulder that is being pushed back.
        p["hands"]["r"]["at"] = add(p["hands"]["r"]["at"], (0.0, hip[0] * hips, 0.0))
        kick_body(p, scale(chest, ribs), scale(hip, hips), head * face)

    return layer


def clip(keys, frames, weapons, moments=None, layer=None, spot=None, curve=m.once, lag=None):
    count = frames[-1]
    lag = m.BODY_LAG if lag is None else lag

    def at(t):
        f = t * count
        p = m.between(keys, frames, f, lag, curve)
        if layer:
            layer(p, f)
        return glued(p, spot)

    out = {"length": count / FPS, "at": at, "weapons": weapons}
    if moments:
        out["moments"] = moments
    return out


# ---------------------------------------------------------------- pistol

# Duellist's stance: right foot leads, right shoulder a little forward, weight
# on the back leg, the gun carried low in front of the thigh, barrel down.
PISTOL_POSE = {
    "hip": (0.012, 0.03, 0.885),
    "hip_rot": (6.0, -1.0, 12.0),
    "chest_rot": (5.0, 1.0, 14.0),
    "look": (-0.03, -1.0, -0.05),
    "head_up": (0.0, 0.0, 1.0),
    "feet": {"l": m.plant(0.16, -0.01, yaw=28.0), "r": m.plant(-0.12, -0.24, yaw=-6.0)},
    "hands": {
        "l": {"at": (0.3, 0.05, 0.96), "pole": (0.3, 0.8, -1.0), "curl": 0.34, "thumb": 0.25},
        "r": {"at": (-0.27, -0.25, 1.03), "aim": (-0.02, -0.86, -0.5), "up": (0.0, -0.5, 0.86),
              "pole": (-0.7, 0.6, -0.7), "curl": 0.9, "thumb": 0.75},
    },
}

pistol_breath = breathing(PISTOL_POSE, 1)


def pistol_key(**patch):
    return m.merge(PISTOL_POSE, patch)


# Arm up and locked, shoulder pushed at the target, head dropped to the sights.
PISTOL_AIM = pistol_key(
    hip=(0.0, -0.025, 0.868), hip_rot=(9.0, 0.0, 24.0), chest_rot=(9.0, -2.0, 36.0),
    look=(0.0, -1.0, -0.04), head_up=(-0.2, 0.0, 1.0),
    feet={"l": m.plant(0.16, -0.01, yaw=38.0, heel=4.0), "r": m.plant(-0.12, -0.24, yaw=2.0)},
    hands={"l": {"at": (0.32, 0.14, 1.02), "pole": (0.5, 0.6, -0.9), "curl": 0.42},
           "r": {"at": (-0.12, -0.835, 1.425), "aim": (0.0, -1.0, 0.0), "up": (0.0, 0.0, 1.0),
                 "pole": (-0.85, 0.2, -0.5), "curl": 0.92, "thumb": 0.85}},
)

PISTOL_SHOTS = [16.8, 26.4, 36.0]

PISTOL_SHOT = [
    PISTOL_POSE,
    pistol_key(  # gathers: hips sink and start to turn, the gun swings out on a low arc
        hip=(0.008, 0.015, 0.872), hip_rot=(7.0, -0.5, 18.0), chest_rot=(6.0, 0.0, 20.0),
        hands={"r": {"at": (-0.31, -0.46, 1.12), "aim": (-0.02, -0.95, -0.3), "up": (0.0, -0.3, 0.95),
                     "pole": (-0.8, 0.4, -0.6)}},
    ),
    m.merge(PISTOL_AIM, {  # swings up past the line: elbow straightening, barrel high
        "chest_rot": (6.0, -1.0, 33.0), "look": (0.0, -1.0, 0.0),
        "hands": {"r": {"at": (-0.15, -0.79, 1.47), "aim": (0.0, -0.97, 0.24), "up": (0.0, 0.24, 0.97)}},
    }),
    PISTOL_AIM,  # locked: arm, shoulder and eye on one line
    PISTOL_AIM,  # held through the three shots, recoil is laid on top
    m.merge(PISTOL_AIM, {  # the last kick dies away, still looking down the barrel
        "hands": {"r": {"at": (-0.13, -0.82, 1.415)}},
    }),
    pistol_key(  # elbow gives first, the barrel tips over
        hip=(0.006, 0.0, 0.875), hip_rot=(8.0, -0.5, 19.0), chest_rot=(7.0, 0.0, 26.0),
        look=(-0.02, -1.0, -0.05), head_up=(-0.05, 0.0, 1.0),
        hands={"l": {"at": (0.31, 0.1, 0.99)},
               "r": {"at": (-0.25, -0.5, 1.2), "aim": (-0.02, -0.96, -0.26), "up": (0.0, -0.26, 0.96),
                     "pole": (-0.8, 0.4, -0.6)}},
    ),
    PISTOL_POSE,
    PISTOL_POSE,
]
PISTOL_FRAMES = [0, 6, 11, 14, 38, 43, 49, 56, 59]


def pistol_hold(p, f):
    recoil(PISTOL_SHOTS, 1.2, 3.2, 15.0, 0.035, 0.012, (3.0, 3.5), (0.008, 1.2, 0.003), 0.035)(p, f)
    # The free hand answers the kick late, for balance.
    jolt = sum(impulse(f - s - 2.0, 2.5, 3.5) for s in PISTOL_SHOTS)
    p["hands"]["l"]["at"] = add(p["hands"]["l"]["at"], (0.006 * jolt, 0.012 * jolt, -0.004 * jolt))


# Magazine out with the left, new one from the belt, palm it home, rack the slide.
def pistol_reload_keys():
    def gun(at, aim, up):
        return {"at": at, "aim": aim, "up": up, "pole": (-0.7, 0.5, -0.7), "curl": 0.9, "thumb": 0.75}

    near = gun((-0.13, -0.33, 1.24), (0.34, -0.72, 0.6), (-0.42, 0.42, 0.8))  # brought in, tipped to the left hand
    return [
        PISTOL_POSE,
        pistol_key(  # gun comes in to the chest, tipped; head drops to it
            hip=(0.012, 0.025, 0.875), hip_rot=(8.0, -0.5, 8.0), chest_rot=(12.0, 0.0, 6.0),
            look=(0.08, -1.0, -0.42), head_up=(0.0, 0.0, 1.0),
            hands={"l": {"at": (0.08, -0.26, 1.08), "pole": (0.7, 0.5, -0.5), "curl": 0.55, "thumb": 0.5}, "r": near},
        ),
        pistol_key(  # the magazine drawn straight out of the grip
            hip=(0.012, 0.025, 0.872), hip_rot=(8.0, -0.5, 8.0), chest_rot=(13.0, 0.0, 5.0),
            look=(0.06, -1.0, -0.45),
            hands={"l": {"at": (0.1, -0.26, 1.0), "pole": (0.7, 0.5, -0.5), "curl": 0.8, "thumb": 0.8}, "r": near},
        ),
        pistol_key(  # hand down to the belt, chest dips and turns to it
            hip=(0.018, 0.03, 0.866), hip_rot=(9.0, -1.5, 6.0), chest_rot=(15.0, 3.0, 12.0),
            look=(0.12, -1.0, -0.4),
            hands={"l": {"at": (0.27, -0.04, 0.99), "pole": (0.6, 0.7, -0.6), "curl": 0.8, "thumb": 0.8}, "r": near},
        ),
        pistol_key(  # the new one comes up
            hip=(0.012, 0.025, 0.872), hip_rot=(8.0, -0.5, 8.0), chest_rot=(13.0, 0.0, 6.0),
            look=(0.06, -1.0, -0.45),
            hands={"l": {"at": (0.09, -0.28, 1.04), "pole": (0.7, 0.5, -0.6), "curl": 0.75, "thumb": 0.8}, "r": near},
        ),
        pistol_key(  # palmed home: the gun jumps to meet it
            hip=(0.012, 0.022, 0.868), hip_rot=(9.0, -0.5, 8.0), chest_rot=(14.0, 0.0, 6.0),
            look=(0.06, -1.0, -0.42),
            hands={"l": {"at": (0.04, -0.3, 1.13), "pole": (0.7, 0.4, -0.7), "curl": 0.3, "thumb": 0.4},
                   "r": gun((-0.12, -0.34, 1.27), (0.34, -0.72, 0.6), (-0.42, 0.42, 0.8))},
        ),
        pistol_key(  # left hand over the top, gripping the slide
            hip=(0.012, 0.022, 0.872), hip_rot=(8.0, -0.5, 10.0), chest_rot=(11.0, 0.0, 8.0),
            look=(0.02, -1.0, -0.32),
            hands={"l": {"at": (0.08, -0.37, 1.36), "pole": (0.8, 0.3, -0.5), "curl": 0.7, "thumb": 0.7},
                   "r": gun((-0.13, -0.3, 1.27), (0.2, -0.86, 0.46), (-0.36, 0.35, 0.86))},
        ),
        pistol_key(  # racked: the two hands tear apart, chest squares
            hip=(0.012, 0.02, 0.868), hip_rot=(9.0, -0.5, 10.0), chest_rot=(13.0, 0.0, 8.0),
            look=(0.02, -1.0, -0.3),
            hands={"l": {"at": (0.09, -0.24, 1.37), "pole": (0.8, 0.2, -0.5), "curl": 0.8, "thumb": 0.8},
                   "r": gun((-0.14, -0.4, 1.25), (0.2, -0.86, 0.46), (-0.36, 0.35, 0.86))},
        ),
        pistol_key(  # let go, the gun starts down
            hip=(0.012, 0.025, 0.878), hip_rot=(7.0, -1.0, 11.0), chest_rot=(7.0, 0.5, 12.0),
            look=(-0.02, -1.0, -0.12),
            hands={"l": {"at": (0.2, -0.14, 1.16), "pole": (0.65, 0.45, -0.7), "curl": 0.4, "thumb": 0.3},
                   "r": gun((-0.23, -0.34, 1.15), (0.05, -0.92, -0.2), (-0.1, -0.2, 0.96))},
        ),
        PISTOL_POSE,
        PISTOL_POSE,
    ]


PISTOL_RELOAD_FRAMES = [0, 7, 11, 16, 21, 24, 28, 31, 35, 38, 40]


# ---------------------------------------------------------------- rifle

RIFLE_LOW_R = {"at": (-0.24, -0.2, 1.07), "aim": (0.38, -0.85, -0.36), "up": (0.14, -0.33, 0.93),
               "pole": (-0.85, 0.45, -0.5), "curl": 0.9, "thumb": 0.8}

# Bladed, knees soft, stock under the arm, muzzle down and across the body.
RIFLE_POSE = {
    "hip": (0.01, 0.045, 0.872),
    "hip_rot": (7.0, -1.0, -18.0),
    "chest_rot": (10.0, 0.0, -24.0),
    "look": (0.05, -1.0, -0.07),
    "head_up": (0.0, 0.0, 1.0),
    "feet": {"l": m.plant(0.14, -0.25, yaw=4.0), "r": m.plant(-0.17, 0.08, yaw=-40.0, heel=4.0)},
    "hands": {
        "r": RIFLE_LOW_R,
        "l": support(RIFLE_LOW_R, RIFLE_GRIP, (0.4, 0.2, -1.0)),
    },
}

rifle_breath = breathing(RIFLE_POSE, 1, spot=RIFLE_GRIP)


def rifle_key(r=None, l=None, **patch):
    """A pose with the right hand replaced; the left stays on the forestock unless given."""
    hand_r = m.merge(RIFLE_LOW_R, r or {})
    hand_l = l if l is not None else support(hand_r, RIFLE_GRIP, (0.4, 0.2, -1.0))
    patch["hands"] = {"r": hand_r, "l": hand_l}
    return m.merge(RIFLE_POSE, patch)


# Stock in the pocket of the shoulder, cheek down on it, leaning into the gun.
RIFLE_AIM = rifle_key(
    r={"at": (-0.19, -0.31, 1.37), "aim": (0.0, -1.0, 0.0), "up": (0.0, 0.0, 1.0), "pole": (-1.0, 0.1, -0.3),
       "curl": 0.92, "thumb": 0.8},
    hip=(0.012, 0.0, 0.852), hip_rot=(11.0, -1.0, -28.0), chest_rot=(17.0, -5.0, -36.0),
    look=(0.0, -1.0, -0.02), head_up=(-0.3, 0.0, 1.0),
    feet={"l": m.plant(0.14, -0.25, yaw=-4.0), "r": m.plant(-0.17, 0.08, yaw=-50.0, heel=9.0)},
)

RIFLE_ROUNDS = [16.8 + 1.68 * i for i in range(10)]

RIFLE_BURST = [
    RIFLE_POSE,
    rifle_key(  # muzzle comes up first, hips sink under it
        r={"at": (-0.2, -0.3, 1.27), "aim": (0.2, -0.92, -0.32), "up": (0.1, -0.32, 0.94), "pole": (-0.95, 0.35, -0.3)},
        hip=(0.012, 0.03, 0.862), hip_rot=(9.0, -1.0, -22.0), chest_rot=(13.0, -2.0, -28.0),
        look=(0.03, -1.0, -0.05),
        feet={"r": m.plant(-0.17, 0.08, yaw=-44.0, heel=6.0)},
    ),
    m.merge(RIFLE_AIM, {  # stock arriving, chest still coming forward, head not there yet
        "chest_rot": (13.0, -3.0, -34.0), "head_up": (-0.12, 0.0, 1.0),
    }),
    RIFLE_AIM,  # set
    RIFLE_AIM,  # the burst, laid on top
    rifle_key(  # burst over: head stays down one beat, weight comes back on the feet
        r={"at": (-0.195, -0.305, 1.365), "aim": (0.0, -0.995, 0.03), "up": (0.0, 0.03, 0.995), "pole": (-1.0, 0.1, -0.3)},
        hip=(0.012, 0.012, 0.858), hip_rot=(10.0, -1.0, -27.0), chest_rot=(15.0, -4.0, -34.0),
        look=(0.0, -1.0, -0.02), head_up=(-0.25, 0.0, 1.0),
        feet={"l": m.plant(0.14, -0.25, yaw=-4.0), "r": m.plant(-0.17, 0.08, yaw=-50.0, heel=9.0)},
    ),
    rifle_key(  # head lifts off, the stock leaves the shoulder
        r={"at": (-0.19, -0.27, 1.29), "aim": (0.14, -0.94, -0.3), "up": (0.08, -0.3, 0.95), "pole": (-0.95, 0.35, -0.3)},
        hip=(0.012, 0.03, 0.864), hip_rot=(9.0, -1.0, -22.0), chest_rot=(12.0, -1.0, -28.0),
        look=(0.03, -1.0, -0.05), head_up=(-0.05, 0.0, 1.0),
        feet={"r": m.plant(-0.17, 0.08, yaw=-45.0, heel=6.0)},
    ),
    RIFLE_POSE,
    RIFLE_POSE,
]
RIFLE_BURST_FRAMES = [0, 6, 11, 15, 32, 37, 44, 52, 55]


def rifle_layer(p, f):
    # Each round: the muzzle jumps, the stock thumps the shoulder.
    recoil(RIFLE_ROUNDS, 0.7, 1.3, 5.0, 0.024, 0.007, (1.5, 1.6), (0.004, 0.6, 0.0015), 0.008)(p, f)
    # Through the burst the gun climbs and the body is shoved back, then fights it.
    d = m.smooth((f - 16.0) / 7.0) * (1.0 - m.smooth((f - 32.0) / 11.0))
    climb = m.smooth((f - 17.0) / 15.0) * (1.0 - m.smooth((f - 32.0) / 9.0))
    kick_gun(p, climb, 7.0, 0.012, 0.0)
    kick_body(p, (3.5 * d, 2.5 * d), (0.022 * d, 2.0 * d, 0.012 * d), 0.015 * d)
    p["hands"]["r"]["at"] = add(p["hands"]["r"]["at"], (0.0, 0.016 * d, 0.0))
    # The shake: alternate rounds pull the shoulders side to side.
    if 16.0 < f < 35.0:
        env = m.smooth((f - 16.0) / 2.0) * (1.0 - m.smooth((f - 32.0) / 3.0))
        shake = math.sin(TAU * (f - 16.8) / 3.36) * env
        p["chest_rot"] = add(p["chest_rot"], (0.0, 2.6 * shake, 3.0 * shake))
        p["hip_rot"] = add(p["hip_rot"], (0.0, -0.9 * shake, 1.0 * shake))
        p["hands"]["r"]["at"] = add(p["hands"]["r"]["at"], (-0.01 * shake, 0.0, 0.005 * shake))
        p["look"] = add(p["look"], (0.012 * shake, 0.0, 0.0))


def rifle_reload_keys():
    def gun(at, aim, up, pole=(-0.9, 0.3, -0.5)):
        return {"at": at, "aim": aim, "up": up, "pole": pole, "curl": 0.9, "thumb": 0.8}

    def left(r, along, over, across=0.0, point=(0.3, 0.9, 0.1), palm=(0.1, 0.1, -1.0),
             pole=(0.7, 0.3, -0.7), curl=0.8, thumb=0.8, glue=0.0):
        wrist, fingers, face = on_gun(r, along, over, across, point, palm)
        return {"at": wrist, "point": fingers, "palm": face, "pole": pole, "curl": curl, "thumb": thumb, "glue": glue}

    def free(at, point, palm, pole=(0.7, 0.5, -0.7), curl=0.8, thumb=0.8):
        return {"at": at, "point": point, "palm": palm, "pole": pole, "curl": curl, "thumb": thumb, "glue": 0.0}

    tilted = gun((-0.2, -0.3, 1.27), (0.26, -0.82, 0.5), (-0.6, 0.25, 0.75))
    mag = (0.075, -0.13)

    return [
        RIFLE_POSE,
        rifle_key(  # left hand lets go of the forestock and turns thumb-up, sliding back under the gun
            r=gun((-0.22, -0.25, 1.17), (0.32, -0.85, 0.07), (-0.23, -0.04, 0.9), pole=(-0.87, 0.38, -0.5)),
            l=left(gun((-0.22, -0.25, 1.17), (0.32, -0.85, 0.07), (-0.23, -0.04, 0.9)), 0.2, -0.04, 0.03,
                   point=(0.65, 0.55, -0.4), palm=(0.0, 0.6, -0.65), curl=0.6, thumb=0.55),
            hip=(0.01, 0.042, 0.867), hip_rot=(7.5, -1.0, -16.0), chest_rot=(11.5, 0.0, -18.0),
            look=(0.05, -1.0, -0.22),
        ),
        rifle_key(  # gun comes up and rolls, the magazine turns toward the left hand
            r=tilted, l=left(tilted, mag[0], mag[1], 0.0, curl=0.55, thumb=0.5),
            hip=(0.01, 0.04, 0.862), hip_rot=(8.0, -1.0, -14.0), chest_rot=(13.0, 0.0, -12.0),
            look=(0.05, -1.0, -0.42),
        ),
        rifle_key(  # magazine stripped downward
            r=tilted, l=free((0.0, -0.2, 0.98), (-0.3, -0.5, 0.8), (-0.75, 0.55, -0.1)),
            hip=(0.01, 0.04, 0.858), hip_rot=(8.0, -1.0, -13.0), chest_rot=(14.0, 0.0, -11.0),
            look=(0.05, -1.0, -0.5),
        ),
        rifle_key(  # to the belt: hand drops to the left hip, torso leans over it
            r=tilted, l=free((0.26, -0.06, 0.99), (-0.1, -0.75, -0.65), (-0.95, 0.25, -0.15), pole=(0.6, 0.7, -0.6)),
            hip=(0.018, 0.04, 0.852), hip_rot=(9.0, -2.0, -11.0), chest_rot=(16.0, 4.0, -6.0),
            look=(0.12, -1.0, -0.45),
        ),
        rifle_key(  # new magazine carried up
            r=tilted, l=free((0.02, -0.22, 1.0), (-0.3, -0.5, 0.8), (-0.75, 0.55, -0.1)),
            hip=(0.01, 0.04, 0.858), hip_rot=(8.0, -1.0, -13.0), chest_rot=(14.0, 0.0, -11.0),
            look=(0.05, -1.0, -0.5),
        ),
        rifle_key(  # seated: heel of the hand shoves it home, the gun rides up
            r=gun((-0.195, -0.3, 1.29), (0.26, -0.82, 0.5), (-0.6, 0.25, 0.75)),
            l=left(gun((-0.195, -0.3, 1.29), (0.26, -0.82, 0.5), (-0.6, 0.25, 0.75)), mag[0], mag[1] - 0.02, 0.0,
                   curl=0.5, thumb=0.4),
            hip=(0.01, 0.04, 0.852), hip_rot=(9.0, -1.0, -13.0), chest_rot=(15.0, 0.0, -11.0),
            look=(0.05, -1.0, -0.45),
        ),
        rifle_key(  # hand rolls out round the left of the receiver
            r=gun((-0.198, -0.285, 1.295), (0.23, -0.85, 0.46), (-0.48, 0.27, 0.82)),
            l=left(gun((-0.198, -0.285, 1.295), (0.23, -0.85, 0.46), (-0.48, 0.27, 0.82)), 0.03, 0.05, 0.13,
                   point=(0.2, 0.45, -0.7), palm=(0.05, -0.6, -0.7), pole=(0.85, 0.25, -0.5), curl=0.35, thumb=0.3),
            hip=(0.01, 0.04, 0.855), hip_rot=(8.5, -1.0, -14.0), chest_rot=(13.5, -0.5, -13.0),
            look=(0.04, -1.0, -0.38),
        ),
        rifle_key(  # across the top to the charging handle
            r=gun((-0.2, -0.27, 1.3), (0.2, -0.88, 0.42), (-0.35, 0.3, 0.88)),
            l=left(gun((-0.2, -0.27, 1.3), (0.2, -0.88, 0.42), (-0.35, 0.3, 0.88)), 0.03, 0.135, 0.0,
                   point=(0.1, -0.2, -0.95), palm=(0.0, -1.0, 0.2), pole=(0.9, 0.2, -0.5), curl=0.3, thumb=0.25),
            hip=(0.01, 0.04, 0.858), hip_rot=(8.0, -1.0, -15.0), chest_rot=(12.0, -1.0, -16.0),
            look=(0.03, -1.0, -0.3),
        ),
        rifle_key(  # slap: hand snaps back along the receiver, the whole gun jolts
            r=gun((-0.205, -0.25, 1.28), (0.2, -0.88, 0.42), (-0.35, 0.3, 0.88)),
            l=left(gun((-0.205, -0.25, 1.28), (0.2, -0.88, 0.42), (-0.35, 0.3, 0.88)), -0.07, 0.135, 0.0,
                   point=(0.1, -0.2, -0.95), palm=(0.0, -1.0, 0.2), pole=(0.9, 0.2, -0.5), curl=0.7, thumb=0.6),
            hip=(0.01, 0.04, 0.852), hip_rot=(9.0, -1.0, -15.0), chest_rot=(14.0, -1.0, -17.0),
            look=(0.03, -1.0, -0.28),
        ),
        rifle_key(  # off the handle: the hand starts to roll out to the left of the receiver
            r=gun((-0.203, -0.243, 1.268), (0.22, -0.875, 0.26), (-0.27, 0.175, 0.9)),
            l=left(gun((-0.203, -0.243, 1.268), (0.22, -0.875, 0.26), (-0.27, 0.175, 0.9)), 0.04, 0.09, 0.07,
                   point=(0.35, -0.05, -0.9), palm=(-0.35, -0.65, -0.55), pole=(0.82, 0.2, -0.6), curl=0.5, thumb=0.45),
            hip=(0.01, 0.041, 0.856), hip_rot=(8.8, -1.0, -15.5), chest_rot=(13.2, -0.8, -18.0),
            look=(0.032, -1.0, -0.24),
        ),
        rifle_key(  # gun tips over; the hand rolls round the left side, thumb up
            r=gun((-0.2, -0.235, 1.255), (0.24, -0.87, 0.1), (-0.18, 0.05, 0.92)),
            l=left(gun((-0.2, -0.235, 1.255), (0.24, -0.87, 0.1), (-0.18, 0.05, 0.92)), 0.15, 0.02, 0.13,
                   point=(0.6, 0.15, -0.75), palm=(-0.6, 0.35, -0.6), pole=(0.75, 0.2, -0.7), curl=0.5, thumb=0.5),
            hip=(0.01, 0.042, 0.86), hip_rot=(8.5, -1.0, -16.0), chest_rot=(12.5, -0.5, -19.0),
            look=(0.035, -1.0, -0.2),
        ),
        rifle_key(  # the left hand drops back to the forestock as the gun goes down
            r=gun((-0.2, -0.22, 1.23), (0.27, -0.85, -0.2), (0.0, -0.2, 0.95)),
            hip=(0.01, 0.045, 0.866), hip_rot=(8.0, -1.0, -17.0), chest_rot=(11.0, 0.0, -21.0),
            look=(0.04, -1.0, -0.14),
        ),
        RIFLE_POSE,
        RIFLE_POSE,
    ]


RIFLE_RELOAD_FRAMES = [0, 4.5, 10.5, 13.5, 18, 22.5, 25.5, 28.5, 31, 33, 35.5, 38.5, 42.5, 45, 47]


# ---------------------------------------------------------------- crossbow

CROSSBOW_LOW_R = {"at": (-0.13, -0.19, 1.075), "aim": (0.2, -0.9, -0.38), "up": (0.1, -0.36, 0.93),
                  "pole": (-0.8, 0.5, -0.6), "curl": 0.9, "thumb": 0.8}

# Heavy thing carried at the waist: hips under it, chest back, knees soft.
CROSSBOW_POSE = {
    "hip": (0.01, 0.055, 0.878),
    "hip_rot": (3.0, -1.0, -12.0),
    "chest_rot": (2.0, 0.0, -24.0),
    "look": (0.03, -1.0, -0.06),
    "head_up": (0.0, 0.0, 1.0),
    "feet": {"l": m.plant(0.145, -0.21, yaw=6.0), "r": m.plant(-0.16, 0.05, yaw=-30.0)},
    "hands": {
        "r": CROSSBOW_LOW_R,
        "l": support(CROSSBOW_LOW_R, CROSSBOW_GRIP, (0.5, 0.3, -1.0)),
    },
}

crossbow_breath = breathing(CROSSBOW_POSE, 1, spot=CROSSBOW_GRIP)


def crossbow_key(r=None, l=None, **patch):
    hand_r = m.merge(CROSSBOW_LOW_R, r or {})
    hand_l = l if l is not None else support(hand_r, CROSSBOW_GRIP, (0.5, 0.3, -1.0))
    patch["hands"] = {"r": hand_r, "l": hand_l}
    return m.merge(CROSSBOW_POSE, patch)


CROSSBOW_AIM = crossbow_key(
    r={"at": (-0.19, -0.275, 1.38), "aim": (0.0, -1.0, 0.0), "up": (0.0, 0.0, 1.0), "pole": (-1.0, 0.15, -0.35)},
    hip=(0.01, 0.0, 0.855), hip_rot=(10.0, -1.0, -24.0), chest_rot=(15.0, -4.0, -32.0),
    look=(0.0, -1.0, -0.02), head_up=(-0.26, 0.0, 1.0),
    feet={"l": m.plant(0.145, -0.21, yaw=0.0), "r": m.plant(-0.16, 0.05, yaw=-42.0, heel=8.0)},
)

CROSSBOW_RELEASE = 16.8

CROSSBOW_SHOT = [
    CROSSBOW_POSE,
    crossbow_key(  # the weight is heaved up from the legs: hips drop, then the arms lift
        r={"at": (-0.2, -0.3, 1.23), "aim": (0.1, -0.95, -0.28), "up": (0.05, -0.28, 0.96), "pole": (-0.95, 0.35, -0.4)},
        hip=(0.012, 0.03, 0.858), hip_rot=(8.0, -1.0, -18.0), chest_rot=(10.0, -2.0, -24.0),
        look=(0.02, -1.0, -0.05),
        feet={"r": m.plant(-0.16, 0.05, yaw=-36.0, heel=4.0)},
    ),
    m.merge(CROSSBOW_AIM, {  # into the shoulder, a touch high and heavy
        "chest_rot": (12.0, -3.0, -30.0), "head_up": (-0.14, 0.0, 1.0),
        "hands": {"r": {"at": (-0.19, -0.275, 1.4), "aim": (0.0, -0.98, 0.14), "up": (0.0, 0.14, 0.98)}},
    }),
    CROSSBOW_AIM,  # settled, breath held
    CROSSBOW_AIM,  # released on top of this
    m.merge(CROSSBOW_AIM, {  # eyes still down the rail as the kick dies
        "hip": (0.01, 0.01, 0.86), "chest_rot": (13.0, -3.0, -31.0),
    }),
    crossbow_key(  # the arms give up the weight, muzzle sinks
        r={"at": (-0.19, -0.27, 1.25), "aim": (0.1, -0.93, -0.32), "up": (0.05, -0.32, 0.94), "pole": (-0.95, 0.35, -0.4)},
        hip=(0.012, 0.03, 0.866), hip_rot=(7.0, -1.0, -18.0), chest_rot=(9.0, -1.0, -24.0),
        look=(0.02, -1.0, -0.05), head_up=(-0.05, 0.0, 1.0),
        feet={"r": m.plant(-0.16, 0.05, yaw=-35.0, heel=4.0)},
    ),
    CROSSBOW_POSE,
    CROSSBOW_POSE,
]
CROSSBOW_SHOT_FRAMES = [0, 5, 10, 14, 17, 25, 31, 37, 40]

crossbow_recoil = recoil([CROSSBOW_RELEASE], 1.3, 4.5, 11.0, 0.075, 0.02, (6.5, 5.5), (0.022, 3.0, 0.012), 0.05)


def crossbow_reload_keys():
    def gun(at, aim, up, pole=(-0.8, 0.5, -0.6)):
        return {"at": at, "aim": aim, "up": up, "pole": pole, "curl": 0.9, "thumb": 0.8}

    def string(at, point=(0.1, -0.45, 0.9), palm=(0.3, 0.9, 0.3), pole=(0.9, 0.4, -0.2), curl=0.85):
        return {"at": at, "point": point, "palm": palm, "pole": pole, "curl": curl, "thumb": 0.7, "glue": 0.0}

    # Nose on the floor by the left foot; the butt tilts toward the belly as the back hauls.
    planted = gun((-0.08, -0.37, 0.62), (0.06, -0.14, -0.99), (0.1, -0.98, 0.14), pole=(-0.9, 0.3, -0.4))
    hauled = gun((-0.07, -0.3, 0.72), (0.05, -0.28, -0.96), (0.1, -0.95, 0.28), pole=(-0.9, 0.7, -0.3))
    level = gun((-0.17, -0.26, 1.02), (0.2, -0.86, -0.46), (0.1, -0.46, 0.88))

    back_feet = {"l": m.plant(0.11, -0.36, yaw=2.0), "r": m.plant(-0.18, 0.08, yaw=-30.0, heel=6.0)}
    lift_left = {"l": m.plant(0.14, -0.27, heel=26.0, yaw=4.0, z=0.05), "r": m.plant(-0.16, 0.05, yaw=-30.0)}

    return [
        CROSSBOW_POSE,
        crossbow_key(  # lowering, weight onto the right, left foot lifting to go to the stirrup
            r={"at": (-0.14, -0.33, 0.98), "aim": (0.14, -0.6, -0.78), "up": (0.1, -0.78, 0.6), "pole": (-0.85, 0.4, -0.5)},
            l=string((0.03, -0.33, 0.96), point=(0.1, -0.8, 0.5), palm=(0.4, 0.4, 0.8), pole=(0.8, 0.4, -0.6), curl=0.6),
            hip=(-0.02, 0.07, 0.84), hip_rot=(20.0, -2.0, -12.0), chest_rot=(38.0, -2.0, -14.0),
            look=(0.04, -1.0, -0.55), feet=lift_left,
        ),
        crossbow_key(  # nose grounded, boot beside it, leaning right over the gun
            r=planted,
            l=string((0.03, -0.46, 0.72), curl=0.5),
            hip=(0.02, 0.07, 0.8), hip_rot=(26.0, 0.0, -10.0), chest_rot=(52.0, 2.0, -10.0),
            look=(0.0, -1.0, -0.85), feet=back_feet,
        ),
        crossbow_key(  # both hands take up the strain, lowest point, back rounded
            r=planted,
            l=string((0.03, -0.44, 0.66), curl=0.9),
            hip=(0.02, 0.08, 0.77), hip_rot=(32.0, 0.0, -10.0), chest_rot=(62.0, 2.0, -12.0),
            look=(0.0, -1.0, -0.95), feet=back_feet,
        ),
        crossbow_key(  # the haul: legs and back straighten, left hand comes up the rail
            r=hauled,
            l=string((0.05, -0.42, 0.74), curl=1.0),
            hip=(0.02, 0.09, 0.82), hip_rot=(22.0, 1.0, -14.0), chest_rot=(36.0, 3.0, -18.0),
            look=(0.0, -1.0, -0.65), feet=back_feet,
        ),
        crossbow_key(  # top of the haul: shoulders thrown back, elbows behind the ribs, latch
            r=m.merge(hauled, {"at": (-0.11, -0.28, 0.92), "aim": (0.05, -0.4, -0.92), "up": (0.1, -0.9, 0.4), "pole": (-0.8, 0.9, -0.2)}),
            l=string((0.09, -0.3, 0.98), curl=1.0, pole=(0.8, 0.8, -0.2)),
            hip=(0.02, 0.1, 0.845), hip_rot=(14.0, 2.0, -16.0), chest_rot=(16.0, 4.0, -22.0),
            look=(0.0, -1.0, -0.4), feet=back_feet,
        ),
        crossbow_key(  # string latched, hand turns over and starts down the outside of the leg
            r=m.merge(level, {"at": (-0.14, -0.26, 0.92), "aim": (0.14, -0.66, -0.74), "up": (0.1, -0.74, 0.66)}),
            l=string((0.22, -0.2, 1.04), point=(0.35, -0.93, 0.05), palm=(-0.45, 0.2, 0.85), pole=(0.75, 0.6, -0.4), curl=0.6),
            hip=(0.02, 0.08, 0.855), hip_rot=(7.5, 0.0, -14.0), chest_rot=(9.0, 3.5, -15.0),
            look=(0.07, -1.0, -0.4),
        ),
        crossbow_key(  # gun swung level at the waist, left hand goes to the bolt case on the hip
            r=level,
            l=string((0.3, 0.08, 1.0), point=(-0.1, -0.3, -0.95), palm=(-0.95, 0.2, 0.0), pole=(0.6, 0.7, -0.6), curl=0.7),
            hip=(0.018, 0.06, 0.862), hip_rot=(7.0, -2.0, -12.0), chest_rot=(14.0, 3.0, -8.0),
            look=(0.14, -1.0, -0.4),
        ),
        crossbow_key(  # bolt laid along the rail
            r=level,
            l=string((-0.02, -0.46, 1.12), point=(-0.4, -0.8, -0.2), palm=(-0.4, -0.05, -0.9), pole=(0.8, 0.3, -0.6), curl=0.6),
            hip=(0.012, 0.05, 0.866), hip_rot=(7.0, -1.0, -14.0), chest_rot=(16.0, 0.0, -14.0),
            look=(0.03, -1.0, -0.42),
        ),
        crossbow_key(  # hand rolls round the left of the rail, thumb up
            r=level,
            l=string((0.0, -0.37, 0.95), point=(-0.3, -0.9, 0.1), palm=(-0.85, -0.2, 0.4), pole=(0.7, 0.35, -0.8), curl=0.5),
            hip=(0.011, 0.052, 0.868), hip_rot=(6.0, -1.0, -14.0), chest_rot=(12.0, 0.0, -19.0),
            look=(0.03, -1.0, -0.3),
        ),
        crossbow_key(  # left hand drops under the stock, the gun comes up to carry
            r={"at": (-0.14, -0.2, 1.08), "aim": (0.2, -0.87, -0.42), "up": (0.1, -0.42, 0.9)},
            hip=(0.01, 0.055, 0.872), hip_rot=(4.0, -1.0, -13.0), chest_rot=(6.0, 0.0, -23.0),
            look=(0.03, -1.0, -0.14),
        ),
        CROSSBOW_POSE,
        CROSSBOW_POSE,
    ]


CROSSBOW_RELOAD_FRAMES = [0, 8, 14, 18, 26, 31, 34.5, 39.5, 44.5, 48, 52, 56, 59]


# ---------------------------------------------------------------- bow

BOW_LOW_L = {"at": (0.25, -0.31, 1.0), "aim": (0.08, -0.84, -0.54), "up": (-0.02, -0.54, 0.84),
             "pole": (0.75, 0.6, -0.5), "curl": 0.9, "thumb": 0.8}

# Three-quarters on to the target, bow hanging forward from a long arm, head up.
BOW_POSE = {
    "hip": (0.01, 0.05, 0.884),
    "hip_rot": (5.0, -1.0, -24.0),
    "chest_rot": (4.0, 1.0, -22.0),
    "look": (0.1, -1.0, -0.05),
    "head_up": (0.0, 0.0, 1.0),
    "feet": {"l": m.plant(0.11, -0.23, yaw=-10.0), "r": m.plant(-0.13, 0.1, yaw=-50.0)},
    "hands": {
        "l": BOW_LOW_L,
        "r": {"at": (-0.23, 0.0, 1.03), "pole": (-0.5, 0.8, -0.7), "curl": 0.5, "thumb": 0.35},
    },
}

bow_breath = breathing(BOW_POSE, 1, chest=0.7, hand=0.003)


def bow_key(**patch):
    return m.merge(BOW_POSE, patch)


BOW_RELEASE = 21.6

SIDE_ON_FEET = {"l": m.plant(0.11, -0.23, yaw=-42.0), "r": m.plant(-0.13, 0.1, yaw=-82.0)}

# Full draw: side-on, bow arm a straight strut, right elbow straight behind the
# arrow, shoulder blade pinched, string hand under the jaw, head turned along it.
BOW_DRAW = bow_key(
    hip=(0.005, 0.03, 0.868), hip_rot=(4.0, -1.0, -55.0), chest_rot=(5.0, -3.0, -74.0),
    look=(0.0, -1.0, -0.03), head_up=(-0.2, 0.0, 1.0),
    feet=SIDE_ON_FEET,
    hands={"l": {"at": (0.03, -0.765, 1.45), "aim": (0.0, -1.0, 0.0), "up": (0.1, 0.0, 1.0),
                 "pole": (0.5, 0.5, -0.8), "clav": (4.0, -3.0), "curl": 0.8, "thumb": 0.8},
           "r": {"at": (-0.1, -0.02, 1.53), "pole": (-0.4, 0.9, 0.0), "curl": 0.6, "thumb": 0.6, "clav": (-10.0, 0.0)}},
)

BOW_SHOT = [
    BOW_POSE,
    bow_key(  # elbow leads up, chest opens toward the right hand
        hip=(0.01, 0.05, 0.878), hip_rot=(5.0, -1.0, -20.0), chest_rot=(3.0, -2.0, -14.0),
        look=(0.14, -1.0, -0.02),
        hands={"r": {"at": (-0.4, -0.14, 1.36), "pole": (-0.95, 0.2, -0.3), "curl": 0.4, "thumb": 0.3}},
    ),
    bow_key(  # elbow out wide and rising, hand climbing past the ear
        hip=(0.01, 0.05, 0.877), hip_rot=(5.0, -1.0, -19.0), chest_rot=(2.0, -3.0, -11.0),
        look=(0.15, -1.0, -0.01),
        hands={"r": {"at": (-0.42, -0.02, 1.62), "pole": (-0.95, -0.15, 0.05), "curl": 0.55, "thumb": 0.5}},
    ),
    bow_key(  # fingers on the fletching behind the shoulder
        hip=(0.01, 0.05, 0.876), hip_rot=(5.0, -1.0, -18.0), chest_rot=(1.0, -4.0, -8.0),
        look=(0.16, -1.0, 0.0),
        hands={"r": {"at": (-0.26, 0.14, 1.63), "pole": (-0.85, -0.42, 0.22), "curl": 0.7, "thumb": 0.7}},
    ),
    bow_key(  # arrow drawn up out of the quiver, hand high, bow starts to lift
        hip=(0.01, 0.05, 0.876), hip_rot=(5.0, -1.0, -24.0), chest_rot=(3.0, -3.0, -18.0),
        look=(0.14, -1.0, -0.02),
        hands={"l": {"at": (0.24, -0.45, 1.12), "aim": (0.05, -0.93, -0.36), "up": (0.0, -0.36, 0.93)},
               "r": {"at": (-0.3, -0.06, 1.72), "pole": (-0.9, -0.3, 0.2), "curl": 0.8, "thumb": 0.8}},
    ),
    bow_key(  # comes over and down to nock, bow across the front at the belt
        hip=(0.008, 0.045, 0.872), hip_rot=(5.0, -1.0, -36.0), chest_rot=(8.0, -1.0, -40.0),
        look=(0.1, -1.0, -0.25),
        hands={"l": {"at": (0.14, -0.55, 1.2), "aim": (0.02, -0.98, -0.18), "up": (0.05, -0.18, 0.98), "pole": (0.7, 0.5, -0.6)},
               "r": {"at": (-0.1, -0.36, 1.3), "pole": (-0.9, 0.4, -0.4), "curl": 0.65, "thumb": 0.6}},
        feet={"l": m.plant(0.11, -0.23, yaw=-26.0), "r": m.plant(-0.13, 0.1, yaw=-66.0)},
    ),
    bow_key(  # bow rises to the mark while the turn finishes, draw begins from the shoulder
        hip=(0.006, 0.04, 0.87), hip_rot=(5.0, -1.0, -44.0), chest_rot=(7.0, -2.0, -53.0),
        look=(0.03, -1.0, -0.05), head_up=(-0.1, 0.0, 1.0),
        hands={"l": {"at": (0.06, -0.72, 1.44), "aim": (0.0, -1.0, 0.0), "up": (0.1, 0.0, 1.0), "pole": (0.5, 0.5, -0.8),
                     "clav": (2.0, 0.0)},
               "r": {"at": (-0.09, -0.3, 1.47), "pole": (-0.7, 0.6, -0.1), "curl": 0.6, "thumb": 0.6}},
        feet={"l": m.plant(0.11, -0.23, yaw=-38.0), "r": m.plant(-0.13, 0.1, yaw=-78.0)},
    ),
    BOW_DRAW,  # anchor
    m.merge(BOW_DRAW, {  # holding: the back keeps working, the hand creeps a centimetre
        "chest_rot": (5.0, -3.0, -76.0),
        "hands": {"r": {"at": (-0.105, 0.0, 1.53), "clav": (-14.0, 0.0)}},
    }),
    m.merge(BOW_DRAW, {  # let go: right hand flies back past the ear, opening; bow hand pushes through
        "chest_rot": (3.0, -3.0, -78.0), "hip": (0.005, 0.038, 0.866),
        "hands": {"l": {"at": (0.03, -0.775, 1.43), "aim": (0.0, -1.0, -0.06), "up": (0.1, -0.06, 1.0)},
                  "r": {"at": (-0.17, 0.17, 1.56), "pole": (-0.5, 0.85, -0.2), "curl": 0.12, "thumb": 0.1, "clav": (-16.0, 0.0)}},
    }),
    m.merge(BOW_DRAW, {  # held open a beat, watching it fly
        "chest_rot": (3.5, -2.5, -74.0), "hip": (0.005, 0.038, 0.868),
        "hands": {"l": {"at": (0.03, -0.755, 1.42), "aim": (0.0, -1.0, -0.08), "up": (0.1, -0.08, 1.0)},
                  "r": {"at": (-0.18, 0.15, 1.5), "pole": (-0.5, 0.85, -0.35), "curl": 0.2, "thumb": 0.15, "clav": (-10.0, 0.0)}},
    }),
    bow_key(  # bow arm comes down, the body opens back toward the target
        hip=(0.008, 0.042, 0.876), hip_rot=(5.0, -1.0, -38.0), chest_rot=(5.0, -1.0, -46.0),
        look=(0.06, -1.0, -0.06), head_up=(-0.05, 0.0, 1.0),
        hands={"l": {"at": (0.2, -0.56, 1.16), "aim": (0.04, -0.95, -0.3), "up": (0.0, -0.3, 0.95), "pole": (0.7, 0.5, -0.6)},
               "r": {"at": (-0.25, 0.08, 1.2), "pole": (-0.5, 0.8, -0.6), "curl": 0.4, "thumb": 0.3}},
        feet={"l": m.plant(0.11, -0.23, yaw=-24.0), "r": m.plant(-0.13, 0.1, yaw=-64.0)},
    ),
    BOW_POSE,
    BOW_POSE,
]
BOW_FRAMES = [0, 2.5, 4.5, 6.5, 9, 12, 15, 18, 21.6, 23.2, 27, 32, 38, 40]


# ---------------------------------------------------------------- axe throw

THROW_R = {"at": (-0.27, -0.08, 0.85), "blade": (-0.05, -0.93, 0.33), "edge": (-0.02, -0.34, -0.94),
           "pole": (-0.25, 0.8, -1.0), "curl": 0.88, "thumb": 0.75}

# The neutral stance, with an axe hanging from the right hand.
THROW_POSE = m.merge(STANCE, {"head_up": (0.0, 0.0, 1.0), "hands": {"r": None}})
THROW_POSE["hands"]["r"] = THROW_R
THROW_POSE["hands"]["l"] = {"at": (0.27, -0.02, 0.95), "pole": (0.25, 0.8, -1.0), "curl": 0.32, "thumb": 0.25}


def throw_key(**patch):
    return m.merge(THROW_POSE, patch)


THROW_RELEASE = 9.6

THROW = [
    THROW_POSE,
    throw_key(  # weight rocks back onto the right, left foot peels up, axe swings out and up
        hip=(-0.03, 0.07, 0.885), hip_rot=(1.0, -5.0, -22.0), chest_rot=(-4.0, -5.0, -34.0),
        look=(0.14, -1.0, 0.0),
        feet={"l": m.plant(0.12, -0.2, heel=30.0, yaw=9.0, z=0.02)},
        hands={"l": {"at": (0.36, -0.28, 1.2), "pole": (0.7, 0.4, -0.5), "curl": 0.25},
               "r": {"at": (-0.5, 0.0, 1.32), "blade": (-0.25, 0.1, 0.96), "edge": (-0.9, -0.3, -0.2), "pole": (-0.7, 0.5, -0.6)}},
    ),
    throw_key(  # cocked: chest wound right, axe behind the head, left arm out at the target
        hip=(-0.04, 0.085, 0.86), hip_rot=(-1.0, -7.0, -32.0), chest_rot=(-12.0, -9.0, -58.0),
        look=(0.28, -1.0, 0.04),
        feet={"l": m.plant(0.14, -0.3, heel=20.0, yaw=8.0, z=0.05)},
        hands={"l": {"at": (0.26, -0.52, 1.36), "pole": (0.7, 0.3, -0.6), "curl": 0.2},
               "r": {"at": (-0.31, 0.27, 1.67), "blade": (-0.05, 0.96, 0.25), "edge": (-0.25, -0.2, 0.95), "pole": (-0.8, -0.2, 0.55)}},
    ),
    throw_key(  # the step lands heel first, hips fire through; the arm is still behind
        hip=(0.03, -0.06, 0.835), hip_rot=(8.0, 0.0, 12.0), chest_rot=(4.0, -3.0, -28.0),
        look=(0.14, -1.0, -0.04),
        feet={"l": m.plant(0.16, -0.46, heel=-8.0, yaw=8.0)},
        hands={"l": {"at": (0.3, -0.4, 1.25), "pole": (0.7, 0.4, -0.55), "curl": 0.4},
               "r": {"at": (-0.27, 0.0, 1.73), "blade": (-0.05, 0.4, 0.91), "edge": (-0.1, -0.91, 0.4), "pole": (-0.85, 0.12, 0.45)}},
    ),
    throw_key(  # release: chest whips over the front leg, arm long and high, axe leaving
        hip=(0.05, -0.12, 0.815), hip_rot=(16.0, 4.0, 26.0), chest_rot=(22.0, 5.0, 26.0),
        look=(0.04, -1.0, -0.1),
        feet={"l": m.plant(0.16, -0.46, yaw=10.0), "r": m.plant(-0.128, -0.085, heel=24.0, yaw=-8.0)},
        hands={"l": {"at": (0.32, -0.22, 1.15), "pole": (0.7, 0.5, -0.5), "curl": 0.55},
               "r": {"at": (-0.14, -0.58, 1.62), "blade": (-0.05, -0.28, 0.96), "edge": (0.0, -0.96, -0.28), "pole": (-0.9, 0.2, 0.1),
                     "curl": 0.88, "thumb": 0.7}},
    ),
    throw_key(  # the hand has let go; arm carries through and down across the body
        hip=(0.06, -0.14, 0.8), hip_rot=(22.0, 5.0, 36.0), chest_rot=(34.0, 6.0, 46.0),
        look=(0.1, -1.0, -0.24),
        feet={"l": m.plant(0.16, -0.46, yaw=12.0), "r": m.plant(-0.128, -0.085, heel=40.0, yaw=-2.0)},
        hands={"l": {"at": (0.33, 0.14, 1.03), "pole": (0.7, 0.8, -0.4), "curl": 0.45},
               "r": {"at": (0.1, -0.55, 1.05), "blade": (0.42, -0.86, 0.3), "edge": (0.5, -0.05, -0.85), "pole": (-0.7, 0.2, -0.6),
                     "curl": 0.25, "thumb": 0.25}},
    ),
    throw_key(  # end of the follow-through, the back leg takes the weight off
        hip=(0.06, -0.12, 0.81), hip_rot=(18.0, 4.0, 28.0), chest_rot=(28.0, 5.0, 38.0),
        look=(0.08, -1.0, -0.14),
        feet={"l": m.plant(0.16, -0.46, yaw=12.0), "r": m.plant(-0.128, -0.085, heel=32.0, yaw=-6.0)},
        hands={"l": {"at": (0.33, 0.12, 1.0), "pole": (0.7, 0.8, -0.5)},
               "r": {"at": (0.03, -0.42, 0.98), "blade": (0.3, -0.9, 0.3), "edge": (0.4, -0.15, -0.9), "pole": (-0.6, 0.3, -0.7),
                     "curl": 0.3, "thumb": 0.25}},
    ),
    throw_key(  # front foot pushes back: heel, then the step home
        hip=(0.03, -0.04, 0.85), hip_rot=(10.0, 1.0, 12.0), chest_rot=(12.0, 3.0, 14.0),
        look=(0.03, -1.0, -0.08),
        feet={"l": m.plant(0.14, -0.32, heel=26.0, yaw=9.0, z=0.05), "r": m.plant(-0.128, -0.085, heel=8.0, yaw=-11.0)},
        hands={"l": {"at": (0.3, 0.06, 0.97)},
               "r": {"at": (-0.14, -0.28, 0.93), "blade": (0.05, -0.93, 0.33), "edge": (0.1, -0.33, -0.94), "pole": (-0.4, 0.5, -0.9),
                     "curl": 0.5, "thumb": 0.4}},
    ),
    throw_key(  # foot down, settling
        hip=(0.018, 0.015, 0.89), hip_rot=(6.0, -1.0, 2.0), chest_rot=(5.0, 1.5, 4.0),
        hands={"r": {"at": (-0.25, -0.13, 0.87), "curl": 0.75, "thumb": 0.65}},
    ),
    THROW_POSE,
    THROW_POSE,
]
THROW_FRAMES = [0, 3, 6.5, 8.2, 9.6, 12.5, 16, 22, 27, 30, 32]


CLIPS = {
    "Stance_Pistol": {"length": 2.5, "loop": True, "at": pistol_breath, "weapons": PISTOL},
    "Stance_Longgun": {"length": 2.33, "loop": True, "at": rifle_breath, "weapons": RIFLE},
    "Stance_Bow": {"length": 1.33, "loop": True, "at": bow_breath, "weapons": LONGBOW},
    "Stance_Crossbow": {"length": 2.33, "loop": True, "at": crossbow_breath, "weapons": CROSSBOW},
    "Pistol_Shot": clip(PISTOL_SHOT, PISTOL_FRAMES, PISTOL, {"release": PISTOL_SHOTS}, pistol_hold),
    "Rifle_Burst": clip(RIFLE_BURST, RIFLE_BURST_FRAMES, RIFLE, {"release": RIFLE_ROUNDS}, rifle_layer, RIFLE_GRIP),
    "Crossbow_Shot": clip(CROSSBOW_SHOT, CROSSBOW_SHOT_FRAMES, CROSSBOW, {"release": [CROSSBOW_RELEASE]},
                          crossbow_recoil, CROSSBOW_GRIP),
    "Bow_Shot": clip(BOW_SHOT, BOW_FRAMES, LONGBOW, {"release": [BOW_RELEASE]}),
    "Throw": clip(THROW, THROW_FRAMES, AXE, {"release": [THROW_RELEASE]}),
    "Reload_Rifle": clip(rifle_reload_keys(), RIFLE_RELOAD_FRAMES, RIFLE, spot=RIFLE_GRIP),
    "Reload_Pistol": clip(pistol_reload_keys(), PISTOL_RELOAD_FRAMES, PISTOL),
    "Reload_Crossbow": clip(crossbow_reload_keys(), CROSSBOW_RELOAD_FRAMES, CROSSBOW, spot=CROSSBOW_GRIP),
}
