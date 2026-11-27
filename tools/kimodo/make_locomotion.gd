extends SceneTree

# Generates the humanoid locomotion set: assets/locomotion_animations.tres,
# the clips, mounted on a body as "Locomotion", and data/locomotion/
# humanoid.tres, the LocomotionSet that says what each clip does with the
# ground.
#
#   godot --headless --path . -s res://tools/kimodo/make_locomotion.gd
#
# It rewrites the whole library and set. The game's idle, walk, run, run
# start and stops are not these takes' but tools/gait/author_gait.gd's, so
# run that (GAIT_LAND=1) after this.
#
# The takes are Kimodo's (tools/kimodo/takes/locomotion, the text and seed
# that made each beside it). Three are loops: an idle, a walk, a jog. The
# rest were made from a frame of one of those, by kimodo.cpp's --continue,
# which makes the source again exactly and goes on from it: so a walk stop's
# first frames ARE the walk's, a turn's the idle's.
#
# IN PLACE. A Kimodo take travels: there is no root bone, the hips go where
# the body goes. Each clip here is baked in place, frame by frame: the body
# is put back over a ground point that faces ahead (its root), and the root's
# own path is kept in the LocomotionClip for the game to move the unit by.
#
# WHAT THE ROOT IS. The hips, on the ground, facing where they face:
#   a loop (walk, jog)  goes straight and steady from where its first frame's
#                       hips stand to where its last frame's do, facing the
#                       way it goes, set across so the hips sway about it
#                       evenly. The unit moves at its speed.
#   the idle            stands still where the hips stand on average.
#   a turning loop      stands still, turning steadily.
#   anything else       follows the hips smoothed over about half a second
#                       (SIGMA), so a step's sway stays in the clip.
# A clip that starts on a frame of a loop has its root there made the
# loop's, and one that ends on a pose of a loop has its root there made
# whatever puts that pose where the loop puts it; each over FADE frames, so
# the handover shows no step. What those corrections came to is printed.
#
# Baked on the humanoid rig's skeleton (tools/rig); every humanoid model shares its rig.

const Retarget := preload("res://tools/kimodo/soma_retarget.gd")
const ClipScript := preload("res://systems/unit_system/locomotion_clip.gd")
const SetScript := preload("res://systems/unit_system/locomotion_set.gd")

const TAKES := "res://tools/kimodo/takes/locomotion/"
const MODEL := "res://tools/rig/humanoid_rig_model.tscn"
const LIBRARY_OUT := "res://assets/locomotion_animations.tres"
const SET_OUT := "res://data/locomotion/humanoid.tres"
const LIBRARY := "Locomotion"

const SIGMA := 12.0
const FADE := 15

# The loops: [take, first frame, last frame]. Each is one take's frames
# that come round to the same pose (the walk three gait cycles).
const IDLE := ["up_idle_a_1", 80, 231]
const WALK := ["up_walk_2", 17, 109]
const JOG := ["up_jog_2", 62, 87]
# The run, one stride. Its own take (not a --continue off the idle), so
# nothing hands to it on a frame: the jog's start and stops serve it and
# UnitLocomotion matches the legs at the handover.
const RUN := ["up_run_c_1", 68, 84]

# Stops: [clip, take, frame of the loop it starts on, idle frame its end shows].
const WALK_STOPS := [
	["walk_stop_l", "set_walkstop_a_3", 105, 108],
	["walk_stop_r", "set_walkstop_b_4", 90, 195],
	["walk_stop_l_contact", "set_walkstop_conl_14", 86, 100],
	["walk_stop_r_contact", "set_walkstop_conr_2", 100, 108],
	["walk_stop_l_passing", "set_walkstop_pasl_2", 79, 104],
	["walk_stop_r_passing", "set_walkstop_pasr_8", 94, 109],
]
const JOG_STOPS := [
	["jog_stop_a", "set_jogstop_a_10", 83, 193],
	["jog_stop_b", "set_jogstop_b_23", 71, 193],
]
# Turns in place, off idle frame 231 (the idle loop's end): [clip, take, idle
# frame its end shows]. The "135w" takes were asked for 135 and turn 180.
const TURNS := [
	["turn_l45", "set_turn_l45_5", 146],
	["turn_r45", "set_turn_r45_7", 145],
	["turn_l60", "set_turn_l60_6", 145],
	["turn_r60", "set_turn_r60_5", 146],
	["turn_l90", "set_turn_l90_1", 80],
	["turn_r90", "set_turn_r90_2", 101],
	["turn_l135", "set_turn_l135c_1", 216],
	["turn_r135", "set_turn_r135c_4", 209],
	["turn_l180", "set_turn_l135w_2", 94],
	["turn_r180", "set_turn_r135w_8", 117],
	["turn_l270", "set_turn_l270w_1", 193],
	["turn_r270", "set_turn_r270w_3", 209],
]
# Off the idle too, into the jog: [clip, take, jog frame its end shows].
const JOG_START := ["jog_start", "set_go_jog_8", 79]
# Turning loops: [side, take, frame the loop starts on, its last frame].
const TURN_LOOPS := [
	["l", "set_turnloopc_l_5", 322, 407],
	["r", "set_turnloopc_r_5", 321, 409],
]
const TURN_FROM := 231

