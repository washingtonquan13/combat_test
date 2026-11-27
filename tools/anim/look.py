"""See an animation the way an animator checks it, from headless Blender.

    blender -b --factory-startup --python tools/anim/look.py -- \
        --src tools/rig/humanoid_rig.glb \
        --takes tools/locomotion/takes/mixamo_duel.glb --action ss_slash_1 \
        --out recordings/anim_look/ss_slash_1 [--frames 1,8,12,14,20,30] [--count 8]
        [--track Hips,Spine2,Head,RightHand,LeftFoot,RightFoot] [--tip RightHand:0,0.9,0]

--src is a .glb or .blend holding the character (mesh + armature).
tools/rig/humanoid_rig.glb is the game's rig with no body, so only the
trails show; pass a skinned .glb on the same rig to see a body. --takes is
an optional second .glb whose actions drive the same skeleton. --tip adds a
tracked point fixed in a bone's space (bone:x,y,z in metres, the bone's local
axes), a stand-in for a blade tip when no weapon object exists; a name in
--track that is an object rather than a bone is tracked as that object.

Writes into --out:

  poses.png       sampled frames (columns) from front, side, three-quarter and
                  top (rows), frame numbers in the corner. On the floor: the
                  support polygon of the planted feet (green) and the centre
                  of gravity's drop point (red, with its plumb line).
  silhouette.png  the same sheet as black shapes: does each pose read?
  trails.png      one frame of the body with every tracked point's path over
                  the whole clip, one dot per frame, so arcs and spacing show
                  (wide dots = fast, bunched = slow, a kink = a mistake).
  report.txt      per frame: balance margin (CoG drop point inside the support
                  polygon, +cm inside / -cm outside), which feet are planted
                  and how far a planted foot slid, the speed of each tracked
                  point; then per tracked point the frame it starts moving,
                  peaks and stops: the order of the chain.

Nothing here judges the clip. It puts in front of me what the craft's checks
look at (docs: memory animation_craft_fundamentals).
"""
import bpy, bmesh, sys, os, math
import numpy as np
from mathutils import Vector, Matrix


def arg(name, default=None):
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return argv[argv.index(name) + 1] if name in argv else default


SRC = arg("--src")
TAKES = arg("--takes")
ACTION = arg("--action")
OUT = arg("--out", "recordings/anim_look/out")
COUNT = int(arg("--count", "8"))
FRAMES = arg("--frames")
TRACK = arg("--track", "Hips,Spine2,Head,RightHand,LeftHand,LeftFoot,RightFoot").split(",")
TIP = arg("--tip")
CELL = (int(arg("--cell", "360")), int(arg("--cellh", "440")))
os.makedirs(OUT, exist_ok=True)

# Body segment masses as fractions of the whole (Dempster), by the Mixamo bone
# each one rides on; the segment's centre is the middle of the bone.
MASS = {"Head": 0.081, "Hips": 0.142, "Spine": 0.139, "Spine1": 0.110, "Spine2": 0.106,
        "LeftArm": 0.028, "RightArm": 0.028, "LeftForeArm": 0.016, "RightForeArm": 0.016,
        "LeftHand": 0.006, "RightHand": 0.006, "LeftUpLeg": 0.100, "RightUpLeg": 0.100,
        "LeftLeg": 0.0465, "RightLeg": 0.0465, "LeftFoot": 0.0145, "RightFoot": 0.0145}
COLORS = [(1, .2, .2, 1), (1, .6, .1, 1), (.95, .9, .1, 1), (.2, .8, .3, 1), (.2, .7, 1, 1),
          (.5, .4, 1, 1), (1, .3, .8, 1), (1, 1, 1, 1), (.1, .1, .1, 1)]

# ------------------------------------------------------------------ load
if SRC.lower().endswith(".blend"):
    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(SRC))
else:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(SRC), bone_heuristic="BLENDER")
scene = bpy.context.scene
arm = max((o for o in scene.objects if o.type == "ARMATURE"), key=lambda o: len(o.data.bones))
if TAKES:
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(TAKES), bone_heuristic="BLENDER")
    for o in set(bpy.data.objects) - before:
        bpy.data.objects.remove(o, do_unlink=True)
