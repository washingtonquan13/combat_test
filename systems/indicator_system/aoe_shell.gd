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

enum Shape { SPHERE, FOOTPRINT }

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
	global_position = center
	if _shape == Shape.SPHERE:
		scale = Vector3(radius, radius * height_scale, radius)
	else:
		scale = Vector3(radius, 1.0, radius)
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
