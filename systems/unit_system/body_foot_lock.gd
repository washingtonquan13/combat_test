class_name BodyFootLock
extends SkeletonModifier3D
## A planted foot holds its place on the ground while the body goes on over
## it: the foot's world position is pinned while its clip marks it down, and
## a two-bone IK (upper leg, lower leg) bends the leg to keep it there.
##
## WHY. The unit's speed is gameplay's, not the clip's (UnitLocomotion
## steers the walk within 0.8-1.2x, starts and stops enter off speed, the
## lean and turn move the body). Any gap between how fast the unit goes and
## how fast the clip's feet push back shows as the planted foot skating.
## Pinning the foot takes the gap up in the leg instead of on the ground.
##
## WHAT. UnitLocomotion sets `left_plant` and `right_plant` each tick, 0..1,
## from the playing clip's baked plant curves (LocomotionClip.plant_at). As a
## foot's weight comes up past PIN_AT, its ankle's world position is taken;
## while it holds, the ankle is drawn to that point by the weight. As the
## weight falls (the heel lifting) the pull eases off with it, so the foot
## goes back to the animation smoothly rather than snapping: that is the
## release. A pin the body has left behind (BREAK_AT) lets go over
## BREAK_EASE: the foot eases from where it was held back to the animation,
## and is not pinned again until its clip lifts it (under LET_GO). A pin
## further off than SNAP_FROM (a teleport) lets go at once. A pin the leg
## cannot reach moves to where the foot got to.
##
## Plants that nobody sets go stale: when no plant arrives in a physics
## frame (locomotion is not ticking: the body is posed, dead, claimed or
## on a move it does not show), the weights ease to 0 and the stride to 1
## by themselves, so a pin is never left holding a foot in the world.
##
## The foot keeps its animated orientation; only where it is changes. The
## knee bends in the plane the animation gives it (hip, knee, ankle), so the
## knee points where the clip points it.
##
## WHERE IT RUNS. After BodyInertia and BodyFlinch, before BodyTurnLead and
## the gaze: it pins the pose the body is actually showing, inertia and all,
## and nothing after it moves the legs.
##
## Owned by the unit system (docs/systems/unit.md, "Locomotion").

const NODE_NAME: StringName = &"BodyFootLock"
const LEGS := [
	[&"LeftUpperLeg", &"LeftLowerLeg", &"LeftFoot"],
	[&"RightUpperLeg", &"RightLowerLeg", &"RightFoot"],
]
## The weight a foot's pin is taken at, and below which it is let go.
const PIN_AT := 0.5
const LET_GO := 0.02
## How far (m) the pin may be from the animated ankle before it lets go,
## how long (s) the foot takes to come back to the animation then, and how
## far off a pin is let go at once instead (a teleport, a cut).
const BREAK_AT := 0.35
const BREAK_EASE := 0.1
const SNAP_FROM := 0.7
## The leg is never drawn straighter than this share of its length.
const REACH := 0.995
## The stride is warped no shorter or longer than these.
const STRIDE_LEAST := 0.7
const STRIDE_MOST := 1.5
## How fast (1/s) a weight comes up to what the clip marks (a cut between
## clips does not jerk the leg).
const RATE := 25.0
const STRIDE_RATE := 20.0

## How planted each foot is, as the playing clip marks it. Setting one
## stamps the physics frame (see stale plants, above).
var left_plant: float = 0.0:
	set(value):
		left_plant = value
		_fed = Engine.get_physics_frames()
var right_plant: float = 0.0:
	set(value):
		right_plant = value
		_fed = Engine.get_physics_frames()
## The physics frame the plants were last set on.
var _fed: int = -1
## The stride asked for: the unit's speed over the clip's (1: as animated),
## and the way the unit goes, world space.
var stride: float = 1.0
var forward: Vector3 = Vector3.FORWARD
var _stride: float = 1.0
var _hips: int = -1
## Per leg: [upper, lower, foot] bone indices (empty on a rig lacking one).
var _legs: Array = []
## Per leg: eased weight, whether pinned, the pin in world space.
var _weight := [0.0, 0.0]
var _pinned := [false, false]
var _pin := [Vector3.ZERO, Vector3.ZERO]
## Per leg, after a break: the held foot's offset from the animated ankle
## (world), what is left of it (1 to 0 over BREAK_EASE), and whether a new
## pin waits for the weight to fall under LET_GO.
var _break_off := [Vector3.ZERO, Vector3.ZERO]
var _break_left := [0.0, 0.0]
var _held_off := [false, false]
## Per leg, how far (m) the shown ankle was from the animated one last frame,
## world space, horizontal (for the demo).
var pull := [0.0, 0.0]
## Per leg, how far (m) the shown ankle missed the target last frame.
var miss := [0.0, 0.0]


