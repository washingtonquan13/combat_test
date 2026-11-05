class_name AltitudeMarker
extends Node3D
## Where a point in the AIR is, read at a glance: a small ring and faint
## disc at the point, a thin drop line straight down to the floor under
## it, a faint shadow ring painted on that floor, and the height above
## the floor as a readout beside the drop line ("3.5 m"). Shared by
## every indicator whose aim can leave the ground (a flier's move end,
## a Fireball lifted into the air, a wall or cone aimed at height), so
## "how high is that" has one look everywhere. A height mode without
## this read as a point floating somewhere in the scene.
##
## Draws only. The owner hands it the point and the floor under it
## (Cursor.floor_below, through floor_under) each frame; nothing here
## raycasts or reads the mouse. Hidden when the point is not in the air
## (within MIN_HEIGHT of the floor) or there is no floor to drop to.
##
## Builds its own children in code. The lines are PathTubes, the one
## look every indicator line uses. The ring, disc, drop line and readout
## sit on Unit.RENDER_LAYER so no ground decal (the shadow ring
## included) paints over them, the arrangement UnitSelection's own drop
## line uses. Made through IndicatorBase._create_altitude_marker(), so
## the owning indicator's hide_visuals/is_showing_anything cover it.

## Below this the point is on the floor, not above it: nothing to show.
const MIN_HEIGHT: float = 0.25
## The ring at the point, in metres.
const RING_RADIUS: float = 0.22
const RING_SEGMENTS: int = 28
## The faint disc inside the ring: it gives the ring a plane to sit in,
## so the ellipse reads as horizontal rather than as a hoop.
const DISC_ALPHA: float = 0.16
## The floor's shadow ring: a little wider than the ring above, faint,
## a decal so it follows slopes and steps.
const SHADOW_RADIUS: float = 0.3
const SHADOW_RING_WIDTH: float = 0.3
const SHADOW_ALPHA: float = 0.45
const SHADOW_DECAL_HEIGHT: float = 0.8
## The drop line is quieter than the line it hangs from.
const DROP_ALPHA: float = 0.7
const DROP_FADE: float = 0.2
const DROP_WIDTH: float = 0.02
## The readout sits beside the drop line at this fraction of the way
## down, pushed this many pixels right of it, so it never covers the
## line, the ring, or a readout floating above the point (the movement
## cost).
const READOUT_AT: float = 0.5
const READOUT_OFFSET_PX: float = 14.0

var _ring: PathTube
var _drop: PathTube
var _disc: MeshInstance3D
var _disc_material: StandardMaterial3D
var _shadow: Decal
var _readout: Label3D

## What the visuals were last built for, so an unchanged aim isn't
## rebuilt every frame.
var _built_point: Vector3 = Vector3.INF
var _built_floor: Vector3 = Vector3.INF
var _built_color: Color = Color(0, 0, 0, 0)


## The floor straight under point for this frame's aim: the Y of
## Cursor.floor_below at point's own XZ (the aim point and the cursor
## share about the same XZ; a line's end pulled in to its max length
## keeps the cursor's floor height). Null when the cursor has no floor
## below. Read by name (get) so it degrades to the cursor's ground
## point on a Cursor without the field.
static func floor_under(aim: Aim, point: Vector3) -> Variant:
	if aim == null or aim.cursor == null:
		return null
	var below = aim.cursor.get(&"floor_below") if "floor_below" in aim.cursor else aim.cursor.ground
	if not (below is Vector3):
		return null
	return Vector3(point.x, (below as Vector3).y, point.z)


## Whether the cursor's point came from the latched height plane rather
## than a surface. False on a Cursor without the field.
static func cursor_on_plane(aim: Aim) -> bool:
	if aim == null or aim.cursor == null or not ("on_plane" in aim.cursor):
		return false
	var on_plane = aim.cursor.get(&"on_plane")
	return on_plane is bool and on_plane


