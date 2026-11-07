extends "res://tools/tier3_demo.gd"
## Recorded showcase of flights meeting the world - NOT a test. A jump
## aimed over a wall shows red and is refused; a shove into a wall stops
## short; a shove off a 10 m ledge hurts; in combat, a jump the move left
## can't cover lands short and is checked there.

const Jump: Ability = preload("res://data/abilities/jump.tres")
const Shove: Ability = preload("res://data/abilities/shove.tres")

var _origin: Vector3
var _fwd: Vector3
var _right: Vector3
var _props: Array[Node] = []


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	_origin = _hero.global_position
	_fwd = -_hero.visual_forward()
	_right = _fwd.cross(Vector3.UP)
	SelectionManager.select(_hero)

	await _jump_over_wall()
	await _shove_into_wall()
	await _shove_off_ledge()
	await _short_jump()

	var total := _passed + _failed.size()
	_say("Done: %d/%d checks passed" % [_passed, total])
	print("DEMO RESULT: %d/%d passed" % [_passed, total])
	for f in _failed:
		print("  FAILED: ", f)
	await _wait(2.5)
	get_tree().quit()


func _jump_over_wall() -> void:
	_wall(_at(2.2, 0.0), Vector3(4.0, 3.0, 0.4))
	_frame(_at(2.0, 0.0), 10.0)
	await _wait(2.0)
	_say("Jump aimed over a 3 m wall: the arc stops at the wall, red")
	AbilityManager.arm(Jump)
	await _glide(_screen(_at(1.0, 0.5)), 0, 10)
	await _glide(_screen(_at(4.0, 0.0)), 0, 40)
	await _wait(2.0)
	_check("the arc over the wall is refused",
		Jump.targeting.check(_hero, _at(4.0, 0.0)) == AbilityTargeting.Reach.PATH_BLOCKED)
	_say("Click: refused, \"Something in the way\"")
	var from: Vector3 = _hero.global_position
	await _click(_screen(_at(4.0, 0.0)))
	await _wait(2.5)
	_check("the hero did not jump", _hero.global_position.distance_to(from) < 0.2)
	_say("Aim past the end of the wall: white, and it jumps")
	await _glide(_screen(_at(1.5, -3.5)), 0, 40)
	await _wait(1.5)
	await _click(_screen(_at(1.5, -3.5)))
	await _wait(3.5)
	_check("the hero jumped round the wall", _hero.global_position.distance_to(from) > 2.0)
	AbilityManager.disarm()
	await _clear()


func _shove_into_wall() -> void:
	_place(_hero, _at(0.0, 0.0))
	var victim: Unit = _dummy_at(_at(1.0, 0.0), 300)
	_wall(_at(3.0, 0.0), Vector3(4.0, 3.0, 0.4))
	_side_view(_at(1.5, 0.0), 9.0)
	await _wait(2.0)
	_say("Shove: ST 10 would fly the target 4.5 m...")
	await _wait(1.5)
	_say("...but a wall 2 m behind it stops the flight short")
	await _preview_shove(victim)
	await _shove(victim)
	var flown: float = _flat(victim.global_position - _at(1.0, 0.0))
	_check("it stopped at the wall (%.1f m, not 4.5)" % flown, flown < 2.0 and flown > 0.5)
	await _wait(2.5)
	victim.queue_free()
	await _clear()


func _shove_off_ledge() -> void:
	var top: Vector3 = _at(4.0, 0.0) + Vector3(0.0, 10.0, 0.0)
	_wall(top - Vector3(0.0, 10.0, 0.0), Vector3(3.0, 10.0, 3.0))
	NavigationGrid.invalidate()
	await _wait(0.3)
	_place(_hero, top - _fwd * 0.8)
	var victim: Unit = _dummy_at(top + _fwd * 0.6, 14)
	_side_view(top - Vector3(0.0, 4.0, 0.0) + _fwd * 2.0, 20.0)
	await _wait(2.5)
	_say("Shove off a 10 m ledge: GURPS falling damage, 4 m and under is free")
	await _preview_shove(victim)
	var hp: int = victim.get_pool(StatIds.HP)
	await _shove(victim)
	var drop: float = top.y - victim.global_position.y
	var lost: int = hp - victim.get_pool(StatIds.HP)
	_say("Fell %.0f m: %dd6 crushing, %d of %d HP" % [drop, ArcFlight.fall_dice(victim.get_stat(StatIds.HP), drop), lost, hp])
	_check("the fall hurt", lost > 0)
	await _wait(3.5)
	victim.queue_free()
	await _clear()


