extends IndicatorBase
## AoE ability preview for AerialAreaTargeting specifically — abilities
## whose blast center can be aimed anywhere in 3D space, not just on the
## ground (Explosive Fireball). See area_indicator.gd for the floor-only
## sibling (Grease and anything else shaped like it) — the two
## explicitly exclude each other's cases so exactly one ever shows for a
## given armed ability.
##
## A line from caster to the hovered point (colored by range/line-of-
## sight, same states as line_of_sight_indicator.gd), plus a WIREFRAME-
## SPHERE outline sized to the real blast radius — read directly from
## the armed ability's own AreaTargeting, not a duplicated/guessed
## value, same WYSIWYG principle as the other indicators. Three mutually
## perpendicular rings rather than a filled mesh, matching how every
## other indicator in this project draws via line primitives — and
## specifically three rings, not one, since the center can be lifted off
## the ground here: a single flat ring floating in midair reads as a
## disc, not a sphere. 3 great circles is what actually communicates
## "blast radius in every direction."
##
## The hover point's HEIGHT is normally just wherever the ground raycast
## hit (an AoE center sitting on the ground, same as the floor-only
## sibling). Holding fly_altitude_modifier (Ctrl) lets the player drag
## it into the air instead: same technique movement_indicator.gd already
## uses for flying altitude (XZ freezes at the anchor the instant the
## modifier is pressed, a vertical mouse drag intersected against a
## camera-facing vertical plane controls height) — duplicated rather
## than shared, since sharing would mean this file depending on a
## scene-tree movement-preview script for an unrelated reason (same call
## already made for ProjectileStep/MoveCasterEffect's arc math). The
## resulting height is written to AbilityManager.aim_height_override,
## NOT held locally — ground_click_target.gd reads the exact same value
## at the moment of the actual click, so the confirmed cast can't
## disagree with what this preview showed.
##
## Only shows during combat, for the unit whose turn it currently is,
## only when player-controlled, and only when the currently armed
## ability's targeting is specifically AerialAreaTargeting.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own visuals in code. ground_collision_mask (see IndicatorBase)
## must match whatever physics layer your ground/terrain body is on.

@export var clear_color: Color = Color(1, 1, 1, 0.9)
@export var blocked_color: Color = Color(1, 0.2, 0.2, 0.9)
@export var out_of_range_color: Color = Color(0.5, 0.5, 0.5, 0.6)
@export var line_height_offset: float = 1.5
@export var ring_color: Color = Color(1, 0.5, 0.1, 0.9)
@export var ring_height_offset: float = 0.05
@export var ring_segments: int = 48

var _line_mesh: MeshInstance3D
var _line_immediate: ImmediateMesh
var _ring_mesh: MeshInstance3D
var _ring_immediate: ImmediateMesh

## Whether the Ctrl height-drag was active last frame — used only to
## detect the moment it STARTS, so the drag's XZ anchor gets captured
## once per press instead of drifting every frame. Same pattern
## movement_indicator.gd uses for its own altitude drag.
var _height_dragging: bool = false
var _height_drag_anchor_xz: Vector2 = Vector2.ZERO


func _ready() -> void:
	var line_built: Dictionary = _create_line_mesh()
	_line_mesh = line_built.mesh_instance
	_line_immediate = line_built.immediate

	var ring_built: Dictionary = _create_line_mesh()
	_ring_mesh = ring_built.mesh_instance
	_ring_immediate = ring_built.immediate


func _process(_delta: float) -> void:
	var unit := _get_active_unit()
	var ability := _get_armed_aerial_ability()

	if not unit or not ability:
		_hide_all()
		return

	var hover_point = _get_mouse_ground_point()
	if hover_point == null:
		_hide_all()
		return

	_handle_height_input(hover_point)
	if AbilityManager.has_aim_height_override:
		hover_point.y = AbilityManager.aim_height_override

	_update_line(unit, ability, hover_point)
	_update_ring(ability, hover_point)


