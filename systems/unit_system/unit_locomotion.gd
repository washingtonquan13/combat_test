class_name UnitLocomotion
extends RefCounted
## How a humanoid walks a route: the clips of its LocomotionSet, and the
## ground they cover, in the shape of Baldur's Gate 3's gameplay set.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion"). Made by
## UnitAnimator for a body whose CharacterModel has a `locomotion` set;
## UnitMovement asks it, every tick of a walk, how far the unit goes
## (travel) instead of going at move_speed. So the feet and the ground agree:
## the walk and the jog go at their loop's own speed, a start and a stop
## move the unit by their own root curve.
##
## A move goes:
##   TURNING   the first leg is well off the unit's facing: a turn in place,
##             the unit held where it stands and turned by the clip's own yaw
##             (scaled to the angle wanted).
##   STARTING  into the jog, by the run start; a walk blends in from the idle.
##   MOVING    the loop. Ahead of the end it picks the stop whose own frame of
##             the loop, played on at a speed near the loop's, brings the stop
##             to cover exactly what is left, and plays the loop at that speed.
##   STOPPING  the stop, moving the unit by its curve (scaled to fit) until
##             the route ends.
##   SETTLING  the route is done, the stop's settle plays on; it hands to the
##             idle on the idle's own frame.
## A route too short for any stop walks and blends back to the idle as the
## animator always did. Never in the air, on a ladder or on a wall: those keep
## their own clips and move_speed.
##
## While the unit moves the body leans into its turns (lean), a roll of the
## body about its forward axis, from speed times turn rate.

enum State { OFF, TURNING, STARTING, MOVING, STOPPING, SETTLING }

## A first leg further off the facing than this turns in place first.
const TURN_MIN := deg_to_rad(35.0)
## The turn hands to the start once this much of it is done; facing does the rest.
const TURN_DONE := 0.9
## A path at least this much longer than the run start and the shortest jog
## stop is jogged; anything shorter is walked.
const JOG_SPARE := 0.5
## A walk shorter than its shortest stop and this has no stop.
const SHORT_SPARE := 0.2
## Crossfades: into the turn, the walk from rest, a handover between clips.
const BLEND_TURN := 0.2
const BLEND_WALK_IN := 0.4
const BLEND_HAND := 0.25
const BLEND_STOP := 0.12
const BLEND_IDLE := 0.3
## The walk's speed (and play rate) comes up from this share over RAMP
## seconds of its blend from the idle.
const RAMP := 0.4
const RAMP_FROM := 0.5
## Seconds before a stop under which its fit is no longer adjusted.
const REFIT_UNTIL := 0.5
## How far off the loop's own speed a stop may play the loop on to fit.
const FIT_GOOD := 0.08
const FIT_MOST := 0.35
## The furthest ahead a stop is chosen, seconds.
const PLAN_AHEAD := 6.0
## A stop's ground is covered once this much of its travel is done; the
## rest is its settle, which plays after the route ends.
const ARRIVED := 0.97
## Lean: degrees at most, of what a body really leans (tan = speed x turn
## rate / g), and how fast it follows.
const LEAN_MOST := deg_to_rad(8.0)
const LEAN_SHARE := 0.35
const LEAN_RATE := 6.0

var state: State = State.OFF

var _unit: Unit
var _playback: BodyAnimationTree
var _set: LocomotionSet
## The body node leaned (the model's glb root), and its own place.
var _body: Node3D
var _body_rest := Transform3D.IDENTITY

var _loop: LocomotionClip = null
var _stops: Array[LocomotionClip] = []
## The one-shot playing (turn, start, stop) and seconds into it.
var _clip: LocomotionClip = null
var _t: float = 0.0
## Seconds into the loop, by this clock (the playback's when it shows it).
var _phase: float = 0.0
## The loop's play speed, near 1, that makes the chosen stop fit.
var _k: float = 1.0
var _ramp: float = 1.0
## The chosen stop and loop seconds left before it.
var _stop: LocomotionClip = null
var _wait: float = 0.0
## A route too short for any stop.
var _short: bool = false
## Turn: the unit's yaw at the start, and the share of the clip's turn wanted.
var _yaw_from: float = 0.0
var _turn_scale: float = 1.0
## Stop: the route left when it began, the clip's progress at its arrival.
var _stop_route: float = 0.0
var _stop_done: float = 0.0
var _stop_arrive: float = 0.0
var _covered: float = 0.0

var _lean: float = 0.0
var _last_yaw: float = NAN
var _speed: float = 0.0
var _ticked: int = -1


func _init(unit: Unit, playback: BodyAnimationTree, set: LocomotionSet, body: Node3D) -> void:
	_unit = unit
	_playback = playback
	_set = set
	_body = body
	if _body:
		_body_rest = _body.transform


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


## Whether the unit is held facing as the turn says, not the path.
func holds_facing() -> bool:
	return state == State.TURNING


