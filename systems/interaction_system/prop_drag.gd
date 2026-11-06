class_name PropDrag
extends Node3D
## One MovableProp being dragged: the ghost that follows the cursor, and
## whether it may be dropped where it is.
##
## The ghost is a see-through copy of the prop's meshes resting on the
## cursor's surface point, outlined white where the prop fits and is in
## the mover's reach (MovableProp.in_reach), red where it doesn't.
## "Fits" is a shape query of the prop's own collision shapes at the
## resting spot, lifted a hair so the floor it rests on doesn't count,
## against everything else on the ground layer (walls, other props,
## units).
##
## A line arcs from the prop to the ghost along MovableProp.arc_point(),
## the path a drop flies it along, in the indicator colours: white where
## it may go, red where not.
##
## Made and fed by ClickRouter, which owns the cursor; this never reads
## input or casts a mouse ray itself.

const OK_COLOR: Color = Color(1, 1, 1, 1)
const BLOCKED_COLOR: Color = Color(0.9, 0.12, 0.1, 1)

## How far the fit query is lifted off the resting surface.
const FIT_LIFT: float = 0.03

## The outline shell's scale over the mesh. Scaled rather than pushed
## along normals (outline.gdshader's outline_width): a box's faces have
## split normals, and pushing them apart leaves the corners open.
const OUTLINE_SCALE: float = 1.06

const ARC_SEGMENTS: int = 24

const OUTLINE_SHADER: Shader = preload("res://systems/unit_system/outline.gdshader")

var prop: MovableProp
var mover: Unit
var collision_mask: int = 1

## Where a drop would land, or null while the cursor is on nothing.
var point = null
var valid: bool = false

var _outline: ShaderMaterial
var _ghost_material: StandardMaterial3D
var _arc: PathTube


func _init(dragged: MovableProp, by: Unit, mask: int = 1) -> void:
	prop = dragged
	mover = by
	collision_mask = mask
	name = "PropDrag"
	top_level = true


func _ready() -> void:
	_outline = ShaderMaterial.new()
	_outline.shader = OUTLINE_SHADER
	_outline.set_shader_parameter("outline_width", 0.0)
	_ghost_material = StandardMaterial3D.new()
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.albedo_color = Color(1, 1, 1, 0.35)
	for child in prop.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var ghost := MeshInstance3D.new()
		ghost.mesh = mesh_instance.mesh
		ghost.transform = mesh_instance.transform
		ghost.material_override = _ghost_material
		ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(ghost)
		var shell := MeshInstance3D.new()
		shell.mesh = mesh_instance.mesh
		shell.transform = mesh_instance.transform.scaled_local(Vector3.ONE * OUTLINE_SCALE)
		shell.material_override = _outline
		shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(shell)
	_arc = PathTube.new()
	_arc.fade_start = 0.3
	_arc.fade_end = 0.3
	add_child(_arc)
	visible = false


## This frame's surface point under the cursor (Cursor.ground).
func follow(ground) -> void:
	point = ground
	if point == null or not is_instance_valid(prop):
		visible = false
		valid = false
		return
	global_transform = prop.resting_transform(point)
	valid = mover != null and prop.in_reach(mover, point) and fits(point)
	_outline.set_shader_parameter("outline_color", OK_COLOR if valid else BLOCKED_COLOR)
	_ghost_material.albedo_color = Color(OK_COLOR if valid else BLOCKED_COLOR, 0.35)
	_draw_arc()
	visible = true


## The flight path, through the prop's middle rather than its origin.
func _draw_arc() -> void:
	var from: Vector3 = prop.global_position
	var to: Vector3 = global_position
	var middle: Vector3 = prop.global_basis * _local_middle()
	var points := PackedVector3Array()
	for i in range(ARC_SEGMENTS + 1):
		points.append(MovableProp.arc_point(from, to, float(i) / ARC_SEGMENTS) + middle)
	_arc.show_line(points, IndicatorPalette.OK if valid else IndicatorPalette.BLOCKED)


func _local_middle() -> Vector3:
	var shapes: Array[CollisionShape3D] = prop.shapes()
	if shapes.is_empty():
		return Vector3.ZERO
	return (shapes[0].transform * shapes[0].shape.get_debug_mesh().get_aabb()).get_center()


## Whether the prop's shapes, resting on at, overlap nothing but itself.
func fits(at: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = prop.get_world_3d().direct_space_state
	var resting: Transform3D = prop.resting_transform(at)
	resting.origin.y += FIT_LIFT
	for cs in prop.shapes():
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = cs.shape
		query.transform = resting * cs.transform
		query.collision_mask = collision_mask
		query.exclude = [prop.get_rid()]
		if not space.intersect_shape(query, 1).is_empty():
			return false
	return true


## Flies the prop to where the ghost is (MovableProp.fly_to). False, and
## nothing moved, when it may not go there.
func drop() -> bool:
	if not valid or point == null or not is_instance_valid(prop):
		return false
	prop.fly_to(point)
	return true
