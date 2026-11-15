@tool
class_name CameraPathRig
extends FramingRig
## A shot whose camera rides a drawn line: a dolly, a track, a crane, or
## all three in one curve. Lives under Shots/ like any rig, is cut to by
## keying the stage's `shot`, and its move is one keyed property, `progress`.
##
## WHERE THE CAMERA IS, AND WHY IT MAY BE A LINE IN THE SET. FramingRig's
## rule is that a shot is about a person, never a keyed transform, so a
## step by the subject does not wreck it. That rule is about the shots that
## frame people. A moving wide shot is about the place: the camera comes
## down over a wall, along a road, past a gate. Saying that as an orbit
## around somebody is a fight with the vocabulary, and "frame a point no one
## stands on" was a named gap. The line is the stage's own, like Paths/ for
## WalkPathBeat and Marks/, so it moves with the stage's anchor_mark and
## the shot still belongs to the scene rather than to world coordinates.
##
## WHAT IT LOOKS AT IS STILL A PERSON OR A MARK. look_role, look_mark,
## look_offset and pan_degrees mean what they mean on any rig (an empty look
## means subject_role, as ever), so a ride that keeps the hobgoblin in frame
## keeps him there wherever he walks. Or the aim rides a second line
## (aim_path) at the same progress: a move that starts on one thing and
## ends on another, which an orbit rig cannot do without cutting.
##
## THE TIMELINE IS THE TWEEN. `progress` is 0 at the line's first point and
## 1 at its last, by distance along it, so the camera's speed is the keys'
## and nothing else. Ease in and out with the key's transition curve.
## There is deliberately no duration or easing field here: two clocks on
## one move is how a shot ends a second before its cut.
##
## ONE CAMERA STILL. The rig hands the CinematicCamera a CameraFraming as
## every rig does; only where that framing says the eye is differs. The
## editor preview reads the same answer through position_for/look_for.

## The line the camera rides. A Path3D, usually a child of this rig.
@export_node_path("Path3D") var path: NodePath = NodePath("")
## How far along `path`, 0 to 1, by distance. The one property to key.
@export_range(0.0, 1.0, 0.001) var progress: float = 0.0
## Optional second line the aim rides at the same progress. When set it
## replaces look_role/look_mark; look_offset and pan still apply.
@export_node_path("Path3D") var aim_path: NodePath = NodePath("")

var _riding: _Riding = _Riding.new()


## This rig as a CameraFraming: every field the base mirrors, plus where
## on the line the eye and aim are right now.
func framing() -> CameraFraming:
	_fill(_riding)
	_riding.eye = _along(path)
	_riding.aim = _along(aim_path) if not aim_path.is_empty() else null
	return _riding


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if _line(path) == null:
		warnings.append("'path' names no Path3D with two or more points; the camera will hold where it was.")
	if not aim_path.is_empty() and _line(aim_path) == null:
		warnings.append("'aim_path' names no Path3D with two or more points.")
	return warnings


## A world point on `line_path` at `progress`, or null when there is no
## line to ride (the camera then holds, as for an unresolved role).
func _along(line_path: NodePath) -> Variant:
	var line: Path3D = _line(line_path)
	if line == null:
		return null
	var curve: Curve3D = line.curve
	return line.global_transform * curve.sample_baked(
		clampf(progress, 0.0, 1.0) * curve.get_baked_length(), true)


func _line(line_path: NodePath) -> Path3D:
	if line_path.is_empty() or not is_inside_tree():
		return null
	var line := get_node_or_null(line_path) as Path3D
	if line == null or line.curve == null or line.curve.point_count < 2:
		return null
	return line


## The framing a CameraPathRig hands out. Same fields, same look and pan
## maths; the eye is a point on the line instead of a place on an orbit.
class _Riding extends CameraFraming:
	## Where the eye is, or null for "no line": resolves to nothing, so
	## the camera holds instead of jumping to the world origin.
	var eye: Variant = null
	## Where the aim is when it rides a line of its own, else null.
	var aim: Variant = null

	func resolve_position(_cast: SceneCast) -> Vector3:
		return eye if eye != null else Vector3.ZERO

	func position_from(_source: Callable) -> Vector3:
		return eye if eye != null else Vector3.ZERO

	func resolve_look(cast: SceneCast) -> Vector3:
		if eye == null:
			return Vector3.ZERO
		if aim != null:
			return _panned(eye, (aim as Vector3) + look_offset)
		return super(cast)

	func look_from(source: Callable) -> Vector3:
		if eye == null:
			return Vector3.ZERO
		if aim != null:
			return _panned(eye, (aim as Vector3) + look_offset)
		return super(source)

	## A ride is never reached by a transit from another shot. Its eye is
	## not on any orbit, so blending toward it would cut the chord. It is
	## always a cut, which is what keying `shot` already means.
	func shares_subject_with(_other: CameraFraming) -> bool:
		return false
