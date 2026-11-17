extends SceneTree

# Lands the Mixamo clips (tools/locomotion/takes/mixamo.glb, made by
# tools/locomotion/mixamo_retarget.py) in the humanoid locomotion set: the
# idle (Breathing Idle), walk, run, turns in place, walk start and the walk
# and run stops in assets/locomotion_animations.tres and
# data/locomotion/humanoid.tres. The stops replace author_gait.gd's (whose
# clips are taken out of the library); the run start, jog and turning loops
# stay author_gait.gd's and make_locomotion.gd's.
#
#   godot --headless --path . -s res://tools/locomotion/land_mixamo.gd
#
# Run it last: after tools/kimodo/make_locomotion.gd (which rewrites the
# whole library and set) and tools/gait/author_gait.gd (GAIT_LAND=1).
#
# IN PLACE, like every clip in the set (no root motion): the takes travel and
# turn, and each is baked back over a ground point that faces ahead, its root,
# whose path is kept in the LocomotionClip for the game to move the unit by.
# The root is the hips on the ground, facing where they face (their turn from
# rest):
#   the idle         stands still where the hips stand on average.
#   the walk, run    go straight and steady from where the first frame's hips
#                    stand to where the last's do (a Mixamo loop's last frame
#                    is its first again, a cycle on), set across so the hips
#                    sway about it evenly, facing the hips' mean.
#   a turn, the walk start, a stop
#                    follows the hips smoothed over about half a second.
#
# The stops and turns hand to the idle on a pose of it
# (LocomotionClip.leaves_at): the idle's frame nearest the clip's last pose. A
# turn also enters off the idle's frame nearest its first (enters_at).
#
# The clips were baked on the proof hero's own skeleton; this checks the
# imported one still is it, to the millimetre.

const ClipScript := preload("res://systems/unit_system/locomotion_clip.gd")

const TAKES := "res://tools/locomotion/takes/mixamo.glb"
const MODEL := "res://scenes/character_models/proof_hero_model.tscn"
const LIBRARY_PATH := "res://assets/locomotion_animations.tres"
const SET_PATH := "res://data/locomotion/humanoid.tres"
const LIBRARY := "Locomotion"
const FPS := 30.0
const SIGMA := 12.0
const TURNS := ["turn_l90", "turn_r90", "turn_l180", "turn_r180"]
# Each stop and its mirror (off the other foot).
const WALK_STOPS := ["walk_stop_a", "walk_stop_b"]
const RUN_STOPS := ["run_stop_a", "run_stop_b"]
# author_gait.gd's stops, which the Mixamo ones replace.
const OLD_STOPS := ["walk_stop_1", "walk_stop_2", "walk_stop_3", "walk_stop_4", "walk_stop_5", "walk_stop_6",
	"run_stop_1", "run_stop_2", "run_stop_3", "run_stop_4"]
# The Kimodo turns the Mixamo four replace.
const OLD_TURNS := ["turn_l45", "turn_r45", "turn_l60", "turn_r60", "turn_l135", "turn_r135",
	"turn_l270", "turn_r270"]
# Joints a pose is compared by, each from the skeleton's root, in place.
const POSE_BONES := ["Hips", "Head", "LeftHand", "RightHand", "LeftFoot", "RightFoot", "LeftToes", "RightToes",
	"LeftLowerLeg", "RightLowerLeg"]

var _skeleton: Skeleton3D      # the takes'
var _player: AnimationPlayer   # the takes'
var _hips: int
var _basis: Basis


func _initialize() -> void:
	_land.call_deferred()


func _land() -> void:
	await process_frame
	var model: Node3D = (load(MODEL) as PackedScene).instantiate()
	root.add_child(model)
	var hero: Skeleton3D = model.find_child("GeneralSkeleton", true, false)
	_basis = hero.global_transform.basis
	var takes: Node3D = (load(TAKES) as PackedScene).instantiate()
	root.add_child(takes)
	_skeleton = takes.find_child("GeneralSkeleton", true, false)
	_player = takes.find_children("*", "AnimationPlayer", true, false)[0]
	_hips = _skeleton.find_bone("Hips")
	if not _same_rest(hero):
		quit(1)
		return

	var library: AnimationLibrary = load(LIBRARY_PATH)
	var set: Resource = load(SET_PATH)
	print("\nLOOPS")
	set.idle = _bake(library, "idle", "idle")
	set.walk = _bake(library, "walk", "straight")
	set.run = _bake(library, "run", "straight")
	print("\nTURNS")
	for n: String in OLD_TURNS:
		if library.has_animation(n):
			library.remove_animation(n)
	var turns: Array[Resource] = []
	for n: String in TURNS:
		turns.append(_bake(library, n, "smoothed"))
	set.turns.assign(turns)
	print("\nSTART, STOPS")
	set.walk_start = _bake(library, "walk_start", "smoothed")
	for n: String in OLD_STOPS:
		if library.has_animation(n):
			library.remove_animation(n)
	var walk_stops: Array[Resource] = []
	for n: String in WALK_STOPS:
		walk_stops.append(_bake(library, n, "smoothed"))
	set.walk_stops.assign(walk_stops)
	var run_stops: Array[Resource] = []
	for n: String in RUN_STOPS:
		run_stops.append(_bake(library, n, "smoothed"))
	set.jog_stops.assign(run_stops)

	print("\nONTO THE IDLE")
	var hero_player: AnimationPlayer = model.find_children("*", "AnimationPlayer", true, false)[0]
	if hero_player.has_animation_library(LIBRARY):
		hero_player.remove_animation_library(LIBRARY)
	hero_player.add_animation_library(LIBRARY, library)
	var idle_poses: Array[PackedVector3Array] = []
	for f in roundi(set.idle.length * FPS) + 1:
		idle_poses.append(_pose(hero_player, hero, set.idle.clip, f / FPS))
	for clip: Resource in set.walk_stops + set.jog_stops + set.turns:
		_reland(clip, idle_poses, hero_player, hero, clip in set.turns)

	var err: Error = ResourceSaver.save(library, LIBRARY_PATH)
	print("\n%s: %s" % [LIBRARY_PATH, error_string(err)])
	if err == OK:
		err = ResourceSaver.save(set, SET_PATH)
		print("%s: %s" % [SET_PATH, error_string(err)])
	quit(0 if err == OK else 1)


