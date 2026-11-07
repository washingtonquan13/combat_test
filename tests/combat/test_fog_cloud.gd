extends AiTestCase
## Fog Cloud: cubes that may hang in the air, stop at walls, block sight
## through them, and Blind whoever is inside only while they are inside. Out of
## combat it still runs out, a round per SurfaceManager.ROUND_SECONDS.
## Darkness is the same cloud, but Dark Vision sees through it.
## Lightning shot through steam or fog electrifies the whole of that cloud.

var FOG: Ability = load("res://data/abilities/fog_cloud.tres")
var DARKNESS: Ability = load("res://data/abilities/darkness.tres")


func run() -> void:
	var cloud: Surface = (FOG.effects[0] as SpawnSurfaceEffect).surface
	var archer: Unit = spawn_unit(&"enemy", 10, 10, 10, [melee()], Vector3(-6.0, 0.0, 0.0))
	var target: Unit = spawn_unit(&"player", 10, 10, 10, [melee()], Vector3(6.0, 0.0, 0.0))
	check("clear field: the archer sees the target", LineOfSight.has_clear_shot(archer, target))

	var context: WorldContext = WorldManager.context_for(archer)
	SurfaceManager.spawn(cloud, Vector3(0.0, 1.5, 0.0), 2.0, archer)
	check("a cloud between them blocks the shot", not LineOfSight.has_clear_shot(archer, target))

	SurfaceManager.expire_all_clouds(context)
	SurfaceManager.spawn(cloud, Vector3(0.0, 6.0, 0.0), 2.0, archer)
	check("a cloud hanging overhead does not", LineOfSight.has_clear_shot(archer, target))
	SurfaceManager.expire_all_clouds(context)

	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	shape.shape.size = Vector3(0.4, 6.0, 12.0)
	wall.add_child(shape)
	archer.get_parent().add_child(wall)
	wall.global_position = Vector3(30.0, 1.0, 0.0)
	await get_tree().physics_frame
	SurfaceManager.spawn(cloud, Vector3(29.0, 0.5, 0.0), 3.0, archer)
	check("a wall stops the cloud",
		SurfaceManager.cloud_at(Vector3(29.5, 1.5, 0.0), context) == cloud
		and SurfaceManager.cloud_at(Vector3(30.5, 1.5, 0.0), context) == null)
	SurfaceManager.expire_all_clouds(context)
	wall.free()

	SurfaceManager.spawn(cloud, target.global_position + Vector3(0.0, 1.0, 0.0), 2.0, archer)
	for _i in 2:
		await get_tree().process_frame
	var blinded: StatusEffect = cloud.status_effects[0]
	check("inside, the target is Blinded", target.has_status(blinded))
	target.global_position = Vector3(20.0, 0.0, 0.0)
	for _i in 2:
		await get_tree().process_frame
	check("stepping out takes Blinded off", not target.has_status(blinded))

	for _i in cloud.duration_rounds:
		SurfaceManager._on_quiet_round()
	check("with no fight, it runs out after its rounds", SurfaceManager._clouds_for(context).is_empty())

	var dark: Surface = (DARKNESS.effects[0] as SpawnSurfaceEffect).surface
	target.global_position = Vector3(6.0, 0.0, 0.0)
	archer.dark_vision = true
	target.dark_vision = true
	SurfaceManager.spawn(dark, target.global_position + Vector3(0.0, 1.0, 0.0), 2.0, archer)
	for _i in 2:
		await get_tree().process_frame
	SurfaceManager._on_turn_started(target)
	check("Dark Vision sees through Darkness", LineOfSight.has_clear_shot(archer, target) and not target.has_status(blinded))
	archer.dark_vision = false
	check("without it, Darkness blocks like fog", not LineOfSight.has_clear_shot(archer, target))
	SurfaceManager.expire_all_clouds(context)

	var steam: Surface = load("res://data/surfaces/steam_cloud.tres")
	var shocked: Surface = load("res://data/surfaces/electrified_steam_cloud.tres")
	SurfaceManager.spawn(steam, Vector3(0.0, 1.5, 0.0), 2.0, archer)
	SurfaceManager.spawn(steam, Vector3(0.0, 1.5, 12.0), 2.0, archer)
	SurfaceManager.touch(Surface.Element.LIGHTNING, null, archer, target)
	check("lightning shot through steam electrifies all of that cloud, not another",
		SurfaceManager.cloud_at(Vector3(0.0, 1.5, 0.0), context) == shocked
		and SurfaceManager.cloud_at(Vector3(0.0, 1.5, 1.6), context) == shocked
		and SurfaceManager.cloud_at(Vector3(0.0, 1.5, 12.0), context) == steam)
	SurfaceManager.expire_all_clouds(context)
	SurfaceManager.spawn(cloud, Vector3(0.0, 1.5, 0.0), 2.0, archer)
	SurfaceManager.touch(Surface.Element.LIGHTNING, null, archer, target)
	check("so does fog", SurfaceManager.cloud_at(Vector3(0.0, 1.5, 1.6), context) == shocked)
	SurfaceManager.expire_all_clouds(context)
	free_spawned()
