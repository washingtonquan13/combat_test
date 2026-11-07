extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase of moving a box, part 2 — NOT a test. Real synthetic
## mouse: pick the crate up, turn it with the wheel, set it down (the
## mover raises a hand), then save, load, and the crate is still there.

const SLOT: String = "box_drag_demo"


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	var box: MovableProp = _find_box()
	var camera: Camera3D = box.get_viewport().get_camera_3d()
	_frame(box.global_position.lerp(_hero.global_position, 0.5), 8.0)
	await _wait(2.0)
	var screen := func(p: Vector3) -> Vector2: return camera.unproject_position(p)
	var start: Vector3 = box.global_position
	var open: Vector3 = _hero.global_position + Vector3(-2.5, 0, 1.0)

	_say("Press on the crate and drag it out")
	await _glide(screen.call(start), 0)
	await _wait(0.5)
	_button(MOUSE_BUTTON_LEFT, true)
	await get_tree().process_frame
	await _glide(screen.call(open), MOUSE_BUTTON_MASK_LEFT, 40)
	await _wait(0.8)
	_say("Mouse wheel turns it, 15 degrees a notch")
	for i in 6:
		_wheel(MOUSE_BUTTON_WHEEL_UP)
		await _wait(0.35)
	await _wait(0.6)
	_say("...and back the other way")
	for i in 3:
		_wheel(MOUSE_BUTTON_WHEEL_DOWN)
		await _wait(0.35)
	await _wait(0.8)
	_say("Release: the hero raises a hand and it flies there, turned")
	_button(MOUSE_BUTTON_LEFT, false)
	await _wait(2.5)
	var put: Transform3D = box.global_transform
	_check("the crate moved", put.origin.distance_to(start) > 1.0)

	_say("Save the game")
	await _wait(1.0)
	_check("saved", SaveManager.save("box demo", SLOT))
	await _wait(1.0)
	_say("Load it again")
	await _wait(1.0)
	_check("loaded", SaveManager.load_file(SaveManager.slot_path(SLOT)))
	for i in 30:
		await get_tree().process_frame
	box = _find_box()
	camera = box.get_viewport().get_camera_3d()
	_frame(box.global_position.lerp(PartyManager.leader.global_position, 0.5), 8.0)
	_say("After the load the crate is still where it was put, still turned")
	await _wait(3.0)
	_check("position kept", box.global_position.distance_to(put.origin) < 0.01)
	_check("turn kept", box.global_basis.is_equal_approx(put.basis))
	SaveManager.delete_save(SaveManager.slot_path(SLOT))
	get_tree().quit()


func _find_box() -> MovableProp:
	for n in get_tree().root.find_children("*", "StaticBody3D", true, false):
		if n is MovableProp and n.is_inside_tree():
			return n
	return null


func _wheel(index: MouseButton) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = _mouse
		event.global_position = _mouse
		event.button_index = index
		event.pressed = pressed
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(event)
