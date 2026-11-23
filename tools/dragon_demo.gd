extends "res://tools/tier3_demo.gd"
## Recorded showcase of the dragon on its own body - NOT a test. Its own
## skeleton and clips: idle, a move order, Fly, Land, then its MotionSet's
## Bite, Claw and Fire Breath, a hit, Downed and back up, and death.

const Fly: Ability = preload("res://data/abilities/fly.tres")
const Breath: Ability = preload("res://data/abilities/fire_breath.tres")

var _dragon: Unit


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	var camera: CRPGCamera = _camera()
	camera.min_distance = 3.0
	# The rest of the party out of shot.
	var i: int = 0
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.global_position = _spot(12.0 + i * 1.5, -12.0)
			i += 1

	_dragon = _spawn_dragon(_spot(-2.5, 1.5))
	SelectionManager.select(_dragon)
	_dragon.snap_face_direction(_hero.global_position - _dragon.global_position)
	await _orbit_idle()
	await _walk_order()
	await _flight()
	await _attacks()

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.5)
	get_tree().quit()


func _spawn_dragon(at: Vector3) -> Unit:
	var definition: UnitDefinition = load("res://data/units/demons/dragon.tres")
	var unit: Unit = definition.unit_scene.instantiate()
	unit.definition = definition
	unit.faction = Unit.PLAYER_FACTION
	WorldManager.spawn_parent().add_child(unit)
	unit.global_position = at
	return unit


func _orbit_idle() -> void:
	var camera: CRPGCamera = _camera()
	_frame(_dragon.global_position + Vector3(0.0, 0.3, 0.0), 4.5)
	await _wait(1.5)
	_say("The dragon at SM %d (%.0f m nose to tail) beside the hero: its own Idle" % [int(_dragon.get_stat(StatIds.SM)), SizeModifier.length_for(int(_dragon.get_stat(StatIds.SM)))])
	_check("the dragon plays its own Idle", _clip() == &"Idle")
	await _wait(2.0)
	for step in 6:
		camera.target_yaw = camera.current_yaw + 60.0
		await _wait(1.6)
	_frame(_dragon.global_position + Vector3(0.0, 0.3, 0.0), 4.0)
	camera.target_yaw = camera.current_yaw - 70.0 + 90.0
	_say("Close up, from the side")
	await _wait(3.0)


func _walk_order() -> void:
	var to: Vector3 = _spot(-7.0, 4.0)
	_frame((_dragon.global_position + to) * 0.5, 9.0)
	await _wait(1.5)
	_say("A move order: its own Walk clip")
	_check("the move order is accepted", _dragon.move_to(to))
	await _wait(0.4)
	_check("walking plays Walk", _clip() == &"Walk")
	await _until(func(): return not _dragon.is_moving(), 8.0)
	await _wait(1.0)
	var back: Vector3 = _spot(-2.5, 1.5)
	_camera().focus_target = _dragon
	_camera().target_distance = 7.0
	_say("And back, the camera following")
	_dragon.move_to(back)
	await _until(func(): return not _dragon.is_moving(), 8.0)
	await _wait(1.5)


func _flight() -> void:
	_frame(_dragon.global_position + Vector3(0.0, 1.5, 0.0), 7.0)
	await _wait(1.5)
	_say("Fly: Takeoff (cut from the source's lift-off) into the Fly loop")
	Fly.effects[0].apply(_dragon, null, Fly, false)
	await _wait(0.25)
	_check("taking off plays Takeoff", _clip() == &"Takeoff")
	await _wait(2.5)
	_check("aloft plays Fly", _clip() == &"Fly")
	_check("it is flying", _dragon.is_flying())
	await _wait(2.5)
	var to: Vector3 = _spot(-7.0, -3.0)
	_camera().focus_target = _dragon
	_camera().target_distance = 9.0
	_say("A flying move order")
	_dragon.move_to(to)
	await _until(func(): return not _dragon.is_moving(), 8.0)
	await _wait(2.0)
	_frame(_dragon.global_position - Vector3(0.0, 1.0, 0.0), 7.0)
	await _wait(1.0)
	_say("Land: it comes down in the Fly loop, then Land (Takeoff backwards) on touchdown")
	var down := [false]
	_dragon.touched_down.connect(func(_u): down[0] = true, CONNECT_ONE_SHOT)
	_dragon.land(true)
	await _until(func(): return down[0], 5.0)
	await _wait(0.1)
	_check("touchdown plays Land", _clip() == &"Land")
	await _wait(2.5)
	_check("back on the ground in Idle", _clip() == &"Idle")
	await _wait(1.0)


