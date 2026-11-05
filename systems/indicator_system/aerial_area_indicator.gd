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
## &"aerial_area", named by AerialAreaTargeting.indicator_ids), the
## volume's shape (_draw_ring below: a sphere AoeShell rather than the
## floor-only footprint), and the cloud's squash (_height_scale).
##
## A line from caster to the hovered point (colored by range/line-of-
## sight, same states as line_of_sight_indicator.gd), plus the blast
## volume as an AoeShell sized to the real radius, read from the armed
## ability's own AreaTargeting. The shell's cut line is where the blast
## meets the world, so it reads the same on the ground (a dome and its
## ring) and in the air (whatever ledge or wall it clips).
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
## The blast centre's height over the floor when it is aimed into the air
## (the cursor on the height plane, or a Ctrl-lifted point): ring, drop
## line, shadow and readout. Hidden on the ground.
var _altitude: AltitudeMarker


func serves() -> StringName:
	return &"aerial_area"


func _ready() -> void:
	super()
	_altitude = _create_altitude_marker()


func _hide_all() -> void:
	super()
	if _altitude:
		_altitude.hide_marker()


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
	_outline_caught(unit, ability, hover_point)
	_altitude.show_at(hover_point, AltitudeMarker.floor_under(aim, hover_point), ring_color)


## A cloud squashed flat (Surface.height_scale) previews as squashed as
## it will fill; a blast stays round.
func _cloud_height_scale(ability: Ability) -> float:
	for effect in ability.effects:
		if effect is SpawnSurfaceEffect and effect.surface and effect.surface.shape == Surface.Shape.SPHERE:
			return effect.surface.height_scale
	return 1.0


## A sphere, centred wherever it is aimed. On the ground it is a dome
## whose cut line is the ring; lifted, the cut line shows exactly what
## it clips (a ledge, a wall).
func _draw_ring(center: Vector3, radius: float) -> void:
	_shell.set_shape(AoeShell.Shape.SPHERE)
	_shell.show_at(center, radius, _height_scale)

