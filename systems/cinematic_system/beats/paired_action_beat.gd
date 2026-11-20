@tool
class_name PairedActionBeat
extends BeatNode
## Two actors do one thing together: a PairedClip, the lead's half on one
## body and the partner's on the other, started on the same frame, with the
## two bodies brought onto the places the clips were made for.
##
## WHY A BEAT AND NOT TWO ClipBeats. Two clips keyed at one time play
## together, but a blade only ends in a chest if the two bodies are exactly
## as far apart as they were when the clips were made, and facing exactly
## so. Actors arrive from gameplay or from a walk, a hand's width out or
## half a metre. This beat owns the distance: it reads where the two stand
## when it fires and moves both onto the pair's places before the contact.
##
## WHERE THE PAIR GOES. With no mark, where the two already are: the line
## from the lead to the partner is kept, the point midway between them is
## kept, and each body takes up half of what is wrong. With `mark`, the lead
## goes on the mark facing the way it points, and the partner where that
## puts them.
##
## HOW THEY GET THERE. Slid and turned, eased, over the first SETTLED part
## of the time before contact, under the clips' own first steps. A stab's
## wind-up covers half a metre; it will not cover three. Bring the actors
## near first (WalkToBeat, PlaceBeat) and leave this the last of it.
##
## THE FLOOR. Each body keeps the height it stands at. The pair is made for
## level ground.
##
## WHEN IT ENDS the lead goes back to its own standing clip, and so does a
## partner the clip leaves alive. Each is moved to where its clip carried
## it (PairedClip.lead_end, partner_end) on that frame, so a lunge that
## stepped in stays in and a stagger stays back.
##
## A KILL. When the clip says the partner ends dead (kills_partner), the
## partner dies as the clip ends, lying as the clip left them, not falling a
## second time in their own death clip.
##
## IMPACTS. Each of the clip's contacts (ContactEvent) goes to the stage's
## impact dispatcher on the frame the clip crosses it, with `impacts` saying
## what plays there. The beat first puts both bodies on the contact's exact
## time, so the impact lands on the touch itself, not a frame past it. The
## sound is started one frame ahead (impact_heard), the rest on the frame.
##
## RUNS IN REAL TIME for the clip's length, and keeps the scene open until
## it is done. Skipped, both are on their places and the partner is dead on
## the ground.

## The part of the time before contact by which both bodies are in place.
const SETTLED: float = 0.75

@export var lead: StringName = &"":
	set(value):
		lead = value
		_changed()
@export var partner: StringName = &"":
	set(value):
		partner = value
		_changed()
@export var clip: PairedClip = null:
	set(value):
		clip = value
		_changed()
## Where the lead stands, facing the way the mark points. Empty = the pair
## is set where the two already are. See the header.
@export var mark: StringName = &"":
	set(value):
		mark = value
		_changed()
## Seconds to blend into the clips over. Below 0 = each body's own.
@export_range(-1.0, 3.0, 0.05, "suffix:s") var blend: float = -1.0
## What the clip's contacts look and sound like. Empty = the contacts still
## shake the camera, with nothing seen or heard.
@export var impacts: ImpactKit = null
## [position, flat facing] each body started from and is going to.
var _from: Array = []
var _to: Array = []
var _elapsed: float = 0.0
## The next of clip.contacts to fire, and whether its sound already has.
var _next: int = 0
var _heard: bool = false


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null:
		return
	if property.name in ["lead", "partner"]:
		_suggest_names(property, owner_stage.role_names())
	elif property.name == "mark":
		_suggest_names(property, owner_stage.spot_names())


func _fire(owner_stage: CinematicStage) -> void:
	if not _aim(owner_stage):
		push_warning("PairedActionBeat '%s': '%s', '%s' or the clip does not resolve." % [name, lead, partner])
		return
	_elapsed = 0.0
	_next = 0
	_heard = false
	owner_stage.clip(lead, clip.lead_clip, true, BodyAnimationTree.Layer.BODY, blend)
	owner_stage.clip(partner, clip.partner_clip, true, BodyAnimationTree.Layer.BODY, blend)
	owner_stage.run(self)


func tick(delta: float) -> bool:
	var owner_stage: CinematicStage = _live_stage()
	if owner_stage == null or _to.is_empty():
		return false
	_elapsed += delta
	_contact(owner_stage, delta)
	_stand(owner_stage, _settled(_elapsed))
	if _elapsed < clip.length:
		return true
	_end(owner_stage)
	return false


func _finish(owner_stage: CinematicStage) -> void:
	if _to.is_empty():
		return
	_stand(owner_stage, 1.0)
	_end(owner_stage)


func _skip(owner_stage: CinematicStage) -> void:
	if not _aim(owner_stage):
		return
	_stand(owner_stage, 1.0)
	_end(owner_stage)