if ACTION:
    act = bpy.data.actions.get(ACTION) or next(a for a in bpy.data.actions if ACTION in a.name)
    arm.animation_data_create()
    for t in arm.animation_data.nla_tracks:
        t.mute = True
    arm.animation_data.action = act
    if hasattr(arm.animation_data, "action_slot") and act.slots:
        arm.animation_data.action_slot = act.slots[0]
    f0, f1 = int(round(act.frame_range[0])), int(round(act.frame_range[1]))
else:
    f0, f1 = scene.frame_start, scene.frame_end
fps = scene.render.fps
print("LOOK armature", arm.name, "action", ACTION, "frames", f0, f1, "fps", fps)


def bone(name):
    pb = arm.pose.bones
    return pb.get(name) or next((b for b in pb if b.name.split(":")[-1] == name), None)


tip_bone, tip_off = None, None
if TIP:
    tip_bone = bone(TIP.split(":")[0])
    tip_off = Vector([float(v) for v in TIP.split(":")[1].split(",")])
    TRACK.append("Tip")


def point(name):
    if name == "Tip":
        return arm.matrix_world @ tip_bone.matrix @ tip_off
    b = bone(name)
    if b:
        return arm.matrix_world @ b.head
    return bpy.data.objects[name].matrix_world.translation.copy()


def cog():
    total, acc = 0.0, Vector()
    for name, m in MASS.items():
        b = bone(name)
        if b:
            acc += (arm.matrix_world @ ((b.head + b.tail) * 0.5)) * m
            total += m
    return acc / total


def foot_points(side):
    f, t = bone(side + "Foot"), bone(side + "ToeBase")
    ankle = arm.matrix_world @ f.head
    toe = arm.matrix_world @ (t.head if t else f.tail)
    end = arm.matrix_world @ (t.tail if t else f.tail)
    return ankle, toe, end


# ------------------------------------------------------------------ sample
frames = list(range(f0, f1 + 1))
track = {n: [] for n in TRACK}
cogs, feet = [], {"Left": [], "Right": []}
for f in frames:
    scene.frame_set(f)
    bpy.context.view_layer.update()
    for n in TRACK:
        track[n].append(point(n))
    cogs.append(cog())
    for s in feet:
        feet[s].append(foot_points(s))
floor = min(min(p[2].z, p[1].z) for s in feet for p in feet[s])
ankle_low = {s: min(p[0].z for p in feet[s]) for s in feet}


def planted(side, i):
    ankle, toe, end = feet[side][i]
    return toe.z - floor < 0.04


def flat(side, i):
    """Whole sole down; otherwise a planted foot is on its ball, heel raised."""
    return planted(side, i) and feet[side][i][0].z - ankle_low[side] < 0.05


def hull(pts):
    pts = sorted(set((round(p[0], 4), round(p[1], 4)) for p in pts))
    if len(pts) < 3:
        return pts
    def half(seq):
        h = []
        for p in seq:
            while len(h) >= 2 and ((h[-1][0] - h[-2][0]) * (p[1] - h[-2][1]) - (h[-1][1] - h[-2][1]) * (p[0] - h[-2][0])) <= 0:
                h.pop()
            h.append(p)
        return h[:-1]
    return half(pts) + half(reversed(pts))


def support(i):
    pts = []
    for s in feet:
        if planted(s, i):
            ankle, toe, end = feet[s][i]
            fwd = (Vector((end.x - ankle.x, end.y - ankle.y)).normalized()) if (end - ankle).length > 1e-4 else Vector((0, -1))
            side = Vector((-fwd.y, fwd.x)) * 0.045
            heel = (Vector((ankle.x, ankle.y)) - fwd * 0.06) if flat(s, i) else Vector((toe.x, toe.y))
            tip = Vector((end.x, end.y))
            pts += [heel + side, heel - side, tip + side, tip - side]
    return hull(pts)


