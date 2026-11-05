class_name IndicatorBase
extends Node3D
## Shared foundation for the preview indicators (movement path, jump arc,
## ranged/area line-of-sight, area ring, ...): the line-mesh setup every
## one of them needs, and the live/draw contract with ClickRouter.
##
## Indicators only DRAW. ClickRouter resolves the one Cursor and builds
## the one Aim each frame, and calls draw(aim) on every live indicator.
## No indicator raycasts, reads the mouse or Ctrl, or decides validity:
## colours come from the ability's own targeting.check(), and the path
## from Unit.preview_route(), the same rules the click and the move use.
## Before this, each indicator raycast for itself through a shared static
## cache and the Ctrl drag's held point was a static whichever live
## indicator wrote - "where is the player aiming" had three owners.

## Default width (meters) of the ribbons _add_ribbon draws. Lines are
## PathTubes now (_create_tube); ribbons remain only for the AoE ring
## outlines, which are footprints rather than lines. Godot's line primitives are always one
## pixel wide whatever the camera distance, which at tactical zoom read
## as a hairline; real geometry is the only way to get width.
const LINE_WIDTH: float = 0.08
## Dark rim either side of a ribbon's core (IndicatorPalette.EDGE), so a
## white line still reads over bright ground or a lit wall.
const LINE_EDGE: float = 0.015

## Every MeshInstance3D this indicator built through _create_line_mesh(),
## so set_live(false) can put ALL of them away without each subclass
## hand-writing its own _hide_all() for the router to call. Subclasses
## still hide their own meshes mid-draw for their own reasons ("nothing
## under the cursor"); this is only for the router switching an indicator
## off wholesale.
var _owned_meshes: Array[MeshInstance3D] = []

## Every AltitudeMarker this indicator built through
## _create_altitude_marker(): a Node3D of several pieces (a decal and a
## label among them), so it is tracked beside _owned_meshes rather than
## in it, and put away by the same hide_visuals.
var _owned_markers: Array[AltitudeMarker] = []

## Whether the router currently draws this indicator. Written only by
## set_live (the router's _apply_intent).
var _live: bool = false

## Units outlined as caught by this aim (Unit.set_area_targeted). Put
## down by hide_visuals with the meshes.
var _targeted: Array[Unit] = []


## Joins the group the ClickRouter walks.
##
## Subclasses that define their own _ready() MUST call super() — Godot
## calls only the most-derived _ready, so an override without it silently
## opts that indicator out of the router entirely.
func _ready() -> void:
	add_to_group(&"indicators")


## The intent id this indicator answers to — the id PlayerIntent.
## indicator_ids() names when this indicator should be live. One id per
## indicator, declared once here instead of re-derived every frame from
## the armed ability's targeting type.
##
## &"" means "not intent-driven": the sight cones and the nav overlay are
## development views with their own toggles and their own _process. The
## router skips anything returning &"" — see ClickRouter._apply_intent.
func serves() -> StringName:
	return &""


## Called by ClickRouter whenever the derived intent changes — the ONLY
## writer of whether an intent-driven indicator is drawn. Puts the
## visuals away on the way out so a line drawn for a since-abandoned
## intent can't be left hanging on screen.
func set_live(live: bool) -> void:
	_live = live
	if not live:
		hide_visuals()


func is_live() -> bool:
	return _live


## Draws this frame's aim. Called by ClickRouter once per frame while
## live, after the cursor is resolved and any height drag applied.
func draw(_aim: Aim) -> void:
	pass


func hide_visuals() -> void:
	for mesh in _owned_meshes:
		if is_instance_valid(mesh):
			mesh.visible = false
	for marker in _owned_markers:
		if is_instance_valid(marker):
			marker.hide_marker()
	_set_targets([])


## Outlines exactly units, dropping whoever was outlined before.
func _set_targets(units: Array[Unit]) -> void:
	for unit in _targeted:
		if is_instance_valid(unit) and not units.has(unit):
			unit.set_area_targeted(false)
	for unit in units:
		if not _targeted.has(unit):
			unit.set_area_targeted(true)
	_targeted = units


## Outlines who ability aimed at target would catch: the targeting
## shape's own units_caught(), gated by the effects' own hostile/ally
## flags. A spawned surface or cloud filters no one, so it catches
## everyone inside.
func _outline_caught(caster: Unit, ability: Ability, target) -> void:
	var hostiles := false
	var allies := false
	for effect in ability.effects:
		if effect is SpawnSurfaceEffect:
			hostiles = true
			allies = true
		elif "affects_hostiles" in effect:
			hostiles = hostiles or effect.affects_hostiles
			allies = allies or effect.affects_allies
	if not ability.targeting or (not hostiles and not allies):
		_set_targets([])
		return
	_set_targets(ability.targeting.units_caught(caster, target, hostiles, allies))