## Fires the contact this frame crossed, and starts the sound of one the
## next frame will cross (a frame being as long as this one).
func _contact(owner_stage: CinematicStage, delta: float) -> void:
	if _next >= clip.contacts.size():
		return
	var event: ContactEvent = clip.contacts[_next]
	if event == null:
		_next += 1
		return
	if _elapsed >= event.time:
		_elapsed = event.time
		for role: StringName in [lead, partner]:
			var tree: BodyAnimationTree = BodyAnimationTree.of(owner_stage.body(role))
			if tree:
				tree.seek(event.time, true)
		var roles: Array[StringName] = _roles(event)
		owner_stage.impact(event, roles[0], roles[1], impact_point(owner_stage, event), impacts)
		_next += 1
		_heard = false
	elif not _heard and delta > 0.0 and _elapsed + delta >= event.time:
		_heard = true
		owner_stage.impact_heard(event, impact_point(owner_stage, event), impacts)


## [striker role, target role] on this stage.
func _roles(event: ContactEvent) -> Array[StringName]:
	var striker: StringName = lead if event.striker == ContactEvent.Who.LEAD else partner
	var target: StringName = lead if event.target_side == ContactEvent.Who.LEAD else partner
	return [striker, target]


## Where `event` touches, in the world, from the two bodies as they stand:
## the midpoint of the closest points of two blades, or the point on the
## striker's blade (or bone) nearest the target bone.
func impact_point(owner_stage: CinematicStage, event: ContactEvent) -> Vector3:
	var roles: Array[StringName] = _roles(event)
	var striking: CharacterModel = StandIn.body_of(owner_stage.actor(roles[0]))
	var struck: CharacterModel = StandIn.body_of(owner_stage.actor(roles[1]))
	if striking == null or struck == null:
		return owner_stage.point(roles[1])
	var edge: PackedVector3Array = blade(striking)
	if event.target == ContactEvent.BLADE or event.target == ContactEvent.BLADE_TIP:
		var guard: PackedVector3Array = blade(struck)
		if edge.is_empty() or guard.is_empty():
			return owner_stage.point(roles[1])
		if event.target == ContactEvent.BLADE_TIP:
			guard = PackedVector3Array([guard[1], guard[1]])
		var closest: PackedVector3Array = Geometry3D.get_closest_points_between_segments(
				edge[0], edge[1], guard[0], guard[1])
		return (closest[0] + closest[1]) * 0.5
	var spot: Vector3 = bone_point(struck, event.target)
	if edge.is_empty():
		return spot
	if event.effector == ContactEvent.BLADE_TIP:
		return edge[1].lerp(spot, 0.5)
	return Geometry3D.get_closest_point_to_segment(spot, edge[0], edge[1])


## [grip, point] of the weapon in `model`'s main hand, in the world: along
## the grip's +Y, as far as the weapon's meshes reach. Empty with no weapon.
static func blade(model: CharacterModel) -> PackedVector3Array:
	var grip: Node3D = model.main_hand_grip if model else null
	if grip == null or grip.get_child_count() == 0:
		return PackedVector3Array()
	var reach: float = 0.0
	var space: Transform3D = grip.global_transform.affine_inverse()
	for mesh: MeshInstance3D in grip.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = mesh.get_aabb()
		var local: Transform3D = space * mesh.global_transform
		for corner in 8:
			reach = maxf(reach, (local * box.get_endpoint(corner)).y)
	var hold: Transform3D = grip.global_transform
	return PackedVector3Array([hold.origin, hold * Vector3(0.0, reach, 0.0)])


static func bone_point(model: CharacterModel, bone: StringName) -> Vector3:
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false) as Skeleton3D
	var index: int = skeleton.find_bone(String(bone)) if skeleton else -1
	if index < 0:
		return model.global_position + Vector3.UP * 1.3
	return skeleton.global_transform * skeleton.get_bone_global_pose(index).origin


## How far onto its place a body is, 0 to 1, `seconds` into the clip.
func _settled(seconds: float) -> float:
	var window: float = clip.contact_time * SETTLED
	return smoothstep(0.0, 1.0, seconds / window) if window > 0.0 else 1.0


## Works out where both bodies are and where the pair puts them. False when
## either is missing.
func _aim(owner_stage: CinematicStage) -> bool:
	_from = []
	_to = []
	var first: Node3D = owner_stage.body(lead) if clip else null
	var second: Node3D = owner_stage.body(partner) if clip else null
	if first == null or second == null:
		return false
	_from = [[first.global_position, _forward(first)], [second.global_position, _forward(second)]]
	_to = places(first.global_position, second.global_position,
			owner_stage.locate(mark) if mark != &"" else null)
	return true


