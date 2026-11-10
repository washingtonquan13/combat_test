class_name CeilingDrop
extends Node
## Put under a crawler (a Unit with Cling) that waits hanging from a
## ceiling: when a fight pulls it in, it lets itself down on a thread,
## straight to the floor below. Lowered, not fallen, so the drop doesn't
## hurt. Nothing else changes: it is in plain sight up there, and once down
## it is an ordinary crawler that may climb back up and drop again next
## fight.
##
## Only a ceiling counts. On a wall or the floor a fight starting does
## nothing.

## Fastest a drop runs: free fall's time over the height, stretched by this,
## so it reads as a quick lowering rather than a plummet.
const SLOWER_THAN_FALLING := 1.3
## Below this normal.y the surface held is a ceiling.
const CEILING_BELOW := -0.5
## What the floor below is found on: level geometry and props.
const FLOOR_MASK := 1

var _unit: Unit


func _ready() -> void:
	_unit = get_parent() as Unit
	if _unit == null:
		push_error("CeilingDrop must be a child of a Unit: %s" % get_path())
		return
	CombatManager.combat_started.connect(_on_combat_started)
	CombatManager.unit_joined_combat.connect(_on_joined)


func _on_combat_started(order: Array[Unit]) -> void:
	if order.has(_unit):
		drop()


func _on_joined(unit: Unit) -> void:
	if unit == _unit:
		drop()


## Lets go and is lowered to the floor below. Returns false, doing nothing,
## when the unit isn't hanging from a ceiling or there's no floor under it.
func drop() -> bool:
	if not is_instance_valid(_unit) or _unit.held_surface_normal().y >= CEILING_BELOW:
		return false
	var from: Vector3 = _unit.global_position
	var floor_at: Variant = _floor_below(from)
	if floor_at == null:
		return false
	var to: Vector3 = _clear_of_units(floor_at)
	var height: float = from.y - to.y
	var time: float = sqrt(2.0 * height / ArcFlight.GRAVITY) * SLOWER_THAN_FALLING
	_unit.stop_moving()
	_unit.begin_busy()
	var tween: Tween = _unit.carry_tween()
	tween.tween_property(_unit, ^"global_position", to, time) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(_unit.end_busy)
	SystemLog.print("%s drops from the ceiling." % LogFormat.unit_name(_unit))
	return true


func _floor_below(from: Vector3) -> Variant:
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 60.0, FLOOR_MASK)
	query.exclude = [_unit.get_rid()]
	query.hit_back_faces = false
	var hit: Dictionary = _unit.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.normal.y < 0.5:
		return null
	return hit.position


## Doesn't land on anyone: tries the spot under it, then rings around it.
func _clear_of_units(spot: Vector3) -> Vector3:
	for ring in 4:
		var steps: int = 1 if ring == 0 else 8
		for i in steps:
			var angle: float = TAU * i / steps
			var offset := Vector3(cos(angle), 0.0, sin(angle)) * ring * _unit.radius * 1.5
			var at: Variant = spot if ring == 0 else _floor_below(spot + offset + Vector3.UP * 2.0)
			if at != null and _free(at):
				return at
	return spot


func _free(at: Vector3) -> bool:
	for node in _unit.get_tree().get_nodes_in_group(&"units"):
		var other := node as Unit
		if other == null or other == _unit or other.get_world_3d() != _unit.get_world_3d():
			continue
		var gap := Vector2(other.global_position.x - at.x, other.global_position.z - at.z)
		if gap.length() < other.radius + _unit.radius and absf(other.global_position.y - at.y) < 2.0:
			return false
	return true
