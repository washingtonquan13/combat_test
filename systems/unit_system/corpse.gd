class_name Corpse
extends Node3D
## What a dead unit leaves where it fell: its body, collapsed, and anything
## it dropped, looted off the body itself. Owned by the unit system (see
## docs/systems/unit.md); UnitCombat._die leaves one for every real death,
## UnitDeath.expire (a summon running out) does not.
##
## THE BODY MOVES HERE. The Unit is freed soon after it dies (UnitDeath,
## death_cleanup_delay), and its CharacterModel would go with it, so the
## body is reparented to this node, which stays until the area is unloaded.
## Nothing on it collides with anything: units walk through a corpse, and
## the navigation grid never knew about it.
##
## HOW IT FALLS. A body whose CharacterModel declares a RagdollProfile goes
## limp: one rigid body per profile part, jointed to its parent part, and
## every physics frame the bones are posed from those bodies. Godot's own
## PhysicalBone3D is not used because the rigs are not all at scale 1
## (a body is worn at its unit's size, and imported rigs carry their own
## scale), which it does not handle; driving the bones by hand from plain
## RigidBody3Ds works at any scale. When everything has come to rest, the
## bodies are freed and the pose simply stays: a settled corpse costs
## nothing per frame. A body with no profile plays its death clip instead,
## and lies however the clip leaves it.
##
## The parts collide with the world only - never with units, which would
## leave a body propped on a neighbour who then walks away - and not with
## each other (their joints keep them apart well enough at this size).
##
## LOOT. Drops are rolled at death (UnitDefinition.level, max_drops,
## drop_chance; party members and owned demons drop nothing) into a
## StashComponent on the corpse, and the corpse offers LootInteraction like
## a chest does. Its click target is an Area3D on PICK_LAYER over where the
## body came to rest, found by GroundClickTarget._corpse_under_mouse; it is
## built once the body settles, and removed (with the stash) once the
## stash is emptied. The body stays.
##
## Spawned at runtime, so not persistent: like any spawned thing a corpse
## isn't in an area's save (spawned_units_dont_persist). An authored unit's
## death is recorded by UnitDeath, so it isn't there to die again.

## The layer a lootable corpse's click area is on. Free of everything else:
## the world and units are 1, a unit's pick area is 1 << 19.
const PICK_LAYER: int = 1 << 20
## The layer the falling parts are on; nothing looks for it.
const BODY_LAYER: int = 1 << 21
## What the falling parts land on.
const WORLD_MASK: int = 1

const LOOT: InteractionOption = preload("res://data/interactions/loot.tres")
const STASH_SCENE: PackedScene = preload("res://systems/inventory_system/stash_component.tscn")

## A body has come to rest when every part is slower than this (m/s, and
## rad/s for turning) for SETTLE_SECONDS, but not before MIN_FALL_SECONDS;
## it is called at rest after MAX_FALL_SECONDS whatever it is doing.
const SETTLE_SPEED: float = 0.08
const SETTLE_SECONDS: float = 0.4
const MIN_FALL_SECONDS: float = 0.5
const MAX_FALL_SECONDS: float = 5.0
## The push the torso gets as the unit dies: back, away from where it faced.
const FALL_PUSH: float = 1.2
## A body with no ragdoll is clickable once its death clip has had time.
const CLIP_SETTLE_SECONDS: float = 2.0
## The click area: the resting body's bounds, this much wider each way,
## and never smaller than PICK_MIN.
const PICK_MARGIN: float = 0.15
const PICK_MIN: Vector3 = Vector3(0.6, 0.3, 0.6)

const PART_LINEAR_DAMP: float = 0.2
const PART_ANGULAR_DAMP: float = 2.0
const PART_FRICTION: float = 0.9

## Who this was, for the stash title.
var display_name: String = ""
var interactions: Array[InteractionOption] = []

var _body: Node3D = null
var _skeleton: Skeleton3D = null
var _parts: Array[_Part] = []
var _joints: Array[Joint3D] = []
var _falling: float = 0.0
var _still: float = 0.0
var _pick: Area3D = null


## One falling piece: the rigid body standing in for a bone, and where the
## bone sits in that body's frame.
class _Part:
	var bone: int = -1
	var rigid: RigidBody3D = null
	var offset: Transform3D = Transform3D.IDENTITY
	var depth: int = 0


