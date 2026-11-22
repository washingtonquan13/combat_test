class_name CutsceneRole
extends Node3D
## Someone in a Cutscene.
##
## Key THIS node's position and rotation to move them. Put one body under
## it (a character model scene) so there is someone to look at and frame
## in the editor; in game that body is replaced by the real unit's own,
## dressed and armed as it is at that moment.
##
## While the scene plays the real unit is hidden and does not move. When
## the scene ends it is put where this role's body ended and shown again.

enum Plays {
	## The party leader.
	LEADER,
	## A unit of `definition`: the one already in the area if there is one,
	## otherwise one the scene brings in, which stays when the scene ends.
	UNIT,
}

@export var plays: Plays = Plays.LEADER
@export var definition: UnitDefinition = null

## The unit in this role, once the scene is bound.
var unit: Unit = null
## The body under this role: the preview until dress(), the unit's after.
var body: CharacterModel = null

var _original: CharacterModel = null
var _original_was_visible: bool = true
## Where the unit's body sits inside the unit.
var _body_in_unit: Transform3D = Transform3D.IDENTITY


func _ready() -> void:
	body = _preview()


func _preview() -> CharacterModel:
	for child in get_children():
		if child is CharacterModel:
			return child
	return null


## The caller's cast wins (a role named like this node), then the rule in
## `plays`. Leaves `unit` null when nobody in the world fits.
func find_unit(cast: SceneCast) -> void:
	if body == null:
		body = _preview()
	unit = null
	if cast and cast.has(name):
		unit = cast.unit(name)
	if unit:
		return
	match plays:
		Plays.LEADER:
			unit = PartyManager.leader
		Plays.UNIT:
			if definition == null:
				return
			for other in get_tree().get_nodes_in_group("units"):
				var candidate := other as Unit
				if candidate and candidate.definition == definition \
						and candidate.get_world_3d() == get_world_3d():
					unit = candidate
					return


## Brings this role's unit into the world where the role stands.
func spawn_unit() -> void:
	if plays != Plays.UNIT or definition == null or definition.unit_scene == null:
		push_warning("CutsceneRole '%s': nobody to play it." % name)
		return
	var parent: Node = WorldManager.spawn_parent()
	var spawned := definition.unit_scene.instantiate() as Unit
	if parent == null or spawned == null:
		return
	# Before it enters the tree: a unit takes its body as it enters.
	spawned.definition = definition
	parent.add_child(spawned)
	unit = spawned
	var worn := unit.get_node_or_null("CharacterModel") as CharacterModel
	var inside: Transform3D = worn.transform if worn else Transform3D.IDENTITY
	unit.global_position = global_position
	_put_unit(body_transform() * inside.affine_inverse())


## Where this role's body is: the body's own transform, or the role's when
## it has none.
func body_transform() -> Transform3D:
	return body.global_transform if is_instance_valid(body) else global_transform


## Where the unit's own body is in the world.
func unit_body_transform() -> Transform3D:
	if unit == null:
		return global_transform
	var worn := unit.get_node_or_null("CharacterModel") as CharacterModel
	return worn.global_transform if worn else unit.global_transform


## Swaps the preview body for a copy of the unit's own and hides the unit.
func dress() -> void:
	if unit == null:
		return
	_original = unit.get_node_or_null("CharacterModel") as CharacterModel
	if _original == null:
		return
	var copy: CharacterModel = StandIn.copy_body(_original, false)
	if copy == null:
		_original = null
		return
	_body_in_unit = _original.transform
	var at: Transform3D = Transform3D.IDENTITY
	var index: int = -1
	if is_instance_valid(body):
		at = body.transform
		index = body.get_index()
		copy.name = body.name
		remove_child(body)
		body.queue_free()
	copy.transform = at
	add_child(copy)
	if index >= 0:
		move_child(copy, index)
	body = copy
	# A skin is filled on its skeleton's update; forced, so the copy draws
	# on the very frame the unit's own body stops.
	for skeleton: Skeleton3D in copy.find_children("*", "Skeleton3D", true, false):
		skeleton.notification(Skeleton3D.NOTIFICATION_UPDATE_SKELETON)
	_original_was_visible = _original.visible
	_original.visible = false
	unit.light_follows(copy)


## Puts the real unit where this role's body ended.
func settle() -> void:
	if not is_instance_valid(unit) or not is_instance_valid(body):
		return
	_put_unit(body.global_transform * _body_in_unit.affine_inverse())


## Shows the real unit again. The role's body goes with the scene.
func undress() -> void:
	if is_instance_valid(_original):
		_original.visible = _original_was_visible
		if is_instance_valid(body) and body != _original:
			body.visible = false
	_original = null


func _put_unit(wanted: Transform3D) -> void:
	var at: Vector3 = wanted.origin
	if at.distance_to(unit.global_position) > 0.01:
		var snap: Dictionary = NavigationGrid.nearest_valid_point(
				get_tree(), at, unit.radius, unit.is_flying(), unit, 4, unit)
		if snap.found:
			at.x = snap.point.x
			at.z = snap.point.z
		unit.global_position = at
	var ahead: Vector3 = -wanted.basis.z
	ahead.y = 0.0
	if ahead.length_squared() > 0.0001:
		unit.snap_face_point(at + ahead.normalized().rotated(
				Vector3.UP, -deg_to_rad(unit.facing_offset_degrees)))
