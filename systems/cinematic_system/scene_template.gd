@tool
class_name SceneTemplate
extends Node3D
## Where the people in a staged scene stand, relative to each other: a set
## of marks around an origin, authored once and laid down wherever the scene
## happens.
##
## Each Marker3D child is a mark, named for the cast role that stands on it,
## and faces along its own -Z. The game supplies only the PLACEMENT: the
## origin goes to the unit in `anchor_role`, where that unit already stands,
## and the template's -Z is turned toward the unit in `toward_role`. Nothing
## else about where anyone ended up reaches the staging, which is what lets
## a shot be composed once and hold everywhere.
##
## A template is laid on ground it has not seen, so fit() checks every mark
## has floor under it at about the origin's height and room for the body,
## and tries a few turns to either side before giving up. No fit is an
## ordinary answer: the scene then plays on the units as they stand.

## The role whose unit the origin is placed on.
@export var anchor_role: StringName = &"npc"
## The role whose unit the template's -Z is turned toward.
@export var toward_role: StringName = &"player"
## The widest body the marks leave room for. A cast with anyone larger does
## not fit.
@export var widest_radius: float = 0.5
## Turns to try, in order, when the ground refuses the marks as authored.
@export var turns_degrees: PackedFloat32Array = [0.0, 30.0, -30.0, 60.0, -60.0]

## How far a mark's floor may be above or below the origin's.
const STEP: float = 0.4
## How far the nearest standable point may be from a mark for the mark to
## count as standable.
const SLACK: float = 0.3


## role -> Transform3D in template space, for every mark.
func marks() -> Dictionary:
	var found: Dictionary = {}
	for child in get_children():
		if child is Marker3D:
			found[StringName(child.name)] = (child as Marker3D).transform
	return found


## Lays the template down for `cast` (role -> Unit). Returns role ->
## {"at": Vector3, "facing": Vector3} for every mark with a unit to stand on
## it, or {} when the cast or the ground does not fit.
func fit(cast: Dictionary) -> Dictionary:
	var anchor: Unit = cast.get(String(anchor_role)) as Unit
	var toward: Unit = cast.get(String(toward_role)) as Unit
	if not is_instance_valid(anchor) or not is_instance_valid(toward) or anchor == toward:
		return {}
	var staged: Dictionary = {}
	var everyone: Array = []
	var all: Dictionary = marks()
	for role in all:
		var unit: Unit = cast.get(String(role)) as Unit
		if not is_instance_valid(unit):
			continue
		if unit.radius > widest_radius or unit.is_flying() or not unit.is_alive():
			return {}
		staged[role] = unit
		everyone.append(unit)
	if not staged.has(anchor_role) or not staged.has(toward_role):
		return {}

	var origin: Vector3 = anchor.global_position
	var ahead: Vector3 = toward.global_position - origin
	ahead.y = 0.0
	ahead = ahead.normalized() if ahead.length() > 0.05 else anchor.visual_forward()
	for turn in turns_degrees:
		var facing := Basis.looking_at(ahead.rotated(Vector3.UP, deg_to_rad(turn)), Vector3.UP)
		var placed: Dictionary = _place(Transform3D(facing, origin), all, staged, everyone)
		if not placed.is_empty():
			return placed
	return {}


func _place(placement: Transform3D, all: Dictionary, staged: Dictionary, everyone: Array) -> Dictionary:
	var placed: Dictionary = {}
	for role in staged:
		var unit: Unit = staged[role]
		var mark: Transform3D = placement * (all[role] as Transform3D)
		var at: Vector3 = mark.origin
		# The mark a unit already stands on needs no ground found for it.
		if at.distance_to(unit.global_position) > 0.05:
			var tree: SceneTree = unit.get_tree()
			at.y = NavigationGrid.ground_height_at(tree, at, unit)
			if absf(at.y - placement.origin.y) > STEP:
				return {}
			var snap: Dictionary = NavigationGrid.nearest_valid_point(
					tree, at, unit.radius, false, unit, 2, unit, everyone)
			if not snap.found:
				return {}
			var off: Vector3 = snap.point - at
			if Vector2(off.x, off.z).length() > SLACK:
				return {}
		placed[role] = {"at": at, "facing": -mark.basis.z}
	return placed
