class_name LocomotionClip
extends Resource
## One clip of a body's locomotion set (LocomotionSet), and what it does
## with the ground.
##
## The clip itself plays in place: the body stays over its own feet, facing
## ahead. How far it travels and turns is taken out of it, frame by frame,
## and kept here (root_positions, root_yaws), for whatever moves the unit to
## move it by. A loop (walk, jog) is moved along its path at `speed`; a stop,
## a start or a turn moves the unit by its own curve, so a stop ends where
## its feet did.
##
## What is taken out is the hips' path smoothed over about half a second,
## so the sway of a step stays in the clip and the unit itself goes smoothly.
## Where a clip starts on a frame of the loop it comes from (a stop off the
## walk, a turn off the idle), the curve is made to agree with that loop's
## on that frame, and where it ends on a pose of the loop it goes to, with
## that one: the handover shows no step.
##
## Made by tools/gait/author_gait.gd (run start),
## tools/kimodo/make_locomotion.gd (jog, turning loops) or
## tools/locomotion/land_mixamo.gd (Warrior Idle, walk, run, turns, walk
## start, stops, from Mixamo); nothing here is hand-set.

const FPS := 30.0

## The clip on the body's AnimationPlayer ("Locomotion/walk").
@export var clip: StringName = &""
## A loop (idle, walk, jog, turn loop) rather than a clip that ends.
@export var loops: bool = false
## Seconds long.
@export var length: float = 0.0
## Where the unit stands on each frame (30 a second), from the first frame's
## standing place, in the model's space: +Z ahead, +X to its left, metres.
@export var root_positions: PackedVector3Array = PackedVector3Array()
## Its facing on each frame, radians to the left of the first frame's.
@export var root_yaws: PackedFloat32Array = PackedFloat32Array()
## Seconds into the clip it starts from (a stop's walk or jog, a turn's idle)
## on which that clip shows this one's first frame; -1 for none.
@export var enters_at: float = -1.0
## Seconds into the clip it hands over to (the idle after a stop or turn,
## the jog after the start) whose pose its last frame shows; -1 for none.
@export var leaves_at: float = -1.0

@export_group("Measured")
## Metres from where it starts to where it ends. A loop: per cycle.
@export var travel: float = 0.0
## Radians it turns, to the left. A loop: per cycle.
@export var turn: float = 0.0
## A loop's metres a second.
@export var speed: float = 0.0
## A loop's cycles of the same stride pair (the walk: 3). A stop that enters
## on one frame of the loop enters as well a 1/strides of the cycle on.
@export var strides: int = 1
## A loop's foot strikes: the seconds into it each foot comes down (is
## furthest ahead), in turn, the left's first, over one cycle. Two loops are
## shown in step by them (phase_at, time_at: a walk under a run as it slows).
## Each is later than the one before, so the last may be past `length` (a
## cycle on).
## Empty: not marked. Set by tools/locomotion/land_mixamo.gd.
@export var strikes: PackedFloat32Array = PackedFloat32Array()


## Whether the loop's strikes are marked, so it can be played in step.
func marked() -> bool:
	return strikes.size() >= 2 and strikes.size() % 2 == 0 and length > 0.0


## How many stride pairs (left strike to left strike) a cycle holds.
func pairs() -> int:
	return strikes.size() / 2


## Where in its strides the loop is `seconds` in: 0 on the left's strike,
## 0.5 on the right's, 1 on the next left's, up to pairs() over a cycle.
## Between two strikes it goes evenly.
func phase_at(seconds: float) -> float:
	var n: int = strikes.size()
	var t: float = fposmod(seconds - strikes[0], length) + strikes[0]
	for i in n:
		var to: float = strikes[i + 1] if i + 1 < n else strikes[0] + length
		if t < to or i == n - 1:
			return (i + clampf((t - strikes[i]) / maxf(to - strikes[i], 1e-4), 0.0, 1.0)) * 0.5
	return 0.0


## The seconds into the loop at `phase` (phase_at's measure, taken round the
## cycle).
func time_at(phase: float) -> float:
	var n: int = strikes.size()
	var p: float = fposmod(phase * 2.0, float(n))
	var i: int = mini(floori(p), n - 1)
	var to: float = strikes[i + 1] if i + 1 < n else strikes[0] + length
	return fposmod(lerpf(strikes[i], to, p - i), length)


## Where the unit stands `seconds` in, from where it stood on the first
## frame. A loop goes on past its end, cycle on cycle.
func root_at(seconds: float) -> Transform3D:
	var last: int = root_positions.size() - 1
	if last < 0:
		return Transform3D.IDENTITY
	var cycles: int = 0
	if loops and length > 0.0:
		cycles = floori(seconds / length)
		seconds -= cycles * length
	var at: float = clampf(seconds * FPS, 0.0, last)
	var i: int = mini(floori(at), maxi(last - 1, 0))
	var w: float = at - i
	var j: int = mini(i + 1, last)
	var here := Transform3D(Basis(Vector3.UP, lerpf(root_yaws[i], root_yaws[j], w)),
		root_positions[i].lerp(root_positions[j], w))
	if cycles == 0:
		return here
	var cycle := Transform3D(Basis(Vector3.UP, root_yaws[last]), root_positions[last])
	var whole := Transform3D.IDENTITY
	for k in absi(cycles):
		whole = whole * (cycle if cycles > 0 else cycle.affine_inverse())
	return whole * here