const LEFT_FOOT := 24
const RIGHT_FOOT := 28

var _skeleton: Skeleton3D
var _fingers: Animation
var _scale: float
var _basis: Basis
var _library := AnimationLibrary.new()
var _takes := {}
# Each take's hips on the ground, every frame: Vector3(x, yaw, z), yaw unwrapped.
var _hips := {}


func _initialize() -> void:
	_bake.call_deferred()


func _bake() -> void:
	await process_frame
	var model: Node3D = (load(MODEL) as PackedScene).instantiate()
	root.add_child(model)
	_skeleton = model.find_child("GeneralSkeleton", true, false)
	var player: AnimationPlayer = model.find_children("*", "AnimationPlayer", true, false)[0]
	for n in player.get_animation_list():
		var low := String(n).to_lower()
		if low.contains("idle") and not low.contains("crouch"):
			_fingers = player.get_animation(n)
			break
	_basis = _skeleton.global_transform.basis
	var idle_take: Retarget = _take(IDLE[0])
	if idle_take == null:
		quit(1)
		return
	_scale = idle_take._leg(_skeleton) / (Retarget.OFFSETS[23].length() + Retarget.OFFSETS[24].length())
	print("skeleton in the model: %s, SOMA to ours x%.4f" % [_basis, _scale])

	var set: Resource = SetScript.new()
	var idle_roots: Dictionary = _idle_roots()
	var walk_roots: Dictionary = _straight_roots(WALK)
	var jog_roots: Dictionary = _straight_roots(JOG)
	print("\nLOOPS")
	set.idle = _loop("idle", IDLE, idle_roots)
	set.walk = _loop("walk", WALK, walk_roots)
	set.jog = _loop("jog", JOG, jog_roots)
	set.run = _loop("run", RUN, _straight_roots(RUN))
	_contacts("walk", WALK)
	_contacts("jog", JOG)
	_contacts("run", RUN)

	print("\nSTOPS")
	var walk_stops: Array[Resource] = []
	for s: Array in WALK_STOPS:
		walk_stops.append(_clip(s[0], s[1], s[2], -1, WALK, walk_roots, IDLE, idle_roots, s[3]))
	set.walk_stops.assign(walk_stops)
	var jog_stops: Array[Resource] = []
	for s: Array in JOG_STOPS:
		jog_stops.append(_clip(s[0], s[1], s[2], -1, JOG, jog_roots, IDLE, idle_roots, s[3]))
	set.jog_stops.assign(jog_stops)

	print("\nTURNS")
	var turns: Array[Resource] = []
	for t: Array in TURNS:
		turns.append(_clip(t[0], t[1], TURN_FROM, -1, IDLE, idle_roots, IDLE, idle_roots, t[2]))
	set.turns.assign(turns)
	for l: Array in TURN_LOOPS:
		var spec := [l[1], l[2], l[3]]
		var loop_roots: Dictionary = _turning_roots(spec)
		var into: Resource = _clip("turn_loop_%s_in" % l[0], l[1], TURN_FROM, l[2], IDLE, idle_roots,
			spec, loop_roots, l[2])
		var loop: Resource = _loop("turn_loop_%s" % l[0], spec, loop_roots)
		if l[0] == "l":
			set.turn_loop_left_in = into
			set.turn_loop_left = loop
		else:
			set.turn_loop_right_in = into
			set.turn_loop_right = loop

	print("\nSTART")
	set.jog_start = _clip(JOG_START[0], JOG_START[1], TURN_FROM, -1, IDLE, idle_roots, JOG, jog_roots, JOG_START[2])

	var err: Error = ResourceSaver.save(_library, LIBRARY_OUT)
	print("\n%s: %s" % [LIBRARY_OUT, error_string(err)])
	if err == OK:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SET_OUT.get_base_dir()))
		err = ResourceSaver.save(set, SET_OUT)
		print("%s: %s" % [SET_OUT, error_string(err)])
	quit(0 if err == OK else 1)


