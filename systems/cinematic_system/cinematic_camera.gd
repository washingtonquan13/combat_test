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
##
## SHAKE (CinematicStage.impact). There is no hit-stop: the framing never
## stops on a contact. shake() adds trauma, 0..1, decaying linearly to nothing over the seconds given.
## The camera is displaced from where the framing put it by trauma SQUARED
## times the limits below, read from smooth noise, so a light knock barely
## moves and a heavy one jolts. The displacement rides on top of every
## framing, so a cut during a shake keeps shaking.

## Displacement at trauma 1: metres sideways and up, degrees of yaw and
## pitch, degrees of roll.
const SHAKE_OFFSET := 0.05
const SHAKE_TURN := 1.2
const SHAKE_ROLL := 1.5
## How fast the noise is read, per second. Higher is a buzz, lower a sway.
const SHAKE_RATE := 18.0

var _camera: Camera3D
var _lens: CameraAttributesPractical = CameraAttributesPractical.new()
var _cast: SceneCast = null
var _from: CameraFraming = null
var _to: CameraFraming = null
var _transit: float = 0.0
var _ease: float = -2.0
var _elapsed: float = 0.0
var _claimed: bool = false
var _locked: bool = false
var _trauma: float = 0.0
var _trauma_fall: float = 0.0
var _shake_clock: float = 0.0
var _noise: FastNoiseLite = null
## Where the framing put the camera, before any shake.
var _base: Transform3D = Transform3D.IDENTITY


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
##
## `locked_off` puts the camera where the framing resolves NOW and leaves it
## there, like a camera on a tripod. A framing measures from a head, and a
## head moves with every breath of an idle, so a shot that keeps following
## one bobs with it. A conversation between people standing still wants the
## tripod.
func frame(framing: CameraFraming, cast: SceneCast, transit_seconds: float = 0.0,
		ease_curve: float = -2.0, locked_off: bool = false) -> void:
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
	_locked = locked_off
	set_process(not locked_off or _trauma > 0.0)
	_apply()


## Hands the viewport back to the tactical camera. Safe to call when
## nothing was framed.
func release() -> void:
	set_process(false)
	_to = null
	_from = null
	_cast = null
	_trauma = 0.0
	if _claimed:
		_claimed = false
		CameraDirector.deactivate_cinematic_camera()


func is_framing() -> bool:
	return _to != null


## Stops re-resolving: the camera stays where the framing last put it, as
## if `locked_off` had been asked. A stage calls this when it unbinds, since
## its marks go with it and a framing on them has nothing left to resolve.
## A shake in progress still runs out.
func lock_off(cast: SceneCast) -> void:
	if _to == null or cast != _cast:
		return
	_locked = true
	_from = null
	_transit = 0.0
	set_process(_trauma > 0.0)


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
	if not _locked:
		if _transit > 0.0 and _elapsed < _transit:
			_elapsed += delta
		_apply()
	if _trauma > 0.0:
		_trauma = maxf(0.0, _trauma - _trauma_fall * delta)
		_shake_clock += delta
		_shaken()
	elif _locked:
		set_process(false)


## Adds `amount` of trauma (0..1, capped at 1), all of which decays away
## over `seconds`.
func shake(amount: float, seconds: float) -> void:
	if amount <= 0.0 or seconds <= 0.0:
		return
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_noise.frequency = 1.0
		_noise.seed = 7
	_trauma = minf(1.0, _trauma + amount)
	_trauma_fall = _trauma / seconds
	set_process(true)


func trauma() -> float:
	return _trauma



## How far the shake has moved the camera from its framing, in metres.
func shake_offset() -> float:
	return _camera.global_position.distance_to(_base.origin)


## The camera at its framing, moved by the current shake.
func _shaken() -> void:
	if _trauma <= 0.0 or _noise == null:
		_camera.global_transform = _base
		return
	var power: float = _trauma * _trauma
	var t: float = _shake_clock * SHAKE_RATE
	var side: float = _noise.get_noise_2d(t, 0.0)
	var up: float = _noise.get_noise_2d(t, 100.0)
	var yaw: float = _noise.get_noise_2d(t, 200.0)
	var pitch: float = _noise.get_noise_2d(t, 300.0)
	var roll: float = _noise.get_noise_2d(t, 400.0)
	var moved: Transform3D = _base.translated_local(Vector3(side, up, 0.0) * SHAKE_OFFSET * power)
	moved.basis = moved.basis 		* Basis(Vector3.UP, deg_to_rad(yaw * SHAKE_TURN * power)) 		* Basis(Vector3.RIGHT, deg_to_rad(pitch * SHAKE_TURN * power)) 		* Basis(Vector3.BACK, deg_to_rad(roll * SHAKE_ROLL * power))
	_camera.global_transform = moved


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
		_camera.look_at(target, CameraFraming.up_for(eye, target))
	_camera.fov = showing.fov_degrees
	_focus(showing.focus_blur, eye.distance_to(target))
	_base = _camera.global_transform
	if _trauma > 0.0:
		_shaken()


## Focuses on whatever is `reach` away and blurs the rest by `blur`. The
## sharp band is cut in proportion to the reach, so a face stays sharp ear
## to nose whether the shot is close or long.
func _focus(blur: float, reach: float) -> void:
	if blur <= 0.0:
		_camera.attributes = null
		return
	_lens.dof_blur_amount = blur
	_lens.dof_blur_near_enabled = true
	_lens.dof_blur_near_distance = reach * 0.7
	_lens.dof_blur_near_transition = reach * 0.3
	_lens.dof_blur_far_enabled = true
	_lens.dof_blur_far_distance = reach * 1.5
	_lens.dof_blur_far_transition = reach * 4.0
	_camera.attributes = _lens


func _claim() -> void:
	if _claimed:
		return
	_claimed = true
	CameraDirector.activate_cinematic_camera(_camera)