## Puts one under `skeleton`, after the inertia and the flinch, or returns
## the one already there.
static func attach(skeleton: Skeleton3D) -> BodyFootLock:
	var there := skeleton.get_node_or_null(NodePath(NODE_NAME)) as BodyFootLock
	if there == null:
		there = BodyFootLock.new()
		there.name = NODE_NAME
		skeleton.add_child(there)
		var after: int = 0
		for name: StringName in [BodyInertia.NODE_NAME, BodyFlinch.NODE_NAME]:
			var node: Node = skeleton.get_node_or_null(NodePath(name))
			if node:
				after = maxi(after, node.get_index() + 1)
		skeleton.move_child(there, after)
	there._find_bones(skeleton)
	return there


func _find_bones(skeleton: Skeleton3D) -> void:
	_legs.clear()
	_hips = skeleton.find_bone(&"Hips")
	for names: Array in LEGS:
		var bones: Array = []
		for name: StringName in names:
			bones.append(skeleton.find_bone(name))
		_legs.append(bones if not bones.has(-1) else [])


## Lets both feet go (a cut, a teleport, the body taken by something else).
func release() -> void:
	left_plant = 0.0
	right_plant = 0.0
	_weight = [0.0, 0.0]
	_pinned = [false, false]
	_break_left = [0.0, 0.0]
	_held_off = [false, false]
	stride = 1.0
	_stride = 1.0


func _process(delta: float) -> void:
	# Fed this physics frame or the last (frames can draw between steps).
	var fresh: bool = Engine.get_physics_frames() - _fed <= 1
	var k: float = 1.0 - exp(-RATE * delta)
	_weight[0] = lerpf(_weight[0], clampf(left_plant, 0.0, 1.0) if fresh else 0.0, k)
	_weight[1] = lerpf(_weight[1], clampf(right_plant, 0.0, 1.0) if fresh else 0.0, k)
	var want: float = clampf(stride, STRIDE_LEAST, STRIDE_MOST) if fresh else 1.0
	_stride = lerpf(_stride, want, 1.0 - exp(-STRIDE_RATE * delta))
	for i in 2:
		_break_left[i] = maxf(0.0, _break_left[i] - delta / BREAK_EASE)


func _process_modification() -> void:
	var skeleton: Skeleton3D = get_skeleton()
	if skeleton == null:
		return
	for i in 2:
		pull[i] = 0.0
		miss[i] = 0.0
		if _legs.size() <= i or (_legs[i] as Array).is_empty():
			continue
		_lock(skeleton, i)


func _lock(skeleton: Skeleton3D, i: int) -> void:
	var bones: Array = _legs[i]
	var w: float = _weight[i]
	var to_world: Transform3D = skeleton.global_transform
	var ankle: Vector3 = _warped(skeleton, skeleton.get_bone_global_pose(bones[2]).origin)
	var ankle_world: Vector3 = to_world * ankle
	var held: Vector3 = ankle_world
	if w < LET_GO:
		_pinned[i] = false
		_held_off[i] = false
	elif not _pinned[i] and not _held_off[i] and w >= PIN_AT:
		_pinned[i] = true
		_pin[i] = ankle_world
	if _pinned[i] and (_pin[i] as Vector3).distance_to(ankle_world) > BREAK_AT:
		# Left behind: the foot eases back from where it was held, and is
		# not pinned again until the clip lifts it.
		_pinned[i] = false
		_held_off[i] = true
		var off: Vector3 = ((_pin[i] as Vector3) - ankle_world) * w
		_break_left[i] = 1.0 if off.length() < SNAP_FROM else 0.0
		_break_off[i] = off
	if _pinned[i]:
		held = ankle_world.lerp(_pin[i], w)
	elif _break_left[i] > 0.0:
		held = ankle_world + (_break_off[i] as Vector3) * smoothstep(0.0, 1.0, _break_left[i])
	if not _pinned[i] and _break_left[i] <= 0.0 and absf(_stride - 1.0) < 0.005:
		return
	var target: Vector3 = to_world.affine_inverse() * held
	_solve(skeleton, bones, target)
	var shown: Vector3 = to_world * skeleton.get_bone_global_pose(bones[2]).origin
	miss[i] = shown.distance_to(held)
	if _pinned[i] and miss[i] > 0.005:
		# Out of reach: the pin goes to where the foot got to, so it is let
		# go from there and does not drag the leg at full stretch.
		_pin[i] = ankle_world + (shown - ankle_world) / maxf(w, 0.05)
	pull[i] = Vector2(shown.x - ankle_world.x, shown.z - ankle_world.z).length()


