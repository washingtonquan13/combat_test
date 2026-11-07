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
## Where on the caster the projectile is SEEN to leave from. The route
## (and its preview) still starts launch_height_offset above the feet;
## the flight just begins at this point instead and joins the route
## where it passes the hand. GROUND keeps the route's own start.
@export var launch_from: CharacterModel.Anchor = CharacterModel.Anchor.GROUND


func play(context: Node, from: Vector3, to: Vector3, _ability: Ability = null, _caster: Unit = null) -> void:
	if not projectile_scene:
		return

	var path: PackedVector3Array = route(_caster, from, unit_at(context.get_tree(), to), to)
	if launch_from != CharacterModel.Anchor.GROUND and is_instance_valid(_caster):
		path = _from_hand(path, _caster.anchor(launch_from))

	var total_length: float = _path_length(path)
	var flight_time: float = duration if duration > 0.0 else total_length / max(speed, 0.01)

	var wrapper := Node3D.new()
	WorldManager.spawn_parent().add_child(wrapper)
	# Placed before the scene goes in, so nothing it lays down (a trail)
	# starts from the world origin.
	_update_transform(wrapper, path, total_length, 0.0)

	var instance := projectile_scene.instantiate()
	wrapper.add_child(instance)
	# A scene that shapes itself by how far along it is (the missile's
	# darts weaving apart and back together) is told each frame.
	var follows := instance.has_method(&"set_flight_progress")

	var tween: Tween = context.create_tween()
	tween.tween_method(
		func(t: float):
			if is_instance_valid(wrapper):
				_update_transform(wrapper, path, total_length, t)
				if follows:
					instance.set_flight_progress(t, total_length),
		0.0, 1.0, flight_time
	)
	await tween.finished

	if is_instance_valid(wrapper):
		arrive_and_free(wrapper, instance)


## The flight path, rounded: from launch_height_offset above `from` to
## the target's chest (or `to` when no unit is aimed at). The cast and
## seeking_indicator.gd's preview both call this, so they draw and fly
## the same route.
##
## The caster and target are ignored as occupants: units fill their
## whole body height, so the launch point sits inside the caster's
## body and the goal inside the target's. Without the ignore the start
## cell is blocked, find_path returns nothing, and the bolt flies a
## straight line through every wall.
func route(caster: Unit, from: Vector3, target: Unit, to: Vector3) -> PackedVector3Array:
	var launch_point: Vector3 = from + Vector3(0, launch_height_offset, 0)
	var end: Vector3 = LineOfSight.shot_to(target) if target else to
	var ignore: Array = []
	if caster:
		ignore.append(caster)
		# This step is a Resource, not a node in a world, so the
		# caster names which world the query runs in.
		NavigationGrid.world_to_cell(launch_point, caster)
	if target:
		ignore.append(target)
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var path: PackedVector3Array = NavigationGrid.find_path(tree, launch_point, end, self, flying, ignore)
	if path.size() < 2:
		path = PackedVector3Array([launch_point, end])
	elif path[-1].distance_to(end) > 0.05:
		# find_path ends on the goal cell's centre, not the point.
		path.append(end)
	var space: PhysicsDirectSpaceState3D = caster.get_world_3d().direct_space_state if caster else null
	var is_clear := func(a: Vector3, b: Vector3) -> bool: return space == null or _geometry_clear(space, a, b)
	return PathCornerRounding.round_corners(path, corner_round_radius, corner_round_segments, is_clear)


## No wall between a and b. Units share layer 1 with walls and are
## stepped past: the route already goes around them.
static func _geometry_clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(a, b, 1)
	var exclude: Array[RID] = []
	for _i in 8:
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return true
		if not hit.collider is Unit:
			return false
		exclude.append(hit.rid)
	return true


## The route, started at the hand: points no farther along than the
## hand (closer to the route's start than it is) are dropped.
static func _from_hand(path: PackedVector3Array, hand: Vector3) -> PackedVector3Array:
	var start: Vector3 = path[0]
	var flat := func(v: Vector3) -> Vector2: return Vector2(v.x, v.z)
	var reach: float = flat.call(start).distance_to(flat.call(hand))
	var out := PackedVector3Array([hand])
	for i in range(1, path.size()):
		if i < path.size() - 1 and flat.call(start).distance_to(flat.call(path[i])) <= reach:
			continue
		out.append(path[i])
	return out


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
