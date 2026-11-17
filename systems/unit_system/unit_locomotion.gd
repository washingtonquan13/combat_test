class_name UnitLocomotion
extends RefCounted
## How a humanoid walks a route: the clips of its LocomotionSet, shown to
## follow the unit as gameplay moves it, in the manner of Baldur's Gate 3.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion"). Made by
## UnitAnimator for a body whose CharacterModel has a `locomotion` set;
## UnitMovement asks it, every tick of a walk, how far the unit goes (travel)
## instead of going at move_speed.
##
## The unit leads and the clips follow (no root motion). The unit's speed is
## gameplay's: it comes up to RUN_SPEED (or the walk's) in a fraction of a
## second, eases as it swings round to face the way, and slows so as to stop
## on the route's end. The clips are timed to that speed: a loop plays at the
## rate that keeps its feet on the ground at the unit's speed; the start and
## the stop are distance-matched, each frame showing the clip's own frame for
## the ground the unit has covered or has left. How fast the unit comes up
## to speed and slows for the end is read off the start and stops
## themselves, so each plays out rather than being cut short.
##
## A move goes (as BG3's do: the unit is under way within a frame of the
## order, whichever way it faces; it swings round as it steps off, at
## UnitFacing's rotation_speed, never standing to turn first):
##   STARTING  from rest into the run or the walk, by its start (its idle
##             lead-in skipped).
##   MOVING    the loop, at the rate of the unit's speed.
##   STOPPING  once the unit slows for the end: the stop whose pose is
##             nearest the loop's, on its frame for the ground left.
##   SETTLING  the route is done, the stop's settle plays on; it hands to the
##             idle on the idle's own frame.
## Running below the run loop's speed (swinging round, breaking into the
## run) the walk shows under the run in step with it, the two weighed by the
## unit's speed (_moving: a blend by speed, as a blend space does), so the
## legs never play a run in slow motion.
## A new order while moving or stopping goes on at the same gait, except
## that a walk whose new route is WALK_UNDER or longer breaks into the run
## (with the walk and run marked, by speeding up through the blend from the
## walk's own stride; otherwise by the run start, from its frame for the
## unit's speed); one while
## settling or turning in place starts at once. Routes under WALK_UNDER are
## walked, the rest run.
##
## Standing (TURNING), a swing of facing of TURN_FROM or more (UnitFacing
## asks, turn_to) is the turn in place nearest the angle, scaled to it,
## turning the unit by its own root yaw, back into the idle;
## smaller swings are UnitFacing's, shown by UnitAnimator's turning loops.
## Never in the air, on a ladder or on a wall: those keep their own clips and
## move_speed.
##
## While the unit moves the body leans into its turns (lean), a roll of the
## body about its forward axis, from speed times turn rate.

enum State { OFF, TURNING, STARTING, MOVING, STOPPING, SETTLING }

