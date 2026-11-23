extends "res://tools/dragon_anims_demo.gd"
## Recorded check that Fire Breath leaves the SM 6 dragon's mouth - NOT a
## test. Side on, close on the head: level, then aimed down at the ground.


var _snout: Node3D


func _attacks() -> void:
	var skel: Skeleton3D = _dragon.find_children("Skeleton3D", "Skeleton3D", true, false)[0]
	var bone := BoneAttachment3D.new()
	bone.bone_name = "head"
	skel.add_child(bone)
	_snout = Node3D.new()
	bone.add_child(_snout)
	_snout.position = Vector3(0, 0.275, 0.159)
	_marker(_snout, Color.GREEN)
	_marker(_dragon.get_node("CharacterModel").mouth_anchor, Color.RED)
	var cone := Breath.targeting as ConeTargeting
	var mouth: Vector3 = _dragon.anchor(CharacterModel.Anchor.MOUTH)
	var head_shot: Vector3 = _dragon.global_position + _dragon.visual_forward() * 9.0 + Vector3(0, 2.0, 0)
	for aim in [["level", 3.0, true], ["down at the ground", 1.0, false]]:
		var ahead: Vector3 = _dragon.global_position + _dragon.visual_forward() * (cone.length * aim[1] + 6.0)
		var point: Vector3 = Breath.targeting.resolve_target_point(ahead) if aim[2] else ahead
		var apex: Vector3 = cone.origin(_dragon, point)
		_check("the cone starts at the mouth (%s)" % aim[0], apex.distance_to(mouth) < 0.05)
		print("BREATH ", aim[0], " apex ", apex, " mouth ", mouth, " body ", _dragon.global_position)
		_frame(head_shot, 13.0)
		_look_side()
		await _wait(2.0)
		_say("Fire Breath, %s: the cone leaves its mouth" % aim[0])
		_dragon.reset_turn_actions()
		_dragon.use_ability(Breath, point)
		var t := 0.0
		while _clip() != &"Breath_Out" and t < 6.0:
			var model: Node3D = _dragon.get_node("CharacterModel")
			if false: print("SNOUT ", aim[0], " %.2f %s %s" % [t, _clip(), model.global_transform.affine_inverse() * _snout.global_position])
			await _wait(0.1)
			t += 0.1
		await _wait(3.0)


func _marker(parent: Node3D, color: Color) -> void:
	var m := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.025
	sphere.height = 0.05
	m.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	m.material_override = mat
	parent.add_child(m)