func _ready() -> void:
	var unit_layer: int = 1 << (Unit.RENDER_LAYER - 1)

	_ring = PathTube.new()
	_ring.name = "Ring"
	# A closed loop has no ends to fade.
	_ring.fade_start = 0.0
	_ring.fade_end = 0.0
	_ring.layers = unit_layer
	add_child(_ring)

	_drop = PathTube.new()
	_drop.name = "DropLine"
	_drop.width = DROP_WIDTH
	_drop.fade_start = DROP_FADE
	_drop.fade_end = DROP_FADE
	_drop.layers = unit_layer
	add_child(_drop)

	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = RING_RADIUS
	disc_mesh.bottom_radius = RING_RADIUS
	disc_mesh.height = 0.002
	disc_mesh.radial_segments = RING_SEGMENTS
	disc_mesh.rings = 1
	_disc_material = StandardMaterial3D.new()
	_disc_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_disc_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_disc_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_disc = MeshInstance3D.new()
	_disc.name = "Disc"
	_disc.mesh = disc_mesh
	_disc.material_override = _disc_material
	_disc.top_level = true
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_disc.layers = unit_layer
	_disc.visible = false
	add_child(_disc)

	# Styled like ClickFeedback's ring: a top_level decal that paints the
	# floor and leaves units alone.
	_shadow = Decal.new()
	_shadow.name = "Shadow"
	_shadow.top_level = true
	_shadow.size = Vector3(SHADOW_RADIUS * 2.0, SHADOW_DECAL_HEIGHT, SHADOW_RADIUS * 2.0)
	_shadow.normal_fade = 0.6
	_shadow.upper_fade = 0.1
	_shadow.lower_fade = 0.1
	_shadow.albedo_mix = 1.0
	_shadow.cull_mask = 0xFFFFF & ~unit_layer
	_shadow.sorting_offset = 2.0
	var textures: Array = UnitSelection._ring_textures_for(SHADOW_RING_WIDTH)
	_shadow.texture_albedo = textures[0]
	_shadow.texture_emission = textures[1]
	_shadow.visible = false
	add_child(_shadow)

	# Styled like the movement preview's cost readout.
	_readout = Label3D.new()
	_readout.name = "Height"
	_readout.top_level = true
	_readout.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_readout.fixed_size = true
	_readout.pixel_size = 0.0012
	_readout.font_size = 24
	_readout.outline_size = 8
	_readout.outline_modulate = IndicatorPalette.EDGE
	_readout.no_depth_test = true
	_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_readout.offset = Vector2(READOUT_OFFSET_PX, 0.0)
	_readout.layers = unit_layer
	_readout.visible = false
	add_child(_readout)


## Shows the marker for point hanging over floor_point (a Vector3 straight
## under it, or null). Hides it when there is no floor or the point is
## within MIN_HEIGHT of it.
func show_at(point: Vector3, floor_point, color: Color) -> void:
	if not is_node_ready() or not (floor_point is Vector3):
		hide_marker()
		return
	var below := Vector3(point.x, (floor_point as Vector3).y, point.z)
	var height: float = point.y - below.y
	if height < MIN_HEIGHT:
		hide_marker()
		return

	if point != _built_point or below != _built_floor or color != _built_color or not _ring.visible:
		_ring.show_line(_circle(point, RING_RADIUS), color)
		_drop.show_line(PackedVector3Array([point, below]), Color(color, color.a * DROP_ALPHA))
		_disc.global_position = point
		_disc_material.albedo_color = Color(color, DISC_ALPHA)
		_shadow.global_position = below
		_shadow.modulate = Color(color, SHADOW_ALPHA)
		_shadow.emission_energy = SHADOW_ALPHA
		_readout.global_position = point.lerp(below, READOUT_AT)
		_readout.text = "%.1f m" % height
		_readout.modulate = color
		_built_point = point
		_built_floor = below
		_built_color = color

	_ring.visible = true
	_drop.visible = true
	_disc.visible = true
	_shadow.visible = true
	_readout.visible = true


func hide_marker() -> void:
	if not is_node_ready():
		return
	_ring.visible = false
	_drop.visible = false
	_disc.visible = false
	_shadow.visible = false
	_readout.visible = false


func is_showing() -> bool:
	return is_node_ready() and _ring.visible


## A closed horizontal loop around center.
static func _circle(center: Vector3, radius: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	for i in range(RING_SEGMENTS + 1):
		var angle: float = (float(i) / RING_SEGMENTS) * TAU
		points.append(center + Vector3(cos(angle), 0.0, sin(angle)) * radius)
	return points
