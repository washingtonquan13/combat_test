class_name CinematicCamera
extends Node3D
## The one camera any staged moment uses — a dialogue, a fusion, an area
## entrance, a boss walking in.
##
## REPLACES DialogueCameraRig, which is deleted rather than moved. That rig
## called the camera it owned "the dedicated cinematic Camera3D" in its own
## header and then stated, as a virtue, that it was "never called directly
## by anything else" — a cinematic camera with exactly one input channel,
## and that channel was dialogue. Nothing of it is orphaned: the Camera3D
## became this, the framing maths became CameraFraming.resolve_position,
## the face anchor was already one line delegating to unit.anchor(HEAD),
## and its three dialogue signal handlers were the coupling itself.
##
## Its four @export shot fields were GLOBAL to every conversation in the
## game — one distance for a whispered confession and a shouted threat, for
## a pixie and a dragon. They are per-shot data now, which is the actual
## reason to delete the object rather than relocate it.
##
## AN ATTENTION NODE, registered in main_root.gd beside Indicators and
## GroundClickTarget: a Node3D only renders in the World3D of the viewport
## above it, so anything representing the player LOOKING at a world has to
## ride into whichever viewport is being looked at. That is the right
## category for a cinematic camera — it belongs to the viewer, not to any
## world.
##
## Claims the slot CameraDirector already had waiting
## (activate_cinematic_camera), so no new arbitration exists. WHOEVER
## FRAMES, RELEASES: the claim is held until release() is called, not for
## the length of one scene, because a conversation frames once per line and
## must not hand the screen back between them.

var _camera: Camera3D
var _cast: SceneCast = null
var _from: CameraFraming = null
var _to: CameraFraming = null
var _transit: float = 0.0
var _ease: float = -2.0
var _elapsed: float = 0.0
var _claimed: bool = false


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.name = "Camera"
	add_child(_camera)
	set_process(false)
	CinematicDirector.register_camera(self)


## Puts the camera on `framing`, arriving over `transit_seconds`.
##
## A transit is only honoured between framings that orbit the same person.
## Crossing to a different subject is shot-and-reverse, which is an EDIT,
## not a move — sweeping between two faces is the swoop that coverage
## exists to avoid, so it snaps whatever the caller asked for.
func frame(framing: CameraFraming, cast: SceneCast, transit_seconds: float = 0.0,
		ease_curve: float = -2.0) -> void:
	if framing == null or cast == null:
		return
	_cast = cast
	_ease = ease_curve
	var can_travel: bool = transit_seconds > 0.0 and _to != null and _to.shares_subject_with(framing)
	_from = _to if can_travel else null
	_transit = transit_seconds if can_travel else 0.0
	_elapsed = 0.0
	_to = framing
	_claim()
	set_process(true)
	_apply()


## Hands the viewport back to the tactical camera. Safe to call when
## nothing was framed.
func release() -> void:
	set_process(false)
	_to = null
	_from = null
	_cast = null
	if _claimed:
		_claimed = false
		CameraDirector.deactivate_cinematic_camera()


func is_framing() -> bool:
	return _to != null


## Exposed so a test can assert where the camera actually ended up rather
## than that a method was called.
func camera() -> Camera3D:
	return _camera


## How far through a transit, 0 to 1. Returns 1 when there is no transit,
## because "already arrived" is what a cut means.
func transit_progress() -> float:
	if _transit <= 0.0:
		return 1.0
	return clampf(_elapsed / _transit, 0.0, 1.0)


## Re-resolves every frame, not only when framed. A framing is relative to
## a person, so a subject who walks is followed for free — and a scene that
## wants a shot to stop following simply frames a mark instead, once phase
## 3 adds them.
func _process(delta: float) -> void:
	if _transit > 0.0 and _elapsed < _transit:
		_elapsed += delta
	_apply()


func _apply() -> void:
	if _to == null or _cast == null:
		return
	var showing: CameraFraming = _to
	if _from != null and _transit > 0.0 and _elapsed < _transit:
		showing = _from.blended_toward(_to, ease(clampf(_elapsed / _transit, 0.0, 1.0), _ease))

	var eye: Vector3 = showing.resolve_position(_cast)
	var target: Vector3 = showing.resolve_look(_cast)
	if eye.is_equal_approx(Vector3.ZERO) and target.is_equal_approx(Vector3.ZERO):
		return  # nobody is cast in this framing's roles yet
	_camera.global_position = eye
	if not eye.is_equal_approx(target):
		_camera.look_at(target, Vector3.UP)
	_camera.fov = showing.fov_degrees


func _claim() -> void:
	if _claimed:
		return
	_claimed = true
	CameraDirector.activate_cinematic_camera(_camera)
