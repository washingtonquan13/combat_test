class_name Shadows
extends RefCounted
## Where it is dark enough to count as shadow (Shadow Step), worked out
## when asked rather than stored, so a wall raised or a box dragged is in
## the answer at once with nothing to invalidate.
##
## Three things make shadow:
## - The sun. A point is in shadow when a ray from it toward the area's
##   shadow-casting DirectionalLight3D hits level geometry. Only a light
##   with shadow_enabled counts, so the game only calls shade what the
##   renderer draws as shade. An area without one has no sun shadows.
## - Darkness. A point inside a darkness cloud, or with one between it and
##   the sun, is in shadow, sun or no sun. A darkness cloud is one Dark
##   Vision sees through (Surface.is_darkness), which fog isn't.
## - Living units. A unit standing (or flying) between the point and the
##   sun shades it like a wall would, so an ally's shadow is somewhere to
##   step to. The dead cast none, nor does a unit sunk mid-step (it is in
##   XRaySilhouettes.UNDER_GROUND). `ignore` is left out: a unit asking
##   about its own feet would otherwise always be in its own shadow.

## How far toward the sun to look for something in the way, metres.
const SUN_REACH: float = 60.0
## Start the sun ray this far above the point, so the floor the point sits
## on doesn't count as being in the way.
const LIFT: float = 0.25
## Level geometry and unit bodies (units share layer 1).
const MASK: int = 1

## WorldContext instance id -> its sun (DirectionalLight3D) or null, so the
## scene is searched once per area, not per query.
static var _suns: Dictionary = {}


## Whether point (on the floor) is in shadow in context.
static func is_shadowed(point: Vector3, context: WorldContext, ignore: Unit = null) -> bool:
	if context == null:
		return false
	var sun: DirectionalLight3D = _sun_of(context)
	var lifted: Vector3 = point + Vector3.UP * LIFT
	var toward: Vector3 = sun.global_basis.z.normalized() if sun else Vector3.UP
	if _darkness_along(context, lifted, lifted + toward * 4.0):
		return true
	return sun != null and _sun_blocked(context, lifted, toward, ignore)


static func _darkness_along(context: WorldContext, from: Vector3, to: Vector3) -> bool:
	for cell in context.cloud_grid.cells_along(from, to):
		if cell.surface.is_darkness():
			return true
	return false


static func _sun_blocked(context: WorldContext, from: Vector3, toward: Vector3, ignore: Unit) -> bool:
	var root: Node3D = context.world_root
	if root == null or not root.is_inside_tree():
		return false
	var space: PhysicsDirectSpaceState3D = root.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + toward * SUN_REACH, MASK)
	var exclude: Array[RID] = []
	# Step past units that cast no shadow and look again behind them.
	for i in 8:
		query.exclude = exclude
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			return false
		if not hit.collider is Unit or _casts_shadow(hit.collider, ignore):
			return true
		exclude.append(hit.rid)
	return false


static func _casts_shadow(unit: Unit, ignore: Unit) -> bool:
	return unit != ignore and unit.is_alive() and not unit.is_in_group(XRaySilhouettes.UNDER_GROUND)


static func _sun_of(context: WorldContext) -> DirectionalLight3D:
	var id: int = context.get_instance_id()
	if _suns.has(id):
		var known = _suns[id]
		if known == null:
			return null
		if is_instance_valid(known):
			return known if _casts(known) else null
	var sun: DirectionalLight3D = null
	if context.world_root:
		for light in context.world_root.find_children("*", "DirectionalLight3D", true, false):
			if _casts(light):
				sun = light
				break
	_suns[id] = sun
	return sun


static func _casts(light: DirectionalLight3D) -> bool:
	return light.shadow_enabled and light.is_visible_in_tree() and light.light_energy > 0.0
