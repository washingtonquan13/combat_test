extends "res://tools/tier3_demo.gd"
## Recorded showcase of the BG3-style movement tube - NOT a test.

const GreaseAbility: Ability = preload("res://data/abilities/grease.tres")
const FogAbility: Ability = preload("res://data/abilities/fog_cloud.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var camera: CRPGCamera = _camera()
	_frame(_spot(-4.0, 0.0), 9.0)
	await _wait(2.0)

	_say("Hover: thin white tube, fades in and out over a metre")
	await _glide(_screen(_spot(-6.0, 2.0)), 0, 40)
	await _wait(1.5)
	await _glide(_screen(_spot(-8.0, -2.5)), 0, 50)
	await _wait(1.5)

	_say("Close up")
	_frame(_spot(-4.0, -1.0), 4.0)
	await _wait(2.0)
	await _glide(_screen(_spot(-6.0, -1.5)), 0, 30)
	await _wait(2.0)

	_say("Over grease: yellow (hazard)")
	_frame(_spot(-4.0, 0.0), 9.0)
	SurfaceManager.spawn((GreaseAbility.effects[0] as SpawnSurfaceEffect).surface, _spot(-4.0, 0.0), 1.5, _hero)
	await _wait(1.5)
	await _glide(_screen(_spot(-8.0, 0.0)), 0, 30)
	await _wait(3.0)

	_say("Behind a wall: 10% through it")
	var target: Vector3 = _spot(-8.0, -3.0)
	var eye: Vector3 = camera.global_position
	var wall_at: Vector3 = _hero.global_position.lerp(target, 0.6)
	wall_at = wall_at.lerp(Vector3(eye.x, wall_at.y, eye.z), 0.15)
	var wall := _solid(wall_at + Vector3(0.0, 1.5, 0.0), Vector3(5.0, 3.0, 0.3))
	wall.look_at(Vector3(eye.x, wall.global_position.y, eye.z))
	await _wait(0.5)
	await _glide(_screen(target), 0, 30)
	await _wait(3.0)
	wall.queue_free()

	_say("Through fog: yellow and dashed (heavily obscured)")
	await _hero.use_ability(FogAbility, _spot(-4.0, 4.0) + Vector3(0.0, 1.0, 0.0))
	await _wait(2.0)
	await _glide(_screen(_spot(-8.0, 4.5)), 0, 30)
	await _wait(3.5)

	_say("In combat: crimson past the move budget")
	var foe: Unit = _nearest_enemy()
	CombatManager.start_combat([_hero, foe] as Array[Unit])
	await _wait(2.0)
	SelectionManager.select(_hero)
	_frame(_hero.global_position, 9.0)
	await _wait(1.5)
	await _glide(_screen(_hero.global_position + Vector3(-2.0, 0.0, -12.0)), 0, 40)
	await _wait(3.0)
	await _glide(_screen(_hero.global_position + Vector3(3.0, 0.0, -7.0)), 0, 40)
	await _wait(2.0)
	get_tree().quit()
