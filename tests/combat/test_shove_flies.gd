extends AiTestCase
## Shove flies the target along ArcFlight, ST through the jump formula.


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
