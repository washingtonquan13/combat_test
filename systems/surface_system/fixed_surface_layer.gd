class_name FixedSurfaceLayer
extends Node3D
## A level's painted surface: the stream and pond a bake laid down, as
## BG3's deep water is. Lays surface (a Surface.fixed one) over its cells
## when the world loads, through SurfaceManager.lay_fixed, so units in it
## wade (its movement cost) and Puddle Step reads it as water, while no
## spell freezes, electrifies or clears it.

@export var surface: Surface
## One per SurfaceGrid cell: x and z its key, y the floor (the bed) there.
@export var cells: PackedVector3Array = PackedVector3Array()


func _ready() -> void:
	# The world's context is built just after the world enters the tree.
	_lay.call_deferred()


func _lay() -> void:
	var reached: Dictionary = {}
	for cell in cells:
		reached[Vector2i(int(cell.x), int(cell.z))] = cell.y
	SurfaceManager.lay_fixed(surface, reached, self)
