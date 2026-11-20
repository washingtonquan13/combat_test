class_name FramingCheck
extends RefCounted
## What each shot actually puts on screen, measured from the picture rather
## than from the shot's numbers. The composition counterpart of
## CinematicStage.cut_problems(): that one checks WHEN cuts land; this checks
## WHAT the cut shows.
##
## WHY IT EXISTS. A FramingRig is a camera spot and an aim point. Nothing
## in that says where the people end up in the frame, so a shot can satisfy
## every rule a stage knows (the cut times) and still show
## a man with no head and a screen of grass. This projects each framed
## person's head, hips and feet through the real camera every frame and
## reports, per shot, what went wrong.
##
## USE. A walkthrough makes one, calls sample(stage) once a frame while the
## scene plays (after the stage has moved the bodies and the camera, e.g. on
## RenderingServer.frame_pre_draw), then prints report() and problems().
## It costs a few bone reads per framed role per frame; nothing runs it
## during play.
##
## WHO IS FRAMED. A shot's FramingRig.framed_roles; empty means its
## subject_role and look_role. A shot on a mark with no roles named frames
## nobody, so it is reported but has nothing to fail.
##
## The picture is the viewport minus the cutscene's letterbox bars as they
## stand on that frame (CinematicOverlay.covered()).

## A framed person whose head top is above or beside the picture on more
## than this share of a shot's frames has had the head cut off.
const HEAD_CUT_SHARE := 0.10
## A framed person wholly out of the picture on more than this share.
const OFF_SHARE := 0.20
## Head top nearer the picture's top edge than this (of its height) on
## average: cramped, no headroom.
const HEADROOM := 0.03
## A framed person whose median height on screen (head top to feet) is
## below this share of the picture is a speck, not a subject.
const MIN_HEIGHT := 0.15
## A shot shorter than this is a flash the eye cannot read.
const MIN_SHOT_SECONDS := 0.5
## A framed face hidden behind the set (a rock, a wall) on more than this
## share of the shot's frames.
const BLOCKED_SHARE := 0.25
## Metres from the Head bone to the top of the head.
const HEAD_TOP := 0.2

## One entry per shot as it played: {name, from, to, frames, roles: {role:
## stats}, order: {pair: [left-of count, right-of count]}}.
var shots: Array[Dictionary] = []


## One frame. Call after the stage and the camera have moved for it.
func sample(stage: CinematicStage) -> void:
	var rig: FramingRig = stage.live_shot() if stage else null
	var holder: CinematicCamera = CinematicDirector.camera()
	var camera: Camera3D = holder.camera() if holder else null
	if rig == null or camera == null or not camera.is_inside_tree():
		return
	var player: AnimationPlayer = stage.timeline()
	var playing: bool = player != null and player.is_playing()
	var clock: float = player.current_animation_position if playing else 0.0
	var shot: Dictionary = shots[-1] if not shots.is_empty() else {}
	if shot.is_empty() or shot.name != rig.name:
		shot = {name = rig.name, from = clock, to = clock, frames = 0, roles = {}, order = {}}
		shots.append(shot)
	# The last frames of a scene can come after its timeline has stopped;
	# they still count, but the span keeps the last time it read.
	if playing:
		shot.to = clock
	shot.frames += 1

	var size: Vector2 = camera.get_viewport().get_visible_rect().size
	var screen: CinematicOverlay = CinematicDirector.overlay()
	var bar: float = screen.covered() if screen else 0.0
	var top: float = size.y * bar
	var height: float = size.y * (1.0 - 2.0 * bar)
	var xs := {}
	for role: StringName in _framed(rig):
		var model: CharacterModel = StandIn.body_of(stage.actor(role))
		var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false) if model else null
		if skeleton == null:
			continue
		var stats: Dictionary = shot.roles.get(role, {})
		if stats.is_empty():
			stats = {frames = 0, off = 0, head_cut = 0, blocked = 0, heights = [], head_x = 0.0, head_y = 0.0, head_n = 0}
			shot.roles[role] = stats
		stats.frames += 1
		var head_pose: Transform3D = skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("Head"))
		var head: Vector3 = head_pose.origin
		var crown: Vector3 = head + Vector3.UP * HEAD_TOP
		var hips: Vector3 = _bone(skeleton, "Hips")
		var feet: Vector3 = (_bone(skeleton, "LeftFoot") + _bone(skeleton, "RightFoot")) * 0.5
		# Picture coordinates: x 0..1 across, y 0..1 down the area between
		# the bars. Behind the lens counts as nowhere.
		var at := {}
		for key: String in ["crown", "head", "hips", "feet"]:
			var point: Vector3 = {crown = crown, head = head, hips = hips, feet = feet}[key]
			if camera.is_position_behind(point):
				continue
			var p: Vector2 = camera.unproject_position(point)
			at[key] = Vector2(p.x / size.x, (p.y - top) / height)
		var inside := func(key: String) -> bool:
			if not at.has(key):
				return false
			var p: Vector2 = at[key]
			return p.x >= 0.0 and p.x <= 1.0 and p.y >= 0.0 and p.y <= 1.0
		var any_in: bool = inside.call("head") or inside.call("hips") or inside.call("feet")
		if not any_in:
			stats.off += 1
			continue
		if not inside.call("crown"):
			stats.head_cut += 1
		if at.has("crown") and at.has("feet"):
			stats.heights.append(absf((at.feet as Vector2).y - (at.crown as Vector2).y))
		if at.has("head"):
			stats.head_x += (at.head as Vector2).x
			stats.head_y += (at.crown as Vector2).y if at.has("crown") else (at.head as Vector2).y
			stats.head_n += 1
			xs[role] = (at.head as Vector2).x
			if _blocked(camera, head):
				stats.blocked += 1
	var names: Array = xs.keys()
	names.sort()
	for i in names.size():
		for j in range(i + 1, names.size()):
			var pair: String = "%s|%s" % [names[i], names[j]]
			var count: Array = shot.order.get(pair, [0, 0])
			count[0 if xs[names[i]] < xs[names[j]] else 1] += 1
			shot.order[pair] = count


