class_name LocomotionSet
extends Resource
## A humanoid body's locomotion clips, in the shape of Baldur's Gate 3's
## gameplay set: an idle, a walk and a jog loop; a start into the jog (a walk
## blends in from the idle, as BG3's does); walk stops for each foot at the
## end of a swing, on contact and passing; jog stops for each foot; turns in
## place left and right; a turning loop each way.
##
## Every clip plays in place and carries the ground it covers
## (LocomotionClip). The humanoid set is data/locomotion/humanoid.tres, made
## with its clips by tools/kimodo/make_locomotion.gd from the Kimodo takes in
## tools/kimodo/takes/locomotion.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion").

@export var idle: LocomotionClip
@export var walk: LocomotionClip
@export var jog: LocomotionClip
## The running loop. Has no start or stops of its own: the jog's serve it,
## matched by the legs at the handover (UnitLocomotion).
@export var run: LocomotionClip
## From the idle into the jog.
@export var jog_start: LocomotionClip
## Off the walk, each on its own frame of it, into the idle.
@export var walk_stops: Array[LocomotionClip] = []
## Off the jog, each on its own frame of it, into the idle.
@export var jog_stops: Array[LocomotionClip] = []
## In place, off the idle and back into it, each its own angle.
@export var turns: Array[LocomotionClip] = []
## From the idle into the turning loop, and the loop, each way.
@export var turn_loop_left_in: LocomotionClip
@export var turn_loop_left: LocomotionClip
@export var turn_loop_right_in: LocomotionClip
@export var turn_loop_right: LocomotionClip


## The stop off `loop` that comes up first after `seconds` into it, and how
## many seconds of the loop are still to play before it: the stop starts on
## its own frame of the loop, not on whatever frame the loop is showing.
static func next_stop(stops: Array[LocomotionClip], loop: LocomotionClip, seconds: float) -> Array:
	var best: LocomotionClip = null
	var wait: float = INF
	for stop in stops:
		var until: float = fposmod(stop.enters_at - seconds, loop.length)
		if until < wait:
			best = stop
			wait = until
	return [best, wait]


## The turn in place whose measured turn is nearest `radians` (to the left);
## null when there is none.
func turn_for(radians: float) -> LocomotionClip:
	var best: LocomotionClip = null
	for clip in turns:
		if best == null or absf(clip.turn - radians) < absf(best.turn - radians):
			best = clip
	return best
