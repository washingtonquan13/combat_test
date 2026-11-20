class_name UnitLocomotion
extends LocomotionDriver
## How a humanoid walks a route: the clips of its LocomotionSet, shown to
## follow the unit as gameplay moves it, in the manner of Baldur's Gate 3.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion"). Made by
## UnitAnimator for a body whose CharacterModel has a `locomotion` set;
## UnitMovement asks it, every tick of a walk, how far the unit goes (travel)
## instead of going at move_speed.
##
## The unit leads and the clips follow (no root motion), and every clip
## plays at its own speed, 1x, always: the animation is never timed to the
## unit's speed. Gameplay owns where the unit goes and when it stops; the
## clips give it its speed:
##   - on a loop, the loop's own (the walk's 1.72 m/s, the run's 4.5);
##   - on a start or a stop, the clip's own over time, read off its root
##     (so the clip and the unit cover the same ground), a stop's scaled to
##     land on the route's end exactly;
##   - between, gameplay's own easing: the run slowing to the walk for the
##     route's end, the walk bending its speed (STEER_LEAST..MOST) to bring
##     its stride to a stop's on the right foot. The feet slide by that
##     difference; foot locking and stride warping are to take it up.
##
## A move goes (as BG3's do: the unit is under way within a frame of the
## order, whichever way it faces; it swings round as it steps off, at
## UnitFacing's rotation_speed, never standing to turn first):
##   STARTING  from rest into the run or the walk, by its start (its idle
##             lead-in skipped).
##   MOVING    the loop.
##   STOPPING  near the end, on the frame whose legs are nearest one of the
##             walk's stops (the stop or its mirror): that stop from its
##             first frame.
##   SETTLING  the route is done, the stop's settle plays on; it hands to the
##             idle on the idle's own frame.
## A run ends on the walk's stop: it holds its speed until WALK_ROOM (half a
## metre) of walk is left ahead of the stop's ground, brakes to the walk's
## speed, hands to the walk loop on the same point of the stride once halfway
## down, and the walk goes into the stop. Run To Stop (its skid throws a foot
## 0.6 m ahead, which then slides back) is used only by a set with no walk,
## which brakes to the stop's first speed and goes into it from the run.
## A new order while moving or stopping goes on at the same gait, except
## that a walk whose new route is WALK_UNDER or longer breaks into the run
## (by the run start, from its frame for the unit's speed); one while
## settling or turning in place starts at once. Routes under WALK_UNDER are
## walked, the rest run.
##
## Held (ClickRouter's hold-to-move sets `held` while the button is down):
## the orders are steering, not destinations. No stop is planned at the
## point; the unit slows only softly as it closes on it (STOPLESS_BRAKE), a
## walk breaks into the run at HELD_RUN_FROM, and a run drops to the walk
## only when the point is about 1.4 m off, so the gait does not flip with
## every new point. On release the last point is an ordinary end, stop and
## all.
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
## Seconds from rest to the loop's speed where no start says (no start, or
## after a stop is cut short).
const RUN_ACCEL_TIME := 0.3
const WALK_ACCEL_TIME := 0.25
## How fast a run slows for the walk at the end of its route, m/s^2.
const RUN_BRAKE := 5.0
## Metres of walk ahead of the stop a run's end leaves, for the walk to bring
## its stride to the stop's (about one stride: 2 m walked the last 3 m of a
## run and slowed play).
const WALK_ROOM := 0.5
## How far the walk's speed may be bent to land on a stop's stride, and from
## how far ahead of the stop it starts to, metres.
const STEER_LEAST := 0.8
const STEER_MOST := 1.2
const STEER_FROM := 5.0
## A stop is entered with this share of its own ground left, at the most and
## at the least (then, whatever the legs show).
const ENTER_MOST := 1.35
const ENTER_LEAST := 0.65
## A stop is entered on the frame its legs are nearest what shows, once they
## are within this (radians summed over MATCH_BONES).
const ENTER_GAP := 1.2
## Without stops (or held), how fast the unit slows for the end, m/s^2.
const STOPLESS_BRAKE := 4.0
## Held, a walk breaks into the run once its point is this far off, metres
## (a run drops to the walk at about 1.4 m: the gap keeps the gait steady).
const HELD_RUN_FROM := 3.0
## Held, the unit closes on its point as if it were this much nearer, metres:
## it trails a slow cursor instead of reaching the point between orders and
## starting again from rest.
const HELD_SHORT := 0.3
## Held, the most speed per metre the point is off (past HELD_SHORT), 1/s: a
## gentle line, so each step the point jumps ahead nudges the pace instead
## of swinging it (a steep braking curve did).
const HELD_FOLLOW := 2.0
## How hard the unit brakes when its speed is over what the end allows (an
## order changed under it, a hold let go), m/s^2.
const HARD_BRAKE := 15.0
## A turn of facing this large is a turn in place; less, UnitFacing's.
const TURN_FROM := deg_to_rad(60.0)
## The turn is done once this much of it is, and hands on.
const TURN_DONE := 0.92
## A turn is scaled to the angle wanted by no more or less than this.
const TURN_SCALE_LEAST := 0.5
const TURN_SCALE_MOST := 1.6
## The slowest the unit closes the last centimetres at, with no stop.
const ARRIVE_SPEED := 0.4
## Facing further off the way than this slows the unit, down to SLOWEST at
## FROM + SPAN, while it swings round.
const FACING_SLOW_FROM := deg_to_rad(40.0)
const FACING_SLOW_SPAN := deg_to_rad(80.0)
const FACING_SLOWEST := 0.05
## A start hands to the loop once its own speed is this share of the loop's.
const UP_TO_SPEED := 0.98
## A clip's motion begins where it first goes this fast, m/s.
const ONSET_SPEED := 0.3
## A stop goes on under a new order whose route is no longer than this
## share of the stop's ground still to cover, and that turns the way no more
## than STAY_TURN: the stop is scaled onto the new end.
const STAY_GROUND := 1.35
const STAY_TURN := deg_to_rad(45.0)
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

