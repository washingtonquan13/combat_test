class_name CharacterModel
extends Node3D
## A creature's whole physical presence, authored as one scene.
##
## The Unit is the ACTOR — stats, skills, abilities, AI, turn state. This
## is the BODY: the mesh it wears, the skeleton under it, the library it
## animates from, the silhouette it outlines with, the ring at its feet,
## and the points on it other systems need to aim at.
##
## The test for whether something belongs here is simple: **would it be
## wrong for a different creature?** The outline mesh is skinned to one
## specific skeleton, so it belongs here. Clip names are facts about one
## animation library, so they belong here. UnitAnimator's sequencing —
## phases, interruption, advance — is identical for every creature, so it
## stays on the Unit and merely reads what it is given.
##
## Nothing gameplay-facing goes in here. No stats, no abilities, no AI, no
## state a rule would read. If a field would ever be consulted by a rule
## rather than by a renderer, it belongs on UnitDefinition or Unit. "All
## the visuals" is exactly the kind of scope that grows into a god-scene,
## and the line has to be held deliberately.
##
## WHY A SCENE AND NOT COMPUTED. An earlier design built the body from
## numbers at spawn — a capsule sized from radius and height. That cannot
## express a creature that is not capsule-shaped, and it cannot be checked
## by eye. Authoring it means opening the scene and looking at it, which
## is the only way to know a body is right.
##
## This is also how the reference games do it. A BG3 character carries a
## single CharacterVisualResourceID pointing at a bundle that owns the
## meshes and the skeleton, with animation bound through that skeleton
## rather than through the character — and its BOUNDS live with the visual
## too, which is the argument for size ending up here in a later pass.
##
## Adopted by Unit._enter_tree() when a UnitDefinition names one. Units
## whose definition names nothing keep whatever body their scene was
## authored with, so nothing changes until a definition opts in.

## The library this body animates from. May legitimately hold no clips at
## all — a whitebox body is exactly that — which UnitAnimator now handles
## rather than stalling on (see its _advance_to_next_phase).
@export var animation_player: AnimationPlayer

@export_group("Clip Names")
## Empty means "this body has no such clip", which is a supported answer
## and not a mistake: it plays nothing and the sequence moves on. Only a
## name that is given and cannot be found is worth a warning.
@export var idle_animation: String = ""
@export var walk_animation: String = ""
@export var hit_animation: String = ""
@export var death_animation: String = ""

@export_group("Armed Animation")
@export var armed_enter_animation: String = ""
@export var armed_hold_animation: String = ""
@export var armed_exit_animation: String = ""

@export_group("Flight Animation")
## While the unit is in the air these stand in for idle and walk; empty
## means the ground clip plays in the air too. Takeoff plays as the unit
## lifts off and land as it touches down, each then resting on whichever
## idle is current.
@export var fly_idle_animation: String = ""
@export var fly_move_animation: String = ""
@export var takeoff_animation: String = ""
@export var land_animation: String = ""

@export_group("Ladder Animation")
## A one-rung climbing loop, in place, with the height it climbs in its
## "rise" metadata (tools/make_ladder_animations.gd); played forwards up
## a ladder and backwards down one. Empty means walking on the rungs.
@export var climb_animation: String = ""

@export_group("Presentation")
## The silhouette drawn behind the body when hovered or selected. Skinned
## to THIS body's skeleton, which is the whole reason it cannot live on
## the Unit: an outline is a second copy of one specific mesh on one
## specific rig.
@export var outline_mesh: MeshInstance3D
## The ring at the feet. Belongs to the body because it has to match the
## body's footprint: at runtime UnitSelection reads the ring's radius from
## this mesh, then clears it and projects a decal ring onto the ground in
## its place, so the mesh is only ever seen in the editor.
@export var highlight_mesh: MeshInstance3D

@export_group("Extent")
## What the NAVIGATION grid is told this body is. The C++ reads radius and
## avoidance_margin off the Unit by duck-typing and sweeps clearance across
## every Y-layer `height` spans, so these three numbers are the whole of
## what makes a dragon path like a dragon:
##
##     clearance      = radius + avoidance_margin
##     vertical_cells = ceil(height / CELL_SIZE)
##
## They live on the BODY, beside the shape they approximate, so they can be
## checked by eye against it rather than guessed in a resource file. That
## is also where BG3 keeps them — Bounds Min/Max sit in the VisualBank, not
## in the character's stats.
##
## DEFAULTS REPRODUCE THE PROJECT'S EXISTING NUMBERS, and avoidance_margin
## is the one to be careful with: unit.gd declares 0.15, but unit.tscn has
## always overridden it to 0.25, so 0.25 is what every unit has actually
## been navigating with. A body declaring the script default would quietly
## re-tune the movement of all 32 demons.
@export var radius: float = 0.25
@export var avoidance_margin: float = 0.25
@export var height: float = 2.0
## The Size Modifier this body was built at (see SizeModifier). A unit of
## another SM wears it scaled by the difference, extent and all: a man-sized
## body on a dragon (SM +2) is worn two and a half times over, while a body
## modelled at a dragon's true size says 2 here and is worn as it is.
@export var authored_size_modifier: int = 0

