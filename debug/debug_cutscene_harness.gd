extends Node
## Debug-only trigger for staged scenes, so a cutscene can be watched
## before anything in the game is wired to ask for one.
##
## SEPARATE FROM debug_combat_harness.gd on purpose. That file's own header
## records why it was moved off test_arena.gd — unrelated content
## copy-pasted into a script that had a different job — and a fusion
## cutscene is not combat. Putting it there would repeat the mistake the
## file is a monument to.
##
## SETUP: Project Settings > Input Map already carries "test_fusion_cutscene"
## (J) and "test_demo_cutscene" (K). Load any area, stand somewhere with
## room in front of you, press one.
##
## K plays cinematics/demo_conversation.tscn, the reference scene that uses
## every kind of beat and cut: open it in the editor next to watching it
## here to see what each track does.
##
## WHAT YOU ARE LOOKING AT, and what you are not:
##   - the beats, their order, and their pacing            REAL
##   - the camera tilt, the cut to the pair, the reveal    REAL
##   - the fusion result, computed by the real calculator  REAL
##   - blobs, orb, strike, flashes, silhouettes            REAL, but plain
##                                                         keyed nodes
##   - lightning tendrils, the floating trickle            NOT BUILT
##   - the demons themselves                               placeholder bodies
##
## The shot-by-shot map to the reference footage, and what was left out
## on purpose, is systems/demon_system/FUSION.md.
##
## The scene itself is cinematics/fusion.tscn now, so re-timing what this
## key plays is a matter of dragging keys in the editor rather than editing
## numbers in a builder and running this again to see what they did.
##
## The marks are dropped relative to where you are standing, because no
## area declares staging of its own yet. The real version puts them in the
## Cathedral of Shadows around an actual device.

const DEMO_PATH: String = "res://cinematics/demo_conversation.tscn"
## The world mark the demo stage anchors on. Must match the demo stage's
## anchor_mark; it is a world mark because only the harness knows where
## the leader is standing.
const DEMO_ANCHOR: StringName = &"DemoConversation"

const FUSION_CHART_PATH: String = "res://data/fusion_charts/fusion_chart.tres"
const PARENT_A_PATH: String = "res://data/units/demons/test_pixie.tres"
const PARENT_B_PATH: String = "res://data/units/demons/test_wolf.tres"

## How far in front of the player the device sits.
const STAGE_DISTANCE: float = 5.0
## How far apart the two parents stand on it.
const PAIR_SPREAD: float = 1.3

var _marks: Node3D = null


func _unhandled_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if event.is_action_pressed("test_fusion_cutscene"):
		_play_fusion()
	elif event.is_action_pressed("test_demo_cutscene"):
		_play_demo()


## The demo stages itself around the leader: the anchor is dropped on the
## leader, facing where they face, so the stage's local -Z is "ahead".
func _play_demo() -> void:
	if CinematicDirector.is_active():
		print("A scene is already playing.")
		return
	var stage: Node = WorldManager.spawn_parent()
	var leader: Unit = PartyManager.leader
	if stage == null or not is_instance_valid(leader):
		print("No world or no leader — nowhere to stage the demo.")
		return

	_clear_marks()
	_marks = Node3D.new()
	_marks.name = "DebugDemoMarks"
	stage.add_child(_marks)
	var anchor := Marker3D.new()
	anchor.name = DEMO_ANCHOR
	_marks.add_child(anchor)
	anchor.global_position = leader.global_position
	var ahead: Vector3 = leader.visual_forward()
	ahead.y = 0.0
	if ahead.length_squared() > 0.0001:
		anchor.look_at(leader.global_position + ahead, Vector3.UP)
	anchor.add_to_group(SceneCast.MARK_GROUP)

	var cast := SceneCast.new().track_unit(CinematicCues.LEADER_ROLE, leader)
	var completed: bool = await CinematicDirector.play(load(DEMO_PATH) as PackedScene, cast)
	print("Demo cutscene %s." % ("finished" if completed else "aborted"))
	_clear_marks()


func _play_fusion() -> void:
	if CinematicDirector.is_active():
		print("A scene is already playing.")
		return

	var stage: Node = WorldManager.spawn_parent()
	if stage == null:
		print("No world loaded — nowhere to stage a cutscene.")
		return

	var species_a: UnitDefinition = load(PARENT_A_PATH)
	var species_b: UnitDefinition = load(PARENT_B_PATH)
	var chart: FusionChart = load(FUSION_CHART_PATH) as FusionChart
	if species_a == null or species_b == null or chart == null:
		print("Missing a demon definition or the fusion chart.")
		return

	# The REAL calculator, not a hand-picked third demon — so this also
	# shows whether the result a player would actually get reads well as a
	# reveal, which a stand-in would hide.
	var result: UnitDefinition = FusionCalculator.compute_fusion(chart, species_a, species_b)
	if result == null:
		print("%s + %s has no fusion result." % [species_a.display_name, species_b.display_name])
		return

	var origin: Vector3 = _stage_origin()
	_drop_marks(stage, origin)

	print("Fusing %s + %s -> %s" % [
		species_a.display_name, species_b.display_name, result.display_name])

	# The parents are spawned by the scene's own keys, from the species in
	# the props, exactly as FusionRitual.perform() hands them over.
	await CinematicDirector.play(
		load(FusionRitual.CUTSCENE_PATH) as PackedScene,
		null,
		FusionRitual.props_for(result, species_a, species_b))

	# The camera is deliberately LEFT on the result: the real caller
	# (FusionRitual.perform) releases it, and this harness shows what the
	# scene ends on. Press the key again, or start a conversation, to move
	# it.
	print("Fusion cutscene finished. Camera is holding the reveal.")
	_clear_marks()


## In front of whoever the player is commanding, so the scene stages where
## they are looking rather than at the world origin.
func _stage_origin() -> Vector3:
	var leader: Unit = PartyManager.leader
	if not is_instance_valid(leader):
		return Vector3.ZERO
	return leader.global_position + leader.visual_forward() * STAGE_DISTANCE


func _drop_marks(stage: Node, origin: Vector3) -> void:
	_clear_marks()
	_marks = Node3D.new()
	_marks.name = "DebugFusionMarks"
	stage.add_child(_marks)

	var placements: Dictionary = {
		FusionRitual.DEVICE_MARK: origin,
		FusionRitual.LEFT_MARK: origin + Vector3(-PAIR_SPREAD, 0.0, 0.0),
		FusionRitual.RIGHT_MARK: origin + Vector3(PAIR_SPREAD, 0.0, 0.0),
		FusionRitual.RESULT_MARK: origin,
	}
	for mark_name in placements:
		var mark := Marker3D.new()
		mark.name = mark_name
		_marks.add_child(mark)
		mark.global_position = placements[mark_name]
		mark.add_to_group(SceneCast.MARK_GROUP)


func _clear_marks() -> void:
	if is_instance_valid(_marks):
		_marks.queue_free()
	_marks = null

