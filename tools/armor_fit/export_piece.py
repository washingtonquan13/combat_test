"""Export fitted pieces (Armor_<KEEP>*, both sides) with the armature, in rest, as a skinned GLB. KEEP may be a
comma list (cuirass,belt,upsleeve) to put several pieces in one file, for an item that is a whole outfit.
blender -b OUTPREFIX.blend --python export_piece.py -- KEEP OUT.glb"""
import bpy, sys
out, keep = sys.argv[-1], tuple("Armor_" + k for k in sys.argv[-2].split(","))
arm = bpy.data.objects["Armature"]
for o in list(bpy.data.objects):
    if o.name != "Armature" and not o.name.startswith(keep):
        bpy.data.objects.remove(o)
arm.data.pose_position = "REST"
bpy.ops.object.select_all(action="DESELECT")
arm.select_set(True); bpy.context.view_layer.objects.active = arm
# Armature now shares the body's frame (scale 0.01, no rotation); bake it so bones and armour share world metres.
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for o in [o for o in bpy.data.objects if o.name.startswith("Armor_")]:
    assert o.matrix_world == o.matrix_world.Identity(4), (o.name, o.matrix_world)
    o.parent = arm; o.matrix_parent_inverse.identity()
    print("PIECE", o.name, len(o.data.vertices), len(o.vertex_groups), [m.type for m in o.modifiers])
print("HIP", arm.data.bones["CC_Base_Hip"].head_local, "HEAD", arm.data.bones["CC_Base_Head"].head_local)
arm.data.pose_position = "POSE"
bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", use_selection=False, export_apply=True, export_skins=True,
    export_animations=False, export_morph=False, export_yup=True, export_image_format="JPEG", export_jpeg_quality=90)
print("EXPORTED", out)