## The body's PHYSICAL shape, authored here and copied onto the Unit's own
## direct-child CollisionShape3D at spawn.
##
## It cannot do the collision from in here, and that is not a workaround —
## Godot ignores nested shapes outright: "Indirect child nodes will be
## ignored and won't be used as collision shapes." Silently, with no error.
## So this node is a TEMPLATE. It exists in the model scene because that is
## the only place it can be positioned against the mesh by eye, which is
## the entire argument for authoring a body instead of computing one.
##
## The editor will show a configuration warning on it for not being under a
## CollisionObject3D. That warning is correct and expected; the node is
## deliberately inert here.
##
## Null is allowed: a body that declares no shape leaves the Unit's own
## authored one alone.
@export var collision_shape: CollisionShape3D

## Named points on this body that other systems aim at.
##
## Before this there was one, found by string search from a single caller,
## with everything else guessing from a constant. Eye height in particular
## was declared in FIVE places — LineOfSight's default parameter,
## AreaTargeting's own export, DetectionManager's constant, and two
## indicator offsets, one of which carries a comment explaining that it has
## to match the first. All of them said 1.5, for every creature.
##
## A dragon does not see from 1.5 m, and no formula gets a dragon and a
## pixie right at once. Naming the points and letting the body place them
## is the only thing that does.
##
## MUZZLE is not declared on the body: it is the Muzzle marker on the held
## weapon's scene, where a shot leaves the gun, and the hand when nothing
## held has one.
enum Anchor { HEAD, EYE, CHEST, GROUND, HAND, MUZZLE }

@export_group("Anchors")
## Where a camera frames the face, and where floating UI belongs.
@export var head_anchor: Node3D
## Where this body SEES from, and where its shots originate.
@export var eye_anchor: Node3D
## Centre of mass — targeting, impacts, body-centred effects.
@export var chest_anchor: Node3D
## The feet. Selection rings, decals, anything that sits on the floor.
@export var ground_anchor: Node3D
## The casting hand - where a spell leaves the body. Put it on a
## BoneAttachment3D so it follows the hand through the cast; read at the
## moment of release, it is wherever the animation has put the hand.
@export var hand_anchor: Node3D
## Where a held weapon sits in each hand, on a BoneAttachment3D so it
## follows the hand. Oriented so a weapon scene's +Y leaves the thumb
## side of the fist and +Z faces the way the knuckles do (WeaponData.
## model_scene). Null means this body holds nothing in that hand - a
## demon's claws are part of its body.
@export var main_hand_grip: Node3D
@export var off_hand_grip: Node3D

## Where an equipped weapon that is NOT in hand is carried (UnitWeapons):
## two across the back, one on each hip. Each is a frame, not a fit: its
## origin sits on the body's surface, +X points straight away from the
## body, +Y the way a carried item's handle end points (up and over the
## shoulder, up out of the belt). UnitWeapons lays the item flat along
## it. Null builds the socket at runtime on the humanoid bones (see
## SHEATH_FRAMES); a body that holds nothing (no grips) carries nothing.
enum SheathSocket { BACK_A, BACK_B, HIP_MAIN, HIP_OFF }

@export_group("Sheaths")
@export var back_sheath_a: Node3D
@export var back_sheath_b: Node3D
@export var hip_sheath_main: Node3D
@export var hip_sheath_off: Node3D

@export_group("Gaze")
## The bone modifier that turns this body's head toward what it is looking
## at. Optional, and null is a real answer meaning "this body does not
## track anything" — a floating orb has no neck to turn.
##
## DECLARE ONE for any body whose rig is not a Godot humanoid. bone_name
## and forward_axis are per-rig facts: the bone may not be called "Head",
## and a body's head can face down any axis its artist chose. The fallback
## below guesses both, and a guess is exactly what anchor_position's own
## header warns against for the same reason.
@export var look_at_modifier: LookAtModifier3D