def margin(poly, p):
    """+ distance inside the polygon, - distance outside, metres."""
    if len(poly) < 3:
        return None
    best, inside = 1e9, True
    for a, b in zip(poly, poly[1:] + poly[:1]):
        a, b = Vector(a), Vector(b)
        e, w = b - a, Vector(p) - a
        if e.x * w.y - e.y * w.x < 0:
            inside = False
        t = max(0.0, min(1.0, w.dot(e) / max(e.length_squared, 1e-9)))
        best = min(best, (w - e * t).length)
    return best if inside else -best


# ------------------------------------------------------------------ report
def speeds(pts):
    v = [0.0] + [(pts[i] - pts[i - 1]).length * fps for i in range(1, len(pts))]
    return v


sp = {n: speeds(track[n]) for n in TRACK}
lines = ["%s  frames %d-%d  %d fps  (%.2f s)" % (ACTION, f0, f1, fps, (f1 - f0) / fps), "",
         "frame  balance_cm  L R   slideL slideR(cm)  " + "  ".join("%9s" % n[:9] for n in TRACK) + "   (m/s)"]
for i, f in enumerate(frames):
    poly = support(i)
    m = margin(poly, (cogs[i].x, cogs[i].y))
    slide = []
    for s in ("Left", "Right"):
        if i and planted(s, i) and planted(s, i - 1):
            d = feet[s][i][1] - feet[s][i - 1][1]
            slide.append("%6.1f" % (Vector((d.x, d.y)).length * 100))
        else:
            slide.append("     -")
    lines.append("%5d  %10s  %s %s   %s %s      %s" % (
        f, "  no feet" if m is None else "%+10.1f" % (m * 100),
        *[("F" if flat(s, i) else "b") if planted(s, i) else "." for s in ("Left", "Right")],
        slide[0], slide[1], "  ".join("%9.2f" % sp[n][i] for n in TRACK)))
lines += ["", "chain order (start = first frame above 15% of its own peak, stop = last frame above it):",
          "%-12s %6s %6s %6s %9s" % ("point", "start", "peak", "stop", "peak m/s")]
for n in sorted(TRACK, key=lambda n: int(np.argmax(sp[n]))):
    v = np.array(sp[n])
    if v.max() < 1e-4:
        continue
    on = np.where(v > 0.15 * v.max())[0]
    lines.append("%-12s %6d %6d %6d %9.2f" % (n, frames[on[0]], frames[int(v.argmax())], frames[on[-1]], v.max()))
hz = [c.z for c in cogs]
lines += ["", "CoG height: start %.3f  min %.3f (frame %d)  max %.3f (frame %d)  end %.3f" % (
    hz[0], min(hz), frames[int(np.argmin(hz))], max(hz), frames[int(np.argmax(hz))], hz[-1])]
open(os.path.join(OUT, "report.txt"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))

# ------------------------------------------------------------------ overlays
def material_free(obj, color):
    obj.color = color
    obj.data.materials.clear()


def make_mesh(name, verts, faces, color):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    ob.color = color
    return ob


def dots(name, pts, color, r=0.012):
    bm = bmesh.new()
    for p in pts:
        bmesh.ops.create_icosphere(bm, subdivisions=1, radius=r, matrix=Matrix.Translation(p))
    for a, b in zip(pts, pts[1:]):
        d = b - a
        if d.length > 1e-5:
            m = Matrix.Translation((a + b) / 2) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
            bmesh.ops.create_cone(bm, segments=5, radius1=r * 0.3, radius2=r * 0.3, depth=d.length, matrix=m)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    scene.collection.objects.link(ob)
    ob.color = color
    return ob


for o in scene.objects:
    if o.type == "MESH":
        o.color = (0.62, 0.62, 0.66, 1)
trails = [dots("trail_" + n, track[n], COLORS[k % len(COLORS)]) for k, n in enumerate(TRACK)]
cog_trail = dots("trail_cog", cogs, (0, 0, 0, 1), 0.008)
trails.append(cog_trail)
blade = None
if tip_bone:
    blade = make_mesh("blade", [(0, 0, 0)] * 8, [], (0.85, 0.85, 0.9, 1))
