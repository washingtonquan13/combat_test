extends SceneTree

# Writes a humanoid's locomotion from nothing but the body's rest pose: no
# take, no base clip. Run it:
#   godot --headless --path . -s res://tools/gait/author_gait.gd
# It writes a trial library and set under tools/_probe/gait for review.
# With GAIT_LAND=1 it also writes them into the game's own library and set
# (assets/locomotion_animations.tres, data/locomotion/humanoid.tres),
# replacing the idle, walk and run, the start and the stops, and leaving the
# jog, the turns and the turning loops as tools/kimodo/make_locomotion.gd
# made them. Run it again after make_locomotion.gd, which rewrites both, and
# run tools/locomotion/land_mixamo.gd after it: Mixamo's idle, walk, run and
# turns replace this one's idle, walk and run.
#
# The feet come first. A foot on the ground is pinned to it and carried back
# at exactly the speed the unit moves, rolling heel -> flat -> ball, so
# nothing slides by construction. A foot in the air follows one smooth path
# that leaves and meets the ground at the ground's own speed. The pelvis
# rides a curve over the feet, the legs are solved to reach them, and the
# spine, head and arms are curves of the same stride phase, each a little
# late on the one below it.
#
# Every clip is a function from time to one "rig state" (where the pelvis
# and feet are, how the spine, head and arms are turned), and states mix:
# the start is the idle mixing into the run while one foot stays where it
# stood; a stop is the loop mixing into the idle while each foot takes one
# last step to where the idle has it.
#
# Before anything is looked at, each clip is played back on the real
# skeleton and measured: foot slide over the ground, ground clearance, how
# near a leg comes to locking, and the largest jump any bone makes.

const MODEL := "res://tools/rig/humanoid_rig_model.tscn"
const TRIAL_LIBRARY := "res://tools/_probe/gait/trial_library.tres"
const TRIAL_SET := "res://tools/_probe/gait/trial_set.tres"
const GAME_LIBRARY := "res://assets/locomotion_animations.tres"
const GAME_SET := "res://data/locomotion/humanoid.tres"
const ClipScript := preload("res://systems/unit_system/locomotion_clip.gd")
const SetScript := preload("res://systems/unit_system/locomotion_set.gd")
# Clips of the Kimodo set these replace.
const RETIRED: Array[String] = ["jog_start", "jog_stop_a", "jog_stop_b", "walk_stop_l", "walk_stop_r",
		"walk_stop_l_contact", "walk_stop_r_contact", "walk_stop_l_passing", "walk_stop_r_passing"]

const FPS := 30.0
# Keys are written twice as often as the game's 30: a planted foot is held
# by three turning bones, and between sparse keys it drifts.
const KEYS_PER_FRAME := 2

# The sole under the ankle, metres, from the rest pose: where the heel and
# the ball of the foot meet the ground, and the tip of the toes.
const HEEL := Vector3(0.0, -0.078, -0.065)
const BALL := Vector3(0.0, -0.078, 0.138)
const TIP := Vector3(0.0, -0.078, 0.245)
const ANKLE_Y := 0.078

# The idle: seconds long, and where its feet stand.
const IDLE_LENGTH := 8.0
const IDLE_X := 0.115
const IDLE_Z := 0.015
const IDLE_YAW := 9.0

# What the game does with the clips (UnitLocomotion): seconds to top speed,
# metres a stop takes, and the share of a stop's travel at which it has
# arrived.
const RUN_ACCEL_TIME := 0.3
const RUN_STOP_DISTANCE := 1.1
const WALK_STOP_DISTANCE := 0.45
const ARRIVED := 0.97

# Angles in degrees, lengths in metres, times as a share of the stride.
# Phase 0 is the left foot's touchdown; the right foot's is half a stride on.
const RUN := {
	"name": "run",
	"speed": 4.6,
	"frames": 20,
	"duty": 0.26,           # share of the stride a foot is down
	"touch_z": 0.25,        # the flat foot's ankle ahead of the root at touchdown
	"heel_strike": 6.0,     # toes up at touchdown
	"flat_by": 0.14,        # share of stance by which the foot is flat
	"heel_off": 0.33,       # share of stance at which the heel starts to lift
	"toe_off": 58.0,        # heel up as the foot leaves
	"step_x": 0.055,        # each foot's track off the midline
	"swing_x": 0.035,       # how much wider the foot passes in the air
	"toe_out": 6.0,
	# The ankle through the air: [share of swing, z, y].
	"swing": [[0.20, -0.53, 0.38], [0.40, -0.40, 0.48], [0.58, -0.19, 0.40], [0.74, 0.09, 0.30], [0.88, 0.30, 0.19]],
	# The ankle's own bend through the air (toes pointed = plus): [share, degrees].
	"swing_ankle": [[0.22, 20.0], [0.5, 2.0], [0.75, -14.0], [0.92, -10.0]],
	"hips_y": -0.060,       # the pelvis' mean height off rest
	"bob": 0.036,           # and how far it rises and falls about that
	"hips_z": -0.01,
	"surge": 0.008,         # the pelvis slows on landing, catches up on the push
	"sway": 0.010,          # toward the foot that is down
	"pelvis_pitch": 9.0, "pelvis_nod": 1.5,
	"pelvis_yaw": 6.0, "pelvis_roll": 4.0,
	"chest_pitch": 20.0, "chest_nod": 2.0,
	"chest_yaw": 10.0, "chest_roll": 2.0,
	"spine_late": 0.03,     # how late each stage up the spine is
	"head_pitch": 4.0, "head_yaw": 0.25,
	"arm_swing": 36.0, "arm_back": -8.0, "arm_out": 11.0, "arm_flare": 4.0,
	"arm_in": 18.0, "arm_cross": 12.0,
	"elbow": 88.0, "elbow_pump": 14.0, "elbow_bounce": 4.0, "arm_late": 0.035,
	"clavicle": 0.12,
	# The stop off it. The first foot to land lands `stop_reach` ahead of the
	# root; a foot already in the air may take `stop_hurry` of the time it
	# had left; one still down needs `stop_swing` seconds in the air. The
	# other foot lifts `stop_hold` after that landing at the latest and
	# takes `stop_close` to come up beside it.
	"stop_reach": 0.30, "stop_hurry": 0.7, "stop_swing": 0.2, "stop_hold": 0.06, "stop_close": 0.34,
	"stop_heel": 12.0, "stop_lift": 0.10, "brake": 1.0,
}

