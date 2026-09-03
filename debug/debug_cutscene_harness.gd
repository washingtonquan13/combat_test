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
## (J). Load any area, stand somewhere with room in front of you, press it.
##
## WHAT YOU ARE LOOKING AT, and what you are not:
##   - the beats, their order, and their pacing            REAL
##   - the camera tilt, the cut to the pair, the reveal    REAL
##   - the fusion result, computed by the real calculator  REAL
##   - lightning, dissolve, coalescing energy, the flash   NOT BUILT
##   - the demons themselves                               placeholder bodies
##
## Beats 3 and 4 need shader techniques the imported VFX pack does not
## provide (see the 2026-08-26 asset audit), so those beats are currently
## held time with nothing in them. If the sequence feels slow, that is why
## — the pauses are reserved for spectacle that does not exist yet, and
## judging the pacing without it is judging half the thing.
##
## The marks are dropped relative to where you are standing, because no
## area declares staging of its own yet. The real version puts them in the
## Cathedral of Shadows around an actual device.

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

	var parent_a: Unit = _spawn(stage, species_a)
	var parent_b: Unit = _spawn(stage, species_b)
	if parent_a == null or parent_b == null:
		_clear_marks()
		return

	print("Fusing %s + %s -> %s" % [
		species_a.display_name, species_b.display_name, result.display_name])

	var built: Dictionary = FusionCinematic.build(parent_a, parent_b, result)
	await CinematicDirector.play(built["scene"], built["cast"])

	# The camera is deliberately LEFT on the result. Beat 8 is the demon
	# introducing itself, which is a dialogue the caller starts — so the
	# shot holding afterwards is the behaviour, not a leak. Press the key
	# again, or start a conversation, to move it.
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
		FusionCinematic.DEVICE_MARK: origin,
		FusionCinematic.LEFT_MARK: origin + Vector3(-PAIR_SPREAD, 0.0, 0.0),
		FusionCinematic.RIGHT_MARK: origin + Vector3(PAIR_SPREAD, 0.0, 0.0),
		FusionCinematic.RESULT_MARK: origin,
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


func _spawn(stage: Node, species: UnitDefinition) -> Unit:
	if species.unit_scene == null:
		print("%s has no unit_scene." % species.display_name)
		return null
	var unit: Unit = species.unit_scene.instantiate()
	# BEFORE add_child — Unit adopts its body in _enter_tree, and a
	# definition assigned afterwards leaves it with no model at all.
	unit.definition = species
	stage.add_child(unit)
	return unit
