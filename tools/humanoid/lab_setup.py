# Opens the UAL mannequin in an empty Blender scene for the lab and the exporter.

import os
import sys
import bpy
import numpy as np
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import body_rig  # noqa: E402

GLB = os.path.join(PROJECT, "assets", "UAL1_Standard.glb")
WEAPONS = os.path.join(PROJECT, "assets", "weapons")
# scenes/weapons/*.tscn: a Model node's own offset, in Godot axes.
MODEL_OFFSET = {"pistol": (0.0, 0.015, 0.0)}


def open_mannequin():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=GLB)
    for o in [o for o in bpy.data.objects if o.type == "MESH" and o.name != "Mannequin"]:
        bpy.data.objects.remove(o)
    arm = bpy.data.objects["Armature"]
    body = bpy.data.objects["Mannequin"]
    arm.animation_data_create()
    arm.animation_data.action = None
    for track in list(arm.animation_data.nla_tracks):
        arm.animation_data.nla_tracks.remove(track)
    for act in list(bpy.data.actions):
        bpy.data.actions.remove(act)
    return arm, body, body_rig.Rig(arm)


def add_weapon(name):
    """An empty carrying the weapon's meshes, placed by setting matrix_world."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(WEAPONS, name + ".glb"))
    new = set(bpy.data.objects) - before
    holder = bpy.data.objects.new("held_" + name, None)
    bpy.context.scene.collection.objects.link(holder)
    offset = MODEL_OFFSET.get(name, (0, 0, 0))
    inner = Matrix.Translation((offset[0], -offset[2], offset[1]))
    for o in new:
        if o.parent is None:
            o.parent = holder
            o.matrix_parent_inverse = Matrix.Identity(4)
            o.matrix_basis = inner @ o.matrix_basis
        if o.type == "MESH":
            for mat in o.data.materials:
                if mat:
                    mat.diffuse_color = (0.3, 0.36, 0.5, 1.0)
    return holder


class Stage:
    """Clay figure, floor, an orthographic camera, and the weapons a clip names."""

    def __init__(self, arm, body, rig, cell):
        self.arm, self.body, self.rig = arm, body, rig
        self.weapons = {}
        scene = self.scene = bpy.context.scene
        scene.render.engine = "BLENDER_WORKBENCH"
        scene.display.shading.light = "STUDIO"
        scene.display.shading.color_type = "MATERIAL"
        scene.display.shading.show_shadows = True
        scene.display.shading.show_cavity = True
        scene.render.resolution_x = cell
        scene.render.resolution_y = cell
        scene.render.resolution_percentage = 100
        scene.render.image_settings.file_format = "PNG"
        scene.world = scene.world or bpy.data.worlds.new("World")
        scene.world.color = (0.55, 0.6, 0.66)
        for mat in body.data.materials:
            if mat:
                mat.diffuse_color = (0.8, 0.72, 0.58, 1.0)
        bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0, -0.051), scale=(14.0, 14.0, 0.1))
        ground_mat = bpy.data.materials.new("Ground")
        ground_mat.diffuse_color = (0.33, 0.33, 0.35, 1.0)
        bpy.context.active_object.data.materials.append(ground_mat)
        cam_data = bpy.data.cameras.new("Cam")
        cam_data.type = "ORTHO"
        self.cam_data = cam_data
        self.cam = bpy.data.objects.new("Cam", cam_data)
        scene.collection.objects.link(self.cam)
        scene.camera = self.cam

    def warm(self, path):
        self.scene.render.filepath = path
        bpy.ops.render.render(write_still=True)  # the first render shows the rest pose
        os.remove(path)

    def show(self, clip_weapons):
        """clip_weapons: {"r": "iron_sword", "l": "wooden_shield"} or None."""
        wanted = set((clip_weapons or {}).values())
        for name in wanted - set(self.weapons):
            self.weapons[name] = add_weapon(name)
        for name, holder in self.weapons.items():
            hide = name not in wanted
            holder.hide_render = hide
            for child in holder.children_recursive:
                child.hide_render = hide

    def pose(self, pose, clip_weapons):
        self.rig.solve(pose)
        self.rig.apply()
        for side, name in (clip_weapons or {}).items():
            at = self.rig.held.get(side)
            if at is None:  # a hand that lets go keeps riding the hand
                hand = "hand_" + side
                at = self.rig.P[hand] @ self.rig.L[hand].inverted() @ self.rig.grip_rest[side]
            self.weapons[name].matrix_world = at
        bpy.context.view_layer.update()

    def shoot(self, loc, at, scale, path):
        loc, at = Vector(loc), Vector(at)
        self.cam_data.ortho_scale = scale
        self.cam.location = loc
        self.cam.rotation_euler = (at - loc).to_track_quat("-Z", "Y").to_euler()
        bpy.context.view_layer.update()
        self.scene.render.filepath = path
        bpy.ops.render.render(write_still=True)


def read_png(path):
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    return px.reshape(h, w, 4)


def write_sheet(panels, cols, path):
    rows = (len(panels) + cols - 1) // cols
    h, w = panels[0].shape[:2]
    out = np.ones((rows * h, cols * w, 4), dtype=np.float32)
    for i, p in enumerate(panels):
        r, c = i // cols, i % cols
        out[(rows - 1 - r) * h:(rows - r) * h, c * w:(c + 1) * w] = p
    img = bpy.data.images.new("sheet", cols * w, rows * h, alpha=True)
    img.pixels.foreach_set(out.ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
