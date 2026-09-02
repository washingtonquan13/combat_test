class_name AiTestCase
extends Node
## Base for the combat-AI regression tests. Subclass, override run(), and
## drop the file in tests/ai/ — TestRunner discovers it by directory scan,
## so nothing needs registering.
##
## Deliberately NOT an autoload. The convention these replace was a
## temporary verify_*.gd wired in as the last autoload and deleted
## afterwards, which worked until it didn't: a stale autoload line was
## left behind in project.godot during this system's development, and a
## stale line there breaks the game on launch. Tests live in their own
## scene and touch no project settings at all.
##
## Each case gets a fresh scene root and a ground plane. The ground plane
## is not scenery — AiScorer raycasts downward to price landings and
## falls (see _ground_y_at), so without a floor those queries silently
## report "nothing below," every descent looks free, and the flight tests
## pass for entirely the wrong reason.

var passes: int = 0
var failures: PackedStringArray = []

var _root: Node3D
var _spawned: Array[Unit] = []


## Override. May await; the runner awaits whatever this returns.
func run() -> void:
	pass


func setup() -> void:
	_root = Node3D.new()
	add_child(_root)

	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	floor_body.add_child(shape)
	_root.add_child(floor_body)
	floor_body.global_position = Vector3(0.0, -0.5, 0.0)

	# Two physics frames, not process frames: the collider has to be live
	# in the physics server before any raycast can find it.
	await get_tree().physics_frame
	await get_tree().physics_frame

	# DetectionManager is an autoload and keeps sweeping every frame
	# regardless of what a test is doing — which means it scans whatever
	# units a case happens to have spawned and can start a fight under a
	# suite that never asked for one. Off for every case; the detection
	# suites drive scan() directly, which is what they want anyway.
	DetectionManager.enabled = false

	# NavigationGrid is an engine singleton that rasterises the CURRENT
	# scene lazily (see WorldManager, which invalidates it on every area
	# change). Without this it still holds whatever the previous test case
	# built, or nothing at all, and any route query walks stale geometry.
	NavigationGrid.invalidate()
	await get_tree().physics_frame


func teardown() -> void:
	free_spawned()
	if is_instance_valid(_root):
		_root.queue_free()
	# Let the deferred frees actually happen before the next case builds
	# its own battlefield. Without this, one suite's half-destroyed units
	# are still in the "units" group while the next suite is scoring
	# against them.
	await get_tree().process_frame
	await get_tree().process_frame


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		passes += 1
	else:
		failures.append("%s%s" % [label, ("   [%s]" % detail) if detail != "" else ""])


func check_equalf(label: String, actual: float, expected: float, tolerance: float = 0.001) -> void:
	check(label, absf(actual - expected) <= tolerance,
		"expected %.3f, got %.3f" % [expected, actual])


# --- Fixtures ------------------------------------------------------

## A plain melee attacker on the player side. ST 16 makes it hit hard
## enough that threat differences are legible in the scores.
func spawn_brute(x: float, z: float = 0.0) -> Unit:
	return spawn_unit(&"player", 16, 12, 20, [melee()], Vector3(x, 0.0, z))


func spawn_unit(faction: StringName, strength: int, dexterity: int, max_hp: int,
		abilities: Array, position: Vector3) -> Unit:
	var unit: Unit = load("res://systems/unit_system/unit.tscn").instantiate()
	# Through a definition, because that is how every unit in the game is
	# built now — all 32 UnitDefinitions name a body, and unit.tscn no
	# longer carries one. A harness that skipped this would be exercising
	# a path production does not have, and would spawn bodiless units with
	# no animation library for suites that need one.
	#
	# Assigned BEFORE add_child so Unit._enter_tree sees it, and before the
	# explicit stats below so those still win over the definition cascade —
	# the same order debug_spawn_panel uses.
	unit.definition = _harness_definition()
	_root.add_child(unit)
	var typed: Array[Ability] = []
	for ability in abilities:
		typed.append(ability)
	unit.faction = faction
	unit.strength = strength
	unit.dexterity = dexterity
	unit.maximum_hp = max_hp
	unit.current_hp = max_hp
	unit.abilities = typed
	unit.ai_smartness = 2
	unit.global_position = position
	unit.reset_turn_actions()
	_spawned.append(unit)
	return unit