## A route shorter than this is walked; anything longer is run.
const WALK_UNDER := 2.0
## The run's ground speed, metres a second (the walk goes at its loop's).
const RUN_SPEED := 4.6
## Seconds from rest to full speed, at the least; a start that takes longer
## to come up to speed, played at START_RATE, sets it.
const RUN_ACCEL_TIME := 0.3
const WALK_ACCEL_TIME := 0.25
const ACCEL_TIME_MOST := 0.6
const START_RATE := 2.0
## Metres from the end the unit begins to slow, at full speed, where the
## stops do not say (they do: where they drop below SLOWING of the loop's
## speed), within STOP_DISTANCE_LEAST..MOST.
const RUN_STOP_DISTANCE := 1.1
const WALK_STOP_DISTANCE := 0.45
const SLOWING := 0.9
const STOP_DISTANCE_LEAST := 0.3
const STOP_DISTANCE_MOST := 1.2
## A turn of facing this large is a turn in place; less, UnitFacing's.
const TURN_FROM := deg_to_rad(60.0)
## The turn is done once this much of it is, and hands on.
const TURN_DONE := 0.92
## A turn is scaled to the angle wanted by no more or less than this.
const TURN_SCALE_LEAST := 0.5
const TURN_SCALE_MOST := 1.6
## The slowest the unit closes the last centimetres at.
const ARRIVE_SPEED := 0.4
## Facing further off the way than this slows the unit, down to SLOWEST at
## FROM + SPAN, while it swings round.
const FACING_SLOW_FROM := deg_to_rad(40.0)
const FACING_SLOW_SPAN := deg_to_rad(80.0)
const FACING_SLOWEST := 0.05
## Play-rate limits: the loop, and a start or stop matched to the ground.
const LOOP_RATE_LEAST := 0.35
const LOOP_RATE_MOST := 1.7
const MATCH_RATE_MOST := 3.0
## A clip's motion begins where it first goes this fast, m/s.
const ONSET_SPEED := 0.3
## Crossfades: the walk or start from rest, a handover, into a stop, the idle.
const BLEND_WALK_IN := 0.25
const BLEND_START := 0.15
const BLEND_HAND := 0.2
const BLEND_STOP := 0.18
const BLEND_IDLE := 0.3
const BLEND_TURN := 0.2
## A stop's ground is covered once this much of its travel is done; the
## rest is its settle, which plays after the route ends.
const ARRIVED := 0.97
## Bones a stop's pose is matched on against the loop's.
const MATCH_BONES := ["LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg"]
## Lean: degrees at most, of what a body really leans (tan = speed x turn
## rate / g), and how fast it follows.
const LEAN_MOST := deg_to_rad(8.0)
const LEAN_SHARE := 0.35
const LEAN_RATE := 6.0
## The head leads into a turn toward the route this far on: metres at the
## least, and seconds of travel at speed.
const LEAD_NEAREST := 1.5
const LEAD_SECONDS := 1.0

var state: State = State.OFF

var _unit: Unit
var _playback: BodyAnimationTree
var _set: LocomotionSet
## The body node leaned (the model's glb root), and its own place.
var _body: Node3D
var _body_rest := Transform3D.IDENTITY

var _loop: LocomotionClip = null
var _stops: Array[LocomotionClip] = []
## The one-shot playing (start, stop).
var _clip: LocomotionClip = null
## The unit's speed and how it comes up and goes down.
var _v: float = 0.0
var _top: float = 0.0
var _accel: float = 0.0
var _decel: float = 0.0
## Per clip, its progress along its own way on each frame, metres.
var _ground := {}
## A gait's stop distance, per stop list (cached).
var _stop_distances := {}

## The turn in place: the unit's yaw it began from, how much of the clip's
## turn it takes, and the yaw it is for.
var _turn_from: float = 0.0
var _turn_scale: float = 1.0
var _turn_target: float = 0.0
var _route: float = 0.0

var _lean: float = 0.0
## The head and chest's lead into a turn (null on a body with no skeleton).
var _turn_lead: BodyTurnLead = null
var _last_yaw: float = NAN
var _speed: float = 0.0
var _ticked: int = -1
## Where the walk under the run last stood (seconds), so a walk of several
## stride pairs keeps to the one it is on.
var _under_at: float = 0.0


func _init(unit: Unit, playback: BodyAnimationTree, set: LocomotionSet, body: Node3D) -> void:
	_unit = unit
	_playback = playback
	_set = set
	_body = body
	if _body:
		_body_rest = _body.transform
		var skeletons: Array[Node] = _body.find_children("*", "Skeleton3D", true, false)
		if not skeletons.is_empty():
			_turn_lead = BodyTurnLead.attach(skeletons[0] as Skeleton3D)


## The idle the set's stops and turns hand to.
func idle_clip() -> String:
	return String(_set.idle.clip) if _set.idle else ""


## The turning loop that way (left for a positive rate), for turning on the spot.
func turn_loop(left: bool) -> String:
	var clip: LocomotionClip = _set.turn_loop_left if left else _set.turn_loop_right
	return String(clip.clip) if clip else ""


## Whether a move is under way that this drives.
func drives() -> bool:
	return state == State.TURNING or state == State.STARTING or state == State.MOVING or state == State.STOPPING


## Whether a turn in place is turning the unit (UnitFacing keeps off it).
func turning() -> bool:
	return state == State.TURNING