balance_objs = []


def set_balance(i):
    for o in balance_objs:
        bpy.data.objects.remove(o, do_unlink=True)
    balance_objs.clear()
    poly = support(i)
    z = floor + 0.004
    if len(poly) >= 3:
        balance_objs.append(make_mesh("support", [(p[0], p[1], z) for p in poly], [list(range(len(poly)))], (0.1, 0.8, 0.2, 1)))
    c = cogs[i]
    m = margin(poly, (c.x, c.y))
    col = (0.1, 0.3, 1, 1) if (m is not None and m >= 0) else (1, 0.05, 0.05, 1)
    balance_objs.append(dots("plumb", [c, Vector((c.x, c.y, floor))], col, 0.02))
    if blade:
        a = arm.matrix_world @ tip_bone.matrix @ Vector((0, 0, 0))
        b = arm.matrix_world @ tip_bone.matrix @ tip_off
        bm = bmesh.new()
        d = b - a
        mtx = Matrix.Translation((a + b) / 2) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
        bmesh.ops.create_cone(bm, segments=6, radius1=0.012, radius2=0.004, depth=d.length, matrix=mtx)
        bm.to_mesh(blade.data)
        bm.free()


ground = make_mesh("ground", [(-6, -6, floor), (6, -6, floor), (6, 6, floor), (-6, 6, floor)], [[0, 1, 2, 3]], (0.86, 0.86, 0.84, 1))

# ------------------------------------------------------------------ render
scene.render.engine = "BLENDER_WORKBENCH"
sh = scene.display.shading
sh.light = "STUDIO"
sh.color_type = "OBJECT"
sh.show_shadows = False
sh.show_cavity = True
scene.display.render_aa = "5"
scene.render.film_transparent = True
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "Standard"
scene.render.resolution_x, scene.render.resolution_y = CELL
scene.render.resolution_percentage = 100
cam = bpy.data.objects.new("look_cam", bpy.data.cameras.new("look_cam"))
scene.collection.objects.link(cam)
scene.camera = cam
cam.data.type = "ORTHO"
allp = [p for n in TRACK for p in track[n]] + cogs
lo = Vector((min(p.x for p in allp), min(p.y for p in allp), floor))
hi = Vector((max(p.x for p in allp), max(p.y for p in allp), max(max(p.z for p in allp), floor + 1.9)))
centre = (lo + hi) / 2
span = max(hi.z - lo.z, hi.x - lo.x, hi.y - lo.y) + 0.5
cam.data.ortho_scale = span * max(1.0, CELL[0] / CELL[1]) * (CELL[1] / CELL[0] if CELL[1] > CELL[0] else 1.0) * 1.0
cam.data.ortho_scale = span * (CELL[0] / CELL[1]) if CELL[0] > CELL[1] else span
cam.data.clip_end = 100
# The character faces -Y (glTF +Z). Eye directions from the centre.
VIEWS = [("front", Vector((0, -1, 0.0))), ("side", Vector((1, 0, 0.0))),
         ("3/4", Vector((0.8, -1, 0.45))), ("top", Vector((0, -0.001, 1)))]


def render(view_dir, path):
    d = view_dir.normalized()
    cam.location = centre + d * 20
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    img = bpy.data.images.load(path)
    px = np.array(img.pixels[:], dtype=np.float32).reshape(img.size[1], img.size[0], 4)[::-1]
    bpy.data.images.remove(img)
    return px


FONT = {"0": "111101101101111", "1": "010110010010111", "2": "111001111100111", "3": "111001111001111",
        "4": "101101111001001", "5": "111100111001111", "6": "111100111101111", "7": "111001001001001",
        "8": "111101111101111", "9": "111101111001111", "/": "001001010100100", " ": "0" * 15,
        "f": "011100110100100", "s": "011100010001110", "t": "010111010010011", "o": "000010101101010",
        "p": "000110101110100", "i": "010000010010010", "d": "001001011101011", "e": "010101111100011",
        "r": "000110101100100", "n": "000110101101101", "3": "111001111001111"}