## A real demon from data/, so these tests exercise authored content
## rather than a synthetic stand-in that could drift away from it.
func spawn_demon(id: String, position: Vector3, flying: bool = false, fp: int = -1) -> Unit:
	var definition: UnitDefinition = load("res://data/units/demons/%s.tres" % id)
	var unit: Unit = definition.unit_scene.instantiate()
	# BEFORE add_child. This was the other way round, so _enter_tree ran
	# with no definition and every demon spawned by this harness came up
	# with no body at all — silently, because a bodiless unit still walks,
	# fights and dies perfectly well.
	unit.definition = definition
	_root.add_child(unit)
	unit.faction = &"enemy"
	unit.global_position = position
	if flying:
		unit.apply_status(load("res://data/statuses/flying.tres"))
	unit.reset_turn_actions()
	if fp >= 0:
		unit.current_fp = fp
	_spawned.append(unit)
	return unit


## Removes one unit early, for a test that needs the battlefield to
## change partway through (a target closing in, a cluster thinning out).
func remove_spawned(unit: Unit) -> void:
	_spawned.erase(unit)
	_release(unit)


func free_spawned() -> void:
	for unit in _spawned:
		_release(unit)
	_spawned.clear()


## queue_free(), never free(). A Unit registers itself with the
## NavigationGrid extension and holds components that connect to
## autoloads; tearing one down synchronously mid-frame crashed the whole
## suite with signal 11 once enough cases ran in one process. Deferring
## lets the engine unwind it at a safe point, which is the same reason
## the game itself never calls free() on a unit.
func _release(unit: Unit) -> void:
	if not is_instance_valid(unit):
		return
	# Leave the "units" group FIRST. queue_free is deferred, so a unit torn
	# down here stays in the group — and visible to every UnitQuery scan —
	# until the frame ends. The next test case then spawns its own units
	# and finds the previous case's ghosts alongside them, which is subtle
	# and awful: a detection test had its observer correctly identify a
	# stale intruder instead of the live one, then refuse to escalate again
	# because it was already AWARE.
	if unit.is_in_group("units"):
		unit.remove_from_group("units")
	if unit.get_parent():
		unit.get_parent().remove_child(unit)
	unit.queue_free()


func behavior_of(unit: Unit, predicate: Callable) -> AiBehavior:
	for behavior in unit.ai_behaviors:
		if predicate.call(behavior):
			return behavior
	return null


## Scores a behavior's raw proposals the way AiScorer._prepare_plan would,
## minus reach resolution — route planning needs a NavigationGrid these
## bare test scenes don't have. Enough to assert what a behavior is worth;
## reachability is covered by the tests that go through best_plan() with
## self-targeted abilities.
func score_proposals(unit: Unit, plans: Array[AiPlan]) -> Array[AiPlan]:
	for plan in plans:
		if not plan.pure_reposition:
			AiScorer._score_plan(unit, plan)
		AiScorer._apply_positional_value(unit, plan)
		if not plan.pure_reposition:
			plan.score -= 0.001 * (plan.ability.move_cost + plan.ability.fp_cost)
	return plans


func best_baseline_attack_score(unit: Unit) -> float:
	var best: float = -INF
	for plan in AiScorer._enumerate_baseline_candidates(unit, unit.get_tree()):
		AiScorer._score_plan(unit, plan)
		best = maxf(best, plan.score)
	return best


func melee() -> Ability:
	return load("res://data/abilities/basic_attack_melee.tres")


func ranged() -> Ability:
	return load("res://data/abilities/basic_attack_ranged.tres")


## A blank definition that names the placeholder body, shared by every
## spawn_unit() call. Blank on purpose: the stats are set explicitly by the
## caller right after, and a definition with opinions of its own would
## quietly become a second source for them.
static var _shared_harness_definition: UnitDefinition = null


func _harness_definition() -> UnitDefinition:
	if _shared_harness_definition == null:
		_shared_harness_definition = UnitDefinition.new()
		_shared_harness_definition.model_scene = load("res://scenes/character_models/placeholder_model.tscn")
	return _shared_harness_definition
