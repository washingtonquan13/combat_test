extends SceneTree
## Bakes the hover outline for a character baked by bake_character.py.
##
##   Godot --headless --path . -s res://tools/characters/bake_outline.gd -- \
##       res://assets/characters/<name>/<name>.glb
##
## CharacterModel.outline_mesh is ONE mesh drawn as an inflated hull behind
## the body. A placeholder mannequin is one mesh already; an MPFB human is a
## body plus a mesh per part. This joins the parts that make the silhouette
## (body, clothes, shoes, hair) into one surface, with no blend shapes, and
## writes it beside the glb as <name>_outline.mesh, along with the skin the
## parts share (<name>_outline_skin.tres), which the outline MeshInstance3D
## needs to follow the skeleton. Eyes, brows, lashes, teeth and tongue sit
## inside or flat on the head and add nothing to the silhouette. Groomed hair
## cards are skipped too: the hull baked over them stands in for them.
##
## Rerun it whenever the glb is rebaked.

const INSIDE_THE_HEAD: Array[String] = ["eye_occlusion", "eyebrow", "eyelash", "groom", "high-poly", "tearline", "teeth", "tongue"]


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("bake_outline: give the character's .glb path")
		quit(1)
		return
	var glb: String = args[0]
	var root: Node = (load(glb) as PackedScene).instantiate()
	var tool := SurfaceTool.new()
	var skin: Skin = null
	var joined: PackedStringArray = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var part := node as MeshInstance3D
		if INSIDE_THE_HEAD.any(func(word: String) -> bool: return word in String(part.name)):
			continue
		if skin == null:
			skin = part.skin
		elif part.skin != skin:
			push_error("bake_outline: %s has its own skin; the parts must share one" % part.name)
			quit(1)
			return
		for surface in part.mesh.get_surface_count():
			tool.append_from(part.mesh, surface, part.transform)
		joined.append(part.name)
	var outline: ArrayMesh = tool.commit()
	var base: String = glb.get_basename()
	ResourceSaver.save(outline, base + "_outline.mesh")
	ResourceSaver.save(skin, base + "_outline_skin.tres")
	print("bake_outline: joined ", ", ".join(joined), " -> ", outline.surface_get_array_len(0), " verts")
	root.free()
	quit()