## Leaves unit's corpse where it fell, holding what it dropped. Waits for a
## scene showing the unit on a stand-in to end first: the body under it is
## hidden and the scene is still using the unit.
static func leave(unit: Unit) -> void:
	var stand: StandIn = StandIn.of(unit)
	if stand:
		stand.tree_exited.connect(func() -> void:
			if is_instance_valid(unit) and unit.is_inside_tree() and not unit.is_queued_for_deletion():
				_leave_now(unit), CONNECT_ONE_SHOT)
		return
	_leave_now(unit)


## The lootable corpse a pick area belongs to, or null for anything else.
static func from_pick_area(area: Object) -> Corpse:
	var node := area as Node
	return node.get_parent() as Corpse if node else null


## Same shape as InteractableProp.get_interactions.
func get_interactions(actor: Unit) -> Array[InteractionOption]:
	var result: Array[InteractionOption] = []
	for option in interactions:
		if option.is_available(actor, self):
			result.append(option)
	return result


## What unit drops: UnitDefinition.max_drops rolls at its level, each
## coming up drop_chance of the time. Party members and owned demons drop
## nothing.
static func roll_drops(unit: Unit) -> Array[ItemInstance]:
	var drops: Array[ItemInstance] = []
	var definition: UnitDefinition = unit.definition
	if not definition or unit.owned_demon or PartyManager.is_member(unit):
		return drops
	var rng := RandomNumberGenerator.new()
	for i in definition.max_drops:
		if rng.randf() < definition.drop_chance:
			var item := LootRoller.roll(definition.level, rng)
			if item:
				drops.append(item)
	return drops


static func _leave_now(unit: Unit) -> void:
	var body := unit.get_node_or_null(NodePath(StandIn.BODY_NAME)) as Node3D
	var drops: Array[ItemInstance] = roll_drops(unit)
	if body == null and drops.is_empty():
		return
	var corpse := Corpse.new()
	corpse.name = "Corpse"
	corpse.display_name = unit.get_display_name()
	unit.get_parent().add_child(corpse)
	corpse.global_position = unit.global_position
	if body:
		corpse._take_body(unit, body)
	if not drops.is_empty():
		corpse._hold(drops)
	if body == null:
		corpse._make_pickable()
		return
	var profile: RagdollProfile = (body as CharacterModel).ragdoll if body is CharacterModel else null
	if profile == null or not corpse._fall(profile, unit.visual_forward()):
		# The death clip plays on and holds its last frame (the body's own
		# AnimationTree advances itself); click it once it has lain down.
		if corpse._stash():
			corpse.get_tree().create_timer(CLIP_SETTLE_SECONDS).timeout.connect(corpse._make_pickable)


func _take_body(unit: Unit, body: Node3D) -> void:
	_body = body
	body.reparent(self, true)
	# A unit hovered or selected as it died would keep its outline lit.
	UnitOutline.clear(body)
	# Held weapons and anything else solid on the body: a corpse blocks
	# nothing and is clicked through its own area.
	for solid: CollisionObject3D in body.find_children("*", "CollisionObject3D", true, false):
		solid.collision_layer = 0
		solid.collision_mask = 0
	if body is CharacterModel:
		(body as CharacterModel).stop_gazing(0.0)
	# What is still telling the body what to do. The unit is going.
	var animator: Node = unit.animator()
	if animator:
		animator.set_process(false)
		animator.set_physics_process(false)


func _hold(drops: Array[ItemInstance]) -> void:
	var stash: StashComponent = STASH_SCENE.instantiate()
	stash.name = "Stash"
	add_child(stash)
	stash.display_name = "Remains of %s" % display_name
	for item in drops:
		stash.put(item)
	interactions = [LOOT]
	StashManager.stash_closed.connect(_on_stash_closed)


func _stash() -> StashComponent:
	return StashComponent.find_on(self)


## Builds the ragdoll and lets go. False when the body has no skeleton
## carrying the profile's bones, which leaves it to its death clip.
func _fall(profile: RagdollProfile, facing: Vector3) -> bool:
	_skeleton = _skeleton_for(profile)
	if _skeleton == null:
		return false
	for mixer: AnimationMixer in _body.find_children("*", "AnimationMixer", true, false):
		mixer.active = false
	for modifier: SkeletonModifier3D in _skeleton.find_children("*", "SkeletonModifier3D", true, false):
		modifier.active = false

	var by_bone: Dictionary = {}
	for part in profile.parts:
		var made := _make_part(part)
		if made:
			by_bone[made.bone] = made
			_parts.append(made)
	if _parts.is_empty():
		return false
	_parts.sort_custom(func(a: _Part, b: _Part) -> bool: return a.depth < b.depth)

	var live: Array[Node] = get_tree().get_nodes_in_group("units")
	for made in _parts:
		for unit in live:
			if unit is PhysicsBody3D:
				made.rigid.add_collision_exception_with(unit)
	for part in profile.parts:
		var bone: int = _skeleton.find_bone(part.bone)
		if not by_bone.has(bone):
			continue
		var parent_part: _Part = _parent_part(bone, by_bone)
		if parent_part:
			_join(parent_part, by_bone[bone], part)

	var push := Vector3(-facing.x, 0.0, -facing.z)
	if push.length() > 0.001:
		_parts[0].rigid.apply_central_impulse(push.normalized() * FALL_PUSH * _parts[0].rigid.mass)
	set_physics_process(true)
	return true