func begin(route: float, _first_leg: Vector3) -> void:
	_route = route
	if (state == State.STARTING or state == State.MOVING or state == State.STOPPING) and _loop:
		# An order replaced mid-move: a walk with far to go breaks into the
		# run; otherwise on at the same gait.
		if _loop == _set.walk and route >= WALK_UNDER and _set.jog != null:
			_break_into_run()
		elif state == State.STOPPING:
			_playback.play(_loop.clip, BLEND_HAND)
			state = State.MOVING
		return
	# Standing, or turning in place (dropped where it is): under way now.
	_v = 0.0
	_start_moving(BLEND_START)


## Standing, a turn of facing to `yaw`: a turn in place if it is TURN_FROM or
## more and the body is in its idle (or settling into it). Returns whether
## the turn in place has it; if not, UnitFacing turns the unit.
func turn_to(yaw: float) -> bool:
	if state == State.TURNING:
		_aim_turn(yaw)
		return true
	var idle: bool = _set.idle != null and _playback.current_animation == _set.idle.clip
	if not (idle or state == State.SETTLING) or _unit.is_moving():
		return false
	return _turn_in_place(yaw)


func _turn_in_place(yaw: float) -> bool:
	var off: float = angle_difference(_unit.rotation.y, yaw)
	if absf(off) < TURN_FROM:
		return false
	var turn: LocomotionClip = _set.turn_for(off)
	if turn == null or absf(turn.turn) < 0.01 or signf(turn.turn) != signf(off):
		return false
	_clip = turn
	_turn_from = _unit.rotation.y
	_aim_turn(yaw)
	_playback.play(turn.clip, BLEND_TURN)
	state = State.TURNING
	return true


## The turn playing set to end facing `yaw`, from where it began.
func _aim_turn(yaw: float) -> void:
	_turn_target = yaw
	var whole: float = angle_difference(_turn_from, yaw)
	# Past the half-turn the other way round is shorter, but the clip turns
	# its own way: keep to it.
	if signf(whole) != signf(_clip.turn) and absf(whole) > PI * 0.5:
		whole += TAU * signf(_clip.turn)
	_turn_scale = clampf(whole / _clip.turn, TURN_SCALE_LEAST, TURN_SCALE_MOST)


## Into the move, by the gait's start: the run past WALK_UNDER, the walk
## short of it.
func _start_moving(blend: float) -> void:
	var runs: bool = _route >= WALK_UNDER and _set.jog != null
	var start: LocomotionClip = _take_gait(runs)
	_v = 0.0
	if start:
		_clip = start
		_playback.play(_clip.clip, blend)
		_playback.seek(_onset(_clip))
		state = State.STARTING
		return
	_playback.play(_loop.clip, BLEND_WALK_IN)
	state = State.MOVING


## The gait's loop, stops, top speed, how it comes up to it and slows from
## it; returns its start (null for none).
func _take_gait(runs: bool) -> LocomotionClip:
	_loop = (_set.run if _set.run else _set.jog) if runs else _set.walk
	_stops = _set.jog_stops if runs else _set.walk_stops
	_top = RUN_SPEED if runs else _loop.speed
	var start: LocomotionClip = _set.jog_start if runs else _set.walk_start
	var accel_time: float = RUN_ACCEL_TIME if runs else WALK_ACCEL_TIME
	if start:
		accel_time = clampf(_ramp_time(start, _top) / START_RATE, accel_time, ACCEL_TIME_MOST)
	_accel = _top / accel_time
	var stop_distance: float = _stop_distance(_stops, _top, RUN_STOP_DISTANCE if runs else WALK_STOP_DISTANCE)
	_decel = _top * _top / (2.0 * stop_distance)
	return start


