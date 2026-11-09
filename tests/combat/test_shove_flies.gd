extends AiTestCase
## Shove flies the target along ArcFlight, ST through the jump formula;
## a wall on the way stops it short, off a ledge it comes down below,
## and a long fall hurts.


func run() -> void:
	var shover: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3.ZERO)
	var victim: Unit = spawn_unit(&"enemy", 10, 10, 10, [], Vector3(1, 0, 0))
	var shove: Ability = load("res://data/abilities/shove.tres")
	var effect: KnockbackEffect = shove.effects[0]
	var start: Vector3 = victim.global_position
	var flight: float = ArcFlight.duration(start, effect.landing_point(shover, victim))
	effect.apply(shover, victim, shove, false)
	await get_tree().create_timer(flight * 0.5).timeout
	check("in the air mid-shove", victim.global_position.y > start.y + 0.5, str(victim.global_position))
	await get_tree().create_timer(flight).timeout
	var flown: float = Vector2(start.x, start.z).distance_to(Vector2(victim.global_position.x, victim.global_position.z))
	check("ST 10 shoves 4.5 m", absf(flown - 4.5) < 0.3, "%.2f" % flown)
	free_spawned()

	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 3.0, 4.0)
	shape.shape = box
	shape.position = Vector3(0, 1.5, 0)
	wall.add_child(shape)
	_root.add_child(wall)
	wall.global_position = Vector3(3, 0, 0)
	await get_tree().physics_frame
	shover = spawn_unit(&"player", 10, 10, 10, [], Vector3.ZERO)
	victim = spawn_unit(&"enemy", 10, 10, 10, [], Vector3(1, 0, 0))
	await get_tree().physics_frame
	var stop = effect.landing_point(shover, victim)
	check("a wall stops the shove short", stop is Vector3 and stop.x < 3.0 - 0.2 - victim.radius + 0.05, str(stop))
	free_spawned()
	wall.queue_free()

	var ledge := StaticBody3D.new()
	var ledge_shape := CollisionShape3D.new()
	var ledge_box := BoxShape3D.new()
	ledge_box.size = Vector3(2.0, 6.0, 4.0)
	ledge_shape.shape = ledge_box
	ledge_shape.position = Vector3(0, 3.0, 0)
	ledge.add_child(ledge_shape)
	_root.add_child(ledge)
	ledge.global_position = Vector3(0.5, 0, 0)
	NavigationGrid.invalidate()
	await get_tree().physics_frame
	shover = spawn_unit(&"player", 10, 10, 10, [], Vector3(0, 6, 0))
	victim = spawn_unit(&"enemy", 10, 10, 10, [], Vector3(1, 6, 0))
	await get_tree().physics_frame
	var down = effect.landing_point(shover, victim)
	check("off a ledge it lands on the ground below", down is Vector3 and down.y < 1.0 and down.x > 3.0, str(down))
	free_spawned()
	ledge.queue_free()
	NavigationGrid.invalidate()

	var faller: Unit = spawn_unit(&"enemy", 10, 10, 10, [], Vector3.ZERO)
	ArcFlight.take_fall(faller, SAFE_DROP)
	check("a 3 m drop is free", faller.get_pool(StatIds.HP) == 10, str(faller.get_pool(StatIds.HP)))
	ArcFlight.take_fall(faller, 10.0)
	check("a 10 m fall hurts", faller.get_pool(StatIds.HP) < 10, str(faller.get_pool(StatIds.HP)))
	free_spawned()

	await _flies_on_the_physics_step()


## Below the physics rate a render-frame flight would sit still for ticks
## at a time, and gravity would build under it.
func _flies_on_the_physics_step() -> void:
	var cap: int = Engine.max_fps
	Engine.max_fps = 20
	var jumper: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3.ZERO)
	await get_tree().physics_frame
	ArcFlight.fly(jumper, Vector3(6, 0, 0), 2.0)
	await get_tree().physics_frame
	var last: Vector3 = jumper.global_position
	var every_tick: bool = true
	for i: int in 12:
		await get_tree().physics_frame
		every_tick = every_tick and not jumper.global_position.is_equal_approx(last)
		last = jumper.global_position
	check("at 20 fps a flight moves every physics tick", every_tick)
	check("and no gravity builds under it", is_zero_approx(jumper.velocity.y), str(jumper.velocity.y))
	Engine.max_fps = cap
	free_spawned()


const SAFE_DROP: float = 3.0
