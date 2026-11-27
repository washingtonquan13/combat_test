extends "res://tools/item_layer_demo.gd"
## Recorded walkthrough of the terminal — NOT a test. Boots into
## test_arena, sets a terminal down in front of the hero, right-clicks it,
## picks Use, reads, scrolls, and presses Escape to step away.
##
## Set TERMINAL_SNAPS=<dir> to also save stills of each step there.

const TerminalScene: PackedScene = preload("res://systems/terminal_system/terminal.tscn")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	var hero: Unit = PartyManager.leader
	SelectionManager.select(hero)
	var terminal: Terminal = TerminalScene.instantiate()
	WorldManager.spawn_parent().add_child(terminal)
	var ahead := Vector3(-2.5, 0.0, 0.0)
	terminal.global_position = hero.global_position + ahead
	terminal.look_at(hero.global_position, Vector3.UP, true)
	await _wait(1.5)
	await _snap("1_idle")

	_say("Right-click the terminal: Use")
	var camera: Camera3D = hero.get_viewport().get_camera_3d()
	var aim: Vector2 = camera.unproject_position(terminal.global_position + Vector3(0, 0.9, 0))
	await _glide(aim, 0)
	await _click(aim, MOUSE_BUTTON_RIGHT)
	await _wait(1.0)
	_check("the terminal's menu offers Use", _pick_menu("Use"))
	var waited := 0.0
	while Terminal.active == null and waited < 8.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_check("the hero walked up and is at the terminal", Terminal.active == terminal)
	_check("GameMode reports TERMINAL", GameMode.current_mode() == GameMode.Mode.TERMINAL)
	_check("the tactical camera has no control", not CameraDirector.has_control())
	await _wait(0.35)
	await _snap("2_gliding")
	await _wait(2.5)
	await _snap("3_reading")

	_say("Scroll down")
	for i in 6:
		await _scroll_wheel(aim, MOUSE_BUTTON_WHEEL_DOWN)
		await _wait(0.15)
	await _wait(0.6)
	await _snap("4_scrolled")

	_say("Escape steps away")
	var esc_menu: UIScreen = get_tree().get_first_node_in_group("esc_menu")
	_press_escape()
	await _wait(0.2)
	_check("Escape did not also open the esc menu", esc_menu != null and not UIStack.is_open(esc_menu))
	_press_escape()
	await _wait(0.1)
	_check("a second Escape mid-glide did not open it either", not UIStack.is_open(esc_menu))
	await _wait(1.4)
	_check("back from the terminal", Terminal.active == null)
	_check("GameMode back to EXPLORATION", GameMode.current_mode() == GameMode.Mode.EXPLORATION)
	_check("the tactical camera has control again", CameraDirector.has_control())
	await _snap("5_back")
	print("DEMO RESULT: %d/%d passed" % [_passed, _passed + _failed.size()])
	for what in _failed:
		print("  failed: ", what)
	get_tree().quit()


func _pick_menu(label: String) -> bool:
	var popup: PopupMenu = InteractionMenu._popup
	if not popup.visible:
		return false
	for i in popup.item_count:
		if popup.get_item_text(i) == label:
			popup.hide()
			InteractionMenu._on_id_pressed(popup.get_item_id(i))
			return true
	return false


## A real key press, so it takes the same path through WorldView's
## SubViewport that a player's Escape does.
func _press_escape() -> void:
	for pressed in [true, false]:
		var key := InputEventKey.new()
		key.keycode = KEY_ESCAPE
		key.physical_keycode = KEY_ESCAPE
		key.pressed = pressed
		Input.parse_input_event(key)


func _scroll_wheel(at: Vector2, index: MouseButton) -> void:
	for pressed in [true, false]:
		var wheel := InputEventMouseButton.new()
		wheel.button_index = index
		wheel.pressed = pressed
		wheel.position = at
		wheel.global_position = at
		Input.parse_input_event(wheel)
	await get_tree().process_frame


func _snap(tag: String) -> void:
	var out := OS.get_environment("TERMINAL_SNAPS")
	if out.is_empty():
		return
	_caption.visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var path := out.path_join("terminal_%s.png" % tag)
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)
	_caption.visible = true
