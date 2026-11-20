@tool
class_name WalkPathBeat
extends BeatNode
## An actor walks a drawn route: a Path3D in the stage, followed from end to
## end at an even pace, turned to the way it is going, in its walk clip, and
## stopped on the path's last point in its idle clip.
##
## WHY A PATH AND NOT A CHAIN OF WalkToBeats. A walk between two marks is a
## straight line with a snap turn at each end, so a route round a corner is
## two beats, two durations to keep in step, and a body that pivots on the
## spot where they meet. A curve is one beat and one duration, and the body
## turns as the line does. The path is a child of the stage, so it moves
## with the stage's anchor and is drawn in the editor against preview_set.
##
## WHERE IT STARTS. From wherever the body is standing: when that is not the
## path's first point, a straight leg to it is walked first, inside the same
## duration. So a path can be drawn from where the actor is expected to be
## without the scene breaking when they are not quite there.
##
## THE GROUND. The path's own heights are followed, and with follows_ground
## each step is then dropped onto the floor under it, so a route up a ramp
## needs only its ends at about the right height. The floor is only believed
## within GROUND_REACH of the drawn height: over a gap the drawn line wins.
##
## RUNS IN REAL TIME, like WalkToBeat, and a walk still going when the last
## key passes keeps the scene open until it arrives.
##
## WALKING AND DOING. upper_animation_name plays on the upper body over the
## walk, a bow drawn and loosed on the move, and comes down on arrival.
##
## Skipped, the actor is on the path's last point, turned the way the path
## ends.

const PREVIEW_MOVE_SPEED: float = 4.0
## How far ahead along the route the body looks to decide its heading. Long
## enough that a corner is turned through rather than snapped.
const LOOK_AHEAD: float = 0.6
## A body nearer the path's start than this is taken to be on it.
const JOIN_SLACK: float = 0.15
const GROUND_REACH: float = 1.5

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
## The Path3D to follow, usually under the stage's Paths/.
@export_node_path("Path3D") var path: NodePath = NodePath(""):
	set(value):
		path = value
		_changed()
## Metres per second. 0 = the unit's own move_speed.
@export_range(0.0, 20.0, 0.1, "suffix:m/s") var speed: float = 0.0
## Seconds for the whole route, overriding speed when set.
@export_range(0.0, 60.0, 0.1, "suffix:s") var duration: float = 0.0
## The clip to move in. Empty = the unit's own walk clip.
@export var animation_name: String = ""
## A clip for the upper body over the walk, from the first step; one that
## does not loop comes down by itself when it ends. Empty = none.
@export var upper_animation_name: String = ""
## Drop each step onto the floor under it. See the header.
@export var follows_ground: bool = true

var _points: PackedVector3Array = PackedVector3Array()
## Distance along the route at each point.
var _reached: PackedFloat32Array = PackedFloat32Array()
var _seconds: float = 0.0
var _elapsed: float = 0.0


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "role":
		_suggest_names(property, owner_stage.role_names())


func route() -> Path3D:
	return get_node_or_null(path) as Path3D if not path.is_empty() else null


func _fire(owner_stage: CinematicStage) -> void:
	var walker: Unit = owner_stage.actor(role)
	if walker == null or not _lay(owner_stage.body(role).global_position):
		push_warning("WalkPathBeat '%s': '%s' or the path does not resolve." % [name, role])
		return
	_seconds = _duration_for(_length(), walker.move_speed)
	_elapsed = 0.0
	_step(owner_stage, walker, 0.0)
	var animator: UnitAnimator = walker.animator()
	if animator:
		owner_stage.clip(role, animation_name if animation_name != "" else animator.walk_animation)
		if upper_animation_name != "":
			owner_stage.clip(role, upper_animation_name, true, BodyAnimationTree.Layer.UPPER)
	owner_stage.run(self)


func tick(delta: float) -> bool:
	var owner_stage: CinematicStage = _live_stage()
	var walker: Unit = owner_stage.actor(role) if owner_stage else null
	if walker == null or _points.is_empty():
		return false
	_elapsed += delta
	if _seconds <= 0.0 or _elapsed >= _seconds:
		_arrive(owner_stage, walker)
		return false
	_step(owner_stage, walker, _length() * _elapsed / _seconds)
	return true


func _finish(owner_stage: CinematicStage) -> void:
	var walker: Unit = owner_stage.actor(role)
	if walker and not _points.is_empty():
		_arrive(owner_stage, walker)


