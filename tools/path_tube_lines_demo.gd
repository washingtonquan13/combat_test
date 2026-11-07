extends "res://tools/path_tube_demo.gd"
## Recorded showcase: every indicator line is now the PathTube - NOT a test.

const RangedAbility: Ability = preload("res://data/abilities/basic_attack_ranged.tres")
const FireballAbility: Ability = preload("res://data/abilities/explosive_fireball.tres")
const WallAbility: Ability = preload("res://data/abilities/wall_of_fire.tres")
const JumpAbility: Ability = preload("res://data/abilities/jump.tres")
const MissileAbility: Ability = preload("res://data/abilities/magic_missile.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	var ally: Unit = _dummy(-3.0, -2.0)
	SelectionManager.select(_hero)
	_frame(_spot(-3.0, 0.0), 8.0)
	await _wait(1.5)

	var steps: Array = [
		["Ranged attack: line of sight", RangedAbility, ally.global_position + Vector3(0.0, 1.0, 0.0)],
		["Grease: aim line to the ring", GreaseAbility, _spot(-6.0, 1.5)],
		["Fireball: aim line to the ring", FireballAbility, _spot(-6.5, -1.5)],
		["Jump: the arc", JumpAbility, _spot(-5.0, 2.0)],
		["Magic missile: seeking path", MissileAbility, ally.global_position + Vector3(0.0, 1.0, 0.0)],
	]
	for step in steps:
		_say(step[0])
		AbilityManager.arm(step[1])
		await _glide(_screen(_spot(-4.0, -0.5)), 0, 10)
		await _glide(_screen(step[2]), 0, 40)
		await _wait(2.5)
		AbilityManager.disarm()
		await _wait(0.3)

	_say("Wall of Fire: aim line, then the wall outline")
	AbilityManager.arm(WallAbility)
	await _glide(_screen(_spot(-4.5, -1.5)), 0, 30)
	await _wait(1.5)
	AbilityManager.set_line_start(_spot(-4.5, -1.5))
	await _glide(_screen(_spot(-6.5, 1.5)), 0, 40)
	await _wait(3.0)
	AbilityManager.disarm()

	_say("A flier: drop line to the ground")
	ally.apply_status(load("res://data/statuses/flying.tres"))
	SelectionManager.select(ally)
	var lift_from: Vector3 = ally.global_position
	_frame(lift_from + Vector3(0.0, 1.5, 0.0), 7.0)
	await _rise(ally, lift_from + Vector3(0.0, 4.0, 0.0), 2.5)
	await _wait(3.0)
	get_tree().quit()
