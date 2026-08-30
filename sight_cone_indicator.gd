class_name SightConeIndicator
extends IndicatorBase
## BG3-style vision cones on the ground: for every NPC that could notice
## the party, the wedge it can actually see into — the same
## vision_cone_degrees and max_sight_range DetectionManager rolls against,
## read straight off the unit rather than redrawn from guessed values.
## If the cone lies, the bug is visible instead of invisible.
##
## Coloured by AWARENESS, which is the part BG3 doesn't do and this
## project needs more: a cone shifts from calm to alarmed to hostile as
## its owner goes UNAWARE -> SUSPICIOUS -> AWARE (see UnitAwareness).
## Detection is rolled repeatedly and resolves over a second or two, so
## without this the player gets no feedback between "unseen" and
## "suddenly in combat" — the state exists, and drawing it is most of
## what makes the mechanic readable.
##
## Faint fill PLUS an outline, departing slightly from the pure-line
## convention the other indicators state (see area_indicator.gd's header
## on rings over discs). The reasoning there — an outline shows what's
## inside without obscuring it — still holds, so the fill is kept low
## enough to read as a tint rather than a surface. A bare arc turned out
## genuinely hard to parse at a glance when several overlap, which is
## exactly the situation these exist for.
##
## Flat at the observer's own height, like the AoE ring. Terrain-following
## would mean raycasting down at every arc vertex of every cone every
## frame — hundreds of casts for a cosmetic gain that only shows up on
## slopes this project doesn't have yet.
##
## Toggle with the toggle_sight_cones InputMap action (F4 by default —
## see project.godot > Input Map), sitting next to F3's nav overlay
## because it belongs to the same family: a view onto what a system is
## actually thinking, useful while building and distracting the rest of
## the time.
##
## Scene setup: attach to a Node3D under Indicators in MainRoot.tscn.

## Master switch. Also what the F4 toggle flips, so the exported value is
## simply the starting state rather than a separate concept.
@export var enabled: bool = true
## Only draw cones for units actually hostile to the player. Off by
## default: a neutral's cone is worth seeing too, since walking into it
## still gets you noticed, and noticing is what escalates a neutral into
## a threat later.
@export var hostiles_only: bool = false
## Hidden during combat. Everyone in a fight already knows where everyone
## is, so cones there are clutter over information nobody needs.
@export var hide_in_combat: bool = true

@export_group("Colors")
## Hasn't noticed anything — the safe-to-approach state.
@export var unaware_color: Color = Color(0.35, 0.65, 1.0, 0.85)
## Something registered but wasn't identified. The warning beat.
@export var suspicious_color: Color = Color(1.0, 0.75, 0.15, 0.9)
## Identified, and about to act on it.
@export var aware_color: Color = Color(1.0, 0.25, 0.2, 0.95)
## Multiplied into the outline colour for the filled wedge, so fill and
## edge always agree without authoring six colours.
@export var fill_alpha_scale: float = 0.16

@export_group("Shape")
## Arc resolution. 24 is smooth at these radii without generating
## meaningful vertex count for a handful of cones.
@export var arc_segments: int = 24
## Lifted off the floor to avoid z-fighting with it.
@export var height_offset: float = 0.05

var _fill_mesh: MeshInstance3D
var _fill_immediate: ImmediateMesh
var _edge_mesh: MeshInstance3D
var _edge_immediate: ImmediateMesh


func _ready() -> void:
	var fill_built: Dictionary = _create_line_mesh()
	_fill_mesh = fill_built.mesh_instance
	_fill_immediate = fill_built.immediate

	var edge_built: Dictionary = _create_line_mesh()
	_edge_mesh = edge_built.mesh_instance
	_edge_immediate = edge_built.immediate


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("toggle_sight_cones"):
		return
	enabled = not enabled
	# Hide immediately rather than waiting for the next _process: with no
	# observers to draw, _process returns early without touching
	# visibility, so a toggle-off while nothing is on screen would
	# otherwise leave the last frame's cones sitting there.
	if not enabled:
		_fill_mesh.visible = false
		_edge_mesh.visible = false
	SystemLog.print("Sight cones %s." % ("shown" if enabled else "hidden"))