## Whether anything this indicator owns is currently drawn. Exists for
## the suite that asserts an indicator really goes dark rather than
## merely stopping — see tests/interaction/test_intent_has_one_owner.gd.
func is_showing_anything() -> bool:
	for mesh in _owned_meshes:
		if is_instance_valid(mesh) and mesh.visible:
			return true
	for marker in _owned_markers:
		if is_instance_valid(marker) and marker.is_showing():
			return true
	return false


## An AltitudeMarker child, registered so hide_visuals/
## is_showing_anything cover it. Starts hidden.
func _create_altitude_marker() -> AltitudeMarker:
	var marker := AltitudeMarker.new()
	add_child(marker)
	_owned_markers.append(marker)
	return marker


## Creates a new MeshInstance3D + ImmediateMesh configured for
## vertex-colored, unshaded, alpha-blended line/ring drawing — the exact
## material setup every indicator needs (SHADING_MODE_UNSHADED,
## vertex_color_use_as_albedo, TRANSPARENCY_ALPHA, CULL_DISABLED),
## previously hand-assembled identically in each one's own _build_line()/
## _build_ring(). Starts hidden. Returns both pieces: add the mesh
## instance as a child (already done here) and toggle its .visible;
## call clear_surfaces()/surface_begin()/surface_add_vertex()/
## surface_end() on the ImmediateMesh each frame to redraw.
func _create_line_mesh() -> Dictionary:
	var mesh_instance := MeshInstance3D.new()
	add_child(mesh_instance)

	var immediate := ImmediateMesh.new()
	mesh_instance.mesh = immediate

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = mat
	mesh_instance.visible = false
	_owned_meshes.append(mesh_instance)

	return {"mesh_instance": mesh_instance, "immediate": immediate}


## A PathTube child, the one look every indicator LINE uses (see
## path_tube.gd), registered like _create_line_mesh()'s meshes so
## hide_visuals/is_showing_anything cover it. Starts hidden. Short fades
## by default: an aim line is a few metres, and a metre-long fade at the
## caster would leave half of it faint.
func _create_tube(fade: float = 0.3) -> PathTube:
	var tube := PathTube.new()
	tube.fade_start = fade
	tube.fade_end = fade
	add_child(tube)
	_owned_meshes.append(tube)
	return tube


## Appends `points` to `immediate` as one ribbon surface: a core
## `width` wide in `colors` with an IndicatorPalette.EDGE rim `edge` wide
## on each side, laid out across the width as three strips (rim, core,
## rim) rather than a core stacked over a wider dark band, so the core's
## alpha is never darkened by the band under it.
##
## `colors` is either one colour for the whole ribbon or one per point.
##
## `face_camera` false lays the ribbon flat (width in the XZ plane), for
## lines that lie on the ground and follow its heights: a path, a ring.
## true turns its width toward the camera, for lines standing in the air
## (an aim line at eye height, a jump arc, a wall's posts), which a flat
## ribbon would show edge-on as a hairline again. Reading the camera
## here is drawing, not aiming: nothing about what the line answers
## depends on it.
func _add_ribbon(immediate: ImmediateMesh, points: PackedVector3Array, colors: PackedColorArray, width: float = LINE_WIDTH, edge: float = LINE_EDGE, face_camera: bool = false) -> void:
	if points.size() < 2 or colors.is_empty() or width <= 0.0:
		return
	# A surface with no vertices is an engine error, and a route can
	# collapse to one point (aim on the unit's own cell).
	if _longest_segment_squared(points) < 0.00000001:
		return
	var camera: Camera3D = get_viewport().get_camera_3d() if face_camera and is_inside_tree() else null
	var sides: PackedVector3Array = _ribbon_sides(points, camera)
	var core: float = width * 0.5
	var rim: float = core + maxf(edge, 0.0)

	immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(1, points.size()):
		if points[i - 1].distance_squared_to(points[i]) < 0.00000001:
			continue
		var color_a: Color = colors[i - 1] if colors.size() == points.size() else colors[0]
		var color_b: Color = colors[i] if colors.size() == points.size() else colors[0]
		if rim > core:
			_add_strip(immediate, points[i - 1], points[i], sides[i - 1], sides[i], -rim, -core, IndicatorPalette.EDGE, IndicatorPalette.EDGE)
			_add_strip(immediate, points[i - 1], points[i], sides[i - 1], sides[i], core, rim, IndicatorPalette.EDGE, IndicatorPalette.EDGE)
		_add_strip(immediate, points[i - 1], points[i], sides[i - 1], sides[i], -core, core, color_a, color_b)
	immediate.surface_end()