## Per shot: how long it played and, per framed person, their median height
## and average head position in the picture.
func report() -> PackedStringArray:
	var lines := PackedStringArray()
	for shot: Dictionary in shots:
		var parts := PackedStringArray()
		for role: StringName in shot.roles:
			var s: Dictionary = shot.roles[role]
			var head: String = "(%.2f, %.2f)" % [s.head_x / s.head_n, s.head_y / s.head_n] if s.head_n > 0 else "(none)"
			parts.append("%s height %.0f%%, crown at %s, off %d, head cut %d, blocked %d of %d" % [
				role, _median(s.heights) * 100.0, head, s.off, s.head_cut, s.blocked, s.frames])
		lines.append("%s %.2f-%.2f s (%d frames): %s" % [shot.name, shot.from, shot.to, shot.frames,
			"frames nobody" if parts.is_empty() else "; ".join(parts)])
	return lines


## Everything that breaks the rules above, and every cut that swaps two
## people's sides of the screen (the 180-degree line crossed).
func problems() -> PackedStringArray:
	var found := PackedStringArray()
	var last_order := {}
	for shot: Dictionary in shots:
		var seconds: float = shot.frames / 30.0
		if seconds < MIN_SHOT_SECONDS:
			found.append("%s plays %.2f s (under %.1f s): a flash" % [shot.name, seconds, MIN_SHOT_SECONDS])
		for role: StringName in shot.roles:
			var s: Dictionary = shot.roles[role]
			var n: float = maxf(1.0, s.frames)
			if s.off / n > OFF_SHARE:
				found.append("%s: %s out of the picture %.0f%% of the shot" % [shot.name, role, 100.0 * s.off / n])
			if s.head_cut / n > HEAD_CUT_SHARE:
				found.append("%s: %s's head cut by the frame %.0f%% of the shot" % [shot.name, role, 100.0 * s.head_cut / n])
			elif s.head_n > 0 and s.head_y / s.head_n < HEADROOM:
				found.append("%s: %s's head against the top edge (no headroom)" % [shot.name, role])
			if not s.heights.is_empty() and _median(s.heights) < MIN_HEIGHT:
				found.append("%s: %s is %.0f%% of the picture's height (under %.0f%%)" % [
					shot.name, role, _median(s.heights) * 100.0, MIN_HEIGHT * 100.0])
			if s.blocked / n > BLOCKED_SHARE:
				found.append("%s: %s's face blocked by the set %.0f%% of the shot" % [shot.name, role, 100.0 * s.blocked / n])
		for pair: String in shot.order:
			var count: Array = shot.order[pair]
			var side: int = 0 if count[0] >= count[1] else 1
			if last_order.has(pair) and last_order[pair][1] != side:
				var who: PackedStringArray = pair.split("|")
				found.append("cut %s -> %s swaps %s and %s left-right (line crossed)" % [
					last_order[pair][0], shot.name, who[0], who[1]])
			last_order[pair] = [shot.name, side]
	return found


func _framed(rig: FramingRig) -> Array[StringName]:
	var roles: Array[StringName] = []
	if not rig.framed_roles.is_empty():
		roles.assign(rig.framed_roles)
		return roles
	for role: StringName in [rig.subject_role, rig.look_role]:
		if rig.subject_mark != &"" and role == rig.subject_role:
			continue
		if rig.look_mark != &"" and role == rig.look_role:
			continue
		if role != &"" and not roles.has(role):
			roles.append(role)
	return roles


## Whether the set stands between the lens and `point`. Units and stand-ins
## do not count: a person in front of a person is staging, not a rock.
func _blocked(camera: Camera3D, point: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, point)
	var exclude: Array[RID] = []
	for _try in 4:
		query.exclude = exclude
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			return false
		var collider: Object = hit.collider
		var node: Node = collider as Node
		var person := false
		while node != null:
			if node is Unit or node is StandIn or node is CharacterModel:
				person = true
				break
			node = node.get_parent()
		if not person:
			return true
		exclude.append(hit.rid)
	return false


func _bone(skeleton: Skeleton3D, bone: String) -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone(bone)).origin


func _median(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]
