@tool
class_name FramingRig
extends Node3D
## The camera, as something a timeline can key.
##
## ONE VOCABULARY, AND THIS IS WHERE IT WOULD HAVE BEEN LOST. The obvious
## way to put a camera on an AnimationPlayer is to key a Camera3D's
## transform, and it is the single worst thing that could happen to this
## system: a keyed transform is absolute, so every shot stops being
## relative to the person it is about. The subject takes a step and the
## framing is wrong. Two units of different heights get different shots
## from the same authored scene. Nothing composes, nothing is reusable, and
## CameraFraming — the whole polar model, and the reason a push-in, an arc,
## a crane and a dolly zoom are one resource instead of four classes —
## becomes a second, competing way to say where a camera is.
##
## So this rig has NO camera of its own at runtime. Its exports mirror
## CameraFraming exactly, the timeline keys THOSE, and every frame it hands
## the resulting framing to the one cinematic camera. What an author scrubs
## is a framing; what ships is the same framing.
##
##   continuous keys (interp linear/cubic)   a transit. Interpolating in
##       polar space IS the arc: azimuth sweeps around the subject rather
##       than cutting the chord, which is the classic wrong-looking orbit.
##   discrete keys (update = 1)              a cut, and the only sane
##       setting for the identity properties — a subject_role halfway
##       between two names is not a thing.
##
## The transit therefore comes from the TRACK rather than from a
## transit_seconds field, and the camera is asked for a cut every frame.
## That is not a fight with CinematicCamera's own transit machinery, it is
## the layer below it: the timeline is the tween.
##
## IN THE EDITOR there is no cast, so the preview resolves roles against
## sibling StageRole markers and marks against the stage's own Marks node,
## and drives a child Camera3D. It reaches the same maths by the same
## function — see CameraFraming.position_from — because a preview that
## computed its own answer would be the second vocabulary wearing a
## different hat.

## Mirrors CameraFraming field for field. Every setter refreshes the editor
## preview, which is what makes scrubbing the timeline move the viewport
## camera: the AnimationPlayer sets these properties, and the preview
## follows.
@export var subject_role: StringName = &"speaker":
	set(value):
		subject_role = value
		_refresh()
@export var subject_mark: StringName = &"":
	set(value):
		subject_mark = value
		_refresh()
@export var distance: float = 1.4:
	set(value):
		distance = value
		_refresh()
@export var azimuth_degrees: float = 20.0:
	set(value):
		azimuth_degrees = value
		_refresh()
@export var elevation_degrees: float = 2.046:
	set(value):
		elevation_degrees = value
		_refresh()
@export var fov_degrees: float = 40.0:
	set(value):
		fov_degrees = value
		_refresh()
@export var look_role: StringName = &"":
	set(value):
		look_role = value
		_refresh()
@export var look_mark: StringName = &"":
	set(value):
		look_mark = value
		_refresh()
@export var look_offset: Vector3 = Vector3.ZERO:
	set(value):
		look_offset = value
		_refresh()

## The viewport camera an author sees while scrubbing. Editor-only: at
## runtime the one CinematicCamera owns the screen and a second Camera3D
## sitting in the world could take it.
const PREVIEW_NAME: StringName = &"Preview"

## ONE framing, reused. A new Resource every frame would be sixty
## allocations a second for a value that is overwritten before anything
## reads it twice — and CinematicCamera keeps a reference to the last one
## it was given, so churning them is churn it can see.
var _framing: CameraFraming = CameraFraming.new()
var _cast: SceneCast = null
var _preview: Camera3D = null


func _ready() -> void:
	if Engine.is_editor_hint():
		_refresh()
		return
	# A "Preview" camera that got saved into the .tscn would be a live
	# Camera3D in the world, and Camera3D.current is first-come. Remove it
	# rather than trusting it to stay quiet.
	var stray: Node = get_node_or_null(NodePath(PREVIEW_NAME))
	if stray:
		remove_child(stray)
		stray.queue_free()


## Starts driving the real camera. Called by the stage on bind.
func begin(cast: SceneCast) -> void:
	_cast = cast


## Stops. The camera KEEPS its last framing — whether the screen goes back
## to gameplay is the caller's decision, not the rig's (see CinematicCues,
## which releases, and fusion, which deliberately does not).
func end() -> void:
	_cast = null


## One frame of camera. Driven by CinematicStage rather than by this node's
## own _process so that actors are moved to their marks BEFORE the shot
## that frames them is resolved — two nodes each processing themselves
## would make that ordering a property of the tree rather than a decision.
func tick() -> void:
	if _cast == null:
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


## Resolution WITHOUT a cast: sibling StageRole markers by role, and
## Marks/<name> under the stage. This is what an author is actually
## looking at in the editor, and it is deliberately the only thing the
## preview can see — a preview that could resolve live units would be
## showing a shot the editor cannot reproduce.
func editor_source() -> Callable:
	return func(mark_name: StringName, role: StringName) -> Dictionary:
		var spot: Node3D = null
		if mark_name != &"":
			spot = _stage_mark(mark_name)
		elif role != &"":
			spot = _stage_role(role)
		if spot == null:
			return {}
		return {
			"origin": spot.global_position,
			"facing": -spot.global_transform.basis.z,
		}


func _stage_role(role: StringName) -> Node3D:
	var stage: Node = get_parent()
	if stage == null:
		return null
	for node in stage.find_children("*", "Marker3D", true, false):
		if node is StageRole and (node as StageRole).role_name() == role:
			return node
	return null


func _stage_mark(mark_name: StringName) -> Node3D:
	var stage: Node = get_parent()
	if stage == null:
		return null
	var marks: Node = stage.get_node_or_null(NodePath("Marks"))
	if marks == null:
		return null
	return marks.get_node_or_null(NodePath(String(mark_name))) as Node3D


func _refresh() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	var camera: Camera3D = _preview_camera()
	if camera == null:
		return
	var source: Callable = editor_source()
	var eye: Vector3 = position_for(source)
	var target: Vector3 = look_for(source)
	camera.fov = fov_degrees
	if eye.is_equal_approx(Vector3.ZERO) and target.is_equal_approx(Vector3.ZERO):
		return  # nothing on this stage answers to the framing's roles yet
	camera.global_position = eye
	if not eye.is_equal_approx(target):
		camera.look_at(target, Vector3.UP)


## Uses an authored "Preview" camera if the stage has one, and otherwise
## makes an unowned one — unowned so it is not packed into the .tscn, the
## same trick StageRole's whitebox uses.
func _preview_camera() -> Camera3D:
	if is_instance_valid(_preview):
		return _preview
	_preview = get_node_or_null(NodePath(PREVIEW_NAME)) as Camera3D
	if _preview == null:
		_preview = Camera3D.new()
		_preview.name = PREVIEW_NAME
		add_child(_preview)
	return _preview
