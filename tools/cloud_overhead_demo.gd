extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase - NOT a test. Fog Cloud cast straight over the hero's
## head, then Lightning Breath pitched up into it: the whole fog turns to
## Electrified Steam. Record it the same way as fog_cloud_demo.

const LightningBreath: Ability = preload("res://data/abilities/lightning_breath.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	var i: int = 0
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.global_position = _spot(9.0 + i * 1.5, -9.0)
			i += 1
	SelectionManager.select(_hero)
	var overhead: Vector3 = _hero.global_position + Vector3(0.0, 12.0, 0.0)
	_frame(_hero.global_position + Vector3(0.0, 6.5, 0.0), 24.0)
	_side_view()
	await _wait(1.5)
	_say("Fog Cloud, straight overhead")
	await _hero.use_ability(Fog, overhead)
	await _wait(3.0)
	_say("Lightning Breath, pitched up into it")
	await _wait(1.0)
	var up: Vector3 = _hero.global_position + _hero.visual_forward() * 0.5 + Vector3(0.0, 12.0, 0.0)
	await _hero.use_ability(LightningBreath, up)
	await _wait(1.0)
	var shocked: Surface = load("res://data/surfaces/electrified_steam_cloud.tres")
	_check("the fog overhead is electrified", SurfaceManager.cloud_at(overhead, WorldManager.context()) == shocked)
	_say("The whole fog is now Electrified Steam")
	await _wait(5.0)
	get_tree().quit()


## Flattens the camera to a near-level side view: pitch follows zoom
## between min_pitch and max_pitch, so pin both.
func _side_view() -> void:
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	camera.min_pitch = 4.0
	camera.max_pitch = 4.0
	camera.max_distance = 30.0