## The loop of the gait, its speed, and the stops that end it.
var _loop: LocomotionClip = null
var _top: float = 0.0
var _stops: Array[LocomotionClip] = []
## Whether this route is run, and whether the run ends by slowing to the
## walk (a set with no run stops) rather than on its own stops.
var _runs: bool = false
var _run_to_walk: bool = false
## The speed the stops begin at, on average (a run brakes to it).
var _entry_speed: float = 0.0
## The one-shot playing (start, stop) and how far into it, seconds: it plays
## at 1x, so this keeps time with it.
var _clip: LocomotionClip = null
var _clip_t: float = 0.0
## Seconds since the stop was entered (its blend in).
var _stop_in: float = 0.0
## The unit's speed, and how fast it comes up to the loop's.
var _v: float = 0.0
var _accel: float = 0.0
## The ground the walk's stops cover, on average.
var _stop_ground: float = 0.0
## Each stop's second of the walk whose legs are nearest the stop's first
## frame (steering aims at them).
var _entry_phase: Dictionary = {}
## The walk seconds still to play to the stride steering aims at, and the
## walk's position when last counted (-1: none aimed at yet).
var _steer_left: float = -1.0
var _steer_at: float = 0.0
## The nearest the stops' legs were to what showed last tick (entering on
## the frame they are nearest).
var _last_gap: float = INF
## How far the stop's legs were from the pose showing as it was entered,
## degrees summed (for the demo).
var entry_gap: float = 0.0
## Per clip, its progress along its own way on each frame, metres.
var _ground := {}

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
## A move ordered during a turn in place: it starts as the turn ends.
var _go_after_turn: bool = false


func _init(unit: Unit, playback: BodyAnimationTree, set: LocomotionSet, body: Node3D) -> void:
	_unit = unit
	_playback = playback
	_set = set
	_body = body
	if _body:
		_body_rest = _body.transform
		var skeletons: Array[Node] = _body.find_children("*", "Skeleton3D", true, false)
		if not skeletons.is_empty():
			foot_lock = BodyFootLock.attach(skeletons[0] as Skeleton3D)
			_turn_lead = BodyTurnLead.attach(skeletons[0] as Skeleton3D)