func _same_rest(hero: Skeleton3D) -> bool:
	var worst := 0.0
	for i in _skeleton.get_bone_count():
		var j: int = hero.find_bone(_skeleton.get_bone_name(i))
		if j < 0:
			push_error("the hero has no bone %s" % _skeleton.get_bone_name(i))
			return false
		var a: Transform3D = _skeleton.get_bone_global_rest(i)
		var b: Transform3D = hero.get_bone_global_rest(j)
		worst = maxf(worst, a.origin.distance_to(b.origin))
		for k in 3:
			worst = maxf(worst, (a.basis[k] - b.basis[k]).length() * 0.1)
	print("the takes' skeleton is the hero's to %.2f mm" % (worst * 1000.0))
	if worst > 0.001:
		push_error("the takes are not on the hero's skeleton")
		return false
	return true


## Every frame's Hips and root bone, in skeleton space.
func _sample(anim: Animation) -> Array:
	var n: int = roundi(anim.length * FPS) + 1
	var hips: Array[Transform3D] = []
	var roots: Array[Transform3D] = []
	var name: StringName = _player.find_animation(anim)
	_player.play(name)
	for f in n:
		_player.seek(f / FPS, true)
		hips.append(_skeleton.get_bone_global_pose(_hips))
		var p: int = _skeleton.get_bone_parent(_hips)
		roots.append(_skeleton.get_bone_global_pose(p) if p >= 0 else Transform3D.IDENTITY)
	_player.stop()
	return [hips, roots]


## Vector3(x, yaw, z) per frame: the hips on the ground, facing their turn from rest, yaw unwrapped.
func _ground(hips: Array[Transform3D]) -> PackedVector3Array:
	var rest: Basis = _skeleton.get_bone_global_rest(_hips).basis.orthonormalized()
	var out := PackedVector3Array()
	var last := 0.0
	for f in hips.size():
		var b: Basis = hips[f].basis.orthonormalized() * rest.inverse()
		var yaw: float = atan2(b.z.x, b.z.z)
		if f > 0:
			yaw = last + angle_difference(last, yaw)
		last = yaw
		out.append(Vector3(hips[f].origin.x, yaw, hips[f].origin.z))
	return out


func _roots(g: PackedVector3Array, how: String) -> PackedVector3Array:
	var n: int = g.size()
	var out := PackedVector3Array()
	if how == "idle":
		var mean := Vector3.ZERO
		for p in g:
			mean += p
		mean /= n
		for p in g:
			out.append(mean)
	elif how == "straight":
		var a: Vector3 = g[0]
		var span := Vector2(g[n - 1].x - a.x, g[n - 1].z - a.z)
		var off := Vector2.ZERO
		var yaw := 0.0
		for f in n:
			var w: float = float(f) / (n - 1)
			off += Vector2(g[f].x - (a.x + span.x * w), g[f].z - (a.z + span.y * w))
			yaw += g[f].y
		off /= n
		yaw /= n
		var goes: float = atan2(span.x, span.y)
		print("  the hips face %.1f deg off the way they go, on average" % rad_to_deg(angle_difference(goes, yaw)))
		for f in n:
			var w: float = float(f) / (n - 1)
			out.append(Vector3(a.x + span.x * w + off.x, yaw, a.z + span.y * w + off.y))
	else:
		var reach: int = ceili(SIGMA * 3.0)
		for f in n:
			var sum := Vector3.ZERO
			var total := 0.0
			for k in range(-reach, reach + 1):
				var w: float = exp(-0.5 * (k / SIGMA) * (k / SIGMA))
				var at: int = f + k
				var p: Vector3
				if at < 0:
					p = g[0] * 2.0 - g[mini(-at, n - 1)]
				elif at > n - 1:
					p = g[n - 1] * 2.0 - g[maxi(2 * (n - 1) - at, 0)]
				else:
					p = g[at]
				sum += p * w
				total += w
			out.append(sum / total)
	return out


