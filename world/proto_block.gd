@tool
class_name ProtoBlock
extends StaticBody3D
## Reusable greybox/blockout primitive for level layout — one exported
## size drives both the visual BoxMesh and the collision BoxShape3D, so
## blocking out a platform is "drop this in, drag one Vector3" instead of
## separately opening the MeshInstance3D's mesh and the CollisionShape3D's
## shape and keeping their sizes in sync by hand.
##
## Collision MUST stay a BoxShape3D, not swapped for anything else —
## NavigationGrid (the project's own pathfinding GDExtension) only does
## exact per-cell rasterization for BoxShape3D colliders; any other shape
## type falls back to a coarse AABB approximation, silently degrading
## pathfinding accuracy for whatever gets placed with it.
##
## Both sub-resources are resource_local_to_scene = true in this scene's
## own .tscn — without that, every instance placed in a level would share
## the SAME BoxMesh/BoxShape3D, and resizing one would resize all of them.

@export var size: Vector3 = Vector3(2, 2, 2):
	set(value):
		size = value
		_sync_shapes()

@onready var _mesh_instance: MeshInstance3D = $MeshInstance3D
@onready var _collision_shape: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	_sync_shapes()


func _sync_shapes() -> void:
	if not is_node_ready():
		return  # size can be set (e.g. from a saved scene) before @onready vars are populated — _ready() re-syncs once they are

	var mesh: BoxMesh = _mesh_instance.mesh
	if mesh:
		mesh.size = size

	var shape: BoxShape3D = _collision_shape.shape
	if shape:
		shape.size = size
