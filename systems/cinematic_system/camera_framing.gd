class_name CameraFraming
extends Resource
## Where the camera is and what it is looking at, expressed relative to
## the people in the scene rather than to the world.
##
## POSITION AND LOOK TARGET ARE INDEPENDENT, and that is the whole design.
## A framing that only says "orbit this subject" can never express a pan or
## a tilt, because the camera would always face whatever it orbits. Keeping
## them apart is also what makes a shot like "hold still and tilt up to the
## thing above the platform" a case of the general model rather than a
## special one.
##
## POSITION IS POLAR, not a world vector, and that is what makes the move
## vocabulary fall out of one resource instead of one class per move:
##
##   push-in / dolly   distance changes
##   arc / orbit       azimuth changes
##   crane / jib       elevation changes
##   zoom              fov changes
##   dolly zoom        distance and fov, inversely
##   pan / tilt        position held, look_offset changes
##   cut               the transit takes no time (see CameraShotStep)
##
## Interpolating azimuth in polar space IS the arc. A tween between two
## world positions would cut the chord instead, passing closer to the
## subject in the middle of the move — the classic wrong-looking orbit.

## Whose orbit the camera sits on. A role name resolved through the cast,
## never a node, so one framing plays with whoever is cast in it.
@export var subject_role: StringName = &"speaker"
## Orbit a fixed point in the world instead of a person. Takes precedence
## over subject_role when set. This is what lets a shot open on a THING —
## the fusion device, an altar, a door — rather than on somebody's face,
## and it is why position is a SOURCE rather than always a subject.
@export var subject_mark: StringName = &""
## Metres from the subject's head.
@export var distance: float = 1.4
## Degrees around the subject's own facing. The default is the slight
## three-quarter angle a dead-on mugshot lacks.
@export var azimuth_degrees: float = 20.0
## Degrees above the horizontal. 2.046 reproduces the 0.05 m rise the
## previous dialogue rig applied at its 1.4 m distance, so conversation
## framing is unchanged by the move to polar.
@export var elevation_degrees: float = 2.046
@export var fov_degrees: float = 40.0

## Who the camera looks at. Empty means the subject — the common case, and
## the only one a conversation needs.
@export var look_role: StringName = &""
## Look at a fixed point instead. Takes precedence over look_role.
@export var look_mark: StringName = &""
## Shifts the aim point without moving the camera, in world axes. This is
## the pan/tilt knob: same position, different look.
@export var look_offset: Vector3 = Vector3.ZERO


## True when `other` orbits the same person, and can therefore be reached
## by interpolating rather than cut to.
##
## Moving BETWEEN two people's orbits is not a camera move at all — it is
## shot and reverse, which is an edit. A transit across it would sweep the
## camera through the space between two faces, which is the disorienting
## swoop that coverage exists to avoid.
func shares_subject_with(other: CameraFraming) -> bool:
	return other != null and other.subject_role == subject_role 		and other.subject_mark == subject_mark


func resolve_position(cast: SceneCast) -> Vector3:
	return position_of(_read_source(cast, subject_mark, subject_role))


func resolve_look(cast: SceneCast) -> Vector3:
	var aim: Array = look_target()
	return look_of(_read_source(cast, aim[0], aim[1]))


## The same two answers, from a source that is NOT a cast.
##
## FramingRig's editor preview is the reason these exist: there is no cast
## in the editor, only sibling markers, and a preview that reimplemented
## the polar maths would be a SECOND camera vocabulary that could silently
## disagree with the one that ships. `source` is asked (mark, role) and
## answers {"origin": Vector3, "facing": Vector3}, or {} for unresolved —
## exactly the shape _read_source returns.
##
## Note what is factored and what is not: the CALLABLE is only the lookup,
## and the maths below is reached by both paths as one function rather
## than as two that happen to agree today.
func position_from(source: Callable) -> Vector3:
	return position_of(source.call(subject_mark, subject_role))


func look_from(source: Callable) -> Vector3:
	var aim: Array = look_target()
	return look_of(source.call(aim[0], aim[1]))


## Which (mark, role) the camera aims at. Falls back to the SUBJECT, not
## to nothing: a framing that says only where the camera is means "look at
## what you are orbiting", which is every ordinary shot.
func look_target() -> Array:
	if look_mark == &"" and look_role == &"":
		return [subject_mark, subject_role]
	return [look_mark, look_role]


## THE polar maths. One copy, reached by the cast path and the editor
## path alike.
func position_of(source: Dictionary) -> Vector3:
	if source.is_empty():
		return Vector3.ZERO
	var elevation: float = deg_to_rad(elevation_degrees)
	var horizontal: Vector3 = (source["facing"] as Vector3).rotated(
		Vector3.UP, deg_to_rad(azimuth_degrees))
	var direction: Vector3 = (horizontal * cos(elevation) + Vector3.UP * sin(elevation)).normalized()
	return (source["origin"] as Vector3) + direction * distance


func look_of(source: Dictionary) -> Vector3:
	if source.is_empty():
		return Vector3.ZERO
	return (source["origin"] as Vector3) + look_offset


## Where a framing measures from, and which way that thing faces — from a
## mark if one is named, otherwise from the unit in `role`.
##
## Returns a Dictionary rather than filling parameters because GDScript
## passes Vector3 by VALUE; an out-parameter version of this compiles,
## runs, and silently leaves both vectors at zero.
##
## Empty is a normal answer, not an error: a scene can be framed before its
## cast is complete, and the camera simply holds where it was.
func _read_source(cast: SceneCast, mark_name: StringName, role: StringName) -> Dictionary:
	if mark_name != &"":
		var spot: Node3D = cast.mark(mark_name)
		if spot == null:
			return {}
		return {"origin": spot.global_position, "facing": -spot.global_transform.basis.z}
	var actor: Unit = cast.unit(role)
	if actor == null:
		return {}
	return {
		"origin": actor.anchor(CharacterModel.Anchor.HEAD),
		"facing": actor.visual_forward(),
	}


## A framing partway between this one and `to`.
##
## Only meaningful when both share a subject — see shares_subject_with.
## azimuth uses lerp_angle so an orbit takes the short way round instead of
## unwinding the long way when the two angles straddle a wrap.
func blended_toward(to: CameraFraming, t: float) -> CameraFraming:
	var mid := CameraFraming.new()
	mid.subject_role = to.subject_role
	mid.subject_mark = to.subject_mark
	mid.look_role = to.look_role
	mid.look_mark = to.look_mark
	mid.distance = lerpf(distance, to.distance, t)
	mid.azimuth_degrees = rad_to_deg(lerp_angle(
		deg_to_rad(azimuth_degrees), deg_to_rad(to.azimuth_degrees), t))
	mid.elevation_degrees = lerpf(elevation_degrees, to.elevation_degrees, t)
	mid.fov_degrees = lerpf(fov_degrees, to.fov_degrees, t)
	mid.look_offset = look_offset.lerp(to.look_offset, t)
	return mid
