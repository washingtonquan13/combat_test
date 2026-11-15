class_name StandIn
extends Node3D
## A copy of a unit's body, shown somewhere the unit is not, while the
## unit's own body is hidden.
##
## A staged scene wants people on its marks: a fixed distance apart, turned
## to each other. The game wants its units exactly where the rules left
## them. Walking a unit onto a mark makes the scene a move order with a
## camera on it, and every shot then depends on where pathfinding happened
## to stop. So the scene never moves the unit. It raises a stand-in on the
## mark, performs on that, and strikes it when it is over; the unit's
## position, facing, collision and occupancy are never written.
##
## The copy is the unit's live CharacterModel duplicated, so it wears
## whatever the unit wears and holds whatever it holds at that moment, with
## nothing to keep in step. It is a child of the unit (freed with it, hidden
## with it) but top-level, so it stays where it was put when the unit turns.
##
## WHO READS IT. Whatever shows a unit in a scene asks here first: the
## camera (CameraFraming, SceneCast.point), heads (DialogueGaze) and faces
## (FaceDriver.of). Gameplay never does, so a rule cannot be fooled by where
## somebody appears to stand.
##
## WHAT IT DOES NOT CARRY. Effects and floating text follow the unit, not
## the copy; a scene that needs them on screen should not use a stand-in.

const NODE_NAME: StringName = &"StandIn"
const BODY_NAME: StringName = &"CharacterModel"

var _original: CharacterModel = null
var _original_was_visible: bool = true
var _facing_offset_degrees: float = 0.0


## Shows unit at `at`, facing along `facing`, in place of its own body.
## Null when the unit has no body to copy.
static func raise(unit: Unit, at: Vector3, facing: Vector3) -> StandIn:
	strike_for(unit)
	var original := unit.get_node_or_null(NodePath(BODY_NAME)) as CharacterModel
	if original == null:
		return null
	var copy := original.duplicate(DUPLICATE_SCRIPTS) as CharacterModel
	if copy == null:
		return null
	_mirror_owners(original, copy, {original: copy})
	for solid in copy.find_children("*", "CollisionObject3D", true, false):
		solid.free()
	copy.name = BODY_NAME
	copy.visible = true

	var stand := StandIn.new()
	stand.name = NODE_NAME
	stand.top_level = true
	stand._original = original
	stand._original_was_visible = original.visible
	stand._facing_offset_degrees = unit.facing_offset_degrees
	stand.add_child(copy)
	unit.add_child(stand)

	var flat := Vector3(facing.x, 0.0, facing.z)
	flat = flat.normalized() if flat.length() > 0.001 else unit.visual_forward()
	var ahead: Vector3 = flat.rotated(Vector3.UP, deg_to_rad(stand._facing_offset_degrees))
	stand.global_transform = Transform3D(Basis.looking_at(ahead, Vector3.UP), at)

	stand._stand_idle(original, copy)
	# A mesh binds its skin when it enters the tree, which is after its
	# skeleton did, and a skin is only filled on the skeleton's update. Left
	# to the next frame's, the copy draws nothing for the one frame in which
	# the unit's own body is already hidden.
	for skeleton: Skeleton3D in copy.find_children("*", "Skeleton3D", true, false):
		skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
	original.visible = false
	return stand


## Gives every node of the copy the owner its original has, as the matching
## node of the copy. A plain duplicate leaves owners unset, and a scene-unique
## name (%GeneralSkeleton, which every animation track is addressed to) is
## only found through its owner. Duplicating by re-instantiating the scene
## would keep them, but fails on a body whose children changed after it was
## made, which is every dressed one.
static func _mirror_owners(from: Node, to: Node, twins: Dictionary) -> void:
	for i in mini(from.get_child_count(), to.get_child_count()):
		var child: Node = from.get_child(i)
		var twin: Node = to.get_child(i)
		twins[child] = twin
		if twins.has(child.owner):
			twin.owner = twins[child.owner]
		_mirror_owners(child, twin, twins)


## The stand-in showing unit, or null when its own body is what is on screen.
static func of(unit: Node) -> StandIn:
	if not is_instance_valid(unit):
		return null
	var found: Node = unit.get_node_or_null(NodePath(NODE_NAME))
	return found as StandIn if found and not found.is_queued_for_deletion() else null


## The body on screen for unit: its stand-in's, else its own, else null.
static func body_of(unit: Node) -> CharacterModel:
	if not is_instance_valid(unit):
		return null
	var stand: StandIn = of(unit)
	return stand.body() if stand else unit.get_node_or_null(NodePath(BODY_NAME)) as CharacterModel


## Where unit is seen to stand.
static func place_of(unit: Unit) -> Vector3:
	var stand: StandIn = of(unit)
	return stand.global_position if stand else unit.global_position


static func strike_for(unit: Node) -> void:
	var stand: StandIn = of(unit)
	if stand:
		stand.strike()


## Takes the copy away and puts the unit's own body back on screen.
func strike() -> void:
	_restore()
	name = &"StandInStruck"
	queue_free()


func _exit_tree() -> void:
	_restore()


func _restore() -> void:
	if is_instance_valid(_original):
		_original.visible = _original_was_visible
	_original = null


func body() -> CharacterModel:
	return get_node_or_null(NodePath(BODY_NAME)) as CharacterModel


func anchor(kind: CharacterModel.Anchor) -> Vector3:
	var copy: CharacterModel = body()
	return copy.anchor_position(kind) if copy else global_position


## The way the copy visibly faces; the same sum as UnitFacing.visual_forward.
func visual_forward() -> Vector3:
	return (-global_transform.basis.z).rotated(Vector3.UP, -deg_to_rad(_facing_offset_degrees))


## The copy stands at rest, picking up the idle where the unit's own body
## had got to so the swap does not restart a breath.
func _stand_idle(original: CharacterModel, copy: CharacterModel) -> void:
	var player: AnimationPlayer = copy.resolve_animation_player()
	if player == null:
		return
	var clip: String = copy.idle_animation
	var source: AnimationPlayer = original.resolve_animation_player()
	if not player.has_animation(clip):
		clip = source.assigned_animation if source else ""
	if clip == "" or not player.has_animation(clip):
		return
	player.play(clip)
	if source and source.assigned_animation == clip:
		player.seek(source.current_animation_position, true)