const WALK := {
	"name": "walk",
	"speed": 1.84,
	"frames": 26,
	"duty": 0.60,
	"touch_z": 0.37,
	"heel_strike": 18.0,
	"flat_by": 0.16,
	"heel_off": 0.50,
	"toe_off": 52.0,
	"step_x": 0.075,
	"swing_x": 0.010,
	"toe_out": 7.0,
	"swing": [[0.2, -0.36, 0.25], [0.36, -0.18, 0.22], [0.55, 0.04, 0.165], [0.78, 0.27, 0.125]],
	"swing_ankle": [[0.25, 2.0], [0.5, -10.0], [0.8, -8.0]],
	"hips_y": -0.036,
	"bob": 0.018,
	"bob_at": 0.24,         # highest over the planted foot, not in the air
	"hips_z": 0.0,
	"surge": 0.004,
	"sway": 0.022,
	"pelvis_pitch": 3.0, "pelvis_nod": 0.5,
	"pelvis_yaw": 8.0, "pelvis_roll": 3.5,
	"yaw_at": 0.5,          # a hip is furthest back as the other foot lands
	"chest_pitch": 5.0, "chest_nod": 0.6,
	"chest_yaw": 5.0, "chest_roll": 1.5,
	"spine_late": 0.03,
	"head_pitch": 1.0, "head_yaw": 0.3,
	"arm_swing": 20.0, "arm_back": 2.0, "arm_out": 7.0, "arm_flare": 1.0,
	"arm_in": 20.0, "arm_cross": 6.0,
	"elbow": 22.0, "elbow_pump": 10.0, "elbow_bounce": 1.0, "arm_late": 0.02,
	"arm_at": 0.52,         # an arm is furthest forward as the other foot lands
	"clavicle": 0.10,
	"stop_reach": 0.20, "stop_hurry": 0.7, "stop_swing": 0.30, "stop_hold": 0.12, "stop_close": 0.30,
	"stop_heel": 10.0, "stop_lift": 0.05, "brake": 0.35,
}

