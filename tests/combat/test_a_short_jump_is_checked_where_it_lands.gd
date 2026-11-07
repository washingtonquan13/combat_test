extends AiTestCase
## A jump past the move left lands short, and the wall check runs on that
## shorter, lower curve, not the one to the click.


func run() -> void:
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 1.2, 4.0)
	shape.shape = box
	shape.position = Vector3(0, 0.6, 0)
	wall.add_child(shape)
	_root.add_child(wall)
	wall.global_position = Vector3(2, 0, 0)
	var jumper: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3.ZERO)
	var enemy: Unit = spawn_unit(&"enemy", 10, 10, 10, [], Vector3(0, 0, 8))
	var roster: Array[Unit] = [jumper, enemy]
	CombatManager.start_combat(roster)
	for _i in 5:
		await get_tree().physics_frame
	jumper.move_remaining = 2.5
	jumper.global_position.x = 0.0
	var jump: Ability = load("res://data/abilities/jump.tres")
	var targeting: GroundPointTargeting = jump.targeting
	var click := Vector3(4.4, 0, 0)
	check("the full curve clears the wall",
		ArcFlight.clear_fraction(jumper, jumper.global_position, click, targeting.flight_arc_height) >= 1.0)
	var landing: Vector3 = targeting.landing_for(jumper, click)
	check("it lands short", absf(jumper.global_position.distance_to(landing) - 2.5) < 0.01,
		"%s from %s" % [landing, jumper.global_position])
	check("the short curve is the one checked",
		targeting.check_click(jumper, click) == AbilityTargeting.Reach.PATH_BLOCKED,
		str(targeting.check_click(jumper, click)))
	enemy.take_damage(50)
	free_spawned()
	wall.queue_free()