## Held: the order is steering (hold-to-move), with no stop at its end.
func _held_changed() -> void:
	_steer_left = -1.0
	_last_gap = INF


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


## Whether a stop is carrying the unit onto its end (UnitMovement arrives
## on the point itself then, not within its arrival tolerance).
func lands() -> bool:
	return state == State.STOPPING


## Whether a turn in place is turning the unit (UnitFacing keeps off it).
func turning() -> bool:
	return state == State.TURNING


func begin(route: float, first_leg: Vector3) -> void:
	_route = route
	if (state == State.STARTING or state == State.MOVING or state == State.STOPPING) and _loop:
		# An order replaced mid-move: a walk with far to go breaks into the
		# run; otherwise on at the same gait.
		if _loop == _set.walk and route >= (HELD_RUN_FROM if held else WALK_UNDER) and _set.jog != null:
			_break_into_run()
		elif state == State.STOPPING and _stop_takes(route, first_leg):
			# Near enough the same end: the stop scales onto it.
			return
		elif state == State.STOPPING:
			_play_loop(_loop, _playback.current_animation, _clip_t)
		_last_gap = INF
		_steer_left = -1.0
		return
	# Turning in place: the turn is aimed at the way and plays out, and the
	# start follows it (travel() holds the unit still meanwhile). Dropping
	# it where it was played the start facing sideways.
	if state == State.TURNING and _clip and first_leg.length_squared() > 0.5:
		_aim_turn(_unit.yaw_facing(first_leg))
		_go_after_turn = true
		return
	# Standing: under way now.
	_v = 0.0
	_start_moving(BLEND_START)


## Whether the stop playing can land on a new end `route` metres off whose
## way is `first_leg`: about as near as its own ground still to cover, and
## about ahead.
func _stop_takes(route: float, first_leg: Vector3) -> bool:
	if held or _clip == null:
		return false
	var p: PackedFloat32Array = _progress_frames(_clip)
	var still: float = p[p.size() - 1] * ARRIVED - _progress(_clip, _clip_t)
	if still <= 1e-3 or route > still * STAY_GROUND:
		return false
	var facing: Vector3 = _unit.visual_forward()
	facing.y = 0.0
	var way := Vector3(first_leg.x, 0.0, first_leg.z)
	if route < 0.05 or way.length_squared() < 1e-6 or facing.length_squared() < 1e-6:
		return true
	return facing.angle_to(way) <= STAY_TURN


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
	var start: LocomotionClip = _take_gait(_route >= (HELD_RUN_FROM if held else WALK_UNDER) and _set.jog != null)
	_v = 0.0
	if start:
		_play_clip(start, blend, _onset(start))
		state = State.STARTING
		return
	_playback.play(_loop.clip, BLEND_WALK_IN)
	state = State.MOVING


## The gait's loop, its speed and stops; returns its start (null for none).
func _take_gait(runs: bool) -> LocomotionClip:
	_runs = runs
	_loop = (_set.run if _set.run else _set.jog) if runs else _set.walk
	_top = _loop.speed
	_accel = _top / (RUN_ACCEL_TIME if runs else WALK_ACCEL_TIME)
	# Runs end on the walk's stop; on Run To Stop only for a set with no walk.
	_run_to_walk = runs and _set.walk != null and not _set.walk_stops.is_empty()
	if runs and not _run_to_walk and not _set.jog_stops.is_empty():
		_stops = _set.jog_stops
	else:
		_stops = _set.walk_stops if _set.walk != null else _set.jog_stops
	_stop_ground = 0.0
	_entry_speed = 0.0
	for stop in _stops:
		_stop_ground += _stop_ground_of(stop) / _stops.size()
		_entry_speed += _clip_speed(stop, 0.0) / _stops.size()
	_entry_phase.clear()
	_steer_left = -1.0
	_last_gap = INF
	# Steering (the walk's) aims at the walk second each stop enters on.
	if _stops == _set.walk_stops and _set.walk != null:
		for stop in _stops:
			_entry_phase[stop] = _matching_time(stop.clip, 0.0, _set.walk)
	return _set.jog_start if runs else _set.walk_start


