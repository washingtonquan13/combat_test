extends AiTestCase
## Air Move is twice Basic Speed and is the turn budget while flying;
## taking off mid-turn keeps the share of the turn left. SM is added to
## every attack against the unit.


func wants_world() -> bool:
	return true


func run() -> void:
	# DX 10, HT 11: Basic Speed 5.25, Move 5, Air Move 10.
	var flier: Unit = spawn_unit(&"player", 10, 10, 11, [melee()], Vector3.ZERO)
	check("Air Move is Basic Speed x 2, fraction dropped", flier.get_stat(StatIds.AIR_MOVE) == 10,
		"got %s" % flier.get_stat(StatIds.AIR_MOVE))
	flier.reset_turn_actions()
	flier.move_remaining = 2.5
	flier.apply_status(load("res://data/statuses/flying.tres"))
	check("taking off with half the turn left leaves half a turn of Air Move",
		is_equal_approx(flier.move_remaining, 5.0), "got %.2f" % flier.move_remaining)

	var attacker: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(2.0, 0.0, 0.0))
	var target: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-2.0, 0.0, 0.0))
	var ability: Ability = attacker.abilities[0]
	var plain: int = attacker.to_hit_target(target, ability)
	target.set_base_stat(StatIds.SM, 2)
	check("a target's SM is added to the attack", attacker.to_hit_target(target, ability) == plain + 2)
	free_spawned()