## A move starts: `route` metres to go, `first_leg` the way it leaves.
func begin(route: float, first_leg: Vector3) -> void:
	var jogs: bool = _set.jog_start != null and not _set.jog_stops.is_empty() \
		and route >= _set.jog_start.travel + _shortest(_set.jog_stops) + JOG_SPARE
	var loop: LocomotionClip = _set.jog if jogs else _set.walk
	var stops: Array[LocomotionClip] = _set.jog_stops if jogs else _set.walk_stops
	# Too short for any stop: walked, and blended to the idle at the end.
	_short = stops.is_empty() or route < _shortest(stops) + SHORT_SPARE
	# Already going that way at that gait (an order replaced mid-walk): go on.
	if (state == State.MOVING or state == State.STARTING) and loop == _loop:
		_stops = stops
		_stop = null
		_k = 1.0
		return
	_loop = loop
	_stops = stops
	_stop = null
	_k = 1.0
	first_leg.y = 0.0
	var want: float = atan2(first_leg.x, first_leg.z)
	var off: float = angle_difference(_unit.rotation.y, want)
	var turn: LocomotionClip = _set.turn_for(off) if first_leg.length_squared() > 1e-6 else null
	if turn and absf(off) > TURN_MIN and absf(turn.turn) > 0.01:
		_clip = turn
		_t = 0.0
		_yaw_from = _unit.rotation.y
		_turn_scale = off / turn.turn
		_playback.play(turn.clip, BLEND_TURN)
		state = State.TURNING
		return
	_start(BLEND_TURN)


func _start(blend: float) -> void:
	if _loop == _set.jog and _set.jog_start:
		_clip = _set.jog_start
		_t = 0.0
		_playback.play(_clip.clip, blend)
		state = State.STARTING
		return
	_phase = 0.0
	_ramp = 0.0 if state == State.OFF or state == State.SETTLING or state == State.TURNING else 1.0
	_playback.play(_loop.clip, maxf(blend, BLEND_WALK_IN))
	state = State.MOVING


## How far along its route the unit goes this tick, `left` metres from its
## end. Called by UnitMovement on every grounded walking tick.
func travel(delta: float, left: float) -> float:
	_ticked = Engine.get_physics_frames()
	if not _still_showing():
		state = State.OFF
		return _unit.move_speed * delta
	var step: float = 0.0
	match state:
		State.TURNING:
			step = _turning(delta)
		State.STARTING:
			step = _starting(delta, left)
		State.MOVING:
			step = _moving(delta, left)
		State.STOPPING:
			step = _stopping(delta, left)
	_speed = step / maxf(delta, 1e-4)
	_lean_into(delta)
	return step


## A tick with no walk: the settle after a stop, the lean coming upright.
func tick(delta: float) -> void:
	if _ticked == Engine.get_physics_frames():
		return
	_ticked = Engine.get_physics_frames()
	_speed = 0.0
	if state == State.SETTLING:
		if not _still_showing():
			state = State.OFF
		else:
			_t += delta
			_hand_to_idle_near_end()
	_lean_into(delta)


## The move is over (arrived, stopped short or replaced by nothing). Returns
## whether this shows what comes next (the stop's settle, or the idle).
func finish() -> bool:
	match state:
		State.STOPPING:
			state = State.SETTLING
			return true
		State.SETTLING:
			return true
		State.TURNING, State.STARTING, State.MOVING:
			# Cut short of a stop: back to the idle.
			_playback.play(StringName(idle_clip()), BLEND_IDLE)
			state = State.OFF
			return true
	return false


## Something else takes the body (a stance, a cast, a cutscene).
func abandon() -> void:
	state = State.OFF


func _still_showing() -> bool:
	var want: LocomotionClip = _loop if state == State.MOVING else _clip
	return want != null and _playback.current_animation == want.clip


# --- states -------------------------------------------------------------------

func _turning(delta: float) -> float:
	_t += delta
	var at: float = clampf(_t * LocomotionClip.FPS, 0.0, _clip.root_yaws.size() - 1)
	var i: int = mini(floori(at), maxi(_clip.root_yaws.size() - 2, 0))
	var yaw: float = lerpf(_clip.root_yaws[i], _clip.root_yaws[mini(i + 1, _clip.root_yaws.size() - 1)], at - i)
	_unit.rotation.y = _yaw_from + yaw * _turn_scale
	if absf(yaw) >= absf(_clip.turn) * TURN_DONE or _t >= _clip.length - BLEND_HAND:
		_start(BLEND_HAND)
	return 0.0


func _starting(delta: float, left: float) -> float:
	var from: float = _progress(_clip, _t)
	_t += delta
	var step: float = _progress(_clip, _t) - from
	if _t >= _clip.length - BLEND_HAND:
		# Onto the jog on its own frame of the loop.
		_phase = fposmod(_clip.leaves_at, _loop.length)
		_ramp = 1.0
		_playback.play(_loop.clip, BLEND_HAND)
		_playback.seek(_phase)
		state = State.MOVING
	return minf(step, left)