## Walking, a new order far enough to run: into the run start on its frame
## for the unit's speed now (past its lead-in), which comes up to speed and
## hands to the run loop as from rest; or straight to the loop with none.
func _break_into_run() -> void:
	var from: StringName = _playback.current_animation
	var at: float = _clip_t if state != State.MOVING else _playback.current_animation_position
	var start: LocomotionClip = _take_gait(true)
	if start == null:
		_play_loop(_loop, from, at)
		return
	var t: float = _onset(start)
	while t < start.length - BLEND_HAND and _clip_speed(start, t) < _v:
		t += 1.0 / LocomotionClip.FPS
	_play_clip(start, BLEND_HAND, t)
	state = State.STARTING


## How far along its route the unit goes this tick, `left` metres from its
## end. Called by UnitMovement on every grounded walking tick.
func travel(delta: float, left: float) -> float:
	_ticked = Engine.get_physics_frames()
	if not _still_showing():
		# Something else is showing (a climb, a pose): the unit goes at its
		# own speed, and the lean, the lead and the plants come off.
		state = State.OFF
		_go_after_turn = false
		_speed = 0.0
		_lean_into(delta, false)
		return _unit.move_speed * delta
	if state == State.TURNING:
		_turning()
		_speed = 0.0
		_lean_into(delta)
		return 0.0
	var step: float = 0.0
	match state:
		State.STARTING:
			step = _starting(delta, left)
		State.MOVING:
			step = _moving(delta, left)
		State.STOPPING:
			step = _stopping(delta, left)
	step = clampf(step, 0.0, left)
	if state == State.STARTING or state == State.MOVING:
		_maybe_enter_stop(left - step)
	_speed = step / maxf(delta, 1e-4)
	_lean_into(delta)
	return step


## A tick with no walk: the settle after a stop, the lean coming upright.
func tick(delta: float) -> void:
	if _ticked == Engine.get_physics_frames():
		return
	_ticked = Engine.get_physics_frames()
	_speed = 0.0
	# Still under way with the unit stood still: the move ended without a
	# word (Unit.force_stop_movement, as area travel does it; then the unit
	# is put down elsewhere). It ends as a move cut short does.
	if state == State.STARTING or state == State.MOVING:
		finish()
	elif state == State.STOPPING:
		state = State.SETTLING
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
	_go_after_turn = false
	match state:
		State.STOPPING:
			state = State.SETTLING
			return true
		State.SETTLING:
			return true
		State.TURNING:
			# The turn plays out into the idle.
			return true
		State.STARTING, State.MOVING:
			# Cut short of a stop: back to the rest.
			if not _rest(BLEND_IDLE):
				_playback.play(StringName(idle_clip()), BLEND_IDLE)
			state = State.OFF
			return true
	return false


## Something else takes the body (a stance, a cast, a cutscene, a pose,
## death, a climb). The lean, the lead into the turn and the foot pins come
## off by relax(), each tick the body is not locomotion's.
func abandon() -> void:
	state = State.OFF
	_v = 0.0
	_go_after_turn = false


## A tick while the body is not locomotion's (UnitAnimator: posed, dead,
## claimed by a scene, or on a move it does not show): it lets go of the
## body. The lean comes upright, the head's lead comes back and the feet
## are unpinned, each at its own rate, rather than left as they were.
func relax(delta: float) -> void:
	if _ticked == Engine.get_physics_frames():
		return
	_ticked = Engine.get_physics_frames()
	if state != State.OFF:
		abandon()
	_speed = 0.0
	_lean_into(delta, false)


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


