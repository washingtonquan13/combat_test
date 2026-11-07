extends AiTestCase
## The Jackson Square blockout is walkable the way the place is: from
## Decatur Street into the square, up onto the levee by the amphitheater or
## over the grass bank, and not into the Pontalba courtyards, which the map
## has closed on every side.
##
## It is the first level built from real data rather than proto blocks, so
## this is also the first time the navigation grid has been asked to climb a
## slope it did not get as a flat floor, or to cross a map 290 m wide.

const SCENE := "res://world/jackson_square.tscn"
## The party spawn, on Decatur Street between the square and the levee.
const SPAWN := Vector3(36.0, 0.0, 62.0)
const STATUE_SIDE := Vector3(5.0, 0.0, 10.0)
## On the Washington Artillery Park deck, reached by its amphitheater ramp.
const DECK := Vector3(90.3, 4.0, 63.7)
## On the levee crest past the grass bank, upriver of the brewery.
const CREST := Vector3(82.7, 4.0, 122.4)
## Inside a courtyard of the Lower Pontalba Building.
const COURTYARD := Vector3(56.8, 0.0, -72.9)
## Royal at Orleans, behind the cathedral: the far corner of the map, about
## 250 m of street from the spawn by way of Pere Antoine Alley.
const FAR_CORNER := Vector3(-122.54, 0.0, -121.31)


func run() -> void:
	var area: Node3D = load(SCENE).instantiate()
	_root.add_child(area)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var context := WorldContext.new(area)
	add_child(context)

	var walker: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	area.add_child(walker)
	walker.faction = &"player"
	walker.global_position = SPAWN
	# Settled, not placed: a route asked for from a body still in the air
	# starts in a cell nothing supports and comes back empty.
	for i in 20:
		await get_tree().physics_frame

	var into_square := _route(walker, STATUE_SIDE, "into the square")
	check("a unit walks from Decatur into the square", into_square.size() > 0)

	var deck := _route(walker, DECK, "up the amphitheater")
	check("and up the amphitheater onto the deck", _reaches(deck, DECK),
		"route of %d points ending at %s" % [deck.size(), deck[-1] if deck.size() else "-"])

	var crest := _route(walker, CREST, "over the bank")
	check("and over the grass bank onto the levee crest", _reaches(crest, CREST),
		"route of %d points ending at %s" % [crest.size(), crest[-1] if crest.size() else "-"])

	# An empty route cannot tell "sealed" from "the search gave up", so
	# the courtyard is asked from the inside: walkable within, no way out.
	var within := NavigationGrid.find_path(get_tree(), COURTYARD, COURTYARD + Vector3(1.0, 0.0, 0.0), walker, false)
	var out_of := NavigationGrid.find_path(get_tree(), COURTYARD, STATUE_SIDE, walker, false)
	check("a Pontalba courtyard is floor inside", within.size() > 0)
	check("but closed on every side", out_of.is_empty(),
		"route of %d points out of the courtyard" % out_of.size())

	var far := _route(walker, FAR_CORNER, "across the map")
	check("and across the whole map to Royal at Orleans", _reaches(far, FAR_CORNER),
		"route of %d points ending at %s" % [far.size(), far[-1] if far.size() else "-"])

	if walker.is_in_group("units"):
		walker.remove_from_group("units")
	area.remove_child(walker)
	walker.queue_free()
	context.dispose()
	context.queue_free()
	PartyManager.clear_members()
	_root.remove_child(area)
	area.queue_free()
	await get_tree().process_frame
	NavigationGrid.invalidate()


func _route(walker: Unit, to: Vector3, label: String) -> PackedVector3Array:
	var started := Time.get_ticks_usec()
	var path: PackedVector3Array = NavigationGrid.find_path(get_tree(), walker.global_position, to, walker, false)
	print("    %s: %d points, %.1f ms" % [label, path.size(), (Time.get_ticks_usec() - started) / 1000.0])
	return path


## find_path ends at the nearest reachable cell when the goal itself is not,
## so an unreachable goal still returns a route; only where it ends tells.
func _reaches(path: PackedVector3Array, goal: Vector3) -> bool:
	return path.size() > 0 and Vector2(path[-1].x, path[-1].z).distance_to(Vector2(goal.x, goal.z)) < 1.5 \
		and absf(path[-1].y - goal.y) < 1.5
