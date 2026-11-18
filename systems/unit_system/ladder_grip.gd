class_name LadderGrip
extends SkeletonModifier3D
## On a ladder, a holding hand or a standing foot holds its rung: the limb's
## world position is pinned while the climb clip marks it planted, put on
## the nearest rung of the ladder being climbed, and a two-bone IK
## (BodyFootLock.solve: upper arm or leg, lower, hand or foot) bends the limb
## to keep it there while the body goes on up or down.
##
## WHY. The climb clips (tools/locomotion/land_ladder.gd) are Mixamo takes
## baked in place over the unit's climb, so their hands and feet land on our
## rungs only as closely as the take matches its own ladder (1-2 cm), and a
## holding limb still slides 0.1-0.3 m/s in the take. The unit's climb speed
## is the ladder's (Ladder.speed), the climb over the top is fitted to its
## legs, and its landing height is ramped onto a whole number of rungs. The
## grip takes all of that up in the limbs: what is planted stays put, on a
## rung.
##
## WHAT. UnitAnimator feeds it every physics frame it shows a climb
## (feed): the clip, how far into it, and the rungs. Each clip's "plants"
## metadata is a weight per frame per limb (how still the limb is in the
## take), "contact" how high the limb's bone sits over a rung it holds. As a
## limb's weight comes up past PIN_AT its bone's world position is taken,
## put at the nearest rung's height plus its contact (when one is within
## SNAP of it: the hands flat on the landing are held where they are, and
## a body not the take's still holds the rungs), and
## the limb is drawn to it by the weight; as the weight falls the pull eases
## off with it. A pin the body has left further than BREAK_AT behind lets
## go.
##
## Unfed, it goes stale: the weights ease to 0 by themselves, so a pin is
## never left holding a limb once the climb is over.
##
## WHERE IT RUNS. Last of the body's modifiers (after BodyInertia,
## BodyFlinch, BodyFootLock and BodyTurnLead): it holds the pose the body is
## showing, the spine's lead and all.
##
## Owned by the unit system's ladder display (docs/systems/unit.md,
## "Ladders").

const NODE_NAME: StringName = &"LadderGrip"
const LIMBS := [
	[&"LeftUpperArm", &"LeftLowerArm", &"LeftHand"],
	[&"RightUpperArm", &"RightLowerArm", &"RightHand"],
	[&"LeftUpperLeg", &"LeftLowerLeg", &"LeftFoot"],
	[&"RightUpperLeg", &"RightLowerLeg", &"RightFoot"],
]
## The clips' metadata names the limbs by their end bone.
const NAMES := ["LeftHand", "RightHand", "LeftFoot", "RightFoot"]
const PIN_AT := 0.5
const LET_GO := 0.02
const BREAK_AT := 0.3
## A pin is put on a rung only when one is within this share of the
## spacing of where the limb is: between two rungs that is always, so a
## body whose arms or legs are not the take's (the Mannequin's hands come
## out 10 cm low) still holds them; above the top rung or below the
## bottom one (the hands flat on the landing) it is left where it is.
const SNAP := 0.5
const RATE := 25.0
const FPS := 30.0

var _limbs: Array = []
var _want := [0.0, 0.0, 0.0, 0.0]
var _weight := [0.0, 0.0, 0.0, 0.0]
var _pinned := [false, false, false, false]
var _pin := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _contact := [0.0, 0.0, 0.0, 0.0]
var _rungs := PackedFloat32Array()
var _spacing: float = 0.25
var _fed: int = -1
## Per limb, how far (m) the shown bone missed its target last frame.
var miss := [0.0, 0.0, 0.0, 0.0]