## Walking, a new order far enough to run: into the run start on its frame
## for the unit's speed now (past its lead-in), which comes up to speed and
## hands to the run loop as from rest; or straight to the loop with none.
func _break_into_run() -> void:
	var walk: LocomotionClip = _loop
	var walk_at: float = _playback.current_animation_position
	var start: LocomotionClip = _take_gait(true)
	if _blends():
		# On the run loop at the walk's own stride, the walk under it at full
		# weight: the unit speeds up through the blend.
		_playback.play(_loop.clip, BLEND_HAND)
		_playback.seek(_loop.time_at(walk.phase_at(walk_at)))
		_under_at = walk_at
		state = State.MOVING
		_moving()
		return
	if start == null:
		var from: StringName = _playback.current_animation
		var at: float = _playback.current_animation_position
		_playback.play(_loop.clip, BLEND_HAND)
		_playback.seek(_matching_time(from, at, _loop))
		state = State.MOVING
		return
	var t: float = _onset(start)
	while t < start.length - BLEND_HAND and _clip_speed(start, t) < _v:
		t += 1.0 / LocomotionClip.FPS
	_clip = start
	_playback.play(_clip.clip, BLEND_HAND)
	_playback.seek(t)
	state = State.STARTING


## How far along its route the unit goes this tick, `left` metres from its
## end. Called by UnitMovement on every grounded walking tick.
func travel(delta: float, left: float) -> float:
	_ticked = Engine.get_physics_frames()
	if not _still_showing():
		state = State.OFF
		return _unit.move_speed * delta
	if state == State.TURNING:
		_turning()
		_speed = 0.0
		_lean_into(delta)
		return 0.0
	var want: float = _top * _facing_share()
	if _v < want:
		_v = minf(_v + _accel * delta, want)
	else:
		_v = maxf(want, _v - _decel * delta)
	var ending: bool = sqrt(2.0 * _decel * left) < _v
	if ending:
		_v = sqrt(2.0 * _decel * left)
	var step: float = minf((maxf(_v, ARRIVE_SPEED) if ending else _v) * delta, left)
	match state:
		State.STARTING:
			_starting(delta)
		State.MOVING:
			_moving()
	if ending and state != State.STOPPING:
		_begin_stop(left)
	if state == State.STOPPING:
		_stopping(delta, left - step)
	_speed = step / maxf(delta, 1e-4)
	_lean_into(delta)
	return step


## A tick with no walk: the settle after a stop, the lean coming upright.
func tick(delta: float) -> void:
	if _ticked == Engine.get_physics_frames():
		return
	_ticked = Engine.get_physics_frames()
	_speed = 0.0
	if state == State.SETTLING or state == State.TURNING:
		if not _still_showing():
			state = State.OFF
		elif state == State.TURNING:
			_turning()
		else:
			_hand_to_idle_near_end()
	_lean_into(delta)


## The move is over (arrived, stopped short or replaced by nothing). Returns
## whether this shows what comes next (the stop's settle, or the idle).
func finish() -> bool:
	_v = 0.0
	match state:
		State.STOPPING:
			_playback.set_clip_speed(1.0)
			state = State.SETTLING
			return true
		State.SETTLING:
			return true
		State.TURNING:
			# The turn plays out into the idle.
			return true
		State.STARTING, State.MOVING:
			# Cut short of a stop: back to the idle.
			_playback.play(StringName(idle_clip()), BLEND_IDLE)
			state = State.OFF
			return true
	return false


## Something else takes the body (a stance, a cast, a cutscene).
func abandon() -> void:
	state = State.OFF
	_v = 0.0


func _still_showing() -> bool:
	var want: LocomotionClip = _loop if state == State.MOVING else _clip
	return want != null and _playback.current_animation == want.clip


## How much of its speed the unit may have while it swings round to the way.
func _facing_share() -> float:
	var way: Vector3 = _unit.first_leg()
	if way.length_squared() < 1e-6:
		return 1.0
	var facing: Vector3 = _unit.visual_forward()
	facing.y = 0.0
	if facing.length_squared() < 1e-6:
		return 1.0
	var off: float = facing.normalized().angle_to(way)
	return clampf(1.0 - (off - FACING_SLOW_FROM) / FACING_SLOW_SPAN, FACING_SLOWEST, 1.0)


# --- states -------------------------------------------------------------------

