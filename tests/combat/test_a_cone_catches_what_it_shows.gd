extends AiTestCase
## Fire Breath: a cone from the caster's chest. It burns who stands in it,
## not who stands beside it or behind a wall, and its effects ask the same
## units_caught the preview outlines.

var BREATH: Ability = load("res://data/abilities/fire_breath.tres")


func run() -> void:
	var cone := BREATH.targeting as ConeTargeting
	var caster: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(0.0, 0.0, 0.0))
	var inside: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(5.0, 0.0, 0.0))
	var beside: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(0.0, 0.0, 6.0))
	var aim: Vector3 = Vector3(5.0, cone.origin(caster).y, 0.0)

	var caught: Array[Unit] = cone.units_caught(caster, aim, true, false)
	check("the unit in the cone is caught", inside in caught)
	check("the unit beside it is not", not beside in caught)
	check("pitched up 60 degrees it passes over",
		not inside in cone.units_caught(caster, aim + Vector3(0.0, 20.0, 0.0), true, false))

	var hp: int = inside.get_pool(StatIds.HP)
	var beside_hp: int = beside.get_pool(StatIds.HP)
	BREATH.effects[0].apply(caster, aim, BREATH, false)
	check("the breath burns who it catches", inside.get_pool(StatIds.HP) < hp)
	check("and no one else", beside.get_pool(StatIds.HP) == beside_hp)
	free_spawned()