## Modifier-style height control, mirroring movement_indicator.gd's
## _handle_altitude_input exactly (see this file's header for why it's
## duplicated rather than shared). On the frame the modifier is first
## held, the XZ point the ground hover was aiming at gets frozen — for
## the rest of the hold, mouse movement only changes height, not the
## aim point, so the two never fight over the same input. Writes the
## result straight to AbilityManager rather than a local field — see
## this file's header for why the click handler needs the SAME value.
func _handle_height_input(hover_point: Vector3) -> void:
	if not Input.is_action_pressed("fly_altitude_modifier"):
		_height_dragging = false
		return

	if not _height_dragging:
		_height_drag_anchor_xz = Vector2(hover_point.x, hover_point.z)
		_height_dragging = true

	var sampled_height = _sample_height_from_mouse(_height_drag_anchor_xz)
	if sampled_height != null:
		AbilityManager.set_aim_height_override(sampled_height)


## Identical technique to movement_indicator.gd's _sample_altitude_from_
## mouse — see that file's own doc comment for the full reasoning behind
## flattening the camera's back vector before building the plane.
func _sample_height_from_mouse(anchor_xz: Vector2):
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null

	var back: Vector3 = camera.global_transform.basis.z
	var normal := Vector3(back.x, 0.0, back.z)
	if normal.length() < 0.001:
		return null
	normal = normal.normalized()

	var anchor_point := Vector3(anchor_xz.x, 0.0, anchor_xz.y)
	var plane := Plane(normal, anchor_point)

	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var dir: Vector3 = camera.project_ray_normal(mouse_pos)

	var hit = plane.intersects_ray(from, dir)
	if hit == null:
		return null
	return hit.y


func _hide_all() -> void:
	if _line_mesh:
		_line_mesh.visible = false
	if _ring_mesh:
		_ring_mesh.visible = false


func _get_active_unit() -> Unit:
	return PlayerInteractionState.get_active_unit()


func _get_armed_aerial_ability() -> Ability:
	return PlayerInteractionState.get_armed_ability_of_targeting_type(AerialAreaTargeting)


func _update_line(unit: Unit, ability: Ability, hover_point: Vector3) -> void:
	var targeting: AreaTargeting = ability.targeting

	var color: Color
	if unit.global_position.distance_to(hover_point) > targeting.max_range:
		color = out_of_range_color
	elif targeting.requires_line_of_sight and not LineOfSight.has_clear_shot_to_point(unit, hover_point, targeting.los_obstruction_mask, targeting.eye_height):
		color = blocked_color
	else:
		color = clear_color

	var from: Vector3 = unit.global_position + Vector3(0, line_height_offset, 0)
	var to: Vector3 = hover_point + Vector3(0, line_height_offset, 0)

	_line_immediate.clear_surfaces()
	_line_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(from)
	_line_immediate.surface_set_color(color)
	_line_immediate.surface_add_vertex(to)
	_line_immediate.surface_end()
	_line_mesh.visible = true


func _update_ring(ability: Ability, hover_point: Vector3) -> void:
	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		_ring_mesh.visible = false
		return

	_draw_ring(hover_point, targeting.radius)
	_ring_mesh.visible = true


## Three mutually perpendicular rings (XZ, XY, ZY) sharing one center —
## see this file's header for why a single flat ring stopped being
## enough once the center can float in midair. Each ring is its own
## ImmediateMesh surface (three separate surface_begin/end pairs after
## one shared clear_surfaces()), not one continuous strip through all
## three — a shared strip would draw an unwanted connecting line from
## the end of one ring to the start of the next.
func _draw_ring(center: Vector3, radius: float) -> void:
	var lifted: Vector3 = center + Vector3(0, ring_height_offset, 0)
	_ring_immediate.clear_surfaces()
	_draw_ring_in_plane(lifted, radius, Vector3.RIGHT, Vector3.BACK)  # XZ — matches the floor-only ring exactly
	_draw_ring_in_plane(lifted, radius, Vector3.RIGHT, Vector3.UP)    # XY
	_draw_ring_in_plane(lifted, radius, Vector3.BACK, Vector3.UP)     # ZY


func _draw_ring_in_plane(center: Vector3, radius: float, basis_a: Vector3, basis_b: Vector3) -> void:
	_ring_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(ring_segments + 1):
		var angle: float = (float(i) / ring_segments) * TAU
		var point: Vector3 = center + (basis_a * cos(angle) + basis_b * sin(angle)) * radius
		_ring_immediate.surface_set_color(ring_color)
		_ring_immediate.surface_add_vertex(point)
	_ring_immediate.surface_end()
