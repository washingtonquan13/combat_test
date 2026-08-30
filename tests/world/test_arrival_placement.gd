extends AiTestCase
## Units arrive standing on the ground, not in the sky.
##
## Reproduces a reported sequence: one member walks into the cathedral, two
## more are sent to the overworld, and when those two then travel to the
## cathedral they are nowhere to be found — their Y is in the thousands.
##
## Placement runs through PartyManager.place_at_landing, which asks
## NavigationGrid.nearest_valid_point for a spot near the arrival marker.
## That query resolves WHICH WORLD it means from the unit it is handed
## (see NavigationGrid.activate_for), so a unit asking before it is really
## in the destination — or a destination whose grid has not been scanned —
## gets an answer in some other world's frame of reference. Nothing about
## that fails loudly; it just returns a point.

const HOME := &"test_arena"
const CATHEDRAL := &"cathedral_of_shadows"

## Every area in this project is authored around the origin and none is
## remotely this tall, so anything past it is not a placement, it is a
## number from somewhere else.
const SANE_HEIGHT: float = 100.0

var _host: Control
var _saved_host: Control = null
var _saved_attention: Array[Node] = []


func run() -> void:
	if not _install_synthetic_host():
		check("SETUP: synthetic world host installed", false, "WorldManager refused")
		return

	await _the_reported_sequence()
	await _time_passing_in_an_unfocused_world()
	await _a_failed_snap_still_separates_them()

	WorldManager.unload()
	await get_tree().process_frame
	_restore_host()


func _install_synthetic_host() -> bool:
	_saved_host = WorldManager._world_host
	_saved_attention = WorldManager._attention_nodes.duplicate()
	_host = Control.new()
	_root.add_child(_host)
	WorldManager.register_world_host(_host)
	var none: Array[Node] = []
	WorldManager.register_attention_nodes(none)
	return WorldManager.can_load()


func _the_reported_sequence() -> void:
	WorldManager.load_area(HOME)
	await get_tree().process_frame

	var party: Array[Unit] = _live_members()
	if party.size() < 3:
		check("SETUP: at least three members to scatter", false,
			"%d member(s)" % party.size())
		return

	# One walks into the cathedral on their own.
	var first: Array[Unit] = [party[0]]
	WorldManager.load_area(CATHEDRAL, &"", first)
	await get_tree().process_frame
	_check_heights("after one member enters the cathedral alone")

	# Back to the rest, and two of them go out to the overworld together.
	if not WorldManager.focus_group(PartyManager.group_of(party[1])):
		check("SETUP: could get back to the others", false)
		return
	await get_tree().process_frame

	var pair: Array[Unit] = [party[1], party[2]]
	WorldManager.load_area(&"overworld", &"", pair)
	await get_tree().process_frame
	await get_tree().process_frame
	_check_heights("after two are sent out to the overworld")

	# And then those two follow the first into the cathedral.
	WorldManager.load_area(CATHEDRAL)
	await get_tree().process_frame
	await get_tree().process_frame
	_check_heights("after the pair follows them into the cathedral")

	# The whole point of the report: they were nowhere to be seen.
	var context: WorldContext = WorldManager.context()
	var present: int = 0
	for unit in _live_members():
		if context and context.contains(unit):
			present += 1
	check("everyone who travelled is actually in the cathedral",
		present >= 3, "only %d of 3 arrived" % present)


## The reported sequence does not reproduce in two frames, and the number
## says why: falling for about thirty seconds at this project's gravity
## lands you around eight thousand units away. So the question is not
## where a unit is PUT, it is what happens to it afterwards while nobody
## is looking.
##
## An unfocused world stays live on purpose. Its units keep running
## physics_process, which applies gravity and calls move_and_slide — and
## if that world's physics space is not being stepped, is_on_floor() never
## becomes true, nothing ever stops them, and they accelerate downward
## for as long as the player is elsewhere.
func _time_passing_in_an_unfocused_world() -> void:
	var left_behind: Array[Unit] = []
	var context: WorldContext = WorldManager.context()
	for unit in _live_members():
		if context and not context.contains(unit):
			left_behind.append(unit)

	if left_behind.is_empty():
		check("SETUP: somebody is standing in a world nobody is watching",
			false, "the party is not split")
		return

	var before: Array[float] = []
	for unit in left_behind:
		before.append(unit.global_position.y)

	# Long enough for a fall to be unmistakable, short enough to run.
	for i in 90:
		await get_tree().physics_frame

	var worst_drift: float = 0.0
	var culprit: String = ""
	for i in left_behind.size():
		if not is_instance_valid(left_behind[i]):
			continue
		var drift: float = absf(left_behind[i].global_position.y - before[i])
		if drift > worst_drift:
			worst_drift = drift
			culprit = left_behind[i].name

	check("a unit left in an unwatched world stays where it was standing",
		worst_drift < 2.0,
		"%s drifted %.1f in 90 frames — it is falling, and will keep falling"
			% [culprit, worst_drift])


## Landing asks the navigation grid to snap each follower to a valid
## cell near its ring slot. When that query finds nothing — a marker
## over unscanned ground, a destination whose grid is not baked yet —
## the follower used to be left where it started, which is exactly on
## the marker, on top of everyone else whose snap also failed.
##
## Stacked bodies do not stay stacked: they shove each other apart
## every frame, and with gravity holding them together the shove goes
## upward. The stack climbs for as long as it exists, which is what a
## party member at y=8000 actually is.
##
## Forced rather than hoped for: the marker is put far out over nothing,
## where no snap can succeed, because with a working snap this fallback
## never runs and the check would pass without testing anything.
func _a_failed_snap_still_separates_them() -> void:
	var marker := Node3D.new()
	_root.add_child(marker)
	# Well outside anything the grid has scanned.
	marker.global_position = Vector3(5000.0, 0.0, 5000.0)

	var landed: Array[Unit] = []
	for i in 3:
		var unit: Unit = spawn_brute(0.0)
		PartyManager.place_at_landing(unit, marker, i, 3)
		landed.append(unit)

	var stacked: int = 0
	for i in landed.size():
		for j in range(i + 1, landed.size()):
			if landed[i].global_position.distance_to(landed[j].global_position) < 0.1:
				stacked += 1

	check("a landing the grid cannot snap still puts people apart",
		stacked == 0,
		"%d pair(s) share one point — they will shove each other skyward"
			% stacked)

	marker.queue_free()


func _check_heights(when: String) -> void:
	var worst: float = 0.0
	var culprit: String = ""
	for unit in _live_members():
		var y: float = absf(unit.global_position.y)
		if y > worst:
			worst = y
			culprit = unit.name
	check("nobody is floating in the sky %s" % when,
		worst < SANE_HEIGHT,
		"%s is at y=%.1f" % [culprit, worst])


func _live_members() -> Array[Unit]:
	var live: Array[Unit] = []
	for unit in PartyManager.members:
		if is_instance_valid(unit):
			live.append(unit)
	return live


func _restore_host() -> void:
	WorldManager._world_host = _saved_host
	WorldManager._attention_nodes = _saved_attention
	if is_instance_valid(_host):
		_host.queue_free()
