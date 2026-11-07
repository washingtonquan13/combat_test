@tool
class_name WalkToBeat
extends BeatNode
## An actor walks to a mark: turns to the direction of travel, plays its
## walk clip, moves in a straight line, and stops EXACTLY on the mark in
## its idle clip.
##
## NOT Unit.move_to(). The real locomotion is the right thing for gameplay
## and the wrong thing for a shot: it routes around occupancy on the
## navigation grid, stops within arrival_tolerance rather than on the
## mark, refuses a unit that is busy or not commandable, and takes however
## long the route takes. A cutscene needs the opposite of each — a known
## path, a known duration, an exact end — so the body is moved here, the
## same way the stage already places one, and only the CLIPS are borrowed
## from the unit (its animator's own walk and idle names).
##
## RUNS IN REAL TIME, not timeline time: a walk keeps going while a line
## holds the timeline for the player, which is what a person talking over
## someone crossing the room looks like. A walk still going when the last
## key passes keeps the scene open until it arrives (is_running).
##
## Skipped, the actor is on the mark, turned the way it was travelling.

## Speed a preview assumes when `speed` is 0 — Unit's own default
## move_speed; the editor has no unit to ask.
const PREVIEW_MOVE_SPEED: float = 4.0

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
## Where to stop: a mark, a declared world mark, or a role (walk up to
## where they are standing).
@export var mark: StringName = &"":
	set(value):
		mark = value
		_changed()
## Metres per second. 0 = the unit's own move_speed.
@export_range(0.0, 20.0, 0.1, "suffix:m/s") var speed: float = 0.0
## Seconds, overriding speed when set. For a walk that must land on a beat
## of the timeline whatever the distance turns out to be.
@export_range(0.0, 30.0, 0.1, "suffix:s") var duration: float = 0.0

var _from: Vector3 = Vector3.ZERO
var _to: Vector3 = Vector3.ZERO
var _seconds: float = 0.0
var _elapsed: float = 0.0


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null:
		return
	match property.name:
		"role":
			_suggest_names(property, owner_stage.role_names())
		"mark":
			_suggest_names(property, _role_and_spot_names(owner_stage))


func _fire(owner_stage: CinematicStage) -> void:
	var walker: Unit = owner_stage.actor(role)
	var goal: Node3D = owner_stage.locate(mark)
	if walker == null or goal == null:
		push_warning("WalkToBeat '%s': '%s' or '%s' does not resolve." % [name, role, mark])
		return
	_from = walker.global_position
	_to = goal.global_position
	_seconds = _duration_for(_from.distance_to(_to), walker.move_speed)
	_elapsed = 0.0
	walker.snap_face_point(_to)
	var animator: UnitAnimator = walker.animator()
	if animator:
		owner_stage.clip(role, animator.walk_animation)
	owner_stage.sync_marker(role)
	owner_stage.run(self)


func tick(delta: float) -> bool:
	var owner_stage: CinematicStage = _live_stage()
	var walker: Unit = owner_stage.actor(role) if owner_stage else null
	if walker == null:
		return false
	_elapsed += delta
	if _seconds <= 0.0 or _elapsed >= _seconds:
		_arrive(owner_stage, walker)
		return false
	walker.global_position = _from.lerp(_to, _elapsed / _seconds)
	owner_stage.sync_marker(role)
	return true


func _finish(owner_stage: CinematicStage) -> void:
	var walker: Unit = owner_stage.actor(role)
	if walker:
		_arrive(owner_stage, walker)


## On the mark, not near it, and back to standing.
func _arrive(owner_stage: CinematicStage, walker: Unit) -> void:
	walker.global_position = _to
	owner_stage.sync_marker(role)
	var animator: UnitAnimator = walker.animator()
	if animator:
		owner_stage.clip(role, animator.idle_animation)


## The end state with no clip: on the mark, facing the way the walk would
## have gone from wherever the earlier beats left the actor.
func _skip(owner_stage: CinematicStage) -> void:
	var walker: Unit = owner_stage.actor(role)
	var goal: Node3D = owner_stage.locate(mark)
	if walker == null or goal == null:
		return
	walker.snap_face_point(goal.global_position)
	walker.global_position = goal.global_position
	owner_stage.sync_marker(role)


func _duration_for(distance: float, unit_speed: float) -> float:
	if duration > 0.0:
		return duration
	var pace: float = speed if speed > 0.0 else unit_speed
	return distance / pace if pace > 0.0 else 0.0


## Along the straight line from wherever the earlier beats left the
## stand-in, turned to the direction of travel.
func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null or seconds_since_fire < 0.0:
		return
	var body: Node3D = _stand_in(owner_stage, role)
	var goal: Node3D = _preview_spot(owner_stage, mark)
	if body == null or goal == null or goal == body:
		return
	var from: Vector3 = body.global_position
	var to: Vector3 = goal.global_position
	var seconds: float = _duration_for(from.distance_to(to), PREVIEW_MOVE_SPEED)
	var progress: float = 1.0 if seconds <= 0.0 else clampf(seconds_since_fire / seconds, 0.0, 1.0)
	_preview_face(body, to)
	body.global_position = from.lerp(to, progress)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	_check_spot(warnings, owner_stage, "mark", mark)
	return warnings