## What the fallback drives, when the body has not declared a modifier.
## The standard name in Godot's humanoid bone profile.
const FALLBACK_GAZE_BONE: StringName = &"Head"
## How long the head takes to come around. Handled by the modifier itself
## rather than by a Tween here.
const GAZE_TURN_SECONDS: float = 0.25
## How far the head may turn before it stops following.
##
## LookAtModifier3D enables no limit by default — use_angle_limitation is
## off, and turning it on alone changes nothing because both limit angles
## sit at 2*PI. Left that way, someone speaking from behind rotates a head
## the full way round. It never shows in a two-person conversation where
## the participants face each other, which is exactly why it would ship.
##
## A neck manages roughly 70 degrees of yaw and 45 of pitch before the
## shoulders have to help. Past that the gaze simply stops following,
## which reads as "they cannot see you" rather than as an owl.
const GAZE_YAW_LIMIT_DEGREES: float = 70.0
const GAZE_PITCH_LIMIT_DEGREES: float = 45.0

## A named instant in a clip, from a Call Method key on the clip's
## method track calling release() or impact() below (track path ".." from
## an AnimationPlayer under the imported body). The moment is a fact
## about the motion — the frame the hand comes forward — so it lives in
## the clip; what it MEANS is UnitAnimator's business, which relays it to
## the ability under way. Nothing here knows about abilities.
signal moment(name: StringName)

var _gaze_modifier: LookAtModifier3D = null
var _gaze_release: Tween = null
var _gaze_resolved: bool = false
var _gaze_point: Node3D = null


## Method-track target: the cast lets go here (the projectile leaves).
func release() -> void:
	moment.emit(&"release")


## Method-track target: the blow connects, the feet leave the ground.
func impact() -> void:
	moment.emit(&"impact")


## The AnimationPlayer to drive, falling back to a search when the export
## is unset.
##
## The fallback exists because the common case is a model built around an
## imported .glb, which brings its own AnimationPlayer at a path the
## author did not choose. Requiring the reference to be wired by hand
## would make every new body a two-step job for no benefit.
func resolve_animation_player() -> AnimationPlayer:
	if is_instance_valid(animation_player):
		return animation_player
	return _find_animation_player(self)


func _find_animation_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var deeper: AnimationPlayer = _find_animation_player(child)
		if deeper:
			return deeper
	return null


## A named point on this body, in world space.
##
## Falls back to a proportion of `height` when the body has not declared
## one, and THOSE PROPORTIONS ARE NOT ARBITRARY: at the project's standing
## height of 2.0 they reproduce the exact constants the game already used —
## 1.7 for the face (the old FaceAnchor, and the old `height * 0.85`), and
## 1.5 for the eye (LineOfSight's long-standing default). A body that
## declares nothing therefore behaves precisely as it did.
##
## The fallback is a floor, not the plan. It is right for a humanoid and
## wrong for anything else, which is the whole reason a body gets to
## overrule it by placing a node where the point actually is.
func anchor_position(kind: Anchor) -> Vector3:
	var declared: Node3D = _declared(kind)
	if is_instance_valid(declared):
		return declared.global_position
	# height is as authored; the body may be worn scaled (Unit._wear_size).
	return global_position + Vector3(0.0, height * global_basis.get_scale().y * _fallback_ratio(kind), 0.0)


func _declared(kind: Anchor) -> Node3D:
	match kind:
		Anchor.HEAD: return head_anchor
		Anchor.EYE: return eye_anchor
		Anchor.CHEST: return chest_anchor
		Anchor.GROUND: return ground_anchor
		Anchor.HAND: return hand_anchor
		Anchor.MUZZLE: return _held_muzzle()
	return null


# Held weapons are added at runtime, so they have no owner to find by.
func _held_muzzle() -> Node3D:
	for grip: Node3D in [main_hand_grip, off_hand_grip]:
		if is_instance_valid(grip):
			var muzzle := grip.find_child("Muzzle", true, false) as Node3D
			if muzzle:
				return muzzle
	return hand_anchor


