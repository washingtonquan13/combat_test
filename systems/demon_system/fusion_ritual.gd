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
## That order is also exactly why held roles exist. By the time the camera
## first sees the two parents, DemonRoster has already let go of them:
## asking the roster for either one returns nothing, several beats before
## they dissolve on screen. The scene owns them.
##
## DEGRADES TO NO CUTSCENE. Fusing somewhere with no staging — the
## overworld, a test harness, anywhere that is not the Cathedral — still
## fuses. The scene is skipped rather than the fusion refused, because a
## missing camera angle is not a reason to withhold something the player
## asked for and spent two demons on.

const FUSION_CHART_PATH: String = "res://data/fusion_charts/fusion_chart.tres"


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

	# Bodies BEFORE the roster releases them, because the scene needs
	# something to show and their species is about to stop being anybody's.
	var staging: Dictionary = _stage(a.species, b.species)

	DemonRoster.release(a)
	DemonRoster.release(b)
	var born: OwnedDemon = DemonRoster.recruit(result)

	if not staging.is_empty():
		var built: Dictionary = FusionCinematic.build(
			staging["parent_a"], staging["parent_b"], result)
		await CinematicDirector.play(built["scene"], built["cast"])

	return born


## Two bodies to dissolve, or nothing if this world has no fusion staging.
##
## Checked by looking for the device mark rather than by asking which area
## is loaded: an area either declares the marks a fusion needs or it does
## not, and nothing else should have to know the Cathedral by name.
static func _stage(species_a: UnitDefinition, species_b: UnitDefinition) -> Dictionary:
	var stage: Node = WorldManager.spawn_parent()
	if stage == null or not stage.is_inside_tree():
		return {}
	var probe := SceneCast.new()
	probe.tree = stage.get_tree()
	if not probe.has_mark(FusionCinematic.DEVICE_MARK):
		return {}

	var parent_a: Unit = _body(stage, species_a)
	var parent_b: Unit = _body(stage, species_b)
	if parent_a == null or parent_b == null:
		if parent_a:
			parent_a.queue_free()
		if parent_b:
			parent_b.queue_free()
		return {}
	return {"parent_a": parent_a, "parent_b": parent_b}


static func _body(stage: Node, species: UnitDefinition) -> Unit:
	if species == null or species.unit_scene == null:
		return null
	var unit: Unit = species.unit_scene.instantiate()
	# BEFORE add_child — Unit adopts its body in _enter_tree, and a
	# definition assigned afterwards leaves it with no model at all.
	unit.definition = species
	stage.add_child(unit)
	return unit
