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
## Made by tools/kimodo/make_locomotion.gd; nothing here is hand-set.

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