func _take(name: String) -> Retarget:
	if _takes.has(name):
		return _takes[name]
	var take := Retarget.new()
	if not take.read(TAKES + name):
		push_error("take missing: %s" % name)
		return null
	var hips := PackedVector3Array()
	var last_yaw := 0.0
	for f in take.frames:
		var h: Transform3D = take.world(f)[0]
		var yaw: float = atan2(h.basis.z.x, h.basis.z.z)
		if f > 0:
			yaw = last_yaw + angle_difference(last_yaw, yaw)
		last_yaw = yaw
		hips.append(Vector3(h.origin.x, yaw, h.origin.z))
	_takes[name] = take
	_hips[name] = hips
	return take


# --- roots: Vector3(x, yaw, z) per frame, keyed by frame -------------------

func _idle_roots() -> Dictionary:
	_take(IDLE[0])
	var hips: PackedVector3Array = _hips[IDLE[0]]
	var mean := Vector3.ZERO
	for f in range(IDLE[1], IDLE[2] + 1):
		mean += hips[f]
	mean /= IDLE[2] - IDLE[1] + 1
	var roots := {}
	for f in range(IDLE[1], IDLE[2] + 1):
		roots[f] = mean
	return roots


func _straight_roots(spec: Array) -> Dictionary:
	_take(spec[0])
	var hips: PackedVector3Array = _hips[spec[0]]
	var a: int = spec[1]
	var b: int = spec[2]
	var span := Vector2(hips[b].x - hips[a].x, hips[b].z - hips[a].z)
	var yaw: float = atan2(span.x, span.y)
	var off := Vector2.ZERO
	var mean_yaw := 0.0
	for f in range(a, b + 1):
		var w: float = float(f - a) / (b - a)
		off += Vector2(hips[f].x - (hips[a].x + span.x * w), hips[f].z - (hips[a].z + span.y * w))
		mean_yaw += hips[f].y
	off /= b - a + 1
	mean_yaw /= b - a + 1
	# The hips' own facing about the way the loop goes: kept in the clip.
	print("  %s: the hips face %.1f deg off the way they go, on average" % [spec[0], rad_to_deg(angle_difference(yaw, mean_yaw))])
	# Keep the facing in the same turn as the hips' own, so a clip that starts on this loop
	# and follows the hips needs no whole turn to agree.
	yaw = mean_yaw + angle_difference(mean_yaw, yaw)
	var roots := {}
	for f in range(a, b + 1):
		var w: float = float(f - a) / (b - a)
		roots[f] = Vector3(hips[a].x + span.x * w + off.x, yaw, hips[a].z + span.y * w + off.y)
	return roots


func _turning_roots(spec: Array) -> Dictionary:
	_take(spec[0])
	var hips: PackedVector3Array = _hips[spec[0]]
	var a: int = spec[1]
	var b: int = spec[2]
	var at := Vector2.ZERO
	var off := 0.0
	for f in range(a, b + 1):
		at += Vector2(hips[f].x, hips[f].z)
		off += hips[f].y - lerpf(hips[a].y, hips[b].y, float(f - a) / (b - a))
	at /= b - a + 1
	off /= b - a + 1
	var roots := {}
	for f in range(a, b + 1):
		roots[f] = Vector3(at.x, lerpf(hips[a].y, hips[b].y, float(f - a) / (b - a)) + off, at.y)
	return roots