## The ankle `at` (skeleton space) with the stride warped: its distance
## ahead of or behind the hips along the way scaled by `stride`, so the feet
## push back at the unit's speed and not the clip's.
func _warped(skeleton: Skeleton3D, at: Vector3) -> Vector3:
	if absf(_stride - 1.0) < 0.005 or _hips == -1:
		return at
	var way: Vector3 = skeleton.global_basis.inverse() * forward
	var up: Vector3 = skeleton.global_basis.inverse() * Vector3.UP
	way = (way - up.normalized() * way.dot(up.normalized())).normalized()
	if not way.is_finite() or way.length_squared() < 0.5:
		return at
	var ahead: float = (at - skeleton.get_bone_global_pose(_hips).origin).dot(way)
	return at + way * ahead * (_stride - 1.0)


## Bends the leg `bones` (upper, lower, foot) so the ankle reaches `target`,
## skeleton space, keeping the foot's orientation and the knee's plane.
func _solve(skeleton: Skeleton3D, bones: Array, target: Vector3) -> void:
	var upper: int = bones[0]
	var lower: int = bones[1]
	var foot: int = bones[2]
	var up_g: Transform3D = skeleton.get_bone_global_pose(upper)
	var low_g: Transform3D = skeleton.get_bone_global_pose(lower)
	var foot_g: Transform3D = skeleton.get_bone_global_pose(foot)
	var a: Vector3 = up_g.origin
	var b: Vector3 = low_g.origin
	var c: Vector3 = foot_g.origin
	var l1: float = a.distance_to(b)
	var l2: float = b.distance_to(c)
	if l1 < 1e-4 or l2 < 1e-4:
		return
	var reach: Vector3 = target - a
	var d: float = clampf(reach.length(), absf(l1 - l2) + 1e-3, (l1 + l2) * REACH)
	if reach.length() < 1e-4:
		return
	# The knee: open or close it about the leg's own plane to the length.
	var axis: Vector3 = (b - a).cross(c - b)
	var knee := Quaternion.IDENTITY
	if axis.length_squared() > 1e-10:
		axis = axis.normalized()
		var now: float = (a - b).angle_to(c - b)
		var want: float = acos(clampf((l1 * l1 + l2 * l2 - d * d) / (2.0 * l1 * l2), -1.0, 1.0))
		knee = Quaternion(axis, now - want)
	var c_bent: Vector3 = b + knee * (c - b)
	# The hip: swing the bent leg onto the target.
	var swing := Quaternion(((c_bent - a)).normalized(), reach.normalized())
	var parent: int = skeleton.get_bone_parent(upper)
	var parent_basis := Basis.IDENTITY
	if parent != -1:
		parent_basis = skeleton.get_bone_global_pose(parent).basis.orthonormalized()
	var up_new := Basis(swing) * up_g.basis.orthonormalized()
	var low_new := Basis(swing * knee) * low_g.basis.orthonormalized()
	skeleton.set_bone_pose_rotation(upper, (parent_basis.inverse() * up_new).get_rotation_quaternion())
	skeleton.set_bone_pose_rotation(lower, (up_new.inverse() * low_new).get_rotation_quaternion())
	skeleton.set_bone_pose_rotation(foot, (low_new.inverse() * foot_g.basis.orthonormalized()).get_rotation_quaternion())
