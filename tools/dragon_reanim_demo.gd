extends "res://tools/dragon_sizes_demo.gd"
## Recorded showcase of all 27 reanimated dragon clips in the real game -
## NOT a test. Everything goes through the game's own paths except the
## four clips no ability calls yet, which are played straight on the
## AnimationPlayer and captioned so.

const SleepDart: Ability = preload("res://data/abilities/sleep_dart.tres")
const WALK_ROOM: float = 14.0

var _player: AnimationPlayer
var _dummy_unit: Unit


func _row_length() -> float:
	return super() + WALK_ROOM


func _run() -> void:
	SIZES = [4]
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.visible = false
	var camera: CRPGCamera = _camera()
	camera.min_distance = 3.0
	camera.max_distance = 80.0
	camera.min_pitch = 8.0
	camera.max_pitch = 14.0
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.9
	fill.shadow_enabled = false
	camera.add_child(fill)
	_length = _row_length()
	if not _find_row():
		print("DEMO RESULT: no clear ground for a %.0f m row" % _length)
		get_tree().quit()
		return
	_hero.global_position = _origin - _across() * 18.0
	_spawn_row()
	_dragon = _dragons[0]
	_player = _dragon.find_children("AnimationPlayer", "AnimationPlayer", true, false)[0]
	SelectionManager.select(_dragon)
	await _wait(0.5)
	_watch_wings()

	if not "--air-only" in OS.get_cmdline_user_args():
		await _ground_motion()
		await _ground_attacks()
		await _hurt_and_knockdown()
	await _air()
	await _unwired_on_ground()
	await _dies()

	var total := _passed + _failed.size()
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(1.0)
	get_tree().quit()


func _watch_wings() -> void:
	var skeleton: Skeleton3D = _dragon.find_children("*", "Skeleton3D", true, false)[0]
	var bones: Array[int] = []
	for i in skeleton.get_bone_count():
		var bone: String = skeleton.get_bone_name(i)
		if bone.begins_with("w") and bone.length() == 4 and bone[1].is_valid_int():
			bones.append(i)
	print("WATCH wing bones ", bones.size())
	var last := {}
	var clip: StringName = _clip()
	var since := 100
	var worst_cut := 0.0
	while is_instance_valid(skeleton) and is_instance_valid(_dragon):
		await get_tree().process_frame
		if not is_instance_valid(skeleton):
			break
		since += 1
		if _clip() != clip:
			print("WATCH clip %s -> %s" % [clip, _clip()])
			clip = _clip()
			since = 0
		var worst := 0.0
		for i in bones:
			var q: Quaternion = skeleton.get_bone_pose_rotation(i)
			if last.has(i):
				worst = maxf(worst, rad_to_deg(q.angle_to(last[i])))
			last[i] = q
		if since <= 4:
			worst_cut = maxf(worst_cut, worst)
			print("WATCH step %.1f, %d frames into %s" % [worst, since, clip])
	print("WATCH worst step near a clip change %.1f" % worst_cut)


func _shot(height: float = 0.4, extra: float = 3.0) -> void:
	var k: float = _dragon.worn_size
	_frame(_dragon.global_position + Vector3(0, height * k, 0), 1.9 * k + extra)
	_look_side()


func _ground_motion() -> void:
	_shot()
	_say("Idle")
	await _wait(3.5)
	_check("Idle plays", _clip() == &"Idle")

	var start: Vector3 = _dragon.visual_forward()
	var left: Vector3 = start.rotated(Vector3.UP, deg_to_rad(100.0))
	_say("Turn in place, at the game's real turn rate")
	await _swing(left, 1.2)
	await _wait(0.6)
	await _swing(start, 1.2)
	await _wait(0.8)

	var speed: float = _dragon.rotation_speed
	_dragon.rotation_speed = 1.1
	_say("Turn_L and Turn_R again, turning slowed so the feet can be seen")
	await _swing(left, 2.6)
	await _swing(start, 2.6)
	_dragon.rotation_speed = speed
	await _wait(1.0)

	var home: Vector3 = _dragon.global_position
	var away: Vector3 = home + _line * 12.0
	_camera().focus_target = _dragon
	_camera().target_anchor_offset = Vector3.ZERO
	_camera().target_distance = 1.9 * _dragon.worn_size + 3.0
	_say("Walk")
	_check("the walk order is accepted", _dragon.move_to(away))
	await _wait(0.5)
	_check("walking plays Walk", _clip() == &"Walk")
	await _until(func(): return not _dragon.is_moving(), 12.0)
	await _wait(0.8)
	_dragon.move_to(home)
	await _until(func(): return not _dragon.is_moving(), 12.0)
	await _wait(1.0)
	_dragon.snap_face_direction(-_line)
	await _wait(0.3)