# The hips smoothed over the whole take (so the clip's edges are not its
# take's). Past the take's ends the hips go on as they were going (each end
# mirrored through itself): held still instead, a take that ends running
# would have its root fall half a metre behind the body.
func _smoothed(name: String) -> PackedVector3Array:
	var hips: PackedVector3Array = _hips[name]
	var reach: int = ceili(SIGMA * 3.0)
	var weights := PackedFloat32Array()
	for k in range(-reach, reach + 1):
		weights.append(exp(-0.5 * (k / SIGMA) * (k / SIGMA)))
	var out := PackedVector3Array()
	out.resize(hips.size())
	for f in hips.size():
		var sum := Vector3.ZERO
		var total := 0.0
		for k in range(-reach, reach + 1):
			var w: float = weights[k + reach]
			var at: int = f + k
			var last: int = hips.size() - 1
			var p: Vector3
			if at < 0:
				p = hips[0] * 2.0 - hips[mini(-at, last)]
			elif at > last:
				p = hips[last] * 2.0 - hips[maxi(2 * last - at, 0)]
			else:
				p = hips[at]
			sum += p * w
			total += w
		out[f] = sum / total
	return out


# --- clips -----------------------------------------------------------------

func _loop(clip_name: String, spec: Array, roots: Dictionary) -> Resource:
	var take: Retarget = _take(spec[0])
	var a: int = spec[1]
	var b: int = spec[2]
	var path: Array[Vector3] = []
	for f in range(a, b + 1):
		path.append(roots[f])
	var clip: Resource = _make(clip_name, take, a, b, path, true)
	var seam: float = _pose_gap(take, a, roots[a], take, b, roots[b])
	clip.strides = _strides(take, a, b, roots)
	print("  %-20s %5.2f s  %5.2f m %6.1f deg  %5.2f m/s  seam %4.1f cm  %d strides" % [clip_name, clip.length,
		clip.travel, rad_to_deg(clip.turn), clip.speed, seam, clip.strides])
	return clip


## How many times a loop's frames a..b repeat their own pose: the most n for
## which every frame looks, within STRIDE_GAP on average, like the one a
## 1/n of the cycle on.
const STRIDE_GAP := 8.0

func _strides(take: Retarget, a: int, b: int, roots: Dictionary) -> int:
	var frames: int = b - a
	for n in [4, 3, 2]:
		var shift: int = roundi(float(frames) / n)
		if shift < 4:
			continue
		var gap := 0.0
		var count := 0
		for f in range(a, b - shift, 3):
			gap += _pose_gap(take, f, roots[f], take, f + shift, roots[f + shift])
			count += 1
		if count > 0 and gap / count <= STRIDE_GAP:
			return n
	return 1


## A clip off a loop, from frame `from` of its take to `to` (-1 = its end):
## its root starts as `source`'s does on `from` and ends where `dest`'s puts
## the pose of `dest` frame `dest_frame`.
func _clip(clip_name: String, take_name: String, from: int, to: int, source: Array, source_roots: Dictionary,
		dest: Array, dest_roots: Dictionary, dest_frame: int) -> Resource:
	var take: Retarget = _take(take_name)
	if to < 0:
		to = take.frames - 1
	var hips: PackedVector3Array = _hips[take_name]
	var smooth: PackedVector3Array = _smoothed(take_name)
	var path: Array[Vector3] = []
	for f in range(from, to + 1):
		path.append(smooth[f])
	# On: agree with the loop it starts from.
	var start: Vector3 = source_roots[from]
	var d_in := Vector3(start.x - path[0].x, angle_difference(path[0].y, start.y), start.z - path[0].z)
	for i in path.size():
		path[i] += d_in * (1.0 - smoothstep(0.0, FADE, i))
	# Off: stand where the loop it hands to would, for that loop's pose.
	_take(dest[0])
	var here: Transform3D = _xf(hips[to])
	var there: Transform3D = _xf(_hips[dest[0]][dest_frame]).affine_inverse() * _xf(dest_roots[dest_frame])
	var want: Vector3 = _pose_of(here * there)
	var end: Vector3 = path[path.size() - 1]
	var d_out := Vector3(want.x - end.x, angle_difference(end.y, want.y), want.z - end.z)
	var n: int = path.size() - 1
	for i in path.size():
		path[i] += d_out * smoothstep(0.0, FADE, i - (n - FADE))
	var clip: Resource = _make(clip_name, take, from, to, path, false)
	clip.enters_at = (from - source[1]) / Retarget.FPS
	clip.leaves_at = (dest_frame - dest[1]) / Retarget.FPS
	var gap: float = _pose_gap(take, to, path[n], _take(dest[0]), dest_frame, dest_roots[dest_frame])
	print("  %-20s %5.2f s  %5.2f m %6.1f deg  on %4.1f cm %4.1f deg  off %4.1f cm %4.1f deg  end pose %4.1f cm" % [
		clip_name, clip.length, clip.travel, rad_to_deg(clip.turn),
		Vector2(d_in.x, d_in.z).length() * _scale * 100.0, rad_to_deg(d_in.y),
		Vector2(d_out.x, d_out.z).length() * _scale * 100.0, rad_to_deg(d_out.y), gap])
	return clip


