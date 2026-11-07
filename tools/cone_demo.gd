extends "res://tools/aoe_shell_demo.gd"
## Recorded showcase of the cone indicator, on the ground and in the air - NOT a test.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var slab_at: Vector3 = _spot(-7.0, 0.0)
	_box(slab_at + Vector3(0.0, 0.4, 0.0), Vector3(3.0, 0.8, 3.0))
	_frame(_spot(-5.5, 0.0), 10.0)
	var enemy: Unit = _nearest_enemy()
	var fwd: Vector3 = (slab_at - _hero.global_position)
	fwd.y = 0.0
	fwd = fwd.normalized()
	var side: Vector3 = Vector3.UP.cross(fwd)
	if enemy:
		enemy.global_position = _hero.global_position + fwd * 5.0 + side * 1.0
	await _wait(1.0)

	_say("Fire Breath: a cone from the chest, turned by the cursor")
	var breath: Ability = load("res://data/abilities/fire_breath.tres")
	AbilityManager.arm(breath)
	await _glide(_screen(_hero.global_position + fwd * 4.0 - side * 5.0), 0, 30)
	await _wait(1.0)
	await _glide(_screen(_hero.global_position + fwd * 4.0 + side * 1.0), 0, 50)
	await _wait(2.0)
	await _glide(_screen(_hero.global_position + fwd * 4.0 + side * 6.0), 0, 50)
	await _wait(1.0)
	await _glide(_screen(_hero.global_position + fwd * 4.0 + side * 1.0), 0, 40)
	_say("Height drag pitches it up")
	var aim_y: float = _hero.global_position.y + 1.3
	for i in 40:
		AbilityManager.set_aim_height_override(aim_y + 4.0 * float(i) / 39.0)
		await get_tree().process_frame
	await _wait(2.0)
	AbilityManager.disarm()

	_say("In the air: the cone hangs from the flier's chest")
	var fly: Ability = load("res://data/abilities/fly.tres")
	fly.effects[0].apply(_hero, null, fly, false)
	await _wait(2.0)
	AbilityManager.arm(breath)
	_say("Aimed at the ground, it pitches down onto it")
	await _glide(_screen(_hero.global_position + fwd * 2.0 - side * 3.0 + Vector3.DOWN * 3.0), 0, 30)
	await _wait(1.0)
	await _glide(_screen(enemy.global_position if enemy else _hero.global_position + fwd * 5.0), 0, 50)
	await _wait(2.5)
	await _glide(_screen(_hero.global_position + fwd * 2.0 + side * 4.0 + Vector3.DOWN * 3.0), 0, 50)
	await _wait(1.5)
	_say("Height drag levels it out over their heads")
	var air_y: float = _hero.global_position.y - 4.0
	for i in 40:
		AbilityManager.set_aim_height_override(air_y + 4.0 * float(i) / 39.0)
		await get_tree().process_frame
	await _wait(2.5)
	AbilityManager.disarm()
	get_tree().quit()