func _attacks() -> void:
	var dummy: Unit = _dummy(0.0, 0.0)
	var reach: float = _dragon.worn_size * 0.59 + 1.2
	dummy.global_position = _dragon.global_position + _dragon.visual_forward() * (_dragon.radius + dummy.radius + 0.6)
	_dragon.snap_face_direction(dummy.global_position - _dragon.global_position)
	_frame((_dragon.global_position + dummy.global_position) * 0.5 + Vector3(0, 0.4 * _dragon.worn_size, 0), 1.9 * _dragon.worn_size + 3.0)
	_look_side()
	await _wait(2.0)
	var clips := {&"attack.bite": &"Bite", &"attack.claw": &"Claw"}
	for ability: Ability in _dragon.combat_abilities():
		if not ability.effects.any(func(e): return e is GearDamageEffect):
			continue
		var want: StringName = clips.get(ability.motion, &"")
		_say("%s: the MotionSet answers \"%s\" with its own %s clip" % [ability.ability_name, ability.motion, want])
		await _wait(1.0)
		_dragon.reset_turn_actions()
		var hp: int = dummy.get_pool(StatIds.HP)
		await _attack_with(ability, dummy, want)
		_check("%s resolved (%s)" % [ability.ability_name, "hit" if dummy.get_pool(StatIds.HP) < hp else "missed/defended"], true)
		await _wait(2.0)
	dummy.queue_free()
	await _wait(0.5)

	var ahead: Vector3 = _dragon.global_position + _dragon.visual_forward() * (reach * 3.0)
	_frame(_dragon.global_position + _dragon.visual_forward() * reach + Vector3(0, 0.4 * _dragon.worn_size, 0), 2.4 * _dragon.worn_size + 4.0)
	_look_side()
	await _wait(1.5)
	_say("Fire Breath: Breath rears back, the gust releases on its key, Breath_Hold loops while it burns, Breath_Out")
	_dragon.reset_turn_actions()
	_dragon.use_ability(Breath, Breath.targeting.resolve_target_point(ahead))
	await _wait(0.15)
	_check("breath plays Breath", _clip() == &"Breath")
	await _until(func(): return _clip() == &"Breath_Hold", 3.0)
	_check("then holds in Breath_Hold", _clip() == &"Breath_Hold")
	await _until(func(): return _clip() == &"Breath_Out", 6.0)
	_check("and ends in Breath_Out", _clip() == &"Breath_Out")
	await _wait(3.0)

	_frame(_dragon.global_position + Vector3(0, 0.4 * _dragon.worn_size, 0), 1.8 * _dragon.worn_size + 3.0)
	_look_side()
	await _wait(1.5)
	_say("Hit: its own flinch")
	_dragon.take_damage(1)
	await _wait(0.1)
	_check("a hit plays Hit", _clip() == &"Hit")
	await _wait(2.5)
	_say("Downed: knockdown is its Death clip, held")
	_dragon.apply_status(UnitCombat.downed_status())
	await _wait(0.2)
	_check("downed plays Death", _clip() == &"Death")
	await _wait(3.5)
	_say("Back up: Get_Up (Death played backwards)")
	_dragon.remove_status(UnitCombat.downed_status())
	await _wait(0.2)
	_check("standing up plays Get_Up", _clip() == &"Get_Up")
	await _wait(3.0)
	_say("Death")
	_dragon.die()
	await _wait(0.2)
	_check("dying plays Death", _clip() == &"Death")
	await _wait(4.0)


## Starts the attack, checks its clip a moment in, and waits for it.
func _attack_with(ability: Ability, dummy: Unit, want: StringName) -> void:
	var seen := [false]
	var watcher := func():
		var left := 1.0
		while left > 0.0:
			if _clip() == want:
				seen[0] = true
				return
			await get_tree().process_frame
			left -= get_process_delta_time()
	watcher.call()
	var result: Dictionary = await _dragon.use_ability(ability, dummy)
	_check("%s plays %s" % [ability.motion, want], seen[0])


## Side on to the dragon: the camera on its right flank.
func _look_side() -> void:
	var right: Vector3 = _dragon.visual_forward().cross(Vector3.UP).normalized()
	_camera().target_yaw = rad_to_deg(atan2(right.x, right.z))


func _boot_into_arena() -> void:
	_say("Title screen -> Start -> auto-filled character")
	await _wait(1.5)
	get_tree().get_first_node_in_group("main_menu")._on_start_pressed()
	await _wait(1.0)
	var creation: Node = get_tree().get_first_node_in_group("character_creation")
	creation._on_auto_fill_pressed()
	await _wait(1.5)
	creation._on_confirm_pressed()
	await WorldManager.world_focused
	await _wait(2.5)


func _clip() -> StringName:
	var player: BodyAnimationTree = BodyAnimationTree.of(_dragon)
	var name := String(player.current_animation)
	return StringName(name.get_slice("/", name.get_slice_count("/") - 1))


func _until(done: Callable, seconds: float) -> void:
	var left := seconds
	while left > 0.0 and not done.call():
		await get_tree().process_frame
		left -= get_process_delta_time()
