extends AiTestCase
## Wall of Fire: two clicks make the line, the wall is an opaque cloud that
## sets walkers and fliers Burning with no ground fire under it, and running
## out leaves burning ground with its whole duration.

var WALL: Ability = load("res://data/abilities/wall_of_fire.tres")


func run() -> void:
	var targeting := WALL.targeting as LineTargeting
	var wall: Surface = (WALL.effects[0] as SpawnSurfaceEffect).surface
	var caster: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(-6.0, 0.0, 0.0))
	var target: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(6.0, 0.0, 0.0))
	var context: WorldContext = WorldManager.context_for(caster)

	AbilityManager.clear_line_start()
	var first = targeting.resolve_click(caster, Vector3(0.0, 0.0, -2.0))
	check("the first click holds the start", first == null and AbilityManager.has_line_start)
	var line = targeting.resolve_click(caster, Vector3(0.0, 0.0, 40.0))
	check("the second click makes a line, pulled in to max_length",
		line is LineTarget and is_equal_approx(line.from.distance_to(line.to), targeting.max_length))
	AbilityManager.clear_line_start()

	SurfaceManager.spawn_wall(wall, Vector3(0.0, 0.0, -5.0), Vector3(0.0, 0.0, 5.0), caster)
	check("the wall blocks sight", not LineOfSight.has_clear_shot(caster, target))
	check("no ground fire under it (no double dip)", SurfaceManager.surface_at(Vector3.ZERO, context) == null)
	target.global_position = Vector3(0.0, 2.5, 0.0)
	for _i in 2:
		await get_tree().process_frame
	check("a flier inside is Burning", target.has_status(wall.status_effect))

	for _i in wall.duration_rounds:
		SurfaceManager._age(SurfaceManager._clouds_for(context), SurfaceManager._grid_for(context))
	var cell: SurfaceCell = SurfaceManager._grid_for(context).cell_under(Vector3.ZERO)
	check("running out leaves burning ground with its full rounds",
		SurfaceManager._clouds_for(context).is_empty() and cell != null and cell.surface == wall.leaves_behind
		and cell.rounds == wall.leaves_behind.duration_rounds)
	SurfaceManager.expire_all_clouds(context)
	free_spawned()
