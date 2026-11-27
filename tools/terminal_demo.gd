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
	if OS.get_environment("TERMINAL_FACE") == "vt323":
		terminal.face = TerminalScreen.Face.VT323
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
		if i == 2:
			await _snap("3b_scrolling")  # mid-glide: the phosphor trail
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
	if not OS.get_environment("TERMINAL_SNAPS").is_empty():
		await _night_stills(terminal)
	get_tree().quit()


## The arena is in daylight, which drowns the screen's green spill. With
## the sun off and the sky turned down, stills of the same walk-up show it.
## Stills only, no checks; the arena is put back afterwards.
func _night_stills(terminal: Terminal) -> void:
	var suns: Array[Node] = get_tree().root.find_children("*", "DirectionalLight3D", true, false)
	var sun_was: Array[bool] = []
	for sun: DirectionalLight3D in suns:
		sun_was.append(sun.visible)
		sun.visible = false
	var env: Environment = terminal.get_world_3d().environment
	var env_was := Vector2.ZERO
	if env:
		env_was = Vector2(env.background_energy_multiplier, env.ambient_light_energy)
		env.background_energy_multiplier = 0.04
		env.ambient_light_energy = 0.04
	await _wait(0.5)
	await _snap("6_night_idle")
	terminal.use()
	await _wait(0.35)
	await _snap("7_night_gliding")
	await _wait(2.5)
	await _snap("8_night_reading")
	# What the glass and its light cost, measured at the reading view where
	# the glass fills the screen.
	var world_vp := terminal.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(world_vp, true)
	var light: Light3D = terminal.get_node("Screen/ScreenLight")
	var glass: MeshInstance3D = terminal.get_node("Screen")
	var with_all := await _gpu_ms(world_vp)
	light.visible = false
	var no_light := await _gpu_ms(world_vp)
	glass.visible = false
	var no_glass := await _gpu_ms(world_vp)
	light.visible = true
	glass.visible = true
	RenderingServer.viewport_set_measure_render_time(world_vp, false)
	print("GPU ms (world view, reading): all %.3f  no light %.3f  no light+glass %.3f" % [with_all, no_light, no_glass])
	# From the side, to see the spill on the desk and the hero.
	var reading_view := terminal.get_viewport().get_camera_3d()
	var side := Camera3D.new()
	terminal.add_child(side)
	side.global_position = terminal.to_global(Vector3(1.4, 1.5, 1.6))
	side.look_at(terminal.to_global(Vector3(0.0, 0.9, 0.4)))
	side.make_current()
	await _wait(0.2)
	await _snap("9_night_side")
	reading_view.make_current()
	side.queue_free()
	terminal.step_away()
	await _wait(1.5)
	for i in suns.size():
		suns[i].visible = sun_was[i]
	if env:
		env.background_energy_multiplier = env_was.x
		env.ambient_light_energy = env_was.y


func _gpu_ms(vp: RID, frames := 90) -> float:
	for i in 10:
		await RenderingServer.frame_post_draw
	var total := 0.0
	for i in frames:
		await RenderingServer.frame_post_draw
		total += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return total / frames


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