## The turn in place, the unit turned by the clip's own root yaw, scaled to
## the angle wanted. Done, it hands to the idle.
func _turning() -> void:
	var t: float = _playback.current_animation_position
	var yaw: float = _yaw_at(_clip, t)
	_unit.rotation.y = _turn_from + yaw * _turn_scale
	if absf(yaw) < absf(_clip.turn) * TURN_DONE and t < _clip.length - BLEND_HAND:
		return
	_unit.rotation.y = _turn_from + _clip.turn * _turn_scale
	_playback.play(_set.idle.clip, BLEND_IDLE)
	_playback.seek(fposmod(_clip.leaves_at - (_clip.length - t), _set.idle.length))
	state = State.OFF

## The start, played at the rate that keeps its feet under the unit's speed.
func _starting(_delta: float) -> void:
	var t: float = _playback.current_animation_position
	var own: float = _clip_speed(_clip, t)
	var rate: float = MATCH_RATE_MOST if own < 0.05 else clampf(_v / own, 0.5, MATCH_RATE_MOST)
	_playback.set_clip_speed(rate)
	# Up to speed, or the start runs out: the rest of the start is the jog's
	# own long run-up, which the loop shows better at this speed.
	if _v >= _top * 0.98 or t >= _clip.length - BLEND_HAND:
		# Onto the loop on the frame whose legs match the start's.
		var from: StringName = _playback.current_animation
		_playback.play(_loop.clip, BLEND_HAND)
		_playback.seek(_matching_time(from, t, _loop))
		state = State.MOVING
		_moving()


func _moving() -> void:
	if _blends():
		_moving_blended()
		return
	if _loop.speed > 0.0:
		_playback.set_clip_speed(clampf(_v / _loop.speed, LOOP_RATE_LEAST, LOOP_RATE_MOST))


## Whether the run can have the walk under it: running on the run loop, and
## both loops' strikes marked.
func _blends() -> bool:
	return (_loop != null and _loop == _set.run and _set.walk != null
		and _loop.marked() and _set.walk.marked() and _set.walk.speed < _loop.speed)


## The run with the walk under it, weighed by speed: all walk at the walk's
## speed and below, all run at the run's. The two share one stride: its
## length is theirs weighed the same way, and it goes at the rate that keeps
## the feet down at the unit's speed. The run is played at that rate; the
## walk stands on the same point of its stride (_walk_in_step).
func _moving_blended() -> void:
	var run: LocomotionClip = _loop
	var walk: LocomotionClip = _set.walk
	var w: float = clampf((_v - walk.speed) / (run.speed - walk.speed), 0.0, 1.0)
	var own: float = lerpf(walk.speed, run.speed, w)
	var run_stride: float = run.length / run.pairs()
	var stride: float = lerpf(walk.length / walk.pairs(), run_stride, w)
	_playback.set_clip_speed(clampf(run_stride / stride * _v / own, LOOP_RATE_LEAST, LOOP_RATE_MOST))
	if w >= 0.999:
		_playback.clear_partner()
	else:
		_playback.set_partner(walk.clip, 1.0 - w, _walk_in_step)


## The walk's seconds on the same point of its stride as the run at `run_at`.
## A walk of several stride pairs keeps to the pair it was on.
func _walk_in_step(run_at: float) -> float:
	var walk: LocomotionClip = _set.walk
	var phase: float = fposmod(_loop.phase_at(run_at), 1.0)
	var best: float = walk.time_at(phase)
	var best_gap: float = INF
	for k in walk.pairs():
		var t: float = walk.time_at(phase + k)
		var gap: float = fposmod(t - _under_at, walk.length)
		if gap < best_gap:
			best = t
			best_gap = gap
	_under_at = best
	return best


## Into the stop whose legs are nearest what shows now, on its frame for the
## ground left.
func _begin_stop(left: float) -> void:
	if _stops.is_empty():
		return
	var from: StringName = _playback.current_animation
	var at: float = _playback.current_animation_position
	var best: LocomotionClip = null
	var best_t: float = 0.0
	var best_gap: float = INF
	for stop in _stops:
		var t: float = _time_left(stop, left)
		var gap: float = _pose_gap(from, at, stop.clip, t)
		if gap < best_gap:
			best = stop
			best_t = t
			best_gap = gap
	_clip = best
	_playback.play(_clip.clip, BLEND_STOP)
	_playback.seek(best_t)
	state = State.STOPPING