func _short_jump() -> void:
	_place(_hero, _at(0.0, 0.0))
	var enemy: Unit = _dummy_at(_at(-8.0, 6.0), 300)
	enemy.faction = &"enemy"
	_wall(_at(2.0, 0.0), Vector3(4.0, 1.2, 0.2))
	NavigationGrid.invalidate()
	var roster: Array[Unit] = [_hero, enemy]
	CombatManager.start_combat(roster)
	for i in 300:
		if CombatManager.running_encounter_in_world_of(_hero) != null and _hero.can_be_commanded():
			break
		await get_tree().process_frame
	_place(_hero, _at(0.0, 0.0))
	SelectionManager.select(_hero)
	_frame(_at(2.0, 0.0), 9.0)
	await _wait(1.5)
	var click: Vector3 = _at(4.4, 0.0)
	_hero.move_remaining = 10.0
	_say("In combat, full move: the jump to 4.4 m clears the low wall")
	AbilityManager.arm(Jump)
	await _glide(_screen(_at(1.0, 0.5)), 0, 10)
	await _glide(_screen(click), 0, 40)
	await _wait(2.5)
	_check("full move: clear", Jump.targeting.check_click(_hero, click) == AbilityTargeting.Reach.OK)
	_say("Only 2.5 m of move left: it lands short, on a lower curve...")
	_hero.move_remaining = 2.5
	await _glide(_screen(click + _right * 0.05), 0, 4)
	await _wait(2.0)
	_say("...and that shorter curve is the one checked: into the wall, red")
	_check("short jump: blocked", Jump.targeting.check_click(_hero, click) == AbilityTargeting.Reach.PATH_BLOCKED)
	await _wait(3.0)
	AbilityManager.disarm()
	enemy.take_damage(1000)
	await _wait(1.0)


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


## Arms Shove and hovers victim: the arc shows where it will fly.
func _preview_shove(victim: Unit) -> void:
	_hero.look_at(Vector3(victim.global_position.x, _hero.global_position.y, victim.global_position.z), Vector3.UP, true)
	AbilityManager.arm(Shove)
	await _glide(_screen(victim.global_position + Vector3(0, 0.9, 0)), 0, 30)
	await _wait(2.5)
	_check("the shove arc is drawn", _flight_arc_showing())
	AbilityManager.disarm()
	await _wait(0.3)


func _flight_arc_showing() -> bool:
	for node in get_tree().get_nodes_in_group(&"indicators"):
		if node.serves() == &"flight":
			return node.is_showing_anything()
	return false


func _shove(victim: Unit) -> void:
	var effect: KnockbackEffect = Shove.effects[0]
	_hero.look_at(Vector3(victim.global_position.x, _hero.global_position.y, victim.global_position.z), Vector3.UP, true)
	var flight: float = ArcFlight.duration(victim.global_position, effect.landing_point(_hero, victim))
	effect.apply(_hero, victim, Shove, false)
	await _wait(flight + 0.6)


## Frames point seen from the side of the flight (looking along _right,
## a little toward the hero), so a wall across it can't come between the
## camera and the flight.
func _side_view(point: Vector3, distance: float) -> void:
	_frame(point, distance)
	var look: Vector3 = (_right - _fwd * 0.4).normalized()
	_camera().target_yaw = rad_to_deg(atan2(-look.x, -look.z))


func _at(forward: float, side: float) -> Vector3:
	return _origin + _fwd * forward + _right * side


func _flat(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _place(unit: Unit, at: Vector3) -> void:
	unit.global_position = at


func _dummy_at(at: Vector3, hp: int) -> Unit:
	var unit: Unit = _dummy(0.0, 0.0)
	unit.set_base_stat(StatIds.HP, hp)
	unit.set_pool(StatIds.HP, int(unit.get_stat(StatIds.HP)))
	unit.global_position = at
	return unit


func _wall(center_floor: Vector3, size: Vector3) -> void:
	var box := _solid(center_floor + Vector3(0.0, size.y * 0.5, 0.0), size)
	box.look_at(box.global_position + _fwd, Vector3.UP)
	_props.append(box)


func _clear() -> void:
	for p in _props:
		p.queue_free()
	_props.clear()
	await get_tree().physics_frame
	NavigationGrid.invalidate()
	await _wait(0.5)