func _skeleton_for(profile: RagdollProfile) -> Skeleton3D:
	if profile.parts.is_empty():
		return null
	for skeleton: Skeleton3D in _body.find_children("*", "Skeleton3D", true, false):
		if skeleton.find_bone(profile.parts[0].bone) != -1:
			return skeleton
	return null


func _bone_world(bone: int) -> Transform3D:
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(bone)


func _make_part(part: RagdollPart) -> _Part:
	var bone: int = _skeleton.find_bone(part.bone)
	if bone == -1:
		return null
	var bone_xf: Transform3D = _bone_world(bone)
	var scale: float = _skeleton.global_basis.get_scale().x
	var tip: int = _skeleton.find_bone(part.tip) if part.tip != &"" else -1
	var tip_b: int = _skeleton.find_bone(part.tip_b) if part.tip_b != &"" else -1

	var shape: Shape3D
	var frame: Transform3D
	if tip != -1:
		var from: Vector3 = _bone_world(tip).origin if tip_b != -1 else bone_xf.origin
		var to: Vector3 = _bone_world(tip_b).origin if tip_b != -1 else _bone_world(tip).origin
		var length: float = maxf(from.distance_to(to), 0.01)
		var capsule := CapsuleShape3D.new()
		capsule.radius = length * part.radius_ratio
		capsule.height = length + capsule.radius * 2.0
		shape = capsule
		frame = Transform3D(_basis_along(to - from, bone_xf.basis), (from + to) * 0.5)
	else:
		var sphere := SphereShape3D.new()
		sphere.radius = part.sphere_radius * scale
		shape = sphere
		var up: Vector3 = bone_xf.basis.y.normalized()
		frame = Transform3D(bone_xf.basis.orthonormalized(), bone_xf.origin + up * sphere.radius)

	var rigid := RigidBody3D.new()
	rigid.name = "Part" + String(part.bone)
	rigid.collision_layer = BODY_LAYER
	rigid.collision_mask = WORLD_MASK
	rigid.mass = part.mass
	rigid.linear_damp = PART_LINEAR_DAMP
	rigid.angular_damp = PART_ANGULAR_DAMP
	rigid.continuous_cd = true
	var material := PhysicsMaterial.new()
	material.friction = PART_FRICTION
	rigid.physics_material_override = material
	var collider := CollisionShape3D.new()
	collider.shape = shape
	rigid.add_child(collider)
	add_child(rigid)
	rigid.global_transform = frame

	var made := _Part.new()
	made.bone = bone
	made.rigid = rigid
	made.offset = frame.affine_inverse() * bone_xf
	var walk: int = bone
	while walk != -1:
		made.depth += 1
		walk = _skeleton.get_bone_parent(walk)
	return made


## An orthonormal basis whose Y runs along `along`, turned to match
## `hint`'s X as near as it can, so a part starts out facing its bone.
static func _basis_along(along: Vector3, hint: Basis) -> Basis:
	var y: Vector3 = along.normalized()
	var x: Vector3 = hint.x - y * y.dot(hint.x)
	if x.length() < 0.001:
		x = y.cross(Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT)
	x = x.normalized()
	return Basis(x, y, x.cross(y))


func _parent_part(bone: int, by_bone: Dictionary) -> _Part:
	var walk: int = _skeleton.get_bone_parent(bone)
	while walk != -1:
		if by_bone.has(walk):
			return by_bone[walk]
		walk = _skeleton.get_bone_parent(walk)
	return null


