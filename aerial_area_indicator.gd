extends AreaIndicator
## AoE ability preview for AerialAreaTargeting specifically — abilities
## whose blast center can be aimed anywhere in 3D space, not just on the
## ground (Explosive Fireball). See area_indicator.gd for the floor-only
## sibling (Grease and anything else shaped like it) — the two
## explicitly exclude each other's cases so exactly one ever shows for a
## given armed ability.
##
## Extends AreaIndicator directly (not IndicatorBase) rather than
## duplicating it — this and area_indicator.gd are both fundamentally
## the same "AreaTargeting aim-line-plus-ring preview," just floor-only
## vs. full-3D, so the aim-line drawing (_update_line), the ring wrapper
## (_update_ring), the shared fields/export colors, and _get_active_unit
## are all inherited unchanged. What's genuinely different and stays
## here: which ability type arms this (_get_armed_aerial_ability), the
## ring shape itself (_draw_ring below overrides the inherited single-
## ring version with three mutually perpendicular rings — _update_ring's
## inherited body still calls _draw_ring() virtually, so it picks up
## this override for free), and the height-drag control neither the
## floor-only sibling nor IndicatorBase needs.
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
## camera-facing vertical plane controls height, via IndicatorBase's
## shared _sample_height_from_mouse). The resulting height is written to
## AbilityManager.aim_height_override, NOT held locally —
## ground_click_target.gd reads the exact same value at the moment of
## the actual click, so the confirmed cast can't disagree with what this
## preview showed.
##
## Only shows during combat, for the unit whose turn it currently is,
## only when player-controlled, and only when the currently armed
## ability's targeting is specifically AerialAreaTargeting.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own visuals in code (inherited from AreaIndicator/IndicatorBase).
## ground_collision_mask (see IndicatorBase) must match whatever physics
## layer your ground/terrain body is on.

## Whether the Ctrl height-drag was active last frame — used only to
## detect the moment it STARTS, so the drag's XZ anchor gets captured
## once per press instead of drifting every frame. Same pattern
## movement_indicator.gd uses for its own altitude drag.
var _height_dragging: bool = false
var _height_drag_anchor_xz: Vector2 = Vector2.ZERO


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
## duplicated rather than shared — the shared PART, the actual sampling
## math, lives on IndicatorBase as _sample_height_from_mouse; this
## surrounding drag/anchor bookkeeping is what's genuinely different per
## caller, since one writes to a Unit's flight_target_altitude and the
## other to AbilityManager.aim_height_override). On the frame the
## modifier is first held, the XZ point the ground hover was aiming at
## gets frozen — for the rest of the hold, mouse movement only changes
## height, not the aim point, so the two never fight over the same
## input. Writes the result straight to AbilityManager rather than a
## local field — see this file's header for why the click handler needs
## the SAME value.
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


func _get_armed_aerial_ability() -> Ability:
	return PlayerInteractionState.get_armed_ability_of_targeting_type(AerialAreaTargeting)


## Three mutually perpendicular rings (XZ, XY, ZY) sharing one center —
## see this file's header for why a single flat ring stopped being
## enough once the center can float in midair. Each ring is its own
## ImmediateMesh surface (three separate surface_begin/end pairs after
## one shared clear_surfaces()), not one continuous strip through all
## three — a shared strip would draw an unwanted connecting line from
## the end of one ring to the start of the next. Overrides
## AreaIndicator's own single-ring _draw_ring() — the inherited
## _update_ring() still calls this virtually, so it draws three rings
## here without needing its own copy of that wrapper.
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
