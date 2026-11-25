class_name CameraImpulse
## A knock to whichever camera is showing the viewport: it jumps a few
## centimetres along a blow and settles back. Uses Camera3D's own h_offset
## and v_offset, so it rides on top of whatever places the camera (the CRPG
## camera, a cinematic shot) without touching it.
##
## UnitAnimator calls it as a blow connects (its hitstop).

const OUT := 0.04
const BACK := 0.4
const _TWEEN := &"camera_impulse_tween"
const _BASE := &"camera_impulse_base"


## Knocks `viewport`'s camera along `direction` (world space; only the part
## across the screen shows) by `metres` as seen from 5 m: the knock grows with
## the camera's distance to `at`, so it is the same size on screen from a
## close shot and from the game camera.
static func kick(viewport: Viewport, at: Vector3, direction: Vector3, metres: float) -> void:
	var camera: Camera3D = viewport.get_camera_3d() if viewport else null
	if camera == null or metres <= 0.0:
		return
	metres *= camera.global_position.distance_to(at) / 5.0
	# A knock still settling is ended where it started, so knocks never add up.
	var running: Tween = camera.get_meta(_TWEEN) if camera.has_meta(_TWEEN) else null
	if running and running.is_valid():
		running.kill()
		var was: Vector2 = camera.get_meta(_BASE)
		camera.h_offset = was.x
		camera.v_offset = was.y
	var base := Vector2(camera.h_offset, camera.v_offset)
	var across := Vector2(direction.dot(camera.global_basis.x), direction.dot(camera.global_basis.y))
	if across.length() < 0.2:
		across = Vector2(0.0, -1.0)
	var to: Vector2 = base + across.normalized() * metres
	var tween := camera.create_tween()
	tween.tween_property(camera, "h_offset", to.x, OUT)
	tween.parallel().tween_property(camera, "v_offset", to.y, OUT)
	tween.tween_property(camera, "h_offset", base.x, BACK).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(camera, "v_offset", base.y, BACK).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	camera.set_meta(_TWEEN, tween)
	camera.set_meta(_BASE, base)