func _moving(delta: float, left: float) -> float:
	if _playback.current_animation == _loop.clip:
		_phase = _playback.current_animation_position
	_ramp = minf(1.0, _ramp + delta / RAMP)
	if _stop == null:
		_plan_stop(left)
		if state != State.MOVING:
			# The stop began at once: it moves the unit from the next tick.
			return 0.0
	elif _wait > REFIT_UNTIL:
		# Keep the chosen stop fitting what is left as the route really goes.
		# Not in its last moments, where a centimetre is a large change of
		# speed: the stop's own scaling to the route takes what is left.
		var run: float = _wait * _loop.speed
		_k = clampf((left - _stop.travel) / maxf(run, 1e-3), 1.0 - FIT_MOST, 1.0 + FIT_MOST)
	# Coming up from the idle the loop plays slower as well as goes slower,
	# so the feet keep to the ground.
	var rate: float = _k * lerpf(RAMP_FROM, 1.0, _ramp)
	_playback.set_clip_speed(rate)
	var seconds: float = delta * rate
	if _stop != null:
		_wait -= seconds
		if _wait <= 0.0:
			var over: float = -_wait
			_begin_stop(left, over)
			return minf(_loop.speed * (seconds - over), left)
	return _loop.speed * seconds


## Picks, once one fits, the stop whose frame of the loop comes up at the
## right distance from the end, and the loop speed that makes it fit.
func _plan_stop(left: float) -> void:
	if _short or _stops.is_empty() or _loop.speed <= 0.0:
		return
	var best: LocomotionClip = null
	var best_wait: float = 0.0
	var best_k: float = INF
	# A stop enters on its frame of every stride of the loop.
	var stride: float = _loop.length / maxi(_loop.strides, 1)
	for stop in _stops:
		var wait: float = fposmod(stop.enters_at - _phase, stride)
		while wait <= PLAN_AHEAD:
			if wait > 1e-3:
				var k: float = (left - stop.travel) / (wait * _loop.speed)
				if absf(k - 1.0) < absf(best_k - 1.0):
					best = stop
					best_wait = wait
					best_k = k
			wait += stride
	if best == null:
		return
	var soon: bool = (left - _shortest(_stops)) / _loop.speed < 1.0
	if absf(best_k - 1.0) <= FIT_GOOD or soon:
		_stop = best
		_wait = best_wait
		_k = clampf(best_k, 1.0 - FIT_MOST, 1.0 + FIT_MOST)
		if left <= _stop.travel:
			_begin_stop(left, 0.0)


func _begin_stop(left: float, into: float) -> void:
	_clip = _stop
	_t = into
	_k = 1.0
	_playback.play(_clip.clip, BLEND_STOP)
	_playback.seek(_t)
	_stop_route = left
	_stop_done = _progress(_clip, _clip.length)
	_stop_arrive = _arrival(_clip)
	_covered = _progress(_clip, _t)
	state = State.STOPPING


func _stopping(delta: float, left: float) -> float:
	_t += delta
	_hand_to_idle_near_end()
	if _t >= _stop_arrive:
		return left
	var now: float = _progress(_clip, _t)
	var step: float = (now - _covered) * _stop_route / maxf(_stop_done, 1e-3)
	_covered = now
	return maxf(step, 0.0)


func _hand_to_idle_near_end() -> void:
	if _t < _clip.length - BLEND_IDLE or _set.idle == null:
		return
	_playback.play(_set.idle.clip, BLEND_IDLE)
	_playback.seek(fposmod(_clip.leaves_at - (_clip.length - _t), _set.idle.length))
	# Any route still left (centimetres) is walked under the idle at move_speed.
	state = State.OFF


# --- the clips' ground --------------------------------------------------------

## How far along its own way a clip has gone `seconds` in, metres.
static func _progress(clip: LocomotionClip, seconds: float) -> float:
	var end: Vector3 = clip.root_at(clip.length).origin
	var way := Vector3(end.x, 0.0, end.z)
	if way.length_squared() < 1e-6:
		return 0.0
	var at: Vector3 = clip.root_at(seconds).origin
	return Vector3(at.x, 0.0, at.z).dot(way.normalized())


## The first second a clip has covered ARRIVED of its ground.
static func _arrival(clip: LocomotionClip) -> float:
	var whole: float = _progress(clip, clip.length)
	var t: float = 0.0
	while t < clip.length:
		if _progress(clip, t) >= whole * ARRIVED:
			return t
		t += 1.0 / LocomotionClip.FPS
	return clip.length


static func _shortest(stops: Array[LocomotionClip]) -> float:
	var least: float = INF
	for stop in stops:
		least = minf(least, stop.travel)
	return least


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
