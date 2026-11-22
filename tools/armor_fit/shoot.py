"""Render a fitted .blend: front/side/back, then posed with and without the armour.
blender -b OUTPREFIX.blend --python shoot.py -- SHOTPREFIX"""
import bpy, math, sys
from mathutils import Vector, Matrix

OUT = sys.argv[-1]
sc = bpy.context.scene; cam = sc.camera
arm = bpy.data.objects["Armature"]
sc.render.engine = "BLENDER_WORKBENCH"
sh = sc.display.shading
sh.light = "STUDIO"; sh.color_type = "TEXTURE"; sh.show_shadows = True; sh.show_cavity = True
sh.background_type = "VIEWPORT"; sh.background_color = (0.35, 0.38, 0.42)
sc.render.film_transparent = False
sc.render.resolution_x, sc.render.resolution_y = 900, 1100
for o in bpy.data.objects:
    if o.type == "MESH" and o.name in ("Gambeson", "PaddedPants"):
        o.hide_render = False


# World-axis rotations about each bone's head (FBX bone rolls make local Euler angles meaningless). Front is -Y.
POSE = (("CC_Base_L_Upperarm", (0, 1, 0), 50), ("CC_Base_L_Forearm", (0, 0, 1), -45), ("CC_Base_R_Upperarm", (0, 1, 0), -55),
        ("CC_Base_R_Thigh", (1, 0, 0), -40), ("CC_Base_R_Calf", (1, 0, 0), 55), ("CC_Base_Spine02", (0, 0, 1), 15))


def pose_world(name, axis, deg):
    pb = arm.pose.bones[name]; bpy.context.view_layer.update()
    M = arm.matrix_world @ pb.matrix; h = M.to_translation()
    R = Matrix.Translation(h) @ Matrix.Rotation(math.radians(deg), 4, Vector(axis)) @ Matrix.Translation(-h)
    pb.matrix = arm.matrix_world.inverted() @ R @ M


def shoot(tag, ang, el, c=(0, 0, 0.95), scale=2.0):
    c = Vector(c); t = math.radians(ang); e = math.radians(el)
    cam.location = c + Vector((math.sin(t) * math.cos(e), -math.cos(t) * math.cos(e), math.sin(e))) * 4
    cam.rotation_euler = (c - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.type = "ORTHO"; cam.data.ortho_scale = scale
    sc.render.filepath = OUT + "_" + tag + ".png"; bpy.ops.render.render(write_still=True)


shoot("front", 0, 5); shoot("side", 90, 5); shoot("back", 180, 5)
# The armature object carries a -90 X rotation the meshes don't, so its bones sit off the body in world space
# (hip at y=-1). Rest deform is identity either way; posing is not. Put the armature in the body's frame.
kids = {o: o.matrix_world.copy() for o in arm.children_recursive}
arm.matrix_world = bpy.data.objects["CC_Base_Body"].matrix_world.copy()
bpy.context.view_layer.update()
for o, mw in kids.items():
    o.matrix_world = mw
bpy.context.view_layer.update()
print("HIPW", tuple(round(x, 3) for x in arm.matrix_world @ arm.pose.bones["CC_Base_Hip"].head))
for name, axis, deg in POSE:
    pose_world(name, axis, deg)
bpy.context.view_layer.update()
shoot("posed", 35, 15)
# Same pose, bare body (mask off): the reference the garments must follow.
for o in bpy.data.objects:
    if o.type == "MESH" and (o.name.startswith("Armor_") or o.name in ("Gambeson", "PaddedPants")):
        o.hide_render = True
for m in bpy.data.objects["CC_Base_Body"].modifiers:
    if m.type == "MASK":
        m.show_render = False
shoot("posedbare", 35, 15)
print("RENDERED")