## The stop shown on its frame for the ground still left after this tick.
func _stopping(delta: float, left_after: float) -> void:
	var t: float = _playback.current_animation_position
	var want: float = _time_left(_clip, maxf(left_after, 0.0))
	_playback.set_clip_speed(clampf((want - t) / maxf(delta, 1e-4), 0.3, MATCH_RATE_MOST))


func _hand_to_idle_near_end() -> void:
	var t: float = _playback.current_animation_position
	if t < _clip.length - BLEND_IDLE or _set.idle == null:
		return
	_playback.play(_set.idle.clip, BLEND_IDLE)
	_playback.seek(fposmod(_clip.leaves_at - (_clip.length - t), _set.idle.length))
	state = State.OFF


# --- the clips' ground --------------------------------------------------------

## A clip's progress along its own way on each frame, metres (cached).
func _progress_frames(clip: LocomotionClip) -> PackedFloat32Array:
	if _ground.has(clip):
		return _ground[clip]
	var out := PackedFloat32Array()
	var end: Vector3 = clip.root_at(clip.length).origin
	var way := Vector3(end.x, 0.0, end.z)
	var dir: Vector3 = way.normalized() if way.length_squared() > 1e-6 else Vector3.BACK
	var frames: int = maxi(clip.root_positions.size(), 1)
	for i in frames:
		var at: Vector3 = clip.root_at(i / LocomotionClip.FPS).origin
		out.append(Vector3(at.x, 0.0, at.z).dot(dir))
	_ground[clip] = out
	return out


func _progress(clip: LocomotionClip, seconds: float) -> float:
	var p: PackedFloat32Array = _progress_frames(clip)
	var at: float = clampf(seconds * LocomotionClip.FPS, 0.0, p.size() - 1)
	var i: int = mini(floori(at), maxi(p.size() - 2, 0))
	return lerpf(p[i], p[mini(i + 1, p.size() - 1)], at - i)


func _clip_speed(clip: LocomotionClip, seconds: float) -> float:
	var dt: float = 2.0 / LocomotionClip.FPS
	return (_progress(clip, seconds + dt) - _progress(clip, seconds)) / dt


## A clip's root yaw `seconds` in, unwrapped (a half-turn and more).
func _yaw_at(clip: LocomotionClip, seconds: float) -> float:
	var y: PackedFloat32Array = clip.root_yaws
	var at: float = clampf(seconds * LocomotionClip.FPS, 0.0, y.size() - 1)
	var i: int = mini(floori(at), maxi(y.size() - 2, 0))
	return lerpf(y[i], y[mini(i + 1, y.size() - 1)], at - i)


## Seconds a start takes from its onset to SLOWING of `top`, at its own rate.
func _ramp_time(clip: LocomotionClip, top: float) -> float:
	var from: float = _onset(clip)
	var t: float = from
	while t < clip.length:
		if _clip_speed(clip, t) >= top * SLOWING:
			return t - from
		t += 1.0 / LocomotionClip.FPS
	return clip.length - from


## Metres from the end the unit begins to slow, as the stops do: the ground
## each has left to its arrival where it first drops below SLOWING of `top`,
## on average; `otherwise` with no stops.
func _stop_distance(stops: Array[LocomotionClip], top: float, otherwise: float) -> float:
	if stops.is_empty():
		return otherwise
	if _stop_distances.has(stops):
		return _stop_distances[stops]
	var sum: float = 0.0
	for stop in stops:
		var p: PackedFloat32Array = _progress_frames(stop)
		var arrive: float = p[p.size() - 1] * ARRIVED
		var at: float = p[0]
		var t: float = 0.0
		var fast: bool = false
		while t < stop.length:
			var v: float = _clip_speed(stop, t)
			fast = fast or v >= top * SLOWING
			if fast and v < top * SLOWING:
				at = _progress(stop, t)
				break
			t += 1.0 / LocomotionClip.FPS
		sum += arrive - at
	var d: float = clampf(sum / stops.size(), STOP_DISTANCE_LEAST, STOP_DISTANCE_MOST)
	_stop_distances[stops] = d
	return d


