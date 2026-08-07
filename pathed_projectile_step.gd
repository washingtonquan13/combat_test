class_name PathedProjectileStep
extends VfxStep
## Sibling of ProjectileStep that flies along an actual NavigationGrid
## path instead of a straight line/arc — for a projectile that should
## visibly curve around obstacles the way a real object moving through
## the space would, rather than clipping through walls. Kept as its own
## class rather than a mode flag on ProjectileStep because the two
## follow genuinely different curve math (a single lerp+parabola vs. an
## arc-length walk over an N-point polyline) — same "one subclass per
## shape" split as AbilityTargeting/AbilityEffect.
##
## The path is computed ONCE, at the moment this step starts playing —
## NOT re-queried as the flight progresses, and NOT re-aimed if
## something moves into the way after launch. This is a one-time route
## snapshot ("heatseeking" in the sense of curving toward where the
## target WAS at cast time), not reactive homing — nothing here tracks
## a live target position mid-flight. A projectile that actually chases
## a moving target (and could miss because of it) would need to*, and
## is out of scope here.
##
## *to-hit is already resolved synchronously before this step ever
## plays (see UnitCombat.use_ability) — a truly reactive homing
## projectile would need to defer to-hit until arrival instead, a
## bigger change to combat resolution order, not a VFX addition.
##
## Purely visual timing, same as ProjectileStep — doesn't affect
## whether the ability hits, only how long an ability with
## waits_for_impact set takes to actually resolve. Pair with
## ImpactSignalStep right after this one in the same VfxEffect so
## notify_impact() fires exactly when the visual actually arrives, not
## a moment before.

@export var projectile_scene: PackedScene
## Fixed flight time in seconds. If 0, speed is used instead, computed
## from the ACTUAL path length (not straight-line distance) — a
## projectile that has to detour around an obstacle takes proportionally
## longer, rather than being timed as if it flew straight through.
@export var duration: float = 0.0
@export var speed: float = 15.0
## Passed to NavigationGrid.find_path as its own flying flag — true (the
## default) lets the path use open 3D air space rather than being
## confined to walkable ground cells, appropriate for something that
## flies rather than crawls along the floor.
@export var flying: bool = true
## Duck-typed the same way Unit's identically-named fields are (see
## NavigationGrid.find_path) — this step IS the "unit" passed to the
## path query, since a projectile has no real Unit of its own and is
## almost always much thinner than whatever body cast it. Kept small by
## default (a bolt, not a creature).
@export var radius: float = 0.1
@export var avoidance_margin: float = 0.0
@export var height: float = 0.1
## Same purpose as ProjectileStep's own field — see its doc comment for
## why a look_at()-driven wrapper is used instead of rotating the
## instanced scene's own root directly.
@export var facing_offset_degrees: float = 0.0
## Raises `from` by this much before using it as the path's start point
## (query AND actual flight origin) — a caster's global_position is its
## CharacterBody3D root, which sits at the BASE of its collision capsule
## (see unit.tscn: CollisionShape3D at local y=1 with a height-2 capsule
## — feet, not chest). That's too close to the ground to be a valid
## clearance/flying cell, and find_path only re-snaps its DESTINATION to
## the nearest valid cell, never its start (see NavigationGrid.find_path)
## — so an unraised, literally-at-the-feet start silently produces an
## empty path on every single query, not just an occasional edge case,
## and this step would then always fall back to a straight line no
## matter what's in the way. Confirmed by reproducing it directly: a
## flying=true query from a realistic ground-level point returns zero
## points. Doubles as a visual improvement anyway — a bolt originating
## at a caster's literal feet would look wrong regardless of pathing.
@export var launch_height_offset: float = 1.0
## Purely visual corner rounding for the flight path — see
## PathCornerRounding.round_corners. find_path's raw route is optimal
## but not smooth: real corners at real grid angles, which read as an
## unnaturally sharp swerve for something flying fast. This reshapes the
## path the projectile actually follows (unlike movement_indicator.gd's
## identical technique, which only ever affects what gets DRAWN — there's
## no separate "real" flight path elsewhere this needs to stay in sync
## with, so rounding the flown path directly is safe here).
@export var corner_round_radius: float = 2.0
@export var corner_round_segments: int = 6