## A cone at the child bone's origin, its X (the twist axis) along the
## child part's length.
func _join(parent: _Part, child: _Part, part: RagdollPart) -> void:
	var at: Vector3 = _bone_world(child.bone).origin
	var along: Vector3 = child.rigid.global_basis.y
	var x: Vector3 = along.normalized()
	var y: Vector3 = x.cross(Vector3.UP if absf(x.dot(Vector3.UP)) < 0.9 else Vector3.FORWARD).normalized()
	var joint := ConeTwistJoint3D.new()
	joint.name = "Joint" + String(part.bone)
	add_child(joint)
	joint.global_transform = Transform3D(Basis(x, y, x.cross(y)), at)
	joint.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, deg_to_rad(part.swing_degrees))
	joint.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, deg_to_rad(part.twist_degrees))
	joint.node_a = joint.get_path_to(parent.rigid)
	joint.node_b = joint.get_path_to(child.rigid)
	_joints.append(joint)


func _ready() -> void:
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	if _parts.is_empty() or not is_instance_valid(_skeleton):
		set_physics_process(false)
		return
	_pose_from_parts()
	_falling += delta
	var resting := true
	for made in _parts:
		if made.rigid.linear_velocity.length() > SETTLE_SPEED or made.rigid.angular_velocity.length() > SETTLE_SPEED * 4.0:
			resting = false
			break
	_still = _still + delta if resting else 0.0
	if (_falling >= MIN_FALL_SECONDS and _still >= SETTLE_SECONDS) or _falling >= MAX_FALL_SECONDS:
		_settle()


## Poses each part's bone from its rigid body, parents first, so each
## bone's local pose is taken against its parent's new one. Bones with no
## part keep their local pose and ride along.
func _pose_from_parts() -> void:
	var to_skeleton: Transform3D = _skeleton.global_transform.affine_inverse()
	for made in _parts:
		var wanted: Transform3D = to_skeleton * made.rigid.global_transform * made.offset
		var parent: int = _skeleton.get_bone_parent(made.bone)
		var local: Transform3D = wanted if parent == -1 else _skeleton.get_bone_global_pose(parent).affine_inverse() * wanted
		_skeleton.set_bone_pose_position(made.bone, local.origin)
		_skeleton.set_bone_pose_rotation(made.bone, local.basis.get_rotation_quaternion())


## Frees the physics and keeps the pose. The corpse's own origin moves to
## the middle of the body (what InteractionOption.in_reach measures to),
## the body staying where it lies.
func _settle() -> void:
	set_physics_process(false)
	_pose_from_parts()
	var points: PackedVector3Array = []
	for made in _parts:
		points.append(made.rigid.global_position)
	for joint in _joints:
		joint.queue_free()
	for made in _parts:
		made.rigid.queue_free()
	_joints.clear()
	_parts.clear()
	var centre := Vector3.ZERO
	for p in points:
		centre += p
	centre /= maxf(points.size(), 1)
	var lowest: float = INF
	for p in points:
		lowest = minf(lowest, p.y)
	var body_xf: Transform3D = _body.global_transform
	global_position = Vector3(centre.x, lowest, centre.z)
	_body.global_transform = body_xf
	if _stash():
		_make_pickable(points)


## The click area over the body: round its rest points when it fell as a
## ragdoll, round its meshes otherwise.
func _make_pickable(points: PackedVector3Array = []) -> void:
	if not is_inside_tree() or is_instance_valid(_pick) or _stash() == null:
		return
	var box := AABB(Vector3.ZERO, Vector3.ZERO)
	if not points.is_empty():
		box = AABB(to_local(points[0]), Vector3.ZERO)
		for p in points:
			box = box.expand(to_local(p))
	elif _body:
		var first := true
		for mesh: VisualInstance3D in _body.find_children("*", "VisualInstance3D", true, false):
			if not mesh.visible:
				continue
			var local: AABB = (global_transform.affine_inverse() * mesh.global_transform) * mesh.get_aabb()
			box = local if first else box.merge(local)
			first = false
	box = box.grow(PICK_MARGIN)
	var size := Vector3(maxf(box.size.x, PICK_MIN.x), maxf(box.size.y, PICK_MIN.y), maxf(box.size.z, PICK_MIN.z))
	var area := Area3D.new()
	area.name = "PickArea"
	area.collision_layer = PICK_LAYER
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = false
	area.input_ray_pickable = false
	var shape := CollisionShape3D.new()
	var cube := BoxShape3D.new()
	cube.size = size
	shape.shape = cube
	shape.position = box.get_center()
	area.add_child(shape)
	add_child(area)
	_pick = area


func _on_stash_closed() -> void:
	var stash := _stash()
	if stash == null or not stash.inventory.get_container().items().is_empty():
		return
	StashManager.stash_closed.disconnect(_on_stash_closed)
	interactions = []
	stash.queue_free()
	if is_instance_valid(_pick):
		_pick.queue_free()
	_pick = null
	if _body == null:
		queue_free()