def stamp(img, text, x, y, s=3, color=(0, 0, 0)):
    for ch in text:
        g = FONT.get(ch, FONT[" "])
        for r in range(5):
            for c in range(3):
                if g[r * 3 + c] == "1":
                    img[y + r * s:y + (r + 1) * s, x + c * s:x + (c + 1) * s, :3] = color
        x += 4 * s


def flatten(px, bg=(0.93, 0.93, 0.91)):
    a = px[..., 3:4]
    return px[..., :3] * a + np.array(bg, dtype=np.float32) * (1 - a)


def save(arr, name):
    arr = np.clip(arr, 0, 1)
    h, w = arr.shape[:2]
    out = np.ones((h, w, 4), dtype=np.float32)
    out[..., :3] = arr
    img = bpy.data.images.new(name, w, h, alpha=False)
    img.pixels.foreach_set(out[::-1].ravel())
    img.filepath_raw = os.path.join(os.path.abspath(OUT), name)
    img.file_format = "PNG"
    img.save()
    print("WROTE", img.filepath_raw)


if FRAMES:
    picks = [int(v) for v in FRAMES.split(",")]
else:
    picks = [int(round(f0 + (f1 - f0) * k / (COUNT - 1))) for k in range(COUNT)]
tmp = os.path.join(os.path.abspath(OUT), "_cell.png")
W, H = CELL
sheet = np.ones((H * len(VIEWS), W * len(picks), 3), dtype=np.float32)
sil = np.ones_like(sheet)
for t in trails:
    t.hide_render = True
for c, f in enumerate(picks):
    scene.frame_set(f)
    bpy.context.view_layer.update()
    set_balance(frames.index(f))
    for r, (vname, vdir) in enumerate(VIEWS):
        ground.hide_render = False
        px = render(vdir, tmp)
        cell = flatten(px)
        stamp(cell, "f%d %s" % (f, vname.replace("3/4", "3/4")), 6, 6)
        sheet[r * H:(r + 1) * H, c * W:(c + 1) * W] = cell
        ground.hide_render = True
        for o in balance_objs:
            o.hide_render = True
        px = render(vdir, tmp)
        for o in balance_objs:
            o.hide_render = False
        s = np.ones((H, W, 3), dtype=np.float32)
        s[px[..., 3] > 0.5] = 0.0
        stamp(s, "f%d" % f, 6, 6, color=(0.5, 0.5, 0.5))
        sil[r * H:(r + 1) * H, c * W:(c + 1) * W] = s
        sheet[r * H:(r + 1) * H, c * W] = 0.6
        sil[r * H:(r + 1) * H, c * W] = 0.6
save(sheet, "poses.png")
save(sil, "silhouette.png")

# trails: body at the frame of the fastest tracked point, every path on top.
for t in trails:
    t.hide_render = False
ground.hide_render = False
peak = frames[int(np.argmax(sp["Tip"] if "Tip" in sp else sp[TRACK[0]]))]
scene.frame_set(peak)
bpy.context.view_layer.update()
set_balance(frames.index(peak))
for o in scene.objects:
    if o.type == "MESH" and o not in trails and o is not ground and o not in balance_objs and o is not blade:
        o.color = (0.75, 0.75, 0.78, 1)
scene.render.resolution_x, scene.render.resolution_y = W * 2, H * 2
big = np.ones((H * 2, W * 2 * len(VIEWS), 3), dtype=np.float32)
for r, (vname, vdir) in enumerate(VIEWS):
    cell = flatten(render(vdir, tmp))
    stamp(cell, "f%d %s" % (peak, vname), 8, 8, s=4)
    big[:, r * W * 2:(r + 1) * W * 2] = cell
save(big, "trails.png")
os.remove(tmp)
print("LOOK done; trail colours in track order:", ", ".join(TRACK), "+ black = centre of gravity")