func _swing(direction: Vector3, seconds: float) -> void:
	var left := seconds
	var seen := {}
	while left > 0.0:
		var delta: float = get_physics_process_delta_time()
		_dragon.face_direction(direction, delta)
		seen[_clip()] = true
		await get_tree().physics_frame
		left -= delta
	print("SWING saw ", seen.keys())


func _place_dummy() -> void:
	if _dummy_unit == null:
		_dummy_unit = _dummy(0.0, 0.0)
	var at: Vector3 = _dragon.global_position + _dragon.visual_forward() * (_dragon.radius + _dummy_unit.radius + 0.6)
	_dummy_unit.global_position = _floor_under(at)
	_dragon.snap_face_direction(_dummy_unit.global_position - _dragon.global_position)


func _floor_under(p: Vector3) -> Vector3:
	var ground = _floor_at(Vector3(p.x, _origin.y, p.z))
	return ground if ground != null else Vector3(p.x, _origin.y, p.z)


func _hide_dummy() -> void:
	_dummy_unit.visible = false
	_dummy_unit.global_position += Vector3(0, -20, 0)


func _melee(clips: Dictionary) -> void:
	for ability: Ability in _dragon.combat_abilities():
		if not ability.effects.any(func(e): return e is GearDamageEffect):
			continue
		var want: StringName = clips.get(ability.motion, &"")
		_say(_label(want))
		await _wait(0.8)
		_dragon.reset_turn_actions()
		await _attack_with(ability, _dummy_unit, want)
		await _wait(1.5)


func _attack_with(ability: Ability, dummy: Unit, want: StringName) -> void:
	var from_dragon: Vector3 = dummy.global_position - _dragon.global_position
	print("ATTACK from ", _dragon.global_position, " offset ", from_dragon, " reach ", ability.is_in_range(_dragon, dummy))
	await super(ability, dummy, want)


func _label(clip: StringName) -> String:
	return String(clip).replace("_", " ")


func _breath(first: StringName, hold: StringName, out: StringName, rest: StringName) -> void:
	var reach: float = (_dragon.worn_size * 0.59 + 1.2) * 3.0
	var ahead: Vector3 = _floor_under(_dragon.global_position + _dragon.visual_forward() * reach)
	_say("%s, %s, %s" % [_label(first), _label(hold), _label(out)])
	await _wait(0.8)
	_dragon.reset_turn_actions()
	_dragon.use_ability(Breath, Breath.targeting.resolve_target_point(ahead))
	await _wait(0.15)
	_check("breath plays %s" % first, _clip() == first)
	await _until(func(): return _clip() == hold, 4.0)
	_check("then holds in %s" % hold, _clip() == hold)
	await _until(func(): return _clip() == out, 7.0)
	_check("and ends in %s" % out, _clip() == out)
	await _until(func(): return _clip() == rest, 5.0)
	await _wait(1.2)


func _ground_attacks() -> void:
	_place_dummy()
	_shot()
	await _wait(1.2)
	await _melee({&"attack.bite": &"Bite", &"attack.claw": &"Claw"})
	_hide_dummy()
	await _breath(&"Breath", &"Breath_Hold", &"Breath_Out", &"Idle")


func _knockdown_status() -> StatusEffect:
	for effect in SleepDart.effects:
		if effect.get("status") is StatusEffect:
			return effect.status
	return null


func _hurt_and_knockdown() -> void:
	_shot()
	_say("Hit")
	await _wait(0.8)
	_dragon.take_damage(1)
	await _wait(0.1)
	_check("a hit plays Hit", _clip() == &"Hit")
	await _wait(2.2)
	var status: StatusEffect = _knockdown_status()
	_check("found the Sleep Dart status", status != null)
	_say("Knockdown, through the status Sleep Dart applies")
	await _wait(0.6)
	_dragon.apply_status(status)
	await _wait(0.2)
	_check("the status plays Knockdown", _clip() == &"Knockdown")
	await _wait(4.0)
	_say("Get Up, when the status ends")
	_dragon.remove_status(status)
	await _wait(0.2)
	_check("removing it plays Get_Up", _clip() == &"Get_Up")
	await _until(func(): return _clip() == &"Idle", 5.0)
	await _wait(1.5)


