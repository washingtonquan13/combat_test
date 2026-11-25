extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase of breakable props — NOT a test. A crate offers
## Attack on its right-click menu; the hero walks up and hits it until it
## breaks into debris (the nav grid re-bakes where it stood). Then a
## fireball catches two more crates at once.

const BOX: PackedScene = preload("res://systems/interaction_system/movable_box.tscn")
const FIREBALL: Ability = preload("res://data/abilities/explosive_fireball.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	_hero.set_base_stat(StatIds.DX, 16)
	SelectionManager.select(_hero)
	var crate: Node3D = _crate(-3.0, 1.5)
	var camera: Camera3D = _hero.get_viewport().get_camera_3d()
	_frame(crate.global_position.lerp(_hero.global_position, 0.5), 4.5)
	await _wait(2.5)
	var prop: Breakable = Breakable.of(crate)
	_say("A 10 lb crate: %d HP, DR %d. Walk up to it" % [prop.full_hp(), prop.dr])
	_hero.move_to(crate.global_position + (_hero.global_position - crate.global_position).normalized() * 1.0)
	while _hero.is_moving():
		await get_tree().process_frame
	await _wait(0.8)
	_say("Right-click it: Attack is on the menu")
	await _wait(1.0)
	await _glide(camera.unproject_position(prop.aim_point()), 0)
	await _click(camera.unproject_position(prop.aim_point()), MOUSE_BUTTON_RIGHT)
	await _wait(1.2)
	var picked := _pick_menu("Attack")
	_check("the crate's menu offers Attack", picked)
	var full: int = prop.full_hp()
	var left := [full]
	prop.damaged.connect(func(n: int): left[0] = maxi(left[0] - n, 0))
	await _until_idle(8.0)
	_say("Hit: crate at %d/%d HP" % [left[0], full])
	await _wait(1.5)
	var swings := 0
	while is_instance_valid(prop) and prop.is_alive() and swings < 8:
		swings += 1
		_hero.reset_turn_actions()
		await _hero.use_ability(_hero.default_ability(), prop)
		await _until_idle(6.0)
		if is_instance_valid(prop) and prop.is_alive():
			_say("Crate at %d/%d HP" % [prop.hp, prop.full_hp()])
		await _wait(0.8)
	_say("Broken: debris, and the ground it stood on is walkable again")
	_check("the crate broke", not is_instance_valid(crate) or not crate.is_inside_tree())
	await _wait(4.0)

	var a: Node3D = _crate(-7.0, -1.0)
	var b: Node3D = _crate(-7.5, 1.2)
	var middle: Vector3 = a.global_position.lerp(b.global_position, 0.5)
	_frame(middle.lerp(_hero.global_position, 0.25), 6.0)
	_say("Two more crates. A fireball between them catches both")
	await _wait(2.5)
	_hero.reset_turn_actions()
	_hero.set_pool(StatIds.FP, 30)
	var result: Dictionary = await _hero.use_ability(FIREBALL, middle)
	await _until_idle(8.0)
	await _wait(1.0)
	var gone: int = int(not is_instance_valid(a) or not a.is_inside_tree()) + int(not is_instance_valid(b) or not b.is_inside_tree())
	_say("Fireball: %d damage to the crates, %d of 2 broken. The fire left behind keeps burning them" % [result.get("damage", 0), gone])
	_check("the blast reached the crates", gone > 0 or result.get("damage", 0) > 0)
	await _wait(9.0)
	gone = int(not is_instance_valid(a) or not a.is_inside_tree()) + int(not is_instance_valid(b) or not b.is_inside_tree())
	_say("After the fire: %d of 2 broken" % gone)
	await _wait(3.0)
	get_tree().quit()


func _crate(forward: float, side: float) -> Node3D:
	var crate: Node3D = BOX.instantiate()
	WorldManager.spawn_parent().add_child(crate)
	crate.global_position = _spot(forward, side)
	NavigationGrid.invalidate_region(crate, Breakable.of(crate).box())
	return crate


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


func _until_idle(limit: float) -> void:
	var waited := 0.0
	while waited < limit and _hero.is_busy():
		await get_tree().process_frame
		waited += get_process_delta_time()
