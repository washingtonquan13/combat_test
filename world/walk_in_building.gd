class_name WalkInBuilding
extends StaticBody3D
## A building the party can walk into. While a party member stands in one of
## its rooms the roof stops drawing so the camera can see the floor; it keeps
## casting its shadow, so the inside stays shaded.

## The roof, gables and anything else above the walls.
@export var roof: GeometryInstance3D
## Each room's inside, in this node's space, floor to ridge.
@export var rooms: Array[AABB] = []

var _open := false


func _physics_process(_delta: float) -> void:
	var inside := false
	for unit: Unit in PartyManager.members:
		if is_instance_valid(unit) and _holds(to_local(unit.global_position)):
			inside = true
			break
	if inside != _open:
		_open = inside
		roof.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if inside \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _holds(p: Vector3) -> bool:
	for room in rooms:
		if room.has_point(p):
			return true
	return false