var _sk: Skeleton3D
var _player: AnimationPlayer
var _rest := {}
var _fingers: Animation
var _thigh: float
var _shin: float
var _memo := {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	var model: Node3D = (load(MODEL) as PackedScene).instantiate()
	root.add_child(model)
	_sk = model.find_child("GeneralSkeleton", true, false)
	_player = model.find_children("*", "AnimationPlayer", true, false)[0]
	for n in _player.get_animation_list():
		var low := String(n).to_lower()
		if low.contains("idle") and not low.contains("crouch") and not String(n).begins_with("Locomotion/"):
			_fingers = _player.get_animation(n)
			break
	for i in _sk.get_bone_count():
		_rest[_sk.get_bone_name(i)] = _sk.get_bone_global_rest(i)
	_thigh = _at("LeftLowerLeg").distance_to(_at("LeftUpperLeg"))
	_shin = _at("LeftFoot").distance_to(_at("LeftLowerLeg"))

	var specs: Array[Dictionary] = _specs()
	var only: String = OS.get_environment("GAIT_ONLY")
	var library := AnimationLibrary.new()
	var clips := {}
	for spec in specs:
		if only != "" and not (spec.name as String).begins_with(only):
			continue
		library.add_animation(StringName(spec.name), _write(spec))
		clips[spec.name] = _clip(spec)
	_player.add_animation_library(&"gait", library)
	for spec in specs:
		if only == "" or (spec.name as String).begins_with(only):
			_measure(spec, OS.get_environment("GAIT_TABLE") == spec.name)
	if only != "":
		quit()
		return
	ResourceSaver.save(library, TRIAL_LIBRARY)
	var trial := _fill_set(SetScript.new(), clips)
	ResourceSaver.save(trial, TRIAL_SET)
	print("\nwrote ", TRIAL_LIBRARY, " and ", TRIAL_SET)
	if OS.get_environment("GAIT_LAND") == "1":
		_land(library, clips)
	quit()


## Every clip: its name, seconds, whether it loops, the rig state at a time,
## how far the unit has gone by a time, and what goes in its LocomotionClip.
func _specs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({"name": "idle", "length": IDLE_LENGTH, "loops": true,
			"state": _idle_state, "root": func(_t: float) -> float: return 0.0})
	for g: Dictionary in [WALK, RUN]:
		var length: float = g.frames / FPS
		out.append({"name": g.name, "length": length, "loops": true, "gait": g,
				"state": func(t: float) -> Dictionary: return _gait_state(g, t / length),
				"root": func(t: float) -> float: return g.speed * t})
	var start: Dictionary = _start_plan(RUN)
	out.append({"name": "run_start", "length": start.length, "loops": false, "leaves_at": start.leaves_at,
			"state": func(t: float) -> Dictionary: return _start_state(start, t),
			"root": func(t: float) -> float: return _start_root(start, t)})
	for row: Array in [[RUN, RUN_STOP_DISTANCE, [0.0, 0.25, 0.5, 0.75]],
			[WALK, WALK_STOP_DISTANCE, [0.0, 1.0 / 6.0, 2.0 / 6.0, 0.5, 4.0 / 6.0, 5.0 / 6.0]]]:
		var g: Dictionary = row[0]
		var n: int = 0
		for phase: float in row[2]:
			n += 1
			var plan: Dictionary = _stop_plan(g, phase, row[1])
			out.append({"name": "%s_stop_%d" % [g.name, n], "length": plan.length, "loops": false,
					"enters_at": phase * g.frames / FPS, "leaves_at": 0.0, "plan": plan,
					"state": func(t: float) -> Dictionary: return _stop_state(plan, t),
					"root": func(t: float) -> float: return _stop_root(plan, t)})
	return out


func _at(bone: String) -> Vector3:
	return (_rest[bone] as Transform3D).origin


func _rx(deg: float) -> Basis:
	return Basis(Vector3.RIGHT, deg_to_rad(deg))

func _ry(deg: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(deg))

func _rz(deg: float) -> Basis:
	return Basis(Vector3.BACK, deg_to_rad(deg))

## A turn from its yaw (to the left), roll (left side up) and pitch (forward).
func _turn3(v: Vector3) -> Basis:
	return _ry(v.x) * _rz(v.y) * _rx(v.z)

func _wave(phase: float, peak: float, times: float = 1.0) -> float:
	return cos(TAU * times * (phase - peak))

func _ease(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


# --- a gait at a phase of its stride ---------------------------------------

## The pelvis: where the Hips bone is, and its yaw, roll and pitch.
func _pelvis_parts(g: Dictionary, phase: float) -> Array:
	var duty: float = g.duty
	var mid: float = duty * 0.5            # the left foot's mid-stance
	var high: float = g.get("bob_at", duty + (0.5 - duty) * 0.5)  # a run: mid-flight
	var at: Vector3 = _at("Hips")
	at.y += g.hips_y + g.bob * _wave(phase, high, 2.0)
	at.z += g.hips_z + g.surge * _wave(phase, duty, 2.0)
	at.x += g.sway * _wave(phase, mid)
	var turn := Vector3(g.pelvis_yaw * _wave(phase, g.get("yaw_at", duty)),
			g.pelvis_roll * _wave(phase, mid + 0.03),
			g.pelvis_pitch + g.pelvis_nod * _wave(phase, mid + 0.04, 2.0))
	return [at, turn]


## A planted foot `share` of the way through its stance: the ankle, and the
## foot's pitch (heel up = plus). The flat foot is carried back at the
## clip's speed; toes-up turns it about the heel, heel-up about the ball.
func _stance(g: Dictionary, share: float) -> Array:
	var stride: float = g.speed * g.frames / FPS
	var z: float = g.touch_z - stride * g.duty * share
	var pitch: float = 0.0
	if share < g.flat_by:
		pitch = -g.heel_strike * (1.0 - _ease(share / g.flat_by))
	elif share > g.heel_off:
		pitch = g.toe_off * pow((share - g.heel_off) / (1.0 - g.heel_off), 1.7)
	return [_planted(z, pitch), pitch]


## The ankle of a foot whose flat place is `z`, pitched about its heel
## (toes up) or the ball of the foot (heel up).
func _planted(z: float, pitch: float) -> Vector3:
	var pivot: Vector3 = HEEL if pitch < 0.0 else BALL
	return Vector3(0, ANKLE_Y, z) + pivot - _rx(pitch) * pivot


## The ankle of `side`'s foot (+1 left, -1 right) at a phase of that foot's
## own (0 = its touchdown), in the root's frame.
func _ankle(g: Dictionary, side: float, own: float) -> Vector3:
	var duty: float = g.duty
	var at: Vector3
	if own < duty:
		at = _stance(g, own / duty)[0]
		at.x = side * g.step_x
		return at
	var u: float = (own - duty) / (1.0 - duty)
	var keys: Array = [[0.0, _stance(g, 1.0)[0]]]
	for k: Array in g.swing:
		keys.append([k[0], Vector3(0, k[2], k[1])])
	keys.append([1.0, _stance(g, 0.0)[0]])
	# Leave and meet the ground at the speed the planted foot has there.
	var e := 0.002
	var leave: Vector3 = (_stance(g, 1.0)[0] - _stance(g, 1.0 - e)[0]) / e * (1.0 - duty) / duty
	var meet: Vector3 = (_stance(g, e)[0] - _stance(g, 0.0)[0]) / e * (1.0 - duty) / duty
	at = _spline(keys, u, leave, meet)
	at.x = side * (g.step_x + g.swing_x * sin(PI * u))
	return at


## A curve through `keys` ([share, Vector3], first at 0 and last at 1) with
## the given slopes at its two ends.
func _spline(keys: Array, u: float, slope_in: Vector3, slope_out: Vector3) -> Vector3:
	var n: int = keys.size()
	var i: int = 0
	while i < n - 2 and u > keys[i + 1][0]:
		i += 1
	var slopes: Array[Vector3] = []
	for k in [i, i + 1]:
		if k == 0:
			slopes.append(slope_in)
		elif k == n - 1:
			slopes.append(slope_out)
		else:
			slopes.append((keys[k + 1][1] - keys[k - 1][1]) / (keys[k + 1][0] - keys[k - 1][0]))
	var span: float = keys[i + 1][0] - keys[i][0]
	return _hermite(keys[i][1], slopes[0] * span, keys[i + 1][1], slopes[1] * span, (u - keys[i][0]) / span)


func _hermite(a: Vector3, slope_a: Vector3, b: Vector3, slope_b: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return a * (2 * t3 - 3 * t2 + 1) + slope_a * (t3 - 2 * t2 + t) + b * (-2 * t3 + 3 * t2) + slope_b * (t3 - t2)


## A leg from its hip to where its ankle is wanted: the knee, the ankle it
## reaches, the knee's hinge, and how much of its length it uses.
func _solve(hip: Vector3, want: Vector3, pelvis: Basis, knee_yaw: float) -> Dictionary:
	var to: Vector3 = want - hip
	var reach: float = to.length() / (_thigh + _shin)
	var dist: float = minf(to.length(), (_thigh + _shin) * 0.9995)
	var dir: Vector3 = to.normalized()
	# The knee points ahead, turned a little with the pelvis and the toes.
	var pole: Vector3 = _ry(knee_yaw) * (pelvis * Vector3.BACK).slide(Vector3.UP).normalized()
	var hinge: Vector3 = pole.cross(dir).normalized()
	var ahead: Vector3 = dir.cross(hinge)
	var along: float = (_thigh * _thigh - _shin * _shin + dist * dist) / (2.0 * dist)
	var knee: Vector3 = hip + dir * along + ahead * sqrt(maxf(_thigh * _thigh - along * along, 0.0))
	var ankle: Vector3 = hip + dir * dist
	var shin: Vector3 = (ankle - knee).normalized()
	return {"hip": hip, "knee": knee, "ankle": ankle, "hinge": hinge, "reach": reach,
			"shin_pitch": rad_to_deg(atan2(-shin.z, -shin.y))}


## One leg of a gait solved at a phase of the stride.
func _leg(g: Dictionary, side: float, phase: float) -> Dictionary:
	var key := "%s %s %.5f" % [g.name, side, phase]
	if _memo.has(key):
		return _memo[key]
	var bone: String = "Left" if side > 0.0 else "Right"
	var parts: Array = _pelvis_parts(g, phase)
	var turn: Basis = _turn3(parts[1])
	var hip: Vector3 = parts[0] + turn * (_at(bone + "UpperLeg") - _at("Hips"))
	var own: float = fposmod(phase + (0.0 if side > 0.0 else 0.5), 1.0)
	var want: Vector3 = _ankle(g, side, own)
	var out: Dictionary = _solve(hip, want, turn, side * g.toe_out * 0.5)
	out["own"] = own
	out["want"] = want
	_memo[key] = out
	return out


## The foot's pitch at a phase of the stride (heel up = plus). On the
## ground it is the roll of the stance; in the air it hangs off the shin.
func _foot_pitch(g: Dictionary, side: float, phase: float) -> float:
	var leg: Dictionary = _leg(g, side, phase)
	var duty: float = g.duty
	var own: float = leg.own
	if own < duty:
		return _stance(g, own / duty)[1]
	var start: float = phase - own
	var off: float = g.toe_off - _leg(g, side, start + duty - 0.00001).shin_pitch
	var on: float = -g.heel_strike - _leg(g, side, start + 1.0).shin_pitch
	var keys: Array = [[0.0, Vector3(off, 0, 0)]]
	for k: Array in g.swing_ankle:
		keys.append([k[0], Vector3(k[1], 0, 0)])
	keys.append([1.0, Vector3(on, 0, 0)])
	var u: float = (own - duty) / (1.0 - duty)
	return leg.shin_pitch + _spline(keys, u, Vector3.ZERO, Vector3.ZERO).x


## The rig state of a gait at a phase of its stride.
##   hips: where the Hips bone is.  pelvis, chest, head: yaw, roll, pitch.
##   feet [left, right]: the ankle, the foot's pitch, the toes' bend back,
##     the toes' turn outward.
##   arms [left, right]: swing forward, lift outward, the elbow's turn
##     inward, the elbow's bend, the wrist's, the collarbone's turn.
func _gait_state(g: Dictionary, phase: float) -> Dictionary:
	var duty: float = g.duty
	var mid: float = duty * 0.5
	var late: float = g.spine_late
	var yaw_at: float = g.get("yaw_at", duty)
	# A run: an arm is furthest forward as its own foot leaves the ground.
	var arm_at: float = g.get("arm_at", duty + 0.02 + late * 2.0 + g.arm_late)
	var parts: Array = _pelvis_parts(g, phase)
	var feet := []
	var arms := []
	for side: float in [1.0, -1.0]:
		var leg: Dictionary = _leg(g, side, phase)
		var pitch: float = _foot_pitch(g, side, phase)
		# The toes stay on the ground while the heel lifts, and straighten
		# soon after the foot leaves.
		var bend: float = 0.0
		if leg.own < duty:
			bend = maxf(pitch, 0.0)
		else:
			bend = g.toe_off * (1.0 - _ease((leg.own - duty) / (1.0 - duty) / 0.30))
		feet.append({"ankle": leg.want, "pitch": pitch, "bend": bend, "yaw": g.toe_out})
		var own: float = phase + (0.0 if side > 0.0 else 0.5)
		var beat: float = _wave(own, arm_at)
		var swing: float = g.arm_back + g.arm_swing * beat
		arms.append([swing,
				g.arm_out + g.arm_flare * maxf(-beat, 0.0),
				g.arm_in + g.arm_cross * beat,
				g.elbow + g.elbow_pump * _wave(own, arm_at + g.arm_late) - g.elbow_bounce * _wave(phase, mid + 0.08, 2.0),
				-6.0 - 5.0 * _wave(own, duty + 0.12),   # the hand trails the forearm a touch
				g.clavicle * swing])
	return {
		"hips": parts[0], "pelvis": parts[1],
		# The chest turns against the pelvis, each stage a little late.
		"chest": Vector3(-g.chest_yaw * _wave(phase, yaw_at + late * 2.0),
				-g.chest_roll * _wave(phase, mid + 0.03 + late * 2.0),
				g.chest_pitch + g.chest_nod * _wave(phase, mid + 0.06 + late * 2.0, 2.0)),
		"head": Vector3(-g.chest_yaw * g.head_yaw * _wave(phase, yaw_at + late * 3.0), 0.0,
				g.head_pitch + 1.0 * _wave(phase, mid + 0.10 + late * 3.0, 2.0)),
		"feet": feet, "arms": arms,
	}


# --- the idle --------------------------------------------------------------

## Standing: knees soft, the weight drifting a little from foot to foot
## once, two breaths, the arms hung. The feet do not move.
func _idle_state(t: float) -> Dictionary:
	var p: float = t / IDLE_LENGTH
	var drift: float = sin(TAU * p)
	var breath: float = _wave(p, 0.22, 2.0)
	var feet := []
	var arms := []
	for side: float in [1.0, -1.0]:
		feet.append({"ankle": Vector3(side * IDLE_X, ANKLE_Y, IDLE_Z), "pitch": 0.0, "bend": 0.0, "yaw": IDLE_YAW})
		arms.append([2.0 + 0.5 * breath + 1.0 * side * sin(TAU * p + 0.9),
				7.0 + 0.5 * breath,
				20.0,
				14.5 - side * 1.5 + 0.8 * sin(TAU * p + 0.4 + side),
				-6.0,
				0.4 * breath])
	return {
		"hips": _at("Hips") + Vector3(0.009 * drift, -0.014 + 0.0015 * breath, 0.0),
		"pelvis": Vector3(1.2 + 0.8 * sin(TAU * p + 0.6), 0.9 * drift, 1.0),
		"chest": Vector3(-1.0 - 0.9 * sin(TAU * p + 0.3), -0.6 * sin(TAU * p + 0.25), 2.0 - 0.8 * breath),
		"head": Vector3(1.6 * sin(TAU * p + 1.3), 0.0, 1.0 + 0.4 * breath),
		"feet": feet, "arms": arms,
	}


## `a` mixed toward `b` by `w`.
func _mix(a: Dictionary, b: Dictionary, w: float) -> Dictionary:
	var feet := []
	var arms := []
	for i in 2:
		var fa: Dictionary = a.feet[i]
		var fb: Dictionary = b.feet[i]
		feet.append({"ankle": (fa.ankle as Vector3).lerp(fb.ankle, w), "pitch": lerpf(fa.pitch, fb.pitch, w),
				"bend": lerpf(fa.bend, fb.bend, w), "yaw": lerpf(fa.yaw, fb.yaw, w)})
		var arm := []
		for k in 6:
			arm.append(lerpf(a.arms[i][k], b.arms[i][k], w))
		arms.append(arm)
	return {"hips": (a.hips as Vector3).lerp(b.hips, w), "pelvis": (a.pelvis as Vector3).lerp(b.pelvis, w),
			"chest": (a.chest as Vector3).lerp(b.chest, w), "head": (a.head as Vector3).lerp(b.head, w),
			"feet": feet, "arms": arms}


## A foot in the air may not go through the ground: lift the ankle by as
## much as its heel, ball or toes would be under it, so a foot coming off
## the ground peels off it.
func _keep_above_ground(foot: Dictionary) -> void:
	var turn: Basis = _rx(foot.pitch)
	var ankle: Vector3 = foot.ankle
	var ball: Vector3 = ankle + turn * BALL
	var tip: Vector3 = ball + turn * _rx(-minf(foot.bend, 62.0)) * (TIP - BALL)
	var low: float = minf((ankle + turn * HEEL).y, minf(ball.y, tip.y))
	if low < 0.0:
		ankle.y -= low
		foot.ankle = ankle


# --- the start into the run ------------------------------------------------

## The unit stands a moment, gets to the run's speed in the time the game
## takes to, and then runs. The left foot stays where it stood and pushes
## off as the run's own planted foot; the right comes off the ground into
## the run's swing.
func _start_plan(g: Dictionary) -> Dictionary:
	var stride: float = g.speed * g.frames / FPS
	var plan := {"g": g, "stride": stride, "wait": 0.1, "gain": g.speed / RUN_ACCEL_TIME, "length": 21.0 / FPS}
	# The phase at which the run's planted left foot is where the idle's is.
	plan["phase"] = (g.touch_z - IDLE_Z) / stride
	var end: float = plan.phase + _start_root(plan, plan.length) / stride
	plan["leaves_at"] = fposmod(end, 1.0) * g.frames / FPS
	return plan


func _start_root(plan: Dictionary, t: float) -> float:
	var g: Dictionary = plan.g
	var moving: float = t - plan.wait
	if moving <= 0.0:
		return 0.0
	if moving < RUN_ACCEL_TIME:
		return 0.5 * plan.gain * moving * moving
	return 0.5 * g.speed * RUN_ACCEL_TIME + g.speed * (moving - RUN_ACCEL_TIME)


func _start_state(plan: Dictionary, t: float) -> Dictionary:
	var g: Dictionary = plan.g
	var gone: float = _start_root(plan, t)
	var phase: float = plan.phase + gone / plan.stride
	var run: Dictionary = _gait_state(g, phase)
	var state: Dictionary = _mix(_idle_state(0.0), run, _ease(t / 0.34))
	# The left foot is the run's, kept as wide and as turned out as it stood
	# until it leaves the ground.
	var left: Dictionary = (run.feet[0] as Dictionary).duplicate()
	var freed: float = _ease((phase - g.duty) / 0.2)
	var ankle: Vector3 = left.ankle
	ankle.x = lerpf(IDLE_X, ankle.x, freed)
	left.ankle = ankle
	left.yaw = lerpf(IDLE_YAW, left.yaw, freed)
	state.feet[0] = left
	# The right foot leaves where it stood for the run's swing.
	var from := {"ankle": Vector3(-IDLE_X, ANKLE_Y, IDLE_Z - gone), "pitch": 0.0, "bend": 0.0, "yaw": IDLE_YAW}
	var lifted: float = _ease((t - 0.05) / 0.2)
	var right: Dictionary = run.feet[1]
	var foot := {"ankle": (from.ankle as Vector3).lerp(right.ankle, lifted),
			"pitch": lerpf(0.0, right.pitch, lifted), "yaw": lerpf(IDLE_YAW, right.yaw, lifted)}
	foot["bend"] = lerpf(clampf(foot.pitch, 0.0, 62.0), right.bend, lifted)
	if lifted < 1.0:
		_keep_above_ground(foot)
	state.feet[1] = foot
	return state


# --- the stops -------------------------------------------------------------

## A stop off `g` from `phase` of its stride, over `distance` metres of the
## unit's. The unit slows evenly. Each foot goes on as the loop has it,
## takes one last step, and lands where the idle stands: first the foot
## that is in the air (or nearest leaving the ground), ahead of the body to
## brake on, then the other up beside it.
func _stop_plan(g: Dictionary, phase: float, distance: float) -> Dictionary:
	var stride: float = g.speed * g.frames / FPS
	var duty: float = g.duty
	var travel: float = distance / ARRIVED
	var slowing: float = g.speed * g.speed / (2.0 * travel)
	var plan := {"g": g, "phase": phase, "stride": stride, "travel": travel, "slowing": slowing,
			"halt": g.speed / slowing}
	var own: Array[float] = [fposmod(phase, 1.0), fposmod(phase + 0.5, 1.0)]
	var first: int = 0
	if own[0] >= duty:
		first = 0
	elif own[1] >= duty:
		first = 1
	else:
		first = 0 if own[0] > own[1] else 1
	var second: int = 1 - first
	var off_first: float = 0.0
	var soonest: float = 0.0
	if own[first] >= duty:
		soonest = (1.0 - own[first]) * g.frames / FPS * g.stop_hurry
	else:
		off_first = _stop_when(plan, (duty - own[first]) * stride)
		soonest = off_first + g.stop_swing
	var land_first: float = maxf(_stop_when(plan, travel - g.stop_reach), soonest)
	var off_second: float = land_first + g.stop_hold
	var needs: float = (duty - own[second]) * stride
	if needs < travel:
		off_second = minf(off_second, _stop_when(plan, needs))
	var land_second: float = maxf(off_second + g.stop_close, land_first + 0.2)
	var feet := [{}, {}]
	feet[first] = {"off": off_first, "land": land_first, "heel": g.stop_heel}
	feet[second] = {"off": off_second, "land": land_second, "heel": 4.0}
	plan["feet"] = feet
	plan["brake_from"] = maxf(land_first - 0.12, 0.0)
	var settled: float = maxf(land_second + 0.12, maxf(plan.halt + 0.12, plan.brake_from + 0.5))
	plan["length"] = ceilf((settled + 0.3) * FPS) / FPS
	# Where each foot is, and how fast, as it leaves for its last step.
	for i in 2:
		var f: Dictionary = feet[i]
		var e := 0.002
		f["from"] = _stop_loop_foot(plan, i, f.off)
		f["speed"] = ((f.from.ankle as Vector3) - (_stop_loop_foot(plan, i, f.off - e).ankle as Vector3)) / e
		f["lift"] = g.stop_lift if (f.from.ankle as Vector3).y < 0.2 else 0.0
	return plan


func _stop_root(plan: Dictionary, t: float) -> float:
	var g: Dictionary = plan.g
	if t <= 0.0:
		return g.speed * t
	if t >= plan.halt:
		return plan.travel
	return g.speed * t - 0.5 * plan.slowing * t * t


## When the unit has gone `metres` into the stop.
func _stop_when(plan: Dictionary, metres: float) -> float:
	var g: Dictionary = plan.g
	if metres <= 0.0:
		return 0.0
	if metres >= plan.travel:
		return plan.halt
	return (g.speed - sqrt(g.speed * g.speed - 2.0 * plan.slowing * metres)) / plan.slowing


## A foot as the loop has it, the loop going on by the ground covered.
func _stop_loop_foot(plan: Dictionary, i: int, t: float) -> Dictionary:
	return _gait_state(plan.g, plan.phase + _stop_root(plan, t) / plan.stride).feet[i]


func _stop_foot(plan: Dictionary, i: int, t: float) -> Dictionary:
	var f: Dictionary = plan.feet[i]
	var side: float = 1.0 if i == 0 else -1.0
	if t <= f.off:
		return _stop_loop_foot(plan, i, t)
	# Where the idle has the foot, seen from the unit as it comes up to it.
	var ahead: float = plan.travel - _stop_root(plan, t) + IDLE_Z
	if t >= f.land:
		var pitch: float = -f.heel * (1.0 - _ease((t - f.land) / 0.1))
		var ankle: Vector3 = _planted(ahead, pitch)
		ankle.x = side * IDLE_X
		return {"ankle": ankle, "pitch": pitch, "bend": 0.0, "yaw": IDLE_YAW}
	var from: Dictionary = f.from
	var took: float = f.land - f.off
	var u: float = (t - f.off) / took
	var e := 0.002
	var to: Vector3 = _planted(plan.travel - _stop_root(plan, f.land) + IDLE_Z, -f.heel)
	var to_speed := Vector3(0.0, -0.25, -(_stop_root(plan, f.land) - _stop_root(plan, f.land - e)) / e)
	var at: Vector3 = _hermite(from.ankle, (f.speed as Vector3) * took, to, to_speed * took, u)
	at.y += f.lift * pow(sin(PI * u), 2.0)
	at.x = lerpf((from.ankle as Vector3).x, side * IDLE_X, _ease(u))
	var foot := {"ankle": at, "pitch": lerpf(from.pitch, -f.heel, _ease(u)),
			"bend": from.bend * (1.0 - _ease(u / 0.3)), "yaw": lerpf(from.yaw, IDLE_YAW, _ease(u))}
	_keep_above_ground(foot)
	return foot


func _stop_state(plan: Dictionary, t: float) -> Dictionary:
	var g: Dictionary = plan.g
	var loop: Dictionary = _gait_state(g, plan.phase + _stop_root(plan, t) / plan.stride)
	var state: Dictionary = _mix(loop, _idle_state(t - plan.length), _ease(t / (plan.halt + 0.1)))
	# Braking: the body sits back and down onto the first foot to land.
	var brake: float = g.brake * pow(sin(PI * clampf((t - plan.brake_from) / 0.5, 0.0, 1.0)), 2.0)
	state.hips += Vector3(0.0, -0.045, -0.03) * brake
	state.pelvis += Vector3(0.0, 0.0, -6.0) * brake
	state.chest += Vector3(0.0, 0.0, -14.0) * brake
	for i in 2:
		state.arms[i][1] += 8.0 * brake
		state.feet[i] = _stop_foot(plan, i, t)
	return state


# --- from a rig state to bones ---------------------------------------------

# A frame along `dir` with `side` across it.
func _frame(dir: Vector3, side: Vector3) -> Basis:
	dir = dir.normalized()
	side = (side - dir * side.dot(dir)).normalized()
	return Basis(side, dir, side.cross(dir))


## Every posed bone's turn from rest, in the model's frame, the Hips' place,
## and how much of its length each leg uses.
func _build(state: Dictionary) -> Dictionary:
	var turn := {}
	var pelvis: Basis = _turn3(state.pelvis)
	turn["Hips"] = pelvis
	var reach := []
	for i in 2:
		var side: float = 1.0 if i == 0 else -1.0
		var bone: String = "Left" if i == 0 else "Right"
		var foot: Dictionary = state.feet[i]
		var hip: Vector3 = (state.hips as Vector3) + pelvis * (_at(bone + "UpperLeg") - _at("Hips"))
		var leg: Dictionary = _solve(hip, foot.ankle, pelvis, side * foot.yaw * 0.5)
		reach.append(leg.reach)
		var thigh0: Vector3 = _at(bone + "LowerLeg") - _at(bone + "UpperLeg")
		var shin0: Vector3 = _at(bone + "Foot") - _at(bone + "LowerLeg")
		turn[bone + "UpperLeg"] = _frame(leg.knee - leg.hip, leg.hinge) * _frame(thigh0, Vector3.RIGHT).inverse()
		turn[bone + "LowerLeg"] = _frame(leg.ankle - leg.knee, leg.hinge) * _frame(shin0, Vector3.RIGHT).inverse()
		turn[bone + "Foot"] = _ry(side * foot.yaw) * _rx(foot.pitch)
		turn[bone + "Toes"] = turn[bone + "Foot"] * _rx(-minf(foot.bend, 62.0))

	var chest: Basis = _turn3(state.chest)
	var low := Quaternion(pelvis)
	var high := Quaternion(chest)
	turn["Spine"] = Basis(low.slerp(high, 0.3))
	turn["Chest"] = Basis(low.slerp(high, 0.65))
	turn["UpperChest"] = chest
	var head: Basis = _turn3(state.head)
	turn["Neck"] = Basis(high.slerp(Quaternion(head), 0.5))
	turn["Head"] = head

	# The arms hang off the chest.
	for i in 2:
		var side: float = 1.0 if i == 0 else -1.0
		var bone: String = "Left" if i == 0 else "Right"
		var arm: Array = state.arms[i]
		var pose: Basis = _rx(-arm[0]) * _rz(side * arm[1])
		var dir: Vector3 = pose * Vector3.DOWN
		var bends_to: Vector3 = pose * _ry(-side * arm[2]) * Vector3.BACK
		var rest_dir := Vector3(side, 0, 0)
		var hinge: Vector3 = rest_dir.cross(Vector3.BACK).normalized()
		var upper: Basis = chest * _frame(dir, bends_to) * _frame(rest_dir, Vector3.BACK).inverse()
		turn[bone + "Shoulder"] = chest * _ry(-side * arm[5])
		turn[bone + "UpperArm"] = upper
		var fore: Basis = upper * Basis(hinge, deg_to_rad(arm[3]))
		turn[bone + "LowerArm"] = fore
		turn[bone + "Hand"] = fore * Basis(hinge, deg_to_rad(arm[4]))
	return {"hips": state.hips, "turn": turn, "reach": reach}


# --- the clips -------------------------------------------------------------

func _write(spec: Dictionary) -> Animation:
	_memo.clear()
	var anim := Animation.new()
	var length: float = spec.length
	var keys: int = roundi(length * FPS * KEYS_PER_FRAME)
	anim.length = length
	anim.loop_mode = Animation.LOOP_LINEAR if spec.loops else Animation.LOOP_NONE
	var hips_track: int = anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(hips_track, NodePath("%GeneralSkeleton:Hips"))
	var tracks := {}
	var first: Dictionary = _build(spec.state.call(0.0))
	for i in _sk.get_bone_count():
		var bone: String = _sk.get_bone_name(i)
		if not first.turn.has(bone):
			continue
		tracks[bone] = anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(tracks[bone], NodePath("%GeneralSkeleton:" + bone))
	for f in keys + 1:
		var t: float = length * f / keys
		var pose: Dictionary = _build(spec.state.call(t))
		# A position key is in the skeleton's own measure (motion_scale).
		anim.position_track_insert_key(hips_track, t, pose.hips / _sk.motion_scale)
		for bone: String in tracks:
			var world: Basis = (pose.turn[bone] as Basis) * (_rest[bone] as Transform3D).basis
			var parent: String = _sk.get_bone_name(_sk.get_bone_parent(_sk.find_bone(bone)))
			var above: Basis = (_rest[parent] as Transform3D).basis
			if pose.turn.has(parent):
				above = (pose.turn[parent] as Basis) * above
			anim.rotation_track_insert_key(tracks[bone], t, (above.inverse() * world).get_rotation_quaternion())
	if _fingers:
		for i in _fingers.get_track_count():
			var bone: String = String(_fingers.track_get_path(i)).get_slice(":", 1)
			if _fingers.track_get_type(i) != Animation.TYPE_ROTATION_3D or tracks.has(bone):
				continue
			var track: int = anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(track, _fingers.track_get_path(i))
			anim.rotation_track_insert_key(track, 0.0, _fingers.rotation_track_interpolate(i, 0.0))
	return anim


## What the game needs to know of a clip: the ground it covers, frame by
## frame, and the frames it is entered and left on.
func _clip(spec: Dictionary) -> Resource:
	var clip: Resource = ClipScript.new()
	var length: float = spec.length
	clip.clip = StringName("Locomotion/" + spec.name)
	clip.loops = spec.loops
	clip.length = length
	var positions := PackedVector3Array()
	var yaws := PackedFloat32Array()
	for f in roundi(length * FPS) + 1:
		positions.append(Vector3(0.0, 0.0, spec.root.call(f / FPS)))
		yaws.append(0.0)
	clip.root_positions = positions
	clip.root_yaws = yaws
	clip.enters_at = spec.get("enters_at", -1.0)
	clip.leaves_at = spec.get("leaves_at", -1.0)
	clip.travel = spec.root.call(length)
	clip.turn = 0.0
	clip.speed = clip.travel / length if spec.loops else 0.0
	clip.strides = 1
	return clip


func _fill_set(into: Resource, clips: Dictionary) -> Resource:
	into.idle = clips["idle"]
	into.walk = clips["walk"]
	into.run = clips["run"]
	into.jog_start = clips["run_start"]
	var walk_stops: Array[LocomotionClip] = []
	var run_stops: Array[LocomotionClip] = []
	for name: String in clips:
		if name.begins_with("walk_stop_"):
			walk_stops.append(clips[name])
		elif name.begins_with("run_stop_"):
			run_stops.append(clips[name])
	into.walk_stops = walk_stops
	into.jog_stops = run_stops
	return into


## Into the game's own library and set.
func _land(library: AnimationLibrary, clips: Dictionary) -> void:
	var game: AnimationLibrary = load(GAME_LIBRARY)
	for name in RETIRED:
		if game.has_animation(name):
			game.remove_animation(name)
	for name in library.get_animation_list():
		if game.has_animation(name):
			game.remove_animation(name)
		game.add_animation(name, library.get_animation(name))
	ResourceSaver.save(game, GAME_LIBRARY)
	ResourceSaver.save(_fill_set(load(GAME_SET), clips), GAME_SET)
	print("wrote ", GAME_LIBRARY, " and ", GAME_SET)


# --- the measures ----------------------------------------------------------

func _bone(bone: String) -> Transform3D:
	return _sk.get_bone_global_pose(_sk.find_bone(bone))


func _measure(spec: Dictionary, table: bool) -> void:
	_memo.clear()
	var length: float = spec.length
	var steps: int = roundi(length * 120.0)
	_player.play(StringName("gait/" + spec.name))
	var slide := 0.0
	var slide_at := ""
	var low := 1.0
	var low_at := ""
	var reach := 0.0
	var reach_at := ""
	var rows := []
	var before := {}
	var jump := 0.0
	var jump_at := ""
	var hips_gap := 0.0
	var posed: Dictionary = _build(spec.state.call(0.0)).turn
	for s in steps + (0 if spec.loops else 1):
		var t: float = length * s / steps
		_player.seek(t, true)
		_sk.force_update_all_bone_transforms()
		var pose: Dictionary = _build(spec.state.call(t))
		var gone: float = spec.root.call(t)
		hips_gap = maxf(hips_gap, _bone("Hips").origin.distance_to(pose.hips))
		for i in 2:
			var bone: String = "Left" if i == 0 else "Right"
			if pose.reach[i] > reach:
				reach = pose.reach[i]
				reach_at = "%s %.3f s" % [bone, t]
			var foot: Transform3D = _bone(bone + "Foot")
			var turn: Basis = foot.basis * (_rest[bone + "Foot"] as Transform3D).basis.inverse()
			var heel: Vector3 = foot.origin + turn * HEEL
			var ball: Vector3 = foot.origin + turn * BALL
			var toe_turn: Basis = _bone(bone + "Toes").basis * (_rest[bone + "Toes"] as Transform3D).basis.inverse()
			var tip: Vector3 = ball + toe_turn * (TIP - BALL)
			var lowest: float = minf(heel.y, minf(ball.y, tip.y))
			if lowest < low:
				low = lowest
				low_at = "%s %.3f s %s" % [bone, t, "heel" if lowest == heel.y else ("ball" if lowest == ball.y else "tip")]
			# Whatever is on the ground should stay where it is on the ground.
			for point: Array in [["heel", heel], ["ball", ball]]:
				var key: String = bone + point[0]
				var here: Vector3 = point[1]
				var ground := Vector3(here.x, here.y, here.z + gone)
				if here.y < 0.002 and before.has(key) and (before[key] as Vector3).y < 0.002:
					var moved: float = Vector2(ground.x - before[key].x, ground.z - before[key].z).length()
					if moved > slide:
						slide = moved
						slide_at = "%s %.3f s" % [key, t]
				before[key] = ground
			if table and i == 0 and s % 4 == 0:
				var hip: Vector3 = _bone("LeftUpperLeg").origin
				var knee: Vector3 = _bone("LeftLowerLeg").origin
				var thigh: Vector3 = (knee - hip).normalized()
				var shin: Vector3 = (foot.origin - knee).normalized()
				var pelvis_pitch: float = rad_to_deg(asin((_bone("Hips").basis * Vector3.UP).z))
				var ahead: Vector3 = turn * Vector3.BACK
				var foot_pitch: float = rad_to_deg(atan2(-ahead.y, ahead.z))
				rows.append("  %.3f hip %6.1f knee %6.1f ankle %6.1f foot %6.1f | ankle z %6.3f y %5.3f | hips y %.3f reach L %.3f R %.3f" % [
						t, rad_to_deg(atan2(thigh.z, -thigh.y)) + pelvis_pitch, rad_to_deg(thigh.angle_to(shin)),
						foot_pitch - rad_to_deg(atan2(-shin.z, -shin.y)), foot_pitch, foot.origin.z, foot.origin.y,
						_bone("Hips").origin.y, pose.reach[0], pose.reach[1]])
		for i in _sk.get_bone_count():
			var name: String = _sk.get_bone_name(i)
			if not posed.has(name):
				continue
			var q: Quaternion = _sk.get_bone_pose_rotation(i)
			if before.has("q" + name):
				var step: float = rad_to_deg((before["q" + name] as Quaternion).angle_to(q))
				if step > jump:
					jump = step
					jump_at = "%s %.3f s" % [name, t]
			before["q" + name] = q
	var note := ""
	if spec.has("plan"):
		var feet: Array = spec.plan.feet
		note = " | left off %.2f lands %.2f, right off %.2f lands %.2f, halt %.2f" % [
				feet[0].off, feet[0].land, feet[1].off, feet[1].land, spec.plan.halt]
	print("\n== %s: %.3f s, covers %.3f m%s" % [spec.name, length, spec.root.call(length), note])
	for row in rows:
		print(row)
	print("  slide %.1f mm a sample (%s) | lowest sole %.1f mm (%s) | reach %.3f (%s) | fastest %.0f deg/s (%s) | hips off %.1f mm" % [
			slide * 1000.0, slide_at, low * 1000.0, low_at, reach, reach_at, jump * 120.0, jump_at, hips_gap * 1000.0])
