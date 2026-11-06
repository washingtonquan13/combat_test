extends AiTestCase
## Shove flies the target along ArcFlight, ST through the jump formula;
## a wall on the way stops it short, and a long fall hurts.


func run() -> void:
	var shover: Unit = spawn_unit(&"player", 10, 10, 10, [], Vector3.ZERO)
	var victim: Unit = spawn_unit(&"enemy", 10, 10, 10, [], Vector3(1, 0, 0))
	var shove: Ability = load("res://data/abilities/shove.tres")
	var effect: KnockbackEffect = shove.effects[0]
	var start: Vector3 = victim.global_position
	effect.apply(shover, victim, shove, false)
	await get_tree().create_timer(effect.push_duration * 0.5).timeout
	check("in the air mid-shove", victim.global_position.y > start.y + 0.5, str(victim.global_position))
	await get_tree().create_timer(effect.push_duration).timeout
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

	var faller: Unit = spawn_unit(&"enemy", 10, 10, 10, [], Vector3.ZERO)
	ArcFlight.take_fall(faller, SAFE_DROP)
	check("a 3 m drop is free", faller.get_pool(StatIds.HP) == 10, str(faller.get_pool(StatIds.HP)))
	ArcFlight.take_fall(faller, 10.0)
	check("a 10 m fall hurts", faller.get_pool(StatIds.HP) < 10, str(faller.get_pool(StatIds.HP)))
	free_spawned()


const SAFE_DROP: float = 3.0
