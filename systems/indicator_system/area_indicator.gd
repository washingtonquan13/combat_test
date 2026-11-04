class_name AreaIndicator
extends IndicatorBase
## AoE ability preview, BG3-style: a line from caster to the hovered
## point (colored by range/line-of-sight, same states as
## line_of_sight_indicator.gd), plus a RING outline at that point sized
## to the real blast radius — read directly from the armed ability's own
## AreaTargeting, not a duplicated/guessed value, same WYSIWYG principle
## as the other indicators. A ring rather than a filled disc
## deliberately — an outline shows exactly what's inside the blast
## without obscuring it. The aim line is a PathTube like every other
## indicator line; the ring stays a flat ribbon (IndicatorBase.
## _add_ribbon), since it is a footprint, not a line.
##
## FLOOR-ONLY — the center always sits wherever the ground raycast hit,
## with no way to lift it. Deliberate: this indicator is for abilities
## where an airborne blast center wouldn't make sense (Grease, which
## spawns a ground-hugging Surface spilled over the ground's cells — see
## SpawnSurfaceEffect/Surface). For
## an ability that genuinely CAN be aimed in open 3D space (Fireball),
## see aerial_area_indicator.gd/AerialAreaTargeting instead — this
## indicator explicitly EXCLUDES those (AerialAreaTargeting.indicator_ids
## names &"aerial_area", not &"area") so the two never both show for the
## same armed ability.
##
## Only shows during combat, for the unit whose turn it currently is,
## only when player-controlled, and only when the currently armed
## ability uses AreaTargeting (but not AerialAreaTargeting).
##
## The line's colour is the armed AreaTargeting's own check() — the same
## range/LoS rule the cast uses, not a copy of it kept here.
##
## Scene setup: attach to a Node3D anywhere in your main scene — builds
## its own visuals in code. The hovered point comes from the Aim
## ClickRouter hands draw(); nothing here raycasts.

@export var clear_color: Color = IndicatorPalette.OK
@export var blocked_color: Color = IndicatorPalette.BLOCKED
@export var out_of_range_color: Color = IndicatorPalette.OUT_OF_REACH
@export var line_height_offset: float = 1.5
## Not an answer colour: the shell only says how big the area is and
## never changes with whether the cast is allowed (the line says that).
@export var ring_color: Color = IndicatorPalette.AOE

var _line_mesh: PathTube
var _shell: AoeShell
## Units outlined as inside the area this frame (Unit.set_area_targeted).
var _targeted: Array[Unit] = []


func serves() -> StringName:
	return &"area"


func _ready() -> void:
	super()
	_line_mesh = _create_tube()

	_shell = AoeShell.new()
	add_child(_shell)
	_owned_meshes.append(_shell)
	_shell.set_tint(ring_color)


func draw(aim: Aim) -> void:
	var unit: Unit = aim.caster
	var ability: Ability = aim.ability

	if not unit or not ability:
		_hide_all()
		return

	var hover_point = aim.point
	if hover_point == null:
		_hide_all()
		return

	_update_line(unit, ability, hover_point)
	_update_ring(ability, hover_point)
	_update_targets(unit, ability, hover_point)


func _hide_all() -> void:
	if _line_mesh:
		_line_mesh.visible = false
	if _shell:
		_shell.visible = false
	_set_targets([])


func hide_visuals() -> void:
	super()
	_set_targets([])


## Outlines exactly who the cast will catch: the same UnitQuery scan the
## area effects run, with their own hostile/ally gates. A spawned surface
## or cloud filters no one, so it catches everyone inside.
func _update_targets(caster: Unit, ability: Ability, center: Vector3) -> void:
	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		_set_targets([])
		return
	var hostiles := false
	var allies := false
	for effect in ability.effects:
		if effect is SpawnSurfaceEffect:
			hostiles = true
			allies = true
		elif "affects_hostiles" in effect:
			hostiles = hostiles or effect.affects_hostiles
			allies = allies or effect.affects_allies
	if not hostiles and not allies:
		_set_targets([])
		return
	_set_targets(UnitQuery.area_affected(caster.get_tree(), caster, center, targeting.radius, hostiles, allies))


func _set_targets(units: Array[Unit]) -> void:
	for unit in _targeted:
		if is_instance_valid(unit) and not units.has(unit):
			unit.set_area_targeted(false)
	for unit in units:
		if not _targeted.has(unit):
			unit.set_area_targeted(true)
	_targeted = units


func _update_line(unit: Unit, ability: Ability, hover_point: Vector3) -> void:
	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		_line_mesh.visible = false
		return

	# BLOCKED and INVALID both mean "this click is refused".
	var color: Color
	match targeting.check(unit, hover_point):
		AbilityTargeting.Reach.OK:
			color = clear_color
		AbilityTargeting.Reach.OUT_OF_RANGE:
			color = out_of_range_color
		_:
			color = blocked_color

	var from: Vector3 = unit.global_position + Vector3(0, line_height_offset, 0)
	var to: Vector3 = hover_point + Vector3(0, line_height_offset, 0)

	_line_mesh.show_line(PackedVector3Array([from, to]), color)


func _update_ring(ability: Ability, hover_point: Vector3) -> void:
	var targeting := ability.targeting as AreaTargeting
	if not targeting:
		_shell.visible = false
		return
	_draw_ring(hover_point, targeting.radius)


## Floor-only: the footprint the spill will cover, traced on the terrain.
func _draw_ring(center: Vector3, radius: float) -> void:
	_shell.set_shape(AoeShell.Shape.FOOTPRINT)
	_shell.show_at(center, radius)
