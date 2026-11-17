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
## WHAT IT DOES NOT CARRY. What the body shows the player about the unit
## (hover outline, selection and turn rings) is left off the copy and stays
## on the unit's hidden body. Effects and floating text follow the unit, not
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
	_give_own_tree(copy)
	for solid in copy.find_children("*", "CollisionObject3D", true, false):
		solid.free()
	_strip_player_feedback(original, copy)
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


## The unit's body shows its clips through a BodyAnimationTree, and the
## copy takes that along with everything else, sharing the original's tree
## root and so its playback, and its flinch. Both go, and the copy gets a
## tree of its own on its own player, so it layers as the unit's body does.
static func _give_own_tree(copy: CharacterModel) -> void:
	for shared in copy.find_children("*", "BodyAnimationTree", true, false):
		shared.free()
	for shared in copy.find_children("*", "BodyFlinch", true, false):
		shared.free()
	var player: AnimationPlayer = copy.resolve_animation_player()
	if player:
		player.active = true
		BodyAnimationTree.attach(player)


## What shows the copy's clips: its own tree.
func _shown() -> BodyAnimationTree:
	return BodyAnimationTree.of(body())


## What shows the original body's clips: its BodyAnimationTree, or its
## player for a body with none. Either answers assigned_animation,
## current_animation_position and seek().
static func _shown_by(original: CharacterModel) -> Object:
	var tree: BodyAnimationTree = BodyAnimationTree.of(original)
	return tree if tree else original.resolve_animation_player()


## The body carries what the player is shown about the unit: the hover
## outline (UnitOutline, a parameter on its meshes, which a copy takes
## with it) and the ring (whose decals hang under highlight_mesh). On the
## copy nothing would drive them, so whatever was showing at the moment of
## the copy, a ring for the selected leader, an outline for the person just
## clicked to talk to, would stand frozen in every shot. They stay the
## unit's own, hidden with its body and back when the copy is struck.
static func _strip_player_feedback(original: CharacterModel, copy: CharacterModel) -> void:
	UnitOutline.clear(copy)
	var own: Node = original.highlight_mesh
	if own == null or not original.is_ancestor_of(own):
		return
	var twin: Node = copy.get_node_or_null(original.get_path_to(own))
	if twin:
		twin.free()


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


## Turns the copy to look toward `point`, on the ground plane. The stand-in's
## own Unit.snap_face_point.
func face_point(point: Vector3) -> void:
	var flat := Vector3(point.x - global_position.x, 0.0, point.z - global_position.z)
	if flat.length() < 0.001:
		return
	var ahead: Vector3 = flat.normalized().rotated(Vector3.UP, deg_to_rad(_facing_offset_degrees))
	global_transform = Transform3D(Basis.looking_at(ahead, Vector3.UP), global_position)


## Plays one of the body's clips on the copy, crossfading from the one it
## is in over `blend` seconds (-1 is the player's own default), on `layer`
## (see UnitAnimator.play_cutscene_clip: BODY leaves an upper clip up, UPPER
## with no clip lowers it). False when it has no such clip.
func play(clip: String, blend: float = -1.0,
		layer: BodyAnimationTree.Layer = BodyAnimationTree.Layer.BODY) -> bool:
	var tree: BodyAnimationTree = _shown()
	if tree == null:
		return false
	match layer:
		BodyAnimationTree.Layer.UPPER:
			if clip == "":
				tree.stop_upper(maxf(blend, 0.0))
				return true
			return tree.has_animation(clip) and tree.play_upper(clip, maxf(blend, 0.0))
		BodyAnimationTree.Layer.FLINCH:
			return tree.has_animation(clip) and tree.flinch(clip)
	if not tree.has_animation(clip):
		return false
	if tree.assigned_animation != clip or not tree.is_playing():
		tree.play(clip, blend)
	return true


## Brings the unit's own body to the point of the clip the copy has reached,
## when both are in the same one, so taking the copy away does not restart
## a breath. The other half of _stand_idle.
func match_original() -> void:
	var copy: CharacterModel = body()
	if copy == null or not is_instance_valid(_original):
		return
	var shown: BodyAnimationTree = _shown()
	var own: Object = _shown_by(_original)
	if shown and own and shown.assigned_animation != "" \
			and own.assigned_animation == shown.assigned_animation:
		own.seek(shown.current_animation_position, true)


## The copy stands at rest, picking up the idle where the unit's own body
## had got to so the swap does not restart a breath.
func _stand_idle(original: CharacterModel, copy: CharacterModel) -> void:
	var player: BodyAnimationTree = BodyAnimationTree.of(copy)
	if player == null:
		return
	var clip: String = copy.idle_animation
	var source: Object = _shown_by(original)
	if not player.has_animation(clip):
		clip = source.assigned_animation if source else ""
	if clip == "" or not player.has_animation(clip):
		return
	player.play(clip)
	if source and source.assigned_animation == clip:
		player.seek(source.current_animation_position, true)