## Puts one under `skeleton`, last of the body's modifiers, or returns the
## one already there.
static func attach(skeleton: Skeleton3D) -> LadderGrip:
	var there := skeleton.get_node_or_null(NodePath(NODE_NAME)) as LadderGrip
	if there == null:
		there = LadderGrip.new()
		there.name = NODE_NAME
		skeleton.add_child(there)
		var after: int = 0
		for name: StringName in [BodyInertia.NODE_NAME, BodyFlinch.NODE_NAME, BodyFootLock.NODE_NAME,
				BodyTurnLead.NODE_NAME]:
			var node: Node = skeleton.get_node_or_null(NodePath(name))
			if node:
				after = maxi(after, node.get_index() + 1)
		skeleton.move_child(there, mini(after, skeleton.get_child_count() - 1))
	there._find_bones(skeleton)
	return there


func _find_bones(skeleton: Skeleton3D) -> void:
	_limbs.clear()
	for names: Array in LIMBS:
		var bones: Array = []
		for name: StringName in names:
			bones.append(skeleton.find_bone(name))
		_limbs.append(bones if not bones.has(-1) else [])


## This physics frame's plants: `clip` shown `at` seconds in, on a ladder
## whose rungs are at `rungs` (world heights) `spacing` apart.
func feed(clip: Animation, at: float, rungs: PackedFloat32Array, spacing: float) -> void:
	_fed = Engine.get_physics_frames()
	_rungs = rungs
	_spacing = spacing
	var plants: Dictionary = clip.get_meta("plants", {}) if clip else {}
	var contact: Dictionary = clip.get_meta("contact", {}) if clip else {}
	for i in 4:
		_want[i] = _plant_at(plants.get(NAMES[i], PackedFloat32Array()), at)
		_contact[i] = float(contact.get(NAMES[i], 0.0))


## A plant curve's weight `at` seconds in, between its frames.
static func _plant_at(curve: PackedFloat32Array, at: float) -> float:
	if curve.is_empty():
		return 0.0
	var f: float = clampf(at * FPS, 0.0, curve.size() - 1)
	var i: int = floori(f)
	var j: int = mini(i + 1, curve.size() - 1)
	return lerpf(curve[i], curve[j], f - i)


func _process(delta: float) -> void:
	var fresh: bool = Engine.get_physics_frames() - _fed <= 1
	var k: float = 1.0 - exp(-RATE * delta)
	for i in 4:
		_weight[i] = lerpf(_weight[i], clampf(_want[i], 0.0, 1.0) if fresh else 0.0, k)


func _process_modification() -> void:
	var skeleton: Skeleton3D = get_skeleton()
	# A body taken out of the world (a despawn) still poses, with no world
	# for it to hold anything in.
	if skeleton == null or not skeleton.is_inside_tree():
		return
	var to_world: Transform3D = skeleton.global_transform
	for i in 4:
		miss[i] = 0.0
		if _limbs.size() <= i or (_limbs[i] as Array).is_empty():
			continue
		var bones: Array = _limbs[i]
		var w: float = _weight[i]
		var shown: Vector3 = to_world * skeleton.get_bone_global_pose(bones[2]).origin
		if w < LET_GO:
			_pinned[i] = false
			continue
		if not _pinned[i] and w >= PIN_AT:
			_pinned[i] = true
			_pin[i] = _on_rung(shown, _contact[i])
		if not _pinned[i]:
			continue
		if (_pin[i] as Vector3).distance_to(shown) > BREAK_AT:
			_pinned[i] = false
			continue
		var held: Vector3 = shown.lerp(_pin[i], w)
		BodyFootLock.solve(skeleton, bones, to_world.affine_inverse() * held)
		miss[i] = (to_world * skeleton.get_bone_global_pose(bones[2]).origin).distance_to(held)


## `at` brought to the height of the rung nearest it plus `contact`, when
## there is one within SNAP of the spacing.
func _on_rung(at: Vector3, contact: float) -> Vector3:
	var best: float = INF
	for h: float in _rungs:
		if absf(at.y - contact - h) < absf(best - (at.y - contact)) or best == INF:
			best = h
	if best == INF or absf(at.y - contact - best) > SNAP * _spacing:
		return at
	return Vector3(at.x, best + contact, at.z)
