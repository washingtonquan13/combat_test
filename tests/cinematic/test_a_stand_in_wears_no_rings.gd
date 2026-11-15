extends AiTestCase
## A stand-in is a body in a shot, not a unit on a board. Whatever the
## unit's own body was showing for the player when the copy was raised
## (hover outline, selection ring) does not come with it, and is still the
## unit's own when the copy is struck.


func wants_world() -> bool:
	return true


func run() -> void:
	var unit: Unit = spawn_brute(0.0, 0.0)
	await get_tree().process_frame
	unit.set_selected(true)
	unit.set_hovered(true)
	await get_tree().physics_frame
	await get_tree().process_frame
	var own: CharacterModel = StandIn.body_of(unit)
	check("the unit shows a ring and an outline before the scene",
		own.outline_mesh != null and own.outline_mesh.visible \
				and _shown(own.find_children("*", "Decal", true, false)) > 0,
		"outline %s, rings %d" % [own.outline_mesh.visible if own.outline_mesh else null,
			_shown(own.find_children("*", "Decal", true, false))])

	var stand: StandIn = StandIn.raise(unit, Vector3(4.0, 0.0, 0.0), Vector3.FORWARD)
	await get_tree().process_frame
	var copy: CharacterModel = stand.body()
	var decals: Array = copy.find_children("*", "Decal", true, false)
	var outlines: Array = copy.find_children("*", "MeshInstance3D", true, false).filter(
		func(mesh: MeshInstance3D) -> bool: return mesh.name == own.outline_mesh.name)
	check("the copy carries no selection ring",
		_shown(decals) == 0, "%d ring decals showing on the copy" % _shown(decals))
	check("the copy carries no hover outline",
		outlines.filter(func(mesh: MeshInstance3D) -> bool: return mesh.is_visible_in_tree()).is_empty(),
		"outline showing on the copy")

	stand.strike()
	await get_tree().process_frame
	check("the unit's own ring is back when the copy is struck",
		own.outline_mesh.visible and _shown(own.find_children("*", "Decal", true, false)) > 0,
		"ring or outline gone from the unit")
	unit.set_hovered(false)
	unit.set_selected(false)


func _shown(nodes: Array) -> int:
	return nodes.filter(func(node: Node3D) -> bool: return node.is_visible_in_tree()).size()
