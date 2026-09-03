extends AiTestCase
## THE invariant of the timeline front end, asserted on the maths.
##
## Putting a camera on an AnimationPlayer has one obvious implementation
## and it is a disaster: key the Camera3D's transform. A keyed transform is
## absolute, so a shot stops being ABOUT anybody — the subject takes a step
## and the framing is wrong, two units of different heights get different
## shots from one authored scene, and CameraFraming becomes a second,
## competing way to say where a camera is. Whichever of the two a given
## scene happened to use would then be a coin flip, and the failure would
## look like bad authoring rather than like a split vocabulary.
##
## So the claim here is narrow and load-bearing: FramingRig has no answer
## of its own. Whatever it computes, and whatever it does to the real
## camera, is CameraFraming's answer for the same values — reached through
## TWO DIFFERENT SOURCES, which is the only way to tell "one function" from
## "two functions that agree today".
##
##   the editor path   no cast exists; roles resolve against sibling
##                     markers, through position_from(Callable).
##   the runtime path  a cast exists; roles resolve through it, and the
##                     rig hands the framing to the one cinematic camera.
##
## The values below are all deliberately off-default. With the defaults,
## a rig that had quietly stopped copying its properties into the framing
## would still agree with a default CameraFraming, and this suite would be
## green for the worst possible reason.

const ORIGIN := Vector3(3.0, 1.5, -2.0)
const FACING := Vector3(0.0, 0.0, -1.0)

const DISTANCE := 5.5
const AZIMUTH := 47.0
const ELEVATION := 21.0
const FOV := 62.0
const OFFSET := Vector3(0.0, 1.75, 0.0)
const MARK := &"RigVocabularyMark"

var _saved_camera: CinematicCamera = null
var _camera: CinematicCamera = null


func run() -> void:
	_saved_camera = CinematicDirector.camera()

	# The mark the CAST path resolves through, standing at exactly where
	# the fake source claims to be. Same place, two ways of finding it.
	var spot := Node3D.new()
	spot.name = MARK
	spot.add_to_group(SceneCast.MARK_GROUP)
	_root.add_child(spot)
	spot.global_position = ORIGIN
	await get_tree().process_frame

	var cast := SceneCast.new()
	cast.tree = get_tree()

	var rig := FramingRig.new()
	rig.subject_mark = MARK
	rig.distance = DISTANCE
	rig.azimuth_degrees = AZIMUTH
	rig.elevation_degrees = ELEVATION
	rig.fov_degrees = FOV
	rig.look_offset = OFFSET
	_root.add_child(rig)
	await get_tree().process_frame

	var reference := CameraFraming.new()
	reference.subject_mark = MARK
	reference.distance = DISTANCE
	reference.azimuth_degrees = AZIMUTH
	reference.elevation_degrees = ELEVATION
	reference.fov_degrees = FOV
	reference.look_offset = OFFSET

	# --- SETUP: the reference is not the default shot --------------------
	check("SETUP: these values are nowhere near CameraFraming's defaults",
		reference.resolve_position(cast).distance_to(
			CameraFraming.new().resolve_position(cast)) > 1.0,
		"the reference framing resolves to almost the same place as a " +
		"default one, so a rig that ignored its properties would pass")

	# --- the editor path -------------------------------------------------
	var source: Callable = func(_mark: StringName, _role: StringName) -> Dictionary:
		return {"origin": ORIGIN, "facing": FACING}

	check("the rig's own answer IS CameraFraming's answer",
		rig.position_for(source).distance_to(reference.resolve_position(cast)) < 0.001,
		"rig says %s, CameraFraming says %s — the rig has grown a second " % [
			str(rig.position_for(source)), str(reference.resolve_position(cast))] +
		"way to say where a camera is")

	check("and so is where it looks",
		rig.look_for(source).distance_to(reference.resolve_look(cast)) < 0.001,
		"rig aims at %s, CameraFraming aims at %s" % [
			str(rig.look_for(source)), str(reference.resolve_look(cast))])

	# --- the runtime path ------------------------------------------------
	# The rig must not merely COMPUTE the right place, it must put the one
	# cinematic camera there — through frame(), not by driving a camera of
	# its own. A rig that keyed a raw transform onto a private Camera3D
	# would pass every check above and fail this one.
	_camera = CinematicCamera.new()
	_root.add_child(_camera)
	await get_tree().process_frame

	rig.begin(cast)
	rig.tick()

	var expected: Vector3 = reference.resolve_position(cast)
	check("and ticking the rig moves the ONE cinematic camera there",
		_camera.is_framing()
			and _camera.camera().global_position.distance_to(expected) < 0.01,
		"framing=%s, camera at %s, expected %s — the rig is not going " % [
			_camera.is_framing(), str(_camera.camera().global_position), str(expected)] +
		"through CinematicCamera.frame()")

	check("and hands it the fov as well, so a zoom is part of the same shot",
		is_equal_approx(_camera.camera().fov, FOV),
		"fov is %.1f, expected %.1f" % [_camera.camera().fov, FOV])

	check("and the rig owns no camera of its own at runtime",
		rig.get_node_or_null(NodePath(FramingRig.PREVIEW_NAME)) == null,
		"there is a Camera3D under the rig outside the editor — a second " +
		"camera in the world, and Camera3D.current is first-come")

	# --- a stopped rig stops driving --------------------------------------
	rig.end()
	var parked: Vector3 = _camera.camera().global_position
	rig.distance = DISTANCE * 3.0
	rig.tick()
	check("a rig that has been ended stops driving the camera",
		_camera.camera().global_position.distance_to(parked) < 0.01,
		"the camera moved after end() — a torn-down stage is still " +
		"writing to the screen")

	rig.queue_free()
	_cleanup()


func _cleanup() -> void:
	if is_instance_valid(_camera):
		_camera.release()
		_camera.queue_free()
	CinematicDirector.register_camera(_saved_camera)
