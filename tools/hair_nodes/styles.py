"""Four test hairstyles built with hairkit. exec hairkit.py first, then this file
with `hk` (the hairkit namespace dict) in globals. build("F1") etc."""
import math
from mathutils import Vector

K = hk  # noqa: F821  (hairkit namespace)


F1_PART = 0.0
F2_PART = 0.03


def sm(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def crown_out(i, back=0.08, swirl=65.0, radius=0.055):
    """Horizontal direction away from the crown whorl. Near the centre the
    direction is rotated (a spiral, like a real whorl) so hair lies over the
    centre instead of parting radially and baring the scalp."""
    C = i["fr"]["C"]
    d = Vector((i["p"].x, i["p"].y - (C.y + back), 0))
    r = d.length
    if r < 1e-4:
        return Vector((0, 1, 0))
    d /= r
    a = math.radians(swirl) * (1 - sm(r / radius))
    ca, sa = math.cos(a), math.sin(a)
    return Vector((d.x * ca - d.y * sa, d.x * sa + d.y * ca, 0))


# ---------------------------------------------------------------- female
def f1_curtain(i):
    """Long layers, centre part, curtain bangs. Reference: hair rises off the
    part, the front pieces drop over the forehead corners and sweep out past
    the cheekbones; layers get longer toward the back."""
    p = i["p"]
    side = 1.0 if p.x > F1_PART else -1.0
    top = sm((i["theta"] - 38) / 22)
    base = Vector((side * (0.95 * top + 0.15), 0.3 + 0.35 * (1 - top), -0.25 - 0.75 * (1 - top)))
    fb = sm((52 - i["phi"]) / 18) * sm((22 - i["above"]) / 10)       # curtain-bang band at the front hairline
    d = base.lerp(Vector((side * 0.8, -0.5, -0.3)), fb)
    layer = sm((i["phi"] - 45) / 60)                                # longer toward the back
    length = (0.27 + 0.13 * layer + 0.03 * i["u"]) * (1 - fb) + (0.15 + 0.04 * i["u"]) * fb
    return dict(dir=d, lift=0.2 + 0.12 * top + 0.2 * fb, length=length, grav=0.23, stiff=6, off=0.012,
                face_push=1.3, wave=(0.009, 0.15, 1.0))


def f2_lob(i):
    """Collarbone-length wavy lob, deep side part; the heavy side sweeps across
    the forehead corner, the light side is pushed back off the face."""
    p = i["p"]
    side = 1.0 if p.x > F2_PART else -1.0
    top = sm((i["theta"] - 38) / 22)
    base = Vector((side * (0.95 * top + 0.15), 0.3 + 0.35 * (1 - top), -0.25 - 0.75 * (1 - top)))
    fb = sm((55 - i["phi"]) / 20) * sm((18 - i["above"]) / 9)
    sweep = Vector((side * 0.9, -0.1 if side < 0 else 0.3, -0.6 if side < 0 else -0.3))
    d = base.lerp(sweep, fb)
    length = 0.19 + 0.03 * i["u"] - 0.03 * fb
    return dict(dir=d, lift=0.22 + 0.14 * top + 0.15 * fb, length=length, grav=0.22, stiff=6, off=0.015,
                face_push=1.2, wave=(0.012, 0.14, 1.0))


# ---------------------------------------------------------------- male
def m1_textured(i):
    """Short textured crop: the whole top is combed forward into a short fringe
    that lifts a little at the front, sides and back tapered toward the hairline."""
    top = sm((i["theta"] - 32) / 20)
    front = sm((60 - i["phi"]) / 35) * top
    out = crown_out(i, back=0.07, swirl=50.0)
    behind = sm((i["phi"] - 115) / 30)                               # behind the whorl hair falls back/down
    d_top = (Vector((0.18, -1.0, 0.04 * front)) * (1 - behind) + (out + Vector((0, 0, -0.4))) * behind)
    d_side = out * 0.2 + Vector((0, -0.15, -1))
    d = d_side.lerp(d_top, top)
    taper = sm(i["above"] / 30)
    length = 0.004 + 0.008 * taper + 0.030 * top + 0.010 * front
    return dict(dir=d, lift=0.08 + 0.08 * top + 0.06 * front, length=length * (0.8 + 0.4 * i["u"]),
                grav=0.1, stiff=5, off=0.002 + 0.004 * top, face_push=0.0)


def m2_flow(i):
    """Medium flow: the front rises off the forehead and sweeps back and a little
    to one side, sides run back over the tops of the ears, loose waves, ends at the nape."""
    p = i["p"]
    top = sm((i["theta"] - 30) / 25)
    front = sm((75 - i["phi"]) / 45)
    side = max(-1.0, min(1.0, p.x / 0.035))                          # smooth across the midline: a sign flip opens a part
    d_top = Vector((0.25 + side * 0.12, 0.9, 0.15 * front))
    d_side = Vector((side * 0.1, 0.9, -0.3))
    d_back = Vector((side * 0.1, 0.4, -1.0))
    d = d_back.lerp(d_side, sm((120 - i["phi"]) / 40)).lerp(d_top, top)
    length = 0.095 + 0.03 * i["u"] + 0.05 * front * top     # front hair must reach past the crown, or its tips stand free on top
    return dict(dir=d, lift=0.12 + 0.2 * front * top, length=length, grav=0.16, stiff=6, off=0.008,
                face_push=0.0, wave=(0.006, 0.09, 1.0))


def _stack(density, clump, clump2, frizz, trim, radius=0.00009, shape=0.35, fmin=0.3):
    s = [("Interpolate Hair Curves", {"Density": density, "Density Mask": ("attr", "hair_density"),
                                      "Part by Mesh Islands": False, "Interpolation Guides": 1}),
         ("Clump Hair Curves", clump),
         ("Clump Hair Curves", dict({"Existing Guide Map": False}, **clump2)),
         ("Frizz Hair Curves", {"Distance": frizz, "Shape": 0.3})]
    if trim:
        s.append(("Trim Hair Curves", {"Length Factor": 1.0, "Replace Length": False, "Random Offset": trim}))
    s.append(("Set Hair Curve Profile", {"Radius": radius, "Shape": shape, "Factor Min": fmin}))
    return s


STYLES = {
    "F1": dict(tag="F", fn=f1_curtain, n=440, part=F1_PART, mel=0.82, red=0.45, tint=(0.008, 0.005, 0.003),
               stack=_stack(460000.0, {"Factor": 0.75, "Shape": 0.5, "Tip Spread": 0.002},
                            {"Guide Distance": 0.005, "Factor": 0.45, "Shape": 0.6, "Tip Spread": 0.002},
                            0.0012, 0.015)),
    "F2": dict(tag="F", fn=f2_lob, n=440, part=F2_PART, mel=0.74, red=0.55, tint=(0.010, 0.006, 0.004),
               stack=_stack(480000.0, {"Factor": 0.75, "Shape": 0.5, "Tip Spread": 0.002},
                            {"Guide Distance": 0.005, "Factor": 0.45, "Shape": 0.6, "Tip Spread": 0.002},
                            0.001, 0.015)),
    "M1": dict(tag="M", fn=m1_textured, n=520, spacing=0.007, rough=0.5, mel=0.9, red=0.3, tint=(0.006, 0.004, 0.003),
               stack=_stack(520000.0, {"Factor": 0.7, "Shape": 0.45, "Tip Spread": 0.003},
                            {"Guide Distance": 0.006, "Factor": 0.6, "Shape": 0.5},
                            0.0005, 0.004, shape=0.4, fmin=0.6)),
    "M2": dict(tag="M", fn=m2_flow, n=460, rough=0.5, mel=0.8, red=0.45, tint=(0.008, 0.005, 0.003),
               stack=_stack(470000.0, {"Factor": 0.75, "Shape": 0.5, "Tip Spread": 0.002},
                            {"Guide Distance": 0.005, "Factor": 0.45, "Shape": 0.6, "Tip Spread": 0.002},
                            0.001, 0.012)),
}


def build(name, **over):
    s = dict(STYLES[name]); s.update(over)
    tag = s["tag"]
    K["build_scalp"](tag, part=s.get("part"))
    for st_ in s["stack"]:
        if st_[0] == "Interpolate Hair Curves":
            st_[1]["Part by Mesh Islands"] = s.get("part") is not None
    n = K["grow"](tag, s["fn"], n=s["n"], spacing=s.get("spacing", 0.008))
    mat = K["hair_material"]("Hair_" + name, melanin=s["mel"], redness=s["red"], rough=s.get("rough", 0.3))
    import bpy
    ob = bpy.data.objects["Hair_" + tag]
    mods = K["stack"](ob, s["stack"], mat)
    K["paint_material"](color=s["tint"])
    return dict(guides=n, mods=mods)
