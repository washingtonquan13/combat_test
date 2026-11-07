extends "res://tools/path_tube_demo.gd"
## Recorded showcase of the AoE shell - NOT a test.
## Record WITHOUT --rendering-driver opengl3: the cut line needs depth.

const FireballAbility: Ability = preload("res://data/abilities/explosive_fireball.tres")


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var slab_at: Vector3 = _spot(-7.0, 0.0)
	_box(slab_at + Vector3(0.0, 0.4, 0.0), Vector3(3.0, 0.8, 3.0))
	_frame(_spot(-5.5, 0.0), 9.0)
	await _wait(1.5)

	_say("Grease: footprint traced on the terrain, up the slab")
	AbilityManager.arm(GreaseAbility)
	await _glide(_screen(_spot(-3.0, 2.0)), 0, 20)
	await _glide(_screen(slab_at + Vector3(0.0, 0.0, 1.6)), 0, 50)
	await _wait(2.5)
	AbilityManager.disarm()

	_say("Fireball on the ground: a dome with its own ring")
	AbilityManager.arm(FireballAbility)
	await _glide(Vector2(1250, 330), 0, 40)
	await _wait(2.5)
	_say("Against the slab: the cut line shows what it clips")
	await _glide(_screen(slab_at + Vector3(0.0, 0.8, -1.5)), 0, 40)
	await _wait(2.5)

	_say("Over the party: who it would catch is outlined")
	var enemy: Unit = _nearest_enemy()
	var toward: Vector3 = (slab_at - _hero.global_position).normalized()
	if enemy:
		enemy.global_position = _hero.global_position + toward * 4.5 + Vector3(0.0, 0.0, 0.0)
	await _glide(_screen(_hero.global_position + toward * 2.5), 0, 40)
	await _wait(3.0)
	await _glide(Vector2(1150, 330), 0, 40)
	await _wait(1.0)

	_say("Lifted into the air")
	var base_y: float = _hero.global_position.y
	for i in 40:
		AbilityManager.set_aim_height_override(base_y + 2.0 * float(i) / 39.0)
		await get_tree().process_frame
	await _wait(1.0)
	await _glide(Vector2(1150, 700), 0, 40)
	await _wait(2.5)
	AbilityManager.disarm()

	_say("Wall of Fire: a slab standing along the line")
	var wall: Ability = load("res://data/abilities/wall_of_fire.tres")
	AbilityManager.arm(wall)
	var wall_start: Vector3 = slab_at + Vector3(2.5, 0.0, -3.0)
	AbilityManager.set_line_start(wall_start)
	if enemy:
		enemy.global_position = slab_at + Vector3(2.5, 0.0, 1.5)
	await _glide(_screen(wall_start + Vector3(0.0, 0.0, 1.0)), 0, 20)
	await _glide(_screen(slab_at + Vector3(2.5, 0.0, 4.0)), 0, 50)
	await _wait(2.0)
	await _glide(_screen(slab_at + Vector3(-1.0, 0.0, 3.0)), 0, 50)
	await _wait(2.5)
	AbilityManager.disarm()

	_say("Fire Breath: a cone from the chest, turned by the cursor")
	AbilityManager.has_aim_height_override = false
	var breath: Ability = load("res://data/abilities/fire_breath.tres")
	AbilityManager.arm(breath)
	var fwd: Vector3 = (slab_at - _hero.global_position)
	fwd.y = 0.0
	fwd = fwd.normalized()
	var side: Vector3 = Vector3.UP.cross(fwd)
	if enemy:
		enemy.global_position = _hero.global_position + fwd * 5.0 + side * 1.0
	await _glide(_screen(_hero.global_position + fwd * 4.0 - side * 5.0), 0, 30)
	await _wait(1.5)
	await _glide(_screen(_hero.global_position + fwd * 4.0 + side * 1.0), 0, 50)
	await _wait(2.5)
	await _glide(_screen(_hero.global_position + fwd * 4.0 + side * 6.0), 0, 50)
	await _wait(2.0)
	await _glide(_screen(_hero.global_position + fwd * 4.0 + side * 1.0), 0, 40)
	_say("Height drag pitches it up")
	var aim_y: float = _hero.global_position.y + 1.3
	for i in 40:
		AbilityManager.set_aim_height_override(aim_y + 4.0 * float(i) / 39.0)
		await get_tree().process_frame
	await _wait(2.5)
	AbilityManager.disarm()
	get_tree().quit()


func _box(center: Vector3, size: Vector3) -> void:
	var box := CSGBox3D.new()
	box.size = size
	box.use_collision = true
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.42, 0.38)
	box.material = material
	WorldManager.spawn_parent().add_child(box)
	box.global_position = center


func _nearest_enemy() -> Unit:
	var best: Unit = null
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit and FactionRelations.is_hostile(unit.faction, _hero.faction) 				and (best == null or unit.global_position.distance_to(_hero.global_position) < best.global_position.distance_to(_hero.global_position)):
			best = unit
	return best
