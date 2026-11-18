extends "res://tools/locomotion_demo.gd"
## Recorded showcase of the feet meeting the ground - NOT a test. Boots the
## game, finds the steepest walkable ground near the hero, and walks it: up,
## standing on it, across it and back down. Prints the ground under each
## foot (over the unit's), the hips' drop and how far the IK missed, as
## BodyFootLock sees them. Record it like locomotion_demo. GROUND=0 in the
## environment turns the ground off (pins and stride stay), for a before and
## after.


func _run() -> void:
	await _wait(1.0)
	await _boot_into_arena()
	_hero = PartyManager.leader
	SelectionManager.select(_hero)
	var lock: BodyFootLock = _hero.animator().locomotion.foot_lock
	var off: bool = OS.get_environment("GROUND") == "0"
	if off:
		lock.set_physics_process(false)
	var slope: Array = _steepest(_hero.global_position)
	if slope.is_empty():
		_say("no slope found near the hero")
		await _wait(1.0)
		get_tree().quit()
		return
	var at: Vector3 = slope[0]
	var up: Vector3 = slope[1]
	var across: Vector3 = up.cross(Vector3.UP).normalized()
	print("slope at %s, %.0f deg, rising %s" % [at, slope[2], up])
	_follow(4.0)
	_say("To the foot of the slope")
	await _go(at - up * 3.5)
	_aim_camera(across)
	await _wait(1.0)
	_say("Walk up it" + (" (ground off)" if off else ""))
	await _walk_watching(at + up * 3.5)
	_say("Stand on it, across the slope")
	await _face(across, 1.5)
	await _watch(2.0)
	_say("Walk across it")
	await _walk_watching(at + up * 3.5 + across * 3.0)
	_say("Walk down it")
	await _walk_watching(at - up * 3.5 + across * 3.0)
	await _watch(1.5)
	get_tree().quit()


## The camera side on to `across`'s slope.
func _aim_camera(across: Vector3) -> void:
	var camera: CRPGCamera = get_tree().root.find_children("*", "CRPGCamera", true, false)[0]
	camera.target_yaw = rad_to_deg(atan2(across.x, across.z))


func _walk_watching(to: Vector3) -> void:
	if not _hero.move_to(to):
		_say("move refused")
		return
	var n: int = 0
	while _hero.is_moving():
		await get_tree().physics_frame
		n += 1
		if n % 6 == 0:
			print("  " + _ground_line())
	await _watch(1.0)


func _watch(seconds: float) -> void:
	var frames: int = int(seconds * 60.0)
	for f in frames:
		await get_tree().physics_frame
		if f % 15 == 14:
			print("  still " + _ground_line())


func _ground_line() -> String:
	var lock: BodyFootLock = _hero.animator().locomotion.foot_lock
	return "y %.2f ground L %+.1f R %+.1f cm, hips %+.1f cm, feet L %.2f%s R %.2f%s, missed %.1f / %.1f cm, %s" % [
		_hero.global_position.y, lock._ground[0] * 100.0, lock._ground[1] * 100.0, lock._drop * 100.0,
		lock._weight[0], "*" if lock._pinned[0] else "", lock._weight[1], "*" if lock._pinned[1] else "",
		lock.miss[0] * 100.0, lock.miss[1] * 100.0, _hero.animator().playback.current_animation]


## The steepest walkable ground within 40 m of `from`: [point, the way it
## rises (level, unit), its angle in degrees], or [] with none over 8 deg.
func _steepest(from: Vector3) -> Array:
	var best: Array = []
	var best_rise: float = tan(deg_to_rad(8.0))
	for gx in range(-40, 41, 2):
		for gz in range(-40, 41, 2):
			var p: Vector3 = from + Vector3(gx, 0.0, gz)
			for k in 4:
				var a: float = PI * float(k) / 4.0
				var d := Vector3(cos(a), 0.0, sin(a))
				var lo: Dictionary = _ground_at(p - d * 2.0, from.y)
				var hi: Dictionary = _ground_at(p + d * 2.0, from.y)
				var mid: Dictionary = _ground_at(p, from.y)
				if lo.is_empty() or hi.is_empty() or mid.is_empty():
					continue
				if (lo.normal as Vector3).y < 0.8 or (hi.normal as Vector3).y < 0.8 or (mid.normal as Vector3).y < 0.8:
					continue
				var rise: float = ((hi.position as Vector3).y - (lo.position as Vector3).y) / 4.0
				# An even rise, not a step: the middle halfway between the ends.
				var even: float = absf((mid.position as Vector3).y - ((hi.position as Vector3).y + (lo.position as Vector3).y) * 0.5)
				if even > 0.1 or absf(rise) > tan(deg_to_rad(40.0)):
					continue
				if absf(rise) > best_rise:
					best_rise = absf(rise)
					best = [mid.position, d * signf(rise), rad_to_deg(atan(absf(rise)))]
	return best


func _ground_at(p: Vector3, y: float) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(Vector3(p.x, y + 6.0, p.z), Vector3(p.x, y - 6.0, p.z), 1)
	var exclude: Array[RID] = []
	for _try in 4:
		query.exclude = exclude
		var hit: Dictionary = _hero.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or not (hit.collider is Unit):
			return hit
		exclude.append(hit.rid)
	return {}
