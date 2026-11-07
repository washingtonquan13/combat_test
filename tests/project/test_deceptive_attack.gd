extends AiTestCase
## Deceptive Attack (B369): level N is -2N to skill and -N to the
## defender's defense. Switched off it keeps its level; the AI picks a
## level when the trade pays.


func wants_world() -> bool:
	return true


func run() -> void:
	var deceptive: Ability = UnitCombat.DECEPTIVE_ATTACK
	var attacker: Unit = spawn_unit(&"player", 10, 20, 10, [melee()], Vector3.ZERO)
	var target: Unit = spawn_unit(&"enemy", 10, 14, 30, [melee()], Vector3(1.0, 0.0, 0.0))
	var attack: Ability = attacker.abilities[0]

	var skill: int = attacker.to_hit_target(target, attack)
	var defense: int = attacker._combat.defense_against(target, attack).target
	attacker.set_toggled(deceptive, true)
	attacker.set_toggle_level(deceptive, 3)
	check("level 3 is -6 to skill and -3 to defense",
		attacker.to_hit_target(target, attack) == skill - 6 and attacker._combat.defense_against(target, attack).target == defense - 3)
	attacker.set_toggled(deceptive, false)
	check("off keeps the level and costs nothing",
		attacker.toggle_level(deceptive) == 3 and attacker.deceptive_level() == 0 and attacker.to_hit_target(target, attack) == skill)

	# DX 20 against a good Dodge: trading skill for the defense pays.
	var plan := AiPlan.new()
	plan.ability = attack
	plan.target = target
	AiScorer._score_plan(attacker, plan)
	check("the AI feints with a skilled attack", plan.deceptive_level > 0, "level %d, %s" % [plan.deceptive_level, plan.reason])
	check("pricing levels leaves the unit's own state alone",
		attacker.deceptive_level() == 0 and attacker.toggle_level(deceptive) == 3)
	free_spawned()
