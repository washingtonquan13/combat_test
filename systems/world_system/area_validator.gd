class_name AreaValidator
extends RefCounted
## Author-time integrity check over every AreaDefinition and every
## AreaExit in the project. Static, no instances, not an autoload — same
## idiom as AreaDatabase itself.
##
## Exists because area wiring fails LATE and far from its cause: an
## AreaDefinition with an unset world_scene doesn't complain when it's
## saved, it crashes at travel time, in a different scene, possibly weeks
## later. Everything checked here is knowable from the data alone, so it
## should be knowable before the game runs at all.
##
## Deliberately splits ERRORS from WARNINGS. An error is content that
## cannot work — a dangling target_area, a null world_scene. A warning is
## content that is merely unusual and might be intentional: a one-way
## link is legal (a trapdoor, a point of no return), and an area with no
## inbound exits is legal while it's still being built. Warnings must
## never fail a run, or the check becomes something people learn to
## ignore.
##
## Scene traversal instantiates each world_scene but never adds it to the
## tree, so _ready() and @onready never fire — this inspects authored
## structure only, and nothing here can be perturbed by runtime state.

## One problem found. `where` is an area id or a scene-relative node path,
## whichever locates the fault better for whoever has to fix it.
class Issue extends RefCounted:
	var fatal: bool
	var where: String
	var message: String

	func _init(p_fatal: bool, p_where: String, p_message: String) -> void:
		fatal = p_fatal
		where = p_where
		message = p_message

	func format() -> String:
		return "%s  %s: %s" % ["ERROR " if fatal else "warn  ", where, message]


## Returns every Issue found, errors and warnings together, in the order
## the checks run. Empty means the project's area graph is sound.
static func validate() -> Array[Issue]:
	var issues: Array[Issue] = []
	var areas: Array[AreaDefinition] = AreaDatabase.get_all()

	if areas.is_empty():
		issues.append(Issue.new(true, String(AreaDatabase.AREAS_DIR), "no AreaDefinition resources found at all"))
		return issues

	_check_definitions(areas, issues)

	# Exits are checked against the id set rather than AreaDatabase.find()
	# so a duplicate-id project still reports every dangling link instead
	# of silently resolving through whichever duplicate won the scan.
	var known_ids: Dictionary = {}
	for area in areas:
		known_ids[area.id] = true

	var links: Dictionary = {}  # StringName -> Dictionary of StringName -> true
	for area in areas:
		links[area.id] = {}

	for area in areas:
		if not area.world_scene:
			continue  # already reported as an error above
		_check_exits(area, known_ids, links, issues)

	_check_topology(areas, links, issues)
	return issues


static func _check_definitions(areas: Array[AreaDefinition], issues: Array[Issue]) -> void:
	var seen_ids: Dictionary = {}
	for area in areas:
		var where: String = area.resource_path if area.resource_path else "<unsaved AreaDefinition>"

		if area.id == &"":
			issues.append(Issue.new(true, where, "id is empty"))
		elif seen_ids.has(area.id):
			issues.append(Issue.new(true, where, "duplicate id '%s' — also used by %s" % [area.id, seen_ids[area.id]]))
		else:
			seen_ids[area.id] = where

		if not area.world_scene:
			issues.append(Issue.new(true, where, "world_scene is unset — travel to this area will crash"))

		if area.display_name.is_empty():
			issues.append(Issue.new(false, where, "display_name is empty"))

		# Music is optional by design (MusicManager simply plays nothing),
		# so a missing exploration track is a warning about a silent area,
		# not a fault.
		if not area.exploration_track:
			issues.append(Issue.new(false, where, "no exploration_track — this area will be silent"))


static func _check_exits(area: AreaDefinition, known_ids: Dictionary, links: Dictionary, issues: Array[Issue]) -> void:
	var world: Node = area.world_scene.instantiate()
	var exits: Array[AreaExit] = []
	_collect_exits(world, exits)

	if exits.is_empty():
		issues.append(Issue.new(false, String(area.id), "has no AreaExit anywhere — nothing leads out of it"))

	for exit in exits:
		var where: String = "%s/%s" % [area.id, world.get_path_to(exit)]

		if exit.target_area == &"":
			issues.append(Issue.new(true, where, "target_area is empty"))
			continue

		if not known_ids.has(exit.target_area):
			issues.append(Issue.new(true, where, "target_area '%s' names no known area" % exit.target_area))
			continue

		links[area.id][exit.target_area] = true

		if exit.target_spawn_point != &"":
			_check_spawn_point(exit, where, issues)

		if exit.arrival_point and not is_instance_valid(exit.arrival_point):
			issues.append(Issue.new(true, where, "arrival_point reference is broken"))

	world.free()


## An explicit target_spawn_point is a node NAME resolved inside the
## destination scene (see GameArea.get_spawn_point) — so it can go stale
## on a rename with nothing to catch it. That's exactly the class of bug
## this file exists for.
static func _check_spawn_point(exit: AreaExit, where: String, issues: Array[Issue]) -> void:
	var target: AreaDefinition = AreaDatabase.find(exit.target_area)
	if not target or not target.world_scene:
		return  # the dangling target itself is already an error

	var target_world: Node = target.world_scene.instantiate()
	if not target_world.find_child(String(exit.target_spawn_point), true, false):
		issues.append(Issue.new(true, where, "target_spawn_point '%s' does not exist in area '%s'" % [exit.target_spawn_point, exit.target_area]))
	target_world.free()


static func _check_topology(areas: Array[AreaDefinition], links: Dictionary, issues: Array[Issue]) -> void:
	var inbound: Dictionary = {}
	for area in areas:
		inbound[area.id] = 0
	for from_id in links:
		for to_id in links[from_id]:
			inbound[to_id] = int(inbound[to_id]) + 1

	for area in areas:
		if int(inbound[area.id]) == 0:
			issues.append(Issue.new(false, String(area.id), "unreachable — no other area has an exit leading here"))

	# One-way links are legal content (a trapdoor, a point of no return),
	# so this only ever warns. It's still worth surfacing: the overwhelming
	# majority of one-way links in practice are an exit someone forgot to
	# pair, and WorldManager's back-link spawn derivation silently falls
	# back to a bare marker when the return exit is missing.
	for from_id in links:
		for to_id in links[from_id]:
			if not links.has(to_id) or not links[to_id].has(from_id):
				issues.append(Issue.new(false, String(from_id), "one-way link to '%s' — '%s' has no exit back" % [to_id, from_id]))


static func _collect_exits(node: Node, into: Array[AreaExit]) -> void:
	if node is AreaExit:
		into.append(node)
	for child in node.get_children():
		_collect_exits(child, into)