## [[lead position, facing], [partner position, facing]] for a pair whose
## bodies stand at `lead_at` and `partner_at`, or whose lead goes on `on`.
func places(lead_at: Vector3, partner_at: Vector3, on: Node3D = null) -> Array:
	var offset: Vector3 = clip.partner_from_lead.origin
	offset.y = 0.0
	var turn: float
	var lead_to: Vector3
	if on:
		var ahead: Vector3 = -on.global_transform.basis.z
		turn = atan2(ahead.x, ahead.z)
		lead_to = Vector3(on.global_position.x, lead_at.y, on.global_position.z)
	else:
		var across := Vector3(partner_at.x - lead_at.x, 0.0, partner_at.z - lead_at.z)
		if across.length() < 0.001:
			across = Vector3.BACK
		turn = atan2(across.x, across.z) - atan2(offset.x, offset.z)
		var middle: Vector3 = (lead_at + partner_at) * 0.5
		lead_to = middle - Basis(Vector3.UP, turn) * offset * 0.5
		lead_to.y = lead_at.y
	var frame := Basis(Vector3.UP, turn)
	var partner_to: Vector3 = lead_to + frame * offset
	partner_to.y = partner_at.y
	var partner_ahead: Vector3 = frame * clip.partner_from_lead.basis.z
	partner_ahead.y = 0.0
	return [[lead_to, frame.z], [partner_to, partner_ahead.normalized()]]


func _stand(owner_stage: CinematicStage, part: float) -> void:
	var roles: Array[StringName] = [lead, partner]
	for i in 2:
		var at: Vector3 = (_from[i][0] as Vector3).lerp(_to[i][0], part)
		var was: Vector3 = _from[i][1]
		var will: Vector3 = _to[i][1]
		var yaw: float = lerp_angle(atan2(was.x, was.z), atan2(will.x, will.z), part)
		owner_stage.move(roles[i], at)
		owner_stage.face(roles[i], at + Vector3(sin(yaw), 0.0, cos(yaw)))


func _end(owner_stage: CinematicStage) -> void:
	_to = []
	# A scene's clip is what its body rests on, so one that ends starts
	# again. The lead goes back to standing instead.
	_stand_down(owner_stage, lead, clip.lead_end)
	if not clip.kills_partner:
		_stand_down(owner_stage, partner, clip.partner_end)
		return
	var dying: Unit = owner_stage.actor(partner)
	if dying == null or not dying.is_alive():
		return
	# The unit's death is the clip's last frame: it has already fallen.
	HurtBeat.kill(dying, clip.partner_clip)


## `role` back to its standing clip, its place moved by `moved` (in its own
## space) on the same frame, the travel its clip had in the hips handed to
## the root.
func _stand_down(owner_stage: CinematicStage, role: StringName, moved: Transform3D) -> void:
	var unit_now: Unit = owner_stage.actor(role)
	var stance: UnitAnimator = unit_now.animator() if unit_now else null
	if stance == null or stance.idle_animation == "":
		return
	owner_stage.clip(role, stance.idle_animation, true, BodyAnimationTree.Layer.BODY, blend)
	if moved.is_equal_approx(Transform3D.IDENTITY):
		return
	var shown: Node3D = owner_stage.body(role)
	var model: Node3D = (shown as StandIn).body() if shown is StandIn \
			else unit_now.get_node_or_null(NodePath(StandIn.BODY_NAME)) as Node3D
	if shown == null or model == null:
		return
	var tree: BodyAnimationTree = BodyAnimationTree.of(model)
	if tree:
		tree.carry_root(model, moved)
	var frame: Basis = model.global_basis.orthonormalized()
	var step: Vector3 = frame * moved.origin
	step.y = 0.0
	var at: Vector3 = shown.global_position + step
	var ahead: Vector3 = _forward(shown).rotated(Vector3.UP, moved.basis.get_euler().y)
	owner_stage.move(role, at)
	owner_stage.face(role, at + ahead)


func _forward(body: Node3D) -> Vector3:
	var ahead: Vector3 = -body.global_transform.basis.z
	if body.has_method(&"visual_forward"):
		ahead = body.call(&"visual_forward")
	ahead.y = 0.0
	return ahead.normalized() if ahead.length() > 0.001 else Vector3.BACK


## The two stand-ins sliding onto their places from wherever the earlier
## beats left them.
func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null or clip == null or seconds_since_fire < 0.0:
		return
	var first: Node3D = _stand_in(owner_stage, lead)
	var second: Node3D = _stand_in(owner_stage, partner)
	if first == null or second == null:
		return
	var to: Array = places(first.global_position, second.global_position,
			owner_stage.local_mark(mark) if mark != &"" else null)
	var part: float = _settled(seconds_since_fire)
	var shown: Array[Node3D] = [first, second]
	for i in 2:
		shown[i].global_position = shown[i].global_position.lerp(to[i][0], part)
		if part >= 1.0:
			_preview_face(shown[i], shown[i].global_position + to[i][1])


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "lead", lead)
	_check_role(warnings, owner_stage, "partner", partner)
	if mark != &"":
		_check_spot(warnings, owner_stage, "mark", mark)
	if clip == null:
		warnings.append("'clip' is empty.")
	elif clip.lead_clip == "" or clip.partner_clip == "":
		warnings.append("The PairedClip names no clips.")
	return warnings