func _xf(p: Vector3) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, p.y), Vector3(p.x, 0.0, p.z))


## Take `name` baked in place over its roots, into the library, and its LocomotionClip.
func _bake(library: AnimationLibrary, name: String, how: String) -> Resource:
	var src: Animation = _player.get_animation(name)
	var s: Array = _sample(src)
	var hips: Array[Transform3D] = s[0]
	var parents: Array[Transform3D] = s[1]
	var path: PackedVector3Array = _roots(_ground(hips), how)
	var loops: bool = how != "smoothed"

	var anim := Animation.new()
	anim.length = src.length
	anim.step = 1.0 / FPS
	anim.loop_mode = Animation.LOOP_LINEAR if loops else Animation.LOOP_NONE
	for t in src.get_track_count():
		var bone: String = String(src.track_get_path(t).get_concatenated_subnames())
		var kind: Animation.TrackType = src.track_get_type(t)
		if bone == "" or bone == "Root" or _skeleton.find_bone(bone) < 0:
			continue
		if bone == "Hips" and (kind == Animation.TYPE_POSITION_3D or kind == Animation.TYPE_ROTATION_3D):
			continue
		var copy: int = anim.add_track(kind)
		anim.track_set_path(copy, NodePath("%%GeneralSkeleton:%s" % bone))
		anim.track_set_interpolation_type(copy, src.track_get_interpolation_type(t))
		for k in src.track_get_key_count(t):
			anim.track_insert_key(copy, src.track_get_key_time(t, k), src.track_get_key_value(t, k))
	var pos: int = anim.add_track(Animation.TYPE_POSITION_3D)
	var rot: int = anim.add_track(Animation.TYPE_ROTATION_3D)
	for tr in [pos, rot]:
		anim.track_set_path(tr, NodePath("%GeneralSkeleton:Hips"))
	for f in hips.size():
		var local: Transform3D = parents[f].affine_inverse() * _xf(path[f]).affine_inverse() * hips[f]
		# A Hips position track is kept over the skeleton's motion scale (its hip height).
		anim.position_track_insert_key(pos, f / FPS, local.origin / _skeleton.motion_scale)
		anim.rotation_track_insert_key(rot, f / FPS, local.basis.orthonormalized().get_rotation_quaternion())
	if library.has_animation(name):
		library.remove_animation(name)
	library.add_animation(StringName(name), anim)

	var clip: Resource = ClipScript.new()
	clip.clip = StringName("%s/%s" % [LIBRARY, name])
	clip.loops = loops
	clip.length = anim.length
	var first: Transform3D = _xf(path[0]).affine_inverse()
	for p in path:
		clip.root_positions.append(_basis * (first * _xf(p)).origin)
		clip.root_yaws.append(p.y - path[0].y)
	var last: int = path.size() - 1
	clip.travel = Vector2(clip.root_positions[last].x, clip.root_positions[last].z).length()
	clip.turn = clip.root_yaws[last]
	if loops and clip.length > 0.0:
		clip.speed = clip.travel / clip.length
	print("  %-10s %5.2f s  %5.2f m %7.1f deg  %5.2f m/s  ends at %s" % [name, clip.length, clip.travel,
		rad_to_deg(clip.turn), clip.speed, clip.root_positions[last]])
	return clip


## The pose on `player`'s body at `seconds` into `clip`: POSE_BONES from the skeleton's root.
func _pose(player: AnimationPlayer, skeleton: Skeleton3D, clip: StringName, seconds: float) -> PackedVector3Array:
	player.play(clip)
	player.seek(seconds, true)
	var out := PackedVector3Array()
	for b: String in POSE_BONES:
		out.append(skeleton.get_bone_global_pose(skeleton.find_bone(b)).origin)
	return out


## A clip's leaves_at set to the idle frame whose pose its last frame is
## nearest; a turn's enters_at too, to the one nearest its first.
func _reland(clip: Resource, idle_poses: Array[PackedVector3Array], player: AnimationPlayer,
		skeleton: Skeleton3D, enters: bool) -> void:
	var out: Array = _nearest(idle_poses, _pose(player, skeleton, clip.clip, clip.length))
	clip.leaves_at = out[0]
	var said := "  %-22s leaves at %5.2f s of the idle, %4.1f cm off" % [clip.clip, out[0], out[1] * 100.0]
	clip.enters_at = -1.0
	if enters:
		var into: Array = _nearest(idle_poses, _pose(player, skeleton, clip.clip, 0.0))
		clip.enters_at = into[0]
		said += "; enters at %5.2f s, %4.1f cm off" % [into[0], into[1] * 100.0]
	print(said)


## [seconds, metres]: the idle frame nearest `pose`, and how far its worst joint is.
func _nearest(idle_poses: Array[PackedVector3Array], pose: PackedVector3Array) -> Array:
	var best := 0.0
	var best_gap := INF
	for f in idle_poses.size():
		var gap := 0.0
		for i in pose.size():
			gap = maxf(gap, idle_poses[f][i].distance_to(pose[i]))
		if gap < best_gap:
			best_gap = gap
			best = f / FPS
	return [best, best_gap]