## Where a sheath is built when the body declares none, in the skeleton's
## space - the character's frame, as tools/pose_builder.gd has it: metres,
## facing +Z, its left +X. Measured off the UAL mannequin (UAL1_Standard
## .glb): the shoulder blades stand out to z -0.16 between 1.2 and 1.5 m,
## the pelvis is +-0.16 wide at 0.9 m. Back items cross over the upper
## back, handle ends toward the shoulders; hip items hang at the side,
## handle up and forward, tip down and back, behind where the arm hangs.
## Riding UpperChest and Hips so they move with the torso, not the arms.
## Right for a humanoid of that build, a guess for anything else -
## declare the export to overrule it.
const SHEATH_FRAMES: Dictionary = {
	SheathSocket.BACK_A: {"bones": [&"UpperChest", &"Chest", &"Spine"],
		"origin": Vector3(0.0, 1.25, -0.165), "up": Vector3(-0.45, 0.89, 0.0), "out": Vector3(0, 0, -1)},
	SheathSocket.BACK_B: {"bones": [&"UpperChest", &"Chest", &"Spine"],
		"origin": Vector3(0.0, 1.25, -0.165), "up": Vector3(0.45, 0.89, 0.0), "out": Vector3(0, 0, -1)},
	SheathSocket.HIP_MAIN: {"bones": [&"Hips"],
		"origin": Vector3(-0.18, 0.92, -0.04), "up": Vector3(0.0, 0.89, 0.45), "out": Vector3(-1, 0, 0)},
	SheathSocket.HIP_OFF: {"bones": [&"Hips"],
		"origin": Vector3(0.18, 0.92, -0.04), "up": Vector3(0.0, 0.89, 0.45), "out": Vector3(1, 0, 0)},
}

## SheathSocket -> the socket built for it (or null: this body can't have it).
var _built_sheaths: Dictionary = {}


## The frame a weapon not in hand is carried on, or null: a body without
## grips carries nothing, as it holds nothing.
func sheath_socket(which: SheathSocket) -> Node3D:
	var declared: Node3D = _declared_sheath(which)
	if is_instance_valid(declared):
		return declared
	if not is_instance_valid(main_hand_grip) and not is_instance_valid(off_hand_grip):
		return null
	if not _built_sheaths.has(which) or (_built_sheaths[which] != null and not is_instance_valid(_built_sheaths[which])):
		_built_sheaths[which] = _build_sheath(which)
	return _built_sheaths[which]


func _declared_sheath(which: SheathSocket) -> Node3D:
	match which:
		SheathSocket.BACK_A: return back_sheath_a
		SheathSocket.BACK_B: return back_sheath_b
		SheathSocket.HIP_MAIN: return hip_sheath_main
		SheathSocket.HIP_OFF: return hip_sheath_off
	return null


## A BoneAttachment3D on the frame's bone, with the socket under it placed
## so that at the rest pose it sits exactly on the frame. Built at runtime
## and never saved, like the fallback gaze.
func _build_sheath(which: SheathSocket) -> Node3D:
	var skeleton: Skeleton3D = _find_skeleton(self)
	if skeleton == null:
		return null
	var frame: Dictionary = SHEATH_FRAMES[which]
	var bone: int = -1
	for bone_name: StringName in frame["bones"]:
		bone = skeleton.find_bone(bone_name)
		if bone != -1:
			break
	if bone == -1:
		return null
	var attachment := BoneAttachment3D.new()
	attachment.name = "Sheath" + String(SheathSocket.keys()[which]).to_pascal_case()
	skeleton.add_child(attachment)
	attachment.bone_name = skeleton.get_bone_name(bone)
	var socket := Node3D.new()
	socket.name = "Socket"
	attachment.add_child(socket)
	var out: Vector3 = frame["out"]
	var up_hint: Vector3 = frame["up"]
	var up: Vector3 = (up_hint - out * out.dot(up_hint)).normalized()
	var wanted := Transform3D(Basis(out, up, out.cross(up)), frame["origin"])
	socket.transform = skeleton.get_bone_global_rest(bone).affine_inverse() * wanted
	return socket


func _fallback_ratio(kind: Anchor) -> float:
	match kind:
		Anchor.HEAD: return 0.85   # 1.70 at height 2.0 — the old FaceAnchor
		Anchor.EYE: return 0.75    # 1.50 at height 2.0 — the old eye_height
		Anchor.CHEST: return 0.55
		Anchor.GROUND: return 0.0
		Anchor.HAND: return 0.55   # no hand declared: the chest
		Anchor.MUZZLE: return 0.55
	return 0.0


## Turn this body's head toward `target`. Returns whether it could.
##
## False is normal, not an error: a body with no rig, no Head bone and no
## declared modifier simply does not track, and every caller is expected to
## carry on without it. That is the whole degradation story — no warning,
## no fallback rotation applied to the root, nothing that would make a
## bodyless unit spin.
func gaze_at(target: Node3D) -> bool:
	var modifier: LookAtModifier3D = _resolve_gaze_modifier()
	if modifier == null or not is_instance_valid(target):
		return false
	if _gaze_release:
		_gaze_release.kill()
		_gaze_release = null
	modifier.target_node = modifier.get_path_to(target)
	modifier.influence = 1.0
	return true