func _air() -> void:
	var k: float = _dragon.worn_size
	_shot(0.9, 4.0)
	_say("Takeoff")
	await _wait(0.8)
	Fly.effects[0].apply(_dragon, null, Fly, false)
	await _wait(0.25)
	_check("taking off plays Takeoff", _clip() == &"Takeoff")
	await _until(func(): return _clip() == &"Fly", 6.0)
	_check("aloft plays Fly", _clip() == &"Fly")
	_say("Fly")
	await _wait(3.5)

	_camera().focus_target = _dragon
	_camera().target_anchor_offset = Vector3.ZERO
	_camera().target_distance = 1.9 * k + 6.0
	var home: Vector3 = _dragon.global_position
	var away: Vector3 = home + _line * 12.0
	_say("Fly Forward")
	_dragon.move_to(away)
	await _wait(0.5)
	_check("moving aloft plays Fly_Forward", _clip() == &"Fly_Forward")
	await _until(func(): return not _dragon.is_moving(), 10.0)
	await _wait(0.8)
	_dragon.move_to(home)
	await _until(func(): return not _dragon.is_moving(), 10.0)
	await _wait(1.0)
	_dragon.snap_face_direction(-_line)

	await _hovering_dummy()
	_shot(0.9, 4.0)
	await _wait(1.2)
	await _melee({&"attack.bite": &"Bite_Air", &"attack.claw": &"Claw_Air"})
	_hide_dummy()
	await _breath(&"Breath_Air", &"Breath_Hold_Air", &"Breath_Out_Air", &"Fly")

	_say("Hit, in the air")
	await _wait(0.8)
	_dragon.take_damage(1)
	await _wait(0.1)
	_check("a hit aloft plays Hit_Air", _clip() == &"Hit_Air")
	await _wait(2.2)
	await _direct("Roar_Air", "Roar in the air (no ability yet, clip played directly)")

	_say("Land")
	await _wait(0.6)
	var down := [false]
	_dragon.touched_down.connect(func(_u): down[0] = true, CONNECT_ONE_SHOT)
	_dragon.land(true)
	await _until(func(): return down[0], 6.0)
	await _wait(0.1)
	_check("touchdown plays Land", _clip() == &"Land")
	await _until(func(): return _clip() == &"Idle", 5.0)
	await _wait(1.2)


## A target hovering beside the dragon, through the same Fly it used.
func _hovering_dummy() -> void:
	if _dummy_unit == null:
		_dummy_unit = _dummy(0.0, 0.0)
	_dummy_unit.visible = true
	var at: Vector3 = _dragon.global_position + _dragon.visual_forward() * (_dragon.radius + _dummy_unit.radius + 0.6)
	_dummy_unit.global_position = _floor_under(at)
	Fly.effects[0].apply(_dummy_unit, null, Fly, false)
	await _wait(3.0)
	print("HOVER dummy y ", _dummy_unit.global_position.y, " dragon y ", _dragon.global_position.y)
	_dragon.snap_face_direction(_dummy_unit.global_position - _dragon.global_position)


func _direct(clip: String, caption: String) -> void:
	_check("%s exists" % clip, _player.has_animation(clip))
	_say(caption)
	await _wait(0.8)
	_player.play(clip, 0.2)
	await _wait(_player.get_animation(clip).length + 1.0)


func _unwired_on_ground() -> void:
	_shot(0.4, 5.0)
	await _direct("Roar", "Roar (no ability yet, clip played directly)")
	await _direct("Wing_Buffet", "Wing Buffet (no ability yet, clip played directly)")
	_shot(0.4, 9.0)
	await _direct("Tail_Swipe", "Tail Swipe (no ability yet, clip played directly)")


func _dies() -> void:
	_shot()
	_say("Death")
	await _wait(1.0)
	_dragon.death_cleanup_delay = 6.0
	_dragon.die()
	await _wait(0.2)
	_check("dying plays Death", _clip() == &"Death")
	await _wait(4.5)