## The second a clip's motion begins, a few frames ahead of it.
func _onset(clip: LocomotionClip) -> float:
	var t: float = 0.0
	while t < clip.length:
		if _clip_speed(clip, t) >= ONSET_SPEED:
			return maxf(t - 3.0 / LocomotionClip.FPS, 0.0)
		t += 1.0 / LocomotionClip.FPS
	return 0.0


## The second of a stop at which `metres` are left to its arrival.
func _time_left(clip: LocomotionClip, metres: float) -> float:
	var p: PackedFloat32Array = _progress_frames(clip)
	var whole: float = p[p.size() - 1]
	var arrive: float = whole * ARRIVED
	var goal: float = arrive - metres
	if goal <= p[0]:
		return 0.0
	for i in range(1, p.size()):
		if p[i] >= goal:
			var w: float = (goal - p[i - 1]) / maxf(p[i] - p[i - 1], 1e-5)
			return (i - 1 + w) / LocomotionClip.FPS
	return clip.length


## The second of `loop` whose legs are nearest `clip`'s at `at`.
func _matching_time(clip: StringName, at: float, loop: LocomotionClip) -> float:
	var best: float = 0.0
	var best_gap: float = INF
	var t: float = 0.0
	while t < loop.length:
		var gap: float = _pose_gap(clip, at, loop.clip, t)
		if gap < best_gap:
			best = t
			best_gap = gap
		t += 1.0 / LocomotionClip.FPS
	return best


## How far apart two clips' legs are at their times, radians summed.
func _pose_gap(a: StringName, at_a: float, b: StringName, at_b: float) -> float:
	var anim_a: Animation = _playback.get_animation(a)
	var anim_b: Animation = _playback.get_animation(b)
	if anim_a == null or anim_b == null:
		return 0.0
	var gap: float = 0.0
	for bone in MATCH_BONES:
		var path := NodePath("%GeneralSkeleton:" + bone)
		var ta: int = anim_a.find_track(path, Animation.TYPE_ROTATION_3D)
		var tb: int = anim_b.find_track(path, Animation.TYPE_ROTATION_3D)
		if ta < 0 or tb < 0:
			continue
		var qa: Quaternion = anim_a.rotation_track_interpolate(ta, at_a)
		var qb: Quaternion = anim_b.rotation_track_interpolate(tb, at_b)
		gap += qa.angle_to(qb)
	return gap


# --- lean ---------------------------------------------------------------------

func _lean_into(delta: float) -> void:
	if _body == null:
		return
	var yaw: float = _unit.rotation.y
	var rate: float = 0.0
	if not is_nan(_last_yaw) and delta > 0.0:
		rate = angle_difference(_last_yaw, yaw) / delta
	_last_yaw = yaw
	var want: float = 0.0
	if state == State.MOVING or state == State.STARTING or state == State.STOPPING:
		want = clampf(atan(_speed * rate / 9.8) * LEAN_SHARE, -LEAN_MOST, LEAN_MOST)
	_lean = lerpf(_lean, want, 1.0 - exp(-LEAN_RATE * delta))
	# Left (a positive turn) tips the head to the body's left, +X.
	_body.transform = Transform3D(Basis(Vector3.BACK, -_lean), Vector3.ZERO) * _body_rest
	_lead_into_turn()


## The head and chest turn to the route a little way on, ahead of the body.
func _lead_into_turn() -> void:
	if _turn_lead == null:
		return
	var lead: float = 0.0
	if state == State.MOVING or state == State.STARTING:
		var ahead: Vector3 = _unit.route_point_ahead(maxf(LEAD_NEAREST, _speed * LEAD_SECONDS))
		if ahead != Vector3.INF:
			var to: Vector3 = ahead - _unit.global_position
			to.y = 0.0
			var facing: Vector3 = _unit.visual_forward()
			facing.y = 0.0
			if to.length() > 0.2 and facing.length() > 0.01:
				lead = facing.signed_angle_to(to, Vector3.UP)
	_turn_lead.lead = lead