## The most speed the unit may have `left` metres from the end. A run slows
## at RUN_BRAKE to the walk's speed WALK_ROOM ahead of the walk's stop (or, a
## set with no walk, to its run stops' first speed as it reaches their
## ground); with no stops, or held, the unit slows to nothing on the end.
func _speed_cap(left: float) -> float:
	if held:
		return maxf(minf(HELD_FOLLOW * maxf(left - HELD_SHORT, 0.0), sqrt(2.0 * STOPLESS_BRAKE * left)), ARRIVE_SPEED)
	if _stops.is_empty():
		return maxf(sqrt(2.0 * STOPLESS_BRAKE * left), ARRIVE_SPEED)
	if not _runs:
		return INF
	if _run_to_walk:
		var walk: float = _set.walk.speed
		return sqrt(walk * walk + 2.0 * RUN_BRAKE * maxf(left - _stop_ground - WALK_ROOM, 0.0))
	return sqrt(_entry_speed * _entry_speed + 2.0 * RUN_BRAKE * maxf(left - _stop_ground, 0.0))


## Whether the run is to hand to the walk now, at `cap` and speed `v`: a run
## ending on the walk's stop, or a held run whose point has come close.
func _drops_to_walk(cap: float, v: float) -> bool:
	if not _runs or _loop == _set.walk or _set.walk == null:
		return false
	if not (_run_to_walk or held):
		return false
	# At the geometric middle of the two stride warps' limits: the run
	# warped no slower than STRIDE_LEAST and the walk no faster than
	# STRIDE_MOST cannot both hold at any one speed (3.0 m/s and 2.46), so
	# each is bent by the same ratio past its limit.
	var hand: float = sqrt(_top * BodyFootLock.STRIDE_LEAST * _set.walk.speed * BodyFootLock.STRIDE_MOST)
	return cap < _top and v <= hand


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
	if _go_after_turn:
		_go_after_turn = false
		_start_moving(BLEND_START)
		return
	_settle_into_idle(t)


## The start at 1x, the unit going at its own speed on each frame. Up to the
## loop's speed, or out of start, it hands to the loop on the frame whose
## legs match.
func _starting(delta: float, left: float) -> float:
	var t0: float = _clip_t
	_clip_t += delta
	var own: float = (_progress(_clip, _clip_t) - _progress(_clip, t0)) / maxf(delta, 1e-4)
	_v = minf(maxf(own, 0.0) * _facing_share(), _speed_cap(left))
	if _drops_to_walk(_speed_cap(left), _speed_cap(left)):
		# A run too short to reach its speed: on to the walk.
		_hand_run_to_walk()
	elif _clip_speed(_clip, _clip_t) >= _top * UP_TO_SPEED or _clip_t >= _clip.length - BLEND_HAND:
		_play_loop(_loop, _clip.clip, _clip_t)
	return _v * delta


## The loop at 1x. The unit comes up to the loop's speed (bent by steering,
## on the walk), and on a run slows for the end, handing to the walk once
## halfway down to its speed.
func _moving(delta: float, left: float) -> float:
	var cap: float = _speed_cap(left)
	if _drops_to_walk(cap, _v):
		_hand_run_to_walk()
		cap = _speed_cap(left)
	var want: float = _top * _facing_share()
	if _loop == _set.walk and not _stops.is_empty() and not held:
		want = minf(want, _steer_speed(left))
	want = minf(want, cap)
	if _v < want:
		_v = minf(_v + _accel * delta, want)
	else:
		_v = maxf(_v - RUN_BRAKE * delta, want)
	# Over the cap (the end came nearer, a hold let go): brake hard onto it
	# rather than snap. Held, the point jumps ahead in steps and the cap with
	# it: braking at RUN_BRAKE alone keeps the pace from following the teeth.
	if _v > cap and not held:
		_v = maxf(_v - HARD_BRAKE * delta, cap)
	return _v * delta


## The run handed to the walk loop on the same point of the stride (by their
## strikes if marked, else the nearest legs; from the run start, the nearest
## legs): at the end of a run that ends on the walk's stop, or held with the
## point close, when the walk is taken as the gait, stops and all.
func _hand_run_to_walk() -> void:
	var run: LocomotionClip = _clip if state == State.STARTING else _loop
	var at: float = _clip_t if state == State.STARTING else _playback.current_animation_position
	var from_loop: bool = state == State.MOVING
	if _run_to_walk:
		_loop = _set.walk
		_top = _loop.speed
		_accel = _top / WALK_ACCEL_TIME
	else:
		_take_gait(false)
	if from_loop and run.marked() and _loop.marked():
		_playback.play(_loop.clip, BLEND_HAND)
		_playback.seek(_loop.time_at(run.phase_at(at)))
		state = State.MOVING
	else:
		_play_loop(_loop, run.clip, at)
	_steer_left = -1.0
	_last_gap = INF