## Bakes frames `a` to `b` of `take` in place over `path` (its roots) and
## makes the LocomotionClip for them.
func _make(clip_name: String, take: Retarget, a: int, b: int, path: Array[Vector3], loops: bool) -> Resource:
	var placements: Array[Transform3D] = []
	for p in path:
		placements.append(_xf(p).affine_inverse())
	var anim: Animation = take.animation(_skeleton, a, b, Transform3D.IDENTITY, _fingers, 0.0, placements)
	if loops:
		anim.loop_mode = Animation.LOOP_LINEAR
	_library.add_animation(StringName(clip_name), anim)

	var clip: Resource = ClipScript.new()
	clip.clip = StringName("%s/%s" % [LIBRARY, clip_name])
	clip.loops = loops
	clip.length = anim.length
	var first: Transform3D = _xf(path[0]).affine_inverse()
	for p in path:
		clip.root_positions.append(_basis * ((first * _xf(p)).origin * _scale))
		clip.root_yaws.append(p.y - path[0].y)
	var last: int = path.size() - 1
	clip.travel = Vector2(clip.root_positions[last].x, clip.root_positions[last].z).length()
	clip.turn = clip.root_yaws[last]
	if loops and clip.length > 0.0:
		clip.speed = clip.travel / clip.length
	return clip


# --- measures --------------------------------------------------------------

## How far apart two frames' poses are, each over its own root: the most any
## joint is out, centimetres on our body.
func _pose_gap(take_a: Retarget, fa: int, root_a: Vector3, take_b: Retarget, fb: int, root_b: Vector3) -> float:
	var ja: Array[Transform3D] = take_a.world(fa)
	var jb: Array[Transform3D] = take_b.world(fb)
	var pa: Transform3D = _xf(root_a).affine_inverse()
	var pb: Transform3D = _xf(root_b).affine_inverse()
	var most := 0.0
	for j in ja.size():
		most = maxf(most, (pa * ja[j].origin).distance_to(pb * jb[j].origin))
	return most * _scale * 100.0


## Prints the frames of a loop each foot is planted on.
func _contacts(loop_name: String, spec: Array) -> void:
	var take: Retarget = _take(spec[0])
	for foot: int in [LEFT_FOOT, RIGHT_FOOT]:
		var low := INF
		for f in range(spec[1], spec[2] + 1):
			low = minf(low, take.world(f)[foot].origin.y)
		var runs: Array[String] = []
		var run_from := -1
		for f in range(spec[1], spec[2] + 1):
			var at: Vector3 = take.world(f)[foot].origin
			var next: Vector3 = take.world(mini(f + 1, take.frames - 1))[foot].origin
			var still: bool = Vector2(next.x - at.x, next.z - at.z).length() * Retarget.FPS < 0.4
			var down: bool = at.y < low + 0.03 and still
			if down and run_from < 0:
				run_from = f
			if (not down or f == spec[2]) and run_from >= 0:
				runs.append("%d-%d" % [run_from, f if down else f - 1])
				run_from = -1
		print("  %s %s foot planted on frames %s" % [loop_name, "left" if foot == LEFT_FOOT else "right", ", ".join(runs)])


func _xf(p: Vector3) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, p.y), Vector3(p.x, 0.0, p.z))


func _pose_of(t: Transform3D) -> Vector3:
	return Vector3(t.origin.x, atan2(t.basis.z.x, t.basis.z.z), t.origin.z)
