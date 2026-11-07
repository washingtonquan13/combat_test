extends "res://tools/weapons_demo.gd"
## Recorded review clip of the new Fire Bolt, Ray of Frost and Magic
## Missile visuals — NOT a test. Each spell twice at a dummy, the camera
## close on the line between caster and target, then Magic Missile at a
## dummy behind the arena's cover so its darts fly the route around it.

var _marker := Node3D.new()


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	_hero.set_base_stat(StatIds.DX, 18)
	_hero.set_base_stat(StatIds.IQ, 18)
	var target: Unit = _dummy(-9.0, 2.0)
	SelectionManager.select(_hero)
	_frame((_hero.global_position + target.global_position) * 0.5, 9.0)
	await _wait(2.0)
	for path in ["fire_bolt", "ray_of_frost", "magic_missile"]:
		var ability: Ability = load("res://data/abilities/%s.tres" % path)
		for i in 2:
			await _cast(ability, target, ability.ability_name)
	var hidden: Unit = _dummy(15.0, 0.0)
	_frame((_hero.global_position + hidden.global_position) * 0.5, 14.0)
	await _wait(1.5)
	var missile: Ability = load("res://data/abilities/magic_missile.tres")
	await _cast(missile, hidden, "Magic Missile at a dummy behind cover: the darts fly the route")
	await _cast(missile, hidden, "Magic Missile behind cover, again")
	await _wait(1.0)
	get_tree().quit()


func _cast(ability: Ability, target: Unit, caption: String) -> void:
	_say(caption)
	await _wait(0.8)
	var result: Dictionary = await _hero.use_ability(ability, target)
	print("CAST ", ability.ability_name, " -> ", result.keys(), " hit=", result.get("hit", "?"))
	await _wait(2.2)


func _frame(point: Vector3, distance: float) -> void:
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	if not _marker.is_inside_tree():
		WorldManager.spawn_parent().add_child(_marker)
	_marker.global_position = point
	camera.focus_target = _marker
	camera.target_anchor_offset = Vector3.ZERO
	camera.target_distance = distance
	camera.target_yaw = camera.current_yaw + 70.0
