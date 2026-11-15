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
## WHEN IT ENDS the lead goes back to its own standing clip. The partner is
## left as the clip left them.
##
## A KILL. When the clip says the partner ends dead (kills_partner), the
## partner dies as the clip ends, lying as the clip left them, not falling a
## second time in their own death clip.
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

## [position, flat facing] each body started from and is going to.
var _from: Array = []
var _to: Array = []
var _elapsed: float = 0.0


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
	owner_stage.clip(lead, clip.lead_clip, true, BodyAnimationTree.Layer.BODY, blend)
	owner_stage.clip(partner, clip.partner_clip, true, BodyAnimationTree.Layer.BODY, blend)
	owner_stage.run(self)


func tick(delta: float) -> bool:
	var owner_stage: CinematicStage = _live_stage()
	if owner_stage == null or _to.is_empty():
		return false
	_elapsed += delta
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
	var leading: Unit = owner_stage.actor(lead)
	var stance: UnitAnimator = leading.animator() if leading else null
	if stance and stance.idle_animation != "":
		owner_stage.clip(lead, stance.idle_animation, true, BodyAnimationTree.Layer.BODY, blend)
	if not clip.kills_partner:
		return
	var dying: Unit = owner_stage.actor(partner)
	if dying == null or not dying.is_alive():
		return
	# The unit's death is the clip's last frame: it has already fallen.
	var animator: UnitAnimator = dying.animator()
	var lies: bool = animator != null and animator.animation_player != null \
			and animator.animation_player.has_animation(clip.partner_clip)
	if lies:
		animator.death_animation = clip.partner_clip
	dying.die()
	if lies and animator.playback:
		animator.playback.seek(clip.length, true)


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
