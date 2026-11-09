extends AiTestCase
## A jump's curve rises by itself to clear what's in the way, up to a
## limit; the player can set it by holding Ctrl, for their own armed jump
## only, and the height set reaches the flight.

const ROUTER_SCRIPT: GDScript = preload("res://systems/indicator_system/ground_click_target.gd")


func run() -> void:
	_wall(Vector3(2.2, 0, 0), 2.4)
	_wall(Vector3(2.2, 0, -8), 30.0)
	var jump: Ability = load("res://data/abilities/jump.tres")
	var targeting: GroundPointTargeting = jump.targeting
	var jumper: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3.ZERO)
	var other: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3(0, 0, 1))
	for _i in 5:
		await get_tree().physics_frame

	var landing := Vector3(4.4, 0, 0)
	var usual: float = targeting.arc_height_for(jumper, landing)
	check("the usual curve hits the wall", ArcFlight.clear_fraction(jumper, jumper.global_position, landing, usual) < 1.0)
	var raised: float = targeting.chosen_arc(jumper, landing)
	check("the curve rises over it, within the limit", raised > usual and raised <= usual * GroundPointTargeting.ARC_RAISE, str(raised))
	check("and the jump is allowed", targeting.check(jumper, landing) == AbilityTargeting.Reach.OK)

	jumper.global_position = Vector3(0, 0, -8)
	var past_tall := Vector3(4.4, 0, -8)
	check("a wall past the limit still refuses it", targeting.check(jumper, past_tall) == AbilityTargeting.Reach.PATH_BLOCKED)
	jumper.global_position = Vector3.ZERO

	AbilityManager.armed_ability = jump
	AbilityManager.armed_unit = jumper
	AbilityManager.set_arc_height_override(0.5)
	check("a height the player set wins", is_equal_approx(targeting.chosen_arc(jumper, landing), 0.5))
	check("and shows blocked rather than quietly rising", targeting.check(jumper, landing) == AbilityTargeting.Reach.PATH_BLOCKED)
	var beside := Vector3(4.4, 0, 1)
	check("nobody else's jump takes it", targeting.chosen_arc(other, beside) > usual, str(targeting.chosen_arc(other, beside)))
	AbilityManager.set_arc_height_override(99.0)
	check("it stops at the limit", is_equal_approx(targeting.chosen_arc(jumper, landing), usual * GroundPointTargeting.ARC_RAISE))

	_test_ctrl(jump, targeting, landing)
	await _test_flight(jump, jumper, targeting)
	AbilityManager.armed_ability = null
	AbilityManager.armed_unit = null
	AbilityManager.clear_arc_height_override()
	free_spawned()


func _test_ctrl(jump: Ability, targeting: GroundPointTargeting, landing: Vector3) -> void:
	var router: Node3D = Node3D.new()
	router.set_script(ROUTER_SCRIPT)
	add_child(router)
	router.set_process(false)
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = Vector3(4.4, 2.0, 12.0)
	camera.make_current()
	var intent := AimingIntent.new(jump)
	var unit: Unit = AbilityManager.armed_unit

	AbilityManager.clear_arc_height_override()
	_ctrl(true)
	router.resolve_cursor(intent)
	router._held_ground = landing
	router._arc_hold_base = 1.5
	var held: Cursor = router.resolve_cursor(intent)
	check("Ctrl keeps the landing on the floor", held.holding_height and held.ground == landing and not held.on_plane, str(held.ground))
	var sampled: float = router._sample_height(Vector2(landing.x, landing.z))
	check("and the mouse's rise sets the height", is_equal_approx(AbilityManager.arc_height_override, targeting.clamp_arc(unit, landing, 1.5 + sampled)),
		str(AbilityManager.arc_height_override))
	check("a wheel notch steps it", router._step_plane(intent, 1.0) and is_equal_approx(router._arc_hold_base, 1.75), str(router._arc_hold_base))
	_ctrl(false)
	router.resolve_cursor(intent)
	check("letting go ends the hold but keeps the height", router._arc_hold_base == null and AbilityManager.has_arc_height_override)
	camera.free()
	router.free()


func _test_flight(jump: Ability, jumper: Unit, targeting: GroundPointTargeting) -> void:
	jumper.global_position = Vector3(0, 0, 6)
	var open_landing := Vector3(4.4, 0, 6)
	AbilityManager.set_arc_height_override(3.0)
	var effect: MoveCasterEffect = jump.effects[0]
	var plan: Dictionary = effect.resolve(jumper, open_landing, jump, false)
	AbilityManager.clear_arc_height_override()
	effect.commit(jumper, open_landing, jump, false, plan)
	var peak: float = 0.0
	for _i in 180:
		await get_tree().physics_frame
		peak = maxf(peak, jumper.global_position.y)
	check("the height set on the click is the flight's", peak > 2.5, str(peak))
	check("and it lands", jumper.global_position.distance_to(open_landing) < 0.2, str(jumper.global_position))


func _wall(at: Vector3, height: float) -> void:
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, height, 4.0)
	shape.shape = box
	shape.position = Vector3(0, height * 0.5, 0)
	wall.add_child(shape)
	_root.add_child(wall)
	wall.global_position = at


func _ctrl(down: bool) -> void:
	if down:
		Input.action_press("fly_altitude_modifier")
	else:
		Input.action_release("fly_altitude_modifier")
