extends SceneTree

# Prints joint positions (model space, metres; +Z forward, +X character left)
# for the flight clips, to check poses without eyeballing renders.

func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var model: Node3D = load("res://scenes/character_models/placeholder_model.tscn").instantiate()
	root.add_child(model)
	var player: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	var sk: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	player.add_animation_library("Flight", load("res://assets/flight_animations.tres"))
	for spec in [["Idle", 0.0], ["Flight/Hover", 0.0], ["Flight/Fly_Fwd", 0.0], ["Flight/Takeoff", 0.18], ["Flight/Takeoff", 0.36]]:
		player.play(spec[0])
		player.seek(spec[1], true)
		player.pause()
		await process_frame
		print("== %s @ %.2f" % spec)
		for b in ["Hips", "Head", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes", "RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes", "LeftUpperArm", "LeftHand", "RightUpperArm", "RightHand"]:
			var p := sk.get_bone_global_pose(sk.find_bone(b)).origin
			print("  %-14s x=%6.2f y=%6.2f z=%6.2f" % [b, p.x, p.y, p.z])
	quit()