## Release the head back to whatever the animation is doing, at once or
## eased over ease_seconds.
##
## At once snaps a body holding a strong turn: fine when the camera cuts
## away on the same frame, as it does when a conversation ends. A gaze
## that ends while the shot holds (Fire Breath's) eases instead.
func stop_gazing(ease_seconds: float = 0.0) -> void:
	if not is_instance_valid(_gaze_modifier):
		return
	if _gaze_release:
		_gaze_release.kill()
		_gaze_release = null
	if ease_seconds <= 0.0:
		_gaze_modifier.influence = 0.0
		return
	_gaze_release = create_tween()
	_gaze_release.tween_property(_gaze_modifier, "influence", 0.0, ease_seconds)


## The node OTHER bodies should aim at to look this one in the face.
##
## A Node3D rather than a position, because LookAtModifier3D tracks a node
## and re-reads it every frame — which is what lets a gaze follow someone
## who is walking. Prefers the declared head anchor; otherwise places a
## marker at the same fallback proportion anchor_position uses, so the two
## can never disagree about where a face is.
func gaze_point() -> Node3D:
	if is_instance_valid(head_anchor):
		return head_anchor
	if is_instance_valid(_gaze_point):
		return _gaze_point
	_gaze_point = Marker3D.new()
	_gaze_point.name = "GazePoint"
	add_child(_gaze_point)
	_gaze_point.position = Vector3(0.0, height * _fallback_ratio(Anchor.HEAD), 0.0)
	return _gaze_point


## Resolved once and cached, including the null answer — a body with no
## skeleton must not re-walk its whole subtree on every line of dialogue.
func _resolve_gaze_modifier() -> LookAtModifier3D:
	if _gaze_resolved:
		return _gaze_modifier
	_gaze_resolved = true
	if is_instance_valid(look_at_modifier):
		_gaze_modifier = look_at_modifier
	else:
		_gaze_modifier = _build_fallback_gaze()
	return _gaze_modifier


## Built at runtime rather than authored, and never saved to the scene.
##
## A SkeletonModifier3D has to be a child of the Skeleton3D it drives, so
## this cannot live on CharacterModel itself — and adding it here rather
## than in every model scene is what makes the capability arrive for free
## on bodies nobody has hand-edited. Same standing as anchor_position's
## proportions: right for a humanoid, wrong for anything else, and
## overruled by declaring a real modifier.
func _build_fallback_gaze() -> LookAtModifier3D:
	var skeleton: Skeleton3D = _find_skeleton(self)
	if skeleton == null or skeleton.find_bone(FALLBACK_GAZE_BONE) == -1:
		return null
	var made := LookAtModifier3D.new()
	made.name = "FallbackGaze"
	skeleton.add_child(made)
	# THE BONE INDEX, NOT THE NAME — defensively, not as a bug fix.
	#
	# A SkeletonModifier3D resolves bone_name through get_skeleton(), and
	# get_skeleton() is null until the modifier's own tree entry has been
	# processed. When the skeleton is ALREADY in the tree, as it is here,
	# add_child() fires that synchronously and bone_name resolves fine —
	# measured, not assumed. It comes back -1 only when the skeleton is
	# itself still entering, which this path never does.
	#
	# The index is nonetheless what gets assigned, because it cannot depend
	# on that timing at all and it is already in hand from the guard above.
	made.bone = skeleton.find_bone(FALLBACK_GAZE_BONE)
	made.duration = GAZE_TURN_SECONDS
	# primary is yaw (rotation about Y, the modifier's own default) and
	# secondary is pitch. symmetry_limitation is already true, so one angle
	# covers turning both ways.
	made.use_angle_limitation = true
	made.primary_limit_angle = deg_to_rad(GAZE_YAW_LIMIT_DEGREES)
	made.secondary_limit_angle = deg_to_rad(GAZE_PITCH_LIMIT_DEGREES)
	# Inert until something actually asks for a gaze.
	made.influence = 0.0
	return made


func _find_skeleton(node: Node) -> Skeleton3D:
	for child in node.get_children():
		if child is Skeleton3D:
			return child
		var deeper: Skeleton3D = _find_skeleton(child)
		if deeper:
			return deeper
	return null
