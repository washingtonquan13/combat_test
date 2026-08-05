class_name ActiveSurface
extends RefCounted
## Runtime instance of a Surface currently on the battlefield — NOT a
## Resource, same split as ActiveStatus/StatusEffect: Surface is shared,
## reusable DATA (the "Grease" surface as a concept, potentially spawned
## many times); this is one specific placement of it (THIS position, THIS
## many rounds left, THIS particular ambient visual instance) and has no
## business being shared or saved as an asset.

var surface: Surface
var position: Vector3
var radius: float
var rounds_remaining: int
## The persistent ambient visual instantiated for this specific placement
## (see SurfaceManager.spawn) — freed when the surface expires. Null if
## surface.ambient_scene was left unassigned.
var visual_node: Node3D


func _init(p_surface: Surface, p_position: Vector3, p_radius: float, p_rounds_remaining: int) -> void:
	surface = p_surface
	position = p_position
	radius = p_radius
	rounds_remaining = p_rounds_remaining
