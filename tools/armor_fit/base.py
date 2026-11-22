"""A CC base FBX as the .blend fit.py works on: imported in rest, its underwear dropped, a camera for the renders.
blender -b --factory-startup --python base.py -- BODY.fbx OUT.blend"""
import bpy, sys

fbx, out = sys.argv[-2], sys.argv[-1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=fbx)
arm = bpy.data.objects["Armature"]
if arm.animation_data:
    arm.animation_data.action = None
for pb in arm.pose.bones:
    pb.location = (0, 0, 0); pb.rotation_quaternion = (1, 0, 0, 0); pb.rotation_euler = (0, 0, 0); pb.scale = (1, 1, 1)
for o in list(bpy.data.objects):
    if o.name in ("Bra", "Underwear_Bottoms"):
        bpy.data.objects.remove(o)
sc = bpy.context.scene
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam); sc.camera = cam
bpy.context.view_layer.update()
bpy.ops.wm.save_as_mainfile(filepath=out)
print("BASE", out)
