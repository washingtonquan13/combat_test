extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase of cloud reactions - NOT a test. A steam cloud
## between the hero and a dummy, a second one off to the side; Lightning
## Breath into the first electrifies the whole of it, the second stays
## steam. Record it the same way as fog_cloud_demo.

const LightningBreath: Ability = preload("res://data/abilities/lightning_breath.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	var middle: Vector3 = _spot(-4.5, 0.0)
	var aside: Vector3 = _spot(-4.5, 5.0)
	_dummy(-9.0, 0.0)
	var i: int = 0
	for member: Unit in PartyManager.members:
		if member != _hero:
			member.global_position = _spot(9.0 + i * 1.5, -9.0)
			i += 1
	SelectionManager.select(_hero)
	_hero.snap_face_direction(middle - _hero.global_position)
	_frame((middle + aside) * 0.5 + Vector3(0.0, 0.5, 0.0), 16.0)
	var steam: Surface = load("res://data/surfaces/steam_cloud.tres")
	_say("Two steam clouds")
	SurfaceManager.spawn(steam, middle + Vector3(0.0, 0.5, 0.0), 2.0, _hero)
	SurfaceManager.spawn(steam, aside + Vector3(0.0, 0.5, 0.0), 1.5, _hero)
	await _wait(3.0)
	_say("Lightning Breath into the near one")
	await _hero.use_ability(LightningBreath, LightningBreath.targeting.resolve_target_point(middle))
	await _wait(1.0)
	var shocked: Surface = load("res://data/surfaces/electrified_steam_cloud.tres")
	_check("the struck cloud is electrified", SurfaceManager.cloud_at(middle + Vector3(0.0, 0.5, 0.0), WorldManager.context()) == shocked)
	_check("the other is still steam", SurfaceManager.cloud_at(aside + Vector3(0.0, 0.5, 0.0), WorldManager.context()) == steam)
	_say("The whole cloud is electrified; the other stays steam")
	await _wait(5.0)
	get_tree().quit()