func _process(_delta: float) -> void:
	var observers: Array[Unit] = _observers()
	if observers.is_empty():
		_fill_mesh.visible = false
		_edge_mesh.visible = false
		return

	_fill_immediate.clear_surfaces()
	_edge_immediate.clear_surfaces()

	# One surface for ALL cones rather than one mesh per unit: every cone
	# shares a material and is rebuilt each frame anyway, so batching them
	# is both fewer draw calls and far less node bookkeeping as units come
	# and go.
	_fill_immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	_edge_immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	for observer in observers:
		_draw_cone(observer)
	_fill_immediate.surface_end()
	_edge_immediate.surface_end()

	_fill_mesh.visible = true
	_edge_mesh.visible = true


## Everyone whose cone should be on screen right now.
func _observers() -> Array[Unit]:
	var result: Array[Unit] = []
	if not enabled:
		return result
	if hide_in_combat and CombatManager.in_combat:
		return result

	var tree: SceneTree = get_tree()
	if tree == null:
		return result

	var party: Array[Unit] = []
	for unit in UnitQuery.living_units(tree):
		if unit.is_player_controlled():
			party.append(unit)
	if party.is_empty():
		return result

	for unit in UnitQuery.living_units(tree):
		if unit.is_player_controlled():
			continue
		if hostiles_only and not unit.is_hostile_to(party[0]):
			continue
		result.append(unit)
	return result


func _draw_cone(observer: Unit) -> void:
	var color: Color = _color_for(observer)
	var fill: Color = Color(color.r, color.g, color.b, color.a * fill_alpha_scale)

	var origin: Vector3 = observer.global_position
	origin.y += height_offset

	var forward: Vector3 = observer.visual_forward()
	forward.y = 0.0
	if forward.length() < 0.01:
		return
	forward = forward.normalized()

	var radius: float = observer.max_sight_range
	var half_angle: float = deg_to_rad(observer.vision_cone_degrees) * 0.5
	var base_angle: float = atan2(forward.x, forward.z)

	var arc: PackedVector3Array = []
	for i in range(arc_segments + 1):
		var t: float = float(i) / float(arc_segments)
		var angle: float = base_angle - half_angle + t * (half_angle * 2.0)
		arc.append(origin + Vector3(sin(angle), 0.0, cos(angle)) * radius)

	# Fill: a triangle fan from the observer out to each arc segment.
	for i in range(arc.size() - 1):
		_fill_immediate.surface_set_color(fill)
		_fill_immediate.surface_add_vertex(origin)
		_fill_immediate.surface_set_color(fill)
		_fill_immediate.surface_add_vertex(arc[i])
		_fill_immediate.surface_set_color(fill)
		_fill_immediate.surface_add_vertex(arc[i + 1])

	# Edge: the two straight sides plus the arc, as discrete line pairs
	# (PRIMITIVE_LINES, not LINE_STRIP — a strip would run a stray segment
	# between one cone's last point and the next cone's first).
	_add_edge(origin, arc[0], color)
	_add_edge(origin, arc[arc.size() - 1], color)
	for i in range(arc.size() - 1):
		_add_edge(arc[i], arc[i + 1], color)

	# The inner circle where facing stops mattering — DetectionManager
	# ignores the cone entirely inside proximity_radius, so a cone drawn
	# without it would promise a blind spot that isn't there.
	_draw_proximity_ring(origin, observer.proximity_radius, color)


func _draw_proximity_ring(center: Vector3, radius: float, color: Color) -> void:
	if radius <= 0.0:
		return
	var previous: Vector3 = center + Vector3(0.0, 0.0, radius)
	for i in range(1, arc_segments + 1):
		var angle: float = (float(i) / float(arc_segments)) * TAU
		var point: Vector3 = center + Vector3(sin(angle), 0.0, cos(angle)) * radius
		_add_edge(previous, point, color)
		previous = point


func _add_edge(from: Vector3, to: Vector3, color: Color) -> void:
	_edge_immediate.surface_set_color(color)
	_edge_immediate.surface_add_vertex(from)
	_edge_immediate.surface_set_color(color)
	_edge_immediate.surface_add_vertex(to)


func _color_for(observer: Unit) -> Color:
	match observer.awareness().state:
		UnitAwareness.State.AWARE:
			return aware_color
		UnitAwareness.State.SUSPICIOUS:
			return suspicious_color
		_:
			return unaware_color
