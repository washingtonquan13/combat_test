@tool
class_name FramingRig
extends Node3D
## One SHOT, as something a timeline can key. Lives under a stage's Shots/
## node; the stage's `shot` property says which one is live, and keying
## that is a cut. See cinematic_stage.gd.
##
## ONE VOCABULARY, AND THIS IS WHERE IT WOULD HAVE BEEN LOST. The obvious
## way to put a camera on an AnimationPlayer is to key a Camera3D's
## transform, and it is the single worst thing that could happen to this
## system: a keyed transform is absolute, so every shot stops being
## relative to the person it is about. The subject takes a step and the
## framing is wrong; two units of different heights get different shots
## from the same scene; and CameraFraming — the polar model that makes a
## push-in, an arc, a crane and a dolly zoom one resource instead of four
## classes — becomes a second, competing way to say where a camera is.
##
## So this rig has NO camera of its own. Its exports mirror CameraFraming
## exactly, the timeline keys THOSE, and while it is the live shot it hands
## the resulting framing to the one cinematic camera every frame.
##
##   continuous keys (interp linear/cubic)   a move within the shot.
##       Interpolating in polar space IS the arc: azimuth sweeps around the
##       subject rather than cutting the chord.
##   discrete keys (update = 1)              a jump, and the only sane
##       setting for the identity properties — a subject_role halfway
##       between two names is not a thing.
##
## IN THE EDITOR there is no cast, so the stage's preview camera resolves
## roles against the StageRole stand-ins and marks against the stage's own
## Marks/ node, through the same maths (CameraFraming.position_from) — a
## preview that computed its own answer would be a second vocabulary.

## Mirrors CameraFraming field for field. The four name fields are offered
## as dropdowns of what the stage has — its roles, its Marks/, and the
## world marks it declares (see _validate_property). Free text is still
## allowed, because a WORLD mark belongs to an area the stage cannot see.
@export var subject_role: StringName = &"speaker"
@export var subject_mark: StringName = &""
@export var distance: float = 1.4
@export var azimuth_degrees: float = 20.0
@export var elevation_degrees: float = 2.046
@export var fov_degrees: float = 40.0
@export var look_role: StringName = &""
@export var look_mark: StringName = &""
@export var look_offset: Vector3 = Vector3.ZERO

## ONE framing, reused. A new Resource every frame would be sixty
## allocations a second for a value overwritten before anything reads it
## twice — and CinematicCamera keeps a reference to the last one it was
## given, so churning them is churn it can see.
var _framing: CameraFraming = CameraFraming.new()
var _cast: SceneCast = null


func _validate_property(property: Dictionary) -> void:
	var stage: CinematicStage = _stage()
	if stage == null:
		return
	match property.name:
		"subject_role", "look_role":
			property.hint = PROPERTY_HINT_ENUM_SUGGESTION
			property.hint_string = ",".join(stage.role_names())
		"subject_mark", "look_mark":
			property.hint = PROPERTY_HINT_ENUM_SUGGESTION
			property.hint_string = ",".join(stage.spot_names())


## Starts driving the real camera. Called by the stage on bind.
func begin(cast: SceneCast) -> void:
	_cast = cast


## Stops. The camera KEEPS its last framing — whether the screen goes back
## to gameplay is the caller's decision, not the rig's (see CinematicCues,
## which releases, and fusion, which deliberately does not).
func end() -> void:
	_cast = null


## One frame of camera. Driven by the stage rather than by this node's own
## _process so that actors are moved to their marks BEFORE the shot that
## frames them is resolved, and so only the live shot ticks.
func tick() -> void:
	# The editor guard as well: the director is an autoload, and autoloads
	# do not run in the editor.
	if _cast == null or Engine.is_editor_hint():
		return
	var camera: CinematicCamera = CinematicDirector.camera()
	if camera == null:
		return
	# Always a cut. The timeline is the tween — asking for a transit here
	# would put two interpolators on one move.
	camera.frame(framing(), _cast, 0.0)


## This rig's properties as a CameraFraming. The same object every time.
func framing() -> CameraFraming:
	_framing.subject_role = subject_role
	_framing.subject_mark = subject_mark
	_framing.distance = distance
	_framing.azimuth_degrees = azimuth_degrees
	_framing.elevation_degrees = elevation_degrees
	_framing.fov_degrees = fov_degrees
	_framing.look_role = look_role
	_framing.look_mark = look_mark
	_framing.look_offset = look_offset
	return _framing


## Where this rig puts the camera, given a source that answers
## (mark, role) -> {"origin", "facing"}. The editor preview's entry point,
## and the one a test can drive without standing up a world.
func position_for(source: Callable) -> Vector3:
	return framing().position_from(source)


func look_for(source: Callable) -> Vector3:
	return framing().look_from(source)


## Resolution WITHOUT a cast: the stage's StageRole stand-ins by role, and
## Marks/<name> under the stage. The stand-in rather than the marker, so a
## beat previewing a walk moves what the camera frames too.
func editor_source() -> Callable:
	return func(mark_name: StringName, role: StringName) -> Dictionary:
		var stage: CinematicStage = _stage()
		if stage == null:
			return {}
		var spot: Node3D = null
		if mark_name != &"":
			spot = stage.local_mark(mark_name)
		elif role != &"":
			var marker: StageRole = stage.role_marker(role)
			spot = marker.preview_body() if marker else null
		if spot == null:
			return {}
		return {
			"origin": spot.global_position,
			"facing": -spot.global_transform.basis.z,
		}


func _stage() -> CinematicStage:
	var node: Node = get_parent()
	while node != null and not (node is CinematicStage):
		node = node.get_parent()
	return node as CinematicStage
