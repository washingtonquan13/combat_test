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
## vs. full-3D, so the aim-line drawing (_update_line, coloured by the
## targeting's check()), the ring wrapper (_update_ring) and the shared
## fields/export colors are all inherited unchanged. What's genuinely
## different and stays here: which intent id arms this (serves() ->
## &"aerial_area", named by AerialAreaTargeting.indicator_ids), the ring
## shape itself (_draw_ring below overrides the inherited single-ring
## version with three mutually perpendicular rings — _update_ring's
## inherited body still calls _draw_ring() virtually, so it picks up
## this override for free), and the cloud's squash (_height_scale).
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
## it into the air instead (XZ freezes at the ground point the press
## started on, a vertical mouse drag sets the height). This indicator
## no longer reads that drag itself: ClickRouter resolves it into the
## Cursor, the intent writes it to AbilityManager.aim_height_override,
## and Aim.point arrives already lifted by AerialAreaTargeting.
## resolve_target_point — the same call the actual click makes, so the
## confirmed cast can't disagree with what this preview showed.
##
## Only shows during combat, for the unit whose turn it currently is,
## only when player-controlled, and only when the currently armed
## ability's targeting is specifically AerialAreaTargeting.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own visuals in code (inherited from AreaIndicator/IndicatorBase).
## The hovered point comes from the Aim ClickRouter hands draw().

var _height_scale: float = 1.0


func serves() -> StringName:
	return &"aerial_area"


func draw(aim: Aim) -> void:
	var unit: Unit = aim.caster
	var ability: Ability = aim.ability

	if not unit or not ability:
		_hide_all()
		return

	# Already lifted to any Ctrl-dragged height (see Aim.point).
	var hover_point = aim.point
	if hover_point == null:
		_hide_all()
		return

	_height_scale = _cloud_height_scale(ability)
	_update_line(unit, ability, hover_point)
	_update_ring(ability, hover_point)


## A cloud squashed flat (Surface.height_scale) previews as squashed as
## it will fill; a blast stays round.
func _cloud_height_scale(ability: Ability) -> float:
	for effect in ability.effects:
		if effect is SpawnSurfaceEffect and effect.surface and effect.surface.shape == Surface.Shape.SPHERE:
			return effect.surface.height_scale
	return 1.0


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
		var point: Vector3 = center + (basis_a * cos(angle) + basis_b * sin(angle)) * radius * Vector3(1.0, _height_scale, 1.0)
		_ring_immediate.surface_set_color(ring_color)
		_ring_immediate.surface_add_vertex(point)
	_ring_immediate.surface_end()
