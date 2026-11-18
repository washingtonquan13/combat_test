extends AiTestCase
## A body's grips, casting hand, head and sheaths are built from its kind's
## socket profile (data/sockets/humanoid.tres) on its own bones, not placed
## by hand per model, so a new body gets them by having the bones.
##
## 1. NOTHING MOVED. The hero's grips, which used to be hand-placed nodes,
##    are built exactly where those were.
## 2. EACH BODY ITS OWN. On the hero and the townsperson every socket rides
##    the bone it names, and every sheath sits on that body's skin, however
##    broad or narrow it is.
## 3. ONLY ITS KIND. A dragon has none of the humanoid bones and gets none.

const OLD_MAIN_GRIP := Transform3D(Basis(Vector3(0, 0, 1), Vector3(0.94, -0.342, 0), Vector3(0.342, 0.94, 0)), Vector3(0, 0.085, 0.035))
const RIDES := {
	&"main_hand_grip": &"RightHand", &"off_hand_grip": &"LeftHand",
	&"hand_anchor": &"RightMiddleProximal", &"head_anchor": &"Head",
	&"back_sheath_a": &"UpperChest", &"back_sheath_b": &"UpperChest",
	&"hip_sheath_main": &"Hips", &"hip_sheath_off": &"Hips",
}
const SHEATHS: Array[StringName] = [&"back_sheath_a", &"back_sheath_b", &"hip_sheath_main", &"hip_sheath_off"]
const ON_SKIN: float = 0.02


func run() -> void:
	for scene in ["proof_hero_model", "townsperson_model"]:
		var model: CharacterModel = _add(scene)
		var skeleton: Skeleton3D = model._find_skeleton(model)
		if scene == "proof_hero_model":
			var grip: Node3D = model.main_hand_grip
			check("hero grip where the hand-placed one was", grip != null
				and grip.transform.origin.distance_to(OLD_MAIN_GRIP.origin) < 0.001
				and grip.transform.basis.x.distance_to(OLD_MAIN_GRIP.basis.x) < 0.001,
				str(grip.transform) if grip else "missing")
		for socket: StringName in RIDES:
			var node: Node3D = model.get(socket)
			var attachment := node.get_parent() as BoneAttachment3D if node else null
			check("%s %s rides %s" % [scene, socket, RIDES[socket]],
				attachment != null and attachment.bone_name == RIDES[socket],
				str(attachment.bone_name) if attachment else "missing")
		var skin: Array[PackedVector3Array] = model._skin_at_rest(skeleton)
		for socket: StringName in SHEATHS:
			var node: Node3D = model.get(socket)
			if node == null:
				check("%s %s on its skin" % [scene, socket], false, "missing")
				continue
			var attachment := node.get_parent() as BoneAttachment3D
			var at: Vector3 = (skeleton.get_bone_global_rest(skeleton.find_bone(attachment.bone_name)) * node.transform).origin
			var nearest: float = INF
			for vertices in skin:
				for v: Vector3 in vertices:
					nearest = minf(nearest, v.distance_to(at))
			check("%s %s on its skin" % [scene, socket], nearest < ON_SKIN, "%.3f m off" % nearest)
		model.queue_free()

	var dragon: CharacterModel = _add("dragon_model")
	check("a dragon gets no humanoid sockets",
		dragon.main_hand_grip == null and dragon.back_sheath_a == null, "")
	dragon.queue_free()
	await get_tree().process_frame


func _add(scene: String) -> CharacterModel:
	var model: CharacterModel = load("res://scenes/character_models/%s.tscn" % scene).instantiate()
	add_child(model)
	return model
