extends AiTestCase
## Resistance: a status naming resisted_by is rolled against that stat
## when something hostile puts it on, and never when an ally does. Only
## the odds are asserted for the hostile case; the roll is left to chance.


func wants_world() -> bool:
	return true


func run() -> void:
	var sleep: StatusEffect = null
	for effect in load("res://data/abilities/sleep_dart.tres").effects:
		if effect is ApplyStatusEffect:
			sleep = effect.status
	check("Sleep is resisted by HT", sleep != null and sleep.resisted_by == StatIds.HT)
	if sleep == null:
		return

	var caster: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3.ZERO)
	var enemy: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(3.0, 0.0, 0.0))
	var ally: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(-3.0, 0.0, 0.0))
	var quick: Unit = spawn_unit(&"enemy", 10, 11, 10, [melee()], Vector3(0.0, 0.0, 3.0))
	check("Basic Speed keeps its fraction; Dodge drops it",
		quick.get_stat(StatIds.BASIC_SPEED) == 5.25 and quick.get_stat(StatIds.DODGE) == 8,
		"speed %.2f, dodge %d" % [quick.get_stat(StatIds.BASIC_SPEED), quick.get_stat(StatIds.DODGE)])

	# HT 10 resists on 108 of 216 rolls.
	var chance: float = enemy.status_land_chance(sleep, caster)
	check("a hostile's Sleep lands on HT 10 half the time", absf(chance - 0.5) < 0.0001,
		"got %.4f" % chance)

	check("an ally's status is never resisted",
		ally.status_land_chance(sleep, caster) == 1.0 and ally.inflict_status(sleep, caster)
		and ally.has_status(sleep))
	free_spawned()
