extends AiTestCase
## Fog Cloud: a sphere that may hang in the air, blocks sight through it,
## and Blinds whoever is inside only while they are inside. Out of
## combat it still runs out, a round per SurfaceManager.ROUND_SECONDS.

var FOG: Ability = load("res://data/abilities/fog_cloud.tres")


func run() -> void:
	var cloud: Surface = (FOG.effects[0] as SpawnSurfaceEffect).surface
	var archer: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(-6.0, 0.0, 0.0))
	var target: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(6.0, 0.0, 0.0))
	check("clear field: the archer sees the target", LineOfSight.has_clear_shot(archer, target))

	var fog: ActiveSurface = SurfaceManager.spawn(cloud, Vector3(0.0, 1.5, 0.0), 2.0, archer)
	check("a cloud between them blocks the shot", not LineOfSight.has_clear_shot(archer, target))

	SurfaceManager._expire(fog)
	fog = SurfaceManager.spawn(cloud, Vector3(0.0, 6.0, 0.0), 2.0, archer)
	check("a cloud hanging overhead does not", LineOfSight.has_clear_shot(archer, target))
	SurfaceManager._expire(fog)

	fog = SurfaceManager.spawn(cloud, target.global_position + Vector3(0.0, 1.0, 0.0), 2.0, archer)
	for _i in 3:
		await get_tree().physics_frame
	var blinded: StatusEffect = cloud.status_effect
	check("inside, the target is Blinded", target.has_status(blinded))
	target.global_position = Vector3(20.0, 0.0, 0.0)
	for _i in 3:
		await get_tree().physics_frame
	check("stepping out takes Blinded off", not target.has_status(blinded))

	for _i in cloud.duration_rounds:
		SurfaceManager._on_quiet_round()
	check("with no fight, it runs out after its rounds", not SurfaceManager._list_for(fog.context).has(fog))
	free_spawned()
