class_name AoeShell
extends MeshInstance3D
## The volume an area ability will fill, drawn as a near-clear shell
## (aoe_shell.gdshader). Its glowing cut line is where the volume meets
## the world, which is the footprint on whatever it touches: ground,
## stairs, walls, a bridge. One look for floor and airborne areas.
##
## SPHERE: a blast or cloud, centred wherever it is aimed (half buried
## when aimed at the ground, so it reads as a dome with its own ring).
## FOOTPRINT: a ground-only spill (Grease). A short cylinder whose face
## and rim are hidden, so only the cut line along the terrain shows.
## BOX: a slab standing along a line (Wall of Fire), show_box(). Sunk
## into the ground so its sides, not its floor, meet the terrain: the
## cut line is the strip it will stand on.

enum Shape { SPHERE, FOOTPRINT, BOX }

## How far a BOX reaches below the line it stands on, so its cut line
## still lands on steps and slopes under it.
const BOX_SINK: float = 0.6

## Height of the FOOTPRINT cylinder: the vertical slop its cut line
## follows (steps, slopes) before it stops touching the ground.
const FOOTPRINT_HEIGHT: float = 1.2

var _material: ShaderMaterial
var _shape: Shape = Shape.SPHERE


func _init() -> void:
	_material = ShaderMaterial.new()
	_material.shader = preload("res://systems/indicator_system/aoe_shell.gdshader")
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_apply_shape()
	visible = false


func set_shape(shape: Shape) -> void:
	if shape == _shape:
		return
	_shape = shape
	_apply_shape()


func set_tint(color: Color) -> void:
	_material.set_shader_parameter(&"tint", color)


## Shows the volume at `center`. `height_scale` squashes a sphere (a flat
## cloud previews as flat as it fills).
func show_at(center: Vector3, radius: float, height_scale: float = 1.0) -> void:
	var size := Vector3(radius, 1.0, radius)
	if _shape == Shape.SPHERE:
		size.y = radius * height_scale
	global_transform = Transform3D(Basis.from_scale(size), center)
	visible = true


## Shows a BOX standing from from to to: as tall as height above the
## ground line between them (sheared to follow a slope), and twice
## half_thickness across.
func show_box(from: Vector3, to: Vector3, height: float, half_thickness: float) -> void:
	set_shape(Shape.BOX)
	var along: Vector3 = to - from
	var flat := Vector3(along.x, 0.0, along.z)
	if flat.length_squared() < 0.0001:
		flat = Vector3.RIGHT * 0.01
	var across: Vector3 = Vector3.UP.cross(flat).normalized() * half_thickness * 2.0
	var tall: float = height + BOX_SINK
	var basis := Basis(along if along.length_squared() > 0.0001 else flat, Vector3.UP * tall, across)
	var middle: Vector3 = from.lerp(to, 0.5)
	global_transform = Transform3D(basis, middle + Vector3.UP * (tall * 0.5 - BOX_SINK))
	visible = true


func _apply_shape() -> void:
	if _shape == Shape.SPHERE:
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 48
		sphere.rings = 24
		mesh = sphere
		_material.set_shader_parameter(&"face_alpha", 0.015)
		_material.set_shader_parameter(&"rim_alpha", 0.3)
		_material.set_shader_parameter(&"shimmer_alpha", 0.025)
	elif _shape == Shape.BOX:
		var box := BoxMesh.new()
		box.size = Vector3.ONE
		mesh = box
		_material.set_shader_parameter(&"face_alpha", 0.015)
		_material.set_shader_parameter(&"rim_alpha", 0.3)
		_material.set_shader_parameter(&"shimmer_alpha", 0.025)
	else:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 1.0
		cylinder.bottom_radius = 1.0
		cylinder.height = FOOTPRINT_HEIGHT
		cylinder.radial_segments = 64
		cylinder.cap_top = false
		cylinder.cap_bottom = false
		mesh = cylinder
		_material.set_shader_parameter(&"face_alpha", 0.0)
		_material.set_shader_parameter(&"rim_alpha", 0.0)
		_material.set_shader_parameter(&"shimmer_alpha", 0.0)
