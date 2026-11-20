class_name SimpleLocomotion
extends LocomotionDriver
## A humanoid's move as the idle, the walk and the run, and nothing else:
## the unit moves on its own curve and the loops' playback follows it. The
## animation serves the game, never the other way round.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion"). Made by
## UnitAnimator for a body whose LocomotionSet has `simple` on; the
## LocomotionSet's other clips (jog, starts, stops, turns) are not used.
##
## A move: the run fades in over the idle (BLEND_IN) as the unit comes up
## to the run's speed in ACCEL_TIME; it holds that speed, slowed while it
## swings round to face the way; near the end it brakes at BRAKE onto the
## point. What shows is a blend by speed: the walk alone up to its own
## speed, the run alone at the run's, the two mixed in step between (the
## walk a partner under the run, ClipPlayback, matched strike to strike by
## LocomotionClip.phase_at), weighed so the mix's stride covers the ground
## the unit does, its cadence between the two loops'. Below the walk's
## speed the walk plays slower, no slower than SLOWEST_RATE.
## The move is over the moment the unit reaches its point (lands: the point
## itself, not within the arrival tolerance), and the idle (or the unit's own rest, a drawn
## weapon's guard) fades in over BLEND_IDLE: nothing waits on a clip. A new
## order while moving goes on from the speed the unit has.
##
## Every number that shapes the feel is a constant here.

## Seconds from rest to the run's speed.
const ACCEL_TIME := 0.25
## How hard the unit brakes for its point, m/s^2 (from the run's 4.3 m/s:
## 0.9 m and 0.43 s).
const BRAKE := 10.0
## The slowest the unit closes the last centimetres at, m/s.
const ARRIVE_SPEED := 0.5
## Below the walk's speed the walk plays at the unit's speed over its own,
## no slower than this.
const SLOWEST_RATE := 0.6
## Crossfades: the idle into the run, the run into the idle.
const BLEND_IN := 0.2
const BLEND_IDLE := 0.25
## Facing further off the way than this slows the unit, down to SLOWEST at
## FROM + SPAN, while it swings round.
const FACING_SLOW_FROM := deg_to_rad(40.0)
const FACING_SLOW_SPAN := deg_to_rad(80.0)
const FACING_SLOWEST := 0.05

var _unit: Unit
var _playback: BodyAnimationTree
var _set: LocomotionSet
var _loop: LocomotionClip
## Shown under the run below the run's speed; null if unmarked (the run
## alone then, slowed).
var _walk: LocomotionClip
var _moving: bool = false
## The unit's speed, m/s.
var _v: float = 0.0


func _init(unit: Unit, playback: BodyAnimationTree, set: LocomotionSet) -> void:
	_unit = unit
	_playback = playback
	_set = set
	_loop = set.run if set.run else set.jog
	if set.walk and set.walk.marked() and _loop and _loop.marked() and set.walk.speed < _loop.speed:
		_walk = set.walk


func idle_clip() -> String:
	return String(_set.idle.clip) if _set.idle else ""


func drives() -> bool:
	return _moving


## Braked onto the point itself: ending at the arrival tolerance stopped
## the unit dead from 1.7 m/s.
func lands() -> bool:
	return _moving


func begin(_route: float, _first_leg: Vector3) -> void:
	if _loop == null:
		return
	if _moving and _playback.current_animation == _loop.clip:
		return
	_v = 0.0
	_playback.play(_loop.clip, BLEND_IN, SLOWEST_RATE)
	_moving = true
	_show(0.0)


func travel(delta: float, left: float) -> float:
	if _playback.current_animation != _loop.clip:
		# Something else is showing (a climb, a pose): the unit goes at its
		# own speed.
		_moving = false
		return _unit.move_speed * delta
	var top: float = _loop.speed
	var want: float = minf(top * _facing_share(), maxf(sqrt(2.0 * BRAKE * left), ARRIVE_SPEED))
	if _v < want:
		_v = minf(_v + top / ACCEL_TIME * delta, want)
	else:
		_v = maxf(_v - 2.0 * BRAKE * delta, want)
	_show(_v)
	return minf(_v * delta, left)


## The walk and run mixed for speed v: the run's share where their speeds
## blended give v, the run's playback at the blend's cadence.
func _show(v: float) -> void:
	if _walk == null:
		_playback.set_clip_speed(clampf(v / _loop.speed, SLOWEST_RATE, 1.0))
		return
	var share: float = clampf((v - _walk.speed) / (_loop.speed - _walk.speed), 0.0, 1.0)
	var natural: float = lerpf(_walk.speed, _loop.speed, share)
	var cadence: float = lerpf(1.0 / _walk.length, 1.0 / _loop.length, share) * clampf(v / natural, SLOWEST_RATE, 1.0)
	_playback.set_clip_speed(cadence * _loop.length)
	_playback.set_partner(_walk.clip, 1.0 - share, _in_step)


## The walk's time in step with the run at `run_time`.
func _in_step(run_time: float) -> float:
	return _walk.time_at(_loop.phase_at(run_time))


func tick(_delta: float) -> void:
	# Still under way with the unit stood still: the move ended without a
	# word (Unit.force_stop_movement).
	if _moving:
		finish()


func finish() -> bool:
	if not _moving:
		return false
	_moving = false
	_v = 0.0
	if not (rest.is_valid() and bool(rest.call(BLEND_IDLE))) and _set.idle:
		_playback.play(_set.idle.clip, BLEND_IDLE)
	return true


func abandon() -> void:
	_moving = false
	_v = 0.0


func relax(_delta: float) -> void:
	abandon()


## How much of its speed the unit may have while it swings round to the way.
func _facing_share() -> float:
	var way: Vector3 = _unit.first_leg()
	way.y = 0.0
	if way.length_squared() < 1e-6:
		return 1.0
	var facing: Vector3 = _unit.visual_forward()
	facing.y = 0.0
	if facing.length_squared() < 1e-6:
		return 1.0
	var off: float = facing.normalized().angle_to(way.normalized())
	return clampf(1.0 - (off - FACING_SLOW_FROM) / FACING_SLOW_SPAN, FACING_SLOWEST, 1.0)