func play(context: Node, from: Vector3, to: Vector3, _ability: Ability = null, _caster: Unit = null) -> void:
	if not projectile_scene:
		return

	var launch_point: Vector3 = from + Vector3(0, launch_height_offset, 0)

	var path: PackedVector3Array = NavigationGrid.find_path(context.get_tree(), launch_point, to, self, flying)
	if path.size() < 2:
		path = PackedVector3Array([launch_point, to])
	path = PathCornerRounding.round_corners(path, corner_round_radius, corner_round_segments)

	var wrapper := Node3D.new()
	context.get_tree().current_scene.add_child(wrapper)

	var instance := projectile_scene.instantiate()
	wrapper.add_child(instance)

	var total_length: float = _path_length(path)
	var flight_time: float = duration if duration > 0.0 else total_length / max(speed, 0.01)

	var tween: Tween = context.create_tween()
	tween.tween_method(
		func(t: float):
			if is_instance_valid(wrapper):
				_update_transform(wrapper, path, total_length, t),
		0.0, 1.0, flight_time
	)
	await tween.finished

	if is_instance_valid(wrapper):
		wrapper.queue_free()  # frees the instance too, as its child


func _path_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(path.size() - 1):
		total += path[i].distance_to(path[i + 1])
	return total


## Rotation follows the polyline's INSTANTANEOUS direction of travel (a
## tiny forward-sample along the path), same sampling idea as
## ProjectileStep._update_transform — but YAW ONLY, matching how
## UnitFacing.face_direction/snap_face_direction rotate a Unit: flatten
## the direction to the horizontal plane and rotate purely around Y,
## never pitching to match the path's vertical slope. A full 3D look_at
## would nose the projectile up/down through every altitude change
## (e.g. cresting an obstacle), which reads as an object tumbling rather
## than a unit-like body that stays level and simply turns to face where
## it's going. Same atan2 formula/sign convention as UnitFacing, applied
## instantly each frame rather than lerped — a projectile shouldn't lag
## its own direction of travel the way a walking body's turn might.
func _update_transform(wrapper: Node3D, path: PackedVector3Array, total_length: float, t: float) -> void:
	var current: Vector3 = _point_at_distance(path, total_length * t)
	wrapper.global_position = current

	var look_t: float = min(t + 0.01, 1.0)
	var ahead: Vector3 = _point_at_distance(path, total_length * look_t)

	var direction: Vector3 = ahead - current
	direction.y = 0.0
	if direction.length_squared() > 0.0001:
		wrapper.rotation.y = atan2(-direction.x, -direction.z) + deg_to_rad(facing_offset_degrees)


## Walks the polyline to the point `distance` units along its total
## length — the multi-segment equivalent of ProjectileStep's
## from.lerp(to, t).
func _point_at_distance(path: PackedVector3Array, distance: float) -> Vector3:
	if path.size() < 2:
		return path[0] if path.size() == 1 else Vector3.ZERO

	var remaining: float = distance
	for i in range(path.size() - 1):
		var seg_start: Vector3 = path[i]
		var seg_end: Vector3 = path[i + 1]
		var seg_length: float = seg_start.distance_to(seg_end)
		if remaining <= seg_length or i == path.size() - 2:
			var seg_t: float = 0.0 if seg_length < 0.0001 else clamp(remaining / seg_length, 0.0, 1.0)
			return seg_start.lerp(seg_end, seg_t)
		remaining -= seg_length

	return path[path.size() - 1]


func describe() -> String:
	return "Pathed projectile: %s" % ("fixed %.1fs" % duration if duration > 0.0 else "%.1f m/s" % speed)
