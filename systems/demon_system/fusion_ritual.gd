class_name FusionRitual
extends RefCounted
## Performing a fusion: the roster change, and the cutscene that shows it.
##
## THE TRANSACTION HAPPENS FIRST, THE CUTSCENE SECOND, and that order is
## deliberate. The roster change is the fusion; the cutscene is how it
## looks. Doing the presentation first and the bookkeeping after would mean
## an aborted scene — a world unload, a load from the menu — could consume
## two demons and produce nothing. Committing first makes the worst case a
## fusion the player did not get to watch, rather than one they paid for
## and did not receive.
##
## That order is also why the parents are SPAWNED BY THE SCENE rather than
## handed to it. By the time the camera first sees them, DemonRoster has
## already let go: asking the roster for either one returns nothing. So the
## ritual hands over only their SPECIES, as props, and the timeline's spawn
## keys make the bodies on their pads, the same way it makes the result.
##
## Bodies made here and handed over would exist before the scene placed
## them, somewhere: at the world origin, inside the floor, being pushed out
## of it by the physics. That is what made the parents fly off the pads,
## because a placement moves a body but does not stop it.
##
## DEGRADES TO NO CUTSCENE. Fusing somewhere with no staging — the
## overworld, a test harness, anywhere that is not the Cathedral — still
## fuses. The scene is skipped rather than the fusion refused, because a
## missing camera angle is not a reason to withhold something the player
## asked for and spent two demons on.

const FUSION_CHART_PATH: String = "res://data/fusion_charts/fusion_chart.tres"
## The authored cutscene: a .tscn whose root is a CinematicStage, with a
## timeline anyone can open and scrub. The file IS the cutscene; its
## "scene" animation is the performance.
const CUTSCENE_PATH: String = "res://cinematics/fusion.tscn"
## What the result says when it wakes. See fusion_greetings.gd.
const GREETINGS_PATH: String = "res://data/fusion_greetings/fusion_greetings.tres"

## THE STAGING VOCABULARY, and it lives HERE rather than on the cutscene,
## because it is the FUSION that requires it. An area declares it can host
## a fusion by carrying these four marks in group scene_marks (see
## world/cathedral_of_shadows.tscn); the timeline names them on its keys;
## and this file probes for one of them to decide whether there is anywhere
## to play. Three unrelated things agree on four names, so the names are a
## constant on the system that owns the ritual.
const DEVICE_MARK: StringName = &"FusionDevice"
const LEFT_MARK: StringName = &"FusionLeft"
const RIGHT_MARK: StringName = &"FusionRight"
const RESULT_MARK: StringName = &"FusionResult"

## Cast roles, matching the StageRole markers under cinematics/fusion.tscn,
## and the props keys their spawn keys name.
const PARENT_A: StringName = &"parent_a"
const PARENT_B: StringName = &"parent_b"
## Also the props key the timeline's spawn key names — the result demon is
## computed here and handed to the stage, because a method track key cannot
## carry a Resource.
const RESULT: StringName = &"result"
## Text props the greeting LineBeat fills its {tokens} from.
const NAME: StringName = &"name"
const ORDER: StringName = &"order"
const GREETING: StringName = &"greeting"

## The Minister's role in the cutscene, and the group a room puts its
## Minister in. He belongs to the ROOM, not to the scene: he presides over
## the menu before any fusion and is still standing there after one, so the
## scene borrows him (tracked) rather than making its own.
const MINISTER: StringName = &"minister"
const MINISTER_GROUP: StringName = &"fusion_minister"


## What `a` and `b` would produce, or null if they produce nothing.
static func preview(a: OwnedDemon, b: OwnedDemon) -> UnitDefinition:
	if a == null or b == null or a == b:
		return null
	var chart: FusionChart = load(FUSION_CHART_PATH) as FusionChart
	if chart == null:
		return null
	return FusionCalculator.compute_fusion(chart, a.species, b.species)


## Consumes `a` and `b`, produces their result, and plays the cutscene if
## there is anywhere to play it. Returns the new roster entry, or null if
## the pair does not fuse.
##
## Async because the cutscene is. A caller that does not care about the
## spectacle can ignore the await and the fusion is already done — the
## transaction completes before the first frame of the scene.
static func perform(a: OwnedDemon, b: OwnedDemon) -> OwnedDemon:
	var result: UnitDefinition = preview(a, b)
	if result == null:
		return null

	# Read BEFORE the roster releases them: their species is about to stop
	# being anybody's.
	var props: Dictionary = props_for(result, a.species, b.species)

	DemonRoster.release(a)
	DemonRoster.release(b)
	var born: OwnedDemon = DemonRoster.recruit(result)

	if _can_stage():
		await CinematicDirector.play(load(CUTSCENE_PATH) as PackedScene,
			cast_for(WorldManager.spawn_parent()), props)
		# The cinematic camera holds its last shot until told otherwise, so
		# whoever comes next (the Cathedral's menu) sees the room it expects.
		var showing: CinematicCamera = CinematicDirector.camera()
		if showing:
			showing.release()

	return born


## Everything the cutscene is handed: the two going in and the result to
## spawn, and the words its greeting line fills in. A parent left null is
## not spawned (the spawn key warns), which is all a caller that only wants
## the reveal needs.
static func props_for(result: UnitDefinition, parent_a: UnitDefinition = null,
		parent_b: UnitDefinition = null) -> Dictionary:
	var greetings: FusionGreetings = load(GREETINGS_PATH) as FusionGreetings
	return {
		PARENT_A: parent_a,
		PARENT_B: parent_b,
		RESULT: result,
		NAME: result.display_name,
		ORDER: String(result.order),
		GREETING: greetings.greeting_for(result) if greetings else "",
	}


## The cast a fusion plays with: the Minister of the world under `world`,
## if it has one. Only the Minister — the demons are made by the scene.
##
## Searched under `world` rather than taken as the first in the group, so a
## resident Cathedral parked in another viewport cannot lend its Minister to
## a fusion staged somewhere else.
static func cast_for(world: Node) -> SceneCast:
	var cast := SceneCast.new()
	if world == null or not world.is_inside_tree():
		return cast
	for candidate in world.get_tree().get_nodes_in_group(MINISTER_GROUP):
		if candidate is Unit and world.is_ancestor_of(candidate):
			cast.track_unit(MINISTER, candidate)
			break
	return cast


## Whether this world has fusion staging.
##
## Checked by looking for the device mark rather than by asking which area
## is loaded: an area either declares the marks a fusion needs or it does
## not, and nothing else should have to know the Cathedral by name.
static func _can_stage() -> bool:
	var stage: Node = WorldManager.spawn_parent()
	if stage == null or not stage.is_inside_tree():
		return false
	var probe := SceneCast.new()
	probe.tree = stage.get_tree()
	return probe.has_mark(DEVICE_MARK)