## The walk's speed that brings it onto a stop's stride as it reaches the
## stop's ground: steering aims at the nearest second of the walk some stop
## enters on (nearest as a ratio, so a little faster and a little slower weigh
## alike) and keeps to it, counting down the walk seconds played, so the aim
## never flips between strides.
func _steer_speed(left: float) -> float:
	var to_entry: float = left - _stop_ground
	if to_entry <= 0.0 or to_entry > STEER_FROM or _entry_phase.is_empty():
		_steer_left = -1.0
		return INF
	var length: float = _loop.length
	var now: float = _playback.current_animation_position
	if _steer_left < 0.0:
		var natural: float = to_entry / _loop.speed
		var best_off: float = INF
		for stop in _entry_phase:
			var ahead: float = fposmod(float(_entry_phase[stop]) - now, length)
			for k in 4:
				var want: float = ahead + k * length
				if want <= 0.05:
					continue
				var off: float = absf(log(want / natural))
				if off < best_off:
					best_off = off
					_steer_left = want
	else:
		_steer_left = maxf(_steer_left - fposmod(now - _steer_at, length), 0.0)
	_steer_at = now
	if _steer_left <= 0.02:
		return _loop.speed
	return clampf(to_entry / _steer_left, _loop.speed * STEER_LEAST, _loop.speed * STEER_MOST)


## Near the end, into the stop whose first frame's legs are nearest what
## shows, on the frame they are nearest (once close enough); short of
## ENTER_LEAST of its ground, whatever shows. Not from a run that ends on the
## walk's stop (it slows to the walk first) unless forced; never held.
func _maybe_enter_stop(left: float) -> void:
	if _stops.is_empty() or _stop_ground <= 1e-3 or held:
		return
	if left > _stop_ground * ENTER_MOST:
		_last_gap = INF
		return
	var forced: bool = left <= _stop_ground * ENTER_LEAST
	var on_walk: bool = not _run_to_walk or _loop == _set.walk
	if not on_walk and not forced:
		return
	var from: StringName = _playback.current_animation
	var at: float = _clip_t if state == State.STARTING else _playback.current_animation_position
	var best: LocomotionClip = null
	var best_gap: float = INF
	for stop in _stops:
		var gap: float = _pose_gap(from, at, stop.clip, 0.0)
		if gap < best_gap:
			best = stop
			best_gap = gap
	# The frame before was the nearest: the gap has begun to grow.
	var passed: bool = _last_gap < INF and best_gap > _last_gap and _last_gap <= ENTER_GAP
	_last_gap = best_gap
	if not (passed or forced):
		return
	_clip = best
	entry_gap = rad_to_deg(best_gap)
	_play_clip(best, BLEND_STOP, 0.0)
	_stop_in = 0.0
	state = State.STOPPING


## The stop at 1x. The unit covers the ground left in step with the stop's
## own: each tick its share of what the stop has still to cover, so it lands
## on the end as the stop arrives. Over the blend in it eases from the speed
## it came in at.
func _stopping(delta: float, left: float) -> float:
	var t0: float = _clip_t
	_clip_t += delta
	_stop_in += delta
	var p: PackedFloat32Array = _progress_frames(_clip)
	var arrive: float = p[p.size() - 1] * ARRIVED
	var still: float = arrive - _progress(_clip, t0)
	var step: float = left
	if still > 1e-3:
		step = left * clampf((_progress(_clip, _clip_t) - _progress(_clip, t0)) / still, 0.0, 1.0)
	var w: float = clampf(_stop_in / BLEND_STOP, 0.0, 1.0)
	step = lerpf(_v * delta, step, w)
	if w >= 1.0:
		_v = step / maxf(delta, 1e-4)
	return step