## The closed loop of `segments` points around `center` in the plane of
## `axis_a`/`axis_b`, scaled per-axis by `axis_scale`. Rings are just ribbons
## whose last point is their first.
static func _ring_points(center: Vector3, radius: float, segments: int, axis_a: Vector3 = Vector3.RIGHT, axis_b: Vector3 = Vector3.BACK, axis_scale: Vector3 = Vector3.ONE) -> PackedVector3Array:
	var points := PackedVector3Array()
	for i in range(segments + 1):
		var angle: float = (float(i) / segments) * TAU
		points.append(center + (axis_a * cos(angle) + axis_b * sin(angle)) * radius * axis_scale)
	return points


static func _longest_segment_squared(points: PackedVector3Array) -> float:
	var longest: float = 0.0
	for i in range(1, points.size()):
		longest = maxf(longest, points[i - 1].distance_squared_to(points[i]))
	return longest


## One quad between two cross-section offsets (`from_side` to `to_side`,
## in units of the per-point side vector) of the segment a->b.
func _add_strip(immediate: ImmediateMesh, a: Vector3, b: Vector3, side_a: Vector3, side_b: Vector3, from_side: float, to_side: float, color_a: Color, color_b: Color) -> void:
	var a0: Vector3 = a + side_a * from_side
	var a1: Vector3 = a + side_a * to_side
	var b0: Vector3 = b + side_b * from_side
	var b1: Vector3 = b + side_b * to_side
	immediate.surface_set_color(color_a)
	immediate.surface_add_vertex(a0)
	immediate.surface_add_vertex(a1)
	immediate.surface_set_color(color_b)
	immediate.surface_add_vertex(b1)
	immediate.surface_set_color(color_a)
	immediate.surface_add_vertex(a0)
	immediate.surface_set_color(color_b)
	immediate.surface_add_vertex(b1)
	immediate.surface_add_vertex(b0)


## One unit-ish side vector per point, shared by both segments meeting
## there (a miter join), so adjacent quads agree on the joint's edge
## instead of leaving a gap or overlap at every bend. Lengthened by
## 1/cos(half the turn) so the ribbon doesn't pinch at bends; that
## correction is skipped near a full reversal, where it spikes.
func _ribbon_sides(points: PackedVector3Array, camera: Camera3D) -> PackedVector3Array:
	var sides := PackedVector3Array()
	sides.resize(points.size())
	var closed: bool = points.size() > 2 and points[0].distance_squared_to(points[points.size() - 1]) < 0.00000001
	for i in range(points.size()):
		var prev: int = i - 1
		var next: int = i + 1
		if closed and i == 0:
			prev = points.size() - 2
		if closed and i == points.size() - 1:
			next = 1
		var dir_in := Vector3.ZERO
		var dir_out := Vector3.ZERO
		if prev >= 0:
			dir_in = (points[i] - points[prev]).normalized()
		if next < points.size():
			dir_out = (points[next] - points[i]).normalized()

		var dir: Vector3 = dir_in + dir_out
		if dir.length_squared() < 0.00000001:
			dir = dir_in if dir_in != Vector3.ZERO else dir_out

		var stretch: float = 1.0
		if dir_in != Vector3.ZERO and dir_out != Vector3.ZERO:
			var cos_half: float = sqrt(max(0.0, (1.0 + dir_in.dot(dir_out)) * 0.5))
			if cos_half > 0.2:
				stretch = 1.0 / cos_half

		var side := Vector3.ZERO
		if camera:
			side = dir.cross(camera.global_position - points[i])
		if side.length_squared() < 0.00000001:
			side = _horizontal_side(dir)
		sides[i] = side.normalized() * stretch
	return sides


## Sideways direction in the XZ plane, so a flat ribbon keeps its width
## seen from above even where the path climbs or a flier dives. Falls
## back to world right for a straight-up segment, which has no
## horizontal heading to turn.
static func _horizontal_side(direction: Vector3) -> Vector3:
	var horizontal := Vector2(direction.x, direction.z)
	if horizontal.length() < 0.001:
		return Vector3.RIGHT
	horizontal = horizontal.normalized()
	return Vector3(-horizontal.y, 0.0, horizontal.x)
