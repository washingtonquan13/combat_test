class_name LocomotionSet
extends Resource
## A humanoid body's locomotion clips, in the shape of Baldur's Gate 3's
## gameplay set: an idle, a walk and a run loop; a start into each; walk
## stops and run stops (each a stop and its mirror); turns in place left and
## right; a turning loop each way.
##
## Every clip plays in place and carries the ground it covers
## (LocomotionClip). The humanoid set is data/locomotion/humanoid.tres. Its
## run start is written from the rest pose by tools/gait/author_gait.gd; its
## jog and turning loops are made by tools/kimodo/make_locomotion.gd from the
## Kimodo takes in tools/kimodo/takes/locomotion; its idle (Warrior Idle),
## walk, run, turns, walk start and stops are Mixamo's, landed by
## tools/locomotion/land_mixamo.gd. Run them in
## that order: make_locomotion.gd, author_gait.gd (GAIT_LAND=1),
## land_mixamo.gd.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion").

@export var idle: LocomotionClip
@export var walk: LocomotionClip
@export var jog: LocomotionClip
## The running loop.
@export var run: LocomotionClip
## From the idle into the run (named for the jog it once started).
@export var jog_start: LocomotionClip
## From the idle into the walk.
@export var walk_start: LocomotionClip
## Off the walk, each on its own frame of it, into the idle.
@export var walk_stops: Array[LocomotionClip] = []
## Off the run, each on its own frame of it, into the idle.
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