func _hand_to_idle_near_end() -> void:
	var t: float = _playback.current_animation_position
	if t < _clip.length - BLEND_IDLE or _set.idle == null:
		return
	_settle_into_idle(t)


## A stop or turn `t` seconds in, handed on to the rest: the unit's own (a
## drawn weapon's guard), else the set's idle on the frame the clip leaves
## it at.
func _settle_into_idle(t: float) -> void:
	state = State.OFF
	if _rest(BLEND_IDLE) or _set.idle == null:
		return
	_playback.play(_set.idle.clip, BLEND_IDLE)
	_playback.seek(fposmod(_clip.leaves_at - (_clip.length - t), _set.idle.length))


## The unit's own rest, if it has one other than the set's idle.
func _rest(blend: float) -> bool:
	return rest.is_valid() and bool(rest.call(blend))


## A start or stop from `at` seconds, at 1x, timed by _clip_t.
func _play_clip(clip: LocomotionClip, blend: float, at: float) -> void:
	_clip = clip
	_clip_t = at
	_playback.play(clip.clip, blend)
	_playback.seek(at)


## Onto `loop` at 1x on the frame whose legs match `from`'s at `at`.
func _play_loop(loop: LocomotionClip, from: StringName, at: float) -> void:
	var t: float = _matching_time(from, at, loop)
	_loop = loop
	_playback.play(loop.clip, BLEND_HAND)
	_playback.seek(t)
	state = State.MOVING


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


## The second a clip's motion begins, a few frames ahead of it.
func _onset(clip: LocomotionClip) -> float:
	var t: float = 0.0
	while t < clip.length:
		if _clip_speed(clip, t) >= ONSET_SPEED:
			return maxf(t - 3.0 / LocomotionClip.FPS, 0.0)
		t += 1.0 / LocomotionClip.FPS
	return 0.0


## The ground a stop covers from its first frame to its arrival.
func _stop_ground_of(stop: LocomotionClip) -> float:
	var p: PackedFloat32Array = _progress_frames(stop)
	return maxf(p[p.size() - 1] * ARRIVED - p[0], 0.0)


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

func _lean_into(delta: float, plant: bool = true) -> void:
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
	_plant_feet(plant)


## Tells the foot lock how planted each foot is in the clip showing: the
## loop on its own clock, a start or stop on _clip_t, a turn or the settle
## on the player's. OFF, the set's idle is read while it shows, so the feet
## a stop or turn plants stay where it planted them (the idle's own stance
## is 11-13 cm off the stops'; blending to it would slide them). Nothing
## else locks off locomotion (a stance, a cast, the turning loops).
func _plant_feet(plant: bool = true) -> void:
	if foot_lock == null:
		return
	if not plant:
		foot_lock.left_plant = 0.0
		foot_lock.right_plant = 0.0
		foot_lock.stride = 1.0
		return
	foot_lock.ground_y = _unit.global_position.y
	var clip: LocomotionClip = _loop if state == State.MOVING else _clip
	if state == State.OFF and _set.idle != null and _playback.current_animation == _set.idle.clip:
		clip = _set.idle
	# The stride is warped along the way the unit goes, which leads its
	# facing as it swings round.
	var way: Vector3 = _unit.first_leg() if _unit.is_moving() else Vector3.ZERO
	way.y = 0.0
	foot_lock.forward = way.normalized() if way.length_squared() > 1e-6 else _unit.visual_forward()
	# The loop plays at 1x while the unit goes at its own speed: the stride
	# is warped to it. Starts and stops give the unit their own speed.
	foot_lock.stride = _speed / _loop.speed if state == State.MOVING and _loop and _loop.speed > 0.1 else 1.0
	if (state == State.OFF and clip != _set.idle) or clip == null or _playback.current_animation != clip.clip:
		foot_lock.left_plant = 0.0
		foot_lock.right_plant = 0.0
		return
	var at: float = _clip_t if state == State.STARTING or state == State.STOPPING else _playback.current_animation_position
	foot_lock.left_plant = clip.plant_at(true, at)
	foot_lock.right_plant = clip.plant_at(false, at)


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
