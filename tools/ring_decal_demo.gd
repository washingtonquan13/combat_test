extends "res://tools/fog_cloud_demo.gd"
## Recorded showcase of the ground ring (Tier 2 item 8) - NOT a test.
## Selected vs hovered weight, relation hues, the ring on a raised slab,
## a flier's ring on the ground with its drop line, and a flier over a
## bridge: one ring, on the bridge, never the ground under it.
## Record WITHOUT --rendering-driver opengl3: decals need Forward+.

var _flier: Unit


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	var ally: Unit = _dummy(-3.0, -2.0)
	var foe: Unit = _nearest_enemy()
	SelectionManager.select(_hero)
	_frame(_spot(-1.5, 0.0), 6.0)
	await _wait(2.0)

	_say("Selected: thick party-blue ring, projected on the floor")
	await _wait(3.0)
	_hover(ally, true)
	_say("Hovered party member: thin and dimmer")
	await _wait(3.0)
	_hover(ally, false)
	if foe:
		_frame(foe.global_position, 6.0)
		await _wait(1.0)
		_hover(foe, true)
		_say("Hovered enemy (arena goblin): vermillion")
		await _wait(3.0)
		_hover(foe, false)

	var slab_at: Vector3 = _spot(-7.0, 0.0)
	_box(slab_at + Vector3(0.0, 0.4, 0.0), Vector3(3.0, 0.8, 3.0))
	_say("Walk onto a raised slab: the ring hugs its top")
	_frame(_spot(-5.0, 0.0), 7.0)
	await _wait(1.0)
	await _walk(_hero, slab_at + Vector3(0.0, 0.8, 0.0))
	await _wait(2.5)
	await _walk(_hero, slab_at + Vector3(0.0, 0.0, 3.0))
	await _wait(1.0)

	_say("A flier: ring on the ground below, drop line to the body")
	_flier = ally
	_flier.apply_status(load("res://data/statuses/flying.tres"))
	SelectionManager.select(_flier)
	var lift_from: Vector3 = _flier.global_position
	_frame(lift_from + Vector3(0.0, 1.5, 0.0), 8.0)
	await _rise(_flier, lift_from + Vector3(0.0, 4.0, 0.0), 2.5)
	await _wait(2.5)

	var bridge_at: Vector3 = lift_from + _hero.visual_forward() * -6.0
	_box(bridge_at + Vector3(0.0, 2.0, 0.0), Vector3(2.0, 0.3, 6.0))
	_say("Over a bridge: one ring, on the bridge, not on the ground under it")
	_frame(lift_from.lerp(bridge_at, 0.5) + Vector3(0.0, 2.0, 0.0), 13.0)
	await _wait(1.0)
	await _rise(_flier, bridge_at + Vector3(0.0, 4.0, 0.0), 3.0)
	await _wait(2.5)
	await _rise(_flier, bridge_at + _hero.visual_forward() * -5.0 + Vector3(0.0, 4.0, 0.0), 2.5)
	_say("Past the bridge it drops back to the ground")
	await _wait(3.0)
	get_tree().quit()


## A hostile unit already in the arena, hovered without starting a fight.
func _nearest_enemy() -> Unit:
	var best: Unit = null
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Unit
		if unit and FactionRelations.is_hostile(unit.faction, _hero.faction) 				and (best == null or unit.global_position.distance_to(_hero.global_position) < best.global_position.distance_to(_hero.global_position)):
			best = unit
	return best


func _hover(unit: Unit, on: bool) -> void:
	var selection: UnitSelection = unit.get_node("Selection")
	if on:
		selection.on_mouse_entered()
	else:
		selection.on_mouse_exited()


## Moves a flier with no gravity fighting the tween.
func _rise(unit: Unit, to: Vector3, seconds: float) -> void:
	var tween := create_tween()
	tween.tween_property(unit, "global_position", to, seconds)
	await tween.finished


func _box(center: Vector3, size: Vector3) -> void:
	var box := CSGBox3D.new()
	box.size = size
	box.use_collision = true
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.42, 0.38)
	box.material = material
	WorldManager.spawn_parent().add_child(box)
	box.global_position = center