func _arrive(owner_stage: CinematicStage, walker: Unit) -> void:
	_step(owner_stage, walker, _length())
	var animator: UnitAnimator = walker.animator()
	if animator:
		owner_stage.clip(role, animator.idle_animation)
		if upper_animation_name != "":
			owner_stage.clip(role, "", true, BodyAnimationTree.Layer.UPPER)


func _skip(owner_stage: CinematicStage) -> void:
	var walker: Unit = owner_stage.actor(role)
	if walker and _lay(owner_stage.body(role).global_position):
		_step(owner_stage, walker, _length())


## Puts the body `travelled` metres along the route, heading the way the
## route goes there.
func _step(owner_stage: CinematicStage, walker: Unit, travelled: float) -> void:
	var at: Vector3 = _at(travelled)
	if follows_ground and not walker.is_flying():
		var floor_y: float = NavigationGrid.ground_height_at(
				get_tree(), at + Vector3.UP * (GROUND_REACH * 0.5), walker)
		if absf(floor_y - at.y) <= GROUND_REACH:
			at.y = floor_y
	owner_stage.move(role, at)
	owner_stage.face(role, at + _heading(travelled))


## The route in world space: the path's baked points, led by a straight leg
## from `from` when that is not where the path starts. False with no path.
func _lay(from: Vector3) -> bool:
	_points = PackedVector3Array()
	_reached = PackedFloat32Array()
	var line: Path3D = route()
	if line == null or line.curve == null or line.curve.point_count < 2:
		return false
	var baked: PackedVector3Array = line.curve.get_baked_points()
	if baked.size() < 2:
		return false
	var first: Vector3 = line.global_transform * baked[0]
	if from.distance_to(first) > JOIN_SLACK:
		_points.append(from)
	for point in baked:
		_points.append(line.global_transform * point)
	var total: float = 0.0
	_reached.append(0.0)
	for i in range(1, _points.size()):
		total += _points[i - 1].distance_to(_points[i])
		_reached.append(total)
	return true


func _length() -> float:
	return _reached[_reached.size() - 1] if not _reached.is_empty() else 0.0


func _at(travelled: float) -> Vector3:
	if _points.is_empty():
		return Vector3.ZERO
	var along: float = clampf(travelled, 0.0, _length())
	var next: int = clampi(_reached.bsearch(along), 1, _points.size() - 1)
	var span: float = _reached[next] - _reached[next - 1]
	var part: float = (along - _reached[next - 1]) / span if span > 0.0 else 1.0
	return _points[next - 1].lerp(_points[next], clampf(part, 0.0, 1.0))


## The flat direction of travel at `travelled`: toward the point LOOK_AHEAD
## further on, and near the end the direction the route finishes in.
func _heading(travelled: float) -> Vector3:
	var start: float = clampf(travelled, 0.0, maxf(_length() - LOOK_AHEAD, 0.0))
	var ahead: Vector3 = _at(start + LOOK_AHEAD) - _at(start)
	ahead.y = 0.0
	return ahead.normalized() if ahead.length() > 0.001 else Vector3.ZERO


func _duration_for(distance: float, unit_speed: float) -> float:
	if duration > 0.0:
		return duration
	var pace: float = speed if speed > 0.0 else unit_speed
	return distance / pace if pace > 0.0 else 0.0


## Along the route from wherever the earlier beats left the stand-in. The
## editor has no floor to ask, so the drawn heights are shown as drawn.
func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null or seconds_since_fire < 0.0:
		return
	var shown: Node3D = _stand_in(owner_stage, role)
	if shown == null or not _lay(shown.global_position):
		return
	var seconds: float = _duration_for(_length(), PREVIEW_MOVE_SPEED)
	var progress: float = 1.0 if seconds <= 0.0 else clampf(seconds_since_fire / seconds, 0.0, 1.0)
	var travelled: float = _length() * progress
	shown.global_position = _at(travelled)
	_preview_face(shown, shown.global_position + _heading(travelled))
	if progress < 1.0:
		var moving: String = animation_name if animation_name != "" else _preview_walk(owner_stage, role)
		_preview_clip(owner_stage, role, moving, seconds_since_fire)
	else:
		_preview_clip(owner_stage, role, _preview_idle(owner_stage, role), seconds_since_fire - seconds)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	var line: Path3D = route()
	if line == null:
		warnings.append("'path' does not name a Path3D.")
	elif line.curve == null or line.curve.point_count < 2:
		warnings.append("The path needs a curve with at least two points.")
	return warnings
