extends "res://tools/ring_decal_demo.gd"
## Recorded showcase of the unit-control indicators after Tiers 2-3 - NOT
## a test. Real synthetic mouse: path ribbon + readout, a move order's
## marker, a refused click, walls fading in front of the hero, and the
## x-ray silhouette. Record WITHOUT opengl3 (decals need Forward+).


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var camera: CRPGCamera = _camera()
	_frame(_spot(-3.0, 0.0), 9.0)
	await _wait(2.0)

	_say("Hover the ground: path ribbon, stop ring, distance readout")
	await _glide(_screen(_spot(-5.0, 1.5)), 0, 40)
	await _wait(1.0)
	await _glide(_screen(_spot(-7.0, -2.0)), 0, 50)
	await _wait(2.0)

	_say("Click: the move marker pops at the destination")
	await _click(_screen(_spot(-6.0, 0.0)))
	await _wait(3.0)

	_say("A refused click: red marker and the reason")
	var box_at: Vector3 = _spot(-3.0, 3.5)
	_box(box_at + Vector3(0.0, 1.5, 0.0), Vector3(1.2, 3.0, 1.2))
	await _wait(0.5)
	await _click(_screen(box_at + Vector3(0.0, 3.0, 0.0)))
	await _wait(1.0)
	var feedback: ClickFeedback = get_tree().root.find_children("*", "ClickFeedback", true, false)[0]
	feedback.refuse(_spot(-30.0, 0.0), "Can't move there")
	await _wait(2.5)

	_say("A wall between camera and hero fades out")
	_frame(_hero.global_position + Vector3(0.0, 1.0, 0.0), 9.0)
	camera.target_yaw = camera.current_yaw
	await _wait(2.0)
	var wall_at: Vector3 = _hero.global_position + (camera.global_position - _hero.global_position) * Vector3(1, 0, 1) * 0.35
	var wall := _solid(wall_at + Vector3(0.0, 1.75, 0.0), Vector3(5.0, 3.5, 0.4))
	wall.look_at(Vector3(_hero.global_position.x, wall.global_position.y, _hero.global_position.z))
	await _wait(4.0)

	_say("Fade off: the hero shows as a blue silhouette through the wall")
	await _wait(4.0)
	get_tree().quit()


func _camera() -> CRPGCamera:
	return get_tree().root.find_children("*", "CRPGCamera", true, false)[0]


func _screen(point: Vector3) -> Vector2:
	return _camera().unproject_position(point)


func _solid(center: Vector3, size: Vector3) -> CSGBox3D:
	var box := CSGBox3D.new()
	box.size = size
	box.use_collision = true
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.42, 0.38)
	box.material = material
	WorldManager.spawn_parent().add_child(box)
	box.global_position = center
	return box
